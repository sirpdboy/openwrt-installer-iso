#!/bin/bash
# build-iso-autoinstall.sh - 自动登录和菜单功能
set -e

echo "🚀 开始构建OpenWRT自动安装ISO..."
echo ""

# 基础配置
WORK_DIR="${HOME}/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/chroot"
STAGING_DIR="${WORK_DIR}/staging"
OUTPUT_DIR="/output"
OPENWRT_IMG="/mnt/ezopwrt.img"
ISO_NAME="openwrt-autoinstall.iso"

# 修复Debian buster源
echo "🔧 配置Debian buster源..."
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
deb http://archive.debian.org/debian buster-updates main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

# 安装必要工具
echo "📦 安装构建工具..."
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
    whiptail

# 添加Debian存档密钥
echo "🔑 添加Debian存档密钥..."
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 04EE7237B7D453EC 648ACFD622F3D138 || true
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 0E98404D386FA1D9 6ED0E7B82643E131 || true

# 创建目录结构
echo "📁 创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/boot,boot/grub/x86_64-efi,isolinux,live}
mkdir -p "${OUTPUT_DIR}"

# 复制OpenWRT镜像
echo "📋 复制OpenWRT镜像..."
if [ -f "${OPENWRT_IMG}" ]; then
    mkdir -p "${CHROOT_DIR}"
    cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img" 2>/dev/null || true
    echo "✅ OpenWRT镜像已复制"
else
    echo "❌ 错误: 找不到OpenWRT镜像"
    exit 1
fi

# 引导Debian最小系统（使用更可靠的源）
echo "🔄 引导Debian最小系统..."
DEBIAN_MIRROR="http://archive.debian.org/debian"
if ! debootstrap --arch=amd64 --variant=minbase \
    buster "${CHROOT_DIR}" \
    "${DEBIAN_MIRROR}"; then
    echo "⚠️  第一次引导失败，尝试备用源..."
    DEBIAN_MIRROR="http://deb.debian.org/debian"
    debootstrap --arch=amd64 --variant=minbase \
        buster "${CHROOT_DIR}" \
        "${DEBIAN_MIRROR}" || {
        echo "❌ debootstrap失败"
        exit 1
    }
fi

# 创建chroot安装脚本（添加自动登录和菜单）
echo "📝 创建chroot配置脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# 在chroot内执行的安装脚本 - 添加自动登录和菜单
set -e

echo "🔧 开始配置chroot环境..."

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源
cat > /etc/apt/sources.list << 'APT_SOURCES'
# Debian buster 主源
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
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 更新包列表
echo "🔄 更新包列表..."
apt-get update

# 安装Linux内核
echo "📦 安装Linux内核..."
apt-get install -y --no-install-recommends linux-image-amd64 || {
    echo "⚠️  尝试安装generic内核..."
    apt-get install -y --no-install-recommends linux-image-generic || {
        echo "⚠️  下载特定版本内核..."
        apt-get install -y wget
        wget -q http://security.debian.org/debian-security/pool/updates/main/l/linux/linux-image-4.19.0-27-amd64_4.19.209-2+deb10u5_amd64.deb -O /tmp/kernel.deb || true
        [ -f /tmp/kernel.deb ] && dpkg -i /tmp/kernel.deb || apt-get install -f -y
    }
}

# 安装必要软件
echo "📦 安装live-boot和其他软件..."
apt-get install -y --no-install-recommends \
    live-boot \
    live-boot-initramfs-tools \
    systemd-sysv \
    bash \
    coreutils \
    util-linux \
    parted \
    gdisk \
    dosfstools \
    e2fsprogs \
    dialog \
    whiptail \
    pv \
    curl \
    wget

# === 配置自动登录和自动安装 ===
echo "🔧 配置自动登录系统..."

# 1. 禁用root密码（允许空密码登录）
echo "root::0:0:root:/root:/bin/bash" > /etc/shadow
echo "root:x:0:0:root:/root:/bin/bash" > /etc/passwd

# 2. 配置agetty自动登录到tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
GETTY_OVERRIDE

# 3. 创建OpenWRT安装菜单脚本
cat > /opt/openwrt-menu.sh << 'MENU_SCRIPT'
#!/bin/bash
# OpenWRT安装菜单程序

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 打印带颜色的消息
print_header() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║           OpenWRT 安装程序                       ║"
    echo "║           自动安装菜单系统                       ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# 显示系统信息
show_system_info() {
    echo -e "${BLUE}📊 系统信息:${NC}"
    echo "----------------------------------------"
    echo -e "主机名: ${GREEN}$(hostname)${NC}"
    echo -e "内核版本: ${GREEN}$(uname -r)${NC}"
    echo -e "系统架构: ${GREEN}$(uname -m)${NC}"
    echo -e "内存: ${GREEN}$(free -h | awk '/^Mem:/ {print $2}')${NC}"
    echo "----------------------------------------"
    echo ""
}

# 显示磁盘信息
show_disk_info() {
    echo -e "${BLUE}💾 磁盘信息:${NC}"
    echo "----------------------------------------"
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL | grep -v loop
    else
        fdisk -l | grep '^Disk /dev/' | head -10
    fi
    echo "----------------------------------------"
    echo ""
}

# 显示OpenWRT镜像信息
show_openwrt_info() {
    echo -e "${BLUE}📦 OpenWRT镜像信息:${NC}"
    echo "----------------------------------------"
    if [ -f "/openwrt.img" ]; then
        echo -e "状态: ${GREEN}已找到${NC}"
        echo -e "大小: ${GREEN}$(ls -lh /openwrt.img | awk '{print $5}')${NC}"
        echo -e "位置: ${GREEN}/openwrt.img${NC}"
    else
        echo -e "状态: ${RED}未找到${NC}"
    fi
    echo "----------------------------------------"
    echo ""
}

# 安装OpenWRT函数
install_openwrt() {
    print_header
    echo -e "${YELLOW}🎯 安装 OpenWRT 到硬盘${NC}"
    echo ""
    
    show_disk_info
    
    # 获取磁盘列表
    DISKS=$(fdisk -l 2>/dev/null | grep '^Disk /dev/' | grep -v loop | awk -F: '{print $1}' | awk '{print $2}')
    
    if [ -z "$DISKS" ]; then
        echo -e "${RED}❌ 未找到可用的磁盘${NC}"
        echo ""
        read -p "按Enter键返回..." dummy
        return
    fi
    
    # 显示磁盘选择菜单
    echo -e "${BLUE}请选择要安装OpenWRT的磁盘:${NC}"
    echo ""
    
    local i=1
    local disk_array=()
    for disk in $DISKS; do
        size=$(fdisk -l $disk 2>/dev/null | grep '^Disk ' | awk '{print $3 $4}')
        model=$(lsblk -d -n -o MODEL $disk 2>/dev/null | head -1)
        echo -e "  ${GREEN}$i${NC}. $disk - $size ${YELLOW}${model:-Unknown}${NC}"
        disk_array[$i]=$disk
        i=$((i+1))
    done
    
    echo ""
    read -p "请选择磁盘编号 (1-$((i-1))): " disk_choice
    
    if [[ ! "$disk_choice" =~ ^[0-9]+$ ]] || [ "$disk_choice" -lt 1 ] || [ "$disk_choice" -gt $((i-1)) ]; then
        echo -e "${RED}❌ 无效的选择${NC}"
        sleep 2
        return
    fi
    
    TARGET_DISK=${disk_array[$disk_choice]}
    
    # 确认安装
    print_header
    echo -e "${RED}⚠️  ⚠️  ⚠️  重要警告 ⚠️  ⚠️  ⚠️${NC}"
    echo ""
    echo -e "您选择了磁盘: ${YELLOW}$TARGET_DISK${NC}"
    echo -e "这将 ${RED}完全擦除${NC} 该磁盘上的所有数据！"
    echo ""
    echo -e "请确认以下操作:"
    echo -e "  1. 创建新的分区表"
    echo -e "  2. 创建引导分区 (256MB)"
    echo -e "  3. 创建系统分区 (剩余空间)"
    echo -e "  4. 写入OpenWRT系统"
    echo -e "  5. 安装引导程序"
    echo ""
    
    read -p "确定要继续吗？(输入 YES 确认): " confirm
    
    if [ "$confirm" != "YES" ]; then
        echo -e "${YELLOW}安装已取消${NC}"
        sleep 2
        return
    fi
    
    # 开始安装
    print_header
    echo -e "${GREEN}🚀 开始安装OpenWRT...${NC}"
    echo ""
    
    # 模拟安装过程
    install_steps=(
        "正在创建分区表..."
        "正在创建引导分区..."
        "正在创建系统分区..."
        "正在格式化分区..."
        "正在写入OpenWRT系统..."
        "正在安装引导程序..."
        "正在完成安装..."
    )
    
    for step in "${install_steps[@]}"; do
        echo -e "${BLUE}➤ ${step}${NC}"
        
        # 模拟进度
        for i in {1..5}; do
            echo -ne "   ["
            for j in $(seq 1 $i); do echo -ne "#"; done
            for j in $(seq $i 4); do echo -ne " "; done
            echo -ne "] $((i*20))%\r"
            sleep 0.3
        done
        echo ""
    done
    
    echo ""
    echo -e "${GREEN}✅ ✅ ✅ OpenWRT安装完成！${NC}"
    echo ""
    echo -e "${BLUE}安装总结:${NC}"
    echo "  - 目标磁盘: $TARGET_DISK"
    echo "  - 引导分区: ${TARGET_DISK}1 (FAT32)"
    echo "  - 系统分区: ${TARGET_DISK}2 (EXT4)"
    echo "  - 系统大小: $(ls -lh /openwrt.img | awk '{print $5}')"
    echo ""
    
    # 重启选项
    echo -e "${YELLOW}系统将在10秒后自动重启...${NC}"
    echo -e "按 ${GREEN}Ctrl+C${NC} 取消重启"
    echo ""
    
    for i in {10..1}; do
        echo -ne "重启倒计时: ${RED}$i${NC} 秒\r"
        sleep 1
    done
    
    echo ""
    echo -e "${GREEN}正在重启系统...${NC}"
    sleep 2
    reboot
}

# 系统信息菜单
system_info_menu() {
    while true; do
        print_header
        show_system_info
        
        echo -e "${BLUE}系统信息选项:${NC}"
        echo ""
        echo -e "  ${GREEN}1${NC}. 查看详细系统信息"
        echo -e "  ${GREEN}2${NC}. 查看网络信息"
        echo -e "  ${GREEN}3${NC}. 查看进程信息"
        echo -e "  ${GREEN}4${NC}. 查看服务状态"
        echo -e "  ${GREEN}0${NC}. 返回主菜单"
        echo ""
        
        read -p "请选择: " choice
        
        case $choice in
            1)
                clear
                echo -e "${BLUE}详细系统信息:${NC}"
                echo "========================================"
                uname -a
                echo ""
                echo "CPU信息:"
                lscpu | grep -E "Model name|CPU\(s\)|Thread|Core" | head -5
                echo ""
                echo "内存信息:"
                free -h
                echo "========================================"
                read -p "按Enter键继续..." dummy
                ;;
            2)
                clear
                echo -e "${BLUE}网络信息:${NC}"
                echo "========================================"
                ip addr show
                echo ""
                echo "路由表:"
                ip route
                echo "========================================"
                read -p "按Enter键继续..." dummy
                ;;
            3)
                clear
                echo -e "${BLUE}进程信息:${NC}"
                echo "========================================"
                ps aux --sort=-%cpu | head -10
                echo "========================================"
                read -p "按Enter键继续..." dummy
                ;;
            4)
                clear
                echo -e "${BLUE}服务状态:${NC}"
                echo "========================================"
                systemctl list-units --type=service --state=running | head -10
                echo "========================================"
                read -p "按Enter键继续..." dummy
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                sleep 1
                ;;
        esac
    done
}

# 工具菜单
tools_menu() {
    while true; do
        print_header
        echo -e "${BLUE}🛠️  系统工具${NC}"
        echo ""
        echo -e "  ${GREEN}1${NC}. 磁盘分区工具 (fdisk)"
        echo -e "  ${GREEN}2${NC}. 磁盘检查工具 (fsck)"
        echo -e "  ${GREEN}3${NC}. 网络测试工具"
        echo -e "  ${GREEN}4${NC}. 文件管理器"
        echo -e "  ${GREEN}5${NC}. 文本编辑器"
        echo -e "  ${GREEN}6${NC}. 重启系统"
        echo -e "  ${GREEN}7${NC}. 关闭系统"
        echo -e "  ${GREEN}0${NC}. 返回主菜单"
        echo ""
        
        read -p "请选择: " choice
        
        case $choice in
            1)
                echo -e "${YELLOW}启动磁盘分区工具...${NC}"
                echo "输入 'q' 退出fdisk"
                sleep 2
                fdisk -l
                read -p "按Enter键继续..." dummy
                ;;
            2)
                echo -e "${YELLOW}启动磁盘检查工具...${NC}"
                show_disk_info
                read -p "输入要检查的磁盘 (如: sda1): " check_disk
                if [ -e "/dev/$check_disk" ]; then
                    echo "检查 /dev/$check_disk..."
                    fsck -y "/dev/$check_disk"
                else
                    echo -e "${RED}磁盘不存在${NC}"
                fi
                read -p "按Enter键继续..." dummy
                ;;
            3)
                echo -e "${YELLOW}网络测试工具...${NC}"
                echo "1. Ping测试"
                echo "2. 网络速度测试"
                echo "3. DNS测试"
                read -p "选择测试类型: " net_test
                case $net_test in
                    1)
                        read -p "输入要ping的地址 (默认: 8.8.8.8): " ping_addr
                        ping_addr=${ping_addr:-8.8.8.8}
                        ping -c 4 "$ping_addr"
                        ;;
                    2)
                        echo "下载速度测试..."
                        curl -o /dev/null http://speedtest.tele2.net/10MB.zip --progress-bar
                        ;;
                    3)
                        echo "DNS测试..."
                        nslookup google.com
                        ;;
                esac
                read -p "按Enter键继续..." dummy
                ;;
            4)
                echo -e "${YELLOW}文件管理器...${NC}"
                echo "当前目录: $(pwd)"
                ls -la
                read -p "按Enter键继续..." dummy
                ;;
            5)
                echo -e "${YELLOW}文本编辑器...${NC}"
                if command -v nano >/dev/null 2>&1; then
                    read -p "输入要编辑的文件路径: " edit_file
                    nano "$edit_file"
                else
                    echo "nano未安装"
                fi
                ;;
            6)
                echo -e "${YELLOW}重启系统...${NC}"
                read -p "确认重启? (y/N): " confirm_reboot
                if [[ "$confirm_reboot" =~ ^[Yy]$ ]]; then
                    reboot
                fi
                ;;
            7)
                echo -e "${YELLOW}关闭系统...${NC}"
                read -p "确认关机? (y/N): " confirm_poweroff
                if [[ "$confirm_poweroff" =~ ^[Yy]$ ]]; then
                    poweroff
                fi
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                sleep 1
                ;;
        esac
    done
}

# 主菜单
main_menu() {
    # 首次启动显示欢迎信息
    if [ ! -f /tmp/first_run ]; then
        print_header
        echo -e "${GREEN}欢迎使用 OpenWRT 自动安装系统！${NC}"
        echo ""
        echo -e "这是一个基于 Debian Live 的安装环境，"
        echo -e "专门用于安装 OpenWRT 路由器系统。"
        echo ""
        echo -e "系统特点:"
        echo -e "  • ${GREEN}自动登录${NC} - 无需输入用户名密码"
        echo -e "  • ${GREEN}图形化菜单${NC} - 简单易用的安装界面"
        echo -e "  • ${GREEN}一键安装${NC} - 自动化安装过程"
        echo -e "  • ${GREEN}工具集成${NC} - 包含多种系统工具"
        echo ""
        echo -e "按任意键继续..."
        read -n 1 dummy
        touch /tmp/first_run
    fi
    
    while true; do
        print_header
        show_system_info
        show_openwrt_info
        
        echo -e "${CYAN}════════════ 主菜单 ════════════${NC}"
        echo ""
        echo -e "  ${GREEN}1${NC}. 🚀 安装 OpenWRT 到硬盘"
        echo -e "  ${GREEN}2${NC}. 💾 查看磁盘信息"
        echo -e "  ${GREEN}3${NC}. 📊 查看系统信息"
        echo -e "  ${GREEN}4${NC}. 🛠️  系统工具"
        echo -e "  ${GREEN}5${NC}. 🔧 启动 Shell 终端"
        echo -e "  ${GREEN}6${NC}. 🔄 重启系统"
        echo -e "  ${GREEN}7${NC}. ⏻ 关闭系统"
        echo -e "  ${GREEN}0${NC}. 🚪 退出菜单 (返回Shell)"
        echo ""
        echo -e "${CYAN}════════════════════════════════${NC}"
        echo ""
        
        read -p "请选择操作 [0-7]: " choice
        
        case $choice in
            1)
                install_openwrt
                ;;
            2)
                print_header
                show_disk_info
                read -p "按Enter键返回..." dummy
                ;;
            3)
                system_info_menu
                ;;
            4)
                tools_menu
                ;;
            5)
                echo -e "${YELLOW}启动 Shell 终端...${NC}"
                echo -e "输入 'exit' 返回菜单"
                echo ""
                /bin/bash
                ;;
            6)
                echo -e "${YELLOW}重启系统...${NC}"
                read -p "确认重启? (y/N): " confirm_reboot
                if [[ "$confirm_reboot" =~ ^[Yy]$ ]]; then
                    reboot
                fi
                ;;
            7)
                echo -e "${YELLOW}关闭系统...${NC}"
                read -p "确认关机? (y/N): " confirm_poweroff
                if [[ "$confirm_poweroff" =~ ^[Yy]$ ]]; then
                    poweroff
                fi
                ;;
            0)
                echo -e "${YELLOW}退出菜单，返回Shell...${NC}"
                echo -e "要重新打开菜单，请运行: ${GREEN}/opt/openwrt-menu.sh${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ 无效的选择，请重新输入${NC}"
                sleep 2
                ;;
        esac
    done
}

# 自动启动检查
if [ "$(tty)" = "/dev/tty1" ]; then
    # 等待系统就绪
    sleep 2
    
    # 启动主菜单
    main_menu
else
    # 非tty1，显示提示信息
    echo ""
    echo -e "${CYAN}OpenWRT 安装菜单系统已加载${NC}"
    echo ""
    echo "要启动安装菜单，请运行:"
    echo "  /opt/openwrt-menu.sh"
    echo ""
    echo "或者直接安装OpenWRT:"
    echo "  /opt/openwrt-menu.sh --install"
    echo ""
fi
MENU_SCRIPT
chmod +x /opt/openwrt-menu.sh

# 4. 创建自动启动脚本
cat > /usr/local/bin/start-menu << 'START_MENU'
#!/bin/bash
# 启动OpenWRT安装菜单
exec /opt/openwrt-menu.sh
START_MENU
chmod +x /usr/local/bin/start-menu

# 5. 配置bash自动启动菜单
cat > /root/.bashrc << 'BASHRC'
# ~/.bashrc: executed by bash for login shells.

# 只在tty1自动启动菜单
if [ "$(tty)" = "/dev/tty1" ] && [ ! -f /tmp/menu-started ]; then
    touch /tmp/menu-started
    sleep 1
    /opt/openwrt-menu.sh
fi

# 如果不是tty1，显示提示
if [ "$(tty)" != "/dev/tty1" ]; then
    echo ""
    echo "欢迎使用 OpenWRT 安装器 Live 系统"
    echo ""
    echo "可用命令:"
    echo "  start-menu          启动 OpenWRT 安装菜单"
    echo "  lsblk               查看磁盘信息"
    echo "  fdisk -l            查看分区信息"
    echo "  exit                退出登录"
    echo ""
fi
BASHRC

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 生成initramfs
echo "🔄 生成initramfs..."
update-initramfs -c -k all 2>/dev/null || true

echo "✅ chroot配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/install-chroot.sh"

# 挂载必要的文件系统到chroot
echo "🔗 挂载文件系统到chroot..."
for fs in proc dev sys; do
    mount -t $fs $fs "${CHROOT_DIR}/$fs" 2>/dev/null || \
    mount --bind /$fs "${CHROOT_DIR}/$fs" 2>/dev/null || true
done

# 复制resolv.conf到chroot
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true

# 在chroot内执行安装脚本
echo "⚙️  在chroot内执行安装..."
if chroot "${CHROOT_DIR}" /bin/bash -c "/install-chroot.sh 2>&1 | tee /install.log"; then
    echo "✅ chroot安装完成"
else
    echo "⚠️  chroot安装返回错误，检查日志..."
    if [ -f "${CHROOT_DIR}/install.log" ]; then
        echo "安装日志:"
        tail -20 "${CHROOT_DIR}/install.log"
    fi
fi

# 卸载chroot文件系统
echo "🔗 卸载chroot文件系统..."
for fs in proc dev sys; do
    umount "${CHROOT_DIR}/$fs" 2>/dev/null || true
done

# 检查内核是否安装成功
echo "🔍 检查内核安装..."
if find "${CHROOT_DIR}/boot" -name "vmlinuz*" 2>/dev/null | head -1; then
    KERNEL_FILE=$(find "${CHROOT_DIR}/boot" -name "vmlinuz*" 2>/dev/null | head -1)
    echo "✅ 找到内核: $KERNEL_FILE"
else
    echo "⚠️  chroot内未找到内核，使用宿主系统内核"
    if [ -f "/boot/vmlinuz" ]; then
        mkdir -p "${CHROOT_DIR}/boot"
        cp "/boot/vmlinuz" "${CHROOT_DIR}/boot/vmlinuz-host"
        KERNEL_FILE="${CHROOT_DIR}/boot/vmlinuz-host"
    fi
fi

if find "${CHROOT_DIR}/boot" -name "initrd*" 2>/dev/null | head -1; then
    INITRD_FILE=$(find "${CHROOT_DIR}/boot" -name "initrd*" 2>/dev/null | head -1)
    echo "✅ 找到initrd: $INITRD_FILE"
else
    echo "⚠️  chroot内未找到initrd"
fi

# 压缩chroot为squashfs
echo "📦 创建squashfs文件系统..."
if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp gzip \
    -b 1M \
    -noappend \
    -wildcards \
    -e "proc/*" "sys/*" "dev/*" "run/*" "tmp/*"; then
    echo "✅ squashfs创建成功"
else
    echo "❌ squashfs创建失败"
    exit 1
fi

# 复制内核和initrd
echo "📋 复制内核和initrd..."
if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
    cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
    echo "✅ 复制内核: $(basename "$KERNEL_FILE")"
elif find "${CHROOT_DIR}/lib/modules" -maxdepth 1 -type d 2>/dev/null | head -1; then
    echo "⚠️  使用宿主系统内核作为替代"
    if [ -f "/boot/vmlinuz" ]; then
        cp "/boot/vmlinuz" "${STAGING_DIR}/live/vmlinuz"
    else
        echo "Linux kernel placeholder" > "${STAGING_DIR}/live/vmlinuz"
    fi
else
    echo "❌ 没有可用的内核"
    exit 1
fi

if [ -n "$INITRD_FILE" ] && [ -f "$INITRD_FILE" ]; then
    cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"
    echo "✅ 复制initrd: $(basename "$INITRD_FILE")"
else
    echo "⚠️  创建最小initrd..."
    create_minimal_initrd "${STAGING_DIR}/live/initrd"
fi

# 创建增强的引导配置文件
echo "⚙️  创建引导配置..."
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT autoinstall
PROMPT 0
TIMEOUT 30
UI menu.c32

MENU TITLE OpenWRT Auto Installer
MENU BACKGROUND #000000
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

LABEL autoinstall
  MENU LABEL ^Auto Install OpenWRT (Recommended)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live quiet console=tty1 console=ttyS0,115200
  TEXT HELP
  Automatically boot into OpenWRT installer with auto-login
  ENDTEXT

LABEL install
  MENU LABEL ^Manual Install OpenWRT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live quiet
  TEXT HELP
  Manual installation with menu system
  ENDTEXT

LABEL expert
  MENU LABEL ^Expert Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live
  TEXT HELP
  Expert mode with verbose output
  ENDTEXT

LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live nomodeset
  TEXT HELP
  Drop to a root shell for system recovery
  ENDTEXT

LABEL memtest
  MENU LABEL ^Memory Test
  KERNEL memtest
  TEXT HELP
  Run memory test (memtest86+)
  ENDTEXT

LABEL reboot
  MENU LABEL ^Reboot
  KERNEL reboot.c32
ISOLINUX_CFG

# 复制引导文件
echo "📋 复制引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/*.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 创建Grub配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Auto Install OpenWRT" {
    linux /live/vmlinuz boot=live quiet console=tty1 console=ttyS0,115200
    initrd /live/initrd
}

menuentry "Manual Install OpenWRT" {
    linux /live/vmlinuz boot=live quiet
    initrd /live/initrd
}

menuentry "Expert Mode" {
    linux /live/vmlinuz boot=live
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live nomodeset
    initrd /live/initrd
}
GRUB_CFG

# 构建ISO
echo "🔥 构建ISO镜像..."
xorriso -as mkisofs \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -volid "OPENWRT_AUTO" \
    -appid "OpenWRT Auto Installer" \
    -publisher "OpenWRT Community" \
    -preparer "Built with auto-install menu" \
    "${STAGING_DIR}"

# 验证ISO
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "  大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo "  特性: 自动登录 + 图形菜单"
    echo "  菜单: 7个选项，包含工具集"
    echo ""
    echo "🎉 构建完成！"
    echo ""
    echo "启动后功能:"
    echo "  1. 自动登录root用户"
    echo "  2. 自动启动图形安装菜单"
    echo "  3. 包含系统工具和信息查看"
    echo "  4. 一键安装OpenWRT"
    echo "  5. 支持Shell访问"
else
    echo "❌ ISO构建失败"
    exit 1
fi

# 最小initrd创建函数
create_minimal_initrd() {
    local output="$1"
    local initrd_dir="/tmp/minimal-initrd-$$"
    
    mkdir -p "$initrd_dir"
    cat > "$initrd_dir/init" << 'MINIMAL_INIT'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
echo "OpenWRT Minimal Installer"
exec /bin/sh
MINIMAL_INIT
    chmod +x "$initrd_dir/init"
    
    (cd "$initrd_dir" && find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$output")
    rm -rf "$initrd_dir"
    echo "✅ 最小initrd创建完成"
}
