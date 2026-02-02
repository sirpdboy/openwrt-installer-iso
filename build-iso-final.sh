#!/bin/bash
# build-iso-final.sh - 构建OpenWRT自动安装ISO（修复依赖问题）
set -e

echo "开始构建OpenWRT安装ISO（修复依赖问题）..."
echo "========================================"

# 基础配置
WORK_DIR="${HOME}/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/chroot"
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
    echo "请确保OpenWRT镜像文件存在"
    exit 1
fi

# 配置APT使用archive源
log_info "配置APT源..."
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
EOF

cat > /etc/apt/apt.conf.d/99no-check-valid-until << 'APT_CONF'
Acquire::Check-Valid-Until "false";
APT::Get::AllowUnauthenticated "true";
APT_CONF

# 安装必要工具（修复依赖问题）
log_info "安装构建工具（修复依赖）..."
apt-get update --allow-insecure-repositories

# 先安装基础依赖
apt-get install -y --allow-unauthenticated \
    debootstrap \
    squashfs-tools \
    xorriso \
    isolinux \
    syslinux-common \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools \
    dosfstools \
    parted \
    wget \
    curl

# 尝试安装live-boot相关包（不强制）
log_info "尝试安装live-boot组件..."
apt-get install -y --allow-unauthenticated \
    live-boot \
    initramfs-tools \
    udev || {
    log_warning "live-boot安装失败，使用替代方案"
    # 创建基本的live-boot功能
    mkdir -p /usr/share/initramfs-tools/scripts/init-bottom
    mkdir -p /usr/share/initramfs-tools/scripts/init-premount
}

# 创建目录结构
log_info "创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/boot,boot/grub/x86_64-efi,isolinux,live}
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${WORK_DIR}/tmp"

# 复制OpenWRT镜像
log_info "复制OpenWRT镜像..."
mkdir -p "${CHROOT_DIR}"
cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img"
log_success "OpenWRT镜像已复制"

# 引导Debian系统（简化版本，不使用live-boot）
log_info "引导Debian最小系统..."
DEBIAN_MIRROR="http://archive.debian.org/debian"

# 使用debootstrap直接创建基本系统
debootstrap --arch=amd64 --variant=minbase \
    --include=linux-image-amd64,systemd-sysv \
    buster "${CHROOT_DIR}" \
    "${DEBIAN_MIRROR}" 2>&1 | tee /tmp/debootstrap.log

if [ $? -eq 0 ]; then
    log_success "Debian系统引导成功"
else
    log_error "debootstrap失败"
    cat /tmp/debootstrap.log
    exit 1
fi

# 配置chroot环境（简化版本）
log_info "配置chroot环境..."

cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# OpenWRT安装系统chroot配置脚本（简化版）
set -e

echo "🔧 开始配置chroot环境..."

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
EOF

cat > /etc/apt/apt.conf.d/99no-check-valid-until << 'APT_CONF'
Acquire::Check-Valid-Until "false";
APT::Get::AllowUnauthenticated "true";
APT_CONF

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 配置DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 更新包列表
apt-get update --allow-insecure-repositories

# 安装必要工具
apt-get install -y --allow-unauthenticated --no-install-recommends \
    parted \
    dosfstools \
    gdisk \
    bash

# 创建最小化的内核环境
echo "配置内核..."
if ! dpkg -l | grep -q linux-image; then
    apt-get install -y --allow-unauthenticated --no-install-recommends \
        linux-image-amd64
fi

# 创建init脚本（替代live-boot）
cat > /init << 'INIT_SCRIPT'
#!/bin/sh
# 最小化init脚本

PATH=/bin:/sbin:/usr/bin:/usr/sbin

# 挂载虚拟文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# 创建设备节点
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts

# 设置控制台
exec >/dev/console 2>&1
echo "Starting OpenWRT Installer..."

# 设置环境
export PATH
export HOME=/root

# 运行安装脚本
if [ -f /openwrt.img ]; then
    echo "OpenWRT image found, starting installer..."
    /opt/install-openwrt.sh
else
    echo "ERROR: OpenWRT image not found!"
    echo "Dropping to emergency shell..."
    exec /bin/sh
fi
INIT_SCRIPT
chmod +x /init

# 创建安装脚本
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT自动安装脚本

clear
cat << "EOF"

╔══════════════════════════════════════════╗
║         OpenWRT Auto Installer           ║
╚══════════════════════════════════════════╝

EOF

echo ""
echo "Checking OpenWRT image..."
if [ ! -f "/openwrt.img" ]; then
    echo "❌ ERROR: OpenWRT image not found!"
    echo ""
    echo "Press Enter for shell..."
    read
    exec /bin/bash
fi

echo "✅ OpenWRT image found"
echo ""

while true; do
    echo "Available disks:"
    echo "================="
    lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || echo "No disks found"
    echo "================="
    echo ""
    
    read -p "Enter target disk (e.g., sda): " DISK
    
    if [ -z "$DISK" ]; then
        continue
    fi
    
    if [ ! -b "/dev/$DISK" ]; then
        echo "❌ Disk /dev/$DISK not found!"
        continue
    fi
    
    echo ""
    echo "⚠️  WARNING: This will erase ALL data on /dev/$DISK!"
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        continue
    fi
    
    clear
    echo ""
    echo "Installing OpenWRT to /dev/$DISK..."
    echo ""
    
    dd if=/openwrt.img of="/dev/$DISK" bs=4M status=progress
    
    sync
    echo ""
    echo "✅ Installation complete!"
    echo ""
    
    for i in {10..1}; do
        echo -ne "Rebooting in $i seconds... (Press any key to cancel)\r"
        if read -t 1 -n 1; then
            echo ""
            echo "Reboot cancelled."
            echo "Type 'reboot' to restart."
            exec /bin/bash
        fi
    done
    
    reboot -f
done
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "✅ chroot配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/install-chroot.sh"

# 挂载文件系统到chroot
log_info "挂载文件系统到chroot..."
mount -t proc none "${CHROOT_DIR}/proc"
mount -o bind /dev "${CHROOT_DIR}/dev"
mount -o bind /sys "${CHROOT_DIR}/sys"

# 在chroot内执行安装脚本
log_info "在chroot内执行安装..."
chroot "${CHROOT_DIR}" /bin/bash -c "/install-chroot.sh 2>&1 | tee /install.log"

# 获取内核文件
log_info "获取内核文件..."
VMLINUZ=""
INITRD=""

# 查找内核
for vmlinuz in "${CHROOT_DIR}"/boot/vmlinuz-* "${CHROOT_DIR}"/vmlinuz*; do
    [ -f "$vmlinuz" ] && VMLINUZ="$vmlinuz" && break
done

# 查找initramfs
for initrd in "${CHROOT_DIR}"/boot/initrd.img-* "${CHROOT_DIR}"/boot/initramfs-*; do
    [ -f "$initrd" ] && INITRD="$initrd" && break
done

if [ -z "$VMLINUZ" ]; then
    log_warning "未找到内核，创建最小内核..."
    # 使用当前系统内核
    if [ -f "/boot/vmlinuz-$(uname -r)" ]; then
        cp "/boot/vmlinuz-$(uname -r)" "${STAGING_DIR}/live/vmlinuz"
        log_success "使用主机系统内核"
    else
        # 下载一个最小内核
        wget -q -O "${STAGING_DIR}/live/vmlinuz" \
            "https://cloud.debian.org/images/cloud/buster/current-10/debian-10-generic-amd64-vmlinuz"
        log_success "下载最小内核"
    fi
else
    cp "$VMLINUZ" "${STAGING_DIR}/live/vmlinuz"
    log_success "复制内核: $(basename "$VMLINUZ")"
fi

if [ -z "$INITRD" ]; then
    log_warning "未找到initrd，创建最小initrd..."
    # 创建最小initrd
    cat > /tmp/create_initrd.sh << 'CREATE_INITRD'
#!/bin/sh
cd /tmp
mkdir initrd
cd initrd

# 创建基本结构
mkdir -p bin dev etc lib lib64 proc sys sbin
cp /bin/busybox bin/ 2>/dev/null || cp /bin/sh bin/

# 创建init脚本
cat > init << 'INIT'
#!/bin/sh
# 最小init脚本
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "Starting OpenWRT Installer..."

# 查找根文件系统
for device in /dev/sr0 /dev/cdrom /dev/sda /dev/sdb; do
    if [ -b "$device" ]; then
        mount -o ro "$device" /mnt 2>/dev/null && break
    fi
done

# 如果找到squashfs，挂载它
if [ -f /mnt/live/filesystem.squashfs ]; then
    echo "Found squashfs, mounting..."
    mount -t squashfs /mnt/live/filesystem.squashfs /root
fi

# 切换根文件系统
exec switch_root /root /init
INIT
chmod +x init

# 创建cpio存档
find . | cpio -o -H newc | gzip -9 > /tmp/initrd.img
CREATE_INITRD

    chmod +x /tmp/create_initrd.sh
    /tmp/create_initrd.sh
    cp /tmp/initrd.img "${STAGING_DIR}/live/initrd"
    log_success "创建最小initrd"
else
    cp "$INITRD" "${STAGING_DIR}/live/initrd"
    log_success "复制initrd: $(basename "$INITRD")"
fi

# 卸载chroot文件系统
log_info "卸载chroot文件系统..."
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
umount "${CHROOT_DIR}/sys" 2>/dev/null || true
umount "${CHROOT_DIR}/dev" 2>/dev/null || true
rm -f "${CHROOT_DIR}/install-chroot.sh"

# 创建squashfs文件系统
log_info "创建squashfs文件系统..."
if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp gzip \
    -noappend; then
    log_success "squashfs创建成功"
    rm -rf "${CHROOT_DIR}"
else
    log_error "squashfs创建失败"
    exit 1
fi

# 创建引导配置
log_info "创建引导配置..."

# 1. ISOLINUX配置
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
TIMEOUT 30
PROMPT 0

LABEL live
  MENU LABEL Install OpenWRT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd
ISOLINUX_CFG

# 2. GRUB配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=3
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz
    initrd /live/initrd
}
GRUB_CFG

# 复制引导文件
log_info "复制引导文件..."
# ISOLINUX
if [ -f /usr/lib/ISOLINUX/isolinux.bin ]; then
    cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/"
fi

# GRUB EFI
mkdir -p "${STAGING_DIR}/EFI/boot"
if [ -f /usr/lib/grub/x86_64-efi/grub.efi ]; then
    cp /usr/lib/grub/x86_64-efi/grub.efi \
        "${STAGING_DIR}/EFI/boot/bootx64.efi"
fi

# 创建EFI映像
if [ -f "${STAGING_DIR}/EFI/boot/bootx64.efi" ]; then
    log_info "创建EFI引导映像..."
    dd if=/dev/zero of="${STAGING_DIR}/EFI/boot/efiboot.img" bs=1M count=2
    mkfs.vfat -F 32 "${STAGING_DIR}/EFI/boot/efiboot.img" 2>/dev/null || true
    
    # 使用mcopy复制文件
    if command -v mcopy >/dev/null 2>&1; then
        mcopy -i "${STAGING_DIR}/EFI/boot/efiboot.img" \
            "${STAGING_DIR}/EFI/boot/bootx64.efi" ::/EFI/boot/
    fi
    log_success "UEFI引导文件创建完成"
fi

# 构建ISO镜像
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# 简化构建命令
xorriso -as mkisofs \
    -volid 'OPENWRT_INSTALL' \
    -o "${ISO_PATH}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin 2>/dev/null \
    "${STAGING_DIR}" 2>&1 | tee /tmp/xorriso.log

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
rm -rf "${WORK_DIR}" /tmp/* 2>/dev/null || true

log_success "所有步骤完成！"
