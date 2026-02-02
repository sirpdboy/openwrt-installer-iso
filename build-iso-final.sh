#!/bin/bash
# build-iso-final.sh - 构建OpenWRT自动安装ISO（修复Debian源问题）
set -e

echo "开始构建OpenWRT安装ISO（修复Debian源问题）..."
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

# 配置APT使用archive源（修复buster EOL问题）
log_info "配置APT源（使用archive源）..."
cat > /etc/apt/sources.list <<EOF
# Debian buster archive sources (buster is EOL)
deb http://archive.debian.org/debian buster main
# deb-src http://archive.debian.org/debian buster main

# Security updates (if available)
# deb http://archive.debian.org/debian-security buster/updates main
# deb-src http://archive.debian.org/debian-security buster/updates main
EOF

# 禁用有效期检查
cat > /etc/apt/apt.conf.d/99no-check-valid-until << 'APT_CONF'
Acquire::Check-Valid-Until "false";
APT::Get::AllowUnauthenticated "true";
APT_CONF

# 安装必要工具
log_info "安装构建工具..."
apt-get update --allow-insecure-repositories
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
    initramfs-tools \
    udev \
    parted \
    wget \
    curl \
    live-boot \
    live-boot-initramfs-tools

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

# 引导Debian系统（使用archive源）
log_info "引导Debian系统（使用archive.debian.org）..."
DEBIAN_MIRROR="http://archive.debian.org/debian"

# 直接使用debootstrap命令，避免中间脚本
if debootstrap --arch=amd64 --variant=minbase \
    --include=linux-image-amd64,systemd-sysv,live-boot \
    buster "${CHROOT_DIR}" \
    "${DEBIAN_MIRROR}" 2>&1 | tee /tmp/debootstrap.log; then
    log_success "Debian系统引导成功"
else
    log_error "debootstrap失败，尝试备用镜像..."
    
    # 尝试备用镜像
    DEBIAN_MIRROR="http://deb.debian.org/debian-archive/debian"
    if debootstrap --arch=amd64 --variant=minbase \
        --include=linux-image-amd64,systemd-sysv,live-boot \
        buster "${CHROOT_DIR}" \
        "${DEBIAN_MIRROR}" 2>&1 | tee -a /tmp/debootstrap.log; then
        log_success "备用镜像引导成功"
    else
        log_error "所有镜像尝试失败"
        cat /tmp/debootstrap.log
        exit 1
    fi
fi

# 配置chroot环境
log_info "配置chroot环境..."

# 创建chroot配置脚本
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# OpenWRT安装系统chroot配置脚本
set -e

echo "🔧 开始配置chroot环境..."

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT使用archive源
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
EOF

# 禁用有效期检查
cat > /etc/apt/apt.conf.d/99no-check-valid-until << 'APT_CONF'
Acquire::Check-Valid-Until "false";
APT::Get::AllowUnauthenticated "true";
APT_CONF

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 配置DNS
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# 更新包列表
echo "更新包列表..."
apt-get update --allow-insecure-repositories

echo "安装必要工具..."
apt-get install -y --allow-unauthenticated --no-install-recommends \
    parted \
    dosfstools \
    gdisk \
    bash \
    dialog \
    initramfs-tools \
    live-boot \
    live-boot-initramfs-tools

# 确保内核已安装
echo "检查内核..."
if ! dpkg -l | grep -q linux-image; then
    echo "安装Linux内核..."
    apt-get install -y --allow-unauthenticated --no-install-recommends \
        linux-image-amd64
fi

# 生成initramfs
echo "生成initramfs..."
update-initramfs -c -k all 2>/dev/null || mkinitramfs -o /boot/initrd.img 2>/dev/null || true

# 创建启动脚本
cat > /opt/start-installer.sh << 'START_SCRIPT'
#!/bin/bash
# OpenWRT安装系统启动脚本

clear
cat << "WELCOME"

╔══════════════════════════════════════════╗
║     OpenWRT Auto Install System          ║
╚══════════════════════════════════════════╝

WELCOME

sleep 2

if [ ! -f "/openwrt.img" ]; then
    echo "❌ Error: OpenWRT image not found"
    echo "Press Enter for shell..."
    read
    exec /bin/bash
fi

exec /opt/install-openwrt.sh
START_SCRIPT
chmod +x /opt/start-installer.sh

# 创建OpenWRT安装脚本
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

# 配置systemd自动启动
cat > /etc/systemd/system/openwrt-installer.service << 'SERVICE'
[Unit]
Description=OpenWRT Auto Installer
After=getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=simple
ExecStart=/opt/start-installer.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable openwrt-installer.service

# 配置自动登录
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
Type=idle
GETTY_OVERRIDE

# 设置root无密码
usermod -p '*' root

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

# 检查内核文件
log_info "检查内核文件..."
VMLINUZ=""
INITRD=""

# 查找内核文件
for file in "${CHROOT_DIR}"/boot/vmlinuz-* "${CHROOT_DIR}"/vmlinuz*; do
    if [ -f "$file" ]; then
        VMLINUZ="$file"
        break
    fi
done

# 查找initrd文件
for file in "${CHROOT_DIR}"/boot/initrd.img-* "${CHROOT_DIR}"/boot/initramfs-* "${CHROOT_DIR}"/initrd*; do
    if [ -f "$file" ]; then
        INITRD="$file"
        break
    fi
done

if [ -n "$VMLINUZ" ] && [ -n "$INITRD" ]; then
    log_success "找到内核: $(basename "$VMLINUZ")"
    log_success "找到initrd: $(basename "$INITRD")"
    
    cp "$VMLINUZ" "${STAGING_DIR}/live/vmlinuz"
    cp "$INITRD" "${STAGING_DIR}/live/initrd"
else
    log_warning "内核文件不完整，创建最小内核..."
    
    # 如果缺少文件，创建最小内核方案
    if [ -z "$VMLINUZ" ]; then
        log_info "下载最小化内核..."
        # 使用当前系统的内核
        if [ -f "/boot/vmlinuz-$(uname -r)" ]; then
            cp "/boot/vmlinuz-$(uname -r)" "${STAGING_DIR}/live/vmlinuz"
            log_success "使用主机系统内核"
        else
            # 下载预编译的内核
            wget -q -O "${STAGING_DIR}/live/vmlinuz" \
                "https://cloud.debian.org/images/cloud/buster/latest/debian-10-generic-amd64-vmlinuz"
            log_success "下载最小内核"
        fi
    fi
    
    if [ -z "$INITRD" ]; then
        log_info "创建最小initrd..."
        # 创建简单的initrd
        cat > /tmp/init << 'INIT_SCRIPT'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
echo "OpenWRT Installer"
exec /bin/sh
INIT_SCRIPT
        
        # 创建cpio存档
        (cd /tmp && echo init | cpio -o -H newc | gzip -9) > "${STAGING_DIR}/live/initrd"
        log_success "创建最小initrd"
    fi
fi

# 卸载chroot文件系统
log_info "卸载chroot文件系统..."
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
umount "${CHROOT_DIR}/sys" 2>/dev/null || true
umount "${CHROOT_DIR}/dev" 2>/dev/null || true
rm -f "${CHROOT_DIR}/install-chroot.sh"

# 创建squashfs文件系统（排除boot，因为内核已单独复制）
log_info "创建squashfs文件系统..."
if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp gzip \
    -noappend \
    -no-progress \
    -e boot; then
    log_success "squashfs创建成功"
    
    # 删除chroot目录以释放空间
    rm -rf "${CHROOT_DIR}"
else
    log_error "squashfs创建失败"
    exit 1
fi

echo "live" > "${STAGING_DIR}/live/filesystem.squashfs.type"

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
  APPEND initrd=/live/initrd boot=live quiet
ISOLINUX_CFG

# 2. GRUB配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=3
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live quiet
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
    log_warning "找不到isolinux.bin"
fi

# GRUB EFI
mkdir -p "${STAGING_DIR}/EFI/boot"
if [ -f /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed ]; then
    cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed \
        "${STAGING_DIR}/EFI/boot/bootx64.efi"
elif [ -f /usr/lib/grub/x86_64-efi/grub.efi ]; then
    cp /usr/lib/grub/x86_64-efi/grub.efi \
        "${STAGING_DIR}/EFI/boot/bootx64.efi"
else
    # 下载grub efi文件
    log_info "下载GRUB EFI文件..."
    wget -q -O "${STAGING_DIR}/EFI/boot/bootx64.efi" \
        "https://github.com/ventoy/grub2/releases/download/1.0.0/grubx64.efi" || \
    log_warning "无法获取GRUB EFI文件"
fi

# 创建EFI映像
if [ -f "${STAGING_DIR}/EFI/boot/bootx64.efi" ]; then
    log_info "创建EFI引导映像..."
    dd if=/dev/zero of="${STAGING_DIR}/EFI/boot/efiboot.img" bs=1M count=2
    mkfs.vfat -F 32 "${STAGING_DIR}/EFI/boot/efiboot.img" 2>/dev/null || true
    
    # 复制EFI文件
    if command -v mcopy >/dev/null 2>&1; then
        mcopy -i "${STAGING_DIR}/EFI/boot/efiboot.img" \
            "${STAGING_DIR}/EFI/boot/bootx64.efi" ::/EFI/boot/
    else
        # 使用mount方式
        MOUNT_POINT=$(mktemp -d)
        mount -t vfat -o loop "${STAGING_DIR}/EFI/boot/efiboot.img" "$MOUNT_POINT"
        mkdir -p "$MOUNT_POINT/EFI/boot"
        cp "${STAGING_DIR}/EFI/boot/bootx64.efi" "$MOUNT_POINT/EFI/boot/"
        umount "$MOUNT_POINT"
        rm -rf "$MOUNT_POINT"
    fi
    log_success "UEFI引导文件创建完成"
fi

# 构建ISO镜像
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

XORRISO_CMD="xorriso -as mkisofs \
    -iso-level 3 \
    -volid 'OPENWRT_INSTALL' \
    -eltorito-boot isolinux/isolinux.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin 2>/dev/null \
    -output '${ISO_PATH}' \
    '${STAGING_DIR}'"

# 添加UEFI支持（如果可用）
if [ -f "${STAGING_DIR}/EFI/boot/efiboot.img" ]; then
    XORRISO_CMD="$XORRISO_CMD \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot"
fi

# 执行xorriso命令
eval "$XORRISO_CMD" 2>&1 | tee /tmp/xorriso.log || {
    log_warning "xorriso命令失败，尝试简化命令..."
    
    # 简化命令
    xorriso -as mkisofs \
        -volid 'OPENWRT_INSTALL' \
        -o "${ISO_PATH}" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        "${STAGING_DIR}" 2>&1 | tee -a /tmp/xorriso.log
}

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
    
    # 创建构建摘要
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Auto Installer ISO
===========================
构建时间: $(date)
ISO文件: $ISO_NAME
文件大小: $ISO_SIZE
支持引导: BIOS + UEFI
使用源: archive.debian.org (buster EOL)
BUILD_INFO
    
    log_success "构建完成！"
else
    log_error "ISO构建失败"
    if [ -f /tmp/xorriso.log ]; then
        echo "xorriso日志:"
        tail -20 /tmp/xorriso.log
    fi
    exit 1
fi

# 清理工作目录
log_info "清理工作目录..."
rm -rf "${WORK_DIR}" /tmp/* 2>/dev/null || true

log_success "所有步骤完成！"
