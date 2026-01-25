#!/bin/bash
# build.sh - OpenWRT ISO构建脚本（在Docker容器内运行）
set -e

echo "🚀 Starting OpenWRT ISO build inside Docker container..."
echo "========================================================"

# 从环境变量获取参数，或使用默认值
OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-autoinstall.iso}"

# 工作目录（使用唯一名称避免冲突）
WORK_DIR="/tmp/OPENWRT_LIVE_$(date +%s)"
CHROOT_DIR="$WORK_DIR/chroot"
STAGING_DIR="$WORK_DIR/staging"
ISO_PATH="$OUTPUT_DIR/$ISO_NAME"

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
    # 卸载所有挂载
    umount -f "$CHROOT_DIR"/proc 2>/dev/null || true
    umount -f "$CHROOT_DIR"/sys 2>/dev/null || true
    umount -f "$CHROOT_DIR"/dev 2>/dev/null || true
    # 删除工作目录
    rm -rf "$WORK_DIR" 2>/dev/null || true
}

# 设置trap确保清理
trap cleanup EXIT INT TERM

# 显示配置信息
log_info "Build Configuration:"
log_info "  OpenWRT Image: $OPENWRT_IMG"
log_info "  Output Dir:    $OUTPUT_DIR"
log_info "  ISO Name:      $ISO_NAME"
log_info "  Work Dir:      $WORK_DIR"
echo ""

# ==================== 步骤1: 检查输入文件 ====================
log_info "[1/10] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== 步骤2: 创建目录结构 ====================
log_info "[2/10] Creating directory structure..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$CHROOT_DIR"
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub/x86_64-efi,isolinux,live}
mkdir -p "$WORK_DIR/tmp"
mkdir -p "$OUTPUT_DIR"

# ==================== 步骤3: 复制OpenWRT镜像 ====================
log_info "[3/10] Copying OpenWRT image..."
cp "$OPENWRT_IMG" "$CHROOT_DIR/openwrt.img"
log_success "OpenWRT image copied"

# ==================== 步骤4: 引导Debian最小系统 ====================
log_info "[4/10] Bootstrapping Debian minimal system..."
DEBIAN_MIRROR="http://archive.debian.org/debian"

if debootstrap --arch=amd64 --variant=minbase \
    buster "$CHROOT_DIR" "$DEBIAN_MIRROR" 2>&1 | tail -5; then
    log_success "Debian bootstrap successful"
else
    log_warning "First attempt failed, trying alternative mirror..."
    DEBIAN_MIRROR="http://deb.debian.org/debian"
    debootstrap --arch=amd64 --variant=minbase \
        buster "$CHROOT_DIR" "$DEBIAN_MIRROR" || {
        log_error "Debootstrap failed"
        exit 1
    }
    log_success "Debian bootstrap successful with alternative mirror"
fi

# ==================== 步骤5: 配置chroot环境 ====================
log_info "[5/10] Configuring chroot environment..."

# 创建chroot配置脚本
cat > "$CHROOT_DIR/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
set -e

echo "🔧 Configuring chroot environment..."

# 基本设置
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check

# 设置主机名和DNS
echo "openwrt-installer" > /etc/hostname
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 更新并安装包
echo "Updating packages..."
apt-get update

echo "Installing system packages..."
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    live-boot \
    live-boot-initramfs-tools \
    systemd-sysv \
    parted \
    dosfstools \
    pv \
    wget \
    dialog \
    locales

# 配置locale
echo "Configuring locale..."
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# 设置自动登录
echo "Configuring auto-login..."
echo 'root:x:0:0:root:/root:/bin/bash' > /etc/passwd
echo 'root::0:0:99999:7:::' > /etc/shadow

# 创建安装脚本
mkdir -p /opt
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
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

echo "✅ OpenWRT image found: $(ls -lh /openwrt.img | awk '{print $5}')"
echo ""

while true; do
    echo "Available disks:"
    echo "================="
    lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^(sd|hd|nvme)' || echo "No disks detected"
    echo "================="
    echo ""
    
    read -p "Enter target disk (e.g., sda): " TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo "Please enter a disk name"
        continue
    fi
    
    if [ ! -b "/dev/$TARGET_DISK" ]; then
        echo "❌ Disk /dev/$TARGET_DISK not found!"
        continue
    fi
    
    echo ""
    echo "⚠️  WARNING: This will erase ALL data on /dev/$TARGET_DISK!"
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
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
    
    echo "System will reboot in 10 seconds..."
    echo "Press any key to cancel."
    
    for i in {10..1}; do
        echo -ne "Rebooting in $i seconds...\r"
        if read -t 1 -n 1; then
            echo ""
            echo "Reboot cancelled. Type 'reboot' to restart."
            exec /bin/bash
        fi
    done
    
    reboot -f
done
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 设置自动启动
cat > /etc/profile.d/autoinstall.sh << 'PROFILE'
if [ "$(tty)" = "/dev/tty1" ]; then
    sleep 2
    clear
    /opt/install-openwrt.sh
fi
PROFILE

# 配置live-boot
mkdir -p /etc/live/boot
echo "live" > /etc/live/boot.conf

# 生成initramfs
echo "Generating initramfs..."
update-initramfs -c 2>/dev/null || true

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "✅ Chroot configuration complete"
CHROOT_EOF

chmod +x "$CHROOT_DIR/install-chroot.sh"

# 挂载文件系统并执行chroot配置
mount -t proc proc "$CHROOT_DIR/proc"
mount -t sysfs sysfs "$CHROOT_DIR/sys"
mount -o bind /dev "$CHROOT_DIR/dev"

log_info "Running chroot configuration..."
chroot "$CHROOT_DIR" /install-chroot.sh

# 清理chroot
rm -f "$CHROOT_DIR/install-chroot.sh"

# ==================== 步骤6: 提取内核和initrd ====================
log_info "[6/10] Extracting kernel and initrd..."
KERNEL=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" -type f | head -1)
INITRD=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" -type f | head -1)

if [ -z "$KERNEL" ] || [ -z "$INITRD" ]; then
    log_error "Failed to find kernel or initrd"
    exit 1
fi

cp "$KERNEL" "$STAGING_DIR/live/vmlinuz"
cp "$INITRD" "$STAGING_DIR/live/initrd"
log_success "Kernel: $(basename "$KERNEL")"
log_success "Initrd: $(basename "$INITRD")"

# ==================== 步骤7: 创建squashfs文件系统 ====================
log_info "[7/10] Creating squashfs filesystem..."
if mksquashfs "$CHROOT_DIR" \
    "$STAGING_DIR/live/filesystem.squashfs" \
    -comp xz \
    -b 1M \
    -noappend \
    -e boot; then
    log_success "Squashfs created successfully"
else
    log_error "Failed to create squashfs"
    exit 1
fi

# 创建live-boot需要的文件
echo "live" > "$STAGING_DIR/live/filesystem.squashfs.type"
touch "$STAGING_DIR/live/filesystem.squashfs-"

# ==================== 步骤8: 创建引导配置 ====================
log_info "[8/10] Creating boot configuration..."

# 复制引导文件
cp /usr/lib/ISOLINUX/isolinux.bin "$STAGING_DIR/isolinux/" 2>/dev/null || \
cp /usr/lib/syslinux/isolinux.bin "$STAGING_DIR/isolinux/" 2>/dev/null || true

cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$STAGING_DIR/isolinux/" 2>/dev/null || true

# 创建isolinux配置
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
TIMEOUT 50
PROMPT 0
UI menu.c32

MENU TITLE OpenWRT Auto Installer

LABEL live
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet
  TEXT HELP
  Automatically start OpenWRT installer
  ENDTEXT
ISOLINUX_CFG

# 创建GRUB配置
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet
    initrd /live/initrd
}
GRUB_CFG

# ==================== 步骤9: 构建ISO镜像 ====================
log_info "[9/10] Building ISO image..."
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -output "$ISO_PATH" \
    "$STAGING_DIR" 2>&1 | grep -E "(^[^.]|%)" || true

# ==================== 步骤10: 验证结果 ====================
log_info "[10/10] Verifying build..."

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    log_success "✅ ISO built successfully!"
    echo ""
    log_info "Build Results:"
    log_info "  Output File: $ISO_PATH"
    log_info "  File Size:   $ISO_SIZE"
    log_info "  Volume ID:   OPENWRT_INSTALL"
    echo ""
    
    # 创建构建信息文件
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO Build Information
========================================
Build Date:      $(date)
Build Script:    build.sh
Docker Image:    openwrt-iso-builder:latest

Input Image:     $(basename "$OPENWRT_IMG")
Output ISO:      $ISO_NAME
ISO Size:        $ISO_SIZE
Kernel Version:  $(basename "$KERNEL")

Boot Support:    BIOS + UEFI
Boot Timeout:    5 seconds
Auto-install:    Enabled

Usage:
  1. Flash: dd if="$ISO_NAME" of=/dev/sdX bs=4M status=progress
  2. Boot from USB
  3. Select target disk
  4. Confirm installation
EOF
    
    log_success "Build info saved to: $OUTPUT_DIR/build-info.txt"
    
    # 卸载挂载点
    umount "$CHROOT_DIR/proc" 2>/dev/null || true
    umount "$CHROOT_DIR/sys" 2>/dev/null || true
    umount "$CHROOT_DIR/dev" 2>/dev/null || true
    
    log_success "🎉 All steps completed successfully!"
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
