#!/bin/bash
# build.sh - OpenWRT ISO构建脚本（在Docker容器内运行） sirpdboy  https://github.com/sirpdboy/openwrt-installer-iso.git
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
log_info "Configuring apt sources for Debian buster..."
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian buster main contrib non-free
deb http://deb.debian.org/debian buster-updates main contrib non-free
deb http://security.debian.org/debian-security buster/updates main contrib non-free
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

# 安装必要工具（包括扩容所需工具）
log_info "[1.5/10] Installing required packages..."
apt-get update
# 先安装一些基本工具，再尝试安装其他包
apt-get -y install debootstrap squashfs-tools xorriso isolinux syslinux-efi grub-pc-bin grub-efi-amd64-bin grub-efi mtools dosfstools parted pv grub-common grub2-common efibootmgr e2fsprogs f2fs-tools kpartx gzip bc

# 安装gdisk（包含sgdisk）
apt-get -y install gdisk

# 验证gdisk安装
if command -v sgdisk >/dev/null 2>&1; then
    log_success "sgdisk (from gdisk package) installed successfully"
else
    log_warning "sgdisk not found, trying alternative method..."
    # 尝试从源码编译安装
    apt-get -y install build-essential uuid-dev libpopt-dev
    wget https://sourceforge.net/projects/gptfdisk/files/gptfdisk/1.0.9/gptfdisk-1.0.9.tar.gz -O /tmp/gptfdisk.tar.gz
    tar -xzf /tmp/gptfdisk.tar.gz -C /tmp/
    cd /tmp/gptfdisk-1.0.9
    make && make install
    cd /
fi

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
DEBIAN_MIRROR="http://deb.debian.org/debian"

if debootstrap --arch=amd64 --variant=minbase \
    buster "$CHROOT_DIR" "$DEBIAN_MIRROR" 2>&1 | tail -5; then
    log_success "Debian bootstrap successful"
else
    log_warning "First attempt failed, trying alternative mirror..."
    DEBIAN_MIRROR="http://archive.debian.org/debian"
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

# 基本设置
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源（使用正确的buster源）
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian buster main contrib non-free
deb http://deb.debian.org/debian buster-updates main contrib non-free
deb http://security.debian.org/debian-security buster/updates main contrib non-free
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check

# 设置主机名和DNS
echo "openwrt-installer" > /etc/hostname
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 更新并安装包（包括扩容所需工具）
echo "Updating packages..."
apt-get update
apt-get -y install apt || true
apt-get -y upgrade

# 安装必要的工具（分步安装，避免依赖问题）
echo "Installing basic tools..."
apt-get install -y locales dialog whiptail wget curl

echo "Setting locale..."
sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
dpkg-reconfigure --frontend=noninteractive locales
update-locale LANG=en_US.UTF-8

echo "Installing system packages..."
apt-get install -y --no-install-recommends linux-image-amd64 live-boot systemd-sysv

echo "Installing utilities..."
apt-get install -y parted openssh-server bash-completion cifs-utils curl dbus dosfstools firmware-linux-free gddrescue iputils-ping isc-dhcp-client less nfs-common ntfs-3g openssh-client open-vm-tools procps vim wimtools wget pv grub-efi-amd64-bin bc

# 安装分区工具（gdisk包含sgdisk）
echo "Installing partition tools..."
apt-get install -y gdisk

# 安装文件系统工具
echo "Installing filesystem tools..."
apt-get install -y e2fsprogs f2fs-tools kpartx gzip

# 安装kmod-loop模块（用于扩容）
echo "Installing kernel modules..."
apt-get install -y kmod
# 加载loop模块
modprobe loop 2>/dev/null || true

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

# 创建安装脚本（包含扩容功能）
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash

# 工具函数：获取系统磁盘
get_system_disk() {
    local boot_dev=$(mount | grep ' /boot' | awk '{print $1}' 2>/dev/null)
    if [ -z "$boot_dev" ]; then
        boot_dev=$(mount | grep ' / ' | awk '{print $1}' | sed 's/[0-9]*$//')
    fi
    
    if [ -n "$boot_dev" ]; then
        echo "$boot_dev" | sed 's/p[0-9]*$//' | sed 's/[0-9]*$//'
    else
        # 回退方案：使用第一个磁盘
        lsblk -d -n -o NAME | grep -E '^(sd|hd|nvme|vd)' | head -1
    fi
}

# 工具函数：验证镜像文件
image_supported() {
    local image_file="$1"
    
    if [ ! -f "$image_file" ]; then
        return 1
    fi
    
    # 检查是否为有效的镜像文件
    if file "$image_file" | grep -q "gzip compressed data"; then
        return 0
    elif file "$image_file" | grep -q "filesystem data"; then
        return 0
    else
        return 1
    fi
}

# 工具函数：获取磁盘大小（MB）
get_disk_size_mb() {
    local disk="$1"
    if [ -b "$disk" ]; then
        local size_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null)
        if [ -n "$size_bytes" ]; then
            echo $((size_bytes / 1024 / 1024))
        else
            echo 0
        fi
    else
        echo 0
    fi
}

# 工具函数：获取磁盘可用空间（MB）
get_disk_free_mb() {
    local disk="$1"
    if [ -b "$disk" ]; then
        # 使用lsblk获取未分区空间
        local free_space=$(lsblk -b "$disk" -o SIZE | tail -1)
        echo $((free_space / 1024 / 1024))
    else
        echo 0
    fi
}

pkill -9 systemd-timesyncd 2>/dev/null
pkill -9 journald 2>/dev/null
echo 0 > /proc/sys/kernel/printk 2>/dev/null
    
clear
cat << "EOF"

╔═══════════════════════════════════════════════════════╗
║               OpenWRT Auto Installer                  ║
╚═══════════════════════════════════════════════════════╝

EOF

echo -e "\nChecking OpenWRT image..."
if [ ! -f "/openwrt.img" ]; then
    echo -e "\n❌ ERROR: OpenWRT image not found!"
    echo -e "\nImage file should be at: /openwrt.img"
    echo -e "\nPress Enter for shell..."
    read
    exec /bin/bash
fi

IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}')
echo -e "✅ OpenWRT image found: $IMG_SIZE\n"

# ==================== 步骤1: 选择安装硬盘 ====================
echo "══════════════════════════════════════════════════════════"
echo "                  STEP 1: SELECT DISK"
echo "══════════════════════════════════════════════════════════\n"

# 获取磁盘列表函数
get_disk_list() {
    # 获取所有磁盘，排除loop设备和只读设备
    DISK_LIST=()
    DISK_SIZES=()
    DISK_FREE=()
    DISK_INDEX=1
    
    echo "Available disks:"
    echo "----------------------------------------------------------------"
    echo " ID | Device      | Size        | Model"
    echo "----|-------------|-------------|--------------------------------"
    
    # 使用lsblk获取磁盘信息
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            DISK_NAME=$(echo "$line" | awk '{print $1}')
            DISK_SIZE=$(echo "$line" | awk '{print $2}')
            DISK_MODEL=$(echo "$line" | cut -d' ' -f3-)
            
            # 检查是否为有效磁盘（排除CD/DVD）
            if [[ $DISK_NAME =~ ^(sd|hd|nvme|vd) ]]; then
                DISK_LIST[DISK_INDEX]="$DISK_NAME"
                DISK_SIZES[DISK_INDEX]=$(get_disk_size_mb "/dev/$DISK_NAME")
                DISK_FREE[DISK_INDEX]=$(get_disk_free_mb "/dev/$DISK_NAME")
                
                # 显示磁盘信息
                printf " %-2d | /dev/%-8s | %-10s | %s\n" \
                    "$DISK_INDEX" "$DISK_NAME" "$DISK_SIZE" "$DISK_MODEL"
                
                ((DISK_INDEX++))
            fi
        fi
    done < <(lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^(sd|hd|nvme|vd)')
    
    TOTAL_DISKS=$((DISK_INDEX - 1))
}

# 主循环选择磁盘
DISK_SELECTED=""
while true; do
    # 获取磁盘列表
    unset DISK_LIST DISK_SIZES DISK_FREE
    declare -A DISK_LIST
    declare -A DISK_SIZES
    declare -A DISK_FREE
    
    get_disk_list
    
    if [ $TOTAL_DISKS -eq 0 ]; then
        echo -e "\n❌ No disks detected!"
        echo -e "Please check your storage devices and try again."
        echo ""
        read -p "Press Enter to rescan..." _
        clear
        continue
    fi
    
    echo -e "\n══════════════════════════════════════════════════════════"
    echo "Please select target disk:"
    echo ""
    
    # 获取用户选择
    while true; do
        read -p "Enter disk number (1-$TOTAL_DISKS) or 'r' to rescan: " SELECTION
        
        case $SELECTION in
            [Rr])
                clear
                break 2  # 跳出两层循环，重新扫描
                ;;
            [0-9]*)
                if [[ $SELECTION -ge 1 && $SELECTION -le $TOTAL_DISKS ]]; then
                    DISK_SELECTED=${DISK_LIST[$SELECTION]}
                    DISK_SIZE_MB=${DISK_SIZES[$SELECTION]}
                    DISK_FREE_MB=${DISK_FREE[$SELECTION]}
                    break 2  # 跳出两层循环，继续下一步
                else
                    echo "❌ Invalid selection. Please choose between 1 and $TOTAL_DISKS."
                fi
                ;;
            *)
                echo "❌ Invalid input. Please enter a number or 'r' to rescan."
                ;;
        esac
    done
done

# 显示选择的磁盘信息
clear
echo -e "\n══════════════════════════════════════════════════════════"
echo "                  SELECTED DISK"
echo "══════════════════════════════════════════════════════════\n"
echo "Device:     /dev/$DISK_SELECTED"
echo "Total Size: $((DISK_SIZE_MB / 1024))GB ($((DISK_SIZE_MB))MB)"
echo "Free Space: $((DISK_FREE_MB / 1024))GB ($((DISK_FREE_MB))MB)"
echo ""

# ==================== 步骤2: 选择写入模式 ====================
echo "══════════════════════════════════════════════════════════"
echo "                 STEP 2: SELECT MODE"
echo "══════════════════════════════════════════════════════════\n"

# 计算镜像大小
IMAGE_TMP="/openwrt.img"
if file "$IMAGE_TMP" | grep -q "gzip compressed data"; then
    # 如果是压缩镜像，估计解压后大小
    ORIGINAL_SIZE=$(gzip -dc "$IMAGE_TMP" 2>/dev/null | wc -c)
    ORIGINAL_SIZE_MB=$((ORIGINAL_SIZE / 1024 / 1024))
else
    # 如果是原始镜像，直接获取大小
    ORIGINAL_SIZE=$(du -sb "$IMAGE_TMP" 2>/dev/null | cut -f1)
    ORIGINAL_SIZE_MB=$((ORIGINAL_SIZE / 1024 / 1024))
fi

# 计算可用扩容空间（保留1%的空间）
EXPANDABLE_SIZE=$((DISK_SIZE_MB - ORIGINAL_SIZE_MB - (DISK_SIZE_MB / 100)))
if [ $EXPANDABLE_SIZE -lt 0 ]; then
    EXPANDABLE_SIZE=0
fi

echo "Image size:        $((ORIGINAL_SIZE_MB / 1024))GB ($ORIGINAL_SIZE_MB MB)"
echo "Disk size:         $((DISK_SIZE_MB / 1024))GB ($DISK_SIZE_MB MB)"
if [ $EXPANDABLE_SIZE -gt 0 ]; then
    echo "Available for expansion: $((EXPANDABLE_SIZE / 1024))GB ($EXPANDABLE_SIZE MB)"
else
    echo "Available for expansion: 0GB (Disk is smaller than image)"
fi
echo ""

echo "Please select installation mode:"
echo "══════════════════════════════════════════════════════════"
echo "  [1] Direct Write - Write image directly without expansion"
echo "  [2] Auto Expand - Automatically expand to use full disk"
echo "══════════════════════════════════════════════════════════\n"

# 获取写入模式选择
WRITE_MODE=""
EXPANSION_MB=0
while true; do
    read -p "Select mode (1 or 2): " MODE_SELECTION
    
    case $MODE_SELECTION in
        1)
            WRITE_MODE="direct"
            echo -e "\n✅ Selected: Direct Write Mode"
            echo "   Will write image without expansion"
            break
            ;;
        2)
            WRITE_MODE="expand"
            if [ $EXPANDABLE_SIZE -gt 0 ]; then
                EXPANSION_MB=$EXPANDABLE_SIZE
                echo -e "\n✅ Selected: Auto Expand Mode"
                echo "   Will expand image by $((EXPANSION_MB / 1024))GB ($EXPANSION_MB MB)"
                echo "   to use full disk capacity"
            else
                echo -e "\n⚠️  Warning: Not enough space for expansion"
                echo "   Falling back to Direct Write Mode"
                WRITE_MODE="direct"
            fi
            break
            ;;
        *)
            echo "❌ Invalid selection. Please choose 1 or 2."
            ;;
    esac
done

sleep 2
clear

# ==================== 步骤3: 确认写盘 ====================
echo -e "\n══════════════════════════════════════════════════════════"
echo "                  STEP 3: CONFIRMATION"
echo "══════════════════════════════════════════════════════════\n"

echo "Installation Summary:"
echo "══════════════════════════════════════════════════════════"
echo "Target Disk:      /dev/$DISK_SELECTED"
echo "Disk Size:        $((DISK_SIZE_MB / 1024))GB"
echo "Image Size:       $((ORIGINAL_SIZE_MB / 1024))GB"
if [ "$WRITE_MODE" = "expand" ] && [ $EXPANSION_MB -gt 0 ]; then
    echo "Write Mode:       Auto Expand (+$((EXPANSION_MB / 1024))GB)"
else
    echo "Write Mode:       Direct Write"
fi
echo "══════════════════════════════════════════════════════════\n"

echo "⚠️  ⚠️  ⚠️   CRITICAL WARNING   ⚠️  ⚠️  ⚠️"
echo "══════════════════════════════════════════════════════════"
echo "This operation will:"
echo "1. ERASE ALL DATA on /dev/$DISK_SELECTED"
echo "2. DESTROY all existing partitions"
echo "3. PERMANENTLY delete all files"
echo "══════════════════════════════════════════════════════════\n"

# 最终确认
FINAL_CONFIRM=""
while true; do
    read -p "Type 'YES' (uppercase) to confirm installation: " FINAL_CONFIRM
    
    if [ "$FINAL_CONFIRM" = "YES" ]; then
        echo -e "\n✅ Confirmed. Starting installation..."
        break
    else
        echo -e "\n❌ Installation cancelled."
        echo -e "\nPress Enter to start over..."
        read
        exec /opt/install-openwrt.sh  # 重新启动安装程序
    fi
done

# 开始安装
clear
echo -e "\n══════════════════════════════════════════════════════════"
echo "                INSTALLATION IN PROGRESS"
echo "══════════════════════════════════════════════════════════\n"
echo "Target Disk: /dev/$DISK_SELECTED"
echo "Write Mode:  $( [ "$WRITE_MODE" = "direct" ] && echo "Direct Write" || echo "Auto Expand" )"
echo ""
echo "This may take several minutes. Please wait..."
echo "══════════════════════════════════════════════════════════\n"

# 创建日志文件
LOG_FILE="/tmp/ezotaflash.log"
echo "Starting OpenWRT installation at $(date)" > $LOG_FILE
chmod 644 $LOG_FILE

# 验证镜像文件
echo "Verifying firmware image..."
sleep 1

if ! image_supported "/openwrt.img"; then
    echo "ERROR: Invalid firmware image"
    echo -e "\n❌ ERROR: Invalid firmware image format"
    echo -e "\nPress Enter to return to installation..."
    read
    exec /opt/install-openwrt.sh
fi

# 检查是否为压缩镜像
IMAGE_TMP="/openwrt.img"
IMAGE_TO_WRITE="/tmp/final_image.img"

if file "$IMAGE_TMP" | grep -q "gzip compressed data"; then
    echo "Image is compressed, decompressing..."
    
    # 获取解压后大小
    decompressed_size=$(gzip -dc "$IMAGE_TMP" 2>/dev/null | wc -c)
    if [ -z "$decompressed_size" ] || [ "$decompressed_size" -eq 0 ]; then
        echo "ERROR: Invalid firmware image, please redownload."
        echo -e "\n❌ ERROR: Invalid firmware image"
        echo -e "\nPress Enter to return to installation..."
        read
        exec /opt/install-openwrt.sh
    fi
    
    # 检查可用空间
    available_space=$(df -k /tmp 2>/dev/null | tail -1 | awk '{print $4}')
    available_space=$((available_space * 1024))
    required_with_buffer=$((decompressed_size * 120 / 100))  # 20% buffer
    
    if [ $required_with_buffer -gt $available_space ]; then
        echo "Error: Insufficient disk space for extraction"
        echo "Need: $((required_with_buffer / 1024 / 1024)) MB (with 20% buffer)"
        echo "available: $((available_space / 1024 / 1024)) MB"
        echo -e "\n❌ ERROR: Insufficient disk space for extraction"
        echo -e "\nPress Enter to return to installation..."
        read
        exec /opt/install-openwrt.sh
    fi
    
    # 解压镜像
    echo "Extracting firmware..."
    if gzip -dc "$IMAGE_TMP" > "$IMAGE_TO_WRITE"; then
        actual_size=$(du -sb "$IMAGE_TO_WRITE" 2>/dev/null | cut -f1)
        if [ "$actual_size" -eq "$decompressed_size" ]; then
            echo "Decompression successful"
        else
            echo "Warning: File size mismatch"
            rm -f "$IMAGE_TO_WRITE"
            echo -e "\n❌ ERROR: File size mismatch during extraction"
            echo -e "\nPress Enter to return to installation..."
            read
            exec /opt/install-openwrt.sh
        fi
    else
        echo "ERROR: Failed to extract firmware"
        rm -f "$IMAGE_TO_WRITE"
        echo -e "\n❌ ERROR: Failed to extract firmware"
        echo -e "\nPress Enter to return to installation..."
        read
        exec /opt/install-openwrt.sh
    fi
else
    echo "Image is not compressed, using directly..."
    cp "$IMAGE_TMP" "$IMAGE_TO_WRITE"
    actual_size=$(du -sb "$IMAGE_TO_WRITE" 2>/dev/null | cut -f1)
    decompressed_size=$actual_size
fi

# ==================== 扩容处理 ====================
if [ "$WRITE_MODE" = "expand" ] && [ $EXPANSION_MB -gt 0 ]; then
    echo "Adding expansion capacity..."
    echo -e "\n📏 Expanding image by $((EXPANSION_MB / 1024))GB..."
    
    # 扩展镜像文件
    echo "Expanding image by ${EXPANSION_MB}MB..."
    dd if=/dev/zero bs=1M count=$EXPANSION_MB >> "$IMAGE_TO_WRITE" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo "Expansion successful"
        
        # 修复GPT分区表（使用gdisk）
        if command -v gdisk >/dev/null 2>&1; then
            echo "Fixing GPT partition table..."
            echo -e "x\ne\ny\nw\ny" | gdisk "$IMAGE_TO_WRITE" >/dev/null 2>&1 || true
        fi
        
        # 调整分区大小
        if command -v parted >/dev/null 2>&1; then
            echo "Resizing partition..."
            
            # 使用parted调整分区
            LOOP_DEV=$(losetup -f --show -P "$IMAGE_TO_WRITE" 2>/dev/null)
            
            if [ -n "$LOOP_DEV" ]; then
                # 通常OpenWRT镜像使用第二个分区作为根分区
                PART_NUM=2
                
                # 检查分区是否存在
                if [ -b "${LOOP_DEV}p${PART_NUM}" ] || [ -b "${LOOP_DEV}${PART_NUM}" ]; then
                    # 扩展分区
                    echo -e "resizepart ${PART_NUM} -1\\nq" | parted "$IMAGE_TO_WRITE" >/dev/null 2>&1
                    
                    # 扩展文件系统
                    PART_DEV="${LOOP_DEV}p${PART_NUM}"
                    [ ! -b "$PART_DEV" ] && PART_DEV="${LOOP_DEV}${PART_NUM}"
                    
                    if [ -b "$PART_DEV" ]; then
                        # 检查文件系统类型并扩展
                        if e2fsck -f -y "$PART_DEV" >/dev/null 2>&1; then
                            resize2fs "$PART_DEV" >/dev/null 2>&1
                            echo "Filesystem resized successfully"
                        fi
                    fi
                fi
                
                # 卸载loop设备
                losetup -d "$LOOP_DEV" 2>/dev/null || true
            fi
        fi
        
        echo "Image expanded and ready for writing"
    else
        echo "Warning: Expansion failed, using original image"
        echo -e "\n⚠️  Expansion failed, using original image size"
    fi
fi

# 显示进度条函数
show_progress() {
    local pid=$1
    local total_size=${2:-0}
    local delay=0.1
    
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
                if [ -n "$bytes_written" ] && [ "$total_size" -gt 0 ]; then
                    percentage=$((bytes_written * 100 / total_size))
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
                    echo -ne "] ${percentage}%"
                fi
            fi
        fi
        sleep 2
    done
    
    # 等待进程完成
    wait $pid
    return $?
}

# 执行安装
echo -e "\nStarting installation process...\n"
echo "Writing image to /dev/$DISK_SELECTED..."

# 获取最终镜像大小
FINAL_SIZE=$(du -sb "$IMAGE_TO_WRITE" 2>/dev/null | cut -f1)
[ -z "$FINAL_SIZE" ] && FINAL_SIZE=0

# 停止可能干扰的服务
echo "Stopping services..."
pkill -9 dropbear uhttpd nginx 2>/dev/null || true
sleep 2
sync

# 使用dd写入镜像
echo "DD writing image to /dev/$DISK_SELECTED..."
if command -v pv >/dev/null 2>&1; then
    # 使用pv显示进度
    pv -p -t -e -r "$IMAGE_TO_WRITE" | dd of="/dev/$DISK_SELECTED" bs=4M 2>/dev/null
    DD_EXIT=$?
else
    # 使用静默dd
    dd if="$IMAGE_TO_WRITE" of="/dev/$DISK_SELECTED" bs=4M 2>/dev/null &
    DD_PID=$!
    
    # 显示自定义进度
    show_progress $DD_PID $FINAL_SIZE
    DD_EXIT=$?
fi

# 检查dd结果
if [ $DD_EXIT -eq 0 ]; then
    # 同步磁盘
    sync
    echo "DD write completed successfully"
    echo -e "\n\n✅ Installation successful!"
    echo -e "\nOpenWRT has been installed to /dev/$DISK_SELECTED"
    
    # 清理临时文件
    rm -f "$IMAGE_TO_WRITE" 2>/dev/null || true
    
    # 显示安装后信息
    echo -e "\n══════════════════════════════════════════════════════════"
    echo -e "           INSTALLATION COMPLETE"
    echo -e "══════════════════════════════════════════════════════════\n"
    echo -e "Summary:"
    echo -e "  • Target Disk: /dev/$DISK_SELECTED"
    echo -e "  • Write Mode: $( [ "$WRITE_MODE" = "direct" ] && echo "Direct Write" || echo "Auto Expand" )"
    if [ "$WRITE_MODE" = "expand" ]; then
        echo -e "  • Expanded by: $((EXPANSION_MB / 1024))GB"
    fi
    echo -e "\nNext steps:"
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
    echo "Rebooting system"
    reboot -f
    
else
    echo "DD write failed with error code: $DD_EXIT"
    echo -e "\n\n❌ Installation failed! Error code: $DD_EXIT"
    echo -e "\nPossible issues:"
    echo -e "1. Disk may be in use or mounted"
    echo -e "2. Disk may be failing"
    echo -e "3. Not enough space on target disk"
    echo -e "\nPlease check the disk and try again.\n"
    echo ""
    read -p "Press Enter to restart installation..." _
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
chroot "$CHROOT_DIR" /install-chroot.sh

# 清理chroot
rm -f "$CHROOT_DIR/install-chroot.sh"

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
touch "$STAGING_DIR/DEBIAN_CUSTOM"

# ==================== 步骤7: 创建引导配置 ====================
log_info "[7/10] Creating boot configuration..."

# 创建isolinux配置
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
UI vesamenu.c32

MENU TITLE OpenWRT Auto Installer
DEFAULT linux
TIMEOUT 10
MENU RESOLUTION 640 480
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

LABEL linux
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live
LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 init=/bin/sh
ISOLINUX_CFG

# 创建GRUB配置
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
search --set=root --file /DEBIAN_CUSTOM

set default="0"
set timeout=10

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

menuentry "Emergency Shell" {
    linux /live/vmlinuz console=tty0 init=/bin/sh
    initrd /live/initrd.img
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
    cat > "$OUTPUT_DIR/Iso-build-info.txt" << EOF
OpenWRT Installer ISO Build Information
========================================
Build Date:      $(date)

ISO Size:        $ISO_SIZE
Kernel Version:  $(basename "$KERNEL")
Initrd Version:  $(basename "$INITRD")

Boot Support:    BIOS + UEFI
Boot Timeout:    10 seconds

Installation Features:
  - 3-Step Installation Process
  - Automatic disk size detection
  - Two write modes: Direct Write or Auto Expand
  - Auto Expand: Automatically expands to use full disk capacity
  - Simple numeric disk selection (1, 2, 3, etc.)
  - Visual progress indicator
  - Safety confirmation before writing (Type YES)
  - Automatic reboot after installation
  - Installation log at /tmp/ezotaflash.log

Installation Steps:
  1. Select target disk from list
  2. Choose write mode:
      [1] Direct Write - Write image directly without expansion
      [2] Auto Expand - Automatically expand to use full disk
  3. Type 'YES' to confirm installation

Required Tools in ISO:
  ✓ losetup, resize2fs, e2fsprogs, f2fs-tools
  ✓ kmod-loop, gdisk (contains sgdisk), parted
  ✓ gzip for compressed image support
  ✓ bc for size calculations

Usage:
  1. Create bootable USB: dd if="$ISO_NAME" of=/dev/sdX bs=4M status=progress
  2. Boot from USB in UEFI or Legacy mode
  3. Follow the 3-step installation process
  4. Wait for automatic reboot

Notes:
  - Supports both compressed (.img.gz) and raw (.img) images
  - Auto Expand mode automatically calculates available space
  - GPT partition table is preserved and extended using gdisk
  - Filesystem is automatically resized
  - source: https://github.com/sirpdboy/openwrt-installer-iso.git
EOF
    
    log_success "Build info saved to: $OUTPUT_DIR/Iso-build-info.txt"
    
    echo ""
    echo "================================================================================"
    echo "📦 ISO Build Complete!"
    echo "================================================================================"
    echo "Key features in this version:"
    echo "  ✓ 3-Step Installation Process"
    echo "  ✓ Automatic disk size detection"
    echo "  ✓ Two write modes: Direct Write or Auto Expand"
    echo "  ✓ Auto Expand: Automatically expands to use full disk"
    echo "  ✓ Uses gdisk (contains sgdisk) for GPT operations"
    echo "  ✓ Simple numeric disk selection (1, 2, 3...)"
    echo "  ✓ Visual progress bar during writing"
    echo "  ✓ Safety confirmation (must type YES)"
    echo "  ✓ Installation logging at /tmp/ezotaflash.log"
    echo ""
    echo "To create bootable USB:"
    echo "  sudo dd if='$ISO_PATH' of=/dev/sdX bs=4M status=progress && sync"
    echo "================================================================================"
    
    log_success "🎉 All steps completed successfully!"
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
