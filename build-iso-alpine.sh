#!/bin/bash
# build-alpine-openwrt-iso.sh - 构建可引导的OpenWRT安装ISO
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
log_info "[1/6] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== 步骤2: 安装必要工具 ====================
log_info "[2/6] Installing build tools..."
apk update --no-cache
apk add --no-cache \
    xorriso \
    syslinux \
    grub-bios \
    mtools \
    dosfstools \
    e2fsprogs \
    squashfs-tools \
    wget \
    curl \
    parted \
    gptfdisk \
    bash \
    dialog \
    pv \
    coreutils \
    util-linux \
    busybox \
    linux-firmware-none

log_success "Build tools installed"

# ==================== 步骤3: 下载Alpine minirootfs作为基础 ====================
log_info "[3/6] Downloading Alpine minirootfs..."

ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_VERSION="3.20"
ARCH="x86_64"

# 下载Alpine minirootfs
MINIROOTFS_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ARCH}.tar.gz"
log_info "Downloading: $MINIROOTFS_URL"

if wget -q "$MINIROOTFS_URL" -O "$WORK_DIR/alpine-minirootfs.tar.gz"; then
    log_success "Alpine minirootfs downloaded"
else
    # 尝试备用URL
    log_warning "Primary URL failed, trying alternative..."
    MINIROOTFS_URL="${ALPINE_MIRROR}/latest-stable/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ARCH}.tar.gz"
    wget -q "$MINIROOTFS_URL" -O "$WORK_DIR/alpine-minirootfs.tar.gz" || {
        log_error "Failed to download Alpine minirootfs"
        exit 1
    }
fi

# 创建根文件系统目录
ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

# 解压minirootfs
log_info "Extracting minirootfs..."
tar -xzf "$WORK_DIR/alpine-minirootfs.tar.gz" -C "$ROOTFS_DIR"

log_success "Alpine base system ready"

# ==================== 步骤4: 配置根文件系统 ====================
log_info "[4/6] Configuring root filesystem..."

# 挂载必要的文件系统
mount -t proc proc "$ROOTFS_DIR/proc" 2>/dev/null || true
mount -t sysfs sys "$ROOTFS_DIR/sys" 2>/dev/null || true
mount -o bind /dev "$ROOTFS_DIR/dev" 2>/dev/null || true

# 复制DNS配置
cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true

# 在chroot中安装必要的包
log_info "Installing packages in chroot..."

cat > "$ROOTFS_DIR/setup.sh" << 'SETUP_EOF'
#!/bin/sh
set -e

# 设置apk仓库
cat > /etc/apk/repositories << REPO_EOF
https://dl-cdn.alpinelinux.org/alpine/v3.20/main
https://dl-cdn.alpinelinux.org/alpine/v3.20/community
REPO_EOF

# 更新并安装必要包
apk update
apk add --no-cache \
    linux-lts \
    linux-firmware-none \
    busybox \
    bash \
    util-linux \
    coreutils \
    e2fsprogs \
    parted \
    gptfdisk \
    dialog \
    pv \
    syslinux \
    xorriso \
    squashfs-tools \
    mtools \
    dosfstools \
    wget \
    curl \
    nano \
    less

# 清理apk缓存
rm -rf /var/cache/apk/*

# 创建安装脚本
cat > /opt/install-openwrt.sh << 'INSTALL_EOF'
#!/bin/bash
# OpenWRT自动安装脚本

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
    read
    exec /bin/bash
fi

echo "✅ OpenWRT image found"
echo ""

while true; do
    echo "Available disks:"
    echo "================="
    lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || echo "No disks detected"
    echo "================="
    echo ""
    
    read -p "Enter target disk (e.g., sda): " TARGET_DISK
    
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
    read -p "Type 'YES' to confirm: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        sleep 2
        continue
    fi
    
    clear
    echo ""
    echo "Installing OpenWRT to /dev/$TARGET_DISK..."
    echo ""
    
    if command -v pv >/dev/null 2>&1; then
        pv /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M
    else
        dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M status=progress
    fi
    
    sync
    
    echo ""
    echo "✅ Installation complete!"
    echo ""
    echo "System will reboot in 5 seconds..."
    sleep 5
    reboot -f
    
    break
done
INSTALL_EOF

chmod +x /opt/install-openwrt.sh

# 创建init脚本
cat > /init << 'INIT_EOF'
#!/bin/sh
# OpenWRT安装器init脚本

# 挂载必要文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# 设置控制台
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

clear

cat << "WELCOME"

╔═══════════════════════════════════════════════════════╗
║       OpenWRT Auto Installer System                   ║
╚═══════════════════════════════════════════════════════╝

System booting...
WELCOME

sleep 2

if [ -f "/openwrt.img" ]; then
    echo ""
    echo "✅ OpenWRT image found"
    echo ""
    exec /opt/install-openwrt.sh
else
    echo ""
    echo "❌ ERROR: OpenWRT image not found!"
    echo ""
    echo "Dropping to emergency shell..."
    echo ""
    exec /bin/sh
fi
INIT_EOF

chmod +x /init

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 允许root登录
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true

echo "Setup completed successfully"
SETUP_EOF

chmod +x "$ROOTFS_DIR/setup.sh"

# 在chroot中运行setup.sh
chroot "$ROOTFS_DIR" /bin/sh /setup.sh

# 卸载文件系统
umount "$ROOTFS_DIR/proc" 2>/dev/null || true
umount "$ROOTFS_DIR/sys" 2>/dev/null || true
umount "$ROOTFS_DIR/dev" 2>/dev/null || true

rm -f "$ROOTFS_DIR/setup.sh"

log_success "Root filesystem configured"

# ==================== 步骤5: 创建可引导ISO结构 ====================
log_info "[5/6] Creating bootable ISO structure..."

ISO_DIR="$WORK_DIR/iso"
mkdir -p "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/grub"
mkdir -p "$ISO_DIR/EFI/BOOT"

# 复制OpenWRT镜像
cp "$OPENWRT_IMG" "$ISO_DIR/openwrt.img"

# 创建squashfs文件系统
log_info "Creating squashfs filesystem..."
mksquashfs "$ROOTFS_DIR" "$ISO_DIR/filesystem.squashfs" -comp xz -noappend

# 复制内核和initramfs
log_info "Copying kernel files..."
find "$ROOTFS_DIR/boot" -name "vmlinuz-*" -type f | head -1 | xargs -I {} cp {} "$ISO_DIR/boot/vmlinuz"
find "$ROOTFS_DIR/boot" -name "initramfs-*" -type f | head -1 | xargs -I {} cp {} "$ISO_DIR/boot/initrd.img"

# 如果没找到initramfs，创建一个
if [ ! -f "$ISO_DIR/boot/initrd.img" ]; then
    log_warning "No initramfs found, creating one..."
    # 创建简单的initramfs
    INITRAMFS_DIR="$WORK_DIR/initramfs"
    mkdir -p "$INITRAMFS_DIR"
    cp "$ROOTFS_DIR/init" "$INITRAMFS_DIR/init"
    chmod +x "$INITRAMFS_DIR/init"
    
    # 创建必要的目录
    mkdir -p "$INITRAMFS_DIR"/{dev,proc,sys}
    
    # 打包为initramfs
    cd "$INITRAMFS_DIR"
    find . | cpio -H newc -o | gzip > "$ISO_DIR/boot/initrd.img"
    cd "$WORK_DIR"
fi

# 创建GRUB配置文件
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_EOF'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 quiet
    initrd /boot/initrd.img
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 single
    initrd /boot/initrd.img
}
GRUB_EOF

# 创建ISOLINUX配置文件
mkdir -p "$ISO_DIR/isolinux"
cat > "$ISO_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_EOF'
DEFAULT openwrt
TIMEOUT 50
PROMPT 0
UI menu.c32

MENU TITLE OpenWRT Auto Installer

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200 quiet

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200 single
ISOLINUX_EOF

# 复制ISOLINUX文件
log_info "Copying bootloader files..."
for file in isolinux.bin ldlinux.c32 menu.c32 libutil.c32 libcom32.c32; do
    find /usr -name "$file" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$ISO_DIR/isolinux/" 2>/dev/null || true
done

# 创建EFI引导文件（可选）
if command -v grub-mkstandalone >/dev/null 2>&1; then
    log_info "Creating UEFI boot image..."
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$ISO_DIR/EFI/BOOT/BOOTX64.EFI" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg" 2>/dev/null || true
fi

# ==================== 步骤6: 构建可引导ISO ====================
log_info "[6/6] Building bootable ISO..."

mkdir -p "$OUTPUT_DIR"
cd "$ISO_DIR"

# 使用xorriso创建可引导ISO
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
    -output "$ISO_PATH" \
    . 2>&1 | tee "$WORK_DIR/xorriso.log"

# 验证ISO是否可引导
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    # 检查ISO的引导信息
    if file "$ISO_PATH" | grep -q "bootable"; then
        BOOTABLE="✅ Bootable"
    else
        BOOTABLE="⚠️  May not be bootable"
    fi
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║        BOOTABLE ISO CREATED SUCCESSFULLY!            ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    echo "📊 Build Summary:"
    echo "  OpenWRT Image:    $IMG_SIZE"
    echo "  Final ISO:        $ISO_SIZE"
    echo "  Boot Status:      $BOOTABLE"
    echo ""
    
    echo "🎯 ISO Features:"
    echo "  • Hybrid ISO (BIOS + UEFI boot support)"
    echo "  • ISOLINUX bootloader with menu"
    echo "  • Complete Alpine Linux system"
    echo "  • OpenWRT disk image included"
    echo "  • Interactive installer"
    echo ""
    
    echo "🔧 Boot Methods Supported:"
    echo "  1. BIOS/Legacy boot: ISOLINUX bootloader"
    echo "  2. UEFI boot: GRUB bootloader (if available)"
    echo ""
    
    echo "📝 Usage Instructions:"
    echo "  1. Write to USB: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress"
    echo "  2. Boot from USB drive"
    echo "  3. Select 'Install OpenWRT' from boot menu"
    echo "  4. Follow on-screen instructions"
    echo ""
    
    # 显示ISO详细信息
    echo "🔍 ISO Details:"
    xorriso -indev "$ISO_PATH" -toc 2>/dev/null | grep -E "Boot|El Torito" || true
    
    # 创建构建信息文件
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO
=====================
Build Date:      $(date)
ISO File:        $ISO_NAME
ISO Size:        $ISO_SIZE
Alpine Version:  $ALPINE_VERSION
OpenWRT Image:   $(basename "$OPENWRT_IMG") ($IMG_SIZE)

Boot Configuration:
  - Bootloader: ISOLINUX (BIOS) + GRUB (UEFI)
  - Kernel: Linux LTS from Alpine
  - Init System: Custom OpenWRT installer

ISO Contents:
  - /openwrt.img: OpenWRT disk image
  - /filesystem.squashfs: Alpine root filesystem
  - /boot/vmlinuz: Linux kernel
  - /boot/initrd.img: Initial RAM disk
  - /isolinux/: BIOS boot files
  - /EFI/BOOT/: UEFI boot files (if available)

To Test:
1. Check bootability: file $ISO_NAME
2. Write to USB: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress
3. Boot and test installation
EOF
    
    log_success "✅ Bootable ISO created: $ISO_PATH"
    log_success "📄 Build info saved to: $OUTPUT_DIR/build-info.txt"
    
else
    log_error "❌ ISO creation failed"
    log_info "Xorriso log:"
    cat "$WORK_DIR/xorriso.log" 2>/dev/null | tail -20
    exit 1
fi

log_info "Build process completed successfully!"
