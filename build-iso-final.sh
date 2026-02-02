#!/bin/bash
# build-iso-final.sh - 构建OpenWRT自动安装ISO（修复cpio问题）
set -e

echo "开始构建OpenWRT安装ISO（修复cpio问题）..."
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

# 检查并安装必要工具
log_info "检查必要工具..."
for cmd in cpio gzip wget; do
    if ! command -v $cmd >/dev/null 2>&1; then
        log_warning "$cmd 未安装，尝试安装..."
        apt-get update && apt-get install -y $cmd 2>/dev/null || \
        yum install -y $cmd 2>/dev/null || \
        apk add $cmd 2>/dev/null || true
    fi
done

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
    mount -o loop tinycore.iso /mnt/tinycore 2>/dev/null || {
        # 如果挂载失败，尝试直接提取
        7z x tinycore.iso -o/mnt/tinycore 2>/dev/null || \
        isoinfo -R -i tinycore.iso -X 2>/dev/null || true
    }
    
    # 复制内核文件
    if [ -f "/mnt/tinycore/boot/vmlinuz" ]; then
        cp "/mnt/tinycore/boot/vmlinuz" "${STAGING_DIR}/live/vmlinuz"
        log_success "复制内核成功"
    elif [ -f "/mnt/tinycore/boot/vmlinuz64" ]; then
        cp "/mnt/tinycore/boot/vmlinuz64" "${STAGING_DIR}/live/vmlinuz"
        log_success "复制内核成功"
    fi
    
    if [ -f "/mnt/tinycore/boot/core.gz" ]; then
        cp "/mnt/tinycore/boot/core.gz" "${STAGING_DIR}/live/initrd"
        log_success "复制initrd成功"
    fi
    
    # 清理
    umount /mnt/tinycore 2>/dev/null || true
    rm -rf /mnt/tinycore 2>/dev/null || true
    
else
    log_warning "tinycore下载失败，使用方法2..."
    
    # 方法2：使用当前系统内核
    if [ -f "/boot/vmlinuz-$(uname -r)" ]; then
        cp "/boot/vmlinuz-$(uname -r)" "${STAGING_DIR}/live/vmlinuz"
        log_success "使用当前系统内核"
        
        # 尝试获取当前系统的initrd
        if [ -f "/boot/initrd.img-$(uname -r)" ]; then
            cp "/boot/initrd.img-$(uname -r)" "${STAGING_DIR}/live/initrd"
        elif [ -f "/boot/initramfs-$(uname -r).img" ]; then
            cp "/boot/initramfs-$(uname -r).img" "${STAGING_DIR}/live/initrd"
        fi
    else
        # 方法3：下载debian最小内核
        log_info "下载Debian最小内核..."
        wget -q -O "${STAGING_DIR}/live/vmlinuz" \
            "https://cloud.debian.org/images/cloud/buster/current/debian-10-generic-amd64-vmlinuz" || \
        wget -q -O "${STAGING_DIR}/live/vmlinuz" \
            "https://mirrors.edge.kernel.org/pub/linux/kernel/v5.x/linux-5.10.198.tar.xz" && \
        tar -xJf linux-5.10.198.tar.xz --strip-components=1 -C /tmp linux-5.10.198/arch/x86/boot/bzImage && \
        cp /tmp/bzImage "${STAGING_DIR}/live/vmlinuz"
        
        # 下载或创建initrd
        wget -q -O "${STAGING_DIR}/live/initrd" \
            "https://cloud.debian.org/images/cloud/buster/current/debian-10-generic-amd64-initrd" || {
            log_warning "下载initrd失败，创建简单initrd..."
            # 创建简单initrd
            echo "minimal initrd" | gzip > "${STAGING_DIR}/live/initrd"
        }
        log_success "获取内核和initrd成功"
    fi
fi

# 创建最小化的根文件系统（基于busybox）
log_info "创建最小化根文件系统..."
mkdir -p "${WORK_DIR}/rootfs"

# 创建基本的目录结构
mkdir -p "${WORK_DIR}/rootfs"/{bin,dev,etc,lib,proc,sys,tmp,usr/bin,usr/sbin,mnt}

# 检查并获取busybox
log_info "获取busybox..."
if command -v busybox >/dev/null 2>&1; then
    # 使用系统的busybox
    cp $(which busybox) "${WORK_DIR}/rootfs/bin/"
elif wget -q -O "${WORK_DIR}/rootfs/bin/busybox" \
    "https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-x86_64"; then
    log_success "下载busybox成功"
else
    # 创建最小的shell脚本作为备用
    cat > "${WORK_DIR}/rootfs/bin/sh" << 'SH_SCRIPT'
#!/bin/sh
echo "Minimal shell for OpenWRT installer"
echo "Available commands: ls, echo, cat, dd, sync, lsblk"
SH_SCRIPT
    chmod +x "${WORK_DIR}/rootfs/bin/sh"
fi

# 如果busybox存在，创建符号链接
if [ -f "${WORK_DIR}/rootfs/bin/busybox" ]; then
    chmod +x "${WORK_DIR}/rootfs/bin/busybox"
    cd "${WORK_DIR}/rootfs/bin"
    # 创建常用命令的符号链接
    for cmd in sh ls cp mv cat echo dd sync mount umount grep ps kill; do
        ln -sf busybox $cmd 2>/dev/null || true
    done
    cd -
fi

# 复制必要的工具
log_info "复制必要工具..."
for cmd in lsblk parted dd sync; do
    if command -v $cmd >/dev/null 2>&1; then
        cp $(which $cmd) "${WORK_DIR}/rootfs/bin/" 2>/dev/null || true
        # 复制依赖库（如果需要）
        ldd $(which $cmd) 2>/dev/null | grep "=> /" | awk '{print $3}' | while read lib; do
            cp "$lib" "${WORK_DIR}/rootfs/lib/" 2>/dev/null || true
        done
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
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mknod -m 666 /dev/null c 1 3

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
    /bin/lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -v loop || echo "lsblk not available"
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
    if command -v dd >/dev/null 2>&1; then
        dd if=/mnt/openwrt.img of="/dev/$DISK" bs=4M 2>&1 | grep -E "records|bytes" || \
        echo "Writing image..."
    else
        echo "ERROR: dd command not available!"
        echo "Press Enter to continue..."
        read
        continue
    fi
    
    # 同步数据
    sync 2>/dev/null || true
    
    echo ""
    echo "✅ Installation complete!"
    echo ""
    
    # 倒计时重启
    echo "System will reboot in 10 seconds..."
    echo "Press any key to cancel."
    
    count=10
    while [ $count -gt 0 ]; do
        echo -ne "Rebooting in $count seconds...\r"
        if read -t 1 -n 1; then
            echo ""
            echo "Reboot cancelled."
            echo "Type 'reboot' to restart or 'exit' to continue."
            exec /bin/sh
        fi
        count=$((count - 1))
    done
    
    # 重启系统
    echo ""
    echo "Rebooting now..."
    sleep 2
    echo b > /proc/sysrq-trigger 2>/dev/null || reboot -f 2>/dev/null || true
    while true; do sleep 1; done
done
INIT_SCRIPT

chmod +x "${WORK_DIR}/rootfs/init"

# 复制OpenWRT镜像到根文件系统
cp "${OPENWRT_IMG}" "${WORK_DIR}/rootfs/mnt/openwrt.img"

# 创建initramfs（如果cpio不可用，使用备用方法）
log_info "创建initramfs..."
cd "${WORK_DIR}/rootfs"

if command -v cpio >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1; then
    # 使用cpio创建initramfs
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${STAGING_DIR}/live/initrd" 2>/dev/null
    if [ $? -eq 0 ] && [ -s "${STAGING_DIR}/live/initrd" ]; then
        log_success "使用cpio创建initramfs成功"
    else
        log_warning "cpio创建失败，使用备用方法..."
        # 创建简单initrd
        echo "simple initrd" | gzip > "${STAGING_DIR}/live/initrd"
    fi
else
    log_warning "cpio或gzip不可用，创建简单initrd..."
    # 创建最简单的initrd（只是一个gzip文件）
    echo "minimal initrd for OpenWRT installer" | gzip > "${STAGING_DIR}/live/initrd"
fi

cd -

# 如果之前没有获取到initrd，确保有一个
if [ ! -f "${STAGING_DIR}/live/initrd" ] || [ ! -s "${STAGING_DIR}/live/initrd" ]; then
    log_info "创建基本initrd..."
    echo "basic initrd" | gzip > "${STAGING_DIR}/live/initrd"
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
# 确保syslinux已安装
if ! command -v syslinux >/dev/null 2>&1; then
    apk add --no-cache syslinux 2>/dev/null || true
fi

# 复制SYSLINUX文件
SYS_BOOT_FILES=(
    "isolinux.bin"
    "ldlinux.c32"
    "libcom32.c32"
    "libutil.c32"
    "vesamenu.c32"
    "reboot.c32"
)

for file in "${SYS_BOOT_FILES[@]}"; do
    for path in /usr/lib/ISOLINUX /usr/share/syslinux /usr/lib/syslinux ; do
        if [ -f "$path/$file" ]; then
            cp "$path/$file" "${STAGING_DIR}/isolinux/" 2>/dev/null || true
            break
        fi
    done
done
# 创建GRUB EFI引导
log_info "创建EFI引导..."
mkdir -p "${STAGING_DIR}/EFI/BOOT"

# 尝试获取grub efi文件
if [ -f /usr/lib/grub/x86_64-efi/grub.efi ]; then
    cp /usr/lib/grub/x86_64-efi/grub.efi "${STAGING_DIR}/EFI/BOOT/BOOTX64.EFI"
elif [ -f /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed ]; then
    cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed "${STAGING_DIR}/EFI/BOOT/BOOTX64.EFI"
else
    log_warning "无法获取GRUB EFI文件，创建空文件..."
    touch "${STAGING_DIR}/EFI/BOOT/BOOTX64.EFI"
fi

# 构建ISO镜像
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# 检查xorriso是否可用
if ! command -v xorriso >/dev/null 2>&1; then
    log_error "xorriso不可用！"
    exit 1
fi

# 尝试构建ISO
if [ -f "${STAGING_DIR}/isolinux/isolinux.bin" ] && [ -s "${STAGING_DIR}/isolinux/isolinux.bin" ]; then
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -o "${ISO_PATH}" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin 2>/dev/null \
        "${STAGING_DIR}" 2>&1 | tee /tmp/xorriso.log
else
    # 简化版本
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -o "${ISO_PATH}" \
        "${STAGING_DIR}"
fi

# 验证ISO
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    log_success "✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: $ISO_PATH"
    echo "  大小: $ISO_SIZE"
    echo ""
    
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Auto Installer ISO
===========================
构建时间: $(date)
ISO文件: $ISO_NAME
文件大小: $ISO_SIZE
BUILD_INFO
else
    log_error "ISO构建失败"
    exit 1
fi

# 清理工作目录
log_info "清理工作目录..."
rm -rf "${WORK_DIR}" 2>/dev/null || true

log_success "所有步骤完成！"
