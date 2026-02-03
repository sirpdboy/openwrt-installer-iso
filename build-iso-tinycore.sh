#!/bin/bash
# build-tinycore-iso.sh - 基于Tiny Core Linux的极简OpenWRT安装ISO
set -e

echo "开始构建Tiny Core Linux安装ISO..."
echo "========================================"

# 配置
TINYCORE_VERSION="15.x"
ARCH="x86_64"
WORK_DIR="/tmp/tinycore-build"
ISO_DIR="${WORK_DIR}/iso"
BOOT_DIR="${ISO_DIR}/boot"
TC_DIR="${ISO_DIR}/tc"
EFI_DIR="${ISO_DIR}/efi/boot"

OPENWRT_IMG="${1:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${2:-/output}"
ISO_NAME="${3:-openwrt-autoinstall.iso}"
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
rm -rf "${WORK_DIR}"
mkdir -p "${ISO_DIR}" "${BOOT_DIR}" "${TC_DIR}" "${EFI_DIR}" "${OUTPUT_DIR}"

# 下载Tiny Core Linux核心文件
log_info "下载Tiny Core Linux核心文件..."

# Tiny Core Linux镜像URL
TINYCORE_MIRROR="http://tinycorelinux.net/15.x/x86_64"
TINYCORE_RELEASE="15.0"

# 下载内核和initrd
log_info "下载内核..."
wget -q "${TINYCORE_MIRROR}/release/distribution_files/vmlinuz64" -O "${BOOT_DIR}/vmlinuz64"
wget -q "${TINYCORE_MIRROR}/release/distribution_files/corepure64.gz" -O "${BOOT_DIR}/core.gz"

# 下载rootfs
log_info "下载rootfs..."
wget -q "${TINYCORE_MIRROR}/release/distribution_files/rootfs64.gz" -O "${TC_DIR}/rootfs.gz"

# 下载扩展工具
log_info "下载必要扩展..."
mkdir -p "${TC_DIR}/optional"
cd "${TC_DIR}/optional"

# 基础扩展
EXTENSIONS=(
    "bash.tcz"
    "dialog.tcz"
    "parted.tcz"
    "grub2-multi.tcz"
    "ntfs-3g.tcz"
    "syslinux.tcz"
    "pv.tcz"
    "e2fsprogs.tcz"
    "gptfdisk.tcz"
    "ddrescue.tcz"
)

for ext in "${EXTENSIONS[@]}"; do
    echo "下载扩展: $ext"
    wget -q "${TINYCORE_MIRROR}/tcz/$ext" -O "$ext"
    wget -q "${TINYCORE_MIRROR}/tcz/$ext.dep" -O "$ext.dep" 2>/dev/null || true
    wget -q "${TINYCORE_MIRROR}/tcz/$ext.md5.txt" -O "$ext.md5.txt" 2>/dev/null || true
done

# 验证下载
log_info "验证下载文件..."
if [ ! -f "${BOOT_DIR}/vmlinuz64" ] || [ ! -f "${BOOT_DIR}/core.gz" ]; then
    log_error "Tiny Core核心文件下载失败"
    exit 1
fi

# 创建启动脚本
log_info "创建启动脚本..."

# 1. 创建tce目录结构
mkdir -p "${TC_DIR}/tce"

# 2. 创建onboot.lst
cat > "${TC_DIR}/tce/onboot.lst" << 'ONBOOT'
bash.tcz
dialog.tcz
parted.tcz
grub2-multi.tcz
ntfs-3g.tcz
syslinux.tcz
pv.tcz
e2fsprogs.tcz
gptfdisk.tcz
ddrescue.tcz
ONBOOT

# 3. 创建OpenWRT安装脚本
cat > "${TC_DIR}/install-openwrt.sh" << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT自动安装脚本 - Tiny Core版本

clear
cat << "EOF"

╔═══════════════════════════════════════════════════════╗
║        OpenWRT Auto Installer (Tiny Core)            ║
╚═══════════════════════════════════════════════════════╝

EOF

# 检查OpenWRT镜像
OPENWRT_IMG="/mnt/sr0/openwrt.img"
if [ ! -f "$OPENWRT_IMG" ]; then
    echo "❌ ERROR: OpenWRT image not found!"
    echo "镜像应该位于: $OPENWRT_IMG"
    echo ""
    echo "请检查ISO是否正确挂载"
    echo "按Enter键进入shell..."
    read
    exec /bin/bash
fi

echo "✅ OpenWRT镜像找到: $(ls -lh "$OPENWRT_IMG" | awk '{print $5}')"
echo ""

# 循环直到成功安装
while true; do
    # 显示可用磁盘
    echo "可用磁盘:"
    echo "================="
    fdisk -l 2>/dev/null | grep -E '^Disk /dev/(sd|hd|nvme|vd)' | awk -F'[:,]' '{print $1 " - " $2}'
    echo "================="
    echo ""
    
    read -p "输入目标磁盘 (例如: sda): " DISK
    
    if [ -z "$DISK" ]; then
        echo "请输入磁盘名称"
        continue
    fi
    
    if [ ! -b "/dev/$DISK" ]; then
        echo "❌ 磁盘 /dev/$DISK 未找到!"
        continue
    fi
    
    # 显示磁盘信息
    echo ""
    echo "磁盘信息:"
    parted /dev/$DISK print 2>/dev/null || echo "无法读取磁盘信息"
    echo ""
    
    # 确认
    echo "⚠️  警告: 这将擦除 /dev/$DISK 上的所有数据!"
    echo ""
    read -p "输入 'YES' 确认安装: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "操作取消."
        continue
    fi
    
    # 开始安装
    clear
    echo ""
    echo "正在安装 OpenWRT 到 /dev/$DISK..."
    echo ""
    
    # 使用pv显示进度
    if command -v pv >/dev/null 2>&1; then
        echo "使用pv显示进度..."
        pv -pet "$OPENWRT_IMG" | dd of="/dev/$DISK" bs=4M status=none
    else
        echo "使用dd安装 (可能需要几分钟)..."
        dd if="$OPENWRT_IMG" of="/dev/$DISK" bs=4M status=progress
    fi
    
    # 同步和检查
    sync
    echo ""
    
    # 验证安装
    if [ $? -eq 0 ]; then
        echo "✅ 安装完成!"
        echo ""
        echo "磁盘信息:"
        fdisk -l /dev/$DISK 2>/dev/null | head -10
        echo ""
        
        echo "系统将在10秒后重启..."
        echo "按任意键取消重启并进入shell"
        
        # 倒计时
        for i in {10..1}; do
            echo -ne "重启倒计时: $i 秒...\r"
            if read -t 1 -n 1; then
                echo ""
                echo "重启已取消"
                echo "输入 'reboot' 重启系统"
                echo "输入 'exit' 重新运行安装程序"
                echo ""
                read -p "选择: " CHOICE
                if [ "$CHOICE" = "reboot" ]; then
                    reboot
                else
                    continue 2
                fi
            fi
        done
        
        echo ""
        echo "正在重启..."
        sleep 2
        reboot -f
        
    else
        echo "❌ 安装失败!"
        echo ""
        echo "按Enter键重试..."
        read
    fi
done
INSTALL_SCRIPT
chmod +x "${TC_DIR}/install-openwrt.sh"

# 4. 创建Tiny Core启动配置
cat > "${TC_DIR}/bootlocal.sh" << 'BOOTLOCAL'
#!/bin/sh
# Tiny Core启动后自动执行

# 等待网络
sleep 2

# 清屏
clear

# 显示欢迎信息
cat << "WELCOME"

╔═══════════════════════════════════════════════════════╗
║     OpenWRT Auto Installer - Tiny Core Linux         ║
╚═══════════════════════════════════════════════════════╝

正在启动安装系统，请稍候...
WELCOME

# 等待扩展加载完成
sleep 3

# 检查CDROM挂载
if [ ! -d /mnt/sr0 ]; then
    mkdir -p /mnt/sr0
fi

# 尝试挂载CDROM
mount /dev/sr0 /mnt/sr0 2>/dev/null || mount /dev/cdrom /mnt/sr0 2>/dev/null

# 运行安装程序
if [ -x /mnt/sr0/tc/install-openwrt.sh ]; then
    exec /mnt/sr0/tc/install-openwrt.sh
else
    echo "❌ 安装脚本未找到"
    echo ""
    echo "手动安装步骤:"
    echo "1. 挂载CDROM: mount /dev/sr0 /mnt/sr0"
    echo "2. 运行安装: /mnt/sr0/tc/install-openwrt.sh"
    echo ""
    echo "按Enter键进入shell..."
    read
    exec /bin/bash
fi
BOOTLOCAL
chmod +x "${TC_DIR}/bootlocal.sh"

# 5. 创建opt目录
mkdir -p "${TC_DIR}/opt"
cat > "${TC_DIR}/opt/.filetool.lst" << 'FILETOOL'
opt
tc
FILETOOL

# 复制OpenWRT镜像到ISO
log_info "复制OpenWRT镜像到ISO..."
cp "${OPENWRT_IMG}" "${TC_DIR}/openwrt.img"

# 创建BIOS引导配置
log_info "创建BIOS引导配置..."

# ISOLINUX配置
cat > "${ISO_DIR}/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT tinycore
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE OpenWRT Tiny Core Installer

LABEL tinycore
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz,/boot/rootfs.gz quiet tce=CD waitusb=5

LABEL shell
  MENU LABEL ^Shell (debug)
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz,/boot/rootfs.gz quiet tce=CD waitusb=5 norestore
ISOLINUX_CFG

# 复制ISOLINUX文件
log_info "复制ISOLINUX引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "${ISO_DIR}/"
cp /usr/lib/syslinux/modules/bios/*.c32 "${ISO_DIR}/" 2>/dev/null || true

# 创建UEFI引导
log_info "创建UEFI引导..."

# 1. 创建GRUB配置
cat > "${ISO_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (Tiny Core)" {
    linux /boot/vmlinuz64 quiet tce=CD waitusb=5
    initrd /boot/core.gz /boot/rootfs.gz
}

menuentry "Shell (debug)" {
    linux /boot/vmlinuz64 quiet tce=CD waitusb=5 norestore
    initrd /boot/core.gz /boot/rootfs.gz
}
GRUB_CFG

# 2. 创建UEFI引导镜像
log_info "创建UEFI引导镜像..."
mkdir -p "${WORK_DIR}/efiboot"
cp "${BOOT_DIR}/vmlinuz64" "${WORK_DIR}/efiboot/"
cp "${BOOT_DIR}/core.gz" "${WORK_DIR}/efiboot/"
cp "${BOOT_DIR}/rootfs.gz" "${WORK_DIR}/efiboot/" 2>/dev/null || true

# 创建EFI目录结构
mkdir -p "${WORK_DIR}/efiboot/EFI/BOOT"
mkdir -p "${WORK_DIR}/efiboot/boot/grub"

# 复制GRUB EFI文件
if [ -f /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed ]; then
    cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed \
        "${WORK_DIR}/efiboot/EFI/BOOT/bootx64.efi"
elif [ -f /usr/lib/grub/x86_64-efi/monolithic/grub.efi ]; then
    cp /usr/lib/grub/x86_64-efi/monolithic/grub.efi \
        "${WORK_DIR}/efiboot/EFI/BOOT/bootx64.efi"
else
    # 生成GRUB EFI
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="${WORK_DIR}/efiboot/EFI/BOOT/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=${ISO_DIR}/boot/grub/grub.cfg"
fi

# 复制GRUB配置文件
cp "${ISO_DIR}/boot/grub/grub.cfg" "${WORK_DIR}/efiboot/boot/grub/"

# 创建EFI引导镜像
EFI_IMG_SIZE=16M
dd if=/dev/zero of="${ISO_DIR}/efiboot.img" bs=1 count=0 seek=${EFI_IMG_SIZE}
mkfs.fat -F 32 "${ISO_DIR}/efiboot.img" 2>/dev/null

# 挂载并复制文件
MOUNT_POINT="${WORK_DIR}/efimount"
mkdir -p "${MOUNT_POINT}"
sudo mount -o loop "${ISO_DIR}/efiboot.img" "${MOUNT_POINT}"
sudo cp -r "${WORK_DIR}/efiboot/EFI" "${MOUNT_POINT}/"
sudo cp -r "${WORK_DIR}/efiboot/boot" "${MOUNT_POINT}/"
sync
sudo umount "${MOUNT_POINT}"

# 构建支持BIOS和UEFI双引导的ISO
log_info "构建支持BIOS+UEFI双引导的ISO..."

# 首先确保EFI目录存在
if [ -d "${NEW_ISO_DIR}/EFI" ]; then
    log_info "检测到EFI目录，准备构建双引导ISO"
    
    # 创建临时工作目录
    EFI_TEMP="${WORK_DIR}/efi_temp"
    mkdir -p "${EFI_TEMP}"
    
    # 方法1: 使用xorriso（推荐，更现代）
    if command -v xorriso >/dev/null 2>&1; then
        log_info "使用xorriso构建双引导ISO..."
        
        xorriso -as mkisofs \
            -iso-level 3 \
            -full-iso9660-filenames \
            -volid "OPENWRT-INSTALL" \
            # BIOS引导配置
            -eltorito-boot boot/isolinux/isolinux.bin \
            -eltorito-catalog boot/isolinux/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            # UEFI引导配置
            -eltorito-alt-boot \
            -e EFI/BOOT/BOOTX64.EFI \
            -no-emul-boot \
            # 添加MBR以支持混合模式
            -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
            # 输出
            -output "${OUTPUT_DIR}/${ISO_NAME}" \
            "${NEW_ISO_DIR}" 2>&1 | tee /tmp/iso_build.log
            
        XORRISO_EXIT=$?
        
        if [ $XORRISO_EXIT -eq 0 ]; then
            log_success "xorriso构建成功"
        else
            log_warning "xorriso构建失败，尝试其他方法"
        fi
    fi
    
    # 方法2: 使用genisoimage/mkisofs（传统方法）
    if [ ! -f "${OUTPUT_DIR}/${ISO_NAME}" ] && command -v genisoimage >/dev/null 2>&1; then
        log_info "使用genisoimage构建双引导ISO..."
        
        genisoimage \
            -U \
            -r \
            -v \
            -J \
            -joliet-long \
            -cache-inodes \
            -V "OPENWRT-INSTALL" \
            # BIOS引导
            -b boot/isolinux/isolinux.bin \
            -c boot/isolinux/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            # UEFI引导
            -eltorito-alt-boot \
            -e EFI/BOOT/BOOTX64.EFI \
            -no-emul-boot \
            -output "${OUTPUT_DIR}/${ISO_NAME}" \
            "${NEW_ISO_DIR}" 2>&1 | tee /tmp/iso_build.log
    fi
    
    # 方法3: 纯mkisofs（最兼容）
    if [ ! -f "${OUTPUT_DIR}/${ISO_NAME}" ] && command -v mkisofs >/dev/null 2>&1; then
        log_info "使用mkisofs构建双引导ISO..."
        
        mkisofs \
            -iso-level 3 \
            -full-iso9660-filenames \
            -J \
            -R \
            -V "OPENWRT-INSTALL" \
            # BIOS引导
            -b boot/isolinux/isolinux.bin \
            -c boot/isolinux/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            # UEFI引导
            -eltorito-alt-boot \
            -e EFI/BOOT/BOOTX64.EFI \
            -no-emul-boot \
            -output "${OUTPUT_DIR}/${ISO_NAME}" \
            "${NEW_ISO_DIR}" 2>&1 | tee /tmp/iso_build.log
    fi
    
    # 方法4: 如果以上都失败，使用isohybrid添加UEFI支持
    if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
        log_info "添加isohybrid支持以增强UEFI兼容性..."
        
        # 检查isohybrid是否可用
        if command -v isohybrid >/dev/null 2>&1; then
            isohybrid --uefi "${OUTPUT_DIR}/${ISO_NAME}" 2>/dev/null && \
                log_success "isohybrid UEFI支持添加成功"
        fi
    fi
    
else
    log_warning "未找到EFI目录，仅构建BIOS引导ISO"
    
    # 构建仅BIOS引导的ISO
    xorriso -as mkisofs \
        -iso-level 3 \
        -volid "OPENWRT-INSTALL" \
        -eltorito-boot boot/isolinux/isolinux.bin \
        -eltorito-catalog boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        "${NEW_ISO_DIR}"
fi

# 构建ISO镜像
log_info "构建ISO镜像..."
cd "${ISO_DIR}"

# 计算文件大小
TOTAL_SIZE=$(du -sb . | cut -f1)
TOTAL_SIZE_MB=$((TOTAL_SIZE / 1024 / 1024))

log_info "ISO总大小: ${TOTAL_SIZE_MB}MB"


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
    echo "   卷标: OPENWRT_INSTALL"
    echo "   引导: BIOS + UEFI"
    echo "   内核: Tiny Core Linux ${TINYCORE_VERSION}"
    echo ""
    echo "🎯 特性:"
    echo "   ✓ 极小的ISO体积 (< 50MB)"
    echo "   ✓ 支持BIOS和UEFI双引导"
    echo "   ✓ 自动启动安装程序"
    echo "   ✓ 包含磁盘工具(parted, gdisk等)"
    echo "   ✓ 进度显示(pv工具)"
    echo ""
    echo "🚀 使用方法:"
    echo "   1. 刻录到U盘:"
    echo "      sudo dd if=${ISO_NAME} of=/dev/sdX bs=4M status=progress"
    echo "   2. 从U盘启动计算机"
    echo "   3. 系统自动进入安装界面"
    echo "   4. 选择目标磁盘并确认安装"
    echo "   5. 等待安装完成自动重启"
    echo ""
    echo "💡 提示:"
    echo "   - 安装会完全擦除目标磁盘数据"
    echo "   - 确保已备份重要数据"
    echo "   - 支持SSD、HDD、USB磁盘"
    echo ""
    
    # 创建构建摘要
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Tiny Core Installer ISO
===============================
构建时间: $(date)
ISO文件: ${ISO_NAME}
文件大小: ${ISO_SIZE} (${ISO_SIZE_MB}MB)
Tiny Core版本: ${TINYCORE_VERSION}
支持引导: BIOS + UEFI
包含工具: bash, dialog, parted, gdisk, pv, ntfs-3g
注意事项: 安装会完全擦除目标磁盘数据
BUILD_INFO
    
    log_success "构建摘要已保存到: ${OUTPUT_DIR}/build-info.txt"
    
    # 显示文件列表
    echo "📁 ISO内容:"
    find "${ISO_DIR}" -type f | sed "s|${ISO_DIR}/||" | sort | head -20
    
else
    log_error "ISO构建失败"
    exit 1
fi

# 清理
log_info "清理临时文件..."
rm -rf "${WORK_DIR}"

log_success "✅ 所有步骤完成! Tiny Core Linux安装ISO已创建"
