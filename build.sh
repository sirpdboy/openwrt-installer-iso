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

# 修复Debian buster源
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
EOF
echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

# 安装必要工具
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
    wimtools

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
    apt \
    locales \
    linux-image-amd64 \
    live-boot \
    systemd-sysv \
    parted \
    openssh-server \
    bash-completion \
    cifs-utils \
    curl \
    dbus \
    dosfstools \
    firmware-linux-free \
    gddrescue \
    gdisk \
    iputils-ping \
    isc-dhcp-client \
    less \
    nfs-common \
    ntfs-3g \
    openssh-client \
    open-vm-tools \
    procps \
    vim \
    wimtools \
    wget \
    dialog \
    pv

# 配置locale
echo "Configuring locale..."
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
dpkg-reconfigure --frontend=noninteractive locales
update-locale LANG=en_US.UTF-8

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
mount -t proc none "${CHROOT_DIR}/proc"
mount -o bind /dev "${CHROOT_DIR}/dev"
mount -o bind /sys "${CHROOT_DIR}/sys"

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
chmod 644 "${CHROOT_DIR}/etc/systemd/network/99-dhcp-en.network"

# 卸载挂载点（重要：在复制文件前卸载）
umount "$CHROOT_DIR/proc" 2>/dev/null || true
umount "$CHROOT_DIR/sys" 2>/dev/null || true
umount "$CHROOT_DIR/dev" 2>/dev/null || true

# ==================== 步骤6: 提取内核和initrd ====================
log_info "[6/10] Extracting kernel and initrd..."

# 重新挂载以访问文件
mount -t proc none "${CHROOT_DIR}/proc" 2>/dev/null || true

KERNEL=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" -type f | head -1)
INITRD=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" -type f | head -1)

if [ -z "$KERNEL" ] || [ -z "$INITRD" ]; then
    log_error "Failed to find kernel or initrd"
    exit 1
fi

# 复制内核文件

cp "${CHROOT_DIR}/boot"/vmlinuz-* "${STAGING_DIR}/live/vmlinuz"
cp "${CHROOT_DIR}/boot"/initrd.img-* "${STAGING_DIR}/live/initrd"

cp "$KERNEL" "$STAGING_DIR/live/vmlinuz"
cp "$INITRD" "$STAGING_DIR/live/initrd"

log_success "Kernel: $(basename "$KERNEL")"
log_success "Initrd: $(basename "$INITRD")"

# ==================== 步骤7: 创建squashfs文件系统 ====================
log_info "[7/10] Creating squashfs filesystem..."

# 创建简单的squashfs（不排除太多文件）
if mksquashfs "$CHROOT_DIR" "$STAGING_DIR/live/filesystem.squashfs" \
    -comp gzip -b 1M -noappend -no-progress \
    -e "proc/*" "sys/*" "dev/*" "tmp/*" "run/*"; then
    SQUASHFS_SIZE=$(ls -lh "$STAGING_DIR/live/filesystem.squashfs" | awk '{print $5}')
    log_success "Squashfs created successfully: $SQUASHFS_SIZE"
else
    log_error "Failed to create squashfs"
    exit 1
fi

# 创建live-boot需要的文件
echo "live" > "$STAGING_DIR/live/filesystem.squashfs.type"

# ==================== 步骤8: 创建引导配置 ====================
log_info "[8/10] Creating boot configuration..."

# 使用最简单的ISOLINUX配置（无图形菜单）
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
TIMEOUT 10
PROMPT 1
F1 boot.msg

LABEL live
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet splash
ISOLINUX_CFG

# 创建boot.msg文件（简单的文本菜单）
cat > "$STAGING_DIR/isolinux/boot.msg" << 'BOOT_MSG'
========================================================================
                      OpenWRT Auto Installer
========================================================================

This is a live system for installing OpenWRT to disk.

To start the installer automatically, press Enter.
To enter rescue shell, type 'live rescue' at the boot prompt.

Default boot will start in 10 seconds...
========================================================================
BOOT_MSG

# 复制必要的引导文件
if [ -f /usr/lib/ISOLINUX/isolinux.bin ]; then
    cp /usr/lib/ISOLINUX/isolinux.bin "$STAGING_DIR/isolinux/"
    cp /usr/lib/ISOLINUX/ldlinux.c32 "$STAGING_DIR/isolinux/" 2>/dev/null || true
elif [ -f /usr/lib/syslinux/isolinux.bin ]; then
    cp /usr/lib/syslinux/isolinux.bin "$STAGING_DIR/isolinux/"
    cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$STAGING_DIR/isolinux/" 2>/dev/null || true
fi

# 创建GRUB配置（UEFI引导）
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live components quiet splash rescue
    initrd /live/initrd
}
GRUB_CFG

# 创建EFI引导
log_info "Creating UEFI boot files..."

# 如果grub-mkstandalone可用，使用它
if command -v grub-mkstandalone >/dev/null 2>&1; then
    # 创建简单的grub配置
    cat > "${WORK_DIR}/tmp/grub.cfg" << 'GRUB_STANDALONE'
search --set=root --file /live/vmlinuz
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd
}
GRUB_STANDALONE
    
    # 创建EFI文件
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="${STAGING_DIR}/EFI/boot/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=${WORK_DIR}/tmp/grub.cfg" 2>&1 | grep -v "warning" || {
        log_warning "Failed to create GRUB EFI, using alternative method"
    }
fi

# 如果EFI文件创建失败，尝试复制现有文件
if [ ! -f "${STAGING_DIR}/EFI/boot/bootx64.efi" ]; then
    log_info "Using alternative EFI boot method..."
    # 复制现有的EFI文件
    if [ -f /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed ]; then
        cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed "${STAGING_DIR}/EFI/boot/bootx64.efi"
    elif [ -f /usr/lib/grub/x86_64-efi/monolithic/grub.efi ]; then
        cp /usr/lib/grub/x86_64-efi/monolithic/grub.efi "${STAGING_DIR}/EFI/boot/bootx64.efi"
    fi
fi

# 创建EFI目录结构
if [ -f "${STAGING_DIR}/EFI/boot/bootx64.efi" ]; then
    log_success "UEFI boot file created"
else
    log_warning "No UEFI boot file created - UEFI boot may not work"
fi

# ==================== 步骤9: 构建ISO镜像 ====================
log_info "[9/10] Building ISO image..."

# 卸载chroot挂载
umount "$CHROOT_DIR/proc" 2>/dev/null || true

# 构建ISO - 使用最简单的配置
log_info "Creating ISO with xorriso..."

# 准备xorriso命令
XORRISO_CMD="xorriso -as mkisofs \
    -r -V 'OPENWRT_INSTALL' \
    -J -joliet-long \
    -cache-inodes \
    -iso-level 3 \
    -partition_offset 16 \
    -A 'OpenWRT Installer' \
    -p 'OpenWRT Project' \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-alt-boot \
    -e EFI/boot/bootx64.efi \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o '$ISO_PATH' \
    '$STAGING_DIR' 2>/dev/null"

# 如果没有EFI文件，移除相关参数
if [ ! -f "${STAGING_DIR}/EFI/boot/bootx64.efi" ]; then
    XORRISO_CMD="xorriso -as mkisofs \
        -r -V 'OPENWRT_INSTALL' \
        -J -joliet-long \
        -cache-inodes \
        -iso-level 3 \
        -partition_offset 16 \
        -A 'OpenWRT Installer' \
        -p 'OpenWRT Project' \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -o '$ISO_PATH' \
        '$STAGING_DIR' 2>/dev/null"
fi

# 执行ISO构建
eval "$XORRISO_CMD"

if [ $? -eq 0 ]; then
    log_success "ISO created successfully"
else
    log_error "Failed to create ISO, trying simpler method..."
    
    # 尝试更简单的命令
    xorriso -as mkisofs \
        -r -V 'OPENWRT_INSTALL' \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -o "$ISO_PATH" \
        "$STAGING_DIR" 2>/dev/null || {
        log_error "ISO creation failed completely"
        exit 1
    }
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
    
    # 检查ISO内容
    log_info "ISO contents:"
    xorriso -indev "$ISO_PATH" -find / -type f 2>/dev/null | grep -E "(vmlinuz|initrd|isolinux|grub)" | head -5
    
    # 创建构建信息文件
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO Build Information
========================================
Build Date:      $(date)
Build Script:    build.sh
Docker Image:    openwrt-iso-builder:latest

Output ISO:      $ISO_NAME
ISO Size:        $ISO_SIZE
Kernel Version:  $(basename "$KERNEL")

Boot Support:    BIOS + UEFI (if available)
Boot Method:     Simple text-based boot
Auto-install:    Enabled

Usage:
  1. Flash: dd if="$ISO_NAME" of=/dev/sdX bs=4M status=progress
  2. Boot from USB
  3. System will start installer automatically
  4. Follow on-screen instructions

Notes:
  - If boot fails, try selecting "Install OpenWRT" from boot menu
  - Press Enter at boot prompt to start installer
  - Type 'live rescue' for rescue shell
EOF
    
    log_success "Build info saved to: $OUTPUT_DIR/build-info.txt"
    log_success "🎉 All steps completed successfully!"
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
