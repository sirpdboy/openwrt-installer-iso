#!/bin/bash
# build-openwrt-installer-complete.sh - 完整修复版
set -e

echo "🚀 开始构建OpenWRT安装ISO..."
echo "========================================"

# 基础配置
WORK_DIR="${HOME}/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/chroot"
STAGING_DIR="${WORK_DIR}/staging"
OUTPUT_DIR="/output"
OPENWRT_IMG="/mnt/ezopwrt.img"
ISO_NAME="openwrt-autoinstall.iso"

# 检查目录
mkdir -p "${OUTPUT_DIR}"

# 清理旧目录
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${CHROOT_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/boot,boot/grub,isolinux,live}

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

# 检查必要文件
log_info "检查必要文件..."
if [ ! -f "${OPENWRT_IMG}" ]; then
    log_error "找不到OpenWRT镜像: ${OPENWRT_IMG}"
    exit 1
fi

# 修复Debian buster源
log_info "配置Debian buster源..."
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
EOF

cat > /etc/apt/apt.conf.d/99no-check-valid-until <<EOF
Acquire::Check-Valid-Until "false";
APT::Get::AllowUnauthenticated "true";
EOF

# 安装必要工具
log_info "安装构建工具..."
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
    pv \
    file

# 复制OpenWRT镜像
log_info "复制OpenWRT镜像..."
cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img"

# 引导Debian最小系统
log_info "引导Debian最小系统..."
DEBIAN_MIRROR="http://archive.debian.org/debian"
if ! debootstrap --arch=amd64 --variant=minbase \
    buster "${CHROOT_DIR}" \
    "${DEBIAN_MIRROR}" 2>&1 | tee /tmp/debootstrap.log; then
    log_warning "第一次引导失败，尝试备用源..."
    DEBIAN_MIRROR="http://deb.debian.org/debian"
    debootstrap --arch=amd64 --variant=minbase \
        buster "${CHROOT_DIR}" \
        "${DEBIAN_MIRROR}" 2>&1 | tee -a /tmp/debootstrap.log || {
        log_error "debootstrap失败"
        exit 1
    }
fi

# 创建chroot安装脚本
log_info "创建chroot配置脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# OpenWRT安装系统chroot配置脚本
set -e

echo "🔧 开始配置chroot环境..."

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源
cat > /etc/apt/sources.list << 'APT_SOURCES'
deb http://archive.debian.org/debian/ buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main contrib non-free
APT_SOURCES

cat > /etc/apt/apt.conf.d/99custom << 'APT_CONF'
Acquire::Check-Valid-Until "false";
APT::Get::AllowUnauthenticated "true";
APT_CONF

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 配置DNS
cat > /etc/resolv.conf << 'RESOLV'
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLV

# 更新包列表
echo "🔄 更新包列表..."
apt-get update

# === 安装基本系统 ===
echo "📦 安装基本系统..."
apt-get install -y --no-install-recommends \
    systemd \
    systemd-sysv \
    bash \
    coreutils \
    util-linux \
    parted \
    dosfstools \
    e2fsprogs \
    dialog \
    pv \
    curl \
    wget \
    kbd \
    console-setup \
    locales \
    nano \
    less \
    iputils-ping \
    net-tools \
    sudo

# === 安装内核 ===
echo "🐧 安装内核..."
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    linux-headers-amd64

# === 安装live-boot ===
echo "🚀 安装live-boot..."
apt-get install -y --no-install-recommends \
    live-boot \
    live-boot-initramfs-tools \
    live-tools

# === 配置locale ===
echo "🌐 配置locale..."
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# === 配置自动登录 ===
echo "🔧 配置自动登录..."

# 设置root无密码
echo 'root:$1$xyz$Xq6CxFpL9Q7yRcZ8pzB.Z.:0:0:root:/root:/bin/bash' > /etc/passwd
echo 'root::0:0:99999:7:::' > /etc/shadow

# 创建自动启动脚本
cat > /root/.profile << 'PROFILE'
# ~/.profile

# 如果登录的是tty1，则启动安装程序
if [ "$(tty)" = "/dev/tty1" ]; then
    # 等待系统完全启动
    sleep 2
    
    # 清屏
    clear
    
    # 启动安装程序
    exec /opt/install-openwrt.sh
fi

# 设置PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
PROFILE

# 创建bashrc
cat > /root/.bashrc << 'BASHRC'
# ~/.bashrc

# 如果不是交互式shell，直接退出
case $- in
    *i*) ;;
      *) return;;
esac

# 设置PS1
PS1='\[\e[1;32m\]\u@openwrt-installer\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# 别名
alias ll='ls -la'
alias cls='clear'
BASHRC

# === 创建OpenWRT安装脚本 ===
echo "📝 创建OpenWRT安装脚本..."
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT自动安装脚本

# 设置环境
export TERM=linux
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export LANG=C
export LC_ALL=C

# 清屏
clear

# 显示欢迎信息
cat << "WELCOME"

╔═══════════════════════════════════════════════════════╗
║               OpenWRT Auto Installer                  ║
║               OpenWRT 自动安装系统                    ║
╚═══════════════════════════════════════════════════════╝

WELCOME

echo ""
echo "Initializing system..."
echo "系统初始化中..."
echo ""

sleep 2

# 检查OpenWRT镜像
if [ ! -f "/openwrt.img" ]; then
    clear
    echo ""
    echo "❌ ERROR: OpenWRT image not found!"
    echo "❌ 错误: 未找到OpenWRT镜像！"
    echo ""
    echo "Expected location: /openwrt.img"
    echo "期望位置: /openwrt.img"
    echo ""
    echo "Press Enter to enter shell..."
    echo "按Enter键进入Shell..."
    read
    exec /bin/bash
fi

IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}')
echo "✅ OpenWRT image found: $IMG_SIZE"
echo "✅ 找到OpenWRT镜像: $IMG_SIZE"
echo ""

# 主安装循环
while true; do
    # 清屏
    clear
    
    # 显示标题
    cat << "TITLE"

╔═══════════════════════════════════════════════════════╗
║              OpenWRT Disk Installation                ║
║                OpenWRT 磁盘安装                       ║
╚═══════════════════════════════════════════════════════╝

TITLE

    echo ""
    echo "Scanning for available disks..."
    echo "正在扫描可用磁盘..."
    echo ""
    
    # 显示磁盘列表
    echo "========================================"
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -n -o NAME,SIZE,TYPE,MODEL | grep -E '^(sd|hd|nvme|vd)' || echo "No disks found"
    else
        echo "Disk        Size"
        echo "----------------"
        for dev in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
            if [ -b "$dev" ]; then
                size=$(blockdev --getsize64 "$dev" 2>/dev/null | awk '{printf "%.1fG", $1/1024/1024/1024}')
                echo "$(basename $dev)       $size"
            fi
        done
    fi
    echo "========================================"
    echo ""
    
    # 选择磁盘
    echo "Enter target disk name (e.g., sda, nvme0n1):"
    echo "请输入目标磁盘名称 (例如: sda, nvme0n1):"
    echo ""
    read -p "Disk name: " TARGET_DISK
    
    # 验证输入
    if [ -z "$TARGET_DISK" ]; then
        echo ""
        echo "❌ Please enter a disk name."
        echo "❌ 请输入磁盘名称。"
        sleep 2
        continue
    fi
    
    # 检查磁盘是否存在
    if [ ! -b "/dev/$TARGET_DISK" ]; then
        echo ""
        echo "❌ Disk /dev/$TARGET_DISK does not exist!"
        echo "❌ 磁盘 /dev/$TARGET_DISK 不存在！"
        sleep 2
        continue
    fi
    
    # 确认安装
    clear
    cat << "CONFIRM"

╔═══════════════════════════════════════════════════════╗
║               CONFIRM INSTALLATION                    ║
║                 确认安装                              ║
╚═══════════════════════════════════════════════════════╝

CONFIRM

    echo ""
    echo "⚠️  WARNING: ALL DATA ON /dev/$TARGET_DISK WILL BE ERASED!"
    echo "⚠️  警告: /dev/$TARGET_DISK 上的所有数据将被擦除！"
    echo ""
    echo "Target disk: /dev/$TARGET_DISK"
    echo "目标磁盘: /dev/$TARGET_DISK"
    echo "Image size: $IMG_SIZE"
    echo "镜像大小: $IMG_SIZE"
    echo ""
    echo "Type 'YES' to confirm installation:"
    echo "输入 'YES' 确认安装:"
    echo ""
    read -p "Confirmation: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo ""
        echo "Installation cancelled."
        echo "安装已取消。"
        sleep 2
        continue
    fi
    
    # 开始安装
    clear
    cat << "INSTALLING"

╔═══════════════════════════════════════════════════════╗
║               INSTALLING OPENWRT                      ║
║                 正在安装 OpenWRT                      ║
╚═══════════════════════════════════════════════════════╝

INSTALLING

    echo ""
    echo "Target: /dev/$TARGET_DISK"
    echo "目标: /dev/$TARGET_DISK"
    echo ""
    
    # 写入镜像
    echo "Writing image to disk..."
    echo "正在写入镜像到磁盘..."
    echo ""
    echo "DO NOT POWER OFF OR REMOVE USB!"
    echo "请勿关闭电源或拔出U盘！"
    echo ""
    
    if command -v pv >/dev/null 2>&1; then
        pv -pet /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M status=none
    else
        dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M status=progress
    fi
    
    sync
    
    echo ""
    echo "✅ Installation successful!"
    echo "✅ 安装成功！"
    echo ""
    
    # 重启提示
    echo "The system will reboot in 10 seconds."
    echo "系统将在10秒后重启。"
    echo "Press any key to cancel."
    echo "按任意键取消重启。"
    echo ""
    
    for i in {10..1}; do
        echo -ne "Rebooting in $i seconds...\r"
        if read -t 1 -n 1; then
            echo ""
            echo ""
            echo "Reboot cancelled. You can:"
            echo "重启已取消。您可以："
            echo "1. Type 'reboot' to restart"
            echo "   输入 'reboot' 重启"
            echo "2. Type '/opt/install-openwrt.sh' to restart installer"
            echo "   输入 '/opt/install-openwrt.sh' 重新运行安装程序"
            echo ""
            exec /bin/bash
        fi
    done
    
    echo ""
    echo "Rebooting..."
    echo "正在重启..."
    sleep 2
    reboot -f
done
INSTALL_SCRIPT

chmod +x /opt/install-openwrt.sh

# === 配置live-boot ===
echo "🔧 配置live-boot..."

# 创建live-boot配置
mkdir -p /etc/live/boot
cat > /etc/live/boot.conf << 'LIVE_BOOT'
LIVE_BOOT=live-boot
LIVE_MEDIA=cdrom
BOOT_OPTIONS="boot=live components"
LIVE_BOOT

# 配置initramfs模块
cat > /etc/initramfs-tools/modules << 'MODULES'
loop
squashfs
overlay
fat
vfat
iso9660
udf
ext4
ahci
sd_mod
MODULES

# === 生成initramfs ===
echo "🔄 生成initramfs..."

# 生成initramfs
update-initramfs -c -k all 2>/dev/null || true

# 确保必要的文件存在
if [ ! -f /boot/vmlinuz ]; then
    # 查找并复制内核
    KERNEL_SRC=$(find /boot -name "vmlinuz-*" -type f 2>/dev/null | head -1)
    if [ -n "$KERNEL_SRC" ]; then
        cp "$KERNEL_SRC" /boot/vmlinuz
    fi
fi

if [ ! -f /boot/initrd.img ]; then
    # 查找并复制initrd
    INITRD_SRC=$(find /boot -name "initrd.img-*" -type f 2>/dev/null | head -1)
    if [ -n "$INITRD_SRC" ]; then
        cp "$INITRD_SRC" /boot/initrd.img
    fi
fi

# 清理
echo "🧹 清理系统..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "✅ chroot配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/install-chroot.sh"

# 挂载必要的文件系统到chroot
log_info "挂载文件系统到chroot..."
mount -t proc proc "${CHROOT_DIR}/proc"
mount -t sysfs sysfs "${CHROOT_DIR}/sys"
mount -o bind /dev "${CHROOT_DIR}/dev"

# 复制resolv.conf
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"

# 在chroot内执行安装脚本
log_info "在chroot内执行安装..."
chroot "${CHROOT_DIR}" /bin/bash -c "/install-chroot.sh"

# 卸载chroot文件系统
log_info "卸载chroot文件系统..."
umount "${CHROOT_DIR}/proc"
umount "${CHROOT_DIR}/sys"
umount "${CHROOT_DIR}/dev"

# 检查内核和initramfs
log_info "检查内核和initramfs..."
KERNEL_FILE="${CHROOT_DIR}/boot/vmlinuz"
if [ ! -f "$KERNEL_FILE" ]; then
    KERNEL_FILE=$(find "${CHROOT_DIR}/boot" -name "vmlinuz-*" -type f 2>/dev/null | head -1)
fi

INITRD_FILE="${CHROOT_DIR}/boot/initrd.img"
if [ ! -f "$INITRD_FILE" ]; then
    INITRD_FILE=$(find "${CHROOT_DIR}/boot" -name "initrd.img-*" -type f 2>/dev/null | head -1)
fi

if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
    log_success "找到内核: $(basename $KERNEL_FILE)"
    cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
else
    log_error "未找到内核文件"
    exit 1
fi

if [ -n "$INITRD_FILE" ] && [ -f "$INITRD_FILE" ]; then
    log_success "找到initrd: $(basename $INITRD_FILE)"
    cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"
else
    log_error "未找到initrd文件"
    exit 1
fi

# 压缩chroot为squashfs
log_info "创建squashfs文件系统..."
if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp gzip \
    -noappend; then
    log_success "squashfs创建成功"
else
    log_error "squashfs创建失败"
    exit 1
fi

# === 创建引导文件 ===
log_info "创建引导配置..."

# 1. ISOLINUX配置
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT linux
TIMEOUT 300
PROMPT 0
LABEL linux
  MENU LABEL ^Install OpenWRT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live quiet
  TEXT HELP
  Install OpenWRT to hard disk
  ENDTEXT
ISOLINUX_CFG

# 2. 复制引导文件
log_info "复制引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || {
    log_warning "找不到isolinux.bin，尝试下载..."
    wget -O "${STAGING_DIR}/isolinux/isolinux.bin" \
        http://mirrors.kernel.org/debian/pool/main/s/syslinux/syslinux-common_6.03+dfsg-5_amd64.deb
    dpkg -x syslinux-common*.deb /tmp/syslinux 2>/dev/null && \
    cp /tmp/syslinux/usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
}

# 复制ldlinux.c32
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 3. GRUB配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live quiet
    initrd /live/initrd
}
GRUB_CFG

# === 创建简单的ISO结构 ===
log_info "创建ISO结构..."

# 创建README
cat > "${STAGING_DIR}/README.txt" << 'README'
OpenWRT Auto Installer ISO
===========================

This ISO will automatically install OpenWRT to your hard disk.

Boot Options:
- Default: Install OpenWRT (auto-boots in 5 seconds)

After booting, the system will automatically start the installer.
Follow the on-screen instructions to select target disk and install.

WARNING: This will erase all data on the target disk!
README

# === 构建ISO镜像 ===
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# 使用简单的xorriso命令
xorriso -as mkisofs \
    -r -J \
    -V "OPENWRT_INSTALL" \
    -o "$ISO_PATH" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    "${STAGING_DIR}"

# 验证ISO
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    log_success "✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: $ISO_PATH"
    echo "  大小: $ISO_SIZE"
    echo ""
    echo "🎉 构建完成！"
    echo ""
    echo "使用说明："
    echo "  1. 刻录到U盘: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress"
    echo "  2. 从U盘启动计算机"
    echo "  3. 系统将自动启动安装程序"
    echo "  4. 按照提示选择磁盘并安装"
    echo ""
else
    log_error "ISO构建失败"
    exit 1
fi

log_success "所有步骤完成！"
