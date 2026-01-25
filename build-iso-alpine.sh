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
log_info "[1/9] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== 步骤2: 安装必要工具 ====================
log_info "[2/9] Installing build tools..."

# 更新并安装基本工具
apk update --no-cache
apk add --no-cache \
    alpine-sdk \
    xorriso \
    syslinux \
    mtools \
    dosfstools \
    squashfs-tools \
    wget \
    curl \
    e2fsprogs \
    e2fsprogs-extra \
    parted \
    gptfdisk \
    util-linux \
    coreutils \
    bash \
    sudo \
    dialog \
    pv

log_success "Build tools installed"

# ==================== 步骤3: 创建目录结构 ====================
log_info "[3/9] Creating directory structure..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$CHROOT_DIR"
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub,boot/isolinux,live}
mkdir -p "$WORK_DIR/tmp"
mkdir -p "$OUTPUT_DIR"

# ==================== 步骤4: 复制OpenWRT镜像 ====================
log_info "[4/9] Copying OpenWRT image..."
cp "$OPENWRT_IMG" "$CHROOT_DIR/openwrt.img"
log_success "OpenWRT image copied"

# ==================== 步骤5: 下载Alpine mini rootfs ====================
log_info "[5/9] Downloading Alpine mini rootfs..."

# 直接使用已知可用的镜像源下载mini rootfs
MIRROR="http://dl-cdn.alpinelinux.org/alpine"
MINIROOTFS_URL="$MIRROR/v$ALPINE_VERSION/releases/$ALPINE_ARCH/alpine-minirootfs-$ALPINE_VERSION.0-$ALPINE_ARCH.tar.gz"

log_info "Downloading from: $MINIROOTFS_URL"

# 下载mini rootfs
if wget -O /tmp/alpine-minirootfs.tar.gz "$MINIROOTFS_URL"; then
    log_success "Downloaded Alpine mini rootfs"
    
    # 验证文件
    if tar -tzf /tmp/alpine-minirootfs.tar.gz >/dev/null 2>&1; then
        log_success "File verification passed"
    else
        log_error "Downloaded file is corrupted"
        exit 1
    fi
else
    # 尝试备用URL（不带版本号的）
    log_warning "First attempt failed, trying alternative URL..."
    ALT_URL="$MIRROR/latest-stable/releases/$ALPINE_ARCH/alpine-minirootfs-latest-$ALPINE_ARCH.tar.gz"
    if wget -O /tmp/alpine-minirootfs.tar.gz "$ALT_URL"; then
        log_success "Downloaded from alternative URL"
    else
        log_error "Failed to download Alpine mini rootfs"
        exit 1
    fi
fi

# 解压到chroot目录
tar -xzf /tmp/alpine-minirootfs.tar.gz -C "$CHROOT_DIR"
rm -f /tmp/alpine-minirootfs.tar.gz

# ==================== 步骤6: 配置Alpine chroot环境 ====================
log_info "[6/9] Configuring Alpine chroot environment..."

# 创建配置脚本
cat > "$CHROOT_DIR/setup-alpine.sh" << 'ALPINE_EOF'
#!/bin/sh
set -e

echo "🔧 Setting up Alpine environment..."

# 设置apk仓库（正确的格式）
cat > /etc/apk/repositories <<EOF
http://dl-cdn.alpinelinux.org/alpine/v3.20/main
http://dl-cdn.alpinelinux.org/alpine/v3.20/community
EOF

# 更新包数据库
echo "Updating package database..."
apk update --no-cache

# 安装最小必要包
echo "Installing essential packages..."
apk add --no-cache \
    linux-lts \
    openrc \
    eudev \
    util-linux \
    bash \
    busybox \
    parted \
    gptfdisk \
    e2fsprogs \
    dosfstools \
    syslinux \
    grub-bios \
    grub-efi \
    xorriso \
    curl \
    wget \
    dialog \
    pv \
    nano \
    less \
    openssh \
    openssh-server \
    dhcpcd \
    haveged

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 设置时区
echo "UTC" > /etc/timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# 设置DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 设置root无密码登录
sed -i 's/^root:!:/root::/' /etc/shadow

# 启用基本服务
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit
rc-update add hwclock boot
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add syslog boot
rc-update add networking boot
rc-update add sshd default
rc-update add haveged default
rc-update add dhcpcd default

# 配置网络
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# 允许root通过SSH登录
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# 创建自动启动脚本
mkdir -p /etc/local.d
cat > /etc/local.d/autoinstall.start <<'START_SCRIPT'
#!/bin/sh
# Auto-start installer script

# 等待系统就绪
sleep 5

# 检查是否在tty1
if [ "$(tty)" = "/dev/tty1" ]; then
    # 清屏并显示欢迎信息
    clear
    cat << "EOF"

╔═══════════════════════════════════════════════════════╗
║       OpenWRT Auto Install System (Alpine)            ║
╚═══════════════════════════════════════════════════════╝

System is starting up, please wait...
EOF
    
    sleep 3
    
    # 检查OpenWRT镜像
    if [ ! -f "/openwrt.img" ]; then
        clear
        echo ""
        echo "❌ Error: OpenWRT image not found"
        echo ""
        echo "Image file should be at: /openwrt.img"
        echo ""
        echo "Press Enter to enter shell..."
        read _
        exec /bin/sh
    fi
    
    # 启动安装程序
    echo "Starting OpenWRT installer..."
    exec /opt/install-openwrt.sh
fi
START_SCRIPT

chmod +x /etc/local.d/autoinstall.start
rc-update add local default

# 创建安装脚本
mkdir -p /opt
cat > /opt/install-openwrt.sh <<'INSTALL_SCRIPT'
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
        read _
        exec /bin/sh
    fi

    IMG_SIZE=$(ls -lh /openwrt.img 2>/dev/null | awk '{print $5}' || echo "unknown")
    echo "✅ OpenWRT image found: $IMG_SIZE"
    echo ""

    # 显示磁盘
    echo "Available disks:"
    echo "================="
    lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || {
        echo "No disks detected"
        echo "Trying fdisk..."
        fdisk -l 2>/dev/null | grep -E "^Disk /dev/" || echo "Cannot list disks"
    }
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
    if command -v pv >/dev/null 2>&1; then
        echo "Using pv to show progress..."
        pv -pet /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M
        DD_EXIT=$?
    else
        echo "Using dd (no progress display)..."
        dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M
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
                read _
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
        read _
    fi
done
INSTALL_SCRIPT

chmod +x /opt/install-openwrt.sh

# 创建bash配置文件
cat > /root/.bashrc <<'BASHRC'
# OpenWRT安装系统bash配置
export PS1='\[\e[1;32m\]\u@openwrt-installer\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

alias ll='ls -la'
alias l='ls -l'
alias cls='clear'

if [ "$(tty)" = "/dev/tty1" ]; then
    echo ""
    echo "Welcome to OpenWRT Installer System (Alpine)"
    echo ""
    echo "If installer doesn't start automatically, run:"
    echo "  /opt/install-openwrt.sh"
    echo ""
fi
BASHRC

# 清理apk缓存
rm -rf /var/cache/apk/*

echo "✅ Alpine setup complete!"
ALPINE_EOF

chmod +x "$CHROOT_DIR/setup-alpine.sh"

# 挂载必要的文件系统
mount -t proc none "$CHROOT_DIR/proc"
mount -t sysfs none "$CHROOT_DIR/sys"
mount -o bind /dev "$CHROOT_DIR/dev"

# 复制resolv.conf到chroot以确保网络正常
cp /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"

# 在chroot中执行设置脚本
log_info "Running Alpine setup in chroot..."
if chroot "$CHROOT_DIR" /setup-alpine.sh 2>&1 | tee "$WORK_DIR/chroot.log"; then
    log_success "Chroot setup completed"
else
    log_warning "Chroot setup had some issues, checking log..."
    if grep -q "ERROR\|failed\|Failed" "$WORK_DIR/chroot.log"; then
        log_warning "Some errors occurred in chroot setup"
    fi
fi

# 清理chroot脚本
rm -f "$CHROOT_DIR/setup-alpine.sh"

# ==================== 步骤7: 准备内核和initramfs ====================
log_info "[7/9] Preparing kernel and initramfs..."

# 查找内核
KERNEL_PATH="$CHROOT_DIR/boot"
if [ -d "$KERNEL_PATH" ]; then
    KERNEL=$(find "$KERNEL_PATH" -name "vmlinuz*" -type f 2>/dev/null | head -1)
    if [ -n "$KERNEL" ]; then
        cp "$KERNEL" "$STAGING_DIR/live/vmlinuz"
        log_success "Copied kernel: $(basename "$KERNEL")"
    else
        log_warning "No kernel found in chroot, will use system kernel"
    fi
fi

# 查找initramfs
INITRAMFS=$(find "$KERNEL_PATH" -name "initramfs*" -o -name "initrd*" -type f 2>/dev/null | head -1)
if [ -n "$INITRAMFS" ]; then
    cp "$INITRAMFS" "$STAGING_DIR/live/initrd"
    log_success "Copied initramfs: $(basename "$INITRAMFS")"
else
    # 如果没有找到initramfs，生成一个简单的
    log_warning "No initramfs found, creating simple one..."
    mkdir -p "$WORK_DIR/initramfs"
    cd "$WORK_DIR/initramfs"
    
    # 创建基本initramfs结构
    mkdir -p {bin,dev,etc,lib,proc,sys,newroot,mnt}
    
    # 复制busybox
    if [ -f "$CHROOT_DIR/bin/busybox" ]; then
        cp "$CHROOT_DIR/bin/busybox" bin/
        chmod +x bin/busybox
    fi
    
    # 创建init脚本
    cat > init <<'INIT_EOF'
#!/bin/sh
# Minimal init script for OpenWRT installer

# Mount essential filesystems
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null

# Create console
mknod /dev/console c 5 1 2>/dev/null

echo "OpenWRT Installer initramfs"
echo "============================"

# Try to mount the squashfs
if [ -f /live/filesystem.squashfs ]; then
    echo "Mounting installer filesystem..."
    mkdir -p /newroot
    mount -t squashfs -o loop,ro /live/filesystem.squashfs /newroot 2>/dev/null
    
    if mountpoint -q /newroot; then
        echo "Switching to installer system..."
        # Move mounts to new root
        mount --move /proc /newroot/proc 2>/dev/null
        mount --move /sys /newroot/sys 2>/dev/null
        mount --move /dev /newroot/dev 2>/dev/null
        
        # Switch root
        exec switch_root /newroot /sbin/init
    else
        echo "ERROR: Could not mount installer filesystem!"
    fi
else
    echo "ERROR: Installer filesystem not found!"
fi

echo "Dropping to emergency shell..."
exec /bin/sh
INIT_EOF
    
    chmod +x init
    
    # 创建压缩的initramfs
    echo "Creating initramfs archive..."
    find . -print0 | cpio -0 -o -H newc 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd"
    cd -
    log_success "Created simple initramfs"
fi

# 如果还没有内核，尝试从系统复制
if [ ! -f "$STAGING_DIR/live/vmlinuz" ]; then
    log_warning "No kernel found, trying to use system kernel..."
    if [ -f "/boot/vmlinuz" ]; then
        cp "/boot/vmlinuz" "$STAGING_DIR/live/vmlinuz"
        log_success "Copied kernel from host system"
    else
        # 最后的手段：下载一个内核
        log_warning "Downloading kernel from Alpine repository..."
        KERNEL_URL="http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/releases/$ALPINE_ARCH/boot/vmlinuz-lts"
        if wget -O "$STAGING_DIR/live/vmlinuz" "$KERNEL_URL"; then
            log_success "Downloaded kernel from Alpine repository"
        else
            log_error "Cannot find or download kernel!"
            exit 1
        fi
    fi
fi

# ==================== 步骤8: 创建squashfs文件系统 ====================
log_info "[8/9] Creating squashfs filesystem..."

# 创建排除列表
cat > "$WORK_DIR/exclude.list" <<'EOF'
proc
sys
dev
tmp
run
mnt
media
boot
var/cache/apk
root/.cache
etc/machine-id
etc/ssh/ssh_host_*
var/log
EOF

# 使用gzip压缩
log_info "Creating compressed filesystem (this may take a moment)..."
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

# 创建live-boot标识文件
echo "live" > "$STAGING_DIR/live/filesystem.squashfs.type"

# ==================== 步骤9: 创建引导配置 ====================
log_info "[9/9] Creating boot configuration..."

# 1. 创建ISOLINUX配置 (BIOS引导)
cat > "$STAGING_DIR/boot/isolinux/isolinux.cfg" <<'ISOLINUX_CFG'
DEFAULT openwrt
TIMEOUT 50
PROMPT 0
UI menu.c32

MENU TITLE OpenWRT Auto Installer (Alpine)

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=tty0 console=ttyS0,115200 boot=live quiet

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=tty0 console=ttyS0,115200 boot=live single
ISOLINUX_CFG

# 复制isolinux文件
if [ -f /usr/share/syslinux/isolinux.bin ]; then
    cp /usr/share/syslinux/isolinux.bin "$STAGING_DIR/boot/isolinux/"
    
    # 复制必要的模块
    for module in menu.c32 libutil.c32 libcom32.c32 ldlinux.c32; do
        if [ -f "/usr/share/syslinux/$module" ]; then
            cp "/usr/share/syslinux/$module" "$STAGING_DIR/boot/isolinux/"
        fi
    done
    log_success "ISOLINUX files copied"
else
    log_warning "isolinux.bin not found, BIOS boot may not work"
fi

# 2. 创建GRUB配置 (UEFI引导)
cat > "$STAGING_DIR/boot/grub/grub.cfg" <<'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz console=tty0 console=ttyS0,115200 boot=live quiet
    initrd /live/initrd
}

menuentry "Emergency Shell" {
    linux /live/vmlinuz console=tty0 console=ttyS0,115200 boot=live single
    initrd /live/initrd
}
GRUB_CFG

# 3. 创建UEFI引导镜像
log_info "Creating UEFI boot image..."
EFI_IMG_SIZE=8M
dd if=/dev/zero of="$STAGING_DIR/EFI/boot/efiboot.img" bs=1 count=0 seek=$EFI_IMG_SIZE 2>/dev/null

if command -v mkfs.vfat >/dev/null 2>&1; then
    if mkfs.vfat -F 32 -n "EFIBOOT" "$STAGING_DIR/EFI/boot/efiboot.img" 2>/dev/null; then
        # 查找GRUB EFI文件
        GRUB_EFI=$(find /usr -type f -name "grubx64.efi" -o -name "bootx64.efi" 2>/dev/null | head -1)
        if [ -n "$GRUB_EFI" ] && command -v mmd >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1; then
            mmd -i "$STAGING_DIR/EFI/boot/efiboot.img" ::/EFI 2>/dev/null
            mmd -i "$STAGING_DIR/EFI/boot/efiboot.img" ::/EFI/BOOT 2>/dev/null
            mcopy -i "$STAGING_DIR/EFI/boot/efiboot.img" "$GRUB_EFI" ::/EFI/BOOT/BOOTX64.EFI 2>/dev/null
            log_success "Added GRUB EFI to boot image"
        else
            log_warning "Could not add GRUB EFI to boot image (missing tools or file)"
        fi
    else
        log_warning "Failed to create FAT filesystem for UEFI"
    fi
else
    log_warning "mkfs.vfat not available, skipping UEFI boot image"
fi

# ==================== 步骤10: 构建ISO镜像 ====================
log_info "[10/9] Building ISO image..."

# 构建ISO
if command -v xorriso >/dev/null 2>&1; then
    log_info "Creating ISO with xorriso..."
    
    # 检查是否有isolinux文件
    if [ -f "$STAGING_DIR/boot/isolinux/isolinux.bin" ]; then
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
            "$STAGING_DIR" 2>&1 | tail -20
    else
        # 如果没有isolinux，创建简单的ISO
        log_warning "No isolinux found, creating simple ISO..."
        xorriso -as mkisofs \
            -iso-level 3 \
            -full-iso9660-filenames \
            -volid "OPENWRT_INSTALL" \
            -output "$ISO_PATH" \
            "$STAGING_DIR" 2>&1 | tail -20
    fi
else
    log_error "xorriso not found!"
    exit 1
fi

# ==================== 步骤11: 验证结果 ====================
log_info "[11/9] Verifying build..."

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    FILESYSTEM_SIZE=$(ls -lh "$STAGING_DIR/live/filesystem.squashfs" | awk '{print $5}')
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║        BUILD SUCCESSFUL!                              ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    log_info "Build Results:"
    log_info "  Output File: $ISO_PATH"
    log_info "  File Size:   $ISO_SIZE"
    log_info "  Filesystem Size: $FILESYSTEM_SIZE"
    echo ""
    
    # 显示ISO信息
    echo "ISO Information:"
    echo "================"
    file "$ISO_PATH" 2>/dev/null || echo "Cannot determine file type"
    echo ""
    
    # 创建构建信息文件
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO Build Information (Alpine)
================================================
Build Date:      $(date)
Build Script:    build-alpine-openwrt-iso.sh
Alpine Version:  $ALPINE_VERSION

Input Image:     $(basename "$OPENWRT_IMG")
Input Size:      $IMG_SIZE
Output ISO:      $ISO_NAME
ISO Size:        $ISO_SIZE
Filesystem Size: $FILESYSTEM_SIZE

Features:
  - Alpine Linux base (musl libc) - Minimal footprint
  - Automatic installer with confirmation
  - Emergency shell for troubleshooting
  - Network support via DHCP
  - SSH access enabled (root login allowed)
  - Disk selection with safety checks

Installation Instructions:
  1. Flash to USB: dd if="$ISO_NAME" of=/dev/sdX bs=4M status=progress
  2. Boot from USB drive
  3. Select "Install OpenWRT" from boot menu
  4. Choose target disk from the list
  5. Type 'YES' to confirm (erases all data!)
  6. Wait for installation to complete
  7. System will auto-reboot (can be cancelled)

Build completed successfully at $(date)
EOF
    
    log_success "Build info saved to: $OUTPUT_DIR/build-info.txt"
    log_success "🎉 Alpine-based OpenWRT installer ISO created successfully!"
    
    # 显示最终文件列表
    echo ""
    echo "Output files:"
    echo "============="
    ls -lh "$OUTPUT_DIR"/
    echo ""
    
    # 清理
    cleanup
    
else
    log_error "❌ ISO file not created: $ISO_PATH"
    
    # 显示staging目录内容用于调试
    echo ""
    echo "Staging directory contents:"
    echo "==========================="
    find "$STAGING_DIR" -type f | sort
    echo ""
    
    exit 1
fi
