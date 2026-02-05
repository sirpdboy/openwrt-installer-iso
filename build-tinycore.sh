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

# 检查必要文件
log_info "检查必要文件..."
if [ ! -f "${OPENWRT_IMG}" ]; then
    log_error "找不到OpenWRT镜像: ${OPENWRT_IMG}"
    exit 1
fi

# 清理并创建工作目录
log_info "创建工作目录..."
sudo rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${ISO_DIR}" "${OUTPUT_DIR}"
chmod 755 "${WORK_DIR}" "${ISO_DIR}" "${OUTPUT_DIR}"

# 使用sudo权限创建必要的子目录
sudo mkdir -p "${ISO_DIR}/boot/isolinux"
sudo chmod 755 "${ISO_DIR}/boot" "${ISO_DIR}/boot/isolinux"

# 下载官方Tiny Core Linux核心文件
log_info "下载Tiny Core Linux核心文件..."

# Tiny Core Linux镜像URL
TINYCORE_BASE="http://tinycorelinux.net/13.x/x86_64"
RELEASE_DIR="${TINYCORE_BASE}/release"
TCZ_DIR="${TINYCORE_BASE}/tcz"

# 下载内核和initrd
log_info "下载内核..."
if ! wget -q --tries=3 --timeout=30 "${RELEASE_DIR}/distribution_files/vmlinuz64" -O "${ISO_DIR}/boot/vmlinuz64"; then
    log_error "无法下载内核"
    exit 1
fi

log_info "下载initrd..."
if ! wget -q --tries=3 --timeout=30 "${RELEASE_DIR}/distribution_files/corepure64.gz" -O "${ISO_DIR}/boot/core.gz"; then
    log_error "无法下载initrd"
    exit 1
fi

# 下载rootfs（可选，Tiny Core Linux通常不需要单独的rootfs）
log_info "下载rootfs.gz..."
wget -q --tries=2 --timeout=20 "${RELEASE_DIR}/distribution_files/rootfs64.gz" -O "${ISO_DIR}/boot/rootfs.gz" 2>/dev/null || {
    log_warning "无法下载rootfs.gz，创建空文件"
    echo "Tiny Core Linux不需要单独的rootfs" > "${ISO_DIR}/boot/rootfs.gz"
}

# 创建cde目录结构
log_info "创建cde目录结构..."
sudo mkdir -p "${TC_DIR}" "${OPTIONAL_DIR}"
sudo chmod 755 "${TC_DIR}" "${OPTIONAL_DIR}"

# 下载必要的扩展
log_info "下载必要扩展..."
# 定义扩展列表及其备用名称
declare -A EXTENSION_MAP=(
    ["bash.tcz"]="bash.tcz"
    ["dialog.tcz"]="dialog.tcz"
    ["parted.tcz"]="parted.tcz"
    ["ntfs-3g.tcz"]="ntfs-3g.tcz"
    ["gptfdisk.tcz"]="gdisk.tcz"  # 备用名称
    ["e2fsprogs.tcz"]="e2fsprogs.tcz"
    ["syslinux.tcz"]="syslinux.tcz"
    ["grub2-multi.tcz"]="grub2.tcz"  # 备用名称
    ["mpv.tcz"]="pv.tcz"
    ["ncursesw.tcz"]="ncursesw.tcz"
    ["readline.tcz"]="readline.tcz"
    ["coreutils.tcz"]="coreutils.tcz"  # 新增：基本工具
    ["findutils.tcz"]="findutils.tcz"  # 新增：find工具
    ["grep.tcz"]="grep.tcz"  # 新增：grep工具
    ["gawk.tcz"]="gawk.tcz"  # 新增：awk工具
)

DOWNLOADED_EXTS=()

for ext_name in "${!EXTENSION_MAP[@]}"; do
    primary_ext="${EXTENSION_MAP[$ext_name]}"
    downloaded=false
    
    echo "下载扩展: $ext_name"
    
    # 尝试主名称
    if wget -q --tries=2 --timeout=20 "${TCZ_DIR}/${primary_ext}" -O "${OPTIONAL_DIR}/${ext_name}"; then
        echo "? $ext_name"
        downloaded=true
    else
        # 尝试使用原始名称作为备用
        if wget -q --tries=1 --timeout=15 "${TCZ_DIR}/${ext_name}" -O "${OPTIONAL_DIR}/${ext_name}"; then
            echo "? $ext_name (使用备用URL)"
            downloaded=true
        fi
    fi
    
    if [ "$downloaded" = true ]; then
        DOWNLOADED_EXTS+=("$ext_name")
        # 下载依赖和校验文件
        wget -q "${TCZ_DIR}/${ext_name}.dep" -O "${OPTIONAL_DIR}/${ext_name}.dep" 2>/dev/null || true
        wget -q "${TCZ_DIR}/${ext_name}.md5.txt" -O "${OPTIONAL_DIR}/${ext_name}.md5.txt" 2>/dev/null || true
        wget -q "${TCZ_DIR}/${ext_name}.info" -O "${OPTIONAL_DIR}/${ext_name}.info" 2>/dev/null || true
    else
        log_warning "无法下载 $ext_name"
        # 检查是否有依赖关系
        if [[ "$ext_name" == "gptfdisk.tcz" ]]; then
            log_info "gptfdisk不是必需的，使用parted替代"
        elif [[ "$ext_name" == "pv.tcz" ]]; then
            log_info "pv不是必需的，使用dd替代"
        fi
    fi
done

# 创建onboot.lst文件（只包含成功下载的扩展）
log_info "创建onboot.lst..."
sudo tee "${TC_DIR}/onboot.lst" > /dev/null << 'ONBOOT_HEADER'
# 自动启动的扩展列表
ONBOOT_HEADER

for ext in "${DOWNLOADED_EXTS[@]}"; do
    echo "$ext" | sudo tee -a "${TC_DIR}/onboot.lst" > /dev/null
done

# 添加一些基础扩展（即使下载失败也列出）
echo "bash.tcz" | sudo tee -a "${TC_DIR}/onboot.lst" > /dev/null
echo "dialog.tcz" | sudo tee -a "${TC_DIR}/onboot.lst" > /dev/null
echo "parted.tcz" | sudo tee -a "${TC_DIR}/onboot.lst" > /dev/null
echo "e2fsprogs.tcz" | sudo tee -a "${TC_DIR}/onboot.lst" > /dev/null

# 创建安装脚本
log_info "创建安装脚本..."
sudo tee "${TC_DIR}/install-openwrt.sh" > /dev/null << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT自动安装脚本 - Tiny Core版本

# 设置颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 清屏并显示标题
clear
cat << "EOF"

╔═══════════════════════════════════════════════════════╗
║        OpenWRT Auto Installer (Tiny Core Linux)      ║
╚═══════════════════════════════════════════════════════╝

EOF

# 检查是否以root运行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 需要root权限运行此脚本${NC}"
    echo "请输入: sudo $0"
    exit 1
fi

# 查找OpenWRT镜像
find_openwrt_image() {
    # 检查常见位置
    local locations=(
        "/mnt/sr0/openwrt.img"
        "/mnt/cdrom/openwrt.img"
        "/mnt/sr0/cde/openwrt.img"
        "/mnt/cdrom/cde/openwrt.img"
        "/openwrt.img"
        "/tmp/openwrt.img"
    )
    
    for loc in "${locations[@]}"; do
        if [ -f "$loc" ]; then
            echo "$loc"
            return 0
        fi
    done
    
    # 尝试挂载和查找
    local mount_points=("/mnt/sr0" "/mnt/cdrom")
    for mp in "${mount_points[@]}"; do
        if [ ! -d "$mp" ]; then
            mkdir -p "$mp"
        fi
        
        # 尝试挂载CD
        mount /dev/sr0 "$mp" 2>/dev/null || \
        mount /dev/cdrom "$mp" 2>/dev/null || \
        mount /dev/sr1 "$mp" 2>/dev/null
        
        if mountpoint -q "$mp"; then
            # 在挂载点中查找
            find "$mp" -name "*.img" -type f 2>/dev/null | head -1
            return $?
        fi
    done
    
    return 1
}

# 查找OpenWRT镜像
echo "正在查找OpenWRT镜像..."
OPENWRT_IMG=$(find_openwrt_image)

if [ -z "$OPENWRT_IMG" ] || [ ! -f "$OPENWRT_IMG" ]; then
    echo -e "${RED}? 错误: 找不到OpenWRT镜像${NC}"
    echo ""
    echo "请确保:"
    echo "1. ISO正确刻录到USB或CD"
    echo "2. 设备已正确挂载"
    echo ""
    echo "手动挂载:"
    echo "  mkdir -p /mnt/cdrom"
    echo "  mount /dev/sr0 /mnt/cdrom"
    echo ""
    echo "当前挂载的设备:"
    mount | grep -E '(sr|cdrom)' || echo "无CD/DVD设备挂载"
    echo ""
    echo "按Enter键进入shell..."
    read
    exec /bin/bash
fi

echo -e "${GREEN}? 找到OpenWRT镜像: $OPENWRT_IMG${NC}"
echo "大小: $(ls -lh "$OPENWRT_IMG" | awk '{print $5}')"
echo ""

# 显示可用磁盘
list_disks() {
    echo "可用磁盘:"
    echo "================="
    
    # 使用lsblk如果可用
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -o NAME,SIZE,MODEL | grep -v '^NAME' | while read line; do
            echo "/dev/$(echo $line | awk '{print $1}') - $(echo $line | cut -d' ' -f2-)"
        done
    else
        # 使用fdisk
        fdisk -l 2>/dev/null | grep -E '^Disk /dev/(sd|hd|nvme|vd|mmc)' | \
            sed 's/Disk //' | sed 's/://' | while read disk size rest; do
            echo "$disk - $size"
        done
    fi
    
    echo "================="
}

# 主安装循环
while true; do
    list_disks
    echo ""
    
    read -p "输入目标磁盘 (例如: sda, nvme0n1, 或完整路径如 /dev/sda): " DISK_INPUT
    
    if [ -z "$DISK_INPUT" ]; then
        echo -e "${YELLOW}请输入磁盘名称${NC}"
        continue
    fi
    
    # 处理磁盘输入
    if [[ "$DISK_INPUT" =~ ^/dev/ ]]; then
        DISK="$DISK_INPUT"
    else
        DISK="/dev/$DISK_INPUT"
    fi
    
    # 检查磁盘是否存在
    if [ ! -b "$DISK" ]; then
        echo -e "${RED}? 错误: 磁盘 $DISK 不存在${NC}"
        continue
    fi
    
    # 检查是否系统磁盘（防止意外擦除）
    if mount | grep -q "^$DISK"; then
        echo -e "${RED}??  警告: $DISK 当前已挂载${NC}"
        mount | grep "^$DISK"
        echo ""
    fi
    
    # 显示磁盘详细信息
    echo ""
    echo "磁盘详细信息:"
    if command -v fdisk >/dev/null 2>&1; then
        fdisk -l "$DISK" 2>/dev/null | head -20
    else
        echo "无法获取详细磁盘信息"
    fi
    echo ""
    
    # 最终确认
    echo -e "${RED}??  ??  ??  严重警告: ??  ??  ??${NC}"
    echo -e "${RED}这将完全擦除 $DISK 上的所有数据!${NC}"
    echo -e "${RED}所有分区和数据都将永久丢失!${NC}"
    echo ""
    
    read -p "输入 'YES' 确认安装 (大小写敏感): " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo -e "${YELLOW}操作已取消${NC}"
        continue
    fi
    
    # 开始安装
    clear
    echo ""
    echo -e "${GREEN}正在安装 OpenWRT 到 $DISK...${NC}"
    echo "源镜像: $OPENWRT_IMG"
    echo "目标磁盘: $DISK"
    echo ""
    
    # 显示进度
    echo "开始复制..."
    START_TIME=$(date +%s)
    
    # 检查是否有pv工具
    if command -v pv >/dev/null 2>&1; then
        echo -e "${GREEN}使用pv显示进度...${NC}"
        pv -pet "$OPENWRT_IMG" | dd of="$DISK" bs=4M status=none
        DD_EXIT=$?
    else
        echo -e "${YELLOW}使用dd安装 (无进度显示)...${NC}"
        echo "这可能需要几分钟，请耐心等待..."
        dd if="$OPENWRT_IMG" of="$DISK" bs=4M
        DD_EXIT=$?
    fi
    
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    # 强制同步
    sync
    
    # 检查结果
    if [ $DD_EXIT -eq 0 ]; then
        echo ""
        echo -e "${GREEN}? 安装成功完成!${NC}"
        echo "耗时: ${DURATION}秒"
        echo ""
        
        # 显示最终磁盘信息
        echo "安装后的磁盘信息:"
        if command -v fdisk >/dev/null 2>&1; then
            fdisk -l "$DISK" 2>/dev/null | head -10
        fi
        echo ""
        
        # 重启选项
        echo "选择下一步操作:"
        echo "1) 立即重启"
        echo "2) 返回安装菜单"
        echo "3) 进入shell"
        echo ""
        
        read -p "请输入选项 (1-3): " CHOICE
        
        case "$CHOICE" in
            1)
                echo "系统将在5秒后重启..."
                for i in {5..1}; do
                    echo -ne "重启倒计时: $i 秒...\r"
                    sleep 1
                done
                echo ""
                echo "正在重启..."
                reboot
                ;;
            2)
                echo "返回安装菜单..."
                continue
                ;;
            3)
                echo "进入shell..."
                echo "输入 'exit' 返回安装菜单"
                echo "输入 'reboot' 重启系统"
                exec /bin/bash
                ;;
            *)
                echo "返回安装菜单..."
                continue
                ;;
        esac
        
    else
        echo ""
        echo -e "${RED}? 安装失败!${NC}"
        echo "dd退出代码: $DD_EXIT"
        echo ""
        echo "可能的原因:"
        echo "1. 磁盘空间不足"
        echo "2. 磁盘损坏"
        echo "3. 镜像文件损坏"
        echo ""
        read -p "按Enter键返回安装菜单..."
    fi
done
INSTALL_SCRIPT

sudo chmod +x "${TC_DIR}/install-openwrt.sh"

# 创建bootlocal.sh
log_info "创建bootlocal.sh..."
sudo tee "${TC_DIR}/bootlocal.sh" > /dev/null << 'BOOTLOCAL'
#!/bin/sh
# Tiny Core启动后自动执行

# 等待基本系统启动
sleep 2

# 加载必要的扩展
if [ -d /usr/local/tce.installed ]; then
    echo "等待扩展加载..."
    sleep 3
fi

# 清屏并显示信息
clear
echo ""
echo "========================================"
echo "    OpenWRT Auto Installer"
echo "    Based on Tiny Core Linux"
echo "========================================"
echo ""
echo "正在启动安装程序..."
echo ""

# 检查CD是否挂载
CD_MOUNT="/mnt/sr0"
if [ ! -d "$CD_MOUNT" ]; then
    mkdir -p "$CD_MOUNT"
fi

# 尝试挂载CD
if ! mountpoint -q "$CD_MOUNT"; then
    echo "挂载安装介质..."
    mount /dev/sr0 "$CD_MOUNT" 2>/dev/null || \
    mount /dev/cdrom "$CD_MOUNT" 2>/dev/null || \
    mount /dev/sr1 "$CD_MOUNT" 2>/dev/null || {
        echo "无法自动挂载CD，请手动操作"
    }
fi

# 执行安装脚本
INSTALL_SCRIPT=""
for script in "$CD_MOUNT/cde/install-openwrt.sh" "$CD_MOUNT/install-openwrt.sh"; do
    if [ -x "$script" ]; then
        INSTALL_SCRIPT="$script"
        break
    fi
done

if [ -n "$INSTALL_SCRIPT" ]; then
    echo "找到安装脚本: $INSTALL_SCRIPT"
    echo "正在启动..."
    sleep 2
    exec "$INSTALL_SCRIPT"
else
    echo "安装脚本未找到"
    echo ""
    echo "手动操作步骤:"
    echo "1. 挂载CD: mount /dev/sr0 /mnt/cdrom"
    echo "2. 查找镜像: find /mnt/cdrom -name '*.img'"
    echo "3. 运行安装: /mnt/cdrom/cde/install-openwrt.sh"
    echo ""
    echo "按Enter键进入shell..."
    read dummy
    exec /bin/bash
fi
BOOTLOCAL

sudo chmod +x "${TC_DIR}/bootlocal.sh"

# 复制OpenWRT镜像到ISO
log_info "复制OpenWRT镜像到ISO..."
sudo cp "${OPENWRT_IMG}" "${ISO_DIR}/openwrt.img"
sudo chmod 644 "${ISO_DIR}/openwrt.img"

# 创建BIOS引导配置
log_info "配置BIOS引导..."
sudo tee "${ISO_DIR}/boot/isolinux/isolinux.cfg" > /dev/null << 'ISOLINUX_CFG'
DEFAULT openwrt
PROMPT 0
TIMEOUT 100
UI menu.c32

MENU TITLE OpenWRT Tiny Core Installer
MENU BACKGROUND /boot/splash.png

MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR cmdline      37;40   #c0ffffff #00000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

LABEL openwrt
  MENU LABEL ^Install OpenWRT (自动安装)
  MENU DEFAULT
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz,/boot/rootfs.gz quiet tce=cdrom waitusb=5 opt=cdrom

LABEL shell
  MENU LABEL ^Shell (调试模式)
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz,/boot/rootfs.gz quiet tce=cdrom waitusb=5 opt=cdrom norestore

LABEL local
  MENU LABEL ^Boot from local drive
  LOCALBOOT 0x80
  TIMEOUT 50
ISOLINUX_CFG

# 复制ISOLINUX引导文件
log_info "复制ISOLINUX引导文件..."
if [ -f "/usr/lib/ISOLINUX/isolinux.bin" ]; then
    sudo cp "/usr/lib/ISOLINUX/isolinux.bin" "${ISO_DIR}/boot/isolinux/"
    # 复制必要的模块
    for module in /usr/lib/syslinux/modules/bios/*.c32; do
        sudo cp "$module" "${ISO_DIR}/boot/isolinux/" 2>/dev/null || true
    done
elif [ -f "/usr/share/syslinux/isolinux.bin" ]; then
    sudo cp "/usr/share/syslinux/isolinux.bin" "${ISO_DIR}/boot/isolinux/"
fi

# 创建简单的背景图片（可选）
echo "创建简单的启动背景..." | sudo tee "${ISO_DIR}/boot/splash.png" > /dev/null

# 创建UEFI引导
log_info "准备UEFI引导..."
sudo mkdir -p "${ISO_DIR}/EFI/BOOT"

# 使用grub-mkstandalone创建EFI引导文件
if command -v grub-mkstandalone >/dev/null 2>&1; then
    log_info "生成GRUB EFI引导文件..."
    
    # 创建临时GRUB配置
    TEMP_GRUB_DIR="${WORK_DIR}/grub-temp"
    mkdir -p "${TEMP_GRUB_DIR}/boot/grub"
    
    cat > "${TEMP_GRUB_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (Tiny Core Linux)" {
    linux /boot/vmlinuz64 quiet tce=cdrom waitusb=5 opt=cdrom
    initrd /boot/core.gz /boot/rootfs.gz
}

menuentry "Shell (debug mode)" {
    linux /boot/vmlinuz64 quiet tce=cdrom waitusb=5 opt=cdrom norestore
    initrd /boot/core.gz /boot/rootfs.gz
}

menuentry "Boot from local disk" {
    exit
}
GRUB_CFG
    
    # 生成EFI文件
    if grub-mkstandalone \
        --format=x86_64-efi \
        --output="${ISO_DIR}/EFI/BOOT/bootx64.efi" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos" \
        "boot/grub/grub.cfg=${TEMP_GRUB_DIR}/boot/grub/grub.cfg" 2>/dev/null; then
        log_success "GRUB EFI文件生成成功"
    else
        log_warning "GRUB EFI文件生成失败，使用备用方法"
        # 尝试复制现有的EFI文件
        if [ -f "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" ]; then
            sudo cp "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" \
                "${ISO_DIR}/EFI/BOOT/bootx64.efi"
        elif [ -f "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" ]; then
            sudo cp "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" \
                "${ISO_DIR}/EFI/BOOT/bootx64.efi"
        fi
    fi
    
    # 复制GRUB配置文件到ISO
    sudo mkdir -p "${ISO_DIR}/boot/grub"
    sudo cp "${TEMP_GRUB_DIR}/boot/grub/grub.cfg" "${ISO_DIR}/boot/grub/"
else
    log_warning "grub-mkstandalone不可用，跳过UEFI引导"
fi

# 构建ISO镜像
log_info "构建ISO镜像..."

cd "${ISO_DIR}"

# 首先计算ISO大小
ISO_SIZE_ESTIMATE=$(du -sb . | cut -f1)
ISO_SIZE_MB=$((ISO_SIZE_ESTIMATE / 1024 / 1024))
log_info "ISO估计大小: ${ISO_SIZE_MB}MB"

# 使用xorriso构建ISO
if command -v xorriso >/dev/null 2>&1; then
    log_info "使用xorriso构建双引导ISO..."
    
    XORRISO_CMD="xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid 'OPENWRT-INSTALL' \
        -eltorito-boot boot/isolinux/isolinux.bin \
        -eltorito-catalog boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -r -J \
        -o '${OUTPUT_DIR}/${ISO_NAME}' \
        ."
    
    echo "执行命令: $XORRISO_CMD"
    eval sudo $XORRISO_CMD 2>&1 | tee /tmp/iso_build.log
    
    # 如果存在EFI引导文件，添加UEFI支持
    if [ -f "${ISO_DIR}/EFI/BOOT/bootx64.efi" ]; then
        log_info "添加UEFI引导支持..."
        xorriso -indev "${OUTPUT_DIR}/${ISO_NAME}" \
            -boot_image any keep \
            -append_partition 2 0xef "${ISO_DIR}/EFI/BOOT/bootx64.efi" \
            -map "${ISO_DIR}/EFI/BOOT/bootx64.efi" /EFI/BOOT/bootx64.efi \
            -outdev "${OUTPUT_DIR}/${ISO_NAME}" 2>/dev/null || \
            log_warning "UEFI引导添加失败，但ISO已创建"
    fi
    
    ISO_RESULT=$?
    
    if [ $ISO_RESULT -eq 0 ]; then
        log_success "ISO构建成功"
    else
        log_warning "xorriso构建失败，错误代码: $ISO_RESULT"
    fi
fi

# 如果xorriso失败，尝试使用genisoimage
if [ ! -f "${OUTPUT_DIR}/${ISO_NAME}" ] && command -v genisoimage >/dev/null 2>&1; then
    log_info "使用genisoimage构建ISO..."
    
    GENISO_CMD="genisoimage \
        -U -r -v -J -joliet-long \
        -V 'OPENWRT-INSTALL' \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -o '${OUTPUT_DIR}/${ISO_NAME}' \
        ."
    
    echo "执行命令: $GENISO_CMD"
    eval sudo $GENISO_CMD 2>&1 | tee -a /tmp/iso_build.log
    
    # 添加isohybrid支持
    if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ] && command -v isohybrid >/dev/null 2>&1; then
        log_info "添加isohybrid支持..."
        sudo isohybrid "${OUTPUT_DIR}/${ISO_NAME}" 2>/dev/null && \
            log_success "isohybrid支持添加成功"
    fi
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
    echo "?? 构建信息:"
    echo "   文件: ${ISO_NAME}"
    echo "   大小: ${ISO_SIZE} (${ISO_SIZE_MB}MB)"
    echo "   卷标: OPENWRT-INSTALL"
    echo "   内核: Tiny Core Linux ${TINYCORE_VERSION}"
    echo "   引导: BIOS + UEFI (hybrid)"
    echo ""
    echo "? 包含的扩展:"
    for ext in "${DOWNLOADED_EXTS[@]}"; do
        echo "   - $ext"
    done
    echo ""
    echo "?? 使用方法:"
    echo "   1. 刻录到U盘:"
    echo "      sudo dd if=${ISO_NAME} of=/dev/sdX bs=4M status=progress"
    echo "   2. 从U盘启动计算机"
    echo "   3. 选择'Install OpenWRT'"
    echo "   4. 按照提示选择磁盘并确认"
    echo ""
    echo "??  重要警告:"
    echo "   - 安装会完全擦除目标磁盘数据!"
    echo "   - 请确保已备份重要数据!"
    echo ""
    
    # 创建构建摘要
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Tiny Core Installer ISO
===============================
构建时间: $(date)
ISO文件: ${ISO_NAME}
文件大小: ${ISO_SIZE} (${ISO_SIZE_MB}MB)
基于: Tiny Core Linux ${TINYCORE_VERSION}
引导支持: BIOS + UEFI (Hybrid ISO)
包含扩展: ${#DOWNLOADED_EXTS[@]}个扩展
安装镜像: $(basename ${OPENWRT_IMG}) ($(ls -lh ${OPENWRT_IMG} | awk '{print $5}'))
注意事项: 安装会完全擦除目标磁盘数据
BUILD_INFO
    
    log_success "构建摘要已保存到: ${OUTPUT_DIR}/build-info.txt"
    
    # 显示ISO基本信息
    echo "?? ISO验证:"
    file "${OUTPUT_DIR}/${ISO_NAME}"
    echo ""
    
else
    log_error "ISO构建失败!"
    echo "构建日志:"
    cat /tmp/iso_build.log 2>/dev/null || echo "无日志文件"
    exit 1
fi

# 清理临时文件
log_info "清理临时文件..."
sudo rm -rf "${WORK_DIR}"

log_success "? 所有步骤完成! Tiny Core Linux安装ISO已创建"
