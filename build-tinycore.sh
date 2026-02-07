#!/bin/bash
# build-tinycore.sh - 基于Tiny Core Linux的极简OpenWRT安装ISO
set -e

echo "开始构建Tiny Core Linux安装ISO..."
echo "========================================"

# 配置
TINYCORE_VERSION="13.x"
ARCH="x86_64"
WORK_DIR="/tmp/tinycore-build"
ISO_DIR="${WORK_DIR}/iso"
BOOT_DIR="${ISO_DIR}/boot"
TC_DIR="${ISO_DIR}/cde"
OPTIONAL_DIR="${TC_DIR}/optional"

OPENWRT_IMG="${1:-assets/openwrt.img}"
OUTPUT_DIR="${2:-output}"
ISO_NAME="${3:-openwrt-tinycore-installer.iso}"

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
 
echo   OPENWRT_IMG:$OPENWRT_IMG    OUTPUT:$OUTPUT_DIR  ISO:$ISO_NAME


# 确保输出目录存在
mkdir -p "${OUTPUT_DIR}"

# 清理并创建工作目录
log_info "创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${ISO_DIR}" "${ISO_DIR}/boot" "${ISO_DIR}/boot/isolinux" "${ISO_DIR}/EFI/BOOT"

# 设置工作目录权限
chmod 755 "${WORK_DIR}" "${ISO_DIR}" "${ISO_DIR}/boot" "${ISO_DIR}/boot/isolinux" "${ISO_DIR}/EFI/BOOT"

# 下载官方Tiny Core Linux核心文件
log_info "下载Tiny Core Linux核心文件..."

# Tiny Core Linux镜像URL
TINYCORE_BASE="http://tinycorelinux.net/13.x/x86_64"
RELEASE_DIR="${TINYCORE_BASE}/release"
TCZ_DIR="${TINYCORE_BASE}/tcz"

# 下载内核
log_info "下载内核 vmlinuz64..."
cd "${WORK_DIR}"
if ! wget -q --tries=3 --timeout=60 "${RELEASE_DIR}/distribution_files/vmlinuz64" -O vmlinuz64; then
    log_error "内核下载失败"
    exit 1
fi
mv vmlinuz64 "${ISO_DIR}/boot/vmlinuz64"
chmod 644 "${ISO_DIR}/boot/vmlinuz64"
log_success "内核下载完成"

# 下载initrd
log_info "下载initrd core.gz..."
if ! wget -q --tries=3 --timeout=60 "${RELEASE_DIR}/distribution_files/corepure64.gz" -O core.gz; then
    log_error "initrd下载失败"
    exit 1
fi
mv core.gz "${ISO_DIR}/boot/core.gz"
chmod 644 "${ISO_DIR}/boot/core.gz"
log_success "initrd下载完成"

# 创建cde目录结构
log_info "创建cde目录结构..."
mkdir -p "${TC_DIR}" "${OPTIONAL_DIR}"
chmod 755 "${TC_DIR}" "${OPTIONAL_DIR}"

# 下载必要的扩展
log_info "下载必要扩展..."
cd "${OPTIONAL_DIR}"

# 扩展列表 - 精简版本，确保安装程序能启动
EXTENSIONS=(
    "bash.tcz"
    "dialog.tcz"
    "parted.tcz"
    "e2fsprogs.tcz"
    "coreutils.tcz"
    "findutils.tcz"
    "grep.tcz"
    "gawk.tcz"
    "sudo.tcz"
    "which.tcz"
)

DOWNLOADED_EXTS=()

for ext in "${EXTENSIONS[@]}"; do
    echo "下载扩展: $ext"
    if wget -q --tries=2 --timeout=30 "${TCZ_DIR}/${ext}" -O "${ext}"; then
        echo "✅ $ext"
        DOWNLOADED_EXTS+=("$ext")
        # 下载依赖文件（可选）
        wget -q "${TCZ_DIR}/${ext}.dep" -O "${ext}.dep" 2>/dev/null || true
        wget -q "${TCZ_DIR}/${ext}.md5.txt" -O "${ext}.md5.txt" 2>/dev/null || true
    else
        log_warning "无法下载 $ext，跳过"
    fi
done

# 创建onboot.lst文件 - 关键：确保基础扩展加载
log_info "创建onboot.lst..."
cat > "${TC_DIR}/onboot.lst" << 'ONBOOT_EOF'
bash.tcz
dialog.tcz
parted.tcz
e2fsprogs.tcz
coreutils.tcz
findutils.tcz
grep.tcz
gawk.tcz
ONBOOT_EOF

# 创建mydata.tgz - 包含我们的安装脚本和配置
log_info "创建mydata.tgz..."
mkdir -p "${WORK_DIR}/mydata"

# 创建安装脚本
cat > "${WORK_DIR}/mydata/install-openwrt.sh" << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT自动安装脚本 - Tiny Core版本

# 设置颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 显示标题
clear
echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║        OpenWRT Auto Installer (Tiny Core Linux)      ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo -e "${BLUE}正在启动安装程序...${NC}"
echo ""

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 需要root权限${NC}"
    echo "请重新以root运行: sudo $0"
    exit 1
fi

# 查找OpenWRT镜像
echo -e "${BLUE}查找OpenWRT镜像...${NC}"

# 尝试从CD/DVD读取
OPENWRT_IMG=""
if [ -f "/mnt/sr0/openwrt.img" ]; then
    OPENWRT_IMG="/mnt/sr0/openwrt.img"
elif [ -f "/mnt/cdrom/openwrt.img" ]; then
    OPENWRT_IMG="/mnt/cdrom/openwrt.img"
elif [ -f "/openwrt.img" ]; then
    OPENWRT_IMG="/openwrt.img"
else
    # 尝试挂载
    for dev in /dev/sr0 /dev/cdrom /dev/sr1; do
        if [ -b "$dev" ]; then
            mount_point="/mnt/$(basename $dev)"
            mkdir -p "$mount_point"
            if mount "$dev" "$mount_point" 2>/dev/null; then
                if [ -f "$mount_point/openwrt.img" ]; then
                    OPENWRT_IMG="$mount_point/openwrt.img"
                    break
                fi
                umount "$mount_point" 2>/dev/null
            fi
        fi
    done
fi

if [ -z "$OPENWRT_IMG" ] || [ ! -f "$OPENWRT_IMG" ]; then
    echo -e "${RED}❌ 错误: 找不到OpenWRT镜像${NC}"
    echo ""
    echo "请检查:"
    echo "1. 确保安装介质已正确连接"
    echo "2. 镜像文件名应为 openwrt.img"
    echo ""
    echo "当前目录内容:"
    ls -la / 2>/dev/null | head -10
    echo ""
    echo "按Enter键进入shell..."
    read
    exec /bin/bash
fi

echo -e "${GREEN}✅ 找到镜像: $OPENWRT_IMG${NC}"
IMG_SIZE=$(ls -lh "$OPENWRT_IMG" 2>/dev/null | awk '{print $5}' || echo "未知")
echo "镜像大小: $IMG_SIZE"
echo ""

# 主安装循环
while true; do
    # 显示可用磁盘
    echo -e "${BLUE}可用磁盘列表:${NC}"
    echo "================="
    
    # 使用lsblk或fdisk
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -o NAME,SIZE,MODEL | grep -v '^NAME' | while read line; do
            disk="/dev/$(echo $line | awk '{print $1}')"
            info=$(echo $line | cut -d' ' -f2-)
            echo "$disk - $info"
        done
    elif command -v fdisk >/dev/null 2>&1; then
        fdisk -l 2>/dev/null | grep -E '^Disk /dev/(sd|hd|nvme|vd)' | \
            sed 's/Disk //' | sed 's/://' | while read disk size rest; do
            echo "$disk - $size"
        done
    else
        echo "使用简单检测..."
        for disk in /dev/sd? /dev/hd? /dev/nvme?n? /dev/vd?; do
            [ -b "$disk" ] && echo "$disk"
        done
    fi
    
    echo "================="
    echo ""
    
    read -p "输入目标磁盘 (例如: sda, nvme0n1): " DISK_INPUT
    
    if [ -z "$DISK_INPUT" ]; then
        echo -e "${YELLOW}请输入磁盘名称${NC}"
        continue
    fi
    
    # 添加/dev/前缀
    if [[ ! "$DISK_INPUT" =~ ^/dev/ ]]; then
        DISK="/dev/$DISK_INPUT"
    else
        DISK="$DISK_INPUT"
    fi
    
    if [ ! -b "$DISK" ]; then
        echo -e "${RED}❌ 错误: 磁盘 $DISK 不存在${NC}"
        continue
    fi
    
    # 显示磁盘信息
    echo ""
    echo -e "${BLUE}磁盘信息:${NC}"
    if command -v fdisk >/dev/null 2>&1; then
        fdisk -l "$DISK" 2>/dev/null | head -5
    else
        echo "设备: $DISK"
        if [ -f "/sys/class/block/$(basename $DISK)/size" ]; then
            SECTORS=$(cat "/sys/class/block/$(basename $DISK)/size" 2>/dev/null || echo "0")
            SIZE_MB=$((SECTORS * 512 / 1024 / 1024))
            echo "大小: ${SIZE_MB}MB"
        fi
    fi
    echo ""
    
    # 最终确认
    echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}⚠️   严重警告! ⚠️${NC}"
    echo -e "${RED}这将完全擦除 $DISK 上的所有数据!${NC}"
    echo -e "${RED}所有分区和数据都将永久丢失!${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    read -p "输入 'YES' 确认安装 (大小写敏感): " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo -e "${YELLOW}操作已取消${NC}"
        continue
    fi
    
    # 开始安装
    clear
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}开始安装 OpenWRT 到 $DISK${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "源镜像: $OPENWRT_IMG"
    echo "目标磁盘: $DISK"
    echo ""
    
    # 检查pv工具
    if command -v pv >/dev/null 2>&1; then
        echo -e "${GREEN}使用pv显示进度...${NC}"
        echo ""
        pv -pet "$OPENWRT_IMG" | dd of="$DISK" bs=4M status=none
        RESULT=$?
    else
        echo -e "${YELLOW}使用dd复制 (可能需要几分钟)...${NC}"
        echo ""
        dd if="$OPENWRT_IMG" of="$DISK" bs=4M status=progress 2>/dev/null || \
        dd if="$OPENWRT_IMG" of="$DISK" bs=4M
        RESULT=$?
    fi
    
    # 同步数据
    echo ""
    echo "同步数据到磁盘..."
    sync
    
    if [ $RESULT -eq 0 ]; then
        echo ""
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✅ 安装成功完成!${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        
        # 重启选项
        echo "系统将在10秒后自动重启..."
        echo "按任意键取消重启并进入shell"
        
        # 倒计时
        for i in {10..1}; do
            if read -t 1 -n 1; then
                echo ""
                echo "重启已取消"
                echo "输入 'reboot' 重启系统"
                echo "输入 'poweroff' 关闭系统"
                echo "输入 'exit' 返回安装菜单"
                echo ""
                read -p "请选择: " CHOICE
                case "$CHOICE" in
                    reboot) reboot ;;
                    poweroff) poweroff ;;
                    *) continue 2 ;;
                esac
            fi
            echo -ne "重启倒计时: $i 秒...\r"
        done
        
        echo ""
        echo "正在重启..."
        reboot
        
    else
        echo ""
        echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}❌ 安装失败!${NC}"
        echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "错误代码: $RESULT"
        echo "可能原因: 磁盘空间不足或磁盘损坏"
        echo ""
        read -p "按Enter键返回安装菜单..."
    fi
done
INSTALL_SCRIPT

chmod +x "${WORK_DIR}/mydata/install-openwrt.sh"

# 创建自动启动脚本
cat > "${WORK_DIR}/mydata/autorun.sh" << 'AUTORUN'
#!/bin/sh
# Tiny Core Linux自动启动脚本

# 等待系统初始化
sleep 2

# 设置PATH
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 加载必要的扩展
echo "加载必要扩展..."
tce-load -i bash dialog parted 2>/dev/null || {
    echo "扩展加载失败，尝试继续..."
    sleep 2
}

# 挂载CDROM（如果尚未挂载）
if ! mount | grep -q '/mnt/sr0'; then
    mkdir -p /mnt/sr0
    mount /dev/sr0 /mnt/sr0 2>/dev/null || mount /dev/cdrom /mnt/sr0 2>/dev/null
fi

# 检查是否有安装脚本
if [ -x /mnt/sr0/cde/install-openwrt.sh ]; then
    echo "找到安装脚本，正在启动..."
    exec /mnt/sr0/cde/install-openwrt.sh
elif [ -x /install-openwrt.sh ]; then
    echo "找到本地安装脚本，正在启动..."
    exec /install-openwrt.sh
else
    echo "安装脚本未找到"
    echo ""
    echo "手动操作:"
    echo "1. 挂载CD: mount /dev/sr0 /mnt/sr0"
    echo "2. 运行: /mnt/sr0/cde/install-openwrt.sh"
    echo ""
    echo "按Enter键进入shell..."
    read dummy
    exec /bin/sh
fi
AUTORUN

chmod +x "${WORK_DIR}/mydata/autorun.sh"

# 创建bootlocal.sh（Tiny Core启动时自动执行）
cat > "${WORK_DIR}/mydata/bootlocal.sh" << 'BOOTLOCAL'
#!/bin/sh
# 在后台运行自动启动脚本
/usr/bin/tce-load -i bash 2>/dev/null
if [ -x /opt/autorun.sh ]; then
    /opt/autorun.sh &
elif [ -x /home/tc/autorun.sh ]; then
    /home/tc/autorun.sh &
fi
exit 0
BOOTLOCAL

chmod +x "${WORK_DIR}/mydata/bootlocal.sh"

# 创建自定义的.profile
cat > "${WORK_DIR}/mydata/.profile" << 'PROFILE'
# 自动启动安装程序
if [ -z "$INSTALL_STARTED" ]; then
    export INSTALL_STARTED=1
    if [ -x /opt/autorun.sh ]; then
        /opt/autorun.sh
    fi
fi
PROFILE

# 打包mydata.tgz
cd "${WORK_DIR}/mydata"
tar -czf "${TC_DIR}/mydata.tgz" .
cd "${WORK_DIR}"

# 复制OpenWRT镜像到ISO
log_info "复制OpenWRT镜像到ISO..."
cp "${OPENWRT_IMG}" "${ISO_DIR}/openwrt.img"
chmod 644 "${ISO_DIR}/openwrt.img"

# 复制安装脚本到cde目录（备份位置）
cp "${WORK_DIR}/mydata/install-openwrt.sh" "${TC_DIR}/install-openwrt.sh"
chmod +x "${TC_DIR}/install-openwrt.sh"

# 创建BIOS引导配置（ISOLINUX）
log_info "创建BIOS引导配置..."

# 复制ISOLINUX文件
if [ -f "/usr/lib/ISOLINUX/isolinux.bin" ]; then
    cp "/usr/lib/ISOLINUX/isolinux.bin" "${ISO_DIR}/boot/isolinux/"
    # 复制必要的模块
    for module in /usr/lib/syslinux/modules/bios/*.c32; do
        cp "$module" "${ISO_DIR}/boot/isolinux/" 2>/dev/null || true
    done
elif [ -f "/usr/share/syslinux/isolinux.bin" ]; then
    cp "/usr/share/syslinux/isolinux.bin" "${ISO_DIR}/boot/isolinux/"
    cp /usr/share/syslinux/menu.c32 "${ISO_DIR}/boot/isolinux/" 2>/dev/null || true
    cp /usr/share/syslinux/ldlinux.c32 "${ISO_DIR}/boot/isolinux/" 2>/dev/null || true
else
    log_warning "找不到ISOLINUX文件，尝试下载"
    wget -q "https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz" -O syslinux.tar.gz 2>/dev/null && \
        tar -xzf syslinux.tar.gz syslinux-6.04-pre1/bios/core/isolinux.bin syslinux-6.04-pre1/bios/com32/menu/menu.c32 && \
        cp syslinux-6.04-pre1/bios/core/isolinux.bin "${ISO_DIR}/boot/isolinux/" && \
        cp syslinux-6.04-pre1/bios/com32/menu/menu.c32 "${ISO_DIR}/boot/isolinux/" && \
        log_success "ISOLINUX文件下载成功" || \
        log_error "无法获取ISOLINUX文件"
fi

# 创建ISOLINUX配置
cat > "${ISO_DIR}/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT install
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE OpenWRT Installer - Tiny Core Linux
MENU BACKGROUND /boot/splash.png

MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std

LABEL install
  MENU LABEL ^Install OpenWRT (Auto)
  MENU DEFAULT
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz quiet waitusb=5 tce=cdrom opt=cdrom mydata=cdrom

LABEL install_nodata
  MENU LABEL Install OpenWRT (^No persistent data)
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz quiet waitusb=5 tce=cdrom opt=cdrom

LABEL shell
  MENU LABEL ^Shell (Debug mode)
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz quiet waitusb=5 tce=cdrom opt=cdrom norestore

LABEL local
  MENU LABEL ^Boot from local disk
  LOCALBOOT 0x80
  TIMEOUT 30
ISOLINUX_CFG

# 创建一个简单的启动背景
echo "iVBORw0KGgoAAAANSUhEUgAAAGQAAABkCAYAAABw4pVUAAAABHNCSVQICAgIfAhkiAAAAAlwSFlzAAAOxAAADsQBlSsOGwAAABl0RVh0U29mdHdhcmUAd3d3Lmlua3NjYXBlLm9yZ5vuPBoAAANCSURBVHic7d2xTttAGMDx/42MHjq1bAdWdgYeIXuX5hGSR8gj5BHSR2gfIV1YMzCyM/DQvAErC0s6sLIz8Ai5IyJt0qr5n47f7wMhhJD4fL7EdnznlGVZJiKy9n7xHUBEfCiIiA0KIj/WNgDWZ/edfw4d2UfGuIf7Gv/+1GmJ1trm2+gROAN6wAFwaP3ewFfgC3AH3ALXwFVmrf0q8R8uCUL6wDlwCuz7zsJzC1xlxpibkq9bKKQLXALnwI7vjD13wAUl7pVFQrrAJT4/m5f7BpwwZ9g8L0J2cEPTi7J4VzB6PcwL0gWuKDemZb4DR1lrYpY1j9gFbih76F3db2A/a03cI/PCCzL8rGyIe9V/ZM7z5sVn2CXlDl0hbOM2OROxkO38G1qsC9z4hEyulJg2+N0+E+/7JEgHuPE6c/0c4YavUfNCjvAbplblFvfwPzbvP3SdU35Iy7wD9kd3jAe5Jb1d4qHcN/kOkS8V25b8Wtr4e4m1dlvy61TF+/O+aJB1ahiiKkgaR0HSOAqSxlGQNI6CpHEUJI2jIGkcBUnjKEgaR0HSOAqSxlGQNI6CpHEUJI2jIGkcBUnjKEgaR0HSOAqSxlGQNI6CpHEUJI2jIGkcBUnjKEgaR0HSOAqSxlGQNI6CpHEUJI2jIGkcBUnjKEgaR0HSOAqSxlGQNI6CpHEUJI2jIGkcBUnjKEgaR0HSOAqSxlGQNI6CpHEUJI2jIGkcBUnjKEgaR0HSOAqSxlGQNI6CpHEUJI2jIGkcBUnjKEgaR0HSOAqSxlGQNI6CpHEUJI2jIGkcBUnjKEgaR0HSOAqSxlGQNI6CpHEUJI2jIGkcBUnjKEgaR0HSOAqSxlGQNI6CpHEUJI2jIGkcBUnjKEgaR0HSOAqSxlGQNI6CpHEUJI2jIGkcBUnjKEgaR0HSOAqSxlGQNE7b9wQiwHfgxvdJTcuv7O/q09J2fwC/gD98B4nAL8Bv4E/fQSKwD/wF/OU7SAT2gb+Ba98hInANXAMbvoNEoAvcA79v/j9cR3oP3G38P0R/a6tQvwM3vgOsqRtgkz9Djk6GXFVn+K2qw8l/sIV77/R6+N8PeG3Pj7gfkN3hfo3pG3BVZdbaxV8qImtkC3ecTfIcGL7GIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiLyogctzr1N7G3HEQAAAABJRU5ErkJggg==" | base64 -d > "${ISO_DIR}/boot/splash.png" 2>/dev/null || true

# 创建UEFI引导配置
log_info "创建UEFI引导配置..."

# 创建GRUB目录结构
mkdir -p "${ISO_DIR}/boot/grub"

# 创建GRUB配置
cat > "${ISO_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (Auto Install)" {
    linux /boot/vmlinuz64 quiet waitusb=5 tce=cdrom opt=cdrom mydata=cdrom
    initrd /boot/core.gz
}

menuentry "Install OpenWRT (No persistent data)" {
    linux /boot/vmlinuz64 quiet waitusb=5 tce=cdrom opt=cdrom
    initrd /boot/core.gz
}

menuentry "Shell (Debug mode)" {
    linux /boot/vmlinuz64 quiet waitusb=5 tce=cdrom opt=cdrom norestore
    initrd /boot/core.gz
}

menuentry "Boot from local disk" {
    exit
}
GRUB_CFG

# 创建EFI引导文件
if command -v grub-mkstandalone >/dev/null 2>&1; then
    log_info "生成GRUB EFI引导文件..."
    
    # 方法1: 使用grub-mkstandalone
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="${ISO_DIR}/EFI/BOOT/bootx64.efi" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos ext2 fat iso9660" \
        "boot/grub/grub.cfg=${ISO_DIR}/boot/grub/grub.cfg" 2>/dev/null
    
    if [ $? -eq 0 ] && [ -f "${ISO_DIR}/EFI/BOOT/bootx64.efi" ]; then
        log_success "GRUB EFI文件生成成功"
    else
        log_warning "grub-mkstandalone失败，尝试其他方法"
        
        # 方法2: 复制预编译的GRUB EFI文件
        if [ -f "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" ]; then
            cp "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" \
                "${ISO_DIR}/EFI/BOOT/bootx64.efi"
            log_success "复制GRUB EFI文件成功"
        elif [ -f "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" ]; then
            cp "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" \
                "${ISO_DIR}/EFI/BOOT/bootx64.efi"
            log_success "复制GRUB EFI文件成功"
        else
            log_warning "无法创建UEFI引导文件，将创建仅BIOS引导的ISO"
        fi
    fi
else
    log_warning "grub-mkstandalone不可用，尝试复制现有文件"
    
    # 尝试复制现有的GRUB EFI文件
    for path in \
        "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" \
        "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" \
        "/usr/share/grub/grub-efi-amd64.efi" \
        "/boot/grub/x86_64-efi/core.efi"; do
        if [ -f "$path" ]; then
            cp "$path" "${ISO_DIR}/EFI/BOOT/bootx64.efi"
            log_success "从 $path 复制GRUB EFI文件成功"
            break
        fi
    done
fi

# 如果需要，创建IA32 UEFI引导
if [ -f "${ISO_DIR}/EFI/BOOT/bootx64.efi" ]; then
    # 尝试创建IA32版本
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        grub-mkstandalone \
            --format=i386-efi \
            --output="${ISO_DIR}/EFI/BOOT/bootia32.efi" \
            --locales="" \
            --fonts="" \
            --modules="part_gpt part_msdos ext2 fat iso9660" \
            "boot/grub/grub.cfg=${ISO_DIR}/boot/grub/grub.cfg" 2>/dev/null && \
            log_success "IA32 UEFI引导文件生成成功"
    fi
fi

# 构建ISO镜像
log_info "构建ISO镜像..."
cd "${ISO_DIR}"

# 检查是否有EFI引导文件
HAS_EFI=false
if [ -f "EFI/BOOT/bootx64.efi" ] || [ -f "EFI/BOOT/bootia32.efi" ]; then
    HAS_EFI=true
    log_info "检测到UEFI引导文件，构建双引导ISO"
fi

# 使用xorriso构建ISO（支持双引导）
if command -v xorriso >/dev/null 2>&1; then
    log_info "使用xorriso构建双引导ISO..."
    
    XORRISO_ARGS="-as mkisofs \
        -iso-level 3 \
        -volid 'OPENWRT-INSTALL' \
        -eltorito-boot boot/isolinux/isolinux.bin \
        -eltorito-catalog boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -r -J \
        -o '${OUTPUT_DIR}/${ISO_NAME}'"
    
    # 如果有EFI文件，添加UEFI引导
    if [ "$HAS_EFI" = true ]; then
        XORRISO_ARGS="$XORRISO_ARGS \
            -eltorito-alt-boot \
            -e EFI/BOOT/bootx64.efi \
            -no-emul-boot \
            -isohybrid-gpt-basdat"
    fi
    
    XORRISO_ARGS="$XORRISO_ARGS ."
    
    echo "执行构建命令..."
    eval xorriso $XORRISO_ARGS 2>&1 | tee /tmp/iso_build.log
    
    if [ $? -eq 0 ]; then
        log_success "ISO构建成功"
    else
        log_warning "xorriso构建失败，尝试其他方法"
    fi
fi

# 如果xorriso失败或未安装，尝试genisoimage
if [ ! -f "${OUTPUT_DIR}/${ISO_NAME}" ] && command -v genisoimage >/dev/null 2>&1; then
    log_info "使用genisoimage构建ISO..."
    
    GENISO_ARGS="-U -r -v -J -joliet-long \
        -V 'OPENWRT-INSTALL' \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -o '${OUTPUT_DIR}/${ISO_NAME}'"
    
    # 如果有EFI文件，添加UEFI引导
    if [ "$HAS_EFI" = true ]; then
        GENISO_ARGS="$GENISO_ARGS \
            -eltorito-alt-boot \
            -e EFI/BOOT/bootx64.efi \
            -no-emul-boot"
    fi
    
    GENISO_ARGS="$GENISO_ARGS ."
    
    echo "执行构建命令..."
    eval genisoimage $GENISO_ARGS 2>&1 | tee -a /tmp/iso_build.log
fi

# 如果genisoimage也失败，尝试最简单的mkisofs
if [ ! -f "${OUTPUT_DIR}/${ISO_NAME}" ] && command -v mkisofs >/dev/null 2>&1; then
    log_info "使用mkisofs构建ISO..."
    
    mkisofs \
        -o "${OUTPUT_DIR}/${ISO_NAME}" \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -V "OPENWRT-INSTALL" \
        . 2>&1 | tee -a /tmp/iso_build.log
fi

# 验证ISO
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    ISO_SIZE=$(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')
    ISO_SIZE_BYTES=$(stat -c%s "${OUTPUT_DIR}/${ISO_NAME}")
    ISO_SIZE_MB=$((ISO_SIZE_BYTES / 1024 / 1024))
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║            ISO构建完成!                              ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    echo "📊 构建信息:"
    echo "   文件: ${ISO_NAME}"
    echo "   大小: ${ISO_SIZE} (${ISO_SIZE_MB}MB)"
    echo "   卷标: OPENWRT-INSTALL"
    echo "   引导: $([ "$HAS_EFI" = true ] && echo "BIOS + UEFI" || echo "BIOS")"
    echo "   内核: Tiny Core Linux ${TINYCORE_VERSION}"
    echo ""
    echo "✅ 关键特性:"
    echo "   - 自动启动安装程序"
    echo "   - 支持BIOS和UEFI双引导"
    echo "   - 包含磁盘工具(parted, fdisk等)"
    echo "   - 交互式安装界面"
    echo ""
    echo "🚀 使用方法:"
    echo "   1. 刻录到U盘: dd if=${ISO_NAME} of=/dev/sdX bs=4M status=progress"
    echo "   2. 从U盘启动计算机"
    echo "   3. 自动进入安装界面"
    echo "   4. 选择目标磁盘并输入'YES'确认"
    echo ""
    echo "⚠️  重要警告:"
    echo "   - 安装会完全擦除目标磁盘数据!"
    echo "   - 请提前备份重要数据!"
    echo ""
    
    # 创建构建摘要
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Tiny Core Installer ISO
===============================
构建时间: $(date)
ISO文件: ${ISO_NAME}
文件大小: ${ISO_SIZE} (${ISO_SIZE_MB}MB)
基于: Tiny Core Linux ${TINYCORE_VERSION}
引导支持: $([ "$HAS_EFI" = true ] && echo "BIOS + UEFI (Hybrid)" || echo "BIOS")
包含工具: bash, dialog, parted, e2fsprogs
自动启动: 是 (通过mydata.tgz)
安装镜像: $(basename ${OPENWRT_IMG})
注意事项: 安装会完全擦除目标磁盘数据，请提前备份！
BUILD_INFO
    
    log_success "构建摘要已保存到: ${OUTPUT_DIR}/build-info.txt"
    
    # 验证ISO引导
    echo "🔍 ISO验证:"
    file "${OUTPUT_DIR}/${ISO_NAME}"
    
    # 检查引导信息
    if command -v xorriso >/dev/null 2>&1; then
        echo ""
        echo "📋 ISO引导信息:"
        xorriso -indev "${OUTPUT_DIR}/${ISO_NAME}" -toc 2>/dev/null | \
            grep -E "(El.Torito|Bootable|UEFI|GPT)" || true
    fi
    
else
    log_error "ISO构建失败!"
    echo "构建日志:"
    cat /tmp/iso_build.log 2>/dev/null | tail -20
    echo ""
    echo "当前目录内容:"
    ls -la "${ISO_DIR}/" 2>/dev/null | head -10
    exit 1
fi

# 清理临时文件
log_info "清理临时文件..."
rm -rf "${WORK_DIR}"

log_success "✅ 所有步骤完成! Tiny Core Linux安装ISO已创建"
