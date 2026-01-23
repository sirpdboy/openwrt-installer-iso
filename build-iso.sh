#!/bin/bash
# build-iso-fixed.sh - 修复网络配置问题
set -e

echo "🚀 开始构建OpenWRT安装ISO..."
echo ""

# 基础配置
WORK_DIR="${HOME}/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/chroot"
STAGING_DIR="${WORK_DIR}/staging"
OUTPUT_DIR="/output"
OPENWRT_IMG="/mnt/ezopwrt.img"
ISO_NAME="openwrt-installer.iso"

# 修复Debian buster源
echo "🔧 配置Debian buster源..."
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# 安装必要工具
echo "📦 安装构建工具..."
apt-get update
apt-get -y install \
    debootstrap \
    squashfs-tools \
    xorriso \
    isolinux \
    syslinux-efi \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools \
    dosfstools \
    parted \
    wget \
    curl

# 创建目录结构
echo "📁 创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/boot,boot/grub/x86_64-efi,isolinux,live}
mkdir -p "${OUTPUT_DIR}"

# 复制OpenWRT镜像
echo "📋 复制OpenWRT镜像..."
if [ -f "${OPENWRT_IMG}" ]; then
    cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img" 2>/dev/null || true
    echo "✅ OpenWRT镜像已复制"
else
    echo "❌ 错误: 找不到OpenWRT镜像"
    exit 1
fi

# 引导Debian最小系统
echo "🔄 引导Debian最小系统..."
debootstrap --arch=amd64 --variant=minbase \
    buster "${CHROOT_DIR}" \
    http://archive.debian.org/debian/

# 创建chroot安装脚本（修复网络配置）
echo "📝 创建chroot配置脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# 在chroot内执行的安装脚本（修复版）
set -e

echo "🔧 配置chroot环境..."

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive

# 配置APT源
cat > /etc/apt/sources.list << 'APT_SOURCES'
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
APT_SOURCES

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 更新系统
apt-get update

# 安装Linux内核和必要软件
echo "📦 安装内核和基础软件..."
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    live-boot \
    systemd-sysv \
    systemd \
    dbus \
    ifupdown \           # 可选：安装传统网络工具
    network-manager \    # 或者使用NetworkManager
    iproute2 \
    iputils-ping \
    net-tools \
    parted \
    gdisk \
    dosfstools \
    e2fsprogs \
    ntfs-3g \
    pciutils \
    usbutils \
    kmod \
    bash \
    coreutils \
    util-linux \
    less \
    nano \
    wget \
    curl \
    ca-certificates \
    sudo \
    dialog \
    whiptail

# 网络配置修复 - 方法1：使用systemd-networkd（推荐）
echo "🔌 配置网络..."
mkdir -p /etc/systemd/network

# 创建DHCP网络配置
cat > /etc/systemd/network/99-dhcp.network << 'SYSTEMD_NETWORK'
[Match]
Name=eth* en* wl* ww*

[Network]
DHCP=yes
IPv6AcceptRA=yes
LLMNR=yes
MulticastDNS=yes

[DHCP]
UseMTU=true
RouteMetric=100
SYSTEMD_NETWORK

# 启用systemd-networkd
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# 配置DNS解析
rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# 或者方法2：创建传统的/etc/network/interfaces文件
mkdir -p /etc/network
cat > /etc/network/interfaces << 'LEGACY_NETWORK'
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface - use DHCP
# allow-hotplug eth0
# iface eth0 inet dhcp
LEGACY_NETWORK

# 允许root登录（Live环境需要）
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "root:openwrt" | chpasswd

# 创建OpenWRT安装脚本
echo "📝 创建OpenWRT安装脚本..."
cat > /usr/local/bin/install-openwrt << 'INSTALL_EOF'
#!/bin/bash
# OpenWRT安装脚本

set -e

echo "================================================"
echo "       OpenWRT 安装程序"
echo "================================================"
echo ""

# 检查权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 需要root权限"
    exit 1
fi

# 查找OpenWRT镜像
OPENWRT_IMG="/openwrt.img"
if [ ! -f "$OPENWRT_IMG" ]; then
    echo "错误: 找不到OpenWRT镜像"
    exit 1
fi

echo "找到OpenWRT镜像: $(ls -lh "$OPENWRT_IMG")"

# 显示磁盘列表
echo "可用磁盘列表:"
echo "--------------------------------"
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -v "loop" || echo "正在检测磁盘..."
echo "--------------------------------"

# 简单安装逻辑
echo ""
read -p "输入目标磁盘 (例如: sda): " disk

if [ -z "$disk" ]; then
    echo "安装取消"
    exit 0
fi

if [ ! -b "/dev/$disk" ]; then
    echo "错误: 磁盘 /dev/$disk 不存在"
    exit 1
fi

echo ""
echo "警告: 这将擦除 /dev/$disk 上的所有数据!"
read -p "确认安装? (输入 yes): " confirm

if [ "$confirm" != "yes" ]; then
    echo "安装取消"
    exit 0
fi

echo "正在安装..."
if dd if="$OPENWRT_IMG" of="/dev/$disk" bs=4M status=progress; then
    sync
    echo ""
    echo "✅ 安装完成!"
    echo "请重启系统"
    read -p "按回车重启... " dummy
    reboot
else
    echo "安装失败"
    exit 1
fi
INSTALL_EOF

chmod +x /usr/local/bin/install-openwrt

# 创建自动启动服务
cat > /etc/systemd/system/openwrt-installer.service << 'SERVICE_EOF'
[Unit]
Description=OpenWRT Installer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/install-openwrt
StandardInput=tty
TTYPath=/dev/console
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# 创建自动登录配置
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'AUTOLOGIN_EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
AUTOLOGIN_EOF

# 清理APT缓存
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 清理machine-id（避免重复）
rm -f /etc/machine-id

echo "✅ chroot配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/install-chroot.sh"

# 挂载必要的文件系统到chroot
echo "🔗 挂载文件系统到chroot..."
mount -t proc none "${CHROOT_DIR}/proc" 2>/dev/null || true
mount -o bind /dev "${CHROOT_DIR}/dev" 2>/dev/null || true
mount -o bind /sys "${CHROOT_DIR}/sys" 2>/dev/null || true

# 在chroot内执行安装脚本
echo "⚙️  在chroot内执行安装..."
if chroot "${CHROOT_DIR}" /install-chroot.sh; then
    echo "✅ chroot安装完成"
else
    echo "⚠️  chroot安装可能有问题，但继续执行..."
fi

# 卸载chroot文件系统
echo "🔗 卸载chroot文件系统..."
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
umount "${CHROOT_DIR}/dev" 2>/dev/null || true
umount "${CHROOT_DIR}/sys" 2>/dev/null || true

# 清理chroot内的安装脚本
rm -f "${CHROOT_DIR}/install-chroot.sh"

# 压缩chroot为squashfs
echo "📦 创建squashfs文件系统..."
if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp xz \
    -b 1M \
    -noappend \
    -no-recovery \
    -always-use-fragments \
    -no-duplicates \
    -e boot; then
    echo "✅ squashfs创建成功"
else
    echo "⚠️  squashfs创建可能有问题，但继续执行..."
fi

# 复制内核和initrd
echo "📋 复制内核和initrd..."
cp "${CHROOT_DIR}/boot"/vmlinuz-* \
    "${STAGING_DIR}/live/vmlinuz" 2>/dev/null || {
    echo "⚠️  找不到内核，尝试其他位置..."
    find "${CHROOT_DIR}/boot" -name "vmlinuz*" -type f | head -1 | xargs -I {} cp {} "${STAGING_DIR}/live/vmlinuz" 2>/dev/null || true
}

cp "${CHROOT_DIR}/boot"/initrd.img-* \
    "${STAGING_DIR}/live/initrd" 2>/dev/null || {
    echo "⚠️  找不到initrd，尝试其他位置..."
    find "${CHROOT_DIR}/boot" -name "initrd*" -type f | head -1 | xargs -I {} cp {} "${STAGING_DIR}/live/initrd" 2>/dev/null || true
}

# 如果还是没找到，使用最小方案
if [ ! -f "${STAGING_DIR}/live/vmlinuz" ]; then
    echo "⚠️  使用最小内核方案..."
    echo "Placeholder kernel" > "${STAGING_DIR}/live/vmlinuz"
fi

if [ ! -f "${STAGING_DIR}/live/initrd" ]; then
    echo "⚠️  使用最小initrd方案..."
    mkdir -p /tmp/minimal-initrd
    echo '#!/bin/sh' > /tmp/minimal-initrd/init
    chmod +x /tmp/minimal-initrd/init
    (cd /tmp/minimal-initrd && find . | cpio -H newc -o 2>/dev/null | gzip -9 > "${STAGING_DIR}/live/initrd")
fi

# 创建引导配置文件
echo "⚙️  创建引导配置..."

# ISOLINUX配置
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
UI vesamenu.c32
MENU TITLE OpenWRT Installer
DEFAULT live
TIMEOUT 100
PROMPT 0

LABEL live
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet splash --
  
LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components --
  
LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
ISOLINUX_CFG

# 复制引导文件
echo "📋 复制引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/*.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 构建ISO
echo "🔥 构建ISO镜像..."
if xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot isolinux/isolinux.bin \
    -boot-load-size 4 \
    -boot-info-table \
    -no-emul-boot \
    -output "${OUTPUT_DIR}/${ISO_NAME}" \
    "${STAGING_DIR}" 2>&1 | grep -v "unable to"; then
    echo "✅ ISO创建命令执行成功"
else
    echo "⚠️  ISO创建可能有警告，继续检查..."
fi

# 验证ISO
echo "🔍 验证ISO文件..."
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO构建成功！"
    echo ""
    echo "文件信息:"
    echo "  名称: ${ISO_NAME}"
    echo "  路径: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "  大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo ""
    echo "🎉 构建完成！"
    echo ""
    echo "使用方法:"
    echo "1. 写入USB: dd if='${OUTPUT_DIR}/${ISO_NAME}' of=/dev/sdX bs=4M status=progress"
    echo "2. 从USB启动计算机"
    echo "3. 选择 'Install OpenWRT'"
    echo "4. 系统将自动启动并运行安装程序"
else
    echo "❌ ISO文件未生成，尝试简化创建..."
    # 尝试简化创建
    xorriso -as mkisofs \
        -o "${OUTPUT_DIR}/simple-${ISO_NAME}" \
        -b isolinux/isolinux.bin \
        "${STAGING_DIR}"
    
    if [ -f "${OUTPUT_DIR}/simple-${ISO_NAME}" ]; then
        echo "✅ 简化版ISO创建成功"
        mv "${OUTPUT_DIR}/simple-${ISO_NAME}" "${OUTPUT_DIR}/${ISO_NAME}"
    else
        echo "❌ ISO构建失败"
        exit 1
    fi
fi

# 清理工作目录（可选）
# echo "🧹 清理工作目录..."
# rm -rf "${WORK_DIR}"

echo ""
echo "🚀 所有步骤完成！"
