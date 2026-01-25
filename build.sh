#!/bin/bash
# build-openwrt-installer-final.sh - 修复live文件系统找不到的问题
set -e

echo "🚀 开始构建OpenWRT安装ISO..."
echo "========================================"

# 基础配置
WORK_DIR="${HOME}/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/chroot"
STAGING_DIR="${WORK_DIR}/staging"
OUTPUT_DIR="/output"
OPENWRT_IMG="/mnt/ezopwrt.img"
ISO_NAME="openwrt-autoinstall.iso"

# 清理并创建目录
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${CHROOT_DIR}"
mkdir -p "${STAGING_DIR}"/{boot/grub,isolinux,live}
mkdir -p "${OUTPUT_DIR}"

# 检查OpenWRT镜像
if [ ! -f "${OPENWRT_IMG}" ]; then
    echo "❌ 错误: 找不到OpenWRT镜像: ${OPENWRT_IMG}"
    exit 1
fi

echo "✅ 找到OpenWRT镜像: $(ls -lh ${OPENWRT_IMG} | awk '{print $5}')"

# 配置APT源
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
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
    syslinux \
    syslinux-common \
    grub-pc-bin \
    mtools \
    dosfstools \
    wget \
    curl

# 引导Debian系统
echo "🔄 引导Debian系统..."
debootstrap --arch=amd64 --variant=minbase \
    buster "${CHROOT_DIR}" \
    http://archive.debian.org/debian

# 创建chroot配置脚本
cat > "${CHROOT_DIR}/setup.sh" << 'CHROOT_EOF'
#!/bin/bash
set -e

echo "🔧 配置chroot环境..."

# 基本设置
export DEBIAN_FRONTEND=noninteractive
echo "openwrt-installer" > /etc/hostname

# 配置APT源
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
deb http://archive.debian.org/debian-security buster/updates main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# 更新并安装必要软件
apt-get update
apt-get -y install \
    linux-image-amd64 \
    live-boot \
    live-boot-initramfs-tools \
    systemd \
    bash \
    util-linux \
    parted \
    dosfstools \
    dialog \
    pv \
    wget \
    locales

# 配置locale
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# 设置root密码
echo 'root:$1$xyz$Xq6CxFpL9Q7yRcZ8pzB.Z.:0:0:root:/root:/bin/bash' > /etc/passwd
echo 'root::0:0:99999:7:::' > /etc/shadow

# 创建自动启动脚本
cat > /etc/profile.d/autostart.sh << 'PROFILE'
# 在tty1自动启动安装程序
if [ "$(tty)" = "/dev/tty1" ]; then
    sleep 2
    clear
    /opt/install-openwrt.sh
fi
PROFILE

# 创建安装脚本
mkdir -p /opt
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT安装脚本

clear
cat << "EOF"

╔═══════════════════════════════════════════════════════╗
║               OpenWRT Auto Installer                  ║
╚═══════════════════════════════════════════════════════╝

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

echo "✅ OpenWRT image found: $(ls -lh /openwrt.img | awk '{print $5}')"
echo ""

while true; do
    # 显示磁盘
    echo "Available disks:"
    echo "================="
    lsblk -d -n -o NAME,SIZE,MODEL | grep -E '^(sd|hd|nvme)' || echo "No disks found"
    echo "================="
    echo ""
    
    read -p "Enter target disk (e.g., sda): " DISK
    
    if [ -z "$DISK" ]; then
        echo "Please enter a disk name"
        continue
    fi
    
    if [ ! -b "/dev/$DISK" ]; then
        echo "❌ Disk /dev/$DISK not found!"
        continue
    fi
    
    # 确认
    echo ""
    echo "⚠️  WARNING: This will erase ALL data on /dev/$DISK!"
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        continue
    fi
    
    # 安装
    clear
    echo ""
    echo "Installing OpenWRT to /dev/$DISK..."
    echo ""
    
    if command -v pv >/dev/null 2>&1; then
        pv /openwrt.img | dd of="/dev/$DISK" bs=4M
    else
        dd if=/openwrt.img of="/dev/$DISK" bs=4M status=progress
    fi
    
    sync
    echo ""
    echo "✅ Installation complete!"
    echo ""
    echo "System will reboot in 10 seconds..."
    echo "Press any key to cancel."
    
    for i in {10..1}; do
        echo -ne "Rebooting in $i seconds...\r"
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

# 配置live-boot
cat > /etc/live/boot.conf << 'EOF'
LIVE_BOOT=live-boot
LIVE_MEDIA=cdrom
EOF

# 配置initramfs
cat > /etc/initramfs-tools/conf.d/live << 'EOF'
export LIVE_BOOT=live-boot
export LIVE_MEDIA=cdrom
EOF

# 生成initramfs
update-initramfs -c -k all

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
CHROOT_EOF

chmod +x "${CHROOT_DIR}/setup.sh"

# 挂载并配置chroot
echo "⚙️ 配置chroot..."
mount -t proc proc "${CHROOT_DIR}/proc"
mount -t sysfs sysfs "${CHROOT_DIR}/sys"
mount -o bind /dev "${CHROOT_DIR}/dev"

cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"

# 复制OpenWRT镜像
cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img"

# 在chroot中运行配置
chroot "${CHROOT_DIR}" /setup.sh

# 卸载
umount "${CHROOT_DIR}/proc"
umount "${CHROOT_DIR}/sys"
umount "${CHROOT_DIR}/dev"

# 提取内核和initrd
echo "📋 提取内核和initrd..."
KERNEL=$(find "${CHROOT_DIR}/boot" -name "vmlinuz-*" -type f | head -1)
INITRD=$(find "${CHROOT_DIR}/boot" -name "initrd.img-*" -type f | head -1)

if [ -z "$KERNEL" ] || [ -z "$INITRD" ]; then
    echo "❌ 找不到内核或initrd"
    exit 1
fi

cp "$KERNEL" "${STAGING_DIR}/live/vmlinuz"
cp "$INITRD" "${STAGING_DIR}/live/initrd.img"

echo "✅ 内核: $(basename $KERNEL)"
echo "✅ initrd: $(basename $INITRD)"

# 创建squashfs
echo "📦 创建squashfs..."
mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp gzip \
    -e boot

# 创建文件标记（live-boot需要这个）
echo "live" > "${STAGING_DIR}/live/filesystem.squashfs.type"

# 创建ISOLINUX配置
echo "⚙️ 创建引导配置..."

# 复制引导文件
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "${STAGING_DIR}/isolinux/"
cp /usr/lib/syslinux/modules/bios/libcom32.c32 "${STAGING_DIR}/isolinux/"
cp /usr/lib/syslinux/modules/bios/libutil.c32 "${STAGING_DIR}/isolinux/"

# 创建isolinux.cfg
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
TIMEOUT 50
PROMPT 0
UI menu.c32

LABEL live
  MENU LABEL ^Install OpenWRT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components quiet
  TEXT HELP
  Install OpenWRT to hard disk
  ENDTEXT
ISOLINUX_CFG

# 创建GRUB配置（可选）
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet
    initrd /live/initrd.img
}
GRUB_CFG

# 创建live-boot需要的文件
touch "${STAGING_DIR}/live/filesystem.module"
echo "filesystem.squashfs" > "${STAGING_DIR}/live/filesystem.module"

# 构建ISO
echo "🔥 构建ISO镜像..."
xorriso -as mkisofs \
    -r -J \
    -V "OPENWRT_INSTALL" \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    "${STAGING_DIR}"

# 验证
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO构建成功！"
    echo ""
    echo "📊 信息："
    echo "  文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "  大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo ""
    echo "🎉 完成！"
    echo ""
    echo "使用方法："
    echo "  1. 刻录到U盘: dd if=${ISO_NAME} of=/dev/sdX bs=4M status=progress"
    echo "  2. 从U盘启动"
    echo "  3. 系统将自动启动安装程序"
else
    echo "❌ ISO构建失败"
    exit 1
fi
