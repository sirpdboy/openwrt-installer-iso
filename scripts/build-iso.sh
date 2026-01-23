#!/bin/bash
# build-iso.sh - 基于Debian Live构建OpenWRT安装ISO
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

# 修复Debian buster源（因为buster已EOL）
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

# 引导Debian最小系统
echo "🔄 引导Debian最小系统..."
debootstrap --arch=amd64 --variant=minbase \
    buster "${CHROOT_DIR}" \
    http://archive.debian.org/debian/

# 复制OpenWRT镜像到chroot
echo "📋 复制OpenWRT镜像..."
if [ -f "${OPENWRT_IMG}" ]; then
    cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img"
    echo "✅ OpenWRT镜像已复制: $(ls -lh "${CHROOT_DIR}/openwrt.img")"
else
    echo "❌ 错误: 找不到OpenWRT镜像: ${OPENWRT_IMG}"
    exit 1
fi

# 创建chroot安装脚本
echo "📝 创建chroot配置脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# 在chroot内执行的安装脚本
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
    iproute2 \
    net-tools \
    openssh-client \
    ca-certificates \
    sudo \
    dialog \
    whiptail

# 清理APT缓存
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 配置网络
cat > /etc/network/interfaces << 'NETWORK_EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NETWORK_EOF

# 允许root登录（Live环境需要）
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "root:1234" | chpasswd

# 创建OpenWRT安装脚本
echo "📝 创建OpenWRT安装脚本..."
cat > /usr/local/bin/install-openwrt << 'INSTALL_EOF'
#!/bin/bash
# OpenWRT安装脚本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
echo_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 显示标题
clear
echo "================================================"
echo "       OpenWRT 安装程序"
echo "================================================"
echo ""

# 检查权限
if [ "$(id -u)" -ne 0 ]; then
    echo_error "需要root权限运行此脚本"
    exit 1
fi

# 查找OpenWRT镜像
OPENWRT_IMG="/openwrt.img"
if [ ! -f "$OPENWRT_IMG" ]; then
    echo_error "找不到OpenWRT镜像: $OPENWRT_IMG"
    exit 1
fi

echo_info "找到OpenWRT镜像: $(ls -lh "$OPENWRT_IMG")"

# 显示磁盘列表
echo_info "检测可用磁盘..."
echo ""
echo "可用磁盘列表:"
echo "--------------------------------"

DISKS=()
while IFS= read -r line; do
    if [[ "$line" =~ ^/dev/[sv]d[a-z] ]]; then
        disk=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $4}')
        model=$(echo "$line" | awk '{print $3}')
        DISKS+=("$disk")
        printf "  %-10s %-10s %s\n" "$disk" "$size" "$model"
    fi
done < <(lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "NAME")

echo "--------------------------------"
echo ""

if [ ${#DISKS[@]} -eq 0 ]; then
    echo_error "未找到可用磁盘"
    exit 1
fi

# 选择磁盘
while true; do
    read -p "请输入要安装OpenWRT的磁盘 (例如: /dev/sda): " TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo_warning "请输入磁盘设备路径"
        continue
    fi
    
    if [[ ! "$TARGET_DISK" =~ ^/dev/[sv]d[a-z]$ ]]; then
        echo_warning "无效的磁盘设备路径。请使用类似 /dev/sda 的格式"
        continue
    fi
    
    if [ ! -b "$TARGET_DISK" ]; then
        echo_warning "磁盘 $TARGET_DISK 不存在"
        continue
    fi
    
    # 确认选择
    DISK_INFO=$(lsblk -d -o SIZE,MODEL "$TARGET_DISK" 2>/dev/null | tail -1)
    if [ -z "$DISK_INFO" ]; then
        echo_warning "无法获取磁盘信息"
        continue
    fi
    
    echo ""
    echo_warning "警告：这将完全擦除磁盘 $TARGET_DISK 上的所有数据！"
    echo "磁盘信息: $DISK_INFO"
    echo ""
    
    read -p "确认安装到 $TARGET_DISK ？输入 'y' 确认: " CONFIRM
    
    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
        break
    else
        echo "取消选择，请重新选择磁盘"
        echo ""
    fi
done

# 最终确认
echo ""
echo "================================================"
echo_warning "最终确认"
echo "================================================"
echo "目标磁盘: $TARGET_DISK"
echo "源镜像: $OPENWRT_IMG"
echo ""
echo "此操作将："
echo "1. 擦除 $TARGET_DISK 上的所有分区和数据"
echo "2. 写入OpenWRT系统镜像"
echo "3. 磁盘将无法恢复原有数据"
echo ""

read -p "输入 'yes' 确认开始安装: " FINAL_CONFIRM

if [ "$FINAL_CONFIRM" != "yes" ]; then
    echo_error "安装已取消"
    exit 0
fi

# 开始安装
echo ""
echo_info "开始安装OpenWRT到 $TARGET_DISK ..."
echo ""

# 卸载所有相关分区
for partition in $(lsblk -lno NAME "$TARGET_DISK" | grep -v "^$(basename "$TARGET_DISK")$"); do
    umount "/dev/$partition" 2>/dev/null || true
done

# 使用dd写入镜像
echo_info "正在写入镜像，这可能需要几分钟..."
if dd if="$OPENWRT_IMG" of="$TARGET_DISK" bs=4M status=progress; then
    sync
    echo ""
    echo_success "✅ OpenWRT安装完成！"
    echo ""
    echo_info "请执行以下操作："
    echo "1. 移除安装介质"
    echo "2. 设置从 $TARGET_DISK 启动"
    echo "3. 重启系统"
    echo ""
    read -p "按Enter键重启系统，或按Ctrl+C取消... "
    
    # 重启
    reboot
else
    echo_error "❌ 镜像写入失败"
    exit 1
fi
INSTALL_EOF

chmod +x /usr/local/bin/install-openwrt

# 创建自动启动脚本
cat > /etc/init.d/openwrt-installer << 'AUTORUN_EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          openwrt-installer
# Required-Start:    $local_fs $network
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Description:       OpenWRT Installer Auto-run
### END INIT INFO

case "$1" in
    start)
        # 检查是否在live环境中
        if grep -q "boot=live" /proc/cmdline; then
            echo "Starting OpenWRT installer..."
            sleep 3
            /usr/local/bin/install-openwrt
        fi
        ;;
    stop)
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac

exit 0
AUTORUN_EOF

chmod +x /etc/init.d/openwrt-installer
update-rc.d openwrt-installer defaults

# 创建桌面快捷方式（如果使用图形界面）
mkdir -p /usr/share/applications
cat > /usr/share/applications/openwrt-installer.desktop << 'DESKTOP_EOF'
[Desktop Entry]
Name=OpenWRT Installer
Comment=Install OpenWRT to disk
Exec=/usr/local/bin/install-openwrt
Icon=system-installer
Terminal=true
Type=Application
Categories=System;
DESKTOP_EOF

# 清理machine-id（避免重复）
rm -f /etc/machine-id

echo "✅ chroot配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/install-chroot.sh"

# 挂载必要的文件系统到chroot
echo "🔗 挂载文件系统到chroot..."
mount -t proc none "${CHROOT_DIR}/proc"
mount -o bind /dev "${CHROOT_DIR}/dev"
mount -o bind /sys "${CHROOT_DIR}/sys"

# 在chroot内执行安装脚本
echo "⚙️  在chroot内执行安装..."
chroot "${CHROOT_DIR}" /install-chroot.sh

# 卸载chroot文件系统
echo "🔗 卸载chroot文件系统..."
umount "${CHROOT_DIR}/proc"
umount "${CHROOT_DIR}/dev"
umount "${CHROOT_DIR}/sys"

# 清理chroot内的安装脚本
rm -f "${CHROOT_DIR}/install-chroot.sh"

# 压缩chroot为squashfs
echo "📦 创建squashfs文件系统..."
mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp xz \
    -b 1M \
    -noappend \
    -no-recovery \
    -always-use-fragments \
    -no-duplicates \
    -e boot

# 复制内核和initrd
echo "📋 复制内核和initrd..."
cp -v "${CHROOT_DIR}/boot"/vmlinuz-* \
    "${STAGING_DIR}/live/vmlinuz" 2>/dev/null || true
cp -v "${CHROOT_DIR}/boot"/initrd.img-* \
    "${STAGING_DIR}/live/initrd" 2>/dev/null || true

# 如果没找到，使用通用名称
if [ ! -f "${STAGING_DIR}/live/vmlinuz" ]; then
    cp "$(ls ${CHROOT_DIR}/boot/vmlinuz* | head -1)" \
        "${STAGING_DIR}/live/vmlinuz"
fi
if [ ! -f "${STAGING_DIR}/live/initrd" ]; then
    cp "$(ls ${CHROOT_DIR}/boot/initrd.img* | head -1)" \
        "${STAGING_DIR}/live/initrd"
fi

# 创建引导配置文件
echo "⚙️  创建引导配置..."

# ISOLINUX配置（BIOS引导）
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
UI vesamenu.c32

MENU TITLE OpenWRT Installer
DEFAULT live
TIMEOUT 100
PROMPT 0
MENU RESOLUTION 800 600

MENU COLOR border       30;44   #00000000 #00000000 none
MENU COLOR title        1;36;44 #ffffffff #00000000 none
MENU COLOR unsel        37;44   #ffffffff #00000000 none
MENU COLOR hotkey       1;37;44 #ffffffff #00000000 none
MENU COLOR sel          7;37;40 #ff000000 #ffffffff none
MENU COLOR hotsel       1;7;37;40 #ff000000 #ffffffff none

LABEL live
  MENU LABEL ^Install OpenWRT (Default)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet splash --
  
LABEL live_nomodeset
  MENU LABEL Install OpenWRT (^No Modeset)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live nomodeset quiet splash --
  
LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components --
  
LABEL memtest
  MENU LABEL ^Memory Test
  KERNEL /isolinux/memtest
  
LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
ISOLINUX_CFG

# GRUB配置（UEFI引导）
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660
insmod all_video
insmod font

set default="0"
set timeout=10

menuentry "Install OpenWRT" {
    search --no-floppy --set=root --label OPENWRT_INSTALL
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd
}

menuentry "Install OpenWRT (no modeset)" {
    search --no-floppy --set=root --label OPENWRT_INSTALL
    linux /live/vmlinuz boot=live nomodeset quiet splash
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    search --no-floppy --set=root --label OPENWRT_INSTALL
    linux /live/vmlinuz boot=live components
    initrd /live/initrd
}

menuentry "Reboot" {
    reboot
}
GRUB_CFG

# 复制引导文件
echo "📋 复制引导文件..."
cp -v /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/"
cp -v /usr/lib/syslinux/modules/bios/* "${STAGING_DIR}/isolinux/" 2>/dev/null || true
cp -v -r /usr/lib/grub/x86_64-efi/* "${STAGING_DIR}/boot/grub/x86_64-efi/" 2>/dev/null || true

# 生成UEFI引导文件
echo "🔧 生成UEFI引导文件..."
cat > "${WORK_DIR}/tmp/grub-standalone.cfg" << 'GRUB_STANDALONE'
if ! [ -d "$cmdpath" ]; then
    if regexp --set=1:isodevice '^(\([^)]+\))\/?[Ee][Ff][Ii]\/[Bb][Oo][Oo][Tt]\/?$' "$cmdpath"; then
        cmdpath="${isodevice}/EFI/BOOT"
    fi
fi
configfile "${cmdpath}/grub.cfg"
GRUB_STANDALONE

grub-mkstandalone --format=x86_64-efi \
    --output="${WORK_DIR}/tmp/bootx64.efi" \
    --locales="" \
    --fonts="" \
    "boot/grub/grub.cfg=${WORK_DIR}/tmp/grub-standalone.cfg"

# 创建EFI引导镜像
echo "🔧 创建EFI引导镜像..."
cd "${STAGING_DIR}/EFI/boot"
SIZE=$(expr $(stat --format=%s "${WORK_DIR}/tmp/bootx64.efi") + 65536)
dd if=/dev/zero of=efiboot.img bs=$SIZE count=1
/sbin/mkfs.vfat efiboot.img
mmd -i efiboot.img efi efi/boot
mcopy -vi efiboot.img "${WORK_DIR}/tmp/bootx64.efi" ::efi/boot/
cd -

# 构建ISO
echo "🔥 构建ISO镜像..."
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-boot \
        isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-catalog isolinux/isolinux.cat \
    -eltorito-alt-boot \
        -e /EFI/boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
    -append_partition 2 0xef "${STAGING_DIR}/EFI/boot/efiboot.img" \
    -output "${OUTPUT_DIR}/${ISO_NAME}" \
    "${STAGING_DIR}"

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
    echo "引导信息:"
    xorriso -indev "${OUTPUT_DIR}/${ISO_NAME}" -toc 2>&1 | grep -E "(El-Torito|bootable)" || true
    echo ""
    echo "🎉 构建完成！"
    echo ""
    echo "使用方法:"
    echo "1. 写入USB: dd if='${OUTPUT_DIR}/${ISO_NAME}' of=/dev/sdX bs=4M status=progress"
    echo "2. 从USB启动计算机"
    echo "3. 选择 'Install OpenWRT'"
    echo "4. 系统将自动启动并运行安装程序"
else
    echo "❌ ISO构建失败"
    exit 1
fi

# 清理工作目录（可选）
echo "🧹 清理工作目录..."
# rm -rf "${WORK_DIR}"  # 可选，调试时可保留

echo ""
echo "🚀 所有步骤完成！"
