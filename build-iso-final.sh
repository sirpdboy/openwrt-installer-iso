#!/bin/bash
# build-iso-final.sh - 构建OpenWRT自动安装ISO（修复内核问题）
set -e

echo "开始构建OpenWRT安装ISO（修复内核问题）..."
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

# 安装必要工具（包含live-boot）
log_info "安装构建工具..."
apt-get update
apt-get -y install \
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

# 引导Debian系统（包含内核）
log_info "引导Debian系统（包含Linux内核）..."
DEBIAN_MIRROR="http://archive.debian.org/debian"

# 创建debootstrap脚本
cat > /tmp/debootstrap.sh << 'DEBOOTSTRAP'
#!/bin/bash
set -e

# 执行debootstrap
debootstrap --arch=amd64 --variant=minbase \
    --include=linux-image-amd64,systemd-sysv,live-boot,live-boot-initramfs-tools \
    buster "$1" "$2"
DEBOOTSTRAP
chmod +x /tmp/debootstrap.sh

if /tmp/debootstrap.sh "${CHROOT_DIR}" "${DEBIAN_MIRROR}" 2>&1 | tee /tmp/debootstrap.log; then
    log_success "Debian系统引导成功"
else
    log_error "debootstrap失败"
    cat /tmp/debootstrap.log
    exit 1
fi

# 检查是否安装了内核
log_info "检查内核安装..."
chroot "${CHROOT_DIR}" dpkg -l | grep linux-image || {
    log_warning "内核未安装，手动安装..."
    
    # 进入chroot安装内核
    mount -t proc none "${CHROOT_DIR}/proc"
    mount -o bind /dev "${CHROOT_DIR}/dev"
    mount -o bind /sys "${CHROOT_DIR}/sys"
    
    cat > "${CHROOT_DIR}/install-kernel.sh" << 'KERNEL_INSTALL'
#!/bin/bash
set -e

echo "安装Linux内核..."
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

apt-get update
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    live-boot \
    live-boot-initramfs-tools \
    systemd-sysv

# 生成initramfs
update-initramfs -c -k all

echo "内核安装完成"
KERNEL_INSTALL
    chmod +x "${CHROOT_DIR}/install-kernel.sh"
    
    chroot "${CHROOT_DIR}" /install-kernel.sh
    
    umount "${CHROOT_DIR}/proc" 2>/dev/null || true
    umount "${CHROOT_DIR}/sys" 2>/dev/null || true
    umount "${CHROOT_DIR}/dev" 2>/dev/null || true
    rm -f "${CHROOT_DIR}/install-kernel.sh"
}

# 创建chroot配置脚本
log_info "创建chroot配置脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# OpenWRT安装系统chroot配置脚本
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

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 配置DNS
cat > /etc/resolv.conf << 'RESOLV'
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLV

# 更新包列表
echo "更新包列表..."
apt-get update

echo "安装必要工具..."
apt-get install -y --no-install-recommends \
    parted \
    dosfstools \
    gdisk \
    bash \
    dialog

# 确保内核文件存在
echo "检查内核文件..."
if [ ! -d /boot ]; then
    mkdir -p /boot
fi

# 创建最小的启动脚本
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

# 设置root密码
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
if ls "${CHROOT_DIR}"/boot/vmlinuz-* 1>/dev/null 2>&1; then
    log_success "找到内核文件"
    ls -la "${CHROOT_DIR}"/boot/
else
    log_warning "内核文件不存在，安装最小内核..."
    
    # 安装最小化内核
    cat > "${CHROOT_DIR}/install-minimal-kernel.sh" << 'MINIMAL_KERNEL'
#!/bin/bash
set -e

echo "安装最小化内核..."

# 安装最小化的linux-image
apt-get update
apt-get install -y --no-install-recommends \
    linux-image-5.10.0-28-amd64 \
    linux-base

# 生成initramfs
mkinitramfs -o /boot/initrd.img-5.10.0-28-amd64 5.10.0-28-amd64

echo "最小化内核安装完成"
MINIMAL_KERNEL
    chmod +x "${CHROOT_DIR}/install-minimal-kernel.sh"
    
    chroot "${CHROOT_DIR}" /install-minimal-kernel.sh
    rm -f "${CHROOT_DIR}/install-minimal-kernel.sh"
fi

# 卸载chroot文件系统
log_info "卸载chroot文件系统..."
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
umount "${CHROOT_DIR}/sys" 2>/dev/null || true
umount "${CHROOT_DIR}/dev" 2>/dev/null || true
rm -f "${CHROOT_DIR}/install-chroot.sh"

# 复制内核和initrd
log_info "复制内核和initrd..."

# 查找最新的内核文件
VMLINUZ=$(ls -1 "${CHROOT_DIR}"/boot/vmlinuz-* 2>/dev/null | tail -1)
INITRD=$(ls -1 "${CHROOT_DIR}"/boot/initrd.img-* 2>/dev/null | tail -1)

if [ -f "$VMLINUZ" ] && [ -f "$INITRD" ]; then
    log_success "找到内核: $(basename "$VMLINUZ")"
    log_success "找到initrd: $(basename "$INITRD")"
    
    cp "$VMLINUZ" "${STAGING_DIR}/live/vmlinuz"
    cp "$INITRD" "${STAGING_DIR}/live/initrd"
    
    # 压缩initrd以减小大小
    log_info "压缩initrd..."
    if command -v xz >/dev/null 2>&1; then
        xz -9 "${STAGING_DIR}/live/initrd"
        mv "${STAGING_DIR}/live/initrd.xz" "${STAGING_DIR}/live/initrd"
    fi
else
    log_error "找不到内核或initrd文件"
    echo "尝试查找的文件:"
    ls -la "${CHROOT_DIR}"/boot/ 2>/dev/null || echo "boot目录不存在"
    
    # 创建最小化的内核文件（备用方案）
    log_warning "使用备用内核方案..."
    
    # 从当前系统复制一个最小的内核
    if [ -f /boot/vmlinuz-$(uname -r) ]; then
        cp /boot/vmlinuz-$(uname -r) "${STAGING_DIR}/live/vmlinuz"
        log_success "从主机系统复制内核"
    else
        # 下载一个最小化的内核
        log_info "下载最小化内核..."
        KERNEL_URL="https://mirrors.edge.kernel.org/pub/linux/kernel/v5.x/linux-5.10.tar.xz"
        wget -q -O /tmp/linux.tar.xz "$KERNEL_URL"
        tar -xf /tmp/linux.tar.xz -C /tmp
        
        # 编译最小配置（简化版本）
        cd /tmp/linux-*
        make defconfig
        make -j4 bzImage
        
        if [ -f arch/x86/boot/bzImage ]; then
            cp arch/x86/boot/bzImage "${STAGING_DIR}/live/vmlinuz"
            log_success "编译最小内核成功"
        else
            log_error "无法获取内核文件"
            exit 1
        fi
    fi
    
    # 创建最小的initrd
    log_info "创建最小initrd..."
    cat > /tmp/create-initrd.sh << 'INITRD_SCRIPT'
#!/bin/bash
set -e

cd /tmp
mkdir -p initrd
cd initrd

# 创建基本目录结构
mkdir -p bin dev etc lib lib64 proc sys sbin usr/bin usr/sbin

# 复制必要的工具
for tool in sh echo cat ls mkdir mount umount sleep; do
    cp /bin/$tool bin/ 2>/dev/null || true
done

# 创建init脚本
cat > init << 'INIT'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "OpenWRT Installer Minimal Initrd"

# 启动主程序
exec /bin/sh
INIT
chmod +x init

# 创建cpio存档
find . | cpio -o -H newc | gzip -9 > /tmp/initrd.img
INITRD_SCRIPT
    chmod +x /tmp/create-initrd.sh
    /tmp/create-initrd.sh
    
    if [ -f /tmp/initrd.img ]; then
        cp /tmp/initrd.img "${STAGING_DIR}/live/initrd"
        log_success "创建最小initrd成功"
    else
        # 创建空initrd（非常简单的版本）
        echo "空initrd" | gzip > "${STAGING_DIR}/live/initrd"
        log_warning "使用空initrd（可能无法正常工作）"
    fi
fi

# 创建squashfs文件系统
log_info "创建squashfs文件系统..."
if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp xz \
    -Xdict-size 1M \
    -b 1M \
    -noappend \
    -no-recovery \
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
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# GRUB EFI
mkdir -p "${STAGING_DIR}/EFI/boot"
if [ -f /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed ]; then
    cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed \
        "${STAGING_DIR}/EFI/boot/bootx64.efi"
elif [ -f /usr/lib/grub/x86_64-efi/grub.efi ]; then
    cp /usr/lib/grub/x86_64-efi/grub.efi \
        "${STAGING_DIR}/EFI/boot/bootx64.efi"
fi

# 创建EFI映像
if [ -f "${STAGING_DIR}/EFI/boot/bootx64.efi" ]; then
    log_info "创建EFI引导映像..."
    dd if=/dev/zero of="${STAGING_DIR}/EFI/boot/efiboot.img" bs=1M count=2
    mkfs.vfat -F 32 "${STAGING_DIR}/EFI/boot/efiboot.img" 2>/dev/null
    
    # 使用mcopy复制文件
    mcopy -i "${STAGING_DIR}/EFI/boot/efiboot.img" \
        "${STAGING_DIR}/EFI/boot/bootx64.efi" ::/EFI/boot/
    
    log_success "UEFI引导文件创建完成"
fi

# 构建ISO镜像
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

if [ -f "${STAGING_DIR}/EFI/boot/efiboot.img" ]; then
    # 构建支持BIOS+UEFI的ISO
    xorriso -as mkisofs \
        -iso-level 3 \
        -volid "OPENWRT_INSTALL" \
        -eltorito-boot isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "${ISO_PATH}" \
        "${STAGING_DIR}"
else
    # 只支持BIOS的ISO
    xorriso -as mkisofs \
        -iso-level 3 \
        -volid "OPENWRT_INSTALL" \
        -eltorito-boot isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "${ISO_PATH}" \
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
    echo "🎉 构建完成！"
    
    # 创建构建摘要
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Auto Installer ISO
===========================
构建时间: $(date)
ISO文件: $ISO_NAME
文件大小: $ISO_SIZE
支持引导: BIOS + UEFI
内核文件: $(basename "$VMLINUZ" 2>/dev/null || echo "自定义内核")
BUILD_INFO
else
    log_error "ISO构建失败"
    exit 1
fi

# 清理工作目录
log_info "清理工作目录..."
rm -rf "${WORK_DIR}"
rm -rf "${STAGING_DIR}" 2>/dev/null || true

log_success "所有步骤完成！"
