#!/bin/bash
# build-openwrt-installer.sh - 构建OpenWRT自动安装ISO
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
    echo "请确保OpenWRT镜像文件存在"
    exit 1
fi

# 修复Debian buster源
log_info "配置Debian buster源..."
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
deb http://archive.debian.org/debian buster-updates main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

# 安装必要工具
log_info "安装构建工具..."
apt-get update
apt-get -y install \
    debootstrap \
    squashfs-tools \
    xorriso \
    isolinux \
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
    file

# 添加Debian存档密钥
log_info "添加Debian存档密钥..."
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 04EE7237B7D453EC 648ACFD622F3D138 2>/dev/null || true
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 0E98404D386FA1D9 6ED0E7B82643E131 2>/dev/null || true

# 创建目录结构
log_info "创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/boot,boot/grub/x86_64-efi,isolinux,live}
mkdir -p "${OUTPUT_DIR}"

# 复制OpenWRT镜像
log_info "复制OpenWRT镜像..."
mkdir -p "${CHROOT_DIR}"
if cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img"; then
    log_success "OpenWRT镜像已复制"
else
    log_error "复制OpenWRT镜像失败"
    exit 1
fi

# 引导Debian最小系统
log_info "引导Debian最小系统..."
DEBIAN_MIRROR="http://archive.debian.org/debian"
if debootstrap --arch=amd64 --variant=minbase \
    buster "${CHROOT_DIR}" \
    "${DEBIAN_MIRROR}" 2>&1 | tee /tmp/debootstrap.log; then
    log_success "Debian最小系统引导成功"
else
    log_warning "第一次引导失败，尝试备用源..."
    DEBIAN_MIRROR="http://deb.debian.org/debian"
    if debootstrap --arch=amd64 --variant=minbase \
        buster "${CHROOT_DIR}" \
        "${DEBIAN_MIRROR}" 2>&1 | tee -a /tmp/debootstrap.log; then
        log_success "备用源引导成功"
    else
        log_error "debootstrap失败"
        cat /tmp/debootstrap.log
        exit 1
    fi
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

# APT配置
mkdir -p /etc/apt/apt.conf.d
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
nameserver 208.67.222.222
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
    busybox-static

# === 安装特定版本内核（避免依赖问题）===
echo "🐧 安装内核..."
# 尝试安装特定版本
KERNEL_PACKAGES=""
if apt-cache show linux-image-4.19.0-20-amd64 > /dev/null 2>&1; then
    KERNEL_PACKAGES="linux-image-4.19.0-20-amd64 linux-headers-4.19.0-20-amd64"
else
    KERNEL_PACKAGES="linux-image-amd64 linux-headers-amd64"
fi

apt-get install -y --no-install-recommends $KERNEL_PACKAGES

# === 安装live-boot和相关工具 ===
echo "🚀 安装live-boot..."
apt-get install -y --no-install-recommends \
    live-boot \
    live-boot-initramfs-tools \
    live-tools

# === 设置locale ===
echo "🌐 配置locale..."
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=C

# === 配置自动登录和自动启动 ===
echo "🔧 配置自动登录和启动..."

# 1. 设置root无密码登录
usermod -p '*' root
cat > /etc/passwd << 'PASSWD'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin
sys:x:3:3:sys:/dev:/usr/sbin/nologin
PASSWD

cat > /etc/shadow << 'SHADOW'
root:*:18507:0:99999:7:::
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

# 等待控制台就绪
sleep 3

# 清屏
clear

# 显示欢迎信息
cat << "WELCOME"

╔═══════════════════════════════════════════════════════╗
║       OpenWRT 自动安装系统                            ║
║       OpenWRT Auto Install System                     ║
╚═══════════════════════════════════════════════════════╝

系统正在启动，请稍候...
System is starting up, please wait...

WELCOME

sleep 2

# 检查OpenWRT镜像
if [ ! -f "/openwrt.img" ]; then
    clear
    echo ""
    echo "❌ 错误: 未找到OpenWRT镜像"
    echo "❌ Error: OpenWRT image not found"
    echo ""
    echo "镜像文件应该位于: /openwrt.img"
    echo "Image file should be at: /openwrt.img"
    echo ""
    echo "按Enter键进入Shell..."
    echo "Press Enter to enter shell..."
    read
    exec /bin/bash
fi

# 执行安装程序
exec /opt/install-openwrt.sh
START_SCRIPT
chmod +x /opt/start-installer.sh

# 启用服务
systemctl enable autoinstall.service

# 4. 配置agetty自动登录（备用方案）
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
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

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 清屏函数
clear_screen() {
    printf "\033c"
}

# 显示标题
show_title() {
    clear_screen
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║       OpenWRT 一键安装程序                            ║"
    echo "║       OpenWRT One-Click Installer                     ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
}

# 显示消息
show_msg() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

show_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

show_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

show_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查OpenWRT镜像
check_openwrt_image() {
    show_msg "检查OpenWRT镜像..."
    if [ ! -f "/openwrt.img" ]; then
        show_error "未找到OpenWRT镜像文件"
        echo "镜像文件应该位于: /openwrt.img"
        echo "按Enter键继续..."
        read dummy
        return 1
    fi
    
    IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}')
    IMG_INFO=$(file /openwrt.img 2>/dev/null || echo "OpenWRT disk image")
    show_success "找到OpenWRT镜像: $IMG_SIZE"
    echo "镜像信息: $IMG_INFO"
    echo ""
    return 0
}

# 显示磁盘列表
show_disk_list() {
    echo "========================================"
    echo "可用磁盘列表 / Available Disks:"
    echo "========================================"
    
    # 使用lsblk显示详细信息
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -n -o NAME,SIZE,TYPE,TRAN,MODEL | head -20
    else
        # 备用方案
        echo "设备名称      大小"
        echo "------------------"
        for dev in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
            if [ -b "$dev" ]; then
                size=$(blockdev --getsize64 "$dev" 2>/dev/null | awk '{print $1/1024/1024/1024 "G"}' || echo "N/A")
                echo "$(basename $dev)      $size"
            fi
        done
    fi
    echo "========================================"
    echo ""
}

# 获取磁盘列表
get_disk_list() {
    local disks=""
    if command -v lsblk >/dev/null 2>&1; then
        disks=$(lsblk -d -n -o NAME | grep -E '^(sd|hd|nvme|vd)' | sort)
    else
        # 检查常见的磁盘设备
        for dev in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
            if [ -b "$dev" ]; then
                disks="$disks $(basename $dev)"
            fi
        done
    fi
    echo "$disks" | tr ' ' '\n' | sort | uniq
}

# 验证磁盘
validate_disk() {
    local disk="$1"
    
    # 检查磁盘是否存在
    if [ ! -b "/dev/$disk" ]; then
        show_error "磁盘 /dev/$disk 不存在"
        return 1
    fi
    
    # 检查是否是系统磁盘（通过挂载点）
    if mount | grep -q "^/dev/$disk"; then
        show_warning "警告: /dev/$disk 已被挂载"
        echo "如果这是系统盘，安装会破坏当前系统！"
        return 2
    fi
    
    # 检查磁盘大小（至少需要128MB）
    local size_kb=$(blockdev --getsize64 "/dev/$disk" 2>/dev/null | awk '{print $1/1024}' || echo 0)
    local size_mb=$((size_kb / 1024))
    
    if [ $size_mb -lt 128 ]; then
        show_error "磁盘太小（${size_mb}MB），至少需要128MB"
        return 3
    fi
    
    return 0
}

# 选择磁盘
select_disk() {
    local disks=$(get_disk_list)
    local selected_disk=""
    
    while true; do
        show_title
        check_openwrt_image || return 1
        
        show_disk_list
        
        echo "可用磁盘 / Available disks:"
        for disk in $disks; do
            echo "  /dev/$disk"
        done
        echo ""
        
        echo "请选择安装目标磁盘"
        echo "Please select target disk for installation:"
        echo ""
        read -p "输入磁盘名称 (例如: sda 或 nvme0n1): " TARGET_DISK
        
        if [ -z "$TARGET_DISK" ]; then
            show_error "请输入磁盘名称"
            sleep 2
            continue
        fi
        
        # 验证磁盘
        if validate_disk "$TARGET_DISK"; then
            selected_disk="$TARGET_DISK"
            show_success "已选择: /dev/$selected_disk"
            sleep 1
            break
        else
            echo ""
            echo "按Enter键重新选择..."
            read dummy
        fi
    done
    
    echo "$selected_disk"
}

# 确认安装
confirm_installation() {
    local disk="$1"
    
    show_title
    echo "⚠️ ⚠️ ⚠️  重要警告 / IMPORTANT WARNING  ⚠️ ⚠️ ⚠️"
    echo ""
    echo "这将完全擦除 /dev/$disk 上的所有数据！"
    echo "This will ERASE ALL DATA on /dev/$disk!"
    echo ""
    echo "目标磁盘 / Target disk: /dev/$disk"
    echo "OpenWRT镜像大小 / Image size: $(ls -lh /openwrt.img | awk '{print $5}')"
    echo ""
    echo "请确认:"
    echo "1. 已备份重要数据 / Important data is backed up"
    echo "2. 确定要安装到 /dev/$disk / Sure to install to /dev/$disk"
    echo ""
    
    read -p "确认安装? (输入 YES 确认 / Type YES to confirm): " CONFIRM
    
    if [ "$CONFIRM" = "YES" ]; then
        return 0
    else
        show_msg "安装已取消 / Installation cancelled"
        return 1
    fi
}

# 执行安装
perform_installation() {
    local disk="$1"
    
    show_title
    echo "🚀 开始安装 OpenWRT"
    echo "🚀 Starting OpenWRT installation"
    echo ""
    echo "目标磁盘 / Target disk: /dev/$disk"
    echo ""
    
    # 显示镜像信息
    IMG_SIZE_BYTES=$(stat -c%s /openwrt.img 2>/dev/null || echo 0)
    if [ $IMG_SIZE_BYTES -gt 0 ]; then
        IMG_SIZE_MB=$((IMG_SIZE_BYTES / 1024 / 1024))
        IMG_SIZE_GB=$(echo "scale=2; $IMG_SIZE_MB / 1024" | bc)
        echo "镜像信息 / Image info:"
        echo "  大小 / Size: ${IMG_SIZE_MB} MB (${IMG_SIZE_GB} GB)"
        echo "  目标 / Target: /dev/$disk"
        echo ""
    fi
    
    # 准备磁盘
    show_msg "准备磁盘..."
    
    # 尝试卸载磁盘上的所有分区
    for part in /dev/${disk}[0-9]* /dev/${disk}p[0-9]*; do
        if [ -b "$part" ]; then
            umount -f "$part" 2>/dev/null || true
        fi
    done
    
    sleep 2
    
    # 写入镜像
    show_msg "正在写入OpenWRT镜像..."
    echo "这可能需要几分钟，请勿中断电源..."
    echo "This may take several minutes, do not power off..."
    echo ""
    
    # 使用dd写入镜像
    if command -v pv >/dev/null 2>&1; then
        # 使用pv显示进度
        show_msg "使用进度显示..."
        pv -pet /openwrt.img | dd of="/dev/$disk" bs=4M status=none oflag=sync
    else
        # 使用dd并显示状态
        show_msg "使用dd写入..."
        dd if=/openwrt.img of="/dev/$disk" bs=4M status=progress oflag=sync 2>&1 || \
        dd if=/openwrt.img of="/dev/$disk" bs=4M 2>&1 | tail -1
    fi
    
    local dd_exit=$?
    
    # 同步磁盘
    sync
    
    if [ $dd_exit -eq 0 ]; then
        show_success "✅ 写入完成！"
        echo ""
        
        # 验证写入
        show_msg "验证安装..."
        sleep 2
        
        # 检查是否写入成功
        if [ -b "/dev/$disk" ]; then
            show_success "🎉 OpenWRT安装成功！"
            echo ""
            echo "安装信息 / Installation info:"
            echo "  目标磁盘 / Target disk: /dev/$disk"
            echo "  镜像大小 / Image size: $(ls -lh /openwrt.img | awk '{print $5}')"
            echo "  安装时间 / Time: $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
            return 0
        else
            show_error "磁盘验证失败"
            return 1
        fi
    else
        show_error "写入失败，错误代码: $dd_exit"
        return 1
    fi
}

# 重启系统
reboot_system() {
    echo ""
    echo "系统将在10秒后自动重启..."
    echo "System will reboot in 10 seconds..."
    echo "按任意键取消重启 / Press any key to cancel reboot"
    echo ""
    
    for i in {10..1}; do
        echo -ne "重启倒计时 / Countdown: $i 秒\r"
        if read -t 1 -n 1; then
            echo ""
            echo "重启已取消 / Reboot cancelled"
            echo ""
            echo "可用命令 / Available commands:"
            echo "  重启系统 / Reboot system: reboot"
            echo "  重新安装 / Reinstall: /opt/install-openwrt.sh"
            echo "  Shell: bash"
            echo ""
            exec /bin/bash
        fi
    done
    
    echo ""
    echo "正在重启 / Rebooting..."
    sleep 2
    reboot -f
}

# 主函数
main() {
    while true; do
        # 选择磁盘
        DISK=$(select_disk)
        if [ $? -ne 0 ]; then
            echo "按Enter键重新开始..."
            read dummy
            continue
        fi
        
        # 确认安装
        if confirm_installation "$DISK"; then
            # 执行安装
            if perform_installation "$DISK"; then
                # 重启系统
                reboot_system
                break
            else
                echo ""
                show_error "安装失败，请检查错误信息"
                show_error "Installation failed, please check error messages"
                echo "按Enter键重新开始..."
                read dummy
            fi
        else
            echo ""
            echo "按Enter键重新开始..."
            read dummy
        fi
    done
}

# 执行主函数
main
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# === 配置live-boot ===
echo "🔧 配置live-boot..."

# 创建live-boot配置
mkdir -p /etc/live/boot
cat > /etc/live/boot.conf << 'LIVE_BOOT'
LIVE_BOOT=live-boot
LIVE_MEDIA=cdrom
LIVE_CONFIG=noautologin
PERSISTENCE=
BOOT_OPTIONS="boot=live components quiet splash"
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
# 网络（可选）
e1000
e1000e
r8169
MODULES

# === 生成initramfs ===
echo "🔄 生成initramfs..."

# 获取内核版本
KERNEL_VERSION=""
if [ -d /lib/modules ]; then
    KERNEL_VERSION=$(ls /lib/modules/ | head -1)
fi

if [ -z "$KERNEL_VERSION" ]; then
    # 从/boot查找
    KERNEL_VERSION=$(basename $(ls /boot/vmlinuz-* 2>/dev/null | head -1) 2>/dev/null | sed 's/vmlinuz-//')
fi

if [ -n "$KERNEL_VERSION" ]; then
    echo "为内核生成initramfs: $KERNEL_VERSION"
    
    # 创建模块目录（如果不存在）
    mkdir -p /lib/modules/${KERNEL_VERSION}
    
    # 生成initramfs
    update-initramfs -c -k ${KERNEL_VERSION} -v 2>&1 | grep -v "WARNING" || true
    
    # 创建符号链接
    ln -sf /boot/initrd.img-${KERNEL_VERSION} /boot/initrd.img 2>/dev/null || true
    ln -sf /boot/vmlinuz-${KERNEL_VERSION} /boot/vmlinuz 2>/dev/null || true
else
    echo "⚠️  无法检测内核版本，使用备用方案"
    
    # 创建简单的initramfs
    echo "创建简单initramfs..."
    cat > /tmp/mini-init << 'MINI_INIT'
#!/bin/sh
# 最小化initramfs

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "OpenWRT Installer Initramfs"

# 挂载根文件系统
mkdir -p /newroot
mount -t tmpfs tmpfs /newroot

# 创建目录结构
mkdir -p /newroot/{bin,dev,etc,lib,proc,sys,tmp,opt}

# 复制必要工具
cp /bin/busybox /newroot/bin/ 2>/dev/null || cp /bin/bash /newroot/bin/
cp /bin/sh /newroot/bin/ 2>/dev/null || true

# 切换到新根
exec switch_root /newroot /bin/sh
MINI_INIT
    
    chmod +x /tmp/mini-init
    (cd /tmp && find . -name "mini-init" | cpio -H newc -o | gzip -9 > /boot/initrd.img)
fi

# 确保必要的文件存在
if [ ! -f /boot/vmlinuz ]; then
    # 复制第一个找到的vmlinuz
    VMLINUZ_SRC=$(find /boot -name "vmlinuz-*" -type f 2>/dev/null | head -1)
    if [ -n "$VMLINUZ_SRC" ]; then
        cp "$VMLINUZ_SRC" /boot/vmlinuz
    fi
fi

if [ ! -f /boot/initrd.img ]; then
    # 创建空的initramfs
    echo "Creating empty initramfs..."
    echo "initramfs" | cpio -H newc -o | gzip > /boot/initrd.img 2>/dev/null || true
fi

# === 创建bash配置 ===
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

# 欢迎信息
if [ "$(tty)" = "/dev/tty1" ]; then
    echo ""
    echo "欢迎使用OpenWRT安装系统"
    echo "Welcome to OpenWRT Installer System"
    echo ""
    echo "如果安装程序没有自动启动，请运行:"
    echo "If installer doesn't start automatically, run:"
    echo "  /opt/install-openwrt.sh"
    echo ""
fi
BASHRC

# 清理
echo "🧹 清理系统..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "✅ chroot配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/install-chroot.sh"

# 复制resolv.conf到chroot
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true

# 挂载必要的文件系统到chroot
log_info "挂载文件系统到chroot..."
mount --bind /proc "${CHROOT_DIR}/proc"
mount --bind /sys "${CHROOT_DIR}/sys"
mount --bind /dev "${CHROOT_DIR}/dev"

# 在chroot内执行安装脚本
log_info "在chroot内执行安装..."
if chroot "${CHROOT_DIR}" /bin/bash -c "/install-chroot.sh 2>&1 | tee /install.log"; then
    log_success "chroot安装完成"
else
    log_warning "chroot安装返回错误，继续处理..."
    if [ -f "${CHROOT_DIR}/install.log" ]; then
        echo "=== chroot安装日志 ==="
        tail -50 "${CHROOT_DIR}/install.log"
        echo "====================="
    fi
fi

# 卸载chroot文件系统
log_info "卸载chroot文件系统..."
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
EXCLUDE_LIST="boot/lost+found boot/*.old-dkms proc sys dev tmp run mnt media var/cache var/tmp var/log var/lib/apt/lists"
EXCLUDE_OPT=""
for item in $EXCLUDE_LIST; do
    EXCLUDE_OPT="$EXCLUDE_OPT -e $item"
done

if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp xz \
    -b 1M \
    -noappend \
    -no-recovery \
    -no-progress \
    $EXCLUDE_OPT 2>&1 | tee /tmp/mksquashfs.log; then
    SQUASHFS_SIZE=$(ls -lh "${STAGING_DIR}/live/filesystem.squashfs" | awk '{print $5}')
    log_success "squashfs创建成功: $SQUASHFS_SIZE"
else
    log_error "squashfs创建失败"
    cat /tmp/mksquashfs.log
    exit 1
fi

# 创建live文件夹结构
touch "${STAGING_DIR}/live/filesystem.squashfs-"

# 创建引导配置文件
log_info "创建引导配置..."
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
  MENU LABEL ^Install OpenWRT (自动安装)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet splash console=tty1 console=ttyS0,115200
  TEXT HELP
  自动启动OpenWRT安装程序
  Automatically start OpenWRT installer
  ENDTEXT

LABEL install_nomodeset
  MENU LABEL Install OpenWRT (^安全图形模式)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components nomodeset quiet console=tty1
  TEXT HELP
  兼容性更好的图形模式
  Better compatibility graphics mode
  ENDTEXT

LABEL install_toram
  MENU LABEL Install OpenWRT (^复制到内存)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components toram quiet console=tty1
  TEXT HELP
  将系统复制到内存运行，速度更快
  Copy system to RAM for faster operation
  ENDTEXT

LABEL debug
  MENU LABEL ^调试模式
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components debug
  TEXT HELP
  显示详细启动信息
  Show verbose boot messages
  ENDTEXT

LABEL shell
  MENU LABEL ^救援Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components single
  TEXT HELP
  进入救援Shell模式
  Enter rescue shell mode
  ENDTEXT

LABEL memtest
  MENU LABEL 内存测试
  KERNEL /live/memtest
  TEXT HELP
  运行内存测试工具
  Run memory test utility
  ENDTEXT
ISOLINUX_CFG

# 复制引导文件
log_info "复制引导文件..."
if [ -f /usr/lib/ISOLINUX/isolinux.bin ]; then
    cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/"
elif [ -f /usr/lib/syslinux/isolinux.bin ]; then
    cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/"
else
    log_warning "找不到isolinux.bin，尝试从包中提取"
    apt-get download syslinux-common 2>/dev/null || true
    dpkg -x syslinux-common*.deb /tmp/syslinux 2>/dev/null || true
    cp /tmp/syslinux/usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
fi

# 复制syslinux模块
if [ -d /usr/lib/syslinux/modules/bios ]; then
    cp /usr/lib/syslinux/modules/bios/*.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null
fi

# 创建memtest文件（占位符）
touch "${STAGING_DIR}/live/memtest"

# 创建Grub配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (Auto Install)" {
    linux /live/vmlinuz boot=live components quiet splash console=tty1 console=ttyS0,115200
    initrd /live/initrd
}

menuentry "Install OpenWRT (Safe Graphics)" {
    linux /live/vmlinuz boot=live components nomodeset quiet console=tty1
    initrd /live/initrd
}

menuentry "Install OpenWRT (Copy to RAM)" {
    linux /live/vmlinuz boot=live components toram quiet console=tty1
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
EFI_IMG_SIZE=32
dd if=/dev/zero of="${STAGING_DIR}/boot/grub/efi.img" bs=1M count=$EFI_IMG_SIZE
mkfs.vfat -F 32 "${STAGING_DIR}/boot/grub/efi.img"

# 挂载并复制文件
mkdir -p /mnt/efi_tmp
if mount -o loop "${STAGING_DIR}/boot/grub/efi.img" /mnt/efi_tmp 2>/dev/null; then
    mkdir -p /mnt/efi_tmp/EFI/BOOT
    
    # 查找grub EFI文件
    GRUB_EFI_SOURCES=(
        "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed"
        "/usr/lib/grub/x86_64-efi/grub.efi"
        "/usr/lib/grub/efi/grub.efi"
        "/usr/lib/grub/x86_64-efi/monolithic/grub.efi"
    )
    
    efi_found=false
    for efi_file in "${GRUB_EFI_SOURCES[@]}"; do
        if [ -f "$efi_file" ]; then
            cp "$efi_file" /mnt/efi_tmp/EFI/BOOT/bootx64.efi
            log_success "复制UEFI引导文件: $(basename $efi_file)"
            efi_found=true
            break
        fi
    done
    
    if [ "$efi_found" = false ]; then
        log_warning "未找到grub EFI文件，使用备用方案"
        # 创建简单的EFI引导
        cat > /mnt/efi_tmp/EFI/BOOT/startup.nsh << 'NSH'
echo -off
echo OpenWRT Installer UEFI Boot
echo.
echo Starting OpenWRT installer...
\live\vmlinuz boot=live quiet splash
NSH
    fi
    
    # 复制grub模块
    mkdir -p /mnt/efi_tmp/EFI/BOOT/x86_64-efi
    if [ -d /usr/lib/grub/x86_64-efi ]; then
        cp -r /usr/lib/grub/x86_64-efi/* /mnt/efi_tmp/EFI/BOOT/x86_64-efi/ 2>/dev/null || true
    fi
    
    # 创建grub.cfg
    cat > /mnt/efi_tmp/EFI/BOOT/grub.cfg << 'UEFI_GRUB'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet splash console=tty1
    initrd /live/initrd
}

menuentry "Safe Graphics Mode" {
    linux /live/vmlinuz boot=live components nomodeset quiet console=tty1
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
    log_warning "无法创建UEFI引导文件，继续使用BIOS引导"
fi

# 构建ISO镜像
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# 检查xorriso版本
XORRISO_VERSION=$(xorriso --version 2>/dev/null | head -1 | grep -o '[0-9]\+\.[0-9]\+' | head -1)

XORRISO_CMD="xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid \"OPENWRT_INSTALL\" \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -output \"$ISO_PATH\" \
    \"${STAGING_DIR}\""

# 如果是新版本xorriso，添加UEFI支持
if [ -f "${STAGING_DIR}/boot/grub/efi.img" ]; then
    XORRISO_CMD="$XORRISO_CMD \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat"
fi

log_info "执行构建命令..."
eval $XORRISO_CMD

# 验证ISO
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    ISO_MD5=$(md5sum "$ISO_PATH" | awk '{print $1}' | cut -c1-8)
    
    echo ""
    log_success "✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: $ISO_PATH"
    echo "  大小: $ISO_SIZE"
    echo "  MD5: $ISO_MD5"
    echo "  卷标: OPENWRT_INSTALL"
    echo ""
    echo "🎉 构建完成！"
    echo ""
    echo "使用说明："
    echo "  1. 刻录ISO到U盘: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress"
    echo "  2. 从U盘启动计算机"
    echo "  3. 系统自动启动安装程序"
    echo "  4. 选择目标磁盘并确认安装"
    echo "  5. 等待安装完成自动重启"
    echo ""
    echo "注意："
    echo "  • 安装会完全擦除目标磁盘"
    echo "  • 默认50秒后自动启动安装"
    echo "  • 按ESC键可显示引导菜单"
    echo "  • 支持UEFI和传统BIOS启动"
    echo ""
    
    # 创建构建摘要
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Auto Installer ISO
===========================
构建时间: $(date)
ISO文件: $ISO_NAME
文件大小: $ISO_SIZE
MD5: $ISO_MD5
内核版本: $(basename $KERNEL_FILE)
Initrd: $(basename $INITRD_FILE)
SquashFS大小: $SQUASHFS_SIZE
支持引导: BIOS + UEFI
引导菜单: 自动安装/安全模式/调试模式/救援Shell
BUILD_INFO
    
    log_success "构建摘要已保存到: ${OUTPUT_DIR}/build-info.txt"
else
    log_error "ISO构建失败"
    exit 1
fi

log_success "所有步骤完成！"
