#!/bin/bash
# build-tinycore.sh - 基于Tiny Core Linux的极简OpenWRT安装ISO
# 遵循官方remastering指南: https://wiki.tinycorelinux.net/doku.php?id=wiki:remastering
set -e

echo "开始构建Tiny Core Linux安装ISO..."
echo "========================================"

# 配置
TINYCORE_VERSION="13.x"
ARCH="x86_64"
WORK_DIR="/tmp/tinycore-build"
ISO_DIR="${WORK_DIR}/iso"
BOOT_DIR="${ISO_DIR}/boot"
TC_DIR="${ISO_DIR}/tc"
EXT_DIR="${ISO_DIR}/cde/optional"
NEW_ISO_DIR="${WORK_DIR}/newiso"

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
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${ISO_DIR}" "${NEW_ISO_DIR}" "${OUTPUT_DIR}"

# 下载并挂载官方Tiny Core Linux ISO
log_info "下载Tiny Core Linux官方ISO..."
TINYCORE_MIRROR="http://tinycorelinux.net/13.x/x86_64/release"
ISO_FILE="${WORK_DIR}/tinycore-current.iso"

if ! wget -q "${TINYCORE_MIRROR}/CorePure64-current.iso" -O "${ISO_FILE}"; then
    log_error "无法下载Tiny Core ISO"
    exit 1
fi

# 挂载ISO
log_info "挂载官方ISO..."
mkdir -p "${WORK_DIR}/mount"
sudo mount -o loop "${ISO_FILE}" "${WORK_DIR}/mount" 2>/dev/null || {
    # 尝试另一种挂载方式
    sudo mount -t iso9660 -o loop "${ISO_FILE}" "${WORK_DIR}/mount"
}

if [ $? -ne 0 ]; then
    log_error "无法挂载Tiny Core ISO"
    exit 1
fi

# 复制ISO内容到工作目录
log_info "复制ISO内容..."
cp -r "${WORK_DIR}/mount/"* "${ISO_DIR}/"
sync

# 卸载ISO
sudo umount "${WORK_DIR}/mount"

# 创建Tiny Core Linux remastering目录结构
log_info "设置Tiny Core目录结构..."
mkdir -p "${TC_DIR}/optional"
mkdir -p "${EXT_DIR}"

# 复制核心文件（如果需要）
if [ -f "${ISO_DIR}/boot/vmlinuz64" ]; then
    log_info "找到核心文件..."
else
    # 如果ISO中没有核心文件，从网络下载
    log_info "从网络下载核心文件..."
    wget -q "http://tinycorelinux.net/13.x/x86_64/release/distribution_files/vmlinuz64" \
        -O "${ISO_DIR}/boot/vmlinuz64"
    wget -q "http://tinycorelinux.net/13.x/x86_64/release/distribution_files/corepure64.gz" \
        -O "${ISO_DIR}/boot/core.gz"
fi

# 下载必要的扩展
log_info "下载必要扩展..."
EXTENSIONS=(
    "bash.tcz"
    "dialog.tcz"
    "parted.tcz"

    "ncursesw.tcz"
    "gdisk.tcz"
    "e2fsprogs.tcz"
    "syslinux.tcz"
    "grub2-multi.tcz"
    "mpv.tcz"
    "readline.tcz"
)

for ext in "${EXTENSIONS[@]}"; do
    echo "下载扩展: $ext"
    if wget -q "http://tinycorelinux.net/13.x/x86_64/tcz/${ext}" -O "${EXT_DIR}/${ext}"; then
        echo "✅ $ext"
        # 下载依赖文件
        wget -q "http://tinycorelinux.net/13.x/x86_64/tcz/${ext}.dep" \
            -O "${EXT_DIR}/${ext}.dep" 2>/dev/null || true
        wget -q "http://tinycorelinux.net/13.x/x86_64/tcz/${ext}.md5.txt" \
            -O "${EXT_DIR}/${ext}.md5.txt" 2>/dev/null || true
    else
        log_warning "无法下载 $ext"
    fi
done

# 创建onboot.lst文件
log_info "创建onboot.lst..."
cat > "${ISO_DIR}/cde/onboot.lst" << 'ONBOOT'
bash.tcz
dialog.tcz
parted.tcz
ntfs-3g.tcz
gptfdisk.tcz
e2fsprogs.tcz
syslinux.tcz
grub2-multi.tcz
pv.tcz
ncurses.tcz
readline.tcz
ONBOOT

# 创建安装脚本
log_info "创建安装脚本..."
cat > "${ISO_DIR}/cde/install-openwrt.sh" << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT自动安装脚本

clear
cat << "EOF"

╔═══════════════════════════════════════════════════════╗
║        OpenWRT Auto Installer (Tiny Core Linux)      ║
╚═══════════════════════════════════════════════════════╝

EOF

# 设置路径
OPENWRT_IMG="/mnt/sr0/openwrt.img"
CD_MOUNT="/mnt/sr0"

# 检查CD是否挂载
if [ ! -d "$CD_MOUNT" ]; then
    mkdir -p "$CD_MOUNT"
fi

if ! mount | grep -q "$CD_MOUNT"; then
    echo "挂载CD-ROM..."
    mount /dev/sr0 "$CD_MOUNT" 2>/dev/null || {
        echo "❌ 无法挂载CD-ROM"
        echo "请手动挂载: mount /dev/sr0 /mnt/sr0"
        exit 1
    }
fi

# 检查OpenWRT镜像
if [ ! -f "$OPENWRT_IMG" ]; then
    echo "❌ ERROR: OpenWRT image not found!"
    echo "镜像应该位于: $OPENWRT_IMG"
    echo ""
    echo "当前CD内容:"
    ls -la "$CD_MOUNT/" 2>/dev/null || echo "无法列出CD内容"
    echo ""
    echo "按Enter键进入shell..."
    read
    exec /bin/bash
fi

echo "✅ OpenWRT镜像找到: $(ls -lh "$OPENWRT_IMG" | awk '{print $5}')"
echo ""

# 主安装循环
while true; do
    # 显示可用磁盘
    echo "可用磁盘:"
    echo "================="
    lsblk -d -o NAME,SIZE,MODEL | grep -E '^(sd|hd|nvme|vd)' || \
    fdisk -l 2>/dev/null | grep -E '^Disk /dev/(sd|hd|nvme|vd)' | awk -F'[:,]' '{print $1 " - " $2}'
    echo "================="
    echo ""
    
    read -p "输入目标磁盘 (例如: sda, nvme0n1): " DISK
    
    if [ -z "$DISK" ]; then
        echo "请输入磁盘名称"
        continue
    fi
    
    # 确保有/dev/前缀
    if [[ ! "$DISK" =~ ^/dev/ ]]; then
        DISK="/dev/$DISK"
    fi
    
    if [ ! -b "$DISK" ]; then
        echo "❌ 磁盘 $DISK 未找到!"
        continue
    fi
    
    # 显示磁盘信息
    echo ""
    echo "磁盘信息:"
    lsblk "$DISK" 2>/dev/null || fdisk -l "$DISK" 2>/dev/null | head -10
    echo ""
    
    # 确认
    echo "⚠️  警告: 这将擦除 $DISK 上的所有数据!"
    echo ""
    read -p "输入 'YES' 确认安装 (输入其他内容取消): " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "操作取消."
        continue
    fi
    
    # 开始安装
    clear
    echo ""
    echo "正在安装 OpenWRT 到 $DISK..."
    echo "镜像: $(ls -lh "$OPENWRT_IMG" | awk '{print $5}')"
    echo ""
    
    # 使用pv显示进度（如果可用）
    if command -v pv >/dev/null 2>&1; then
        echo "使用pv显示进度..."
        pv -pet "$OPENWRT_IMG" | dd of="$DISK" bs=4M status=none
    else
        echo "使用dd安装 (可能需要几分钟)..."
        dd if="$OPENWRT_IMG" of="$DISK" bs=4M status=progress
    fi
    
    # 同步
    sync
    
    # 验证安装
    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ 安装完成!"
        echo ""
        echo "磁盘信息:"
        fdisk -l "$DISK" 2>/dev/null | head -5
        echo ""
        
        # 等待重启
        echo "系统将在15秒后重启..."
        echo "按任意键取消重启并进入shell"
        
        # 倒计时
        for i in {15..1}; do
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
        read -p "按Enter键重试..."
    fi
done
INSTALL_SCRIPT
chmod +x "${ISO_DIR}/cde/install-openwrt.sh"

# 创建bootlocal.sh
log_info "创建bootlocal.sh..."
cat > "${ISO_DIR}/cde/bootlocal.sh" << 'BOOTLOCAL'
#!/bin/sh
# 自动启动安装程序

# 等待基本系统启动
sleep 3

# 清屏
clear

# 显示信息
echo ""
echo "========================================"
echo "    OpenWRT Auto Installer"
echo "    Tiny Core Linux"
echo "========================================"
echo ""
echo "正在启动安装程序..."
echo ""

# 等待扩展加载
sleep 5

# 检查扩展是否已加载
if ! command -v dialog >/dev/null 2>&1; then
    echo "加载必要扩展..."
    tce-load -i bash dialog parted 2>/dev/null || {
        echo "无法加载扩展，进入shell模式"
        exec /bin/bash
    }
fi

# 执行安装脚本
if [ -x /mnt/sr0/cde/install-openwrt.sh ]; then
    exec /mnt/sr0/cde/install-openwrt.sh
elif [ -x /mnt/sr0/install-openwrt.sh ]; then
    exec /mnt/sr0/install-openwrt.sh
else
    echo "安装脚本未找到"
    echo ""
    echo "手动操作:"
    echo "1. 挂载CD: mount /dev/sr0 /mnt/sr0"
    echo "2. 运行: /mnt/sr0/cde/install-openwrt.sh"
    echo ""
    echo "按Enter键进入shell..."
    read
    exec /bin/bash
fi
BOOTLOCAL
chmod +x "${ISO_DIR}/cde/bootlocal.sh"

# 复制OpenWRT镜像到ISO
log_info "复制OpenWRT镜像到ISO..."
cp "${OPENWRT_IMG}" "${ISO_DIR}/openwrt.img"
mkdir -p  ${ISO_DIR}/boot/isolinux
# 创建BIOS引导配置
log_info "配置BIOS引导..."
if [ -f "${ISO_DIR}/boot/isolinux/isolinux.cfg" ]; then
    # 备份原始配置
    # cp "${ISO_DIR}/boot/isolinux/isolinux.cfg" "${ISO_DIR}/boot/isolinux/isolinux.cfg.orig"
    
    # 创建新的配置
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
  APPEND initrd=/boot/core.gz quiet tce=CD waitusb=5 opt=cde

LABEL shell
  MENU LABEL ^Shell (debug mode)
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz quiet tce=CD waitusb=5 opt=cde norestore
ISOLINUX_CFG
fi

# 准备UEFI引导
log_info "准备UEFI引导..."
mkdir -p "${ISO_DIR}/EFI/BOOT"

# 复制或创建GRUB EFI文件
if [ -f "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" ]; then
    cp "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" \
        "${ISO_DIR}/EFI/BOOT/bootx64.efi"
else
    # 创建简单的GRUB配置
    mkdir -p "${ISO_DIR}/boot/grub"
    cat > "${ISO_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (Tiny Core Linux)" {
    linux /boot/vmlinuz64 quiet tce=CD waitusb=5 opt=cde
    initrd /boot/core.gz
}

menuentry "Shell (debug mode)" {
    linux /boot/vmlinuz64 quiet tce=CD waitusb=5 opt=cde norestore
    initrd /boot/core.gz
}
GRUB_CFG
    
    # 尝试生成EFI文件
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        grub-mkstandalone \
            --format=x86_64-efi \
            --output="${ISO_DIR}/EFI/BOOT/bootx64.efi" \
            --locales="" \
            --fonts="" \
            "boot/grub/grub.cfg=${ISO_DIR}/boot/grub/grub.cfg" 2>/dev/null || \
            log_warning "无法生成GRUB EFI文件"
    fi
fi

# 构建ISO镜像
log_info "构建ISO镜像..."

# 确保有正确的引导文件
if [ ! -f "${ISO_DIR}/boot/isolinux/isolinux.bin" ]; then
    log_info "复制ISOLINUX引导文件..."
    if [ -f "/usr/lib/ISOLINUX/isolinux.bin" ]; then
        cp "/usr/lib/ISOLINUX/isolinux.bin" "${ISO_DIR}/boot/isolinux/"
        cp /usr/lib/syslinux/modules/bios/*.c32 "${ISO_DIR}/boot/isolinux/" 2>/dev/null || true
    fi
fi

# 使用xorriso构建支持BIOS/UEFI双引导的ISO
cd "${ISO_DIR}"

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
        -e EFI/BOOT/bootx64.efi \
        -no-emul-boot \
        # 添加MBR以支持混合模式
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        # 设置权限
        -r \
        -J \
        # 输出
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        . 2>&1 | tee /tmp/iso_build.log
    
    if [ $? -eq 0 ]; then
        log_success "xorriso构建成功"
    else
        log_warning "xorriso构建失败，尝试genisoimage..."
    fi
fi

# 如果xorriso失败，尝试genisoimage
if [ ! -f "${OUTPUT_DIR}/${ISO_NAME}" ] && command -v genisoimage >/dev/null 2>&1; then
    log_info "使用genisoimage构建ISO..."
    
    genisoimage \
        -U \
        -r \
        -v \
        -J \
        -joliet-long \
        -cache-inodes \
        -V "OPENWRT-INSTALL" \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/BOOT/bootx64.efi \
        -no-emul-boot \
        -o "${OUTPUT_DIR}/${ISO_NAME}" \
        . 2>&1 | tee -a /tmp/iso_build.log
    
    # 如果是hybrid ISO，添加isohybrid支持
    if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ] && command -v isohybrid >/dev/null 2>&1; then
        log_info "添加isohybrid支持..."
        isohybrid --uefi "${OUTPUT_DIR}/${ISO_NAME}" 2>/dev/null || \
        isohybrid "${OUTPUT_DIR}/${ISO_NAME}" 2>/dev/null
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
    echo "📊 构建信息:"
    echo "   文件: ${ISO_NAME}"
    echo "   大小: ${ISO_SIZE} (${ISO_SIZE_MB}MB)"
    echo "   卷标: OPENWRT-INSTALL"
    echo "   引导: BIOS + UEFI (hybrid)"
    echo "   内核: Tiny Core Linux ${TINYCORE_VERSION}"
    echo ""
    echo "🎯 特性:"
    echo "   ✓ 基于官方Tiny Core Linux ISO"
    echo "   ✓ 支持BIOS和UEFI双引导"
    echo "   ✓ 自动启动安装程序"
    echo "   ✓ 包含磁盘工具(parted, gdisk, pv等)"
    echo "   ✓ 极小的ISO体积"
    echo ""
    echo "🚀 使用方法:"
    echo "   1. 刻录到U盘:"
    echo "      dd if=${ISO_NAME} of=/dev/sdX bs=4M status=progress"
    echo "   2. 从U盘启动计算机"
    echo "   3. 系统自动进入安装界面"
    echo "   4. 选择目标磁盘并输入'YES'确认"
    echo "   5. 等待安装完成自动重启"
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
包含扩展: bash, dialog, parted, gptfdisk, e2fsprogs, pv, ntfs-3g
安装镜像: $(basename ${OPENWRT_IMG})
注意事项: 安装会完全擦除目标磁盘数据
BUILD_INFO
    
    log_success "构建摘要已保存到: ${OUTPUT_DIR}/build-info.txt"
    
    # 显示ISO基本信息
    echo "📁 ISO基本信息:"
    file "${OUTPUT_DIR}/${ISO_NAME}"
    
else
    log_error "ISO构建失败，查看日志: /tmp/iso_build.log"
    cat /tmp/iso_build.log
    exit 1
fi

# 清理
log_info "清理临时文件..."
rm -rf "${WORK_DIR}"

log_success "✅ 所有步骤完成! Tiny Core Linux安装ISO已创建"
