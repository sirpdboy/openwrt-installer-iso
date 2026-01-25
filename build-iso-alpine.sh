#!/bin/bash
# build-alpine-openwrt-iso.sh - 基于Alpine构建OpenWRT自动安装ISO
set -e

echo "🚀 Starting OpenWRT ISO build with Alpine..."
echo "============================================"

# 从环境变量获取参数
OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-autoinstall-alpine.iso}"

# Alpine配置
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
ALPINE_ARCH="x86_64"
ALPINE_REPO="https://dl-cdn.alpinelinux.org/alpine"

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
apk add --no-cache \
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
    util-linux \
    coreutils \
    bash \
    dialog \
    pv \
    linux-lts \
    busybox \
    musl \
    alpine-base

log_success "Build tools installed"

# ==================== 步骤3: 创建工作目录和准备文件 ====================
log_info "[3/8] Preparing build environment..."
WORK_DIR="/tmp/OPENWRT_BUILD_$(date +%s)"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 创建ISO目录结构
mkdir -p iso/{boot/grub,boot/isolinux,EFI/boot,openwrt}

# 复制OpenWRT镜像
cp "$OPENWRT_IMG" "iso/openwrt.img"
log_success "OpenWRT image copied"

# ==================== 步骤4: 下载Alpine mini rootfs ====================
log_info "[4/8] Downloading Alpine mini rootfs..."
MINIROOTFS_URL="$ALPINE_REPO/v$ALPINE_VERSION/releases/$ALPINE_ARCH/alpine-minirootfs-$ALPINE_VERSION.0-$ALPINE_ARCH.tar.gz"
wget -q -O alpine-minirootfs.tar.gz "$MINIROOTFS_URL"

if [ ! -f "alpine-minirootfs.tar.gz" ]; then
    log_error "Failed to download Alpine mini rootfs"
    exit 1
fi

# 解压到iso目录
tar -xzf alpine-minirootfs.tar.gz -C iso/
rm -f alpine-minirootfs.tar.gz
log_success "Alpine mini rootfs extracted"

# ==================== 步骤5: 设置Alpine系统 ====================
log_info "[5/8] Setting up Alpine system..."

# 创建配置脚本
cat > iso/setup.sh << 'SETUP_EOF'
#!/bin/sh
# Alpine系统配置脚本

# 设置apk仓库
cat > /etc/apk/repositories <<EOF
$ALPINE_REPO/v3.20/main
$ALPINE_REPO/v3.20/community
EOF

# 更新包管理器
apk update

# 安装必要的包
apk add --no-cache \
    linux-lts \
    linux-firmware-none \
    busybox \
    musl \
    bash \
    util-linux \
    coreutils \
    e2fsprogs \
    parted \
    gptfdisk \
    dialog \
    pv \
    openssh-client \
    openssh-server \
    dhcpcd \
    haveged \
    wget \
    curl \
    nano \
    less

# 设置root密码为空
sed -i 's/^root::/root::/' /etc/shadow

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 允许root登录SSH
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true

# 创建init脚本
cat > /init << 'INIT_EOF'
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

echo "========================================"
echo "    OpenWRT Auto Installer"
echo "========================================"
echo ""

# 等待设备就绪
sleep 2

# 检查OpenWRT镜像
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
#!/bin/bash
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
        read
        exec /bin/bash
    fi

    IMG_SIZE=$(ls -lh /openwrt.img 2>/dev/null | awk '{print $5}' || echo "unknown")
    echo "✅ OpenWRT image found: $IMG_SIZE"
    echo ""

    # 显示磁盘
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
            echo "Type 'reboot' to restart, or press Enter to return to installer."
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

# 清理缓存
apk cache clean
rm -rf /var/cache/apk/*
SETUP_EOF

# 在chroot中运行配置脚本
log_info "Configuring Alpine system..."
mount -t proc none iso/proc
mount -t sysfs none iso/sys
mount -o bind /dev iso/dev

# 复制DNS配置
cp /etc/resolv.conf iso/etc/resolv.conf

# 执行配置脚本
chroot iso /bin/sh /setup.sh

# 清理
umount iso/proc
umount iso/sys
umount iso/dev
rm -f iso/setup.sh

log_success "Alpine system configured"

# ==================== 步骤6: 准备内核和引导文件 ====================
log_info "[6/8] Preparing kernel and boot files..."

# 复制内核文件
if [ -f "iso/boot/vmlinuz-lts" ]; then
    cp iso/boot/vmlinuz-lts iso/boot/vmlinuz
elif [ -f "/boot/vmlinuz-lts" ]; then
    cp /boot/vmlinuz-lts iso/boot/vmlinuz
else
    # 下载内核
    log_info "Downloading kernel..."
    wget -q -O iso/boot/vmlinuz "$ALPINE_REPO/v$ALPINE_VERSION/releases/$ALPINE_ARCH/boot/vmlinuz-lts"
fi

# 创建initramfs
log_info "Creating initramfs..."
mkdir -p "$WORK_DIR/initramfs"
cd "$WORK_DIR/initramfs"

mkdir -p {bin,dev,etc,lib,proc,sys,newroot,mnt,lib/modules}

# 复制busybox
cp iso/bin/busybox bin/
chmod +x bin/busybox

# 创建符号链接
cd bin
./busybox --list | while read applet; do
    ln -sf busybox "$applet" 2>/dev/null || true
done
cd ..

# 复制必要的库
cp iso/lib/ld-musl-x86_64.so.1 lib/ 2>/dev/null || true
cp iso/lib/libc.musl-x86_64.so.1 lib/ 2>/dev/null || true

# 创建init脚本
cat > init << 'INITRAMFS_INIT'
#!/bin/busybox sh
# Initramfs脚本

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

echo "========================================"
echo "    OpenWRT Installer - Booting"
echo "========================================"
echo ""

sleep 1

# 查找安装介质
echo "Looking for installation media..."

# 尝试按标签查找
if [ -e "/dev/disk/by-label/OPENWRT_INSTALL" ]; then
    ISO_DEVICE=$(readlink -f "/dev/disk/by-label/OPENWRT_INSTALL")
    echo "Found device by label: $ISO_DEVICE"
else
    # 尝试常见设备
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
        
        if [ -f "/mnt/iso/openwrt.img" ]; then
            echo "Found OpenWRT image"
            mkdir -p /newroot
            
            # 复制文件系统到新的root
            echo "Setting up root filesystem..."
            cp -a /mnt/iso/* /newroot/ 2>/dev/null || true
            
            # 移动挂载点
            mount --move /proc /newroot/proc
            mount --move /sys /newroot/sys
            mount --move /dev /newroot/dev
            
            # 清理
            umount /mnt/iso
            
            # 切换到新的root
            echo "Starting installer..."
            exec switch_root /newroot /init
        else
            echo "ERROR: No OpenWRT image found"
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
find . | cpio -o -H newc 2>/dev/null | gzip -9 > iso/boot/initrd
cd "$WORK_DIR"

log_success "Kernel and initramfs prepared"

# ==================== 步骤7: 创建引导配置 ====================
log_info "[7/8] Creating boot configuration..."

# 1. BIOS引导配置 (ISOLINUX)
cat > iso/boot/isolinux/isolinux.cfg << 'ISOLINUX_CFG'
DEFAULT linux
TIMEOUT 10
PROMPT 0
SAY Booting OpenWRT Installer...

LABEL linux
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd console=tty0
ISOLINUX_CFG

# 复制ISOLINUX文件
if [ -f /usr/share/syslinux/isolinux.bin ]; then
    cp /usr/share/syslinux/isolinux.bin iso/boot/isolinux/
    log_success "Copied isolinux.bin"
fi

if [ -f /usr/share/syslinux/ldlinux.c32 ]; then
    cp /usr/share/syslinux/ldlinux.c32 iso/boot/isolinux/
    cp /usr/share/syslinux/ldlinux.c32 iso/
    log_success "Copied ldlinux.c32"
fi

# 2. UEFI引导配置 (GRUB)
cat > iso/boot/grub/grub.cfg << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz console=tty0
    initrd /boot/initrd
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz console=tty0 single
    initrd /boot/initrd
}
GRUB_CFG

# 创建UEFI引导镜像
log_info "Creating UEFI boot image..."
if command -v grub-mkstandalone >/dev/null 2>&1; then
    # 创建GRUB EFI文件
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=iso/boot/grub/grub.cfg"
    
    if [ -f "$WORK_DIR/bootx64.efi" ]; then
        # 创建EFI分区镜像
        dd if=/dev/zero of="$WORK_DIR/efiboot.img" bs=1M count=10
        mkfs.vfat -F 32 "$WORK_DIR/efiboot.img" 2>/dev/null
        
        # 复制EFI文件
        mmd -i "$WORK_DIR/efiboot.img" ::/EFI 2>/dev/null
        mmd -i "$WORK_DIR/efiboot.img" ::/EFI/BOOT 2>/dev/null
        mcopy -i "$WORK_DIR/efiboot.img" "$WORK_DIR/bootx64.efi" ::/EFI/BOOT/bootx64.efi 2>/dev/null
        
        mv "$WORK_DIR/efiboot.img" iso/EFI/boot/
        log_success "UEFI boot image created"
    fi
fi

# ==================== 步骤8: 构建混合ISO ====================
log_info "[8/8] Building hybrid ISO (BIOS + UEFI)..."

# 进入iso目录构建
cd iso

# 构建ISO
if [ -f "boot/isolinux/isolinux.bin" ] && [ -f "boot/isolinux/ldlinux.c32" ]; then
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
        $(if [ -f "EFI/boot/efiboot.img" ]; then \
            echo "-eltorito-alt-boot -e EFI/boot/efiboot.img -no-emul-boot"; \
        fi) \
        -output "$ISO_PATH" \
        . 2>&1 | tail -10
else
    # 简化版本
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "OPENWRT_INSTALL" \
        -output "$ISO_PATH" \
        . 2>&1 | tail -10
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
    echo "  Final ISO:        $ISO_SIZE"
    echo "  Alpine Version:   $ALPINE_VERSION"
    echo ""
    
    echo "✅ Build Method: Direct Alpine mini rootfs"
    echo "   Simplified and reliable build process."
    echo ""
    
    echo "🔧 Boot Support:"
    if [ -f "boot/isolinux/isolinux.bin" ]; then
        echo "  ✅ BIOS boot (ISOLINUX)"
    else
        echo "  ⚠️  BIOS boot may not work"
    fi
    
    if [ -f "EFI/boot/efiboot.img" ]; then
        echo "  ✅ UEFI boot (GRUB)"
    else
        echo "  ⚠️  UEFI boot may not work"
    fi
    echo ""
    
    echo "🎯 Features:"
    echo "  1. Complete Alpine mini rootfs"
    echo "  2. Working init system"
    echo "  3. OpenWRT image included"
    echo "  4. Automatic installer"
    echo "  5. Emergency shell"
    echo ""
    
    # 创建构建信息
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO - Simple Alpine Build
============================================
Build Date:      $(date)
ISO Name:        $ISO_NAME
ISO Size:        $ISO_SIZE
Alpine Version:  $ALPINE_VERSION

Build Process:
1. Downloaded Alpine mini rootfs
2. Configured Alpine system in chroot
3. Created custom initramfs
4. Added OpenWRT image
5. Built hybrid ISO with BIOS+UEFI support

System Components:
  - Alpine mini rootfs v$ALPINE_VERSION
  - Linux kernel: $(ls -lh iso/boot/vmlinuz 2>/dev/null | awk '{print $5}' || echo "unknown")
  - Initrd: $(ls -lh iso/boot/initrd 2>/dev/null | awk '{print $5}' || echo "unknown")
  - OpenWRT image: $IMG_SIZE

Boot Configuration:
  - BIOS: Simple ISOLINUX boot
  - UEFI: GRUB boot (if available)
  - Volume ID: OPENWRT_INSTALL
  - Default: Automatic boot to installer

Advantages:
1. No complex mkimage dependency
2. Simple and reliable
3. All necessary components included
4. Works on most systems

Usage:
1. Burn to USB: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress
2. Boot from USB
3. System will automatically start installer
4. Follow on-screen instructions
EOF
    
    log_success "✅ ISO created successfully: $ISO_SIZE"
    log_success "📁 Output: $ISO_PATH"
    
    # 清理
    cleanup
    
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
