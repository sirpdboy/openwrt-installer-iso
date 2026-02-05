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

# 确保输出目录存在
mkdir -p "${OUTPUT_DIR}"

# 清理并创建工作目录
log_info "创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${ISO_DIR}" "${ISO_DIR}/boot" "${ISO_DIR}/boot/isolinux"

# 设置工作目录权限
chmod 755 "${WORK_DIR}" "${ISO_DIR}" "${ISO_DIR}/boot" "${ISO_DIR}/boot/isolinux"

# 下载官方Tiny Core Linux核心文件
log_info "下载Tiny Core Linux核心文件..."

# Tiny Core Linux镜像URL
TINYCORE_BASE="http://tinycorelinux.net/13.x/x86_64"
RELEASE_DIR="${TINYCORE_BASE}/release"
TCZ_DIR="${TINYCORE_BASE}/tcz"

# 下载内核
log_info "下载内核 vmlinuz64..."
cd "${WORK_DIR}"
wget -q --tries=3 --timeout=60 "${RELEASE_DIR}/distribution_files/vmlinuz64" -O vmlinuz64
if [ ! -f "vmlinuz64" ]; then
    log_error "内核下载失败"
    exit 1
fi
mv vmlinuz64 "${ISO_DIR}/boot/vmlinuz64"
chmod 644 "${ISO_DIR}/boot/vmlinuz64"
log_success "内核下载完成"

# 下载initrd
log_info "下载initrd core.gz..."
wget -q --tries=3 --timeout=60 "${RELEASE_DIR}/distribution_files/corepure64.gz" -O core.gz
if [ ! -f "core.gz" ]; then
    log_error "initrd下载失败"
    exit 1
fi
mv core.gz "${ISO_DIR}/boot/core.gz"
chmod 644 "${ISO_DIR}/boot/core.gz"
log_success "initrd下载完成"

# 尝试下载rootfs.gz（可选）
log_info "尝试下载rootfs.gz..."
wget -q --tries=2 --timeout=30 "${RELEASE_DIR}/distribution_files/rootfs64.gz" -O rootfs.gz 2>/dev/null
if [ -f "rootfs.gz" ]; then
    mv rootfs.gz "${ISO_DIR}/boot/rootfs.gz"
    chmod 644 "${ISO_DIR}/boot/rootfs.gz"
    log_success "rootfs.gz下载完成"
else
    log_warning "rootfs.gz未找到，创建空文件"
    echo "Tiny Core Linux不需要单独的rootfs" > "${ISO_DIR}/boot/rootfs.gz"
    chmod 644 "${ISO_DIR}/boot/rootfs.gz"
fi

# 创建cde目录结构
log_info "创建cde目录结构..."
mkdir -p "${TC_DIR}" "${OPTIONAL_DIR}"
chmod 755 "${TC_DIR}" "${OPTIONAL_DIR}"

# 下载必要的扩展
log_info "下载必要扩展..."
cd "${OPTIONAL_DIR}"

# 扩展列表 - 使用已知存在的扩展
EXTENSIONS=(
    "bash.tcz"
    "dialog.tcz"
    "parted.tcz"
    "ntfs-3g.tcz"
    "e2fsprogs.tcz"
    "syslinux.tcz"
    "grub2.tcz"
    "coreutils.tcz"
    "findutils.tcz"
    "grep.tcz"
    "gawk.tcz"
    "sudo.tcz"
    "which.tcz"
    "file.tcz"
    "less.tcz"
    "ncursesw.tcz"
    "mpv.tcz"
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
        wget -q "${TCZ_DIR}/${ext}.info" -O "${ext}.info" 2>/dev/null || true
    else
        log_warning "无法下载 $ext，跳过"
    fi
done

# 创建onboot.lst文件
log_info "创建onboot.lst..."
cat > "${TC_DIR}/onboot.lst" << 'ONBOOT_EOF'
# 自动启动的扩展列表
bash.tcz
dialog.tcz
parted.tcz
e2fsprogs.tcz
coreutils.tcz
ONBOOT_EOF

# 添加成功下载的其他扩展
for ext in "${DOWNLOADED_EXTS[@]}"; do
    # 避免重复添加
    if ! grep -q "^${ext}$" "${TC_DIR}/onboot.lst"; then
        echo "$ext" >> "${TC_DIR}/onboot.lst"
    fi
done

# 创建安装脚本
log_info "创建安装脚本..."
cat > "${TC_DIR}/install-openwrt.sh" << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT自动安装脚本 - Tiny Core版本

# 设置颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 清屏并显示标题
clear
cat << "EOF"

╔═══════════════════════════════════════════════════════╗
║        OpenWRT Auto Installer (Tiny Core Linux)      ║
╚═══════════════════════════════════════════════════════╝

EOF

echo -e "${BLUE}正在初始化安装环境...${NC}"
echo ""

# 检查是否以root运行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 需要root权限运行此脚本${NC}"
    echo "请输入: sudo $0"
    exit 1
fi

# 查找OpenWRT镜像
find_openwrt_image() {
    echo -e "${BLUE}正在查找OpenWRT镜像...${NC}"
    
    # 首先检查常见位置
    local common_locations=(
        "/openwrt.img"
        "/mnt/sr0/openwrt.img"
        "/mnt/cdrom/openwrt.img"
        "/mnt/sr0/cde/openwrt.img"
    )
    
    for loc in "${common_locations[@]}"; do
        if [ -f "$loc" ]; then
            echo -e "${GREEN}找到镜像: $loc${NC}"
            echo "$loc"
            return 0
        fi
    done
    
    # 尝试挂载CD/DVD设备
    echo "尝试挂载CD/DVD设备..."
    local devices=("/dev/sr0" "/dev/cdrom" "/dev/sr1")
    for dev in "${devices[@]}"; do
        if [ -b "$dev" ]; then
            echo "检测到设备: $dev"
            mount_point="/mnt/cdrom-$(basename $dev)"
            mkdir -p "$mount_point"
            
            if mount "$dev" "$mount_point" 2>/dev/null; then
                echo "成功挂载 $dev 到 $mount_point"
                # 在挂载点中查找镜像
                find_result=$(find "$mount_point" -name "*.img" -type f 2>/dev/null | head -1)
                if [ -n "$find_result" ]; then
                    echo -e "${GREEN}找到镜像: $find_result${NC}"
                    echo "$find_result"
                    return 0
                fi
            fi
        fi
    done
    
    # 在当前目录查找
    if [ -f "./openwrt.img" ]; then
        echo -e "${GREEN}在当前目录找到镜像: ./openwrt.img${NC}"
        echo "./openwrt.img"
        return 0
    fi
    
    return 1
}

# 查找OpenWRT镜像
OPENWRT_IMG=$(find_openwrt_image)

if [ -z "$OPENWRT_IMG" ] || [ ! -f "$OPENWRT_IMG" ]; then
    echo -e "${RED}❌ 错误: 找不到OpenWRT镜像${NC}"
    echo ""
    echo "请确保:"
    echo "1. ISO已正确刻录到USB或CD"
    echo "2. 安装介质已正确连接"
    echo ""
    echo "当前目录内容:"
    ls -la ./
    echo ""
    echo "按Enter键进入shell..."
    read
    exec /bin/bash
fi

echo ""
echo -e "${GREEN}✅ OpenWRT镜像信息:${NC}"
echo "路径: $OPENWRT_IMG"
echo "大小: $(ls -lh "$OPENWRT_IMG" | awk '{print $5}')"
echo ""

# 显示可用磁盘
list_disks() {
    echo -e "${BLUE}可用磁盘列表:${NC}"
    echo "================="
    
    # 使用lsblk如果可用
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v '^NAME' | while read line; do
            disk_name="/dev/$(echo $line | awk '{print $1}')"
            disk_info=$(echo $line | cut -d' ' -f2-)
            echo "$disk_name - $disk_info"
        done
    else
        # 使用fdisk
        fdisk -l 2>/dev/null | grep -E '^Disk /dev/(sd|hd|nvme|vd|mmc)' | \
            sed 's/Disk //' | sed 's/://' | while read disk size rest; do
            echo "$disk - $size"
        done || {
            echo "使用dmesg查找磁盘..."
            dmesg | grep -E '(sd|hd|nvme|vd)[0-9]' | grep 'logical blocks' | head -5
        }
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
        echo -e "${RED}❌ 错误: 磁盘 $DISK 不存在${NC}"
        continue
    fi
    
    # 检查磁盘大小
    IMG_SIZE=$(stat -c%s "$OPENWRT_IMG" 2>/dev/null || echo "0")
    DISK_SIZE=$(blockdev --getsize64 "$DISK" 2>/dev/null || echo "0")
    
    if [ "$DISK_SIZE" -lt "$IMG_SIZE" ]; then
        echo -e "${RED}❌ 错误: 磁盘空间不足${NC}"
        echo "镜像大小: $((IMG_SIZE/1024/1024))MB"
        echo "磁盘大小: $((DISK_SIZE/1024/1024))MB"
        continue
    fi
    
    # 显示磁盘详细信息
    echo ""
    echo -e "${BLUE}磁盘详细信息:${NC}"
    if command -v fdisk >/dev/null 2>&1; then
        fdisk -l "$DISK" 2>/dev/null | head -10
    else
        echo "使用简单检查..."
        echo "磁盘: $DISK"
        echo "大小: $((DISK_SIZE/1024/1024))MB"
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
    echo -e "${GREEN}正在安装 OpenWRT 到 $DISK${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "源镜像: $OPENWRT_IMG"
    echo "目标磁盘: $DISK"
    echo "镜像大小: $((IMG_SIZE/1024/1024))MB"
    echo "磁盘大小: $((DISK_SIZE/1024/1024))MB"
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
        echo -e "${YELLOW}使用dd安装 (可能需要几分钟)...${NC}"
        echo "进度: ████████████████████████████████████ 100%"
        dd if="$OPENWRT_IMG" of="$DISK" bs=4M status=progress 2>/dev/null || \
        dd if="$OPENWRT_IMG" of="$DISK" bs=4M
        DD_EXIT=$?
    fi
    
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    # 强制同步
    echo "同步数据到磁盘..."
    sync
    
    # 检查结果
    if [ $DD_EXIT -eq 0 ]; then
        echo ""
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✅ 安装成功完成!${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "耗时: ${DURATION}秒"
        echo "平均速度: $((IMG_SIZE/DURATION/1024/1024)) MB/s"
        echo ""
        
        # 显示最终磁盘信息
        echo -e "${BLUE}安装后的磁盘信息:${NC}"
        if command -v fdisk >/dev/null 2>&1; then
            fdisk -l "$DISK" 2>/dev/null | head -5
        fi
        echo ""
        
        # 重启选项
        echo -e "${YELLOW}选择下一步操作:${NC}"
        echo "1) 立即重启"
        echo "2) 关闭电源"
        echo "3) 返回安装菜单"
        echo "4) 进入shell"
        echo ""
        
        read -p "请输入选项 (1-4): " CHOICE
        
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
                echo "系统将在5秒后关闭..."
                for i in {5..1}; do
                    echo -ne "关机倒计时: $i 秒...\r"
                    sleep 1
                done
                echo ""
                echo "正在关闭..."
                poweroff
                ;;
            3)
                echo "返回安装菜单..."
                continue 2
                ;;
            4)
                echo "进入shell..."
                echo "输入 'exit' 返回安装菜单"
                echo "输入 'reboot' 重启系统"
                echo "输入 'poweroff' 关闭系统"
                echo ""
                exec /bin/bash
                ;;
            *)
                echo "返回安装菜单..."
                continue 2
                ;;
        esac
        
    else
        echo ""
        echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}❌ 安装失败!${NC}"
        echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "dd退出代码: $DD_EXIT"
        echo ""
        echo "可能的原因:"
        echo "1. 磁盘空间不足"
        echo "2. 磁盘损坏或只读"
        echo "3. 镜像文件损坏"
        echo "4. 权限不足"
        echo ""
        read -p "按Enter键返回安装菜单..."
        continue 2
    fi
done
INSTALL_SCRIPT

chmod +x "${TC_DIR}/install-openwrt.sh"

# 创建bootlocal.sh
log_info "创建bootlocal.sh..."
cat > "${TC_DIR}/bootlocal.sh" << 'BOOTLOCAL'
#!/bin/sh
# Tiny Core启动后自动执行

# 等待基本系统启动
sleep 2

# 设置路径
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# 清屏并显示信息
clear
echo ""
echo "========================================"
echo "    OpenWRT Auto Installer"
echo "    Based on Tiny Core Linux"
echo "========================================"
echo ""
echo "正在启动安装环境..."
echo ""

# 等待网络和扩展加载
sleep 3

# 检查扩展目录
if [ -d /tmp/tcloop ]; then
    echo "扩展已加载"
else
    echo "正在加载扩展..."
    tce-load -wil bash dialog parted 2>/dev/null || true
    sleep 2
fi

# 尝试查找和执行安装脚本
echo "查找安装脚本..."
INSTALL_SCRIPT=""

# 检查多个可能的位置
for mount_point in /mnt/sr0 /mnt/cdrom /cdrom /media/cdrom; do
    if [ -d "$mount_point" ]; then
        for script in "$mount_point/cde/install-openwrt.sh" "$mount_point/install-openwrt.sh"; do
            if [ -x "$script" ]; then
                INSTALL_SCRIPT="$script"
                break 2
            fi
        done
    fi
done

if [ -n "$INSTALL_SCRIPT" ]; then
    echo "找到安装脚本: $INSTALL_SCRIPT"
    echo "正在启动安装程序..."
    sleep 2
    exec "$INSTALL_SCRIPT"
else
    echo "安装脚本未自动找到"
    echo ""
    echo "请手动操作:"
    echo "1. 挂载安装介质: mount /dev/sr0 /mnt/cdrom"
    echo "2. 运行安装: /mnt/cdrom/cde/install-openwrt.sh"
    echo ""
    echo "按Enter键进入shell..."
    read dummy
    exec /bin/bash
fi
BOOTLOCAL

chmod +x "${TC_DIR}/bootlocal.sh"

# 复制OpenWRT镜像到ISO
log_info "复制OpenWRT镜像到ISO..."
cp "${OPENWRT_IMG}" "${ISO_DIR}/openwrt.img"
chmod 644 "${ISO_DIR}/openwrt.img"

# 创建BIOS引导配置
log_info "配置BIOS引导..."
cat > "${ISO_DIR}/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT openwrt
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE OpenWRT Tiny Core Installer

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz,/boot/rootfs.gz quiet tce=cdrom waitusb=5 opt=cdrom

LABEL shell
  MENU LABEL ^Shell (debug mode)
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz,/boot/rootfs.gz quiet tce=cdrom waitusb=5 opt=cdrom norestore

LABEL local
  MENU LABEL ^Boot from local drive
  LOCALBOOT 0x80
  TIMEOUT 10
ISOLINUX_CFG

# 复制ISOLINUX引导文件
log_info "复制ISOLINUX引导文件..."
if [ -f "/usr/lib/ISOLINUX/isolinux.bin" ]; then
    cp "/usr/lib/ISOLINUX/isolinux.bin" "${ISO_DIR}/boot/isolinux/"
    # 复制必要的模块
    cp /usr/lib/syslinux/modules/bios/menu.c32 "${ISO_DIR}/boot/isolinux/" 2>/dev/null || true
    cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "${ISO_DIR}/boot/isolinux/" 2>/dev/null || true
    cp /usr/lib/syslinux/modules/bios/libutil.c32 "${ISO_DIR}/boot/isolinux/" 2>/dev/null || true
elif [ -f "/usr/share/syslinux/isolinux.bin" ]; then
    cp "/usr/share/syslinux/isolinux.bin" "${ISO_DIR}/boot/isolinux/"
    cp /usr/share/syslinux/menu.c32 "${ISO_DIR}/boot/isolinux/" 2>/dev/null || true
else
    log_warning "找不到ISOLINUX文件，需要安装syslinux"
fi

# 创建UEFI引导
log_info "准备UEFI引导..."
mkdir -p "${ISO_DIR}/EFI/BOOT"

# 生成GRUB EFI引导文件
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
        log_warning "GRUB EFI文件生成失败，将创建仅BIOS引导的ISO"
    fi
else
    log_warning "grub-mkstandalone不可用，将创建仅BIOS引导的ISO"
fi

# 构建ISO镜像
log_info "构建ISO镜像..."
cd "${ISO_DIR}"

# 首先计算ISO大小
ISO_SIZE_ESTIMATE=$(du -sb . 2>/dev/null | cut -f1 || echo "0")
ISO_SIZE_MB=$((ISO_SIZE_ESTIMATE / 1024 / 1024))
log_info "ISO估计大小: ${ISO_SIZE_MB}MB"

# 检查是否有EFI引导文件
HAS_UEFI_BOOT=false
if [ -f "EFI/BOOT/bootx64.efi" ]; then
    HAS_UEFI_BOOT=true
    log_info "检测到UEFI引导文件，构建双引导ISO"
fi

# 使用xorriso构建ISO（首选）
if command -v xorriso >/dev/null 2>&1; then
    log_info "使用xorriso构建ISO..."
    
    XORRISO_CMD="xorriso -as mkisofs \
        -iso-level 3 \
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
    
    echo "执行构建命令..."
    eval $XORRISO_CMD 2>&1 | tee /tmp/iso_build.log
    
    ISO_RESULT=$?
    
    if [ $ISO_RESULT -eq 0 ]; then
        log_success "ISO构建成功"
        
        # 如果支持UEFI，添加UEFI引导
        if [ "$HAS_UEFI_BOOT" = true ]; then
            log_info "添加UEFI引导支持..."
            xorriso -indev "${OUTPUT_DIR}/${ISO_NAME}" \
                -boot_image any keep \
                -append_partition 2 0xef "EFI/BOOT/bootx64.efi" \
                -map "EFI/BOOT/bootx64.efi" /EFI/BOOT/bootx64.efi \
                -outdev "${OUTPUT_DIR}/${ISO_NAME}" 2>/dev/null || \
                log_warning "UEFI引导添加失败，但ISO已创建"
        fi
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
    
    echo "执行构建命令..."
    eval $GENISO_CMD 2>&1 | tee -a /tmp/iso_build.log
    
    # 添加isohybrid支持
    if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ] && command -v isohybrid >/dev/null 2>&1; then
        log_info "添加isohybrid支持..."
        isohybrid "${OUTPUT_DIR}/${ISO_NAME}" 2>/dev/null && \
            log_success "isohybrid支持添加成功"
    fi
fi

# 如果上述都失败，尝试最简单的mkisofs
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
    echo "   内核: Tiny Core Linux ${TINYCORE_VERSION}"
    echo "   引导: $([ "$HAS_UEFI_BOOT" = true ] && echo "BIOS + UEFI" || echo "BIOS")"
    echo ""
    echo "✅ 成功下载的扩展 (${#DOWNLOADED_EXTS[@]}个):"
    for ext in "${DOWNLOADED_EXTS[@]}"; do
        echo "   - $(basename "$ext" .tcz)"
    done
    echo ""
    echo "🚀 使用方法:"
    echo "   1. 刻录到U盘:"
    echo "      dd if=${ISO_NAME} of=/dev/sdX bs=4M status=progress"
    echo "   2. 从U盘启动计算机"
    echo "   3. 选择'Install OpenWRT'"
    echo "   4. 按照提示选择磁盘并输入'YES'确认"
    echo ""
    echo "⚠️  重要警告:"
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
引导支持: $([ "$HAS_UEFI_BOOT" = true ] && echo "BIOS + UEFI (Hybrid ISO)" || echo "BIOS only")
下载扩展: ${#DOWNLOADED_EXTS[@]}个
安装镜像: $(basename ${OPENWRT_IMG}) ($(ls -lh ${OPENWRT_IMG} | awk '{print $5}'))
注意事项: 安装会完全擦除目标磁盘数据，请提前备份！
BUILD_INFO
    
    log_success "构建摘要已保存到: ${OUTPUT_DIR}/build-info.txt"
    
    # 显示ISO基本信息
    echo "📁 ISO验证:"
    file "${OUTPUT_DIR}/${ISO_NAME}"
    echo ""
    
    # 显示引导信息
    if command -v xorriso >/dev/null 2>&1; then
        echo "🔧 ISO引导信息:"
        xorriso -indev "${OUTPUT_DIR}/${ISO_NAME}" -toc 2>/dev/null | \
            grep -E "(El Torito|Bootable|UEFI)" || true
    fi
    
else
    log_error "ISO构建失败!"
    echo "构建日志:"
    cat /tmp/iso_build.log 2>/dev/null || echo "无日志文件"
    echo ""
    echo "当前工作目录内容:"
    ls -la "${ISO_DIR}" 2>/dev/null || echo "无法访问ISO目录"
    exit 1
fi

# 清理临时文件
log_info "清理临时文件..."
rm -rf "${WORK_DIR}"

log_success "✅ 所有步骤完成! Tiny Core Linux安装ISO已创建"
