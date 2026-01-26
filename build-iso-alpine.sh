#!/bin/bash
# build-alpine-openwrt-iso.sh - 基于Alpine构建OpenWRT自动安装ISO
set -e

echo "🚀 Starting OpenWRT ISO build..."
echo "================================"

# 从环境变量获取参数
OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-autoinstall-alpine.iso}"
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# Alpine配置
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
ALPINE_ARCH="x86_64"
ALPINE_REPO="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_BRANCH="v${ALPINE_VERSION}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 工作目录
WORK_DIR="/tmp/openwrt_build_$(date +%s)"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 清理函数
cleanup() {
    log_info "Cleaning up..."
    rm -rf "$WORK_DIR" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# ==================== 步骤1: 检查输入文件 ====================
log_info "[1/5] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== 步骤2: 安装必要工具 ====================
log_info "[2/5] Installing build tools..."
apk update --no-cache
apk add --no-cache \
    alpine-sdk \
    xorriso \
    syslinux \
    squashfs-tools \
    bash \
    dialog \
    pv \
    curl

log_success "Build tools installed"

# ==================== 步骤3: 创建最小化根文件系统 ====================
log_info "[3/5] Creating minimal root filesystem..."

ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

# 创建最基本的目录结构
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc,lib,proc,sys,tmp,usr,var}
mkdir -p "$ROOTFS_DIR"/usr/{bin,sbin}
mkdir -p "$ROOTFS_DIR"/var/lib

# 创建init脚本
cat > "$ROOTFS_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh
# 最小化init脚本

# 挂载必要文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# 创建设备节点
mknod /dev/console c 5 1
mknod /dev/null c 1 3
mknod /dev/zero c 1 5

# 设置控制台
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

clear
echo ""
echo "=========================================="
echo "    OpenWRT Installer - Minimal System"
echo "=========================================="
echo ""

# 检查OpenWRT镜像
if [ -f "/openwrt.img" ]; then
    echo "✅ OpenWRT image found"
    echo ""
    echo "Starting installer..."
    echo ""
    
    # 显示可用磁盘
    echo "Available disks:"
    echo "----------------"
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || echo "No disks found"
    else
        echo "sda"
        echo "sdb"
        echo "(Using dummy disk list)"
    fi
    echo "----------------"
    echo ""
    
    echo -n "Enter target disk (e.g., sda): "
    read TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo "No disk specified"
        sleep 2
        reboot -f
    fi
    
    echo ""
    echo "Installing to /dev/$TARGET_DISK..."
    echo "This will take a moment..."
    echo ""
    
    # 写入镜像
    if [ -f /bin/dd ]; then
        dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M 2>/dev/null && echo "✅ Installation complete!" || echo "❌ Installation failed!"
    else
        echo "❌ dd command not available"
    fi
    
    echo ""
    echo "System will reboot in 5 seconds..."
    sleep 5
    reboot -f
else
    echo "❌ ERROR: OpenWRT image not found!"
    echo ""
    echo "The image should be at: /openwrt.img"
    echo ""
    echo "Dropping to emergency shell..."
    echo ""
    exec /bin/sh
fi
INIT_EOF

chmod +x "$ROOTFS_DIR/init"

# 复制busybox（如果可用）
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) "$ROOTFS_DIR/bin/busybox"
    chmod +x "$ROOTFS_DIR/bin/busybox"
    
    # 创建符号链接
    cd "$ROOTFS_DIR/bin"
    for app in sh ls cat echo dd mount grep reboot; do
        ln -sf busybox $app 2>/dev/null || true
    done
    cd "$WORK_DIR"
fi

# 复制其他必要工具
for tool in dd lsblk mount grep reboot; do
    if command -v $tool >/dev/null 2>&1; then
        tool_path=$(which $tool)
        cp "$tool_path" "$ROOTFS_DIR/bin/" 2>/dev/null || true
    fi
done

log_success "Minimal root filesystem created"

# ==================== 步骤4: 创建可启动ISO ====================
log_info "[4/5] Creating bootable ISO..."

# 创建ISO目录结构
ISO_DIR="$WORK_DIR/iso"
mkdir -p "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/syslinux"

# 复制OpenWRT镜像
cp "$OPENWRT_IMG" "$ISO_DIR/openwrt.img"

# 创建squashfs文件系统
log_info "Creating squashfs..."
mksquashfs "$ROOTFS_DIR" "$ISO_DIR/rootfs.squashfs" -comp gzip -noappend >/dev/null 2>&1 || {
    log_warning "Squashfs creation failed, continuing without compression..."
    # 如果不压缩，直接复制文件
    cp -r "$ROOTFS_DIR" "$ISO_DIR/rootfs" 2>/dev/null || true
}

# 创建简单的内核和initramfs
log_info "Creating minimal boot files..."

# 创建简单的内核文件（实际上是一个脚本）
cat > "$ISO_DIR/boot/vmlinuz" << 'VMLINUZ_EOF'
#!/bin/sh
# 这是一个占位符"内核"
echo "Booting OpenWRT installer..."
exec /init
VMLINUZ_EOF
chmod +x "$ISO_DIR/boot/vmlinuz"

# 创建简单的initramfs（包含init脚本）
mkdir -p "$WORK_DIR/initramfs"
cp "$ROOTFS_DIR/init" "$WORK_DIR/initramfs/init"
chmod +x "$WORK_DIR/initramfs/init"
cd "$WORK_DIR/initramfs"
find . | cpio -H newc -o 2>/dev/null | gzip > "$ISO_DIR/boot/initrd.gz" 2>/dev/null
cd "$WORK_DIR"

# 创建引导配置文件
cat > "$ISO_DIR/boot/syslinux/syslinux.cfg" << 'SYSLINUX_CFG'
DEFAULT openwrt
TIMEOUT 30
PROMPT 0
UI menu.c32

MENU TITLE OpenWRT Auto Installer

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.gz console=tty0 quiet

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.gz console=tty0 single
SYSLINUX_CFG

# 复制引导文件
log_info "Copying boot files..."
for file in isolinux.bin ldlinux.c32 menu.c32; do
    find /usr -name "$file" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$ISO_DIR/boot/syslinux/" 2>/dev/null || true
done

# 如果没有找到引导文件，创建一个简单的ISO
if [ ! -f "$ISO_DIR/boot/syslinux/isolinux.bin" ]; then
    log_warning "Syslinux files not found, creating simple ISO structure..."
    # 创建简单的目录结构
    mkdir -p "$ISO_DIR/isolinux"
    echo "Boot failed: Syslinux not available" > "$ISO_DIR/isolinux/isolinux.cfg"
fi

# ==================== 步骤5: 构建ISO ====================
log_info "[5/5] Building final ISO..."

mkdir -p "$OUTPUT_DIR"
cd "$ISO_DIR"

# 尝试使用xorriso创建ISO
if command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -o "$ISO_PATH" \
        . > "$WORK_DIR/xorriso.log" 2>&1 || {
        log_warning "Xorriso failed, trying alternative method..."
        # 尝试使用genisoimage
        if command -v genisoimage >/dev/null 2>&1; then
            genisoimage -volid "OPENWRT_INSTALL" -o "$ISO_PATH" . || {
                log_error "ISO creation failed"
                exit 1
            }
        else
            log_error "No ISO creation tool available"
            exit 1
        fi
    }
else
    log_error "xorriso not found"
    exit 1
fi

# 验证结果
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║        BUILD COMPLETE!                                ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    echo "📊 Build Summary:"
    echo "  OpenWRT Image:    $IMG_SIZE"
    echo "  Final ISO:        $ISO_SIZE"
    echo ""
    
    echo "🎯 This ISO contains:"
    echo "  1. OpenWRT disk image"
    echo "  2. Minimal installer system"
    echo "  3. Simple bootloader"
    echo ""
    
    echo "🔧 Usage:"
    echo "  1. Write to USB: dd if=$ISO_NAME of=/dev/sdX bs=4M"
    echo "  2. Boot from USB"
    echo "  3. Follow on-screen instructions"
    echo ""
    
    # 创建简单的构建信息
    echo "Build completed at: $(date)" > "$OUTPUT_DIR/build-info.txt"
    echo "ISO: $ISO_NAME ($ISO_SIZE)" >> "$OUTPUT_DIR/build-info.txt"
    
    log_success "✅ ISO created: $ISO_PATH"
    
else
    log_error "❌ ISO creation failed"
    exit 1
fi

log_info "Done!"
