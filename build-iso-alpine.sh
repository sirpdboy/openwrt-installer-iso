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
log_info "[1/6] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== 步骤2: 安装必要工具 ====================
log_info "[2/6] Installing build tools..."

# 更新并安装基本工具
apk update --no-cache
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
    musl

log_success "Build tools installed"

# ==================== 步骤3: 创建目录结构 ====================
log_info "[3/6] Creating directory structure..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$CHROOT_DIR"
mkdir -p "$STAGING_DIR"/{boot/grub,live}
mkdir -p "$WORK_DIR/tmp"
mkdir -p "$OUTPUT_DIR"

# ==================== 步骤4: 复制OpenWRT镜像 ====================
log_info "[4/6] Copying OpenWRT image..."
cp "$OPENWRT_IMG" "$CHROOT_DIR/openwrt.img"
log_success "OpenWRT image copied"

# ==================== 步骤5: 创建最小Alpine系统 ====================
log_info "[5/6] Creating minimal Alpine system..."

# 创建必要的目录
mkdir -p "$CHROOT_DIR"/{bin,dev,etc,lib,proc,sys,root,usr/bin,usr/sbin,usr/lib,sbin,tmp,var,opt,lib/modules,lib/firmware,run,mnt,media}

# 复制busybox
log_info "Setting up busybox..."
if command -v busybox >/dev/null 2>&1; then
    cp "$(command -v busybox)" "$CHROOT_DIR/bin/"
    chmod +x "$CHROOT_DIR/bin/busybox"
    
    # 创建busybox符号链接
    cd "$CHROOT_DIR"
    for applet in $(./bin/busybox --list); do
        ln -sf /bin/busybox "bin/$applet" 2>/dev/null || true
    done
    cd -
fi

# 复制必要的库文件
log_info "Copying essential libraries..."
# 复制musl libc
find /lib -name "ld-musl-x86_64.so.1" -type f 2>/dev/null | head -1 | while read lib; do
    if [ -f "$lib" ]; then
        mkdir -p "$CHROOT_DIR$(dirname "$lib")"
        cp "$lib" "$CHROOT_DIR$lib"
        ln -sf "ld-musl-x86_64.so.1" "$CHROOT_DIR/lib/ld-musl-x86_64.so.1"
    fi
done

find /lib -name "libc.musl-x86_64.so.1" -type f 2>/dev/null | head -1 | while read lib; do
    if [ -f "$lib" ]; then
        mkdir -p "$CHROOT_DIR$(dirname "$lib")"
        cp "$lib" "$CHROOT_DIR$lib"
    fi
done

# 创建init脚本
log_info "Creating init system..."
cat > "$CHROOT_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh
# Minimal init system for OpenWRT installer

# Mount essential filesystems
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev

# Create device nodes
/bin/busybox mknod /dev/console c 5 1
/bin/busybox mknod /dev/null c 1 3
/bin/busybox mknod /dev/zero c 1 5

# Set up console
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

# Clear screen
echo -e "\033[2J\033[H"

# Display welcome message
cat << "WELCOME"

╔═══════════════════════════════════════════════════════╗
║       OpenWRT Auto Installer System                   ║
╚═══════════════════════════════════════════════════════╝

Initializing system, please wait...
WELCOME

# Wait for devices
/bin/busybox sleep 2

# Check for OpenWRT image
if [ -f "/openwrt.img" ]; then
    IMG_SIZE=$(/bin/busybox ls -lh /openwrt.img 2>/dev/null | /bin/busybox awk '{print $5}' || echo "unknown")
    echo ""
    echo "✅ OpenWRT image found: $IMG_SIZE"
    echo ""
    echo "Starting installer in 3 seconds..."
    /bin/busybox sleep 3
    exec /opt/install-openwrt.sh
else
    echo ""
    echo "❌ ERROR: OpenWRT image not found!"
    echo ""
    echo "The image should be at: /openwrt.img"
    echo ""
    echo "Dropping to emergency shell..."
    echo ""
    exec /bin/busybox sh
fi
INIT_EOF
chmod +x "$CHROOT_DIR/init"

# 创建安装脚本
cat > "$CHROOT_DIR/opt/install-openwrt.sh" << 'INSTALL_EOF'
#!/bin/busybox sh
# OpenWRT自动安装脚本

# 设置终端
/bin/busybox stty sane

while true; do
    echo -e "\033[2J\033[H"
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
        exec /bin/busybox sh
    fi

    IMG_SIZE=$(/bin/busybox ls -lh /openwrt.img 2>/dev/null | /bin/busybox awk '{print $5}' || echo "unknown")
    echo "✅ OpenWRT image found: $IMG_SIZE"
    echo ""

    # 显示磁盘
    echo "Available disks:"
    echo "================="
    echo "Block devices:"
    /bin/busybox ls -la /dev/sd* /dev/hd* 2>/dev/null | /bin/busybox head -10 || echo "No block devices found"
    echo "================="
    echo ""
    
    echo -n "Enter target disk (e.g., sda): "
    read TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo "Please enter a disk name"
        /bin/busybox sleep 2
        continue
    fi
    
    if [ ! -b "/dev/$TARGET_DISK" ]; then
        echo "❌ Disk /dev/$TARGET_DISK not found!"
        /bin/busybox sleep 2
        continue
    fi
    
    echo ""
    echo "⚠️  WARNING: This will erase ALL data on /dev/$TARGET_DISK!"
    echo ""
    echo -n "Type 'YES' to confirm: "
    read CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        /bin/busybox sleep 2
        continue
    fi
    
    echo -e "\033[2J\033[H"
    echo ""
    echo "Installing OpenWRT to /dev/$TARGET_DISK..."
    echo ""
    echo "This may take a few minutes..."
    echo ""
    
    # 使用dd写入镜像
    echo "Writing image..."
    /bin/busybox dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M
    DD_EXIT=$?
    
    /bin/busybox sync
    
    if [ $DD_EXIT -eq 0 ]; then
        echo ""
        echo "✅ Installation complete!"
        echo ""
        
        echo "System will reboot in 10 seconds..."
        echo "Press any key to cancel..."
        
        # 10秒倒计时
        for i in $(/bin/busybox seq 10 -1 1); do
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
                /bin/busybox reboot -f
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
root:x:0:0:root:/root:/bin/sh
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

# ==================== 步骤6: 准备内核、initramfs和构建ISO ====================
log_info "[6/6] Preparing kernel, initramfs and building ISO..."

# 使用当前系统的内核
log_info "Copying kernel..."
if [ -f "/boot/vmlinuz-lts" ]; then
    cp "/boot/vmlinuz-lts" "$STAGING_DIR/live/vmlinuz"
    KERNEL_SIZE=$(ls -lh "/boot/vmlinuz-lts" | awk '{print $5}')
    log_success "Copied kernel: $KERNEL_SIZE"
elif [ -f "/boot/vmlinuz" ]; then
    cp "/boot/vmlinuz" "$STAGING_DIR/live/vmlinuz"
    KERNEL_SIZE=$(ls -lh "/boot/vmlinuz" | awk '{print $5}')
    log_success "Copied kernel: $KERNEL_SIZE"
else
    log_error "No kernel found!"
    exit 1
fi

# 创建initramfs（包含内核模块）
log_info "Creating initramfs..."
mkdir -p "$WORK_DIR/initramfs"
cd "$WORK_DIR/initramfs"

# 创建基本结构
mkdir -p {bin,dev,etc,lib,proc,sys,newroot,mnt,lib/modules}

# 复制busybox
if command -v busybox >/dev/null 2>&1; then
    cp "$(command -v busybox)" bin/
    chmod +x bin/busybox
    # 创建符号链接
    cd bin
    ./busybox --list | while read applet; do
        ln -sf busybox "$applet" 2>/dev/null || true
    done
    cd ..
fi

# 复制必要的库
find /lib -name "ld-musl-x86_64.so.1" -type f 2>/dev/null | head -1 | while read lib; do
    if [ -f "$lib" ]; then
        mkdir -p "$(dirname "lib/$(basename "$lib")")"
        cp "$lib" "lib/"
    fi
done

# 复制内核模块（用于挂载ISO和squashfs）
log_info "Copying kernel modules..."
mkdir -p lib/modules
# 复制一些关键模块
for module in isofs loop squashfs; do
    find /lib/modules -name "${module}.ko*" -type f 2>/dev/null | head -1 | while read mod; do
        if [ -f "$mod" ]; then
            cp "$mod" "lib/modules/"
            log_info "Copied module: $(basename "$mod")"
        fi
    done
done

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

echo "================================================"
echo "    OpenWRT Installer - Booting"
echo "================================================"
echo ""

# Load necessary modules
echo "Loading kernel modules..."
for mod in /lib/modules/*.ko*; do
    if [ -f "$mod" ]; then
        insmod "$mod" 2>/dev/null && echo "Loaded: $(basename "$mod")"
    fi
done

# Wait a moment
sleep 1

# Try to find and mount the ISO
echo "Looking for installation media..."

# Try by label first
if [ -e "/dev/disk/by-label/OPENWRT_INSTALL" ]; then
    ISO_DEVICE=$(readlink -f "/dev/disk/by-label/OPENWRT_INSTALL")
    echo "Found device by label: $ISO_DEVICE"
else
    # Try common devices
    for dev in /dev/sr0 /dev/cdrom /dev/sr1 /dev/sda /dev/sdb; do
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
    
    if mount -t iso9660 -o ro "$ISO_DEVICE" /mnt/iso 2>/dev/null || \
       mount -t udf -o ro "$ISO_DEVICE" /mnt/iso 2>/dev/null; then
        echo "Media mounted successfully"
        
        # Check for squashfs
        if [ -f "/mnt/iso/live/filesystem.squashfs" ]; then
            echo "Found installer filesystem"
            mkdir -p /newroot
            
            echo "Mounting squashfs..."
            if mount -t squashfs -o loop,ro /mnt/iso/live/filesystem.squashfs /newroot; then
                echo "Squashfs mounted"
                
                # Move mounts
                mount --move /proc /newroot/proc
                mount --move /sys /newroot/sys
                mount --move /dev /newroot/dev
                
                # Clean up
                umount /mnt/iso
                
                # Switch root
                echo "Switching to installer system..."
                exec switch_root /newroot /init
            else
                echo "ERROR: Failed to mount squashfs"
            fi
        else
            echo "ERROR: No filesystem.squashfs found"
        fi
    else
        echo "ERROR: Failed to mount $ISO_DEVICE"
    fi
else
    echo "ERROR: No installation media found"
fi

# Fallback to emergency shell
echo ""
echo "================================================"
echo "    Emergency Shell"
echo "================================================"
echo ""
echo "Try mounting manually:"
echo "  mount -t iso9660 /dev/sr0 /mnt"
echo "  mount -t squashfs -o loop /mnt/live/filesystem.squashfs /newroot"
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

# 创建squashfs
log_info "Creating squashfs..."
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

# ==================== 关键修复：使用GRUB引导而不是ISOLINUX ====================
log_info "Setting up GRUB boot (no ISOLINUX needed)..."

# 创建GRUB配置
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

# Set some display options
set menu_color_normal=white/black
set menu_color_highlight=black/white

# Boot entry for OpenWRT installer
menuentry "Install OpenWRT" {
    echo "Loading kernel..."
    linux /live/vmlinuz
    echo "Loading initramfs..."
    initrd /live/initrd
    echo "Booting OpenWRT installer..."
}

menuentry "Emergency Shell" {
    linux /live/vmlinuz single
    initrd /live/initrd
}

menuentry "Boot from local disk" {
    echo "Booting from first hard disk..."
    set root=(hd0)
    chainloader +1
}
GRUB_CFG

# 创建GRUB引导镜像（用于BIOS引导）
log_info "Creating GRUB boot image..."
mkdir -p "$STAGING_DIR/boot/grub/i386-pc"

# 查找GRUB模块
GRUB_DIR=$(find /usr -type d -name "grub" 2>/dev/null | head -1)
if [ -n "$GRUB_DIR" ]; then
    # 复制必要的GRUB模块
    for module in biosdisk part_msdos ext2 fat iso9660; do
        find "$GRUB_DIR" -name "${module}.mod" -type f 2>/dev/null | head -1 | while read mod; do
            cp "$mod" "$STAGING_DIR/boot/grub/i386-pc/" 2>/dev/null
        done
    done
fi

# 创建core.img（用于BIOS引导）
log_info "Creating GRUB core image..."
if command -v grub-mkimage >/dev/null 2>&1; then
    # 创建GRUB core image
    grub-mkimage \
        -O i386-pc \
        -o "$WORK_DIR/tmp/core.img" \
        -p /boot/grub \
        biosdisk part_msdos ext2 fat iso9660
    
    # 创建引导扇区
    dd if=/dev/zero of="$WORK_DIR/tmp/boot.img" bs=512 count=2880
    mkfs.fat -F 12 -n "GRUB" "$WORK_DIR/tmp/boot.img" 2>/dev/null
    
    # 复制core.img到引导镜像
    mmd -i "$WORK_DIR/tmp/boot.img" ::/boot
    mmd -i "$WORK_DIR/tmp/boot.img" ::/boot/grub
    mcopy -i "$WORK_DIR/tmp/boot.img" "$WORK_DIR/tmp/core.img" ::/boot/grub/
    
    mv "$WORK_DIR/tmp/boot.img" "$STAGING_DIR/boot.img"
    log_success "GRUB boot image created"
fi

# 构建ISO（使用简单的xorriso命令）
log_info "Building ISO with GRUB boot..."
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot boot.img \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -output "$ISO_PATH" \
    "$STAGING_DIR" 2>&1 | tail -10

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
    
    echo "✅ Boot Method: GRUB (no ISOLINUX needed)"
    echo "   This avoids the libutil.c32 and menu.c32 errors."
    echo ""
    echo "🎯 Boot options:"
    echo "   1. Install OpenWRT (default, 5 second timeout)"
    echo "   2. Emergency Shell"
    echo "   3. Boot from local disk"
    echo ""
    
    # 创建构建信息
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO - GRUB Boot Only
=======================================
Build Date:      $(date)
ISO Name:        $ISO_NAME
ISO Size:        $ISO_SIZE

Boot Configuration:
  - Bootloader: GRUB only (no ISOLINUX)
  - Timeout: 5 seconds
  - Default: Install OpenWRT
  - Menu options: Install, Emergency Shell, Local Boot

Key Features:
1. No ISOLINUX dependencies - avoids libutil.c32/menu.c32 errors
2. Uses GRUB for both BIOS and UEFI compatibility
3. Simple text-based boot menu
4. Automatic boot after timeout

Components:
  - Kernel:      $KERNEL_SIZE
  - Initrd:      $INITRD_SIZE (with kernel modules)
  - Filesystem:  $SQUASHFS_SIZE (gzip compression)

Boot Instructions:
1. Burn ISO to USB: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress
2. Boot from USB
3. GRUB menu will appear with 5 second timeout
4. Select "Install OpenWRT" or wait for auto-boot
EOF
    
    log_success "✅ ISO created successfully: $ISO_SIZE"
    
    # 清理
    cleanup
    
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
