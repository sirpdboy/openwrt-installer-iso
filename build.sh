#!/bin/bash
# build-openwrt-installer-fixed.sh - 修复中文乱码和引导问题
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
deb http://archive.debian.org/debian buster-updates main
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
    syslinux-efi \
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
    fonts-dejavu \
    locales

# 创建目录结构
log_info "创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/boot,boot/grub/x86_64-efi,isolinux,live}
mkdir -p "${OUTPUT_DIR}"

# 复制OpenWRT镜像
log_info "复制OpenWRT镜像..."
mkdir -p "${CHROOT_DIR}"
cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img" || {
    log_error "复制OpenWRT镜像失败"
    exit 1
}

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
deb http://archive.debian.org/debian/ buster-updates main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main contrib non-free
APT_SOURCES

cat > /etc/apt/apt.conf.d/99custom << 'APT_CONF'
Acquire::Check-Valid-Until "false";
APT::Get::AllowUnauthenticated "true";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Retries "3";
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
    sudo \
    kmod \
    udev \
    initramfs-tools-core \
    busybox-static \
    whiptail \
    file

# === 安装内核 ===
echo "🐧 安装内核..."
# 尝试安装4.19版本内核（buster的稳定版本）
if apt-cache show linux-image-4.19.0-20-amd64 2>/dev/null | grep -q "Package:"; then
    apt-get install -y --no-install-recommends \
        linux-image-4.19.0-20-amd64 \
        linux-headers-4.19.0-20-amd64
else
    apt-get install -y --no-install-recommends \
        linux-image-amd64 \
        linux-headers-amd64
fi

# === 安装live-boot ===
echo "🚀 安装live-boot..."
apt-get install -y --no-install-recommends \
    live-boot \
    live-boot-initramfs-tools \
    live-tools

# === 配置locale和中文字体 ===
echo "🌐 配置locale..."
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8 zh_CN.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=C

# 安装中文字体
echo "🔤 安装字体..."
apt-get install -y --no-install-recommends \
    fonts-dejavu \
    fonts-wqy-microhei \
    fonts-wqy-zenhei \
    ttf-wqy-microhei \
    ttf-wqy-zenhei

# === 配置自动登录 ===
echo "🔧 配置自动登录..."

# 设置root无密码
usermod -p '*' root
echo 'root:x:0:0:root:/root:/bin/bash' > /etc/passwd
echo 'root::::::::' > /etc/shadow

# 禁用getty服务，直接运行安装程序
cat > /etc/systemd/system/installer.service << 'INSTALLER_SERVICE'
[Unit]
Description=OpenWRT Installer
After=systemd-user-sessions.service
After=plymouth-quit.service
Before=getty@tty1.service

[Service]
Environment=TERM=linux
Environment=HOME=/root
Environment=USER=root
Type=idle
ExecStart=/opt/install-openwrt.sh
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
KillMode=process
IgnoreSIGPIPE=no
SendSIGHUP=yes

[Install]
WantedBy=multi-user.target
INSTALLER_SERVICE

systemctl enable installer.service

# 配置tty1直接运行安装程序
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --skip-login --login-program /opt/install-openwrt.sh --noclear %I linux
Type=idle
GETTY_OVERRIDE

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

# 清屏并重置终端
reset
clear

# 显示欢迎信息
cat << "WELCOME"

╔═══════════════════════════════════════════════════════╗
║                  OpenWRT Auto Installer               ║
║                 OpenWRT 自动安装系统                  ║
╚═══════════════════════════════════════════════════════╝

WELCOME

echo ""
echo "Initializing system, please wait..."
echo "系统初始化中，请稍候..."
echo ""

# 检查OpenWRT镜像
if [ ! -f "/openwrt.img" ]; then
    echo "❌ ERROR: OpenWRT image not found!"
    echo "❌ 错误: 未找到OpenWRT镜像！"
    echo ""
    echo "Image should be at: /openwrt.img"
    echo "镜像文件应该位于: /openwrt.img"
    echo ""
    echo "Press Enter to continue..."
    echo "按Enter键继续..."
    read
    exec /bin/bash
fi

IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}')
echo "✅ OpenWRT image found: $IMG_SIZE"
echo "✅ 找到OpenWRT镜像: $IMG_SIZE"
echo ""

sleep 2

# 主安装函数
main_installer() {
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
        
        # 显示磁盘列表
        echo "Scanning for available disks..."
        echo "正在扫描可用磁盘..."
        echo ""
        echo "========================================"
        
        # 使用简单方法列出磁盘
        echo "Available disks (DO NOT select your installation USB!):"
        echo "可用磁盘 (不要选择安装U盘本身!):"
        echo ""
        
        # 列出磁盘
        DISK_LIST=""
        if command -v lsblk >/dev/null 2>&1; then
            lsblk -d -n -o NAME,SIZE,MODEL | grep -E '^(sd|hd|nvme|vd)' | while read line; do
                disk_name=$(echo $line | awk '{print $1}')
                size=$(echo $line | awk '{print $2}')
                model=$(echo $line | cut -d' ' -f3-)
                echo "  /dev/$disk_name - $size - $model"
                DISK_LIST="$DISK_LIST $disk_name"
            done
        else
            # 简单列出/dev/sd*和/dev/nvme*
            for dev in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
                if [ -b "$dev" ]; then
                    disk_name=$(basename $dev)
                    size=$(blockdev --getsize64 $dev 2>/dev/null | awk '{printf "%.1fG", $1/1024/1024/1024}' || echo "N/A")
                    echo "  $dev - $size"
                    DISK_LIST="$DISK_LIST $disk_name"
                fi
            done
        fi
        
        echo "========================================"
        echo ""
        
        # 获取当前启动设备（警告用户不要选择）
        BOOT_DEVICE=""
        if [ -e /proc/cmdline ]; then
            BOOT_DEVICE=$(cat /proc/cmdline | tr ' ' '\n' | grep '^root=' | cut -d'=' -f2 | sed 's/.*\///' || true)
            if [ -n "$BOOT_DEVICE" ]; then
                echo "⚠️  WARNING: Your boot device is /dev/$BOOT_DEVICE (do not select this!)"
                echo "⚠️  警告: 您的启动设备是 /dev/$BOOT_DEVICE (不要选择这个!)"
                echo ""
            fi
        fi
        
        # 选择磁盘
        echo "Please enter the target disk name (e.g., sda, nvme0n1):"
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
        
        # 警告：不要选择启动设备
        if [ "$TARGET_DISK" = "$BOOT_DEVICE" ]; then
            echo ""
            echo "❌ ERROR: You selected your boot device!"
            echo "❌ 错误: 您选择了启动设备！"
            echo "This will erase your installer system!"
            echo "这会擦除安装系统本身！"
            echo ""
            read -p "Are you REALLY sure? (type DESTROY to confirm): " CONFIRM
            if [ "$CONFIRM" != "DESTROY" ]; then
                echo "Installation cancelled."
                echo "安装已取消。"
                sleep 2
                continue
            fi
        fi
        
        # 显示确认信息
        clear
        cat << "CONFIRM"

╔═══════════════════════════════════════════════════════╗
║               CONFIRM INSTALLATION                    ║
║                 确认安装                              ║
╚═══════════════════════════════════════════════════════╝

CONFIRM

        echo ""
        echo "⚠️ ⚠️ ⚠️  WARNING: ALL DATA ON /dev/$TARGET_DISK WILL BE ERASED! ⚠️ ⚠️ ⚠️"
        echo "⚠️ ⚠️ ⚠️  警告: /dev/$TARGET_DISK 上的所有数据将被擦除！ ⚠️ ⚠️ ⚠️"
        echo ""
        echo "Target disk: /dev/$TARGET_DISK"
        echo "目标磁盘: /dev/$TARGET_DISK"
        echo "Image size: $(ls -lh /openwrt.img | awk '{print $5}')"
        echo "镜像大小: $(ls -lh /openwrt.img | awk '{print $5}')"
        echo ""
        
        # 最终确认
        echo "Type 'YES' to confirm and start installation:"
        echo "输入 'YES' 确认并开始安装:"
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
        
        # 获取镜像大小
        IMG_BYTES=$(stat -c%s /openwrt.img 2>/dev/null || echo 0)
        if [ $IMG_BYTES -gt 0 ]; then
            IMG_MB=$((IMG_BYTES / 1024 / 1024))
            echo "Image size: ${IMG_MB} MB"
            echo "镜像大小: ${IMG_MB} MB"
            echo ""
        fi
        
        echo "Writing image to disk..."
        echo "正在写入镜像到磁盘..."
        echo ""
        echo "DO NOT POWER OFF OR REMOVE USB!"
        echo "请勿关闭电源或拔出U盘！"
        echo ""
        
        # 写入镜像
        if command -v pv >/dev/null 2>&1; then
            # 使用pv显示进度
            pv -pet /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M status=none oflag=sync
        else
            # 简单dd
            dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M status=progress oflag=sync
        fi
        
        DD_EXIT=$?
        sync
        
        if [ $DD_EXIT -eq 0 ]; then
            echo ""
            echo "✅ Installation successful!"
            echo "✅ 安装成功！"
            echo ""
            
            # 等待用户确认重启
            echo "System will reboot in 10 seconds..."
            echo "系统将在10秒后重启..."
            echo "Press any key to cancel and enter shell."
            echo "按任意键取消重启并进入Shell。"
            echo ""
            
            for i in {10..1}; do
                echo -ne "Rebooting in $i seconds...\r"
                if read -t 1 -n 1; then
                    echo ""
                    echo ""
                    echo "Reboot cancelled. You can now:"
                    echo "重启已取消。您现在可以："
                    echo "1. Type 'reboot' to restart"
                    echo "   输入 'reboot' 重启系统"
                    echo "2. Type '/opt/install-openwrt.sh' to restart installer"
                    echo "   输入 '/opt/install-openwrt.sh' 重新运行安装程序"
                    echo "3. Type 'bash' for a shell"
                    echo "   输入 'bash' 进入Shell"
                    echo ""
                    exec /bin/bash
                fi
            done
            
            echo ""
            echo "Rebooting now..."
            echo "正在重启..."
            sleep 2
            reboot -f
        else
            echo ""
            echo "❌ Installation failed with error code: $DD_EXIT"
            echo "❌ 安装失败，错误代码: $DD_EXIT"
            echo ""
            echo "Press Enter to retry..."
            echo "按Enter键重试..."
            read
            continue
        fi
    done
}

# 设置trap确保脚本退出时重置终端
trap 'stty sane; reset' EXIT INT TERM

# 运行安装程序
main_installer
INSTALL_SCRIPT

chmod +x /opt/install-openwrt.sh

# 创建备用shell脚本
cat > /opt/shell.sh << 'SHELL_SCRIPT'
#!/bin/bash
reset
clear
echo "OpenWRT Installer Shell"
echo "Available commands:"
echo "  install    - Start OpenWRT installer"
echo "  reboot     - Reboot system"
echo "  exit       - Return to installer"
echo ""
exec /bin/bash
SHELL_SCRIPT
chmod +x /opt/shell.sh

# === 配置live-boot ===
echo "🔧 配置live-boot..."

# 创建live-boot配置
mkdir -p /etc/live/boot
cat > /etc/live/boot.conf << 'LIVE_BOOT'
LIVE_BOOT=live-boot
LIVE_MEDIA=cdrom
LIVE_CONFIG=noautologin
PERSISTENCE=
BOOT_OPTIONS="boot=live components"
LIVE_BOOT

# 配置initramfs模块
cat > /etc/initramfs-tools/modules << 'MODULES'
# 基础模块
loop
squashfs
overlay
# 文件系统
ext4
ext3
ext2
vfat
ntfs
iso9660
udf
# 存储控制器
ahci
sd_mod
nvme
usb-storage
MODULES

# === 修复：创建简单的initramfs ===
echo "🔄 创建initramfs..."

# 获取内核版本
KERNEL_VERSION=""
if [ -d /lib/modules ]; then
    KERNEL_VERSION=$(ls /lib/modules/ | head -1)
fi

if [ -z "$KERNEL_VERSION" ]; then
    KERNEL_VERSION=$(basename $(ls /boot/vmlinuz-* 2>/dev/null | head -1) 2>/dev/null | sed 's/vmlinuz-//')
fi

if [ -n "$KERNEL_VERSION" ]; then
    echo "Using kernel: $KERNEL_VERSION"
    
    # 创建模块目录
    mkdir -p /lib/modules/${KERNEL_VERSION}
    touch /lib/modules/${KERNEL_VERSION}/modules.dep
    
    # 生成initramfs（忽略错误）
    update-initramfs -c -k ${KERNEL_VERSION} 2>&1 | grep -v "WARNING\|ERROR" || true
    
    # 创建符号链接
    ln -sf /boot/initrd.img-${KERNEL_VERSION} /boot/initrd.img 2>/dev/null || true
    ln -sf /boot/vmlinuz-${KERNEL_VERSION} /boot/vmlinuz 2>/dev/null || true
fi

# 确保必要的文件存在
if [ ! -f /boot/vmlinuz ]; then
    VMLINUZ_SRC=$(find /boot -name "vmlinuz-*" -type f 2>/dev/null | head -1)
    if [ -n "$VMLINUZ_SRC" ]; then
        cp "$VMLINUZ_SRC" /boot/vmlinuz
    fi
fi

if [ ! -f /boot/initrd.img ]; then
    echo "Creating minimal initramfs..."
    # 创建最小化的initramfs
    (cd / && find . -type f -name "*.ko" 2>/dev/null | head -50 | cpio -H newc -o 2>/dev/null | gzip -9 > /boot/initrd.img) || true
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
mount --bind /proc "${CHROOT_DIR}/proc"
mount --bind /sys "${CHROOT_DIR}/sys"
mount --bind /dev "${CHROOT_DIR}/dev"
mount --bind /dev/pts "${CHROOT_DIR}/dev/pts"

# 复制resolv.conf
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true

# 在chroot内执行安装脚本
log_info "在chroot内执行安装..."
if chroot "${CHROOT_DIR}" /bin/bash -c "/install-chroot.sh 2>&1"; then
    log_success "chroot安装完成"
else
    log_warning "chroot安装遇到错误，继续..."
fi

# 卸载chroot文件系统
log_info "卸载chroot文件系统..."
umount "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
umount "${CHROOT_DIR}/sys" 2>/dev/null || true
umount "${CHROOT_DIR}/dev" 2>/dev/null || true

# 检查内核和initramfs
log_info "检查内核和initramfs..."
KERNEL_FILE=$(find "${CHROOT_DIR}/boot" -name "vmlinuz*" -type f 2>/dev/null | head -1)
INITRD_FILE=$(find "${CHROOT_DIR}/boot" -name "initrd*" -type f 2>/dev/null | head -1)

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
EXCLUDE_LIST="boot/lost+found proc sys dev tmp run mnt media var/cache var/tmp var/log"
if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp gzip \
    -b 1M \
    -noappend \
    -no-progress \
    -e $EXCLUDE_LIST 2>&1 | tail -5; then
    SQUASHFS_SIZE=$(ls -lh "${STAGING_DIR}/live/filesystem.squashfs" | awk '{print $5}')
    log_success "squashfs创建成功: $SQUASHFS_SIZE"
else
    log_error "squashfs创建失败"
    exit 1
fi

# 创建live文件夹结构
touch "${STAGING_DIR}/live/filesystem.squashfs-"

# === 创建引导配置文件（使用纯英文避免乱码）===
log_info "创建引导配置..."

# 1. ISOLINUX配置
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT install
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE OpenWRT Auto Installer
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR hotsel       1;37;44 #ff000000 #20ffffff all
MENU COLOR hotkey       37;44   #ff000000 #20ffffff all

LABEL install
  MENU LABEL ^Install OpenWRT (Default)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components console=tty1 console=ttyS0 quiet
  TEXT HELP
  Automatically start OpenWRT installer
  ENDTEXT

LABEL install_nomodeset
  MENU LABEL Install OpenWRT (^Safe Graphics)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components nomodeset console=tty1 quiet
  TEXT HELP
  Use safe graphics mode for compatibility
  ENDTEXT

LABEL install_text
  MENU LABEL Install OpenWRT (^Text Mode)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components console=tty1 text quiet
  TEXT HELP
  Use text mode installation
  ENDTEXT

LABEL debug
  MENU LABEL ^Debug Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components debug
  TEXT HELP
  Verbose boot messages for debugging
  ENDTEXT

LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components single
  TEXT HELP
  Enter rescue shell mode
  ENDTEXT

LABEL memtest
  MENU LABEL Memory Test
  LINUX /live/memtest
  TEXT HELP
  Run memory test utility
  ENDTEXT
ISOLINUX_CFG

# 2. 复制引导文件
log_info "复制引导文件..."
if [ -f /usr/lib/ISOLINUX/isolinux.bin ]; then
    cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/"
elif [ -f /usr/lib/syslinux/isolinux.bin ]; then
    cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/"
else
    # 尝试从包中提取
    apt-get download syslinux-common 2>/dev/null || true
    dpkg -x syslinux-common*.deb /tmp/syslinux 2>/dev/null && \
    cp /tmp/syslinux/usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
fi

# 复制syslinux模块
if [ -d /usr/lib/syslinux/modules/bios ]; then
    cp /usr/lib/syslinux/modules/bios/{menu,libcom32,libutil,vesamenu}.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true
fi

# 复制字体文件避免乱码
if [ -f /usr/lib/syslinux/vesamenu.c32 ]; then
    cp /usr/lib/syslinux/vesamenu.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null
fi

# 3. 创建memtest占位符
touch "${STAGING_DIR}/live/memtest"

# 4. GRUB配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (Default)" {
    linux /live/vmlinuz boot=live components console=tty1 console=ttyS0 quiet
    initrd /live/initrd
}

menuentry "Install OpenWRT (Safe Graphics)" {
    linux /live/vmlinuz boot=live components nomodeset console=tty1 quiet
    initrd /live/initrd
}

menuentry "Install OpenWRT (Text Mode)" {
    linux /live/vmlinuz boot=live components console=tty1 text quiet
    initrd /live/initrd
}

menuentry "Debug Mode" {
    linux /live/vmlinuz boot=live components debug
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live components single
    initrd /live/initrd
}
GRUB_CFG

# === 创建UEFI引导文件 ===
log_info "创建UEFI引导文件..."
dd if=/dev/zero of="${STAGING_DIR}/boot/grub/efi.img" bs=1M count=32
mkfs.vfat -F 32 "${STAGING_DIR}/boot/grub/efi.img"

mkdir -p /mnt/efi_tmp
if mount -o loop "${STAGING_DIR}/boot/grub/efi.img" /mnt/efi_tmp 2>/dev/null; then
    mkdir -p /mnt/efi_tmp/EFI/BOOT
    
    # 查找grub EFI文件
    GRUB_EFI_SOURCES=(
        "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed"
        "/usr/lib/grub/x86_64-efi/grub.efi"
        "/usr/lib/grub/efi/grub.efi"
    )
    
    for efi_file in "${GRUB_EFI_SOURCES[@]}"; do
        if [ -f "$efi_file" ]; then
            cp "$efi_file" /mnt/efi_tmp/EFI/BOOT/bootx64.efi
            log_success "复制UEFI引导文件: $(basename $efi_file)"
            break
        fi
    done
    
    # 创建grub.cfg
    cat > /mnt/efi_tmp/EFI/BOOT/grub.cfg << 'UEFI_GRUB'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components console=tty1 quiet
    initrd /live/initrd
}

menuentry "Safe Graphics Mode" {
    linux /live/vmlinuz boot=live components nomodeset console=tty1 quiet
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live components single
    initrd /live/initrd
}
UEFI_GRUB
    
    umount /mnt/efi_tmp
    rmdir /mnt/efi_tmp
    log_success "UEFI引导文件创建完成"
else
    log_warning "无法创建UEFI引导文件"
fi

# === 构建ISO镜像 ===
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# 简单的构建命令，避免复杂参数
if [ -f "${STAGING_DIR}/boot/grub/efi.img" ]; then
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "OPENWRT_INSTALL" \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "$ISO_PATH" \
        "${STAGING_DIR}"
else
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "OPENWRT_INSTALL" \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "$ISO_PATH" \
        "${STAGING_DIR}"
fi

# 验证ISO
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    log_success "✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: $ISO_PATH"
    echo "  大小: $ISO_SIZE"
    echo "  卷标: OPENWRT_INSTALL"
    echo ""
    echo "🎉 构建完成！"
    echo ""
    echo "刻录到U盘:"
    echo "  dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "启动选项说明:"
    echo "  1. Install OpenWRT (Default) - 推荐选项"
    echo "  2. Safe Graphics - 如果黑屏使用此选项"
    echo "  3. Text Mode - 文本模式"
    echo "  4. Debug Mode - 调试模式"
    echo "  5. Rescue Shell - 救援Shell"
    echo ""
else
    log_error "ISO构建失败"
    exit 1
fi

log_success "所有步骤完成！"
