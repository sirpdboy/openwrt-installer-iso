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

# 安全卸载函数
safe_umount() {
    local mount_point="$1"
    if mountpoint -q "$mount_point"; then
        log_info "Unmounting $mount_point..."
        umount -l "$mount_point" 2>/dev/null || true
        sleep 1
        if mountpoint -q "$mount_point"; then
            log_warning "Force unmounting $mount_point..."
            umount -f "$mount_point" 2>/dev/null || true
        fi
    fi
}

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

# 修复Debian buster源
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
EOF
echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

# 安装必要工具
log_info "Installing required packages..."
apt-get update
apt-get -y install \
    debootstrap \
    squashfs-tools \
    xorriso \
    isolinux \
    syslinux \
    syslinux-common \
    grub-pc-bin \
    grub-efi-amd64-bin \
    grub-efi-ia32-bin \
    mtools \
    dosfstools \
    parted \
    wget \
    curl \
    gnupg \
    dialog \
    live-boot \
    live-boot-initramfs-tools \
    git \
    pv \
    file \
    gddrescue \
    gdisk \
    cifs-utils \
    nfs-common \
    ntfs-3g \
    open-vm-tools \
    wimtools \
    efibootmgr

# ==================== 步骤2: 创建目录结构 ====================
log_info "[2/10] Creating directory structure..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$CHROOT_DIR"
mkdir -p "$STAGING_DIR"/{EFI/BOOT,boot/grub,isolinux,live}
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
apt-get -y install apt || true
apt-get -y upgrade
echo "Setting locale..."
apt-get -y install locales
sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
dpkg-reconfigure --frontend=noninteractive locales
update-locale LANG=en_US.UTF-8
apt-get install -y --no-install-recommends linux-image-amd64 live-boot systemd-sysv
apt-get install -y parted openssh-server bash-completion cifs-utils curl dbus dosfstools firmware-linux-free gddrescue gdisk iputils-ping isc-dhcp-client less nfs-common ntfs-3g openssh-client open-vm-tools procps vim wimtools wget

# 清理包缓存
apt-get clean

# 配置网络
systemctl enable systemd-networkd

# 配置SSH允许root登录
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "PermitEmptyPasswords yes" >> /etc/ssh/sshd_config
systemctl enable ssh

# 1. 设置root无密码登录
usermod -p '*' root
cat > /etc/passwd << 'PASSWD'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin
sys:x:3:3:sys:/dev:/usr/sbin/nologin
PASSWD

cat > /etc/shadow << 'SHADOW'
root::0:0:99999:7:::
daemon:*:18507:0:99999:7:::
bin:*:18507:0:99999:7:::
sys:*:18507:0:99999:7:::
SHADOW

# 2. 创建自动启动服务
cat > /etc/systemd/system/autoinstall.service << 'AUTOINSTALL_SERVICE'
[Unit]
Description=OpenWRT Auto Installer
After=getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/start-installer.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
AUTOINSTALL_SERVICE

# 3. 创建启动脚本
cat > /opt/start-installer.sh << 'START_SCRIPT'
#!/bin/bash
# OpenWRT安装系统启动脚本

sleep 3
clear

cat << "WELCOME"

╔═══════════════════════════════════════════════════════╗
║       OpenWRT Auto Install System                     ║
╚═══════════════════════════════════════════════════════╝

System is starting up, please wait...
WELCOME

sleep 2

if [ ! -f "/openwrt.img" ]; then
    clear
    echo ""
    echo "❌ Error: OpenWRT image not found"
    echo ""
    echo "Image file should be at: /openwrt.img"
    echo ""
    echo "Press Enter to enter shell..."
    read
    exec /bin/bash
fi

exec /opt/install-openwrt.sh
START_SCRIPT
chmod +x /opt/start-installer.sh

# 启用服务
systemctl enable autoinstall.service

# 4. 配置agetty自动登录
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
Type=idle
GETTY_OVERRIDE

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
    
    for i in {10..1}; do
        echo -ne "Rebooting in $i seconds...\r"
        sleep 1
    done
    
    reboot -f
done
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 6. 创建bash配置
cat > /root/.bashrc << 'BASHRC'
# OpenWRT安装系统bash配置

# 如果不是交互式shell，直接退出
case $- in
    *i*) ;;
      *) return;;
esac

# 设置PS1
PS1='\[\e[1;32m\]\u@openwrt-installer\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# 别名
alias ll='ls -la'
alias l='ls -l'
alias cls='clear'

if [ "$(tty)" = "/dev/tty1" ]; then
    echo ""
    echo "Welcome to OpenWRT Installer System"
    echo ""
    echo "If installer doesn't start automatically, run:"
    echo "  /opt/install-openwrt.sh"
    echo ""
fi
BASHRC

# 7. 删除machine-id（重要！每次启动重新生成）
rm -f /etc/machine-id

echo "List installed packages"
dpkg --get-selections|tee /packages.txt

# 8. 配置live-boot
mkdir -p /etc/live/boot
echo "live" > /etc/live/boot.conf

# 生成initramfs
echo "Generating initramfs..."
update-initramfs -c -k all 2>/dev/null || true

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "✅ Chroot configuration complete"
CHROOT_EOF

chmod +x "$CHROOT_DIR/install-chroot.sh"

# 挂载文件系统并执行chroot配置
log_info "Mounting filesystems for chroot..."
mount -t proc proc "${CHROOT_DIR}/proc"
mount -t sysfs sys "${CHROOT_DIR}/sys"
mount -o bind /dev "${CHROOT_DIR}/dev"
mount -t devpts devpts "${CHROOT_DIR}/dev/pts" -o gid=5,mode=620

log_info "Running chroot configuration..."
chroot "$CHROOT_DIR" /install-chroot.sh

# 清理chroot
rm -f "$CHROOT_DIR/install-chroot.sh"

cat > "${CHROOT_DIR}/etc/systemd/network/99-dhcp-en.network" <<EOF
[Match]
Name=e*

[Network]
DHCP=yes

[DHCP]
ClientIdentifier=mac
EOF
chown -v root:root "${CHROOT_DIR}/etc/systemd/network/99-dhcp-en.network"
chmod 644 "${CHROOT_DIR}/etc/systemd/network/99-dhcp-en.network"

# ==================== 步骤6: 提取内核和initrd ====================
log_info "[6/10] Extracting kernel and initrd..."

# 卸载chroot挂载点（关键步骤！）
log_info "Unmounting chroot filesystems..."
safe_umount "$CHROOT_DIR/dev/pts"
safe_umount "$CHROOT_DIR/dev"
safe_umount "$CHROOT_DIR/proc"
safe_umount "$CHROOT_DIR/sys"

# 查找内核文件（在卸载挂载点后）
KERNEL=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" -type f | head -1)
INITRD=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" -type f | head -1)

if [ -z "$KERNEL" ] || [ -z "$INITRD" ]; then
    log_error "Failed to find kernel or initrd"
    exit 1
fi

cp "${CHROOT_DIR}/boot"/vmlinuz-* "${STAGING_DIR}/live/vmlinuz"
cp "${CHROOT_DIR}/boot"/initrd.img-* "${STAGING_DIR}/live/initrd"

cp "$KERNEL" "$STAGING_DIR/live/vmlinuz"
cp "$INITRD" "$STAGING_DIR/live/initrd"
log_success "Kernel: $(basename "$KERNEL")"
log_success "Initrd: $(basename "$INITRD")"

# ==================== 步骤7: 创建squashfs文件系统 ====================
log_info "[7/10] Creating squashfs filesystem..."

# 创建排除文件列表
cat > "$WORK_DIR/squashfs-exclude.txt" << 'EOF'
proc/*
sys/*
dev/*
tmp/*
run/*
var/tmp/*
var/run/*
var/cache/*
var/log/*
boot/*.old
home/*
root/.bash_history
root/.cache
EOF

# 创建squashfs，使用排除列表
if mksquashfs "$CHROOT_DIR" "$STAGING_DIR/live/filesystem.squashfs" \
    -comp xz \
    -b 1M \
    -noappend \
    -no-progress \
    -wildcards \
    -ef "$WORK_DIR/squashfs-exclude.txt"; then
    SQUASHFS_SIZE=$(ls -lh "$STAGING_DIR/live/filesystem.squashfs" | awk '{print $5}')
    log_success "Squashfs created successfully: $SQUASHFS_SIZE"
else
    log_error "Failed to create squashfs"
    exit 1
fi

# 创建live-boot需要的文件
echo "live" > "$STAGING_DIR/live/filesystem.squashfs.type"
touch "$STAGING_DIR/live/filesystem.packages"

# ==================== 步骤8: 创建引导配置 ====================
log_info "[8/10] Creating boot configuration..."

# 创建isolinux配置（用于BIOS引导）
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
UI vesamenu.c32

MENU TITLE OpenWRT Installer Boot Menu
DEFAULT linux
TIMEOUT 50
PROMPT 0
MENU RESOLUTION 640 480

LABEL linux
  MENU LABEL ^Install OpenWRT (Live Mode)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet splash

LABEL linux-nosplash
  MENU LABEL Install OpenWRT (verbose mode)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components

LABEL memtest
  MENU LABEL ^Memory test
  KERNEL /isolinux/memtest
  APPEND -

LABEL hdt
  MENU LABEL ^Hardware Detection Tool
  KERNEL /isolinux/hdt.c32

LABEL reboot
  MENU LABEL Reboot
  KERNEL /isolinux/reboot.c32
ISOLINUX_CFG

# 复制isolinux文件
cp /usr/lib/ISOLINUX/isolinux.bin "$STAGING_DIR/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$STAGING_DIR/isolinux/"
cp /usr/lib/syslinux/modules/bios/vesamenu.c32 "$STAGING_DIR/isolinux/"
cp /usr/lib/syslinux/modules/bios/libutil.c32 "$STAGING_DIR/isolinux/"
cp /usr/lib/syslinux/modules/bios/libcom32.c32 "$STAGING_DIR/isolinux/"
ls -l "$STAGING_DIR/isolinux/"
# 创建GRUB配置（用于UEFI引导）
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
# GRUB configuration for OpenWRT Installer
set timeout=10
set default=0
set gfxpayload=keep

# 设置颜色
set menu_color_normal=light-blue/black
set menu_color_highlight=light-cyan/blue

# 加载必要的模块
insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660
insmod linux
insmod gzio

# 查找根设备
if search --file --set=root /live/vmlinuz; then
    echo "Found OpenWRT installer"
else
    echo "ERROR: Cannot find OpenWRT installer files"
    sleep 5
fi

# 主菜单项
menuentry "Install OpenWRT (UEFI Mode)" --class gnu-linux --class os {
    echo "Loading kernel..."
    linux /live/vmlinuz boot=live components quiet splash
    echo "Loading initrd..."
    initrd /live/initrd
}

menuentry "Install OpenWRT (verbose mode)" --class gnu-linux --class os {
    echo "Loading kernel..."
    linux /live/vmlinuz boot=live components
    echo "Loading initrd..."
    initrd /live/initrd
}

menuentry "Boot from first hard disk" {
    echo "Booting from first hard disk..."
    set root=(hd0)
    chainloader +1
}

menuentry "Reboot" {
    echo "Rebooting system..."
    reboot
}

menuentry "Shutdown" {
    echo "Shutting down..."
    halt
}
GRUB_CFG

# 创建memdisk的GRUB配置
cat > "$STAGING_DIR/boot/grub/loopback.cfg" << 'LOOPBACK_CFG'
# Loopback configuration for ISO
set timeout=10
set default=0

menuentry "Install OpenWRT from ISO" {
    echo "Loading kernel from ISO..."
    linux /live/vmlinuz boot=live components findiso=/dev/sr0 quiet splash
    echo "Loading initrd..."
    initrd /live/initrd
}
LOOPBACK_CFG

# 创建UEFI引导文件
log_info "Creating UEFI boot files..."

# 方法1: 使用grub-mkstandalone创建完整的EFI文件
log_info "Method 1: Creating grubx64.efi with grub-mkstandalone..."
if command -v grub-mkstandalone >/dev/null 2>&1; then
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/tmp/grubx64.efi" \
        --modules="part_gpt part_msdos fat iso9660 linux gzio" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$STAGING_DIR/boot/grub/grub.cfg" && \
    log_success "Created grubx64.efi with grub-mkstandalone"
fi

# 方法2: 直接复制预编译的GRUB EFI文件
if [ ! -f "$WORK_DIR/tmp/grubx64.efi" ]; then
    log_info "Method 2: Copying pre-built grubx64.efi..."
    if [ -f "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" ]; then
        cp "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" "$WORK_DIR/tmp/grubx64.efi"
        log_success "Copied monolithic grubx64.efi"
    elif [ -f "/usr/lib/grub/x86_64-efi/grubnetx64.efi" ]; then
        cp "/usr/lib/grub/x86_64-efi/grubnetx64.efi" "$WORK_DIR/tmp/grubx64.efi"
        log_success "Copied grubnetx64.efi as grubx64.efi"
    fi
fi

# 创建EFI目录结构
mkdir -p "$STAGING_DIR/EFI/BOOT"

# 复制GRUB EFI文件
if [ -f "$WORK_DIR/tmp/grubx64.efi" ]; then
    cp "$WORK_DIR/tmp/grubx64.efi" "$STAGING_DIR/EFI/BOOT/BOOTX64.EFI"
    log_success "BOOTX64.EFI created"
    
    # 同时复制为grubx64.efi
    cp "$WORK_DIR/tmp/grubx64.efi" "$STAGING_DIR/EFI/BOOT/grubx64.efi"
else
    log_warning "Failed to create grubx64.efi, UEFI boot may not work"
fi

# 复制GRUB模块（可选，但推荐）
mkdir -p "$STAGING_DIR/boot/grub/x86_64-efi"
if [ -d "/usr/lib/grub/x86_64-efi" ]; then
    cp -r /usr/lib/grub/x86_64-efi/* "$STAGING_DIR/boot/grub/x86_64-efi/" 2>/dev/null || true
fi

# 创建EFI引导映像（FAT格式）
log_info "Creating FAT32 EFI boot image..."
EFI_IMG="$STAGING_DIR/EFI/boot/efiboot.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=32
mkfs.vfat -F 32 -n "UEFI_BOOT" "$EFI_IMG"

# 挂载EFI映像并复制文件
mkdir -p "$WORK_DIR/efimount"
mount -o loop "$EFI_IMG" "$WORK_DIR/efimount"
mkdir -p "$WORK_DIR/efimount/EFI/BOOT"

# 复制EFI文件到映像中
if [ -f "$STAGING_DIR/EFI/BOOT/BOOTX64.EFI" ]; then
    cp "$STAGING_DIR/EFI/BOOT/BOOTX64.EFI" "$WORK_DIR/efimount/EFI/BOOT/"
fi

# 复制GRUB配置文件到EFI分区
mkdir -p "$WORK_DIR/efimount/boot/grub"
cp "$STAGING_DIR/boot/grub/grub.cfg" "$WORK_DIR/efimount/boot/grub/"

# 卸载EFI映像
umount "$WORK_DIR/efimount"
rm -rf "$WORK_DIR/efimount"

log_success "EFI boot image created: $(ls -lh "$EFI_IMG")"

# ==================== 步骤9: 构建ISO镜像 ====================
log_info "[9/10] Building ISO image..."

cd "$STAGING_DIR"

# 首先检查文件是否存在
log_info "Checking required files..."
ls -la live/
ls -la isolinux/
ls -la EFI/boot/

# 使用xorriso构建ISO
log_info "Building ISO with xorriso..."
xorriso -as mkisofs \
    -volid "OPENWRT_INSTALL" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/boot/efiboot.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -partition_offset 16 \
    -output "$ISO_PATH" \
    .

# 备用方法：如果xorriso失败，使用genisoimage
if [ ! -f "$ISO_PATH" ]; then
    log_warning "xorriso failed, trying genisoimage..."
    apt-get install -y genisoimage
    
    genisoimage \
        -volid "OPENWRT_INSTALL" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot \
        -o "$ISO_PATH" \
        .
    
    # 添加isohybrid支持
    if [ -f "$ISO_PATH" ]; then
        isohybrid --uefi "$ISO_PATH" 2>/dev/null || true
    fi
fi

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
    
    # 详细检查ISO内容
    log_info "Checking ISO contents..."
    
    # 检查BIOS引导
    if file "$ISO_PATH" | grep -q "bootable"; then
        log_success "ISO is bootable (BIOS)"
    else
        log_warning "ISO may not be BIOS bootable"
    fi
    
    # 检查UEFI引导
    if xorriso -indev "$ISO_PATH" -find /EFI/BOOT/BOOTX64.EFI 2>/dev/null | grep -q "BOOTX64.EFI"; then
        log_success "ISO contains UEFI bootloader (BOOTX64.EFI)"
    else
        log_warning "ISO may not contain UEFI bootloader"
    fi
    
    # 检查内核文件
    if xorriso -indev "$ISO_PATH" -find /live/vmlinuz 2>/dev/null | grep -q "vmlinuz"; then
        log_success "ISO contains kernel: /live/vmlinuz"
    fi
    
    # 检查initrd文件
    if xorriso -indev "$ISO_PATH" -find /live/initrd 2>/dev/null | grep -q "initrd"; then
        log_success "ISO contains initrd: /live/initrd"
    fi
    
    # 检查squashfs文件
    SQUASHFS_IN_ISO=$(xorriso -indev "$ISO_PATH" -find /live/filesystem.squashfs 2>/dev/null)
    if echo "$SQUASHFS_IN_ISO" | grep -q "filesystem.squashfs"; then
        log_success "ISO contains squashfs filesystem"
    fi
    
    # 创建构建信息文件
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO Build Information
========================================
Build Date:      $(date)
Build Script:    build.sh

Output ISO:      $ISO_NAME
ISO Size:        $ISO_SIZE
Kernel Version:  $(basename "$KERNEL")
Initrd Version:  $(basename "$INITRD")

Boot Support:
  - BIOS (ISOLINUX/SYSLINUX)
  - UEFI x86_64 (GRUB2)

Boot Files:
  - BIOS: /isolinux/isolinux.bin
  - UEFI: /EFI/BOOT/BOOTX64.EFI
  - Kernel: /live/vmlinuz
  - Initrd: /live/initrd
  - Root FS: /live/filesystem.squashfs

Boot Menu Options:
  1. Install OpenWRT (Live Mode) - default
  2. Install OpenWRT (verbose mode)
  3. Boot from hard disk
  4. Reboot
  5. Shutdown

Usage:
  1. Flash: dd if="$ISO_NAME" of=/dev/sdX bs=4M status=progress
  2. Boot from USB/CD
  3. Select installation mode
  4. Follow on-screen instructions

Troubleshooting:
  - If UEFI boot fails, try disabling Secure Boot in BIOS
  - For older systems, use BIOS/Legacy boot mode
  - Press F12/Esc/F2 during boot for boot menu
EOF
    
    log_success "Build info saved to: $OUTPUT_DIR/build-info.txt"
    
    # 清理工作目录
    log_info "Cleaning up..."
    safe_umount "$CHROOT_DIR/dev/pts" 2>/dev/null || true
    safe_umount "$CHROOT_DIR/dev" 2>/dev/null || true
    safe_umount "$CHROOT_DIR/proc" 2>/dev/null || true
    safe_umount "$CHROOT_DIR/sys" 2>/dev/null || true
    rm -rf "$WORK_DIR"
    
    echo ""
    log_success "🎉 All steps completed successfully!"
    echo ""
    log_info "ISO is ready at: $ISO_PATH"
    log_info "To test UEFI boot: qemu-system-x86_64 -bios /usr/share/qemu/OVMF.fd -cdrom $ISO_PATH"
    log_info "To test BIOS boot: qemu-system-x86_64 -cdrom $ISO_PATH"
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
