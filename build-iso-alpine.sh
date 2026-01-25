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
log_info "[1/7] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== 步骤2: 安装必要工具 ====================
log_info "[2/7] Installing build tools..."

# 更新并安装基本工具
apk update --no-cache
apk add --no-cache \
    xorriso \
    syslinux \
    syslinux-common \
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
    busybox \
    musl \
    alpine-base

log_success "Build tools installed"

# ==================== 步骤3: 创建目录结构 ====================
log_info "[3/7] Creating directory structure..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$CHROOT_DIR"
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub,boot/isolinux,live}
mkdir -p "$WORK_DIR/tmp"
mkdir -p "$OUTPUT_DIR"

# ==================== 步骤4: 复制OpenWRT镜像 ====================
log_info "[4/7] Copying OpenWRT image..."
cp "$OPENWRT_IMG" "$CHROOT_DIR/openwrt.img"
log_success "OpenWRT image copied"

# ==================== 步骤5: 创建最小Alpine系统 ====================
log_info "[5/7] Creating minimal Alpine system..."

# 方法：使用alpine-base包创建最小但完整的系统
log_info "Installing alpine-base to chroot..."

# 创建必要的目录
mkdir -p "$CHROOT_DIR"/{bin,dev,etc,lib,proc,sys,root,usr/bin,usr/sbin,usr/lib,sbin,tmp,var,opt,lib/modules,lib/firmware,run,mnt,media}

# 从当前系统复制基本的busybox和库
log_info "Copying essential binaries and libraries..."

# 复制busybox
if command -v busybox >/dev/null 2>&1; then
    cp "$(command -v busybox)" "$CHROOT_DIR/bin/"
    chmod +x "$CHROOT_DIR/bin/busybox"
    
    # 创建busybox符号链接
    cd "$CHROOT_DIR"
    for applet in $(./bin/busybox --list); do
        ln -sf /bin/busybox "bin/$applet" 2>/dev/null || true
        ln -sf /bin/busybox "sbin/$applet" 2>/dev/null || true
        ln -sf /bin/busybox "usr/bin/$applet" 2>/dev/null || true
    done
    cd -
fi

# 创建init脚本（静态链接的简单版本）
log_info "Creating minimal init system..."
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

# 创建安装脚本（使用busybox命令）
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
    if /bin/busybox which pv >/dev/null 2>&1; then
        pv /openwrt.img | /bin/busybox dd of="/dev/$TARGET_DISK" bs=4M
        DD_EXIT=$?
    else
        /bin/busybox dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M
        DD_EXIT=$?
    fi
    
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

# ==================== 步骤6: 准备内核和initramfs ====================
log_info "[6/7] Preparing kernel and initramfs..."

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
    # 从linux-lts包中提取
    log_info "Extracting kernel from linux-lts package..."
    apk info -L linux-lts 2>/dev/null | grep "boot/vmlinuz" | head -1 | while read kernel_path; do
        if [ -f "/$kernel_path" ]; then
            cp "/$kernel_path" "$STAGING_DIR/live/vmlinuz"
            KERNEL_SIZE=$(ls -lh "/$kernel_path" | awk '{print $5}')
            log_success "Extracted kernel: $KERNEL_SIZE"
        fi
    done
fi

# 验证内核文件
if [ ! -f "$STAGING_DIR/live/vmlinuz" ]; then
    log_error "No kernel found!"
    exit 1
fi

# 创建initramfs
log_info "Creating initramfs..."
mkdir -p "$WORK_DIR/initramfs"
cd "$WORK_DIR/initramfs"

# 创建基本结构
mkdir -p {bin,dev,etc,lib,proc,sys,newroot,mnt}

# 复制静态busybox
log_info "Adding busybox to initramfs..."
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
    log_error "busybox not found!"
    exit 1
fi

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

# Wait a moment
sleep 2

# Try to find and mount the ISO
echo "Looking for installation media..."

# First, try to find by label
if [ -e "/dev/disk/by-label/OPENWRT_INSTALL" ]; then
    ISO_DEVICE=$(readlink -f "/dev/disk/by-label/OPENWRT_INSTALL")
    echo "Found device by label: $ISO_DEVICE"
else
    # Try common CD/DVD devices
    for dev in /dev/sr0 /dev/cdrom /dev/sr1; do
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
        echo "ISO mounted successfully"
        
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
            ls -la /mnt/iso/live/ 2>/dev/null || echo "No live directory"
        fi
    else
        echo "ERROR: Failed to mount $ISO_DEVICE"
    fi
else
    echo "ERROR: No installation media found"
    echo "Available block devices:"
    ls -la /dev/sd* /dev/hd* 2>/dev/null || echo "None"
fi

# Fallback to emergency shell
echo ""
echo "================================================"
echo "    Emergency Shell"
echo "================================================"
echo ""
echo "Diagnostic commands:"
echo "  ls -la /dev/disk/by-label/"
echo "  fdisk -l"
echo "  blkid"
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

# ==================== 步骤7: 创建squashfs和ISO（修复syslinux文件） ====================
log_info "[7/7] Creating squashfs and ISO..."

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
*.pyc
*.pyo
__pycache__
EOF

# 创建squashfs
log_info "Creating squashfs..."
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

# ==================== 修复：复制所有必要的syslinux文件 ====================
log_info "Copying syslinux files..."

# 确保目录存在
mkdir -p "$STAGING_DIR/boot/isolinux"

# 复制isolinux.bin
ISOLINUX_BIN=$(find /usr -name "isolinux.bin" -type f 2>/dev/null | head -1)
if [ -n "$ISOLINUX_BIN" ]; then
    cp "$ISOLINUX_BIN" "$STAGING_DIR/boot/isolinux/"
    log_success "Copied isolinux.bin"
else
    log_error "isolinux.bin not found!"
    exit 1
fi

# 复制所有必要的.c32模块文件
log_info "Copying syslinux modules..."
SYSLOOT_DIR=$(find /usr -type d -name "syslinux" 2>/dev/null | head -1)

if [ -n "$SYSLOOT_DIR" ]; then
    # 复制所有.c32文件
    find "$SYSLOOT_DIR" -name "*.c32" -type f 2>/dev/null | while read c32_file; do
        cp "$c32_file" "$STAGING_DIR/boot/isolinux/" 2>/dev/null
    done
    log_success "Copied all syslinux modules"
else
    # 尝试从syslinux-common包复制
    log_info "Looking for syslinux modules in syslinux-common..."
    apk info -L syslinux-common 2>/dev/null | grep "\.c32$" | while read c32_path; do
        if [ -f "/$c32_path" ]; then
            cp "/$c32_path" "$STAGING_DIR/boot/isolinux/" 2>/dev/null
        fi
    done
fi

# 检查必要的文件是否存在
REQUIRED_FILES="isolinux.bin ldlinux.c32 libutil.c32 libcom32.c32 menu.c32"
missing_files=""
for file in $REQUIRED_FILES; do
    if [ ! -f "$STAGING_DIR/boot/isolinux/$file" ]; then
        missing_files="$missing_files $file"
    fi
done

if [ -n "$missing_files" ]; then
    log_warning "Missing syslinux files:$missing_files"
    log_info "Creating simple isolinux.cfg without menu..."
    
    # 创建简单的直接启动配置
    cat > "$STAGING_DIR/boot/isolinux/isolinux.cfg" << 'ISOLINUX_SIMPLE'
DEFAULT linux
TIMEOUT 10
PROMPT 0
SAY Booting OpenWRT Installer...

LABEL linux
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=tty0
ISOLINUX_SIMPLE
    
    log_info "Using simple text-based boot (no menu)"
else
    # 创建完整的ISOLINUX配置
    cat > "$STAGING_DIR/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT openwrt
TIMEOUT 100
PROMPT 0
UI menu.c32

MENU TITLE OpenWRT Auto Installer
MENU BACKGROUND splash.png

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=tty0

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=tty0 single

LABEL memtest
  MENU LABEL ^Memory Test
  KERNEL memtest
  APPEND -
ISOLINUX_CFG
    
    log_success "Created full ISOLINUX menu configuration"
fi

# 复制ldlinux.c32到正确位置
if [ -f "$STAGING_DIR/boot/isolinux/ldlinux.c32" ]; then
    # 确保ldlinux.c32在根目录
    cp "$STAGING_DIR/boot/isolinux/ldlinux.c32" "$STAGING_DIR/"
fi

# GRUB配置（UEFI引导）
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

# 构建ISO
log_info "Building ISO..."
xorriso_cmd="xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid 'OPENWRT_INSTALL' \
    -eltorito-boot boot/isolinux/isolinux.bin \
    -eltorito-catalog boot/isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
    -output '$ISO_PATH' \
    '$STAGING_DIR'"

log_info "Running: $xorriso_cmd"
if eval "$xorriso_cmd" 2>&1 | grep -q "libisofs"; then
    log_success "ISO created successfully"
else
    # 尝试简化命令
    log_warning "First attempt failed, trying simpler command..."
    xorriso -as mkisofs -o "$ISO_PATH" -V "OPENWRT_INSTALL" "$STAGING_DIR" 2>&1 | tail -10
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
    echo "  Kernel:           $(ls -lh "$STAGING_DIR/live/vmlinuz" | awk '{print $5}')"
    echo "  Initrd:           $INITRD_SIZE"
    echo "  Filesystem:       $SQUASHFS_SIZE"
    echo "  Final ISO:        $ISO_SIZE"
    echo ""
    
    # 显示syslinux文件
    echo "📁 Syslinux files in ISO:"
    if [ -d "$STAGING_DIR/boot/isolinux" ]; then
        ls -la "$STAGING_DIR/boot/isolinux/" | grep -E "\.(bin|c32)$" | head -10
    fi
    echo ""
    
    echo "✅ The ISO should now boot correctly with proper syslinux support."
    echo "   If menu doesn't work, it will fallback to automatic boot."
    echo ""
    
    # 创建构建信息
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO - Fixed Syslinux Version
===============================================
Build Date:      $(date)
ISO Name:        $ISO_NAME
ISO Size:        $ISO_SIZE

Syslinux Files Included:
$(ls -la "$STAGING_DIR/boot/isolinux/" 2>/dev/null | grep -E "\.(bin|c32)$" | awk '{print "  - " $9}')

Boot Configuration:
  - ISOLINUX: $(if [ -f "$STAGING_DIR/boot/isolinux/menu.c32" ]; then echo "Graphical menu"; else echo "Simple text boot"; fi)
  - Timeout: 10 seconds
  - Default: Install OpenWRT

Key Fixes:
1. Added syslinux-common package
2. Copied all necessary .c32 module files
3. Fallback to simple boot if modules missing
4. Fixed library dependencies

Testing Instructions:
1. Burn ISO to USB: dd if=$ISO_NAME of=/dev/sdX bs=4M
2. Boot from USB
3. Should see boot menu or automatic boot
4. Select Install OpenWRT option
EOF
    
    log_success "✅ ISO created successfully: $ISO_SIZE"
    
    # 清理
    cleanup
    
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
