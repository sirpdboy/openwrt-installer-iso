#!/bin/bash
# build-alpine-openwrt-iso.sh - 基于Alpine构建OpenWRT自动安装ISO
set -e

echo "🚀 Starting OpenWRT ISO build with Alpine..."
echo "============================================"

# 从环境变量获取参数
OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-autoinstall-alpine.iso}"

# 工作目录（使用唯一名称避免冲突）
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
    # 卸载所有挂载
    for mountpoint in "$CHROOT_DIR"/proc "$CHROOT_DIR"/sys "$CHROOT_DIR"/dev; do
        if mountpoint -q "$mountpoint"; then
            umount -f "$mountpoint" 2>/dev/null || true
        fi
    done
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
log_info "  Alpine Version: $ALPINE_VERSION"
log_info "  Work Dir:      $WORK_DIR"
echo ""

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

# 更新并安装基本工具
apk update --no-cache
apk add --no-cache \
    xorriso \
    syslinux \
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
    grub-bios \
    grub-efi

log_success "Build tools installed"

# ==================== 步骤3: 创建目录结构 ====================
log_info "[3/8] Creating directory structure..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$CHROOT_DIR"
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub,boot/isolinux,live}
mkdir -p "$WORK_DIR/tmp"
mkdir -p "$OUTPUT_DIR"

# ==================== 步骤4: 复制OpenWRT镜像 ====================
log_info "[4/8] Copying OpenWRT image..."
cp "$OPENWRT_IMG" "$CHROOT_DIR/openwrt.img"
log_success "OpenWRT image copied"

# ==================== 步骤5: 创建最小Alpine系统 ====================
log_info "[5/8] Creating minimal Alpine system..."

# 创建一个最小的文件系统结构
mkdir -p "$CHROOT_DIR"/{bin,dev,etc,lib,proc,sys,root,usr/bin,usr/sbin,usr/lib,sbin,tmp,var,opt,lib/modules}

# 创建init系统（使用简单的bash脚本）
cat > "$CHROOT_DIR/init" << 'INIT_EOF'
#!/bin/bash
# Minimal init system for OpenWRT installer

# 设置终端
export TERM=linux
stty sane

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Create device nodes
mknod /dev/console c 5 1 2>/dev/null
mknod /dev/null c 1 3 2>/dev/null
mknod /dev/zero c 1 5 2>/dev/null
mknod /dev/random c 1 8 2>/dev/null
mknod /dev/urandom c 1 9 2>/dev/null

# Set up console
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# Clear screen
clear

# Display welcome message
cat << "WELCOME"

╔═══════════════════════════════════════════════════════╗
║       OpenWRT Auto Installer System                   ║
╚═══════════════════════════════════════════════════════╝

Initializing system, please wait...
WELCOME

# Wait for devices
sleep 2

# Check for OpenWRT image
if [ -f "/openwrt.img" ]; then
    IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}' 2>/dev/null || echo "unknown")
    echo ""
    echo "✅ OpenWRT image found: $IMG_SIZE"
    echo ""
    echo "Starting installer in 3 seconds..."
    sleep 3
    exec /opt/install-openwrt.sh
else
    echo ""
    echo "❌ ERROR: OpenWRT image not found!"
    echo ""
    echo "The image should be at: /openwrt.img"
    echo ""
    echo "Dropping to emergency shell..."
    echo ""
    exec /bin/bash
fi
INIT_EOF
chmod +x "$CHROOT_DIR/init"

# 创建安装脚本
mkdir -p "$CHROOT_DIR/opt"
cat > "$CHROOT_DIR/opt/install-openwrt.sh" << 'INSTALL_EOF'
#!/bin/bash
# OpenWRT自动安装脚本

# 设置终端
export TERM=linux
stty sane

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
    # Try multiple methods to list disks
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || echo "No disks found via lsblk"
    fi
    
    if command -v fdisk >/dev/null 2>&1; then
        echo ""
        echo "Disk list (fdisk):"
        fdisk -l 2>/dev/null | grep -E "^Disk /dev/" | head -10 || echo "Cannot list disks via fdisk"
    fi
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
        DD_EXIT=$?
    else
        dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M status=progress 2>/dev/null
        DD_EXIT=$?
    fi
    
    sync
    
    if [ $DD_EXIT -eq 0 ]; then
        echo ""
        echo "✅ Installation complete!"
        echo ""
        
        echo "System will reboot in 10 seconds..."
        echo "Press any key to cancel..."
        
        # 10秒倒计时，检测按键
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
    else
        echo ""
        echo "❌ Installation failed with error code: $DD_EXIT"
        echo "Please check the disk and try again."
        echo ""
        echo "Press Enter to continue..."
        read
    fi
done
INSTALL_EOF
chmod +x "$CHROOT_DIR/opt/install-openwrt.sh"

# 创建必要的配置文件
cat > "$CHROOT_DIR/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/bash
EOF

cat > "$CHROOT_DIR/etc/group" << 'EOF'
root:x:0:
EOF

cat > "$CHROOT_DIR/etc/shadow" << 'EOF'
root::0:0:99999:7:::
EOF

cat > "$CHROOT_DIR/etc/fstab" << 'EOF'
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
devtmpfs /dev devtmpfs defaults 0 0
tmpfs /tmp tmpfs defaults 0 0
EOF

cat > "$CHROOT_DIR/etc/hostname" << 'EOF'
openwrt-installer
EOF

log_success "Minimal system created"

# ==================== 步骤6: 准备内核和initramfs ====================
log_info "[6/8] Preparing kernel and initramfs..."

# 使用宿主系统的内核
if [ -f "/boot/vmlinuz" ]; then
    cp "/boot/vmlinuz" "$STAGING_DIR/live/vmlinuz"
    KERNEL_SIZE=$(ls -lh "/boot/vmlinuz" | awk '{print $5}')
    log_success "Copied kernel from host: $KERNEL_SIZE"
else
    # 从Alpine镜像下载最小内核
    log_warning "Downloading minimal kernel..."
    KERNEL_URL="http://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/boot/vmlinuz-lts"
    if wget -q -O "$STAGING_DIR/live/vmlinuz" "$KERNEL_URL"; then
        KERNEL_SIZE=$(ls -lh "$STAGING_DIR/live/vmlinuz" | awk '{print $5}')
        log_success "Downloaded kernel: $KERNEL_SIZE"
    else
        log_error "Cannot find or download kernel!"
        exit 1
    fi
fi

# 创建正确的initramfs（能够挂载squashfs）
log_info "Creating initramfs..."
mkdir -p "$WORK_DIR/initramfs"
cd "$WORK_DIR/initramfs"

# 创建基本结构
mkdir -p {bin,dev,etc,lib,proc,sys,newroot,mnt,lib/modules}

# 下载静态busybox
log_info "Downloading busybox..."
wget -q -O bin/busybox https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
chmod +x bin/busybox

# 创建busybox符号链接
cd bin
./busybox --list | while read applet; do
    ln -sf busybox "$applet" 2>/dev/null || true
done
cd ..

# 创建正确的init脚本
cat > init << 'INITRAMFS_INIT'
#!/bin/busybox sh
# Initramfs script for OpenWRT installer

# Export PATH
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Create device nodes
mknod /dev/console c 5 1
mknod /dev/null c 1 3
mknod /dev/zero c 1 5

# Load essential modules for CD/DVD and filesystems
echo "Loading kernel modules..."
insmod /lib/modules/isofs.ko 2>/dev/null
insmod /lib/modules/loop.ko 2>/dev/null
insmod /lib/modules/squashfs.ko 2>/dev/null
insmod /lib/modules/af_alg.ko 2>/dev/null
insmod /lib/modules/algif_hash.ko 2>/dev/null
insmod /lib/modules/algif_skcipher.ko 2>/dev/null
insmod /lib/modules/crc32c_generic.ko 2>/dev/null
insmod /lib/modules/crypto_simd.ko 2>/dev/null
insmod /lib/modules/cryptd.ko 2>/dev/null
insmod /lib/modules/libcrc32c.ko 2>/dev/null
insmod /lib/modules/xz_dec.ko 2>/dev/null

# Set up console
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

echo "================================================"
echo "    OpenWRT Installer - Booting"
echo "================================================"
echo ""

# Wait for devices to settle
echo "Waiting for storage devices..."
sleep 3

# Try to mount the CD/DVD
echo "Looking for installation media..."
for dev in /dev/sr0 /dev/cdrom /dev/sr1; do
    if [ -b "$dev" ]; then
        echo "Found device: $dev"
        mkdir -p /mnt/cdrom
        if mount -t iso9660 -o ro "$dev" /mnt/cdrom 2>/dev/null; then
            echo "Mounted installation media"
            break
        fi
    fi
done

# Also try mounting by-label
if ! mountpoint -q /mnt/cdrom; then
    for label in OPENWRT_INSTALL LIVE; do
        if [ -e "/dev/disk/by-label/$label" ]; then
            dev=$(readlink -f "/dev/disk/by-label/$label")
            echo "Found device by label '$label': $dev"
            mkdir -p /mnt/cdrom
            if mount -t iso9660 -o ro "$dev" /mnt/cdrom 2>/dev/null; then
                echo "Mounted by label: $label"
                break
            fi
        fi
    done
fi

# Check if we mounted successfully
if mountpoint -q /mnt/cdrom; then
    echo ""
    echo "Found installer files:"
    ls -la /mnt/cdrom/ 2>/dev/null | head -10
    echo ""
    
    # Check for squashfs file
    if [ -f "/mnt/cdrom/live/filesystem.squashfs" ]; then
        echo "Mounting installer filesystem..."
        mkdir -p /newroot
        if mount -t squashfs -o loop,ro /mnt/cdrom/live/filesystem.squashfs /newroot; then
            echo "Installer filesystem mounted successfully"
            
            # Move essential filesystems to new root
            mount --move /proc /newroot/proc
            mount --move /sys /newroot/sys
            mount --move /dev /newroot/dev
            
            # Switch to the new root
            echo "Switching to installer system..."
            exec switch_root /newroot /init
        else
            echo "ERROR: Failed to mount squashfs!"
        fi
    else
        echo "ERROR: Could not find filesystem.squashfs!"
        echo "Files in /mnt/cdrom/live/:"
        ls -la /mnt/cdrom/live/ 2>/dev/null || echo "No live directory found"
    fi
else
    echo "ERROR: Could not mount installation media!"
    echo "Available block devices:"
    ls -la /dev/sd* /dev/hd* /dev/sr* 2>/dev/null || true
fi

# If we get here, something went wrong
echo ""
echo "================================================"
echo "    BOOT FAILED - Emergency Shell"
echo "================================================"
echo ""
echo "Troubleshooting steps:"
echo "1. Check if the ISO was burned correctly"
echo "2. Try booting with 'toram' parameter"
echo "3. Check hardware compatibility"
echo ""
echo "Dropping to emergency shell..."
echo ""

exec /bin/sh
INITRAMFS_INIT
chmod +x init

# 下载必要的内核模块（简化版）
log_info "Downloading kernel modules..."
mkdir -p lib/modules
# 下载一些关键模块
wget -q -O lib/modules/isofs.ko "https://raw.githubusercontent.com/torvalds/linux/master/fs/isofs/isofs.ko" 2>/dev/null || true
wget -q -O lib/modules/loop.ko "https://raw.githubusercontent.com/torvalds/linux/master/drivers/block/loop.ko" 2>/dev/null || true
wget -q -O lib/modules/squashfs.ko "https://raw.githubusercontent.com/torvalds/linux/master/fs/squashfs/squashfs.ko" 2>/dev/null || true

# 创建压缩的initramfs
echo "Compressing initramfs..."
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd"
cd ..

INITRD_SIZE=$(ls -lh "$STAGING_DIR/live/initrd" | awk '{print $5}')
log_success "Created initramfs: $INITRD_SIZE"

# ==================== 步骤7: 创建高度压缩的squashfs ====================
log_info "[7/8] Creating compressed squashfs..."

# 创建排除列表
cat > "$WORK_DIR/exclude.list" << 'EOF'
proc
sys
dev
tmp
run
mnt
media
var
root/.*
*.ko
*.o
*.a
EOF

# 使用xz压缩
log_info "Creating squashfs with xz compression..."
if mksquashfs "$CHROOT_DIR" "$STAGING_DIR/live/filesystem.squashfs" \
    -comp xz \
    -Xdict-size 512K \
    -b 1M \
    -noappend \
    -no-progress \
    -no-recovery \
    -ef "$WORK_DIR/exclude.list" 2>&1; then
    
    SQUASHFS_SIZE=$(ls -lh "$STAGING_DIR/live/filesystem.squashfs" | awk '{print $5}')
    log_success "✅ Squashfs created: $SQUASHFS_SIZE"
    rm -f "$WORK_DIR/exclude.list"
else
    log_warning "XZ compression failed, trying gzip..."
    if mksquashfs "$CHROOT_DIR" "$STAGING_DIR/live/filesystem.squashfs" \
        -comp gzip \
        -b 1M \
        -noappend \
        -no-progress \
        -ef "$WORK_DIR/exclude.list"; then
        SQUASHFS_SIZE=$(ls -lh "$STAGING_DIR/live/filesystem.squashfs" | awk '{print $5}')
        log_success "Squashfs created with gzip: $SQUASHFS_SIZE"
        rm -f "$WORK_DIR/exclude.list"
    else
        log_error "Failed to create squashfs"
        rm -f "$WORK_DIR/exclude.list"
        exit 1
    fi
fi

# 创建live-boot标识文件
echo "live" > "$STAGING_DIR/live/filesystem.squashfs.type"

# ==================== 步骤8: 创建正确的引导配置和ISO ====================
log_info "[8/8] Creating boot configuration and ISO..."

# 1. 创建ISOLINUX配置（BIOS引导）
cat > "$STAGING_DIR/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT openwrt
TIMEOUT 300
PROMPT 1
UI menu.c32

MENU TITLE OpenWRT Auto Installer
MENU BACKGROUND splash.png

LABEL openwrt
  MENU LABEL ^Install OpenWRT (Default)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live console=tty0 console=ttyS0,115200 quiet splash

LABEL openwrt_toram
  MENU LABEL Install OpenWRT (^Copy to RAM)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live console=tty0 console=ttyS0,115200 quiet splash toram

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live console=tty0 console=ttyS0,115200 single

LABEL memtest
  MENU LABEL ^Memory Test
  KERNEL memtest
  APPEND -

MENU SEPARATOR

LABEL local
  MENU LABEL Boot from ^Local Drive
  LOCALBOOT 0
ISOLINUX_CFG

# 复制ISOLINUX文件
if [ -f /usr/share/syslinux/isolinux.bin ]; then
    cp /usr/share/syslinux/isolinux.bin "$STAGING_DIR/boot/isolinux/"
    cp /usr/share/syslinux/vesamenu.c32 "$STAGING_DIR/boot/isolinux/"
    cp /usr/share/syslinux/menu.c32 "$STAGING_DIR/boot/isolinux/"
    cp /usr/share/syslinux/libutil.c32 "$STAGING_DIR/boot/isolinux/"
    cp /usr/share/syslinux/libcom32.c32 "$STAGING_DIR/boot/isolinux/"
    cp /usr/share/syslinux/ldlinux.c32 "$STAGING_DIR/boot/isolinux/"
    cp /usr/share/syslinux/chain.c32 "$STAGING_DIR/boot/isolinux/"
    log_success "ISOLINUX files copied"
fi

# 2. 创建GRUB配置（UEFI引导） - 修复后的配置
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

if loadfont /boot/grub/fonts/unicode.pf2 ; then
    set gfxmode=auto
    insmod efi_gop
    insmod efi_uga
    insmod gfxterm
    terminal_output gfxterm
fi

set menu_color_normal=white/black
set menu_color_highlight=black/white

menuentry "Install OpenWRT (Default)" {
    linux /live/vmlinuz boot=live console=tty0 console=ttyS0,115200 quiet splash
    initrd /live/initrd
}

menuentry "Install OpenWRT (Copy to RAM)" {
    linux /live/vmlinuz boot=live console=tty0 console=ttyS0,115200 quiet splash toram
    initrd /live/initrd
}

menuentry "Emergency Shell" {
    linux /live/vmlinuz boot=live console=tty0 console=ttyS0,115200 single
    initrd /live/initrd
}

menuentry "Boot from local drive" {
    chainloader (hd0)+1
}
GRUB_CFG

# 创建GRUB字体目录
mkdir -p "$STAGING_DIR/boot/grub/fonts"
if [ -f /usr/share/grub/unicode.pf2 ]; then
    cp /usr/share/grub/unicode.pf2 "$STAGING_DIR/boot/grub/fonts/"
fi

# 3. 创建UEFI引导文件
log_info "Creating UEFI boot files..."
if command -v grub-mkstandalone >/dev/null 2>&1; then
    # 创建GRUB EFI镜像
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/tmp/grubx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$STAGING_DIR/boot/grub/grub.cfg"
    
    # 创建EFI分区镜像
    EFI_SIZE=16M
    dd if=/dev/zero of="$STAGING_DIR/EFI/boot/efiboot.img" bs=1 count=0 seek=$EFI_SIZE
    mkfs.vfat -F 32 -n "UEFI_BOOT" "$STAGING_DIR/EFI/boot/efiboot.img" 2>/dev/null
    
    # 复制EFI文件
    mmd -i "$STAGING_DIR/EFI/boot/efiboot.img" ::/EFI 2>/dev/null
    mmd -i "$STAGING_DIR/EFI/boot/efiboot.img" ::/EFI/BOOT 2>/dev/null
    mcopy -i "$STAGING_DIR/EFI/boot/efiboot.img" "$WORK_DIR/tmp/grubx64.efi" ::/EFI/BOOT/BOOTX64.EFI 2>/dev/null
    log_success "UEFI boot files created"
fi

# 4. 构建混合ISO（BIOS+UEFI）
log_info "Building hybrid ISO (BIOS+UEFI)..."

# 创建ISO
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot boot/isolinux/isolinux.bin \
    -eltorito-catalog boot/isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/boot/efiboot.img \
    -no-emul-boot \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
    -output "$ISO_PATH" \
    "$STAGING_DIR" 2>&1 | grep -E "(libisofs|Percentage|done)" | tail -10

# ==================== 验证结果 ====================
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║        BUILD SUCCESSFUL!                              ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    echo "📊 Build Summary:"
    echo "  Kernel:           $(ls -lh "$STAGING_DIR/live/vmlinuz" | awk '{print $5}')"
    echo "  Initrd:           $INITRD_SIZE"
    echo "  Filesystem:       $SQUASHFS_SIZE"
    echo "  Final ISO:        $ISO_SIZE"
    echo ""
    
    echo "🎯 Boot Options:"
    echo "  • BIOS (ISOLINUX): Install OpenWRT, Emergency Shell"
    echo "  • UEFI (GRUB):     Install OpenWRT, Emergency Shell"
    echo "  • Timeout:         30 seconds (BIOS), 10 seconds (UEFI)"
    echo ""
    
    echo "✅ The ISO should now boot correctly in both BIOS and UEFI mode."
    echo "   Select 'Install OpenWRT' from the boot menu."
    
    # 创建构建信息
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO - Fixed Boot Version
===========================================
Build Date:      $(date)
ISO Name:        $ISO_NAME
ISO Size:        $ISO_SIZE

Boot Configuration:
  - BIOS: ISOLINUX with 30s timeout
  - UEFI: GRUB with 10s timeout
  - Default option: Install OpenWRT
  - Additional: Copy to RAM, Emergency Shell

Kernel Parameters:
  boot=live - Enables live boot system
  console=tty0 - Primary console
  console=ttyS0,115200 - Serial console
  quiet splash - Quiet boot with splash
  toram - Copy system to RAM (optional)

Troubleshooting:
1. If boot hangs, try 'Emergency Shell' option
2. For slow media, use 'Copy to RAM' option
3. Check that initrd contains squashfs modules
4. Ensure ISO is properly burned to USB

Build completed: $(date)
EOF
    
    log_success "✅ ISO created successfully: $ISO_SIZE"
    
    # 清理
    cleanup
    
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
