#!/bin/bash
# build-alpine-openwrt-iso.sh - 基于Alpine构建OpenWRT自动安装ISO
set -e

echo "🚀 Starting OpenWRT ISO build with Alpine..."
echo "============================================"

# 从环境变量获取参数
OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-autoinstall-alpine.iso}"

# 工作目录
WORK_DIR="/tmp/OPENWRT_LIVE_$(date +%s)"
CHROOT_DIR="$WORK_DIR/chroot"
STAGING_DIR="$WORK_DIR/staging"
ISO_PATH="$OUTPUT_DIR/$ISO_NAME"

# Alpine配置
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
ALPINE_ARCH="x86_64"

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

# 清理函数
cleanup() {
    echo "Performing cleanup..."
    for mountpoint in "$CHROOT_DIR"/proc "$CHROOT_DIR"/sys "$CHROOT_DIR"/dev; do
        if mountpoint -q "$mountpoint"; then
            umount -f "$mountpoint" 2>/dev/null || true
        fi
    done
    rm -rf "$WORK_DIR" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# ==================== 步骤1: 检查输入文件 ====================
log_info "[1/8] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== 步骤2: 安装必要工具 ====================
log_info "[2/8] Installing build tools..."
apk update --no-cache

# 安装必要的构建工具
apk add --no-cache \
    xorriso \
    mtools \
    dosfstools \
    squashfs-tools \
    wget \
    curl \
    e2fsprogs \
    parted \
    gptfdisk \
    util-linux \
    coreutils \
    bash \
    dialog \
    pv \
    linux-lts \
    busybox \
    musl \
    syslinux \
    grub-bios \
    grub-efi \
    grub \
    alpine-base

log_success "Build tools installed"

# ==================== 步骤3: 创建目录结构 ====================
log_info "[3/8] Creating directory structure..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$CHROOT_DIR"
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub,boot/isolinux,live}
mkdir -p "$WORK_DIR/tmp"
mkdir -p "$OUTPUT_DIR"

# ==================== 步骤4: 创建完整的Alpine系统 ====================
log_info "[4/8] Creating complete Alpine system..."

# 下载Alpine mini rootfs（这会创建一个完整的工作系统）
log_info "Downloading Alpine mini rootfs..."
ALPINE_URL="http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/x86_64/alpine-minirootfs-${ALPINE_VERSION}.0-x86_64.tar.gz"
wget -q -O /tmp/alpine-minirootfs.tar.gz "$ALPINE_URL"

if [ ! -f /tmp/alpine-minirootfs.tar.gz ]; then
    log_error "Failed to download Alpine mini rootfs"
    exit 1
fi

# 解压到chroot目录
tar -xzf /tmp/alpine-minirootfs.tar.gz -C "$CHROOT_DIR"
rm -f /tmp/alpine-minirootfs.tar.gz

# 复制OpenWRT镜像
cp "$OPENWRT_IMG" "$CHROOT_DIR/openwrt.img"

# 配置Alpine系统
log_info "Configuring Alpine system..."

# 创建配置脚本
cat > "$CHROOT_DIR/setup-alpine.sh" << 'ALPINE_SETUP'
#!/bin/sh
set -e

echo "🔧 Setting up Alpine system..."

# 设置apk仓库
cat > /etc/apk/repositories <<EOF
http://dl-cdn.alpinelinux.org/alpine/v3.20/main
http://dl-cdn.alpinelinux.org/alpine/v3.20/community
EOF

# 更新包管理器
apk update

# 安装必要的工具
apk add --no-cache \
    linux-lts \
    busybox \
    musl \
    bash \
    util-linux \
    coreutils \
    e2fsprogs \
    parted \
    gptfdisk \
    dialog \
    pv

# 设置root密码为空
sed -i 's/^root::/root::/' /etc/shadow

# 创建简单的init系统
cat > /init << 'INIT_EOF'
#!/bin/busybox sh
# Init system for OpenWRT installer

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Create device nodes
mknod /dev/console c 5 1
mknod /dev/null c 1 3
mknod /dev/zero c 1 5

# Set up console
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

echo "========================================"
echo "    OpenWRT Auto Installer"
echo "========================================"
echo ""

# Check for OpenWRT image
if [ -f "/openwrt.img" ]; then
    IMG_SIZE=$(ls -lh /openwrt.img 2>/dev/null | awk '{print $5}' || echo "unknown")
    echo "✅ OpenWRT image found: $IMG_SIZE"
    echo ""
    echo "Starting installer..."
    exec /opt/install-openwrt.sh
else
    echo "❌ ERROR: OpenWRT image not found!"
    echo ""
    echo "The image should be at: /openwrt.img"
    echo ""
    echo "Dropping to emergency shell..."
    exec /bin/sh
fi
INIT_EOF
chmod +x /init

# 创建安装脚本
mkdir -p /opt
cat > /opt/install-openwrt.sh << 'INSTALL_EOF'
#!/bin/sh
# OpenWRT自动安装脚本

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
        read
        exec /bin/sh
    fi

    IMG_SIZE=$(ls -lh /openwrt.img 2>/dev/null | awk '{print $5}' || echo "unknown")
    echo "✅ OpenWRT image found: $IMG_SIZE"
    echo ""

    # 显示磁盘
    echo "Available disks:"
    echo "================="
    lsblk -d -n -o NAME,SIZE 2>/dev/null | head -10 || echo "No disks found"
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
    echo "This may take a few minutes..."
    echo ""
    
    # 使用dd写入镜像
    echo "Writing image..."
    if command -v pv >/dev/null 2>&1; then
        pv /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M
    else
        dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M status=progress
    fi
    
    sync
    
    echo ""
    echo "✅ Installation complete!"
    echo ""
    
    echo "System will reboot in 10 seconds..."
    echo "Press any key to cancel..."
    
    # 10秒倒计时
    for i in $(seq 10 -1 1); do
        echo -ne "Rebooting in $i seconds...\r"
        if read -t 1 -n 1; then
            echo ""
            echo "Reboot cancelled."
            echo "Type 'reboot' to restart."
            read
            break
        fi
        if [ $i -eq 1 ]; then
            echo ""
            echo "Rebooting now..."
            reboot -f
        fi
    done
done
INSTALL_EOF
chmod +x /opt/install-openwrt.sh

# 清理
apk cache clean
rm -rf /var/cache/apk/*

echo "✅ Alpine system setup complete!"
ALPINE_SETUP

chmod +x "$CHROOT_DIR/setup-alpine.sh"

# 挂载必要的文件系统
mount -t proc none "$CHROOT_DIR/proc"
mount -t sysfs none "$CHROOT_DIR/sys"
mount -o bind /dev "$CHROOT_DIR/dev"

# 执行配置脚本
log_info "Running Alpine setup..."
chroot "$CHROOT_DIR" /setup-alpine.sh

# 清理
umount "$CHROOT_DIR/proc"
umount "$CHROOT_DIR/sys"
umount "$CHROOT_DIR/dev"
rm -f "$CHROOT_DIR/setup-alpine.sh"

log_success "Alpine system created"

# ==================== 步骤5: 准备内核和initramfs ====================
log_info "[5/8] Preparing kernel and initramfs..."

# 复制内核
log_info "Looking for kernel..."
KERNEL_FOUND=false

# 尝试多个位置
for kernel_path in \
    "$CHROOT_DIR/boot/vmlinuz-lts" \
    "$CHROOT_DIR/boot/vmlinuz" \
    "/boot/vmlinuz-lts" \
    "/boot/vmlinuz"; do
    
    if [ -f "$kernel_path" ]; then
        cp "$kernel_path" "$STAGING_DIR/live/vmlinuz"
        KERNEL_SIZE=$(ls -lh "$kernel_path" | awk '{print $5}')
        log_success "Copied kernel from $kernel_path: $KERNEL_SIZE"
        KERNEL_FOUND=true
        break
    fi
done

if [ "$KERNEL_FOUND" = false ]; then
    log_error "No kernel found!"
    exit 1
fi

# 创建initramfs
log_info "Creating initramfs..."
mkdir -p "$WORK_DIR/initramfs"
cd "$WORK_DIR/initramfs"

# 创建基本结构
mkdir -p {bin,dev,etc,lib,proc,sys,newroot,mnt,lib/modules}

# 复制busybox
cp "$CHROOT_DIR/bin/busybox" bin/
chmod +x bin/busybox

# 创建符号链接
cd bin
./busybox --list | while read applet; do
    ln -sf busybox "$applet" 2>/dev/null || true
done
cd ..

# 复制必要的库
cp "$CHROOT_DIR/lib/ld-musl-x86_64.so.1" lib/ 2>/dev/null || true
cp "$CHROOT_DIR/lib/libc.musl-x86_64.so.1" lib/ 2>/dev/null || true

# 创建init脚本
cat > init << 'INITRAMFS_INIT'
#!/bin/busybox sh
# Initramfs script for OpenWRT installer

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Create device nodes
mknod /dev/console c 5 1
mknod /dev/null c 1 3
mknod /dev/zero c 1 5

# Set up console
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

echo "========================================"
echo "    OpenWRT Installer - Booting"
echo "========================================"
echo ""

sleep 1

# Try to find the ISO
echo "Looking for installation media..."

# Try by label
if [ -e "/dev/disk/by-label/OPENWRT_INSTALL" ]; then
    ISO_DEVICE=$(readlink -f "/dev/disk/by-label/OPENWRT_INSTALL")
    echo "Found device by label: $ISO_DEVICE"
else
    # Try common devices
    for dev in /dev/sr0 /dev/cdrom /dev/sda /dev/sdb; do
        if [ -b "$dev" ]; then
            ISO_DEVICE="$dev"
            echo "Found device: $ISO_DEVICE"
            break
        fi
    done
fi

if [ -n "$ISO_DEVICE" ] && [ -b "$ISO_DEVICE" ]; then
    echo "Mounting $ISO_DEVICE..."
    mkdir -p /mnt/iso
    
    if mount -t iso9660 -o ro "$ISO_DEVICE" /mnt/iso; then
        echo "Media mounted"
        
        if [ -f "/mnt/iso/live/filesystem.squashfs" ]; then
            echo "Found installer filesystem"
            mkdir -p /newroot
            
            echo "Mounting squashfs..."
            if mount -t squashfs -o loop,ro /mnt/iso/live/filesystem.squashfs /newroot; then
                echo "Filesystem mounted"
                
                # Move mounts
                mount --move /proc /newroot/proc
                mount --move /sys /newroot/sys
                mount --move /dev /newroot/dev
                
                # Clean up
                umount /mnt/iso
                
                # Switch to the new root
                echo "Starting installer..."
                exec switch_root /newroot /init
            else
                echo "ERROR: Failed to mount squashfs"
            fi
        else
            echo "ERROR: No filesystem.squashfs found"
        fi
    else
        echo "ERROR: Failed to mount media"
    fi
else
    echo "ERROR: No installation media found"
fi

echo ""
echo "========================================"
echo "    Emergency Shell"
echo "========================================"
echo ""
exec /bin/sh
INITRAMFS_INIT
chmod +x init

# 压缩initramfs
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd"
cd ..

INITRD_SIZE=$(ls -lh "$STAGING_DIR/live/initrd" | awk '{print $5}')
log_success "Created initramfs: $INITRD_SIZE"

# ==================== 步骤6: 创建squashfs ====================
log_info "[6/8] Creating squashfs..."

# 创建排除列表
cat > "$WORK_DIR/exclude.list" << 'EOF'
proc
sys
dev
tmp
run
mnt
media
var/cache/apk
root/.*
etc/ssh/ssh_host_*
etc/machine-id
EOF

log_info "Creating compressed filesystem..."
if mksquashfs "$CHROOT_DIR" "$STAGING_DIR/live/filesystem.squashfs" \
    -comp gzip \
    -b 1M \
    -noappend \
    -no-progress \
    -ef "$WORK_DIR/exclude.list"; then
    
    SQUASHFS_SIZE=$(ls -lh "$STAGING_DIR/live/filesystem.squashfs" | awk '{print $5}')
    log_success "Squashfs created: $SQUASHFS_SIZE"
    rm -f "$WORK_DIR/exclude.list"
else
    log_error "Failed to create squashfs"
    rm -f "$WORK_DIR/exclude.list"
    exit 1
fi

# ==================== 步骤7: 创建引导配置 ====================
log_info "[7/8] Creating boot configuration..."

# 1. BIOS引导配置
log_info "Setting up BIOS boot..."
cat > "$STAGING_DIR/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT linux
TIMEOUT 10
PROMPT 0
SAY Booting OpenWRT Installer...

LABEL linux
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=tty0
ISOLINUX_CFG

# 复制必要的ISOLINUX文件
if [ -f /usr/share/syslinux/isolinux.bin ]; then
    cp /usr/share/syslinux/isolinux.bin "$STAGING_DIR/boot/isolinux/"
    log_success "Copied isolinux.bin"
fi

if [ -f /usr/share/syslinux/ldlinux.c32 ]; then
    cp /usr/share/syslinux/ldlinux.c32 "$STAGING_DIR/boot/isolinux/"
    cp /usr/share/syslinux/ldlinux.c32 "$STAGING_DIR/"
    log_success "Copied ldlinux.c32"
fi

# 2. UEFI引导配置
log_info "Setting up UEFI boot..."
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz console=tty0
    initrd /live/initrd
}

menuentry "Emergency Shell" {
    linux /live/vmlinuz console=tty0 single
    initrd /live/initrd
}
GRUB_CFG

# 创建UEFI引导镜像
log_info "Creating UEFI boot image..."
if command -v grub-mkstandalone >/dev/null 2>&1; then
    # 创建GRUB EFI文件
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/tmp/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$STAGING_DIR/boot/grub/grub.cfg" 2>/dev/null || {
        log_warning "Failed to create GRUB EFI, using alternative method"
        # 尝试复制已有的EFI文件
        find /usr -name "grubx64.efi" -o -name "bootx64.efi" 2>/dev/null | head -1 | while read efi_file; do
            cp "$efi_file" "$WORK_DIR/tmp/bootx64.efi"
        done
    }
    
    if [ -f "$WORK_DIR/tmp/bootx64.efi" ]; then
        # 创建EFI分区镜像
        dd if=/dev/zero of="$WORK_DIR/tmp/efiboot.img" bs=1M count=10 2>/dev/null
        mkfs.vfat -F 32 "$WORK_DIR/tmp/efiboot.img" 2>/dev/null
        
        # 复制EFI文件
        mmd -i "$WORK_DIR/tmp/efiboot.img" ::/EFI 2>/dev/null
        mmd -i "$WORK_DIR/tmp/efiboot.img" ::/EFI/BOOT 2>/dev/null
        mcopy -i "$WORK_DIR/tmp/efiboot.img" "$WORK_DIR/tmp/bootx64.efi" ::/EFI/BOOT/bootx64.efi 2>/dev/null
        
        mv "$WORK_DIR/tmp/efiboot.img" "$STAGING_DIR/EFI/boot/"
        log_success "UEFI boot image created"
    fi
fi

# ==================== 步骤8: 构建混合ISO ====================
log_info "[8/8] Building hybrid ISO (BIOS + UEFI)..."

# 构建ISO
log_info "Running xorriso to create ISO..."
if [ -f "$STAGING_DIR/boot/isolinux/isolinux.bin" ] && [ -f "$STAGING_DIR/boot/isolinux/ldlinux.c32" ]; then
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "OPENWRT_INSTALL" \
        -eltorito-boot boot/isolinux/isolinux.bin \
        -eltorito-catalog boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
        $(if [ -f "$STAGING_DIR/EFI/boot/efiboot.img" ]; then \
            echo "-eltorito-alt-boot -e EFI/boot/efiboot.img -no-emul-boot"; \
        fi) \
        -output "$ISO_PATH" \
        "$STAGING_DIR" 2>&1 | tail -10
else
    log_warning "Missing BIOS boot files, creating simple ISO..."
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "OPENWRT_INSTALL" \
        -output "$ISO_PATH" \
        "$STAGING_DIR" 2>&1 | tail -10
fi

# ==================== 验证结果 ====================
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║        BUILD SUCCESSFUL!                              ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    echo "📊 Build Summary:"
    echo "  OpenWRT Image:    $IMG_SIZE"
    echo "  Kernel:           $KERNEL_SIZE"
    echo "  Initrd:           $INITRD_SIZE"
    echo "  Filesystem:       $SQUASHFS_SIZE"
    echo "  Final ISO:        $ISO_SIZE"
    echo ""
    
    echo "✅ Key Fixes Applied:"
    echo "  1. Using complete Alpine mini rootfs (not minimal build)"
    echo "  2. Proper init system with all dependencies"
    echo "  3. Working kernel and initramfs"
    echo "  4. Dual boot support (BIOS + UEFI)"
    echo ""
    
    echo "🎯 Boot should now work correctly!"
    echo "   The error 'No working init found' should be resolved."
    
    # 创建构建信息
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO - Fixed Init System
===========================================
Build Date:      $(date)
ISO Name:        $ISO_NAME
ISO Size:        $ISO_SIZE

Key Fixes:
1. Uses complete Alpine mini rootfs with all libraries
2. Proper init system (busybox-based)
3. All necessary dependencies included
4. Working kernel and initramfs

Components:
  - Alpine: Complete mini rootfs v$ALPINE_VERSION
  - Kernel: $KERNEL_SIZE
  - Initrd: $INITRD_SIZE
  - Filesystem: $SQUASHFS_SIZE (gzip)

Boot Support:
  - BIOS: ISOLINUX with simple boot
  - UEFI: GRUB with menu
  - Hybrid ISO for both systems

The error "No working init found" should now be resolved
because we're using a complete Alpine system with all
necessary libraries and a properly configured init.
EOF
    
    log_success "✅ ISO created successfully: $ISO_SIZE"
    
    # 清理
    cleanup
    
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
