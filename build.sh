#!/bin/bash
# build-iso-initramfs-fixed.sh - 修复initramfs挂载问题
set -e

echo "🚀 开始构建OpenWRT安装ISO..."
echo ""

# 基础配置
WORK_DIR="${HOME}/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/chroot"
STAGING_DIR="${WORK_DIR}/staging"
OUTPUT_DIR="/output"
OPENWRT_IMG="/mnt/ezopwrt.img"
ISO_NAME="openwrt-autoinstall.iso"

# 修复Debian buster源
echo "🔧 配置Debian buster源..."
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
deb http://archive.debian.org/debian buster-updates main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

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
    curl \
    gnupg \
    dialog \
    live-boot \
    live-boot-initramfs-tools

# 添加Debian存档密钥
echo "🔑 添加Debian存档密钥..."
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 04EE7237B7D453EC 648ACFD622F3D138 || true
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 0E98404D386FA1D9 6ED0E7B82643E131 || true

# 创建目录结构
echo "📁 创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/boot,boot/grub/x86_64-efi,isolinux,live}
mkdir -p "${OUTPUT_DIR}"

# 复制OpenWRT镜像
echo "📋 复制OpenWRT镜像..."
if [ -f "${OPENWRT_IMG}" ]; then
    mkdir -p "${CHROOT_DIR}"
    cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img" 2>/dev/null || true
    echo "✅ OpenWRT镜像已复制"
else
    echo "❌ 错误: 找不到OpenWRT镜像"
    exit 1
fi

# 引导Debian最小系统
echo "🔄 引导Debian最小系统..."
DEBIAN_MIRROR="http://archive.debian.org/debian"
if ! debootstrap --arch=amd64 --variant=minbase \
    buster "${CHROOT_DIR}" \
    "${DEBIAN_MIRROR}"; then
    echo "⚠️  第一次引导失败，尝试备用源..."
    DEBIAN_MIRROR="http://deb.debian.org/debian"
    debootstrap --arch=amd64 --variant=minbase \
        buster "${CHROOT_DIR}" \
        "${DEBIAN_MIRROR}" || {
        echo "❌ debootstrap失败"
        exit 1
    }
fi

# 创建chroot安装脚本（修复initramfs问题）
echo "📝 创建chroot配置脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# 在chroot内执行的安装脚本 - 修复initramfs问题
set -e

echo "🔧 开始配置chroot环境..."

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源
cat > /etc/apt/sources.list << 'APT_SOURCES'
deb http://archive.debian.org/debian/ buster main contrib non-free
deb http://archive.debian.org/debian/ buster-updates main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main contrib non-free
APT_SOURCES

# APT配置
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99custom << 'APT_CONF'
Acquire::Check-Valid-Until "false";
APT::Get::AllowUnauthenticated "true";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Retries "3";
APT_CONF

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 配置DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 更新包列表
echo "🔄 更新包列表..."
apt-get update

# === 关键：安装live-boot和必要组件 ===
echo "📦 安装live-boot和必要组件..."
apt-get install -y --no-install-recommends \
    live-boot \
    live-boot-initramfs-tools \
    live-tools \
    systemd \
    linux-image-amd64 \
    bash \
    coreutils \
    util-linux \
    parted \
    dosfstools \
    e2fsprogs \
    dialog \
    pv \
    curl \
    wget \
    kbd \
    console-setup

# === 配置live-boot ===
echo "🔧 配置live-boot..."

# 1. 创建live-boot配置文件
mkdir -p /lib/live/mount/medium
mkdir -p /etc/live/boot.conf

cat > /etc/live/boot.conf << 'LIVE_BOOT'
#!/bin/sh
# Live boot configuration

LIVE_MEDIA="cdrom"
LIVE_CONFIG="noautologin"
PERSISTENCE=""
LIVE_BOOT

# 2. 配置initramfs模块
cat > /etc/initramfs-tools/modules << 'INITRAMFS_MODULES'
# Live system modules
squashfs
overlay
loop
vfat
iso9660
udf
# Storage controllers
ahci
sd_mod
nvme
usb-storage
uhci_hcd
ehci_hcd
xhci_hcd
# Filesystems
ext4
ext3
ext2
vfat
ntfs
# Network (optional)
e1000
e1000e
r8169
# Framebuffer
fbcon
vesafb
vga16fb
INITRAMFS_MODULES

# 3. 配置initramfs hooks
cat > /etc/initramfs-tools/hooks/live << 'INITRAMFS_HOOKS'
#!/bin/sh
# Live system hook for initramfs

PREREQ=""

prereqs() {
    echo "$PREREQ"
}

case "$1" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

# Copy live-boot components
. /usr/share/initramfs-tools/hook-functions

# Copy necessary binaries
copy_exec /bin/bash
copy_exec /bin/sh
copy_exec /bin/mount
copy_exec /bin/umount
copy_exec /sbin/losetup
copy_exec /sbin/blkid
copy_exec /usr/bin/find
copy_exec /usr/bin/awk
copy_exec /usr/bin/grep
copy_exec /usr/bin/sed

# Copy live-boot scripts
mkdir -p "$DESTDIR"/lib/live
cp -r /usr/share/live/boot/* "$DESTDIR"/lib/live/ 2>/dev/null || true
cp -r /usr/share/live/* "$DESTDIR"/lib/live/ 2>/dev/null || true
INITRAMFS_HOOKS
chmod +x /etc/initramfs-tools/hooks/live

# 4. 创建自定义init脚本
cat > /usr/share/initramfs-tools/scripts/init-bottom/live << 'INIT_BOTTOM'
#!/bin/sh
# Live system init-bottom script

PREREQ=""

prereqs() {
    echo "$PREREQ"
}

case "$1" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

# Mount Live media
mkdir -p /run/live
mkdir -p /run/live/medium

# Try to find Live media
for DEVICE in /dev/sr0 /dev/cdrom /dev/disk/by-label/*; do
    if [ -b "$DEVICE" ]; then
        echo "Trying to mount $DEVICE as Live media..."
        if mount -t iso9660 -o ro "$DEVICE" /run/live/medium 2>/dev/null; then
            echo "Successfully mounted Live media: $DEVICE"
            break
        fi
    fi
done

# Check for squashfs
if [ -f /run/live/medium/live/filesystem.squashfs ]; then
    echo "Found Live system filesystem"
    
    # Create overlay
    mkdir -p /root /run/live/overlay
    mount -t tmpfs tmpfs /run/live/overlay
    
    # Mount squashfs
    mkdir -p /run/live/squashfs
    mount -t squashfs -o loop /run/live/medium/live/filesystem.squashfs /run/live/squashfs
    
    # Create overlay directories
    mkdir -p /run/live/overlay/upper /run/live/overlay/work
    
    # Mount overlay
    mount -t overlay overlay -o \
        lowerdir=/run/live/squashfs,\
        upperdir=/run/live/overlay/upper,\
        workdir=/run/live/overlay/work \
        /root
        
    if [ $? -eq 0 ]; then
        echo "Successfully created overlay filesystem"
        # Move mounts to new root
        mkdir -p /root/run/live
        mount --move /run/live/medium /root/run/live/medium
        mount --move /run/live/overlay /root/run/live/overlay
        mount --move /run/live/squashfs /root/run/live/squashfs
    else
        echo "Failed to create overlay filesystem"
    fi
else
    echo "No Live system found on media"
fi
INIT_BOTTOM
chmod +x /usr/share/initramfs-tools/scripts/init-bottom/live

# === 配置系统自动启动 ===
echo "🔧 配置自动启动..."

# 1. 设置root密码为空
echo "root::0:0:root:/root:/bin/bash" > /etc/shadow
echo "root:x:0:0:root:/root:/bin/bash" > /etc/passwd

# 2. 创建自动启动脚本
cat > /etc/rc.local << 'RCLOCAL'
#!/bin/bash
# OpenWRT安装器自动启动脚本

# 等待系统完全启动
sleep 3

# 只在tty1上运行
if [ "$(tty)" = "/dev/tty1" ]; then
    # 清屏
    clear
    
    # 显示欢迎信息
    echo ""
    echo "========================================"
    echo "      OpenWRT 自动安装系统"
    echo "========================================"
    echo ""
    echo "系统启动完成，正在准备安装环境..."
    echo ""
    
    # 启动安装程序
    exec /opt/install-openwrt.sh
fi

exit 0
RCLOCAL
chmod +x /etc/rc.local

# 3. 配置agetty自动登录（备用）
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
Type=idle
GETTY_OVERRIDE

# 4. 创建OpenWRT安装脚本
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT自动安装脚本

# 设置环境
export TERM=linux
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# 清屏
clear

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║           OpenWRT 一键安装程序                   ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "欢迎使用OpenWRT安装系统"
echo ""

# 检查OpenWRT镜像
if [ ! -f "/openwrt.img" ]; then
    echo "❌ 错误: 未找到OpenWRT镜像"
    echo "镜像文件应该位于: /openwrt.img"
    echo ""
    echo "按Enter键进入Shell..."
    read dummy
    exec /bin/bash
fi

IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}')
echo "✅ 找到OpenWRT镜像: $IMG_SIZE"
echo ""

# 显示磁盘信息
echo "扫描可用磁盘..."
echo "========================================"

# 获取磁盘列表
if command -v lsblk >/dev/null 2>&1; then
    lsblk -d -n -o NAME,SIZE,MODEL,TYPE | grep -v loop
else
    fdisk -l 2>/dev/null | grep '^Disk /dev/' | head -10
fi

echo "========================================"
echo ""

# 获取磁盘名称
DISK_NAMES=$(lsblk -d -n -o NAME 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || \
             fdisk -l 2>/dev/null | grep '^Disk /dev/' | awk -F'[/:]' '{print $3}')

echo "可用磁盘:"
for disk in $DISK_NAMES; do
    echo "  /dev/$disk"
done
echo ""

# 选择目标磁盘
while true; do
    read -p "请输入目标磁盘名称 (如: sda): " TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo "请输入磁盘名称"
        continue
    fi
    
    # 检查磁盘是否存在
    if echo " $DISK_NAMES " | grep -q " $TARGET_DISK "; then
        echo ""
        echo "✅ 已选择: /dev/$TARGET_DISK"
        break
    else
        echo "❌ 磁盘 /dev/$TARGET_DISK 不存在"
    fi
done

# 确认安装
echo ""
echo "⚠️  ⚠️  ⚠️  重要警告  ⚠️  ⚠️  ⚠️"
echo "这将完全擦除 /dev/$TARGET_DISK 上的所有数据！"
echo ""
read -p "确认安装? (输入 INSTALL 确认): " CONFIRM

if [ "$CONFIRM" != "INSTALL" ]; then
    echo "安装已取消"
    echo ""
    echo "按Enter键重新开始..."
    read dummy
    exec /opt/install-openwrt.sh
fi

# 开始安装
clear
echo ""
echo "🚀 开始安装 OpenWRT"
echo "目标磁盘: /dev/$TARGET_DISK"
echo ""

# 显示进度
echo "正在准备磁盘..."
sleep 1

echo "正在写入OpenWRT镜像..."
echo ""

# 获取镜像大小
IMG_BYTES=$(stat -c%s /openwrt.img)
IMG_MB=$((IMG_BYTES / 1024 / 1024))

echo "镜像信息:"
echo "  大小: ${IMG_MB} MB"
echo "  目标: /dev/$TARGET_DISK"
echo ""

# 使用dd写入
echo "正在写入，请勿中断..."
echo ""

if command -v pv >/dev/null 2>&1; then
    # 使用pv显示进度
    pv -pet /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M status=none
else
    # 使用dd并显示简单进度
    echo "开始写入..."
    dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M status=progress 2>&1 || \
    dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M 2>&1 | tail -1
fi

# 同步磁盘
sync

echo ""
echo "✅ OpenWRT写入完成！"
echo ""

# 验证写入
echo "验证安装..."
sleep 2

echo ""
echo "🎉 OpenWRT安装成功！"
echo ""
echo "安装信息:"
echo "  目标磁盘: /dev/$TARGET_DISK"
echo "  镜像大小: $IMG_SIZE"
echo "  安装时间: $(date)"
echo ""

# 重启
echo "系统将在10秒后自动重启..."
echo "按 Ctrl+C 取消重启"
echo ""

for i in {10..1}; do
    echo -ne "重启倒计时: $i 秒\r"
    if read -t 1 -n 1; then
        echo ""
        echo "重启已取消"
        echo ""
        echo "手动重启: reboot"
        echo "重新安装: /opt/install-openwrt.sh"
        echo ""
        exec /bin/bash
    fi
done

echo ""
echo "正在重启..."
sleep 2
reboot
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 5. 创建简单的bash配置
cat > /root/.bashrc << 'BASHRC'
# ~/.bashrc

# 如果不是交互式shell，直接退出
case $- in
    *i*) ;;
      *) return;;
esac

PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# 显示帮助信息
if [ "$(tty)" != "/dev/tty1" ]; then
    echo ""
    echo "OpenWRT安装系统"
    echo "命令: /opt/install-openwrt.sh"
    echo ""
fi
BASHRC

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# === 关键：生成initramfs ===
echo "🔄 生成initramfs..."
update-initramfs -c -k all

if [ $? -ne 0 ]; then
    echo "⚠️  标准initramfs生成失败，尝试手动生成..."
    mkinitramfs -o /boot/initrd.img
fi

echo "✅ chroot配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/install-chroot.sh"

# 挂载必要的文件系统到chroot
echo "🔗 挂载文件系统到chroot..."
for fs in proc dev sys; do
    mount -t $fs $fs "${CHROOT_DIR}/$fs" 2>/dev/null || \
    mount --bind /$fs "${CHROOT_DIR}/$fs" 2>/dev/null || true
done

# 复制resolv.conf到chroot
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true

# 在chroot内执行安装脚本
echo "⚙️  在chroot内执行安装..."
if chroot "${CHROOT_DIR}" /bin/bash -c "/install-chroot.sh 2>&1 | tee /install.log"; then
    echo "✅ chroot安装完成"
else
    echo "⚠️  chroot安装返回错误，检查日志..."
    if [ -f "${CHROOT_DIR}/install.log" ]; then
        echo "安装日志:"
        tail -20 "${CHROOT_DIR}/install.log"
    fi
fi

# 卸载chroot文件系统
echo "🔗 卸载chroot文件系统..."
for fs in proc dev sys; do
    umount "${CHROOT_DIR}/$fs" 2>/dev/null || true
done

# 检查内核和initramfs
echo "🔍 检查内核和initramfs..."
KERNEL_FILE=$(find "${CHROOT_DIR}/boot" -name "vmlinuz*" 2>/dev/null | head -1)
INITRD_FILE=$(find "${CHROOT_DIR}/boot" -name "initrd*" 2>/dev/null | head -1)

if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
    echo "✅ 找到内核: $KERNEL_FILE"
else
    echo "❌ 未找到内核"
    exit 1
fi

if [ -n "$INITRD_FILE" ] && [ -f "$INITRD_FILE" ]; then
    echo "✅ 找到initrd: $INITRD_FILE"
else
    echo "❌ 未找到initrd"
    exit 1
fi

# 压缩chroot为squashfs
echo "📦 创建squashfs文件系统..."
if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp gzip \
    -b 1M \
    -noappend \
    -wildcards \
    -e "proc/*" "sys/*" "dev/*" "run/*" "tmp/*"; then
    echo "✅ squashfs创建成功"
    echo "大小: $(ls -lh "${STAGING_DIR}/live/filesystem.squashfs" | awk '{print $5}')"
else
    echo "❌ squashfs创建失败"
    exit 1
fi

# 复制内核和initrd
echo "📋 复制内核和initrd..."
cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"
echo "✅ 内核和initrd复制完成"

# 创建live文件夹结构（重要！）
echo "🔧 创建live文件夹结构..."
mkdir -p "${STAGING_DIR}/live"
echo "filesystem.squashfs" > "${STAGING_DIR}/live/filesystem.squashfs-"

# 创建引导配置文件（使用正确的live-boot参数）
echo "⚙️  创建引导配置..."
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE OpenWRT Auto Installer
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std

LABEL live
  MENU LABEL ^Install OpenWRT (Normal)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components toram=filesystem.squashfs quiet splash
  TEXT HELP
  Normal installation mode
  ENDTEXT

LABEL live_nomodeset
  MENU LABEL Install OpenWRT (^Safe Graphics)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components nomodeset quiet
  TEXT HELP
  Safe graphics mode for compatibility
  ENDTEXT

LABEL live_toram
  MENU LABEL Install OpenWRT (^Copy to RAM)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components toram quiet
  TEXT HELP
  Copy system to RAM for faster operation
  ENDTEXT

LABEL debug
  MENU LABEL ^Debug Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components debug
  TEXT HELP
  Debug mode with verbose output
  ENDTEXT

LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components single
  TEXT HELP
  Drop to rescue shell
  ENDTEXT
ISOLINUX_CFG

# 复制引导文件
echo "📋 复制引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/*.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 创建memtest文件（可选）
touch "${STAGING_DIR}/live/memtest"

# 创建Grub配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (Normal)" {
    linux /live/vmlinuz boot=live components toram=filesystem.squashfs quiet splash
    initrd /live/initrd
}

menuentry "Install OpenWRT (Safe Graphics)" {
    linux /live/vmlinuz boot=live components nomodeset quiet
    initrd /live/initrd
}

menuentry "Install OpenWRT (Copy to RAM)" {
    linux /live/vmlinuz boot=live components toram quiet
    initrd /live/initrd
}

menuentry "Debug Mode" {
    linux /live/vmlinuz boot=live components debug
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live components single
    initrd /live/initrd
}
GRUB_CFG

# 构建ISO（确保卷标正确）
echo "🔥 构建ISO镜像..."
xorriso -as mkisofs \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -volid "OPENWRT_LIVE" \
    -appid "OpenWRT Installer" \
    -publisher "https://github.com/openwrt" \
    "${STAGING_DIR}"

# 验证ISO
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "  大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo "  卷标: OPENWRT_LIVE"
    echo ""
    echo "🎉 构建完成！"
    echo ""
    echo "重要提示："
    echo "  1. 使用 'Install OpenWRT (Normal)' 启动"
    echo "  2. 系统将自动登录并启动安装程序"
    echo "  3. 如果遇到挂载问题，尝试 'Copy to RAM' 选项"
    echo "  4. 如果黑屏，使用 'Safe Graphics' 选项"
    echo ""
else
    echo "❌ ISO构建失败"
    exit 1
fi
