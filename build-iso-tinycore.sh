#!/bin/bash
# build-iso-tinycore.sh - 修复下载问题的版本
set -e

echo "开始构建Tiny Core Linux安装ISO..."
echo "========================================"

# 参数处理
if [ $# -lt 3 ]; then
    echo "用法: $0 <openwrt_img> <output_dir> <iso_name>"
    echo "示例: $0 ./openwrt.img ./output openwrt-installer.iso"
    exit 1
fi

# 参数定义
OPENWRT_IMG="$1"
OUTPUT_DIR="$2"
ISO_NAME="$3"

# 配置
TINYCORE_VERSION="15.x"
TINYCORE_RELEASE="15.0"
ARCH="x86_64"
TC_MIRROR="http://tinycorelinux.net/${TINYCORE_VERSION}/${ARCH}"
WORK_DIR="/tmp/tc_build_$(date +%s)"
NEW_ISO_DIR="${WORK_DIR}/newiso"

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

# 显示构建信息
log_info "构建参数:"
echo "  OpenWRT镜像: ${OPENWRT_IMG}"
echo "  输出目录: ${OUTPUT_DIR}"
echo "  ISO名称: ${ISO_NAME}"
echo "  Tiny Core版本: ${TINYCORE_VERSION}"

# 检查输入文件
log_info "检查必要文件..."
if [ ! -f "${OPENWRT_IMG}" ]; then
    log_error "找不到OpenWRT镜像: ${OPENWRT_IMG}"
    exit 1
fi

log_info "OpenWRT镜像大小: $(stat -c%s "${OPENWRT_IMG}" | numfmt --to=iec)"

# 清理并创建工作目录
log_info "创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${NEW_ISO_DIR}"

# 创建ISO目录结构
log_info "创建ISO目录结构..."
mkdir -p "${NEW_ISO_DIR}/boot/isolinux"
mkdir -p "${NEW_ISO_DIR}/cde/optional"
mkdir -p "${NEW_ISO_DIR}/tc"
mkdir -p "${NEW_ISO_DIR}/openwrt"

# ================= 下载函数 =================
safe_download() {
    local url="$1"
    local output="$2"
    local description="$3"
    
    echo "下载${description}..."
    
    # 使用curl（如果可用），它有更好的错误处理
    if command -v curl >/dev/null 2>&1; then
        if curl -L --retry 3 --retry-delay 2 --connect-timeout 30 \
               -o "${output}" "${url}" 2>/dev/null; then
            log_success "${description}下载完成"
            return 0
        fi
    fi
    
    # 使用wget作为备选
    if command -v wget >/dev/null 2>&1; then
        if wget -q --tries=3 --timeout=30 --waitretry=2 \
               -O "${output}" "${url}" 2>/dev/null; then
            log_success "${description}下载完成"
            return 0
        fi
    fi
    
    log_warning "${description}下载失败: $url"
    return 1
}

# ================= 下载核心文件 =================
log_info "下载Tiny Core Linux核心文件..."

# 下载内核 - 必须成功
if ! safe_download "${TC_MIRROR}/release/distribution_files/vmlinuz64" \
    "${NEW_ISO_DIR}/boot/vmlinuz64" "内核"; then
    log_error "内核下载失败，无法继续"
    exit 1
fi

# 下载core.gz - 必须成功
if ! safe_download "${TC_MIRROR}/release/distribution_files/corepure64.gz" \
    "${NEW_ISO_DIR}/boot/core.gz" "core.gz"; then
    log_error "core.gz下载失败，无法继续"
    exit 1
fi

# 下载rootfs.gz - 可选
safe_download "${TC_MIRROR}/release/distribution_files/rootfs64.gz" \
    "${NEW_ISO_DIR}/boot/rootfs.gz" "rootfs.gz" || {
    log_warning "rootfs.gz下载失败，使用core.gz代替"
    cp "${NEW_ISO_DIR}/boot/core.gz" "${NEW_ISO_DIR}/boot/rootfs.gz"
}

# 下载ISOLINUX文件
safe_download "${TC_MIRROR}/release/distribution_files/isolinux.bin" \
    "${NEW_ISO_DIR}/boot/isolinux/isolinux.bin" "isolinux.bin" || {
    log_warning "isolinux.bin下载失败，尝试本地文件"
    # 尝试从本地复制
    if [ -f /usr/lib/ISOLINUX/isolinux.bin ]; then
        cp /usr/lib/ISOLINUX/isolinux.bin "${NEW_ISO_DIR}/boot/isolinux/isolinux.bin"
    elif [ -f /usr/lib/syslinux/isolinux.bin ]; then
        cp /usr/lib/syslinux/isolinux.bin "${NEW_ISO_DIR}/boot/isolinux/isolinux.bin"
    else
        log_error "找不到isolinux.bin"
        exit 1
    fi
}

# 下载ISOLINUX模块
ISOLINUX_MODULES=("ldlinux.c32" "libutil.c32" "menu.c32" "libcom32.c32")
for module in "${ISOLINUX_MODULES[@]}"; do
    safe_download "${TC_MIRROR}/release/distribution_files/${module}" \
        "${NEW_ISO_DIR}/boot/isolinux/${module}" "${module}" || {
        log_warning "${module}下载失败，尝试本地文件"
        # 尝试从本地复制
        find /usr/lib/syslinux -name "${module}" -exec cp {} "${NEW_ISO_DIR}/boot/isolinux/" \; 2>/dev/null || true
    }
done

# ================= 复制OpenWRT镜像 =================
log_info "复制OpenWRT镜像..."
cp "${OPENWRT_IMG}" "${NEW_ISO_DIR}/openwrt/openwrt.img"
log_success "OpenWRT镜像已复制"

# ================= 下载扩展包 =================
log_info "下载扩展包..."
cd "${NEW_ISO_DIR}/cde/optional"

# 扩展包列表（已验证存在的）
# 访问 http://tinycorelinux.net/15.x/x86_64/tcz/ 查看可用包
AVAILABLE_EXTENSIONS=(
    "bash.tcz"           # bash shell
    "dialog.tcz"         # 对话框工具
    "ncursesw.tcz"        # 终端控制
    "ncursesw-utils.tcz"  # ncurses工具
    "parted.tcz"         # 分区工具
    "e2fsprogs.tcz"      # ext文件系统工具
    "dosfstools.tcz"     # FAT文件系统工具
    "util-linux.tcz"     # 系统工具（包含fdisk）
    "pv.tcz"             # 进度显示工具
    "syslinux.tcz"       # syslinux工具（可选）
)

# 备选扩展包（如果上面的不可用）
ALTERNATIVE_EXTENSIONS=(
    "coreutils.tcz"      # 核心工具
    "gawk.tcz"           # awk工具
    "grep.tcz"           # grep工具
    "sed.tcz"            # sed工具
    "tar.tcz"            # tar工具
    "gzip.tcz"           # gzip工具
    "fdisk.tcz"          # fdisk（单独包）
)

DOWNLOADED_COUNT=0
FAILED_COUNT=0

for ext in "${AVAILABLE_EXTENSIONS[@]}"; do
    echo "下载: ${ext}"
    
    # 尝试下载
    if wget -q --tries=2 --timeout=20 \
           "${TC_MIRROR}/tcz/${ext}" \
           -O "${ext}" 2>/dev/null; then
        DOWNLOADED_COUNT=$((DOWNLOADED_COUNT + 1))
        
        # 尝试下载依赖和MD5（可选）
        wget -q --tries=1 --timeout=10 \
             "${TC_MIRROR}/tcz/${ext}.dep" \
             -O "${ext}.dep" 2>/dev/null || true
        
        wget -q --tries=1 --timeout=10 \
             "${TC_MIRROR}/tcz/${ext}.md5.txt" \
             -O "${ext}.md5.txt" 2>/dev/null || true
    else
        log_warning "下载失败: ${ext}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        
        # 尝试备选包（如果主要包不可用）
        case "$ext" in
            "syslinux.tcz")
                log_info "syslinux.tcz可能不需要，跳过"
                ;;
            "grub2-multi.tcz")
                log_info "grub2-multi.tcz可能不存在，跳过"
                ;;
            "gptfdisk.tcz")
                log_info "gptfdisk.tcz可能不存在，使用fdisk代替"
                # 尝试下载fdisk
                wget -q "${TC_MIRROR}/tcz/fdisk.tcz" -O "fdisk.tcz" 2>/dev/null && \
                    DOWNLOADED_COUNT=$((DOWNLOADED_COUNT + 1))
                ;;
            *)
                # 尝试备选包
                for alt in "${ALTERNATIVE_EXTENSIONS[@]}"; do
                    if [[ "$alt" =~ "$(echo "$ext" | cut -d. -f1)" ]] || \
                       [[ "$ext" =~ "util-linux" && "$alt" =~ "fdisk" ]]; then
                        echo "  尝试备选: ${alt}"
                        wget -q --tries=1 --timeout=10 \
                             "${TC_MIRROR}/tcz/${alt}" \
                             -O "${alt}" 2>/dev/null && \
                            DOWNLOADED_COUNT=$((DOWNLOADED_COUNT + 1)) && \
                            break
                    fi
                done
                ;;
        esac
    fi
done

log_info "扩展包下载完成: ${DOWNLOADED_COUNT}成功, ${FAILED_COUNT}失败"

# 如果下载的扩展包太少，创建最小集合
if [ $DOWNLOADED_COUNT -lt 3 ]; then
    log_warning "下载的扩展包太少，使用最小集合"
    
    # 创建绝对必要的最小集合
    MINIMAL_EXTENSIONS=("bash.tcz" "dialog.tcz" "ncursesw.tcz" "parted.tcz")
    
    # 清空并重新下载
    rm -f *.tcz
    
    for ext in "${MINIMAL_EXTENSIONS[@]}"; do
        echo "下载最小扩展: ${ext}"
        wget -q "${TC_MIRROR}/tcz/${ext}" -O "${ext}" 2>/dev/null || true
    done
fi

# ================= 创建onboot.lst =================
log_info "创建onboot.lst..."
cat > "${NEW_ISO_DIR}/cde/onboot.lst" << 'ONBOOT'
bash.tcz
dialog.tcz
ncursesw.tcz
ncursesw-utils.tcz
e2fsprogs.tcz
dosfstools.tcz
ONBOOT

# 如果文件不存在，从实际下载的文件创建
if [ ! -f "${NEW_ISO_DIR}/cde/onboot.lst" ]; then
    ls *.tcz 2>/dev/null | head -10 > "${NEW_ISO_DIR}/cde/onboot.lst"
fi

# ================= 创建autostart脚本 =================
log_info "创建autostart脚本..."
cat > "${NEW_ISO_DIR}/cde/autostart.sh" << 'AUTOSTART'
#!/bin/sh
# Tiny Core自动启动脚本

# 等待基础系统启动
sleep 1

# 设置环境
export TERM=linux
stty sane

# 清屏
clear

# 显示标题
cat << "EOF"

╔══════════════════════════════════════╗
║     OpenWRT Tiny Core Installer     ║
╚══════════════════════════════════════╝

EOF

echo "正在启动..."
sleep 1

# 挂载CDROM
CD_DEVICE=""
for dev in /dev/sr0 /dev/cdrom /dev/hdc; do
    if [ -b "$dev" ]; then
        CD_DEVICE="$dev"
        break
    fi
done

if [ -n "$CD_DEVICE" ]; then
    mkdir -p /mnt/cdrom
    mount "$CD_DEVICE" /mnt/cdrom 2>/dev/null || true
fi

# 检查OpenWRT镜像
if [ -f "/mnt/cdrom/openwrt/openwrt.img" ]; then
    echo "✅ 找到OpenWRT镜像"
    
    # 创建简单的安装脚本
    cat > /tmp/install_openwrt.sh << 'INSTALL_EOF'
#!/bin/sh

while true; do
    clear
    echo "========================================"
    echo "      OpenWRT Installation Menu"
    echo "========================================"
    echo ""
    
    # 显示磁盘
    echo "Available disks:"
    echo "----------------"
    if command -v fdisk >/dev/null 2>&1; then
        fdisk -l 2>/dev/null | grep "^Disk /dev/" || echo "No disks found"
    else
        ls -la /dev/sd* /dev/hd* 2>/dev/null | grep '^b' || echo "No disks found"
    fi
    echo "----------------"
    echo ""
    
    echo "OpenWRT image: /mnt/cdrom/openwrt/openwrt.img"
    echo ""
    echo "To install, run:"
    echo "  dd if=/mnt/cdrom/openwrt/openwrt.img of=/dev/sdX bs=4M"
    echo ""
    echo "Options:"
    echo "  1. Show disk details"
    echo "  2. Start installation"
    echo "  3. Open shell"
    echo "  4. Reboot"
    echo ""
    
    read -p "Select option (1-4): " choice
    
    case $choice in
        1)
            echo ""
            echo "Disk details:"
            if command -v fdisk >/dev/null 2>&1; then
                fdisk -l 2>/dev/null
            else
                lsblk 2>/dev/null || echo "Cannot show disk details"
            fi
            echo ""
            read -p "Press Enter to continue..."
            ;;
        2)
            echo ""
            read -p "Enter target disk (e.g., sda): " target_disk
            
            if [ -b "/dev/$target_disk" ]; then
                echo ""
                echo "WARNING: This will erase ALL data on /dev/$target_disk!"
                read -p "Type 'YES' to confirm: " confirm
                
                if [ "$confirm" = "YES" ]; then
                    echo ""
                    echo "Installing OpenWRT to /dev/$target_disk..."
                    
                    if command -v pv >/dev/null 2>&1; then
                        pv /mnt/cdrom/openwrt/openwrt.img | dd of="/dev/$target_disk" bs=4M
                    else
                        dd if=/mnt/cdrom/openwrt/openwrt.img of="/dev/$target_disk" bs=4M status=progress
                    fi
                    
                    sync
                    echo ""
                    echo "✅ Installation complete!"
                    echo "System will reboot in 10 seconds..."
                    
                    for i in {10..1}; do
                        echo -ne "Rebooting in $i seconds...\r"
                        sleep 1
                    done
                    
                    reboot
                else
                    echo "Installation cancelled."
                    sleep 2
                fi
            else
                echo "❌ Disk /dev/$target_disk not found!"
                sleep 2
            fi
            ;;
        3)
            echo "Starting shell..."
            exec /bin/sh
            ;;
        4)
            echo "Rebooting..."
            reboot
            ;;
        *)
            echo "Invalid option"
            sleep 1
            ;;
    esac
done
INSTALL_EOF
    
    chmod +x /tmp/install_openwrt.sh
    exec /tmp/install_openwrt.sh
    
else
    echo "❌ OpenWRT image not found!"
    echo ""
    echo "Files on CDROM:"
    ls -la /mnt/cdrom/ 2>/dev/null || echo "CDROM not mounted"
    echo ""
    echo "Press Enter for shell..."
    read dummy
    exec /bin/sh
fi
AUTOSTART

chmod +x "${NEW_ISO_DIR}/cde/autostart.sh"

# ================= 创建ISOLINUX配置 =================
log_info "创建ISOLINUX配置..."
cat > "${NEW_ISO_DIR}/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT openwrt
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE OpenWRT Installer

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz quiet waitusb=5 tce=cdrom

LABEL shell
  MENU LABEL ^Shell (debug mode)
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz quiet waitusb=5 tce=cdrom norestore

LABEL local
  MENU LABEL Boot from ^local drive
  LOCALBOOT 0x80
  TIMEOUT 60
ISOLINUX_CFG

# 创建boot.cat
touch "${NEW_ISO_DIR}/boot/isolinux/boot.cat"

# ================= 构建ISO =================
log_info "构建ISO镜像..."

# 检查构建工具
if command -v xorriso >/dev/null 2>&1; then
    BUILD_CMD="xorriso -as mkisofs"
    log_info "使用xorriso构建"
elif command -v genisoimage >/dev/null 2>&1; then
    BUILD_CMD="genisoimage"
    log_info "使用genisoimage构建"
elif command -v mkisofs >/dev/null 2>&1; then
    BUILD_CMD="mkisofs"
    log_info "使用mkisofs构建"
else
    log_error "没有找到ISO构建工具"
    exit 1
fi

# 构建ISO
cd "${WORK_DIR}"

log_info "构建命令: $BUILD_CMD"
log_info "输出文件: ${OUTPUT_DIR}/${ISO_NAME}"

if [ "$(echo $BUILD_CMD | cut -d' ' -f1)" = "xorriso" ]; then
    # 使用xorriso
    if ! eval $BUILD_CMD \
        -iso-level 3 \
        -volid "OPENWRT-INSTALL" \
        -eltorito-boot boot/isolinux/isolinux.bin \
        -eltorito-catalog boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        "${NEW_ISO_DIR}" 2>&1; then
        log_error "ISO构建失败"
        exit 1
    fi
else
    # 使用genisoimage/mkisofs
    if ! eval $BUILD_CMD \
        -l \
        -J \
        -R \
        -V "OPENWRT-INSTALL" \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -o "${OUTPUT_DIR}/${ISO_NAME}" \
        "${NEW_ISO_DIR}" 2>&1; then
        log_error "ISO构建失败"
        exit 1
    fi
fi

# ================= 验证构建结果 =================
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    ISO_SIZE=$(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')
    ISO_SIZE_BYTES=$(stat -c%s "${OUTPUT_DIR}/${ISO_NAME}")
    ISO_SIZE_MB=$((ISO_SIZE_BYTES / 1024 / 1024))
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║                 ISO构建成功!                          ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    echo "📊 构建信息:"
    echo "  文件: ${ISO_NAME}"
    echo "  大小: ${ISO_SIZE} (${ISO_SIZE_MB}MB)"
    echo "  位置: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "  引导: BIOS (ISOLINUX)"
    echo ""
    echo "🚀 使用方法:"
    echo "  1. 写入USB: sudo dd if=${OUTPUT_DIR}/${ISO_NAME} of=/dev/sdX bs=4M status=progress"
    echo "  2. 从USB启动"
    echo "  3. 选择 'Install OpenWRT'"
    echo "  4. 按照菜单操作"
    echo ""
    
    # 创建构建信息
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Tiny Core Installer
===========================
构建时间: $(date)
ISO文件: ${ISO_NAME}
ISO大小: ${ISO_SIZE} (${ISO_SIZE_MB}MB)
原始镜像: $(basename "${OPENWRT_IMG}")
镜像大小: $(stat -c%s "${OPENWRT_IMG}" | numfmt --to=iec)
Tiny Core版本: ${TINYCORE_VERSION}
扩展包数量: ${DOWNLOADED_COUNT}
BUILD_INFO
    
    log_success "构建完成!"
    
    # 显示输出目录内容
    echo ""
    echo "📁 输出目录内容:"
    ls -lh "${OUTPUT_DIR}/"
    
else
    log_error "ISO文件未创建"
    exit 1
fi

# 清理
log_info "清理临时文件..."
rm -rf "${WORK_DIR}"

exit 0
