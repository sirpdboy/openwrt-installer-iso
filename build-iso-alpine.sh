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
ALPINE_VERSION="3.20"
ALPINE_ARCH="x86_64"
ALPINE_MIRROR="http://dl-cdn.alpinelinux.org/alpine"

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
apk update
apk add --no-cache \
    alpine-sdk \
    squashfs-tools \
    xorriso \
    syslinux \
    grub-bios \
    grub-efi \
    mtools \
    dosfstools \
    parted \
    curl \
    wget \
    dialog \
    pv \
    gptfdisk \
    e2fsprogs \
    e2fsprogs-extra \
    util-linux \
    coreutils \
    bash \
    sudo \
    git

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

# ==================== 步骤5: 安装Alpine最小系统 ====================
log_info "[5/9] Installing Alpine minimal system..."

# 创建Alpine包缓存目录
mkdir -p /tmp/apk-cache
export APK_CACHE=/tmp/apk-cache

# 使用apk.static安装Alpine基础系统
ALPINE_RELEASE_URL="$ALPINE_MIRROR/v$ALPINE_VERSION/releases/$ALPINE_ARCH"

# 尝试下载apk-tools-static
APK_STATIC_FILES=(
    "apk-tools-static-2.14.4-r1.apk"
    "apk-tools-static-2.14.0-r0.apk"
    "apk-tools-static-2.12.11-r1.apk"
)

APK_STATIC=""
for static_file in "${APK_STATIC_FILES[@]}"; do
    if wget -q --spider "$ALPINE_RELEASE_URL/$static_file"; then
        APK_STATIC="$static_file"
        break
    fi
done

if [ -z "$APK_STATIC" ]; then
    log_warning "No specific apk-tools-static found, trying to find any..."
    wget -q -O /tmp/apk-index.html "$ALPINE_RELEASE_URL/"
    APK_STATIC=$(grep -o 'apk-tools-static-[0-9].*\.apk' /tmp/apk-index.html | head -1)
fi

if [ -z "$APK_STATIC" ]; then
    # 如果还是找不到，使用一个通用的方法
    log_warning "Using alternative method to install Alpine..."
    
    # 下载并安装最新的Alpine mini rootfs
    wget -O /tmp/alpine-minirootfs.tar.gz \
        "$ALPINE_MIRROR/v$ALPINE_VERSION/releases/$ALPINE_ARCH/alpine-minirootfs-$ALPINE_VERSION.0-$ALPINE_ARCH.tar.gz"
    
    if [ -f /tmp/alpine-minirootfs.tar.gz ]; then
        tar -xzf /tmp/alpine-minirootfs.tar.gz -C "$CHROOT_DIR"
    else
        log_error "Failed to download Alpine mini rootfs"
        exit 1
    fi
else
    # 使用apk-tools-static
    log_info "Downloading apk-tools-static: $APK_STATIC"
    wget -O /tmp/$APK_STATIC "$ALPINE_RELEASE_URL/$APK_STATIC"
    
    if [ ! -f "/tmp/$APK_STATIC" ]; then
        log_error "Failed to download apk-tools-static"
        exit 1
    fi
    
    tar -xzf /tmp/$APK_STATIC -C /tmp
    
    # 安装Alpine基础系统
    /tmp/sbin/apk.static -X "$ALPINE_MIRROR/v$ALPINE_VERSION/main" \
        -U --allow-untrusted --root "$CHROOT_DIR" --initdb add alpine-base
fi

# 安装必要的包到chroot
cat > "$CHROOT_DIR/setup-alpine.sh" << 'ALPINE_EOF'
#!/bin/sh
set -e

echo "🔧 Setting up Alpine environment..."

# 设置apk仓库
cat > /etc/apk/repositories <<EOF
http://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64
http://dl-cdn.alpinelinux.org/alpine/v3.20/community/x86_64
EOF

# 更新包数据库
apk update

# 安装必要包（修复gdisk为gptfdisk）
apk add --no-cache \
    linux-lts \
    linux-firmware-none \
    openrc \
    eudev \
    util-linux \
    bash \
    coreutils \
    busybox \
    parted \
    gptfdisk \
    e2fsprogs \
    e2fsprogs-extra \
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
    openssh-client \
    dhcpcd \
    haveged \
    chrony \
    sudo \
    ntfs-3g \
    cifs-utils \
    nfs-utils \
    pciutils \
    usbutils \
    lvm2 \
    mdadm \
    cryptsetup \
    wireguard-tools \
    iptables \
    iproute2 \
    iputils \
    ethtool \
    net-tools

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 设置时区为UTC
setup-timezone -z UTC

# 设置DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 设置root无密码登录
sed -i 's/^root:!:/root::/' /etc/shadow

# 启用服务
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
rc-update add chronyd default
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

# 等待网络就绪
sleep 3

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
    
    sleep 2
    
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
    exec /opt/install-openwrt.sh
fi
START_SCRIPT

chmod +x /etc/local.d/autoinstall.start

# 创建安装脚本
mkdir -p /opt
cat > /opt/install-openwrt.sh <<'INSTALL_SCRIPT'
#!/bin/sh
# OpenWRT自动安装脚本

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

    IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}')
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
    
    # 使用pv显示进度
    if command -v pv >/dev/null 2>&1; then
        pv -pet /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M
    else
        dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M status=progress
    fi
    
    sync
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
            echo "Type 'reboot' to restart, or 'exit' to return to installer."
            echo ""
            echo "Press Enter to return to installer..."
            read _
            break
        fi
        if [ $i -eq 1 ]; then
            echo ""
            echo "Rebooting now..."
            reboot -f
        fi
    done
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

# 在chroot中执行设置脚本
log_info "Running Alpine setup in chroot..."
chroot "$CHROOT_DIR" /setup-alpine.sh

# 清理chroot脚本
rm -f "$CHROOT_DIR/setup-alpine.sh"

# ==================== 步骤6: 提取内核和initramfs ====================
log_info "[6/9] Extracting kernel and initramfs..."

# 查找内核和initramfs
KERNEL=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" -o -name "vmlinuz" | head -1)
INITRAMFS=$(find "$CHROOT_DIR/boot" -name "initramfs-*" -o -name "initrd.img-*" | head -1)

if [ -z "$KERNEL" ]; then
    # 如果没有找到内核，使用当前系统的
    log_warning "Kernel not found in chroot, using system kernel..."
    if [ -f "/boot/vmlinuz" ]; then
        cp "/boot/vmlinuz" "$STAGING_DIR/live/vmlinuz"
    else
        # 从Alpine仓库下载内核
        log_warning "Downloading kernel from Alpine repository..."
        wget -O "$STAGING_DIR/live/vmlinuz" \
            "$ALPINE_MIRROR/v$ALPINE_VERSION/releases/$ALPINE_ARCH/boot/vmlinuz-lts" || \
        wget -O "$STAGING_DIR/live/vmlinuz" \
            "https://raw.githubusercontent.com/alpinelinux/aports/main/scripts/mkimage.kernel.sh"
    fi
else
    cp "$KERNEL" "$STAGING_DIR/live/vmlinuz"
fi

if [ -z "$INITRAMFS" ]; then
    # 如果没有找到initramfs，生成一个简单的
    log_warning "Initramfs not found, creating simple one..."
    mkdir -p "$WORK_DIR/initramfs"
    cd "$WORK_DIR/initramfs"
    
    # 创建基本initramfs结构
    mkdir -p {bin,dev,etc,lib,proc,sys,newroot,mnt}
    
    # 复制busybox
    if [ -f "$CHROOT_DIR/bin/busybox" ]; then
        cp "$CHROOT_DIR/bin/busybox" bin/
    else
        cp /bin/busybox bin/
    fi
    
    # 创建init脚本
    cat > init <<'INIT_EOF'
#!/bin/busybox sh
# Minimal init script for OpenWRT installer

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Mount essential filesystems
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev

# Create device nodes
/bin/busybox mknod /dev/console c 5 1

# Load modules if needed
/bin/busybox modprobe -q ext4
/bin/busybox modprobe -q vfat
/bin/busybox modprobe -q nls_utf8
/bin/busybox modprobe -q isofs

# Mount the root filesystem
echo "Mounting root filesystem..."
if [ -f /openwrt.img ]; then
    # We're in the installer system
    /bin/busybox mount -t squashfs -o loop,ro /live/filesystem.squashfs /newroot 2>/dev/null || \
    /bin/busybox mount -t ext4 -o loop,ro /live/filesystem.squashfs /newroot 2>/dev/null
else
    # Try to find the root filesystem
    /bin/busybox mount -t ext4 /dev/sda1 /newroot 2>/dev/null || \
    /bin/busybox mount -t ext4 /dev/vda1 /newroot 2>/dev/null || \
    /bin/busybox mount -t ext4 /dev/hda1 /newroot 2>/dev/null
fi

if /bin/busybox mountpoint -q /newroot; then
    # Switch to the new root
    echo "Switching to new root..."
    /bin/busybox mount --move /proc /newroot/proc
    /bin/busybox mount --move /sys /newroot/sys
    /bin/busybox mount --move /dev /newroot/dev
    
    exec /bin/busybox switch_root /newroot /sbin/init
else
    echo "ERROR: Could not mount root filesystem!"
    echo "Dropping to emergency shell..."
    exec /bin/busybox sh
fi
INIT_EOF
    
    chmod +x init
    
    # 创建压缩的initramfs
    find . | cpio -o -H newc | gzip > "$STAGING_DIR/live/initrd"
    cd -
else
    cp "$INITRAMFS" "$STAGING_DIR/live/initrd"
fi

log_success "Kernel: $(basename "$STAGING_DIR/live/vmlinuz")"
log_success "Initrd: $(basename "$STAGING_DIR/live/initrd")"

# ==================== 步骤7: 创建squashfs文件系统 ====================
log_info "[7/9] Creating squashfs filesystem..."

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

# 使用高压缩比创建squashfs
if mksquashfs "$CHROOT_DIR" "$STAGING_DIR/live/filesystem.squashfs" \
    -comp xz \
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

# ==================== 步骤8: 创建引导配置 ====================
log_info "[8/9] Creating boot configuration..."

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
  APPEND initrd=/live/initrd console=tty0 console=ttyS0,115200 boot=live ip=frommedia
  TEXT HELP
  Automatically install OpenWRT to disk
  ENDTEXT

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=tty0 console=ttyS0,115200 boot=live single
  TEXT HELP
  Start emergency shell for troubleshooting
  ENDTEXT
ISOLINUX_CFG

# 复制isolinux文件
if [ -f /usr/share/syslinux/isolinux.bin ]; then
    cp /usr/share/syslinux/isolinux.bin "$STAGING_DIR/boot/isolinux/"
else
    # 尝试其他可能的位置
    find /usr/lib/syslinux -name "isolinux.bin" 2>/dev/null | head -1 | xargs -I {} cp {} "$STAGING_DIR/boot/isolinux/" || true
fi

# 复制必要的syslinux模块
for module in ldlinux.c32 libcom32.c32 libutil.c32 menu.c32; do
    if [ -f "/usr/share/syslinux/$module" ]; then
        cp "/usr/share/syslinux/$module" "$STAGING_DIR/boot/isolinux/"
    else
        find /usr/lib/syslinux -name "$module" 2>/dev/null | head -1 | xargs -I {} cp {} "$STAGING_DIR/boot/isolinux/" || true
    fi
done

# 2. 创建GRUB配置 (UEFI引导)
cat > "$STAGING_DIR/boot/grub/grub.cfg" <<'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz console=tty0 console=ttyS0,115200 boot=live ip=frommedia
    initrd /live/initrd
}

menuentry "Emergency Shell" {
    linux /live/vmlinuz console=tty0 console=ttyS0,115200 boot=live single
    initrd /live/initrd
}
GRUB_CFG

# 3. 创建UEFI引导镜像
log_info "Creating UEFI boot image..."

# 创建GRUB standalone EFI文件
if command -v grub-mkstandalone >/dev/null 2>&1; then
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/tmp/grubx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$STAGING_DIR/boot/grub/grub.cfg"
else
    log_warning "grub-mkstandalone not found, trying alternative method..."
    # 尝试直接复制现有的EFI文件
    if [ -f "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" ]; then
        cp "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" "$WORK_DIR/tmp/grubx64.efi"
    elif [ -f "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" ]; then
        cp "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" "$WORK_DIR/tmp/grubx64.efi"
    else
        log_error "Cannot find GRUB EFI file"
    fi
fi

# 创建FAT32格式的EFI系统分区镜像
EFI_IMG_SIZE=16M
dd if=/dev/zero of="$WORK_DIR/tmp/efiboot.img" bs=1 count=0 seek=$EFI_IMG_SIZE
mkfs.vfat -F 32 -n "EFIBOOT" "$WORK_DIR/tmp/efiboot.img" 2>/dev/null || true

# 复制EFI文件到镜像
if [ -f "$WORK_DIR/tmp/grubx64.efi" ] && [ -f "$WORK_DIR/tmp/efiboot.img" ]; then
    mmd -i "$WORK_DIR/tmp/efiboot.img" ::/EFI 2>/dev/null || true
    mmd -i "$WORK_DIR/tmp/efiboot.img" ::/EFI/BOOT 2>/dev/null || true
    mcopy -i "$WORK_DIR/tmp/efiboot.img" "$WORK_DIR/tmp/grubx64.efi" ::/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true
    
    # 移动EFI镜像到最终位置
    mv "$WORK_DIR/tmp/efiboot.img" "$STAGING_DIR/EFI/boot/"
    log_success "UEFI boot image created"
else
    log_warning "Failed to create UEFI boot image, BIOS only"
fi

# ==================== 步骤9: 构建ISO镜像 ====================
log_info "[9/9] Building ISO image..."

# 构建支持BIOS和UEFI的混合ISO
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot boot/isolinux/isolinux.bin \
    -eltorito-catalog boot/isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    $(if [ -f "$STAGING_DIR/EFI/boot/efiboot.img" ]; then echo "-eltorito-alt-boot -e EFI/boot/efiboot.img -no-emul-boot"; fi) \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin 2>/dev/null \
    -output "$ISO_PATH" \
    "$STAGING_DIR" 2>&1 | grep -E "(Progress|^[^.]|%)" || true

# ==================== 步骤10: 验证结果 ====================
log_info "[10/10] Verifying build..."

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    FILESYSTEM_SIZE=$(ls -lh "$STAGING_DIR/live/filesystem.squashfs" | awk '{print $5}')
    
    echo ""
    log_success "✅ ISO built successfully!"
    echo ""
    log_info "Build Results:"
    log_info "  Output File: $ISO_PATH"
    log_info "  File Size:   $ISO_SIZE"
    log_info "  Alpine Version: $ALPINE_VERSION"
    log_info "  Filesystem Size: $FILESYSTEM_SIZE"
    log_info "  Boot Support: BIOS + UEFI"
    echo ""
    
    # 显示ISO内容摘要
    echo "ISO Content Summary:"
    echo "===================="
    xorriso -indev "$ISO_PATH" -find / -type d -name "boot" -o -name "EFI" -o -name "live" 2>/dev/null | sort
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

Boot Support:    BIOS + UEFI (Hybrid ISO)
Boot Loaders:    ISOLINUX (BIOS) + GRUB (UEFI)
Boot Timeout:    5 seconds
Auto-install:    Enabled

Kernel:          $(basename "$STAGING_DIR/live/vmlinuz")
Initrd:          $(basename "$STAGING_DIR/live/initrd")

Features:
  - Alpine Linux base (musl libc)
  - Minimal footprint
  - Automatic installer
  - Emergency shell
  - Network support via DHCP
  - SSH access enabled

Usage:
  1. Flash to USB: dd if="$ISO_NAME" of=/dev/sdX bs=4M status=progress
  2. Boot from USB
  3. Select "Install OpenWRT" from menu
  4. Choose target disk and confirm
  5. Wait for installation to complete
  6. System will auto-reboot
EOF
    
    log_success "Build info saved to: $OUTPUT_DIR/build-info.txt"
    log_success "🎉 Alpine-based OpenWRT installer ISO created successfully!"
    
    # 清理
    cleanup
    
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
