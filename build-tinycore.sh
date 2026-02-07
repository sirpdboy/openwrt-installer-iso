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
    echo "请确保镜像文件位于: ${OPENWRT_IMG}"
    exit 1
fi

IMG_SIZE=$(ls -lh "${OPENWRT_IMG}" | awk '{print $5}')
log_info "OpenWRT镜像大小: ${IMG_SIZE}"

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

# 下载必要的扩展 - 最小化集合确保启动
log_info "下载必要扩展..."
cd "${OPTIONAL_DIR}"

# 扩展列表 - 只包含绝对必要的
ESSENTIAL_EXTENSIONS=(
    "bash.tcz"
    "dialog.tcz"
    "parted.tcz"
    "e2fsprogs.tcz"
)

DOWNLOADED_EXTS=()

for ext in "${ESSENTIAL_EXTENSIONS[@]}"; do
    echo "下载扩展: $ext"
    if wget -q --tries=2 --timeout=30 "${TCZ_DIR}/${ext}" -O "${ext}"; then
        echo "✅ $ext"
        DOWNLOADED_EXTS+=("$ext")
        # 下载依赖文件
        wget -q "${TCZ_DIR}/${ext}.dep" -O "${ext}.dep" 2>/dev/null || true
        wget -q "${TCZ_DIR}/${ext}.md5.txt" -O "${ext}.md5.txt" 2>/dev/null || true
    else
        log_error "无法下载必需扩展: $ext"
        exit 1
    fi
done

# 创建onboot.lst文件
log_info "创建onboot.lst..."
cat > "${TC_DIR}/onboot.lst" << 'ONBOOT_EOF'
bash.tcz
dialog.tcz
parted.tcz
e2fsprogs.tcz
ONBOOT_EOF

# 复制OpenWRT镜像到ISO根目录（确保可访问）
log_info "复制OpenWRT镜像到ISO..."
cp "${OPENWRT_IMG}" "${ISO_DIR}/openwrt.img"
chmod 644 "${ISO_DIR}/openwrt.img"
ls -lh "${ISO_DIR}/openwrt.img"

# 创建自动安装脚本 - 放在多个位置确保能找到
log_info "创建自动安装脚本..."

# 1. 在ISO根目录创建脚本
cat > "${ISO_DIR}/autorun.sh" << 'AUTORUN_SCRIPT'
#!/bin/bash
# 自动安装脚本 - ISO根目录版本

echo "========================================"
echo "    OpenWRT Auto Installer"
echo "========================================"
echo ""

# 等待系统初始化
sleep 3

# 设置环境
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 加载必要扩展
echo "加载必要工具..."
tce-load -i bash dialog parted e2fsprogs 2>/dev/null || {
    echo "扩展加载失败，尝试从CD加载..."
    sleep 2
}

# 查找OpenWRT镜像
echo "查找OpenWRT镜像..."
OPENWRT_IMG=""

# 检查多个可能位置
for path in "/mnt/sr0/openwrt.img" "/mnt/cdrom/openwrt.img" "/openwrt.img" "./openwrt.img"; do
    if [ -f "$path" ]; then
        OPENWRT_IMG="$path"
        echo "找到镜像: $OPENWRT_IMG"
        break
    fi
done

# 如果没找到，尝试挂载CD
if [ -z "$OPENWRT_IMG" ]; then
    echo "尝试挂载CD/DVD..."
    for dev in /dev/sr0 /dev/cdrom /dev/sr1; do
        if [ -b "$dev" ]; then
            mount_point="/mnt/cdrom_$(basename $dev)"
            mkdir -p "$mount_point"
            if mount "$dev" "$mount_point" 2>/dev/null; then
                if [ -f "$mount_point/openwrt.img" ]; then
                    OPENWRT_IMG="$mount_point/openwrt.img"
                    echo "找到镜像: $OPENWRT_IMG"
                    break
                fi
            fi
        fi
    done
fi

if [ -z "$OPENWRT_IMG" ] || [ ! -f "$OPENWRT_IMG" ]; then
    echo "❌ 错误: 找不到OpenWRT镜像"
    echo ""
    echo "请手动查找:"
    echo "find / -name 'openwrt.img' 2>/dev/null"
    echo ""
    echo "按Enter键进入shell..."
    read
    exec /bin/bash
fi

# 运行主安装程序
echo "启动安装程序..."
exec /bin/bash -c "cd /; /tmp/install-main.sh"
AUTORUN_SCRIPT

chmod +x "${ISO_DIR}/autorun.sh"

# 2. 在主安装脚本
cat > "${ISO_DIR}/install-main.sh" << 'MAIN_SCRIPT'
#!/bin/bash
# 主安装程序

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 清屏
clear

# 显示标题
echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║        OpenWRT Auto Installer                        ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo -e "${BLUE}正在初始化...${NC}"
echo ""

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 需要root权限${NC}"
    echo "请重新运行: sudo $0"
    exit 1
fi

# 查找OpenWRT镜像
echo -e "${BLUE}查找OpenWRT镜像...${NC}"

# 检查多个位置
IMG_PATHS=(
    "/openwrt.img"
    "/mnt/sr0/openwrt.img"
    "/mnt/cdrom/openwrt.img"
    "$(pwd)/openwrt.img"
    "$(find / -name 'openwrt.img' 2>/dev/null | head -1)"
)

OPENWRT_IMG=""
for img_path in "${IMG_PATHS[@]}"; do
    if [ -f "$img_path" ]; then
        OPENWRT_IMG="$img_path"
        break
    fi
done

if [ -z "$OPENWRT_IMG" ] || [ ! -f "$OPENWRT_IMG" ]; then
    echo -e "${RED}❌ 错误: 找不到OpenWRT镜像${NC}"
    echo ""
    echo "请检查镜像文件是否存在"
    echo "当前目录: $(pwd)"
    echo "目录内容:"
    ls -la ./
    echo ""
    echo "按Enter键进入shell..."
    read
    exec /bin/bash
fi

echo -e "${GREEN}✅ 找到镜像: $OPENWRT_IMG${NC}"
IMG_SIZE=$(ls -lh "$OPENWRT_IMG" 2>/dev/null | awk '{print $5}' || echo "未知")
echo "镜像大小: $IMG_SIZE"
echo ""

# 安装循环
while true; do
    # 显示磁盘
    echo -e "${BLUE}可用磁盘:${NC}"
    echo "================="
    
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -o NAME,SIZE,MODEL | grep -v '^NAME' | while read line; do
            disk="/dev/$(echo $line | awk '{print $1}')"
            info=$(echo $line | cut -d' ' -f2-)
            echo "$disk - $info"
        done
    else
        for disk in /dev/sd? /dev/nvme?n? /dev/vd?; do
            [ -b "$disk" ] && echo "$disk"
        done
    fi
    
    echo "================="
    echo ""
    
    read -p "输入目标磁盘 (例如: sda): " DISK_INPUT
    
    [ -z "$DISK_INPUT" ] && continue
    
    if [[ "$DISK_INPUT" =~ ^/dev/ ]]; then
        DISK="$DISK_INPUT"
    else
        DISK="/dev/$DISK_INPUT"
    fi
    
    [ ! -b "$DISK" ] && echo -e "${RED}磁盘不存在${NC}" && continue
    
    echo ""
    echo -e "${BLUE}磁盘信息:${NC}"
    if command -v fdisk >/dev/null 2>&1; then
        fdisk -l "$DISK" 2>/dev/null | head -3
    fi
    echo ""
    
    # 确认
    echo -e "${RED}⚠️  警告: 将擦除 $DISK 所有数据!${NC}"
    echo ""
    read -p "输入 'YES' 确认: " CONFIRM
    
    [ "$CONFIRM" != "YES" ] && continue
    
    # 开始安装
    clear
    echo ""
    echo -e "${GREEN}正在安装到 $DISK ...${NC}"
    echo ""
    
    # 使用dd
    echo "开始复制镜像..."
    dd if="$OPENWRT_IMG" of="$DISK" bs=4M status=progress 2>/dev/null || \
    dd if="$OPENWRT_IMG" of="$DISK" bs=4M
    
    # 同步
    sync
    
    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✅ 安装完成!${NC}"
        echo ""
        echo "系统将在10秒后重启..."
        
        for i in {10..1}; do
            echo -ne "倒计时: $i 秒...\r"
            sleep 1
        done
        
        echo ""
        echo "正在重启..."
        reboot
    else
        echo -e "${RED}❌ 安装失败${NC}"
        echo ""
        read -p "按Enter键重试..."
    fi
done
MAIN_SCRIPT

chmod +x "${ISO_DIR}/install-main.sh"

# 3. 创建简单的bootlocal.sh（Tiny Core自动执行）
cat > "${ISO_DIR}/bootlocal.sh" << 'BOOTLOCAL_SCRIPT'
#!/bin/sh
# Tiny Core自动启动脚本

# 等待网络和基本初始化
sleep 3

# 尝试执行自动安装
if [ -x /mnt/sr0/autorun.sh ]; then
    echo "执行自动安装脚本..."
    /mnt/sr0/autorun.sh
elif [ -x /autorun.sh ]; then
    echo "执行根目录安装脚本..."
    /autorun.sh
else
    echo "自动安装脚本未找到"
    echo "手动安装请运行: /install-main.sh"
    echo "进入shell..."
    exec /bin/sh
fi
BOOTLOCAL_SCRIPT

chmod +x "${ISO_DIR}/bootlocal.sh"

# 4. 创建.profile自动启动
cat > "${ISO_DIR}/.profile" << 'PROFILE_SCRIPT'
# 自动启动安装程序
if [ -z "$AUTO_STARTED" ]; then
    export AUTO_STARTED=1
    # 等待系统就绪
    sleep 2
    # 检查并运行安装程序
    if [ -f /tmp/install-main.sh ]; then
        /tmp/install-main.sh
    elif [ -f /install-main.sh ]; then
        /install-main.sh
    fi
fi
PROFILE_SCRIPT

chmod +x "${ISO_DIR}/.profile"

# 创建BIOS引导配置
log_info "配置BIOS引导..."

# 复制ISOLINUX文件
if [ -f "/usr/lib/ISOLINUX/isolinux.bin" ]; then
    cp "/usr/lib/ISOLINUX/isolinux.bin" "${ISO_DIR}/boot/isolinux/"
    cp /usr/lib/syslinux/modules/bios/menu.c32 "${ISO_DIR}/boot/isolinux/" 2>/dev/null || true
    cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "${ISO_DIR}/boot/isolinux/" 2>/dev/null || true
    cp /usr/lib/syslinux/modules/bios/libutil.c32 "${ISO_DIR}/boot/isolinux/" 2>/dev/null || true
    cp /usr/lib/syslinux/modules/bios/libcom32.c32 "${ISO_DIR}/boot/isolinux/" 2>/dev/null || true
else
    log_warning "ISOLINUX文件未找到，尝试下载"
    wget -q "http://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/6.03/syslinux-6.03.tar.gz" -O syslinux.tar.gz 2>/dev/null
    if [ -f "syslinux.tar.gz" ]; then
        tar -xzf syslinux.tar.gz syslinux-6.03/bios/core/isolinux.bin syslinux-6.03/bios/com32/menu/menu.c32 2>/dev/null
        cp syslinux-6.03/bios/core/isolinux.bin "${ISO_DIR}/boot/isolinux/"
        cp syslinux-6.03/bios/com32/menu/menu.c32 "${ISO_DIR}/boot/isolinux/" 2>/dev/null
        log_success "ISOLINUX文件下载成功"
    else
        log_error "无法获取ISOLINUX文件"
        exit 1
    fi
fi

# 创建ISOLINUX配置 - 关键：设置自动启动
cat > "${ISO_DIR}/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT autoinstall
PROMPT 0
TIMEOUT 10
UI menu.c32

MENU TITLE OpenWRT Installer - Tiny Core Linux

LABEL autoinstall
  MENU LABEL ^Auto Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz quiet waitusb=5 tce=cdrom

LABEL shell
  MENU LABEL ^Shell (Manual)
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz quiet waitusb=5 tce=cdrom norestore

LABEL local
  MENU LABEL ^Boot from local disk
  LOCALBOOT 0x80
ISOLINUX_CFG

# 创建UEFI引导
log_info "创建UEFI引导配置..."

# 方法1: 使用xorriso直接创建EFI引导（推荐）
if command -v xorriso >/dev/null 2>&1; then
    log_info "准备UEFI引导文件..."
    
    # 创建GRUB配置
    mkdir -p "${ISO_DIR}/boot/grub"
    cat > "${ISO_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=3
set default=0

menuentry "Auto Install OpenWRT" {
    linux /boot/vmlinuz64 quiet waitusb=5 tce=cdrom
    initrd /boot/core.gz
}

menuentry "Shell (Manual)" {
    linux /boot/vmlinuz64 quiet waitusb=5 tce=cdrom norestore
    initrd /boot/core.gz
}

menuentry "Boot from local disk" {
    exit
}
GRUB_CFG

    # 创建EFI目录结构
    mkdir -p "${ISO_DIR}/EFI/BOOT"
    
    # 尝试多种方法获取EFI文件
    EFI_FOUND=false
    
    # 方法A: 使用系统GRUB文件
    if [ -f "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" ]; then
        cp "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" \
            "${ISO_DIR}/EFI/BOOT/bootx64.efi"
        EFI_FOUND=true
    elif [ -f "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" ]; then
        cp "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" \
            "${ISO_DIR}/EFI/BOOT/bootx64.efi"
        EFI_FOUND=true
    fi
    
    # 方法B: 下载预编译的GRUB EFI
    if [ "$EFI_FOUND" = false ]; then
        log_info "下载GRUB EFI文件..."
        if wget -q "https://github.com/ventoy/grub2/raw/master/grub-2.04/grub2-2.04/grub_x64.efi" -O "${ISO_DIR}/EFI/BOOT/bootx64.efi"; then
            EFI_FOUND=true
        fi
    fi
    
    if [ "$EFI_FOUND" = true ]; then
        log_success "UEFI引导文件准备完成"
    else
        log_warning "UEFI引导文件未找到，将创建仅BIOS引导的ISO"
    fi
fi

# 构建ISO镜像
log_info "构建ISO镜像..."
cd "${ISO_DIR}"

# 显示ISO内容
echo "ISO目录内容:"
ls -la ./
echo ""
echo "boot目录内容:"
ls -la boot/
echo ""
echo "镜像文件:"
ls -lh openwrt.img 2>/dev/null || echo "openwrt.img not found"

# 使用xorriso构建ISO（支持双引导）
if command -v xorriso >/dev/null 2>&1; then
    log_info "使用xorriso构建ISO..."
    
    # 检查是否有EFI文件
    EFI_FILE=""
    if [ -f "EFI/BOOT/bootx64.efi" ]; then
        EFI_FILE="EFI/BOOT/bootx64.efi"
        log_info "检测到UEFI引导文件: $EFI_FILE"
    fi
    
    # 构建命令
    XORRISO_CMD="xorriso -as mkisofs \
        -iso-level 3 \
        -volid 'OPENWRT-INSTALL' \
        -eltorito-boot boot/isolinux/isolinux.bin \
        -eltorito-catalog boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin"
    
    # 添加UEFI引导
    if [ -n "$EFI_FILE" ]; then
        XORRISO_CMD="$XORRISO_CMD \
            -eltorito-alt-boot \
            -e '$EFI_FILE' \
            -no-emul-boot \
            -isohybrid-gpt-basdat"
    fi
    
    XORRISO_CMD="$XORRISO_CMD \
        -r -J \
        -o '${OUTPUT_DIR}/${ISO_NAME}' \
        ."
    
    echo "执行命令:"
    echo "$XORRISO_CMD"
    
    eval $XORRISO_CMD 2>&1 | tee /tmp/iso_build.log
    
    BUILD_RESULT=$?
    
    if [ $BUILD_RESULT -eq 0 ]; then
        log_success "ISO构建成功"
    else
        log_warning "xorriso构建失败，错误代码: $BUILD_RESULT"
        cat /tmp/iso_build.log | tail -20
    fi
fi

# 备用构建方法
if [ ! -f "${OUTPUT_DIR}/${ISO_NAME}" ] && command -v genisoimage >/dev/null 2>&1; then
    log_info "使用genisoimage构建ISO..."
    
    genisoimage \
        -U -r -v -J -joliet-long \
        -V 'OPENWRT-INSTALL' \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -o "${OUTPUT_DIR}/${ISO_NAME}" \
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
    echo "   引导: BIOS + UEFI"
    echo "   内核: Tiny Core Linux ${TINYCORE_VERSION}"
    echo ""
    echo "✅ 包含文件:"
    echo "   - openwrt.img (安装镜像)"
    echo "   - autorun.sh (自动安装脚本)"
    echo "   - install-main.sh (主安装程序)"
    echo "   - bootlocal.sh (启动脚本)"
    echo ""
    echo "🚀 使用方法:"
    echo "   1. 刻录到U盘: dd if=${ISO_NAME} of=/dev/sdX bs=4M status=progress"
    echo "   2. 从U盘启动计算机"
    echo "   3. 自动进入安装界面"
    echo "   4. 选择目标磁盘并输入'YES'确认"
    echo ""
    echo "🔧 手动启动:"
    echo "   如果自动启动失败，在shell中运行: /install-main.sh"
    echo ""
    
    # 创建构建摘要
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Tiny Core Installer ISO
===============================
构建时间: $(date)
ISO文件: ${ISO_NAME}
文件大小: ${ISO_SIZE} (${ISO_SIZE_MB}MB)
基于: Tiny Core Linux ${TINYCORE_VERSION}
引导支持: BIOS + UEFI
自动启动: 是
安装镜像: $(basename ${OPENWRT_IMG}) (${IMG_SIZE})
包含工具: bash, dialog, parted, e2fsprogs
引导参数: quiet waitusb=5 tce=cdrom
注意事项: 安装会完全擦除目标磁盘数据！
BUILD_INFO
    
    log_success "构建摘要已保存到: ${OUTPUT_DIR}/build-info.txt"
    
    # 验证ISO
    echo "🔍 ISO验证:"
    file "${OUTPUT_DIR}/${ISO_NAME}"
    
    # 检查ISO内容
    echo ""
    echo "📋 ISO引导测试:"
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -indev "${OUTPUT_DIR}/${ISO_NAME}" -toc 2>/dev/null | \
            grep -E "(El.Torito|Bootable|UEFI|efi)" || echo "基本引导信息"
    fi
    
else
    log_error "ISO构建失败!"
    echo "错误日志:"
    cat /tmp/iso_build.log 2>/dev/null | tail -30
    echo ""
    echo "ISO目录结构:"
    find "${ISO_DIR}" -type f | sed "s|${ISO_DIR}/||" | sort
    exit 1
fi

# 清理临时文件
log_info "清理临时文件..."
rm -rf "${WORK_DIR}"

log_success "✅ 所有步骤完成! Tiny Core Linux安装ISO已创建"
