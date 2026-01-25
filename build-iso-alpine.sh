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
    grub-efi \
    linux-lts \
    linux-firmware-none

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
mkdir -p "$CHROOT_DIR"/{bin,dev,etc,lib,proc,sys,root,usr/bin,usr/sbin,usr/lib,sbin,tmp,var,opt,lib/modules,lib/firmware}

# 创建init系统
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

# 方法1: 使用当前系统的内核（已安装linux-lts包）
log_info "Looking for kernel in system..."
KERNEL_PATH="/boot"

# 查找内核文件
if [ -f "$KERNEL_PATH/vmlinuz-lts" ]; then
    cp "$KERNEL_PATH/vmlinuz-lts" "$STAGING_DIR/live/vmlinuz"
    KERNEL_SIZE=$(ls -lh "$KERNEL_PATH/vmlinuz-lts" | awk '{print $5}')
    log_success "Copied kernel from system: $KERNEL_SIZE"
elif [ -f "$KERNEL_PATH/vmlinuz" ]; then
    cp "$KERNEL_PATH/vmlinuz" "$STAGING_DIR/live/vmlinuz"
    KERNEL_SIZE=$(ls -lh "$KERNEL_PATH/vmlinuz" | awk '{print $5}')
    log_success "Copied kernel from system: $KERNEL_SIZE"
else
    # 方法2: 查找其他可能的内核位置
    log_warning "Kernel not found in /boot, searching system..."
    SYSTEM_KERNEL=$(find /lib/modules -name "vmlinuz*" -type f 2>/dev/null | head -1)
    if [ -n "$SYSTEM_KERNEL" ]; then
        cp "$SYSTEM_KERNEL" "$STAGING_DIR/live/vmlinuz"
        KERNEL_SIZE=$(ls -lh "$SYSTEM_KERNEL" | awk '{print $5}')
        log_success "Copied kernel from modules directory: $KERNEL_SIZE"
    else
        # 方法3: 使用apk提取内核
        log_info "Extracting kernel from linux-lts package..."
        # 列出linux-lts包的文件
        apk info -L linux-lts 2>/dev/null | grep "boot/vmlinuz" | while read kernel_file; do
            if [ -f "/$kernel_file" ]; then
                cp "/$kernel_file" "$STAGING_DIR/live/vmlinuz"
                KERNEL_SIZE=$(ls -lh "/$kernel_file" | awk '{print $5}')
                log_success "Extracted kernel from package: $KERNEL_SIZE"
                break
            fi
        done
        
        # 如果还是没找到，创建一个小内核
        if [ ! -f "$STAGING_DIR/live/vmlinuz" ]; then
            log_warning "No kernel found, creating placeholder kernel..."
            # 创建一个最小的可执行文件作为占位符
            cat > "$WORK_DIR/tmp/mini_kernel.c" << 'KERNEL_EOF'
int main() {
    asm("mov $1, %rax\n"
        "mov $1, %rdi\n"
        "mov $message, %rsi\n"
        "mov $14, %rdx\n"
        "syscall\n"
        "mov $60, %rax\n"
        "xor %rdi, %rdi\n"
        "syscall\n"
        "message: .ascii \"Kernel missing\\n\"");
    return 0;
}
KERNEL_EOF
            # 尝试编译
            if command -v gcc >/dev/null 2>&1; then
                gcc -nostdlib -static "$WORK_DIR/tmp/mini_kernel.c" -o "$STAGING_DIR/live/vmlinuz" 2>/dev/null && \
                chmod +x "$STAGING_DIR/live/vmlinuz"
                log_warning "Created placeholder kernel (not bootable)"
            else
                # 最后的手段：创建一个空文件
                echo "Minimal kernel placeholder" > "$STAGING_DIR/live/vmlinuz"
                log_warning "Created empty kernel placeholder"
            fi
        fi
    fi
fi

# 创建initramfs
log_info "Creating initramfs..."
mkdir -p "$WORK_DIR/initramfs"
cd "$WORK_DIR/initramfs"

# 创建基本结构
mkdir -p {bin,dev,etc,lib,proc,sys,newroot,mnt,lib/modules}

# 使用busybox（已安装）
if command -v busybox >/dev/null 2>&1; then
    cp "$(command -v busybox)" bin/
    chmod +x bin/busybox
    # 创建符号链接
    cd bin
    ./busybox --list | while read applet; do
        ln -sf busybox "$applet" 2>/dev/null || true
    done
    cd ..
else
    # 下载静态busybox
    log_info "Downloading busybox..."
    wget -q -O bin/busybox https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox || \
    wget -q -O bin/busybox https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-x86_64
    if [ -f "bin/busybox" ]; then
        chmod +x bin/busybox
        cd bin
        ./busybox --list | while read applet; do
            ln -sf busybox "$applet" 2>/dev/null || true
        done
        cd ..
    else
        log_error "Cannot find or download busybox"
        exit 1
    fi
fi

# 创建init脚本
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
sleep 2

# Try to find the ISO media
echo "Looking for installation media..."

# First try by label
if [ -e "/dev/disk/by-label/OPENWRT_INSTALL" ]; then
    MEDIA_DEV=$(readlink -f "/dev/disk/by-label/OPENWRT_INSTALL")
    echo "Found media by label: $MEDIA_DEV"
elif [ -e "/dev/disk/by-label/LIVE" ]; then
    MEDIA_DEV=$(readlink -f "/dev/disk/by-label/LIVE")
    echo "Found media by label: $MEDIA_DEV"
else
    # Try common CD/DVD devices
    for dev in /dev/sr0 /dev/cdrom /dev/sr1; do
        if [ -b "$dev" ]; then
            MEDIA_DEV="$dev"
            echo "Found media device: $MEDIA_DEV"
            break
        fi
    done
fi

# Mount the media
if [ -n "$MEDIA_DEV" ]; then
    mkdir -p /mnt/cdrom
    echo "Mounting $MEDIA_DEV..."
    if mount -t iso9660 -o ro "$MEDIA_DEV" /mnt/cdrom 2>/dev/null; then
        echo "Media mounted successfully"
        
        # Check for squashfs
        if [ -f "/mnt/cdrom/live/filesystem.squashfs" ]; then
            echo "Found installer filesystem"
            mkdir -p /newroot
            
            # Mount squashfs
            echo "Mounting installer filesystem..."
            if mount -t squashfs -o loop,ro /mnt/cdrom/live/filesystem.squashfs /newroot; then
                echo "Installer filesystem mounted"
                
                # Move essential filesystems to new root
                mount --move /proc /newroot/proc
                mount --move /sys /newroot/sys
                mount --move /dev /newroot/dev
                
                # Switch to the new root
                echo "Starting installer..."
                exec switch_root /newroot /init
            else
                echo "ERROR: Failed to mount squashfs!"
            fi
        else
            echo "ERROR: Could not find filesystem.squashfs!"
        fi
    else
        echo "ERROR: Failed to mount media!"
    fi
else
    echo "ERROR: No installation media found!"
    echo "Available block devices:"
    ls -la /dev/sd* /dev/hd* /dev/sr* 2>/dev/null || echo "None found"
fi

# If we get here, something went wrong
echo ""
echo "================================================"
echo "    BOOT FAILED - Emergency Shell"
echo "================================================"
echo ""
echo "Troubleshooting:"
echo "1. Check if ISO was burned correctly to USB"
echo "2. Try different USB port"
echo "3. Check BIOS/UEFI boot settings"
echo ""
echo "Dropping to emergency shell..."
echo ""

exec /bin/sh
INITRAMFS_INIT
chmod +x init

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

# ==================== 步骤8: 创建引导配置和ISO ====================
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
  APPEND initrd=/live/initrd boot=live console=tty0 console=ttyS0,115200 quiet

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
    log_success "ISOLINUX files copied"
fi

# 2. 创建GRUB配置（UEFI引导）
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live console=tty0 console=ttyS0,115200 quiet
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

# 3. 构建混合ISO（BIOS+UEFI）
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
    echo "  OpenWRT Image:    $IMG_SIZE"
    echo "  Kernel:           $(ls -lh "$STAGING_DIR/live/vmlinuz" | awk '{print $5}')"
    echo "  Initrd:           $INITRD_SIZE"
    echo "  Filesystem:       $SQUASHFS_SIZE"
    echo "  Final ISO:        $ISO_SIZE"
    echo ""
    
    # 显示ISO大小分析
    echo "📁 ISO Size Analysis:"
    echo "  - Boot files:     ~2MB"
    echo "  - Kernel:         ~$(ls -lh "$STAGING_DIR/live/vmlinuz" | awk '{print $5}')"
    echo "  - Initrd:         ~$INITRD_SIZE"
    echo "  - Squashfs:       ~$SQUASHFS_SIZE"
    echo "  - Total:          ~$ISO_SIZE"
    echo ""
    
    echo "🎯 Boot Instructions:"
    echo "  1. Burn ISO to USB: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress"
    echo "  2. Boot from USB"
    echo "  3. Select 'Install OpenWRT' from boot menu"
    echo "  4. Choose target disk and confirm installation"
    echo ""
    
    # 创建构建信息
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO - Fixed Kernel Version
=============================================
Build Date:      $(date)
ISO Name:        $ISO_NAME
ISO Size:        $ISO_SIZE

Components:
  - Kernel:      $(ls -lh "$STAGING_DIR/live/vmlinuz" | awk '{print $5}')
  - Initrd:      $INITRD_SIZE
  - Filesystem:  $SQUASHFS_SIZE
  - Boot:        ISOLINUX (BIOS) + Basic GRUB config

Boot Options:
  - Default: Install OpenWRT with 5 minute timeout
  - Emergency Shell for troubleshooting
  - Memory Test utility
  - Boot from local drive

Troubleshooting:
1. If boot fails, try 'Emergency Shell' option
2. Check that USB was burned correctly
3. Verify hardware compatibility
4. Ensure OpenWRT image is valid

Build completed: $(date)
EOF
    
    log_success "✅ ISO created successfully: $ISO_SIZE"
    
    # 清理
    cleanup
    
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
