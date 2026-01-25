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
    grub

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
mkdir -p "$CHROOT_DIR"/{bin,dev,etc,lib,proc,sys,root,usr/bin,usr/sbin,usr/lib,sbin,tmp,var,opt,lib/modules,run,mnt,media}

# 复制busybox
if command -v busybox >/dev/null 2>&1; then
    cp "$(command -v busybox)" "$CHROOT_DIR/bin/"
    chmod +x "$CHROOT_DIR/bin/busybox"
    
    cd "$CHROOT_DIR"
    for applet in $(./bin/busybox --list); do
        ln -sf /bin/busybox "bin/$applet" 2>/dev/null || true
    done
    cd -
fi

# 创建init脚本
cat > "$CHROOT_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh
# Minimal init system for OpenWRT installer

/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev

/bin/busybox mknod /dev/console c 5 1
/bin/busybox mknod /dev/null c 1 3
/bin/busybox mknod /dev/zero c 1 5

exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

echo -e "\033[2J\033[H"
cat << "WELCOME"

╔═══════════════════════════════════════════════════════╗
║       OpenWRT Auto Installer System                   ║
╚═══════════════════════════════════════════════════════╝

Initializing system, please wait...
WELCOME

/bin/busybox sleep 2

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

# 配置文件
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

log_success "Minimal system created"

# ==================== 步骤6: 准备内核和initramfs ====================
log_info "[6/8] Preparing kernel and initramfs..."

# 复制内核
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

# 创建initramfs
log_info "Creating initramfs..."
mkdir -p "$WORK_DIR/initramfs"
cd "$WORK_DIR/initramfs"

mkdir -p {bin,dev,etc,lib,proc,sys,newroot,mnt,lib/modules}

# 复制busybox
if command -v busybox >/dev/null 2>&1; then
    cp "$(command -v busybox)" bin/
    chmod +x bin/busybox
    cd bin
    ./busybox --list | while read applet; do
        ln -sf busybox "$applet" 2>/dev/null || true
    done
    cd ..
fi

# 创建init脚本
cat > init << 'INITRAMFS_INIT'
#!/bin/busybox sh
# Initramfs script for OpenWRT installer

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

mknod /dev/console c 5 1
mknod /dev/null c 1 3
mknod /dev/zero c 1 5

exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

echo "================================================"
echo "    OpenWRT Installer - Booting"
echo "================================================"
echo ""

sleep 2

echo "Looking for installation media..."

# Try by label
if [ -e "/dev/disk/by-label/OPENWRT_INSTALL" ]; then
    ISO_DEVICE=$(readlink -f "/dev/disk/by-label/OPENWRT_INSTALL")
    echo "Found device by label: $ISO_DEVICE"
else
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
        
        if [ -f "/mnt/iso/live/filesystem.squashfs" ]; then
            echo "Found installer filesystem"
            mkdir -p /newroot
            
            echo "Mounting squashfs..."
            if mount -t squashfs -o loop,ro /mnt/iso/live/filesystem.squashfs /newroot; then
                echo "Squashfs mounted"
                
                mount --move /proc /newroot/proc
                mount --move /sys /newroot/sys
                mount --move /dev /newroot/dev
                
                umount /mnt/iso
                
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

echo ""
echo "================================================"
echo "    Emergency Shell"
echo "================================================"
echo ""
exec /bin/sh
INITRAMFS_INIT
chmod +x init

# 压缩initramfs
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd"
cd ..

INITRD_SIZE=$(ls -lh "$STAGING_DIR/live/initrd" | awk '{print $5}')
log_success "Created initramfs: $INITRD_SIZE"

# ==================== 步骤7: 创建squashfs ====================
log_info "[7/8] Creating squashfs..."
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

# ==================== 步骤8: 创建双引导ISO（BIOS+UEFI） ====================
log_info "[8/8] Creating dual-boot ISO (BIOS + UEFI)..."

# 创建简单的ISOLINUX配置（用于BIOS引导）
log_info "Setting up BIOS boot (ISOLINUX)..."

# 使用最简单的ISOLINUX配置，避免.c32模块问题
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

# 复制ldlinux.c32（这是必须的）
if [ -f /usr/share/syslinux/ldlinux.c32 ]; then
    cp /usr/share/syslinux/ldlinux.c32 "$STAGING_DIR/boot/isolinux/"
    # 同时复制到根目录
    cp /usr/share/syslinux/ldlinux.c32 "$STAGING_DIR/"
    log_success "Copied ldlinux.c32"
fi

# 创建GRUB配置（用于UEFI引导）
log_info "Setting up UEFI boot (GRUB)..."
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
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/tmp/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$STAGING_DIR/boot/grub/grub.cfg"
    
    # 创建EFI分区镜像
    dd if=/dev/zero of="$WORK_DIR/tmp/efiboot.img" bs=1M count=10
    mkfs.vfat -F 32 "$WORK_DIR/tmp/efiboot.img" 2>/dev/null
    
    # 创建目录并复制EFI文件
    mmd -i "$WORK_DIR/tmp/efiboot.img" ::/EFI
    mmd -i "$WORK_DIR/tmp/efiboot.img" ::/EFI/BOOT
    mcopy -i "$WORK_DIR/tmp/efiboot.img" "$WORK_DIR/tmp/bootx64.efi" ::/EFI/BOOT/bootx64.efi
    
    # 复制到最终位置
    mv "$WORK_DIR/tmp/efiboot.img" "$STAGING_DIR/EFI/boot/"
    log_success "UEFI boot image created"
else
    log_warning "grub-mkstandalone not found, UEFI boot may not work"
fi

# 构建混合ISO（同时支持BIOS和UEFI）
log_info "Building hybrid ISO (BIOS + UEFI)..."
if [ -f "$STAGING_DIR/boot/isolinux/isolinux.bin" ] && [ -f "$STAGING_DIR/boot/isolinux/ldlinux.c32" ]; then
    # 完整的hybrid ISO构建
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
    # 简化版本
    log_warning "Missing some boot files, creating simple ISO..."
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
    
    # 检查引导支持
    echo "🔧 Boot Support:"
    if [ -f "$STAGING_DIR/boot/isolinux/isolinux.bin" ]; then
        echo "  ✅ BIOS boot (ISOLINUX)"
    else
        echo "  ❌ BIOS boot not configured"
    fi
    
    if [ -f "$STAGING_DIR/EFI/boot/efiboot.img" ]; then
        echo "  ✅ UEFI boot (GRUB)"
    else
        echo "  ⚠️  UEFI boot may not work"
    fi
    echo ""
    
    echo "🎯 Boot Instructions:"
    echo "  1. BIOS systems: Will boot using ISOLINUX"
    echo "  2. UEFI systems: Will boot using GRUB"
    echo "  3. Default timeout: 10 seconds (BIOS), 5 seconds (UEFI)"
    echo ""
    
    # 创建构建信息
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO - Dual Boot (BIOS + UEFI)
================================================
Build Date:      $(date)
ISO Name:        $ISO_NAME
ISO Size:        $ISO_SIZE

Boot Support:
  - BIOS: ISOLINUX with simple text boot
  - UEFI: GRUB with menu interface
  - Hybrid ISO: Supports both BIOS and UEFI

Components:
  - Kernel:      $KERNEL_SIZE
  - Initrd:      $INITRD_SIZE
  - Filesystem:  $SQUASHFS_SIZE (gzip compression)

Boot Files:
  - BIOS: isolinux.bin, ldlinux.c32
  - UEFI: efiboot.img with GRUB EFI

Notes:
1. BIOS boot uses simple text mode (no graphical menu)
2. UEFI boot uses GRUB with 5 second timeout
3. Both methods will load the same installer system
4. ISO is hybrid - works on both legacy BIOS and UEFI systems

Test Instructions:
1. Burn to USB: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress
2. Test on BIOS system: Should show "Booting OpenWRT Installer..."
3. Test on UEFI system: Should show GRUB menu with options
EOF
    
    log_success "✅ Dual-boot ISO created successfully: $ISO_SIZE"
    
    # 清理
    cleanup
    
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
