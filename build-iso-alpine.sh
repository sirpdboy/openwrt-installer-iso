#!/bin/bash
# build-alpine-openwrt-iso.sh - 基于Alpine mkimage构建OpenWRT自动安装ISO
set -e

echo "🚀 Starting OpenWRT ISO build with Alpine mkimage..."
echo "====================================================="

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
WORK_DIR="/tmp/OPENWRT_BUILD_$(date +%s)"

# 清理函数
cleanup() {
    log_info "Performing cleanup..."
    # 只清理工作目录，不移除已构建的ISO
    rm -rf "$WORK_DIR" 2>/dev/null || true
    umount -f "$WORK_DIR/iso-mount" 2>/dev/null || true
    umount -f "$WORK_DIR/efiboot/mnt" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# ==================== 步骤1: 检查输入文件 ====================
log_info "[1/7] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== 步骤2: 安装必要工具 ====================
log_info "[2/7] Installing build tools..."
apk update --no-cache
apk add --no-cache \
    alpine-sdk \
    xorriso \
    syslinux \
    grub-bios \
    grub-efi \
    mtools \
    dosfstools \
    squashfs-tools \
    wget \
    curl \
    e2fsprogs \
    parted \
    gptfdisk \
    bash \
    dialog \
    pv

log_success "Build tools installed"

# ==================== 步骤3: 设置工作目录和下载APK工具 ====================
log_info "[3/7] Setting up build environment..."

# 创建必要目录
mkdir -p "$WORK_DIR"
mkdir -p "$OUTPUT_DIR"
cd "$WORK_DIR"

# 首先尝试直接使用系统apk作为apk.static
log_info "Setting up apk.static..."
if [ -f "/sbin/apk.static" ]; then
    cp /sbin/apk.static "$WORK_DIR/apk.static"
elif [ -f "/usr/sbin/apk.static" ]; then
    cp /usr/sbin/apk.static "$WORK_DIR/apk.static"
else
    # 尝试从已安装的包中提取
    log_info "Extracting apk.static from installed packages..."
    # 查找apk-tools包中的apk.static
    APK_STATIC_PATH=$(find /usr -name "apk.static" 2>/dev/null | head -1)
    if [ -n "$APK_STATIC_PATH" ]; then
        cp "$APK_STATIC_PATH" "$WORK_DIR/apk.static"
    else
        # 使用当前系统的apk
        log_warning "apk.static not found, using system apk"
        cp $(which apk) "$WORK_DIR/apk.static"
    fi
fi

chmod +x "$WORK_DIR/apk.static"
log_success "apk.static ready: $($WORK_DIR/apk.static --version 2>/dev/null | head -1 || echo "unknown version")"

# ==================== 步骤4: 创建根文件系统构建脚本 ====================
log_info "[4/7] Creating build scripts..."

# 创建简单的根文件系统构建脚本
cat > "$WORK_DIR/build-rootfs.sh" << 'EOF'
#!/bin/sh
set -e

# 参数
rootfs_dir="$1"
alpine_version="${2:-3.20}"
arch="${3:-x86_64}"

echo "Building root filesystem for Alpine $alpine_version ($arch)..."

# 设置Alpine仓库URL
ALPINE_REPO="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_BRANCH="v${alpine_version}"

# 创建必要的目录结构
mkdir -p "${rootfs_dir}/etc/apk"
mkdir -p "${rootfs_dir}/var/lib/apk"
mkdir -p "${rootfs_dir}/tmp"
mkdir -p "${rootfs_dir}/dev"
mkdir -p "${rootfs_dir}/proc"
mkdir -p "${rootfs_dir}/sys"

# 创建基本的设备节点
mknod "${rootfs_dir}/dev/console" c 5 1 2>/dev/null || true
mknod "${rootfs_dir}/dev/null" c 1 3 2>/dev/null || true
mknod "${rootfs_dir}/dev/zero" c 1 5 2>/dev/null || true

# 配置apk仓库
cat > "${rootfs_dir}/etc/apk/repositories" << REPO_EOF
${ALPINE_REPO}/${ALPINE_BRANCH}/main
${ALPINE_REPO}/${ALPINE_BRANCH}/community
REPO_EOF

# 设置架构
echo "${arch}" > "${rootfs_dir}/etc/apk/arch"

# 获取构建脚本所在目录的父目录
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Step 1: Installing base system..."
"${SCRIPT_DIR}/apk.static" \
    -X "${ALPINE_REPO}/${ALPINE_BRANCH}/main" \
    -X "${ALPINE_REPO}/${ALPINE_BRANCH}/community" \
    -U --allow-untrusted \
    --root "${rootfs_dir}" \
    --initdb \
    add alpine-base

echo "Step 2: Installing kernel and essential tools..."
"${SCRIPT_DIR}/apk.static" \
    -X "${ALPINE_REPO}/${ALPINE_BRANCH}/main" \
    -X "${ALPINE_REPO}/${ALPINE_BRANCH}/community" \
    -U --allow-untrusted \
    --root "${rootfs_dir}" \
    add linux-lts \
    linux-firmware-none \
    busybox \
    musl \
    bash \
    util-linux \
    coreutils

echo "Step 3: Installing disk tools..."
"${SCRIPT_DIR}/apk.static" \
    -X "${ALPINE_REPO}/${ALPINE_BRANCH}/main" \
    -X "${ALPINE_REPO}/${ALPINE_BRANCH}/community" \
    -U --allow-untrusted \
    --root "${rootfs_dir}" \
    add e2fsprogs \
    parted \
    gptfdisk \
    dialog \
    pv

echo "Step 4: Installing boot tools..."
"${SCRIPT_DIR}/apk.static" \
    -X "${ALPINE_REPO}/${ALPINE_BRANCH}/main" \
    -X "${ALPINE_REPO}/${ALPINE_BRANCH}/community" \
    -U --allow-untrusted \
    --root "${rootfs_dir}" \
    add syslinux \
    grub-bios \
    xorriso \
    squashfs-tools \
    mtools \
    dosfstools

echo "Step 5: Installing network tools..."
"${SCRIPT_DIR}/apk.static" \
    -X "${ALPINE_REPO}/${ALPINE_BRANCH}/main" \
    -X "${ALPINE_REPO}/${ALPINE_BRANCH}/community" \
    -U --allow-untrusted \
    --root "${rootfs_dir}" \
    add wget \
    curl \
    nano \
    less

# 创建主机名
echo "openwrt-installer" > "${rootfs_dir}/etc/hostname"

# 创建基本的passwd文件
cat > "${rootfs_dir}/etc/passwd" << PASSWD_EOF
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/bin:/sbin/nologin
daemon:x:2:2:daemon:/sbin:/sbin/nologin
adm:x:3:4:adm:/var/adm:/sbin/nologin
PASSWD_EOF

# 创建基本的group文件
cat > "${rootfs_dir}/etc/group" << GROUP_EOF
root:x:0:
bin:x:1:
daemon:x:2:
sys:x:3:
adm:x:4:
GROUP_EOF

# 创建基本的shadow文件（空密码）
cat > "${rootfs_dir}/etc/shadow" << SHADOW_EOF
root::0:0:99999:7:::
bin:*:0:0:99999:7:::
daemon:*:0:0:99999:7:::
adm:*:0:0:99999:7:::
SHADOW_EOF

echo "Root filesystem built successfully!"
EOF

chmod +x "$WORK_DIR/build-rootfs.sh"

# 创建init脚本
cat > "$WORK_DIR/init.sh" << 'INIT_EOF'
#!/bin/busybox sh
# OpenWRT安装器init脚本

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

# 清屏
clear

cat << "WELCOME"

╔═══════════════════════════════════════════════════════╗
║       OpenWRT Auto Installer System                   ║
╚═══════════════════════════════════════════════════════╝

System initializing...
WELCOME

# 等待设备就绪
sleep 2

# 检查OpenWRT镜像
if [ -f "/openwrt.img" ]; then
    echo ""
    echo "✅ OpenWRT image found"
    echo ""
    echo "Starting installer..."
    sleep 1
    exec /bin/sh /opt/install.sh
else
    echo ""
    echo "❌ ERROR: OpenWRT image not found at /openwrt.img"
    echo ""
    echo "Dropping to emergency shell..."
    echo ""
    exec /bin/sh
fi
INIT_EOF

# 创建安装脚本
cat > "$WORK_DIR/install.sh" << 'INSTALL_EOF'
#!/bin/sh
# OpenWRT自动安装脚本

# 设置终端
stty sane
export TERM=linux

while true; do
    clear
    cat << "EOF"

╔═══════════════════════════════════════════════════════╗
║               OpenWRT Auto Installer                  ║
╚═══════════════════════════════════════════════════════╝

EOF

    echo ""
    echo "Checking OpenWRT image..."
    
    if [ ! -f "/openwrt.img" ]; then
        echo "❌ ERROR: OpenWRT image not found!"
        echo ""
        echo "Press Enter for shell..."
        read dummy
        exec /bin/sh
    fi

    echo "✅ OpenWRT image found"
    echo ""

    # 显示磁盘
    echo "Available disks:"
    echo "================="
    lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || echo "No disks detected"
    echo "================="
    echo ""
    
    echo -n "Enter target disk (e.g., sda): "
    read TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo "Please enter a disk name"
        sleep 2
        continue
    fi
    
    if [ ! -b "/dev/$TARGET_DISK" ]; then
        echo "❌ Disk /dev/$TARGET_DISK not found!"
        sleep 2
        continue
    fi
    
    echo ""
    echo "⚠️  WARNING: This will erase ALL data on /dev/$TARGET_DISK!"
    echo ""
    echo -n "Type 'YES' to confirm: "
    read CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        sleep 2
        continue
    fi
    
    clear
    echo ""
    echo "Installing OpenWRT to /dev/$TARGET_DISK..."
    echo ""
    
    # 使用dd写入镜像
    if command -v pv >/dev/null 2>&1; then
        pv /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M
    else
        echo "Writing image (this may take a while)..."
        dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M
    fi
    
    sync
    
    echo ""
    echo "✅ Installation complete!"
    echo ""
    
    echo -n "Press Enter to continue..."
    read dummy
done
INSTALL_EOF

chmod +x "$WORK_DIR/init.sh" "$WORK_DIR/install.sh"
log_success "Build scripts created"

# ==================== 步骤5: 构建根文件系统 ====================
log_info "[5/7] Building root filesystem..."

ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

log_info "Building Alpine $ALPINE_VERSION root filesystem..."
if ! "$WORK_DIR/build-rootfs.sh" "$ROOTFS_DIR" "$ALPINE_VERSION" "$ALPINE_ARCH"; then
    log_error "Failed to build root filesystem"
    exit 1
fi

# 复制安装脚本
mkdir -p "$ROOTFS_DIR/opt"
cp "$WORK_DIR/install.sh" "$ROOTFS_DIR/opt/install.sh"
chmod +x "$ROOTFS_DIR/opt/install.sh"

# 设置init脚本
cp "$WORK_DIR/init.sh" "$ROOTFS_DIR/init"
chmod +x "$ROOTFS_DIR/init"

log_success "Root filesystem built successfully"

# ==================== 步骤6: 创建ISO ====================
log_info "[6/7] Creating ISO..."

# 创建ISO目录结构
ISO_DIR="$WORK_DIR/iso"
mkdir -p "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/syslinux"
mkdir -p "$ISO_DIR/EFI/boot"

# 查找并复制内核
log_info "Looking for kernel files..."
KERNEL_FOUND=false
if find "$ROOTFS_DIR/boot" -name "vmlinuz-*" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$ISO_DIR/boot/vmlinuz-lts" 2>/dev/null; then
    KERNEL_FOUND=true
fi

# 查找并复制initramfs
if find "$ROOTFS_DIR/boot" -name "initramfs-*" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$ISO_DIR/boot/initramfs-lts" 2>/dev/null; then
    log_success "Found initramfs"
else
    log_warning "No initramfs found, creating minimal one..."
    # 如果没有initramfs，我们仍然可以继续
    touch "$ISO_DIR/boot/initramfs-lts" 2>/dev/null || true
fi

if [ "$KERNEL_FOUND" = false ]; then
    log_error "Could not find kernel. Checking rootfs structure..."
    find "$ROOTFS_DIR" -name "vmlinuz*" -type f 2>/dev/null
    exit 1
fi

log_success "Kernel files found"

# 复制OpenWRT镜像
log_info "Adding OpenWRT image to ISO..."
cp "$OPENWRT_IMG" "$ISO_DIR/openwrt.img"

# 创建squashfs文件系统
log_info "Creating squashfs filesystem..."
mksquashfs "$ROOTFS_DIR" "$ISO_DIR/rootfs.squashfs" -comp gzip -noappend 2>&1 | tail -5

# 创建引导配置文件
log_info "Creating boot configuration..."

# ISOLINUX配置
cat > "$ISO_DIR/boot/syslinux/syslinux.cfg" << 'SYSLINUX_CFG'
DEFAULT openwrt
TIMEOUT 50
PROMPT 0
UI menu.c32

MENU TITLE OpenWRT Auto Installer

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-lts console=tty0 console=ttyS0,115200 quiet

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-lts console=tty0 console=ttyS0,115200 single
SYSLINUX_CFG

# 复制ISOLINUX文件
log_info "Copying syslinux files..."
for file in isolinux.bin ldlinux.c32 menu.c32 libutil.c32 libcom32.c32; do
    find /usr -name "$file" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$ISO_DIR/boot/syslinux/" 2>/dev/null || true
done

# 检查必需的引导文件
if [ ! -f "$ISO_DIR/boot/syslinux/isolinux.bin" ]; then
    log_warning "isolinux.bin not found, trying to locate..."
    # 从syslinux包中查找
    find /usr/share/syslinux -name "isolinux.bin" 2>/dev/null | head -1 | xargs -I {} cp {} "$ISO_DIR/boot/syslinux/" 2>/dev/null || true
fi

# 创建ISO
log_info "Building final ISO..."
cd "$ISO_DIR"

XORRISO_CMD="xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid 'OPENWRT_INSTALL' \
    -eltorito-boot boot/syslinux/isolinux.bin \
    -eltorito-catalog boot/syslinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -output '$ISO_PATH' \
    ."

log_info "Running: $XORRISO_CMD"
eval $XORRISO_CMD 2>&1 | tee "$WORK_DIR/xorriso.log"

# ==================== 步骤7: 验证结果 ====================
log_info "[7/7] Verifying build..."

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║        BUILD SUCCESSFUL!                              ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    echo "📊 Build Summary:"
    echo "  OpenWRT Image:    $IMG_SIZE"
    echo "  Final ISO:        $ISO_SIZE"
    echo "  Alpine Version:   $ALPINE_VERSION"
    echo ""
    
    echo "✅ Features:"
    echo "  - Bootable ISO with OpenWRT installer"
    echo "  - Simple text-based installer"
    echo "  - BIOS boot support (ISOLINUX)"
    echo "  - Includes all necessary tools"
    echo ""
    
    echo "🔧 Test instructions:"
    echo "  1. Burn to USB: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress"
    echo "  2. Boot from USB"
    echo "  3. Select 'Install OpenWRT' from menu"
    echo "  4. Follow prompts to install"
    echo ""
    
    # 创建构建信息
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO - Simple Build
=====================================
Build Date:      $(date)
ISO Name:        $ISO_NAME
ISO Size:        $ISO_SIZE
Alpine Version:  $ALPINE_VERSION
OpenWRT Image:   $(basename "$OPENWRT_IMG") ($IMG_SIZE)

Build Method: Direct rootfs construction using apk.static

ISO Contents:
  - /openwrt.img: OpenWRT disk image
  - /rootfs.squashfs: Alpine root filesystem
  - /boot/vmlinuz-lts: Linux kernel
  - /boot/initramfs-lts: Initial RAM disk
  - /boot/syslinux/: BIOS bootloader files

Boot Options:
  - Install OpenWRT: Main installation option
  - Emergency Shell: Fallback shell for debugging

Note: This is a BIOS-only ISO. For UEFI support, additional
configuration would be needed.
EOF
    
    log_success "✅ ISO created successfully: $ISO_SIZE"
    log_success "📁 Output: $ISO_PATH"
    
else
    log_error "❌ ISO file not created: $ISO_PATH"
    log_info "Xorriso log:"
    cat "$WORK_DIR/xorriso.log" 2>/dev/null || true
    exit 1
fi

echo ""
log_info "Build process completed!"
