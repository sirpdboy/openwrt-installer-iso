#!/bin/bash
# build-iso-final.sh - 构建OpenWRT自动安装ISO（完全简化版）
set -e

echo "开始构建OpenWRT安装ISO（完全简化版）..."
echo "========================================"

# 基础配置
WORK_DIR="${HOME}/OPENWRT_LIVE"
STAGING_DIR="${WORK_DIR}/staging"

OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-autoinstall.iso}"

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

# 创建目录结构
log_info "创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{boot/grub,isolinux,live}
mkdir -p "${OUTPUT_DIR}"

# 方法1：使用tinycorelinux作为基础（非常小）
log_info "下载最小化Linux系统..."
cd "${WORK_DIR}"

# 尝试下载tinycorelinux
TINYCORE_URL="http://tinycorelinux.net/10.x/x86/release"
if wget -q "${TINYCORE_URL}/Core-current.iso" -O tinycore.iso; then
    log_success "下载tinycorelinux成功"
    
    # 挂载ISO提取内核
    mkdir -p /mnt/tinycore
    mount -o loop tinycore.iso /mnt/tinycore 2>/dev/null || true
    
    # 复制内核文件
    if [ -f "/mnt/tinycore/boot/vmlinuz" ]; then
        cp "/mnt/tinycore/boot/vmlinuz" "${STAGING_DIR}/live/vmlinuz"
        log_success "复制内核成功"
    fi
    
    if [ -f "/mnt/tinycore/boot/core.gz" ]; then
        cp "/mnt/tinycore/boot/core.gz" "${STAGING_DIR}/live/initrd"
        log_success "复制initrd成功"
    fi
    
    umount /mnt/tinycore 2>/dev/null || true
else
    log_warning "tinycore下载失败，使用方法2..."
    
    # 方法2：使用当前系统内核
    if [ -f "/boot/vmlinuz-$(uname -r)" ]; then
        cp "/boot/vmlinuz-$(uname -r)" "${STAGING_DIR}/live/vmlinuz"
        log_success "使用当前系统内核"
    else
        # 方法3：下载debian最小内核
        log_info "下载Debian最小内核..."
        wget -q -O "${STAGING_DIR}/live/vmlinuz" \
            "https://cloud.debian.org/images/cloud/buster/current/debian-10-generic-amd64-vmlinuz"
        
        # 下载initrd
        wget -q -O "${STAGING_DIR}/live/initrd" \
            "https://cloud.debian.org/images/cloud/buster/current/debian-10-generic-amd64-initrd"
        log_success "下载最小内核和initrd成功"
    fi
fi

# 创建最小化的根文件系统（基于busybox）
log_info "创建最小化根文件系统..."
mkdir -p "${WORK_DIR}/rootfs"

# 创建基本的目录结构
mkdir -p "${WORK_DIR}/rootfs"/{bin,dev,etc,lib,proc,sys,tmp,usr/bin,usr/sbin}

# 复制busybox（如果存在）
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) "${WORK_DIR}/rootfs/bin/"
    chmod +x "${WORK_DIR}/rootfs/bin/busybox"
    
    # 创建符号链接
    cd "${WORK_DIR}/rootfs/bin"
    for cmd in sh ls cp mv cat echo dd sync mount umount grep ps kill; do
        ln -s busybox $cmd 2>/dev/null || true
    done
    cd -
fi

# 复制必要的工具
for cmd in lsblk parted dd sync; do
    if command -v $cmd >/dev/null 2>&1; then
        cp $(which $cmd) "${WORK_DIR}/rootfs/bin/" 2>/dev/null || true
    fi
done

# 创建OpenWRT安装脚本
log_info "创建安装脚本..."
cat > "${WORK_DIR}/rootfs/init" << 'INIT_SCRIPT'
#!/bin/sh
# 最小化init脚本

# 挂载虚拟文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# 设置PATH
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# 清屏并显示欢迎信息
clear
cat << "EOF"

╔══════════════════════════════════════════╗
║         OpenWRT Auto Installer           ║
╚══════════════════════════════════════════╝

EOF

echo "Starting OpenWRT installer..."
sleep 2

# 检查OpenWRT镜像
if [ ! -f /mnt/openwrt.img ]; then
    echo "ERROR: OpenWRT image not found!"
    echo "Please ensure the ISO contains openwrt.img"
    echo "Dropping to emergency shell..."
    exec /bin/sh
fi

# 主安装循环
while true; do
    clear
    echo ""
    echo "OpenWRT Auto Installer"
    echo "======================"
    echo ""
    
    # 显示可用磁盘
    echo "Available disks:"
    echo "----------------"
    lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -v loop || echo "No disks found"
    echo "----------------"
    echo ""
    
    echo -n "Enter target disk (e.g., sda): "
    read DISK
    
    if [ -z "$DISK" ]; then
        continue
    fi
    
    if [ ! -b "/dev/$DISK" ]; then
        echo "Disk /dev/$DISK not found!"
        echo "Press Enter to continue..."
        read
        continue
    fi
    
    echo ""
    echo "⚠️  WARNING: This will erase ALL data on /dev/$DISK!"
    echo ""
    echo -n "Type 'YES' to confirm: "
    read CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Installation cancelled."
        echo "Press Enter to continue..."
        read
        continue
    fi
    
    # 开始安装
    clear
    echo ""
    echo "Installing OpenWRT to /dev/$DISK..."
    echo "This may take a few minutes..."
    echo ""
    
    # 使用dd写入镜像
    dd if=/mnt/openwrt.img of="/dev/$DISK" bs=4M status=progress
    
    # 同步数据
    sync
    
    echo ""
    echo "✅ Installation complete!"
    echo ""
    
    # 倒计时重启
    echo "System will reboot in 10 seconds..."
    echo "Press any key to cancel."
    
    for i in {10..1}; do
        echo -ne "Rebooting in $i seconds...\r"
        if read -t 1 -n 1; then
            echo ""
            echo "Reboot cancelled."
            echo "Type 'reboot' to restart or 'exit' to continue."
            exec /bin/sh
        fi
    done
    
    # 重启系统
    echo ""
    echo "Rebooting now..."
    sleep 2
    reboot -f
done
INIT_SCRIPT

chmod +x "${WORK_DIR}/rootfs/init"

# 复制OpenWRT镜像到根文件系统
cp "${OPENWRT_IMG}" "${WORK_DIR}/rootfs/mnt/openwrt.img"

# 创建initramfs
log_info "创建initramfs..."
cd "${WORK_DIR}/rootfs"
find . | cpio -o -H newc | gzip -9 > "${STAGING_DIR}/live/initrd"
cd -

# 如果之前没有下载initrd，使用刚创建的
if [ ! -f "${STAGING_DIR}/live/initrd" ] || [ ! -s "${STAGING_DIR}/live/initrd" ]; then
    log_info "使用自定义initramfs..."
    # 已经在上一步创建了
fi

# 确保有内核文件
if [ ! -f "${STAGING_DIR}/live/vmlinuz" ]; then
    log_error "没有内核文件！"
    exit 1
fi

# 创建引导配置
log_info "创建引导配置..."

# 1. ISOLINUX配置
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT install
TIMEOUT 100
PROMPT 0

LABEL install
  MENU LABEL Install OpenWRT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=ttyS0 console=tty0 quiet
ISOLINUX_CFG

# 2. GRUB配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz console=ttyS0 console=tty0 quiet
    initrd /live/initrd
}
GRUB_CFG

# 复制引导文件
log_info "复制引导文件..."

# ISOLINUX
if [ -f /usr/lib/ISOLINUX/isolinux.bin ]; then
    cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/"
elif [ -f /usr/lib/syslinux/isolinux.bin ]; then
    cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/"
else
    log_warning "找不到isolinux.bin，尝试下载..."
    wget -q -O "${STAGING_DIR}/isolinux/isolinux.bin" \
        "https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz" && \
    tar -xzf syslinux-6.04-pre1.tar.gz --strip-components=4 -C "${STAGING_DIR}/isolinux/" \
        "syslinux-6.04-pre1/bios/core/isolinux.bin" 2>/dev/null || true
fi

# 复制syslinux模块
if [ -f /usr/lib/syslinux/modules/bios/ldlinux.c32 ]; then
    cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "${STAGING_DIR}/isolinux/"
    cp /usr/lib/syslinux/modules/bios/libcom32.c32 "${STAGING_DIR}/isolinux/"
    cp /usr/lib/syslinux/modules/bios/libutil.c32 "${STAGING_DIR}/isolinux/"
fi

# 创建GRUB EFI引导（简化版）
log_info "创建EFI引导..."
mkdir -p "${STAGING_DIR}/EFI/BOOT"

# 尝试获取grub efi文件
if [ -f /usr/lib/grub/x86_64-efi/grub.efi ]; then
    cp /usr/lib/grub/x86_64-efi/grub.efi "${STAGING_DIR}/EFI/BOOT/BOOTX64.EFI"
elif command -v grub-mkstandalone >/dev/null 2>&1; then
    # 生成grub efi
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="${STAGING_DIR}/EFI/BOOT/BOOTX64.EFI" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=${STAGING_DIR}/boot/grub/grub.cfg"
fi

# 构建ISO镜像
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# 简单的xorriso命令
xorriso -as mkisofs \
    -volid "OPENWRT_INSTALL" \
    -o "${ISO_PATH}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/BOOT/BOOTX64.EFI \
    -no-emul-boot \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin 2>/dev/null \
    "${STAGING_DIR}" 2>&1 | tee /tmp/xorriso.log || {
    log_warning "完整ISO构建失败，尝试简化版本..."
    
    # 简化版本（只支持BIOS）
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -o "${ISO_PATH}" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        "${STAGING_DIR}"
}

# 验证ISO
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    ISO_SIZE_BYTES=$(stat -c%s "$ISO_PATH" 2>/dev/null || echo "unknown")
    
    echo ""
    log_success "✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: $ISO_PATH"
    echo "  大小: $ISO_SIZE"
    echo ""
    echo "使用方法："
    echo "  1. dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress"
    echo "  2. 从USB启动计算机"
    echo "  3. 系统将自动启动安装程序"
    echo "  4. 选择目标磁盘并确认安装"
    echo ""
    
    # 创建构建摘要
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Auto Installer ISO (简化版)
==================================
构建时间: $(date)
ISO文件: $ISO_NAME
文件大小: $ISO_SIZE ($ISO_SIZE_BYTES 字节)
支持引导: BIOS + UEFI
内核来源: TinyCoreLinux/当前系统/下载
系统类型: 最小化busybox系统
功能: OpenWRT自动安装
BUILD_INFO
    
    log_success "构建完成！"
else
    log_error "ISO构建失败"
    if [ -f /tmp/xorriso.log ]; then
        echo "错误日志:"
        tail -20 /tmp/xorriso.log
    fi
    exit 1
fi

# 清理工作目录
log_info "清理工作目录..."
rm -rf "${WORK_DIR}" 2>/dev/null || true

log_success "所有步骤完成！"
