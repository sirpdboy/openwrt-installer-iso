#!/bin/bash
# build.sh - OpenWRT ISO构建脚本（在Docker容器内运行） sirpdboy 2025-2026  https://github.com/sirpdboy/openwrt-installer-iso.git
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
apt-get -y install debootstrap squashfs-tools xorriso isolinux syslinux-efi grub-pc-bin grub-efi-amd64-bin grub-efi mtools dosfstools parted pv grub-common grub2-common efibootmgr

# ==================== 步骤2: 创建目录结构 ====================
log_info "[2/10] Creating directory structure..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$CHROOT_DIR"
mkdir -p "$WORK_DIR/tmp"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub/x86_64-efi,isolinux,live}

# ==================== 步骤3: 引导Debian最小系统 ====================
log_info "[3/10] Bootstrapping Debian minimal system..."
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

# ==================== 步骤4: 配置chroot环境 ====================
log_info "[4/10] Configuring chroot environment..."

# 创建chroot配置脚本
cat > "$CHROOT_DIR/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
set -e

echo "🔧 Configuring chroot environment..."


# 禁用systemd日志服务
systemctl mask systemd-journald.service 2>/dev/null || true
systemctl mask systemd-journald.socket 2>/dev/null || true
systemctl mask systemd-journald-dev-log.socket 2>/dev/null || true
systemctl mask syslog.socket 2>/dev/null || true

# 配置journald不输出到控制台
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-quiet.conf << 'JOURNAL_CONF'
[Journal]
Storage=volatile
RuntimeMaxUse=10M
ForwardToConsole=no
ForwardToSyslog=no
MaxLevelStore=err
MaxLevelSyslog=err
MaxLevelConsole=emerg
JOURNAL_CONF

# 禁用timers和其他服务
systemctl mask apt-daily.timer 2>/dev/null || true
systemctl mask apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask systemd-tmpfiles-clean.timer 2>/dev/null || true
systemctl mask logrotate.timer 2>/dev/null || true

# 配置内核参数
cat > /etc/default/grub << 'GRUB_CONF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=0 console=ttyS0 console=tty0 ignore_loglevel systemd.show_status=0 systemd.log_level=err"
GRUB_CMDLINE_LINUX=""
GRUB_CONF

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
apt-get update --no-install-recommends
apt-get -y install apt --no-install-recommends || true
apt-get -y upgrade --no-install-recommends
echo "Setting locale..."
apt-get install -y --no-install-recommends \
    locales \
    fonts-wqy-microhei

# 如果上述失败，尝试备用方案
if [ $? -ne 0 ]; then
    echo "尝试备用字体源..."
    # 下载直接字体文件
    wget -q http://ftp.cn.debian.org/debian/pool/main/f/fonts-wqy-microhei/fonts-wqy-microhei_0.2.0-beta-2_all.deb -O /tmp/wqy.deb
    dpkg -i /tmp/wqy.deb 2>/dev/null || true
    apt-get -f install -y
fi


# 配置locale（强制方法）
cat > /etc/locale.gen << 'LOCALE'
en_US.UTF-8 UTF-8
zh_CN.UTF-8 UTF-8
zh_CN.GBK GBK
LOCALE

# 生成locale
/usr/sbin/locale-gen

# 设置系统范围的语言
cat > /etc/default/locale << 'LOCALE_CONF'
LANG="zh_CN.UTF-8"
LANGUAGE="zh_CN:zh"
LC_ALL="zh_CN.UTF-8"
LC_CTYPE="zh_CN.UTF-8"
LC_MESSAGES="zh_CN.UTF-8"
LOCALE_CONF

# 配置终端
cat > /etc/profile.d/terminal-chinese.sh << 'TERMINAL'
# 终端中文支持
if [ "$TERM" = "linux" ]; then
    # 设置控制台编码
    export LANG=zh_CN.UTF-8
    export LANGUAGE=zh_CN:zh
    
    # 加载中文字体（如果可用）
    if [ -f /usr/share/consolefonts/Uni2-Fixed16.psf.gz ]; then
        loadfont Uni2-Fixed16 2>/dev/null || true
    fi
fi

# 通用设置
export LESSCHARSET=utf-8
alias ll='ls -la --color=auto'
TERMINAL

# 激活配置
. /etc/default/locale
. /etc/profile.d/terminal-chinese.sh





apt-get install -y --no-install-recommends linux-image-amd64 live-boot systemd-sysv 
apt-get install -y --no-install-recommends openssh-server bash-completion dbus dosfstools firmware-linux-free gddrescue iputils-ping isc-dhcp-client less nfs-common open-vm-tools procps wimtools pv grub-efi-amd64-bin dialog whiptail 

    
    
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
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash


clean_system_output() {
    # 1. 停止所有日志服务
    systemctl stop systemd-journald 2>/dev/null || true
    systemctl stop rsyslog 2>/dev/null || true
    systemctl stop syslog 2>/dev/null || true
    
    # 2. 禁用控制台输出
    
    pkill -9 systemd-timesyncd 2>/dev/null || true
    pkill -9 journald 2>/dev/null || true
    echo 0 > /proc/sys/kernel/printk 2>/dev/null || true
    dmesg -n 1 2>/dev/null || true
    
    # 3. 清理屏幕
    clear
    printf "\033c"  # 真正的终端重置
    stty sane 2>/dev/null || true
}

# === 第二步：设置干净的环境 ===
setup_clean_env() {
    # 使用纯英文环境避免乱码
    export LANG=C
    export LC_ALL=C
    export LANGUAGE=en_US
    export TERM=linux
    
    # 简单的ASCII编码
    export LESSCHARSET=ascii
    export MANPAGER=cat
    
    # 清理提示符
    PS1='# '
}

    clean_system_output
    setup_clean_env

# === 中文环境初始化 ===
init_chinese_env() {
    # 检查是否已经设置
    if [ "$LANG" = "zh_CN.UTF-8" ]; then
        return 0
    fi
    
    # 设置环境变量
    export LANG=zh_CN.UTF-8 2>/dev/null || export LANG=C.UTF-8
    export LANGUAGE=zh_CN:zh 2>/dev/null || export LANGUAGE=en_US:en
    export LC_ALL=$LANG
    export LC_CTYPE=$LANG
    export TERM=linux
    
    # 检查字体
    if ! fc-list 2>/dev/null | grep -q -i "wqy\|unifont\|dejavu"; then
        echo "⚠ 未检测到中文字体，使用英文界面"
        USE_ENGLISH=1
    else
        USE_ENGLISH=0
    fi
}

# === 多语言消息函数 ===
t() {
    local key="$1"
    
    if [ "$USE_ENGLISH" = "1" ] || [ "$LANG" != "zh_CN.UTF-8" ]; then
        # 英文消息
        case "$key" in
            "welcome")
                echo "========================================"
                echo "      OpenWRT Auto Installer v1.0"
                echo "========================================"
                ;;
            "select_disk")
                echo "Select disk number (1-\$TOTAL) or 'r' to rescan: "
                ;;
            "rescan")
                echo "Rescanning disks..."
                ;;
            "invalid_selection")
                echo "Invalid selection!"
                ;;
            "selected_disk")
                echo "Selected disk: "
                ;;
            "warning")
                echo "WARNING: This will ERASE ALL data on the disk!"
                ;;
            "confirm")
                echo "Type 'YES' to confirm installation: "
                ;;
            "installing")
                echo "Installing OpenWRT to disk..."
                ;;
            "success")
                echo "Installation completed successfully!"
                ;;
            "reboot")
                echo "System will reboot in 10 seconds..."
                ;;
            *)
                echo "$key"
                ;;
        esac
    else
        # 中文消息（使用base64避免编码问题）
        case "$key" in
            "welcome")
                echo "========================================"
                echo ""
                echo "5Lit5paHIE9wZW5XUlQg6L+Z5Liq5a6J5YWo5a6M5oiQ57O757ufIHYxLjA=" | base64 -d
                echo ""
                echo "========================================"
                ;;
            "select_disk")
                echo "6K+36YWN572u5a6J5YWo5a6M5oiQ57yW56CBICgxLSRUT1RBTCkg5ZKM5Y+RICdyJyDnu5/orqHnlJ/miJD77yM5Zyw5bCG6L+Z5LiqJ3En5LiN6IO96KKr5Y+R6YCB77ya" | base64 -d
                ;;
            "rescan")
                echo "6YeN6KaB6K+35rGC5a6J5YWo5a6M5oiQ5LitLi4u" | base64 -d
                ;;
            "invalid_selection")
                echo "5Y+W5raI5LiN6IO96KKr5Y+R6YCB77yB" | base64 -d
                ;;
            "selected_disk")
                echo "5Y+W5raI5a6J5YWo5a6M5oiQ77ya" | base64 -d
                ;;
            "warning")
                echo "8J+agO+8jOivt+WcqOa1j+iniOWZqOeahOa1i+ivleeCueWHu+S4jeWIsOWPr+iDveaAp++8jA==" | base64 -d
                ;;
            "confirm")
                echo "6K+36YGN5YqgJ1lFUycg6L+Z5qC35o+U5Y+377ya" | base64 -d
                ;;
            "installing")
                echo "5a6J5YWo5Lit5paH5Lmf5Y+R6YCB5a6J5YWo5a6M5oiQ5LitLi4u" | base64 -d
                ;;
            "success")
                echo "5a6J5YWo5Lit5paH5Y+R6YCB5oiQ5Yqf77yB" | base64 -d
                ;;
            "reboot")
                echo "57O757uf5Lit5paH5L2/55SoMTDlj5HmlbTvvIE=" | base64 -d
                ;;
            *)
                echo "$key" | base64 -d 2>/dev/null || echo "$key"
                ;;
        esac
    fi
}

init_chinese_env

clear
# 获取磁盘列表函数
get_disk_list() {

cat << "EOF"

╔═══════════════════════════════════════════════════════╗
║               OpenWRT Auto Installer                  ║
╚═══════════════════════════════════════════════════════╝

EOF

echo -e "\nChecking OpenWRT image..."
if [ ! -f "/openwrt.img" ]; then
    echo -e "\nERROR: OpenWRT image not found!"
    echo -e "\nImage file should be at: /openwrt.img"
    echo -e "\nPress Enter for shell..."
    read
    exec /bin/bash
fi

IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}')
echo -e "OpenWRT image found: $IMG_SIZE\n"

    DISK_LIST=()
    DISK_INDEX=1
    
    echo "Scanning available disks.../ 找到可用磁盘..."
    
    echo -e "==============================================\n"
    # 使用lsblk获取磁盘信息
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            DISK_NAME=$(echo "$line" | awk '{print $1}')
            DISK_SIZE=$(echo "$line" | awk '{print $2}')
            DISK_MODEL=$(echo "$line" | cut -d' ' -f3-)
            
            # 检查是否为有效磁盘（排除CD/DVD）
            if [[ $DISK_NAME =~ ^(sd|hd|nvme|vd) ]]; then
                DISK_LIST[DISK_INDEX]="$DISK_NAME"
                echo "  [$DISK_INDEX] /dev/$DISK_NAME - $DISK_SIZE - $DISK_MODEL"
                ((DISK_INDEX++))
            fi
        fi
    done < <(lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^(sd|hd|nvme|vd)')
    
    TOTAL_DISKS=$((DISK_INDEX - 1))

    echo -e "==============================================\n"
    
}

# 主循环
while true; do
    # 获取磁盘列表
    get_disk_list
    
    
    if [ $TOTAL_DISKS -eq 0 ]; then
        echo -e "\nNo disks detected!"
        echo -e "Please check your storage devices and try again."
	echo ""
        read -p "Press Enter to rescan..." _
        clear
        continue
    fi
    
    # 获取用户选择
    while true; do
        read -p "Select disk number (1-$TOTAL_DISKS) or 'r' to rescan: " SELECTION

        case $SELECTION in
            [Rr])
                get_disk_list
                ;;
            [0-9]*)
                if [[ $SELECTION -ge 1 && $SELECTION -le $TOTAL_DISKS ]]; then
                    TARGET_DISK=${DISK_LIST[$SELECTION]}
                    break 2  # 跳出两层循环，继续安装
                else
                    echo "Invalid selection. Please choose between 1 and $TOTAL_DISKS."
                fi
                ;;
            *)
                echo "Invalid input. Please enter a number or 'r' to rescan."
                ;;
        esac
    done
done

# 确认安装
clear
echo -e "\n══════════════════════════════════════════════════════════"
echo -e "           CONFIRM INSTALLATION"
echo -e "══════════════════════════════════════════════════════════\n"
echo -e "Target disk: /dev/$TARGET_DISK"
echo -e "\n     WARNING: This will ERASE ALL DATA on /dev/$TARGET_DISK!   "
echo -e "\nALL existing partitions and data will be permanently deleted!"
echo -e "\n══════════════════════════════════════════════════════════\n"

while true; do
    read -p "Type 'YES' to continue or 'NO' to cancel: " CONFIRM
    
    case $CONFIRM in
        YES|yes|Y|y)
            echo -e "\nProceeding with installation...\n"
            break
            ;;
        NO|no|N|n)
            echo -e "\nInstallation cancelled."    
	    echo ""
            read -p "Press Enter to return to disk selection..." _
            exec /opt/install-openwrt.sh  # 重新启动安装程序
            ;;
        *)
            echo "Please type 'YES' to confirm or 'NO' to cancel."
            ;;
    esac
done

# 开始安装
clear
echo -e "\n══════════════════════════════════════════════════════════"
echo -e "           INSTALLING OPENWRT"
echo -e "══════════════════════════════════════════════════════════\n"
echo -e "Target: /dev/$TARGET_DISK"
echo -e "Image size: $IMG_SIZE"
echo -e "\nThis may take several minutes. Please wait...\n"
echo -e "══════════════════════════════════════════════════════════\n"

# 显示进度条函数
show_progress() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    
    echo -n "Writing image: ["
    
    # 创建进度条背景
    for ((i=0; i<50; i++)); do
        echo -n " "
    done
    echo -n "]"
    
    # 移动光标到进度条开始位置
    echo -ne "\rWriting image: ["
    
    # 等待dd进程完成并显示进度
    while kill -0 $pid 2>/dev/null; do
        # 获取dd进度（如果可用）
        if kill -USR1 $pid 2>/dev/null; then
            sleep 1
            # 尝试从/proc获取进度信息
            if [ -f "/proc/$pid/io" ]; then
                bytes_written=$(grep "^write_bytes" "/proc/$pid/io" | awk '{print $2}')
                total_bytes=$(ls -l /openwrt.img | awk '{print $5}')
                if [ -n "$bytes_written" ] && [ "$total_bytes" -gt 0 ]; then
                    percentage=$((bytes_written * 100 / total_bytes))
                    if [ $percentage -gt 100 ]; then
                        percentage=100
                    fi
                    
                    # 更新进度条
                    filled=$((percentage / 2))
                    empty=$((50 - filled))
                    
                    echo -ne "\rWriting image: ["
                    for ((i=0; i<filled; i++)); do
                        echo -n "█"
                    done
                    for ((i=0; i<empty; i++)); do
                        echo -n " "
                    done
                    echo -ne "] \n     ${percentage}%"
                fi
            fi
        fi
        sleep 2
    done
    
    # 等待进程完成
    wait $pid
    return $?
}

# 执行安装（禁用所有输出日志）
echo -e "Starting installation process...\n"

# 使用dd写入镜像，禁用所有状态输出
if command -v pv >/dev/null 2>&1; then
    # 使用pv显示进度
    pv -p -t -e -r /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M 2>/dev/null
    DD_EXIT=$?
else
    # 使用静默dd
    dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M 2>/dev/null &
    DD_PID=$!
    
    # 显示自定义进度
    show_progress $DD_PID
    DD_EXIT=$?
fi

# 检查dd结果
if [ $DD_EXIT -eq 0 ]; then
    # 同步磁盘
    sync
    echo -e "\n\nInstallation successful!"
    echo -e "\nOpenWRT has been installed to /dev/$TARGET_DISK"
    
    # 显示安装后信息
    echo -e "\n══════════════════════════════════════════════════════════"
    echo -e "           INSTALLATION COMPLETE"
    echo -e "══════════════════════════════════════════════════════════\n"
    echo -e "Next steps:"
    echo -e "1. Remove the installation media"
    echo -e "2. Boot from the newly installed disk"
    echo -e "3. OpenWRT should start automatically"
    echo -e "\n══════════════════════════════════════════════════════════\n"
    
    # 倒计时重启
    echo -e "System will reboot in 10 seconds..."
    
    for i in {10..1}; do
        echo -ne "Rebooting in $i seconds...\r"
        sleep 1
    done
    
    echo -e "\nRebooting now..."
    sleep 2
    reboot -f
    
else
    echo -e "\n\nInstallation failed! Error code: $DD_EXIT"
    echo -e "\nPossible issues:"
    echo -e "1. Disk may be in use or mounted"
    echo -e "2. Disk may be failing"
    echo -e "3. Not enough space on target disk"
    echo -e "\nPlease check the disk and try again.\n"
    echo ""
    read -p "Press Enter to return to disk selection..." _
    exec /opt/install-openwrt.sh  # 重新启动安装程序
fi
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
# 配置live-boot
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
mount -o bind /dev "${CHROOT_DIR}/dev"
mount -o bind /sys "${CHROOT_DIR}/sys"

log_info "Running chroot configuration..."
chroot "$CHROOT_DIR" /install-chroot.sh 2>&1 

# 清理chroot
rm -f "$CHROOT_DIR/install-chroot.sh"

# === 第六阶段：额外的精简步骤 ===

# 1. 清理chroot中的缓存和临时文件
chroot "${CHROOT_DIR}" /bin/bash -c "
# 清理APT缓存
apt-get clean 2>/dev/null || true

# 清理日志
find /var/log -type f -delete 2>/dev/null || true

# 清理临时文件
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

# 清理bash历史
rm -f /root/.bash_history 2>/dev/null || true

# 清理包管理器状态文件
rm -f /var/lib/dpkg/status-old 2>/dev/null || true
rm -f /var/lib/apt/lists/* 2>/dev/null || true

# 清理系统d-bus缓存
rm -rf /var/lib/dbus/machine-id 2>/dev/null || true

# 清理网络配置缓存
rm -rf /var/lib/systemd/random-seed 2>/dev/null || true
"

# 2. 手动清理不需要的文件
for dir in "${CHROOT_DIR}/usr/share/locale" "${CHROOT_DIR}/usr/share/doc" \
           "${CHROOT_DIR}/usr/share/man" "${CHROOT_DIR}/usr/share/info"; do
    if [ -d "$dir" ]; then
        rm -rf "$dir"
    fi
done

# 3. 清理不必要的内核模块 (再次确保)
if [ -d "${CHROOT_DIR}/lib/modules" ]; then
    KERNEL_VERSION=$(ls "${CHROOT_DIR}/lib/modules/" | head -n1)
    MODULES_PATH="${CHROOT_DIR}/lib/modules/${KERNEL_VERSION}"

    # 创建必要的模块列表
    KEEP_MODS="
kernel/fs/ext4
kernel/fs/fat
kernel/fs/vfat
kernel/drivers/usb/storage
kernel/drivers/ata
kernel/drivers/scsi
kernel/drivers/nvme
kernel/drivers/block
kernel/drivers/hid
kernel/drivers/input
kernel/drivers/net/ethernet
"

    # 备份然后清理
    mkdir -p "${MODULES_PATH}/kernel-keep"
    for mod in $KEEP_MODS; do
        if [ -d "${MODULES_PATH}/kernel/${mod}" ]; then
            mkdir -p "${MODULES_PATH}/kernel-keep/${mod}"
            mv "${MODULES_PATH}/kernel/${mod}"/* "${MODULES_PATH}/kernel-keep/${mod}/" 2>/dev/null || true
        fi
    done

    # 替换模块目录
    rm -rf "${MODULES_PATH}/kernel"
    mv "${MODULES_PATH}/kernel-keep" "${MODULES_PATH}/kernel"
fi
# 创建网络配置文件
cat > "${CHROOT_DIR}/etc/systemd/network/99-dhcp.network" <<EOF
[Match]
Name=e*

[Network]
DHCP=yes

[DHCP]
ClientIdentifier=mac
EOF
chown -v root:root "${CHROOT_DIR}/etc/systemd/network/99-dhcp.network"
chmod 644 "${CHROOT_DIR}/etc/systemd/network/99-dhcp.network"

# 卸载chroot挂载点（关键步骤！）
log_info "Unmounting chroot filesystems..."
safe_umount "$CHROOT_DIR/dev"
safe_umount "$CHROOT_DIR/proc"
safe_umount "$CHROOT_DIR/sys"

# ==================== 复制OpenWRT镜像 ====================
log_info "[5/10] Copying OpenWRT image..."
cp "$OPENWRT_IMG" "$CHROOT_DIR/openwrt.img"
log_success "OpenWRT image copied"

# ==================== 步骤6: 创建squashfs文件系统 ====================
log_info "[6/10] Creating squashfs filesystem..."

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
    -Xbcj x86 \
    -b 1M \
    -noappend \
    -no-progress \
    -no-recovery \
    -always-use-fragments \
    -all-root \
    -processors 2 \
    -mem 1G \
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
touch "$STAGING_DIR/DEBIAN_CUSTOM"

# ==================== 步骤7: 创建引导配置 ====================
log_info "[7/10] Creating boot configuration..."

# 创建isolinux配置
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
UI vesamenu.c32

MENU TITLE OpenWRT Auto Installer
DEFAULT linux
TIMEOUT 3

LABEL linux
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live
ISOLINUX_CFG

# 创建GRUB配置
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
search --set=root --file /DEBIAN_CUSTOM

set default="0"
set timeout=3

insmod efi_gop
insmod font
if loadfont ${prefix}/fonts/unicode.pf2
then
        insmod gfxterm
        set gfxmode=auto
        set gfxpayload=keep
        terminal_output gfxterm
fi
menuentry "Install OpenWRT x86-UEFI Installer [EFI/GRUB]" {
    linux ($root)/live/vmlinuz boot=live
    initrd ($root)/live/initrd
}
GRUB_CFG

# 创建GRUB独立配置文件
cat > "${WORK_DIR}/tmp/grub-standalone.cfg" << 'STAD_CFG'
search --set=root --file /DEBIAN_CUSTOM
set prefix=($root)/boot/grub/
configfile /boot/grub/grub.cfg
STAD_CFG

# 复制引导文件
log_info "[8/10] Extracting kernel and initrd..."

# 查找最新的内核和initrd
KERNEL=$(ls -t "${CHROOT_DIR}/boot"/vmlinuz-* 2>/dev/null | head -1)
INITRD=$(ls -t "${CHROOT_DIR}/boot"/initrd.img-* 2>/dev/null | head -1)

if [ -z "$KERNEL" ] || [ -z "$INITRD" ]; then
    log_error "Kernel or initrd not found in ${CHROOT_DIR}/boot"
    log_error "Available files:"
    ls -la "${CHROOT_DIR}/boot/" 2>/dev/null || echo "Cannot list boot directory"
    exit 1
fi

cp "$KERNEL" "$STAGING_DIR/live/vmlinuz"
cp "$INITRD" "$STAGING_DIR/live/initrd"
log_success "Kernel: $(basename "$KERNEL")"
log_success "Initrd: $(basename "$INITRD")"

# 复制ISOLINUX文件
if [ -f /usr/lib/ISOLINUX/isolinux.bin ]; then
    cp /usr/lib/ISOLINUX/isolinux.bin "$STAGING_DIR/isolinux/"
    cp /usr/lib/ISOLINUX/isohdpfx.bin "$WORK_DIR/tmp/isohdpfx.bin"
elif [ -f /usr/lib/syslinux/isolinux.bin ]; then
    cp /usr/lib/syslinux/isolinux.bin "$STAGING_DIR/isolinux/"
    cp /usr/lib/syslinux/isohdpfx.bin "$WORK_DIR/tmp/isohdpfx.bin"
else
    log_warning "isolinux.bin not found, trying to install syslinux..."
    apt-get install -y syslinux-common
    cp /usr/lib/syslinux/isolinux.bin "$STAGING_DIR/isolinux/" 2>/dev/null || \
    cp /usr/lib/ISOLINUX/isolinux.bin "$STAGING_DIR/isolinux/" 2>/dev/null || \
    log_error "Cannot find isolinux.bin"
fi

# 复制ISOLINUX模块
if [ -d /usr/lib/syslinux/modules/bios ]; then
    cp /usr/lib/syslinux/modules/bios/* "$STAGING_DIR/isolinux/" 2>/dev/null || true
fi

# 复制GRUB EFI模块
if [ -d /usr/lib/grub/x86_64-efi ]; then
    cp -r /usr/lib/grub/x86_64-efi/* "$STAGING_DIR/boot/grub/x86_64-efi/" 2>/dev/null || true
fi

# ==================== 创建UEFI引导文件 ====================
log_info "[8.5/10] Creating UEFI boot file..."

# 确保目标目录存在
mkdir -p "${STAGING_DIR}/EFI/boot"

# 创建GRUB EFI引导文件
cd "$WORK_DIR/tmp"
grub-mkstandalone \
    --format=x86_64-efi \
    --output="${WORK_DIR}/tmp/bootx64.efi" \
    --locales="" \
    --fonts="" \
    "boot/grub/grub.cfg=${WORK_DIR}/tmp/grub-standalone.cfg"

if [ ! -f "${WORK_DIR}/tmp/bootx64.efi" ]; then
    log_error "Failed to create bootx64.efi"
    exit 1
fi

# 创建EFI引导镜像
log_info "Creating EFI boot image..."
EFI_SIZE=$(($(stat --format=%s "${WORK_DIR}/tmp/bootx64.efi") + 65536))
dd if=/dev/zero of="${STAGING_DIR}/EFI/boot/efiboot.img" bs=1 count=0 seek=${EFI_SIZE} 2>/dev/null
mkfs.fat -F 12 -n "OPENWRT_INST" "${STAGING_DIR}/EFI/boot/efiboot.img" >/dev/null 2>&1 || \
mkfs.fat -F 32 -n "OPENWRT_INST" "${STAGING_DIR}/EFI/boot/efiboot.img" >/dev/null 2>&1

# 复制EFI文件到镜像
MMOUNT_DIR="${WORK_DIR}/tmp/efi_mount"
mkdir -p "$MMOUNT_DIR"
mount "${STAGING_DIR}/EFI/boot/efiboot.img" "$MMOUNT_DIR" 2>/dev/null || true

mkdir -p "$MMOUNT_DIR/EFI/boot"
cp "${WORK_DIR}/tmp/bootx64.efi" "$MMOUNT_DIR/EFI/boot/bootx64.efi"

# 尝试卸载，如果失败就继续
umount "$MMOUNT_DIR" 2>/dev/null || true
rm -rf "$MMOUNT_DIR"

log_success "UEFI boot files created successfully"

# ==================== 步骤9: 构建ISO镜像 ====================
log_info "[9/10] Building ISO image..."

# 检查isohdpfx.bin是否存在
if [ ! -f "$WORK_DIR/tmp/isohdpfx.bin" ]; then
    if [ -f /usr/lib/ISOLINUX/isohdpfx.bin ]; then
        cp /usr/lib/ISOLINUX/isohdpfx.bin "$WORK_DIR/tmp/isohdpfx.bin"
    elif [ -f /usr/lib/syslinux/isohdpfx.bin ]; then
        cp /usr/lib/syslinux/isohdpfx.bin "$WORK_DIR/tmp/isohdpfx.bin"
    else
        log_warning "isohdpfx.bin not found, generating ISO without hybrid MBR..."
    fi
fi

# 构建ISO
log_info "Running xorriso to create ISO..."
if [ -f "$WORK_DIR/tmp/isohdpfx.bin" ]; then
    xorriso \
        -as mkisofs \
        -iso-level 3 \
        -output "${ISO_PATH}" \
        -full-iso9660-filenames \
        -volid "DEBIAN_CUSTOM" \
        -isohybrid-mbr "$WORK_DIR/tmp/isohdpfx.bin" \
        -eltorito-boot isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-catalog isolinux/isolinux.cat \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -append_partition 2 0xef "${STAGING_DIR}/EFI/boot/efiboot.img" \
        "$STAGING_DIR"
else
    xorriso \
        -as mkisofs \
        -iso-level 3 \
        -output "${ISO_PATH}" \
        -full-iso9660-filenames \
        -volid "DEBIAN_CUSTOM" \
        -eltorito-boot isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-catalog isolinux/isolinux.cat \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot \
        "$STAGING_DIR"
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

    # 创建构建信息文件
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO Build Information
========================================
Build Date:      $(date)

ISO Size:        $ISO_SIZE
Kernel Version:  $(basename "$KERNEL")
Initrd Version:  $(basename "$INITRD")

Boot Support:    BIOS + UEFI
Boot Timeout:    3 seconds

Installation Features:
  - Simple numeric disk selection (1, 2, 3, etc.)
  - Clean, minimal output (no verbose logs)
  - Visual progress indicator
  - Safety confirmation before writing
  - Automatic reboot after installation

Usage:
  1. Create bootable USB: dd if="$ISO_NAME" of=/dev/sdX bs=4M status=progress
  2. Boot from USB in UEFI or Legacy mode
  3. Select target disk using numbers
  4. Confirm installation
  5. Wait for automatic reboot
  6. souce https://github.com/sirpdboy/openwrt-installer-iso.git

Notes:
  - Installation is completely silent (no dd logs)
  - Use numbers instead of disk names (simpler)
  - Press Ctrl+C during reboot countdown to cancel
EOF

    log_success "Build info saved to: $OUTPUT_DIR/build-info.txt"

    echo ""
    echo "================================================================================"
    echo "📦 ISO Build Complete!"
    echo "================================================================================"
    echo "Key improvements in this version:"
    echo "  ✓ Clean, minimal installation output (no verbose logs)"
    echo "  ✓ Simple numeric disk selection (1, 2, 3... instead of sda, sdb)"
    echo "  ✓ Visual progress bar during writing"
    echo "  ✓ Enhanced safety with confirmation step"
    echo ""
    echo "To create bootable USB:"
    echo "  sudo dd if='$ISO_PATH' of=/dev/sdX bs=4M status=progress && sync"
    echo ""
    echo "  souce https://github.com/sirpdboy/openwrt-installer-iso.git"
    echo "================================================================================"

    log_success "🎉 All steps completed successfully!"
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
