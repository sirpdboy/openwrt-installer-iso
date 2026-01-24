#!/bin/bash
# build-iso-kernel-fixed.sh - 修复内核恐慌问题
set -e

echo "🚀 开始构建OpenWRT安装ISO（修复内核问题）..."
echo ""

# 基础配置
WORK_DIR="${HOME}/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/chroot"
STAGING_DIR="${WORK_DIR}/staging"
OUTPUT_DIR="/output"
OPENWRT_IMG="/mnt/ezopwrt.img"
ISO_NAME="openwrt-installer.iso"

# 使用更新更稳定的Ubuntu源（替代Debian buster）
echo "🔧 配置Ubuntu 20.04源..."
cat > /etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu focal main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu focal-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu focal-security main restricted universe multiverse
EOF

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
    parted \
    wget \
    curl \
    gnupg \
    dialog \
    live-boot \
    live-boot-initramfs-tools \
    linux-image-generic

# 创建目录结构
echo "📁 创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{boot/grub,isolinux,live}
mkdir -p "${OUTPUT_DIR}"

# 复制OpenWRT镜像
echo "📋 复制OpenWRT镜像..."
if [ -f "${OPENWRT_IMG}" ]; then
    mkdir -p "${CHROOT_DIR}"
    cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img"
    echo "✅ OpenWRT镜像已复制"
else
    echo "❌ 错误: 找不到OpenWRT镜像"
    exit 1
fi

# 引导Ubuntu最小系统（使用更稳定的版本）
echo "🔄 引导Ubuntu最小系统..."
debootstrap --arch=amd64 --variant=minbase \
    focal "${CHROOT_DIR}" \
    http://archive.ubuntu.com/ubuntu || {
    echo "尝试备用源..."
    debootstrap --arch=amd64 --variant=minbase \
        focal "${CHROOT_DIR}" \
        http://mirrors.aliyun.com/ubuntu || {
        echo "❌ debootstrap失败"
        exit 1
    }
}

# 创建chroot安装脚本（关键：修复内核配置）
echo "📝 创建chroot配置脚本..."
cat > "${CHROOT_DIR}/setup.sh" << 'CHROOT_EOF'
#!/bin/bash
set -e

echo "🔧 开始配置chroot环境..."

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源（Ubuntu 20.04）
cat > /etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu focal main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu focal-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu focal-security main restricted universe multiverse
EOF

# 配置DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 更新包列表
echo "🔄 更新包列表..."
apt-get update

# === 关键：安装稳定的内核版本 ===
echo "📦 安装稳定内核版本..."
# 先安装基础工具
apt-get install -y --no-install-recommends \
    linux-image-generic \
    linux-modules-extra-generic \
    live-boot \
    live-boot-initramfs-tools \
    systemd-sysv \
    bash \
    coreutils \
    util-linux \
    parted \
    dosfstools \
    dialog \
    wget \
    curl \
    kbd \
    console-setup

# 查看安装的内核版本
echo "安装的内核:"
ls -la /boot/vmlinuz* || echo "未找到内核"
dpkg -l | grep linux-image || echo "未安装内核包"

# 设置root密码为空
echo "root::0:0:root:/root:/bin/bash" > /etc/shadow

# 配置控制台
cat > /etc/default/console-setup << 'CONSOLE_SETUP'
# CONFIGURATION FILE FOR SETUPCON
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="guess"
FONTFACE="Fixed"
FONTSIZE="8x16"
VIDEOMODE=
CONSOLE_SETUP

# 配置initramfs模块（关键修复）
echo "🔧 配置initramfs模块..."
cat > /etc/initramfs-tools/modules << 'INITRAMFS_MODULES'
# 基础模块
loop
squashfs
overlay
# 文件系统
vfat
iso9660
udf
ext4
ext3
ext2
# 存储控制器
ahci
sd_mod
nvme
usb-storage
uhci_hcd
ehci_hcd
xhci_hcd
# 帧缓冲（可选）
fbcon
vesafb
vga16fb
# 网络（可选）
e1000
e1000e
r8169
INITRAMFS_MODULES

# 配置initramfs blacklist（排除可能冲突的模块）
echo "🔧 配置模块黑名单..."
cat > /etc/modprobe.d/blacklist-live.conf << 'BLACKLIST'
# 黑名单可能导致问题的模块
blacklist nouveau
blacklist nvidia
blacklist radeon
blacklist amdgpu
blacklist i915
BLACKLIST

# 创建安装脚本
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT安装脚本

# 等待系统完全启动
sleep 3

# 清屏
clear

echo ""
echo "========================================"
echo "      OpenWRT 一键安装程序"
echo "========================================"
echo ""
echo "系统启动完成，正在初始化..."
echo ""

# 检查OpenWRT镜像
if [ ! -f "/openwrt.img" ]; then
    echo "❌ 错误: 未找到OpenWRT镜像"
    echo "按Enter进入Shell..."
    read dummy
    exec /bin/bash
fi

IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}')
echo "✅ 找到OpenWRT镜像: $IMG_SIZE"
echo ""

# 显示磁盘信息
echo "扫描可用磁盘..."
echo "========================================"

# 使用可靠的方法获取磁盘信息
echo "磁盘列表:"
if command -v lsblk >/dev/null 2>&1; then
    lsblk -d -n -o NAME,SIZE,MODEL,TYPE 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || true
else
    fdisk -l 2>/dev/null | grep '^Disk /dev/' | head -10 || true
fi

echo "========================================"
echo ""

# 获取磁盘名称
DISK_NAMES=""
if command -v lsblk >/dev/null 2>&1; then
    DISK_NAMES=$(lsblk -d -n -o NAME 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || echo "")
else
    DISK_NAMES=$(fdisk -l 2>/dev/null | grep '^Disk /dev/' | awk -F'[/:]' '{print $3}' | head -10 || echo "")
fi

if [ -z "$DISK_NAMES" ]; then
    echo "未找到可用磁盘"
    echo "按Enter重新扫描..."
    read dummy
    exec /opt/install-openwrt.sh
fi

echo "可用磁盘:"
for disk in $DISK_NAMES; do
    echo "  /dev/$disk"
done
echo ""

# 选择目标磁盘
while true; do
    read -p "请输入目标磁盘 (如: sda): " TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo "请输入磁盘名称"
        continue
    fi
    
    # 检查磁盘是否存在
    if echo " $DISK_NAMES " | grep -q " $TARGET_DISK "; then
        echo ""
        echo "✅ 您选择了: /dev/$TARGET_DISK"
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
read -p "确认安装? (输入 YES 确认): " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "安装取消"
    echo ""
    echo "按Enter重新开始..."
    read dummy
    exec /opt/install-openwrt.sh
fi

# 开始安装
clear
echo ""
echo "🚀 开始安装 OpenWRT"
echo "目标磁盘: /dev/$TARGET_DISK"
echo ""

echo "正在准备磁盘..."
sleep 2

echo "正在写入OpenWRT镜像..."
echo ""

# 获取镜像大小
IMG_BYTES=$(stat -c%s /openwrt.img)
IMG_MB=$((IMG_BYTES / 1024 / 1024))

echo "镜像信息:"
echo "  大小: ${IMG_MB} MB"
echo "  目标: /dev/$TARGET_DISK"
echo ""
echo "正在写入，请勿中断..."
echo ""

# 使用dd写入（带进度）
if command -v pv >/dev/null 2>&1; then
    # 使用pv显示进度
    pv -pet /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M status=none
else
    # 使用dd并显示简单进度
    echo "开始写入..."
    dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M status=progress 2>&1 || \
    dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M 2>&1 | tail -2
fi

# 同步磁盘
sync

echo ""
echo "✅ OpenWRT写入完成！"
echo ""

echo "安装完成！"
echo "系统将在10秒后重启..."
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
reboot
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 配置自动启动（使用简单可靠的方法）
echo "🔧 配置自动启动..."
cat > /etc/systemd/system/openwrt-installer.service << 'SERVICE'
[Unit]
Description=OpenWRT Installer
After=multi-user.target

[Service]
Type=idle
ExecStart=/opt/install-openwrt.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1

[Install]
WantedBy=multi-user.target
SERVICE

# 启用服务但禁用自动启动，让用户手动选择
# systemctl enable openwrt-installer.service

# 创建手动启动脚本
cat > /usr/local/bin/start-install << 'START_INSTALL'
#!/bin/bash
echo "正在启动OpenWRT安装程序..."
sleep 2
exec /opt/install-openwrt.sh
START_INSTALL
chmod +x /usr/local/bin/start-install

# 创建登录提示
cat > /etc/motd << 'MOTD'

╔══════════════════════════════════════════════════╗
║            OpenWRT 安装系统                      ║
╚══════════════════════════════════════════════════╝

欢迎！要开始安装OpenWRT，请运行:

  start-install

或者直接运行:
  /opt/install-openwrt.sh

查看磁盘信息:
  lsblk  或  fdisk -l

MOTD

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# === 关键：生成正确的initramfs ===
echo "🔄 生成initramfs（修复内核恐慌）..."
# 强制重新生成initramfs
rm -f /boot/initrd.img*
rm -f /boot/initramfs*

# 使用特定参数生成initramfs
update-initramfs -c -k all -v

# 检查是否生成成功
if [ ! -f /boot/initrd.img ] && [ ! -f /boot/initramfs.img ]; then
    echo "⚠️  标准initramfs生成失败，尝试手动生成..."
    mkinitramfs -o /boot/initrd.img 2>/dev/null || {
        echo "创建简单initramfs..."
        # 创建最小initramfs
        create_minimal_initramfs /boot/initrd.img
    }
fi

echo "✅ chroot配置完成"

# 最小initramfs创建函数
create_minimal_initramfs() {
    local output="$1"
    local initrd_dir="/tmp/minimal-initrd-$$"
    
    mkdir -p "$initrd_dir"
    
    cat > "$initrd_dir/init" << 'MINIMAL_INIT'
#!/bin/sh
# 最小init脚本

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "OpenWRT Minimal Installer"
echo ""
echo "正在启动完整系统..."
sleep 2

# 直接启动bash（绕过systemd）
exec /bin/bash
MINIMAL_INIT
    chmod +x "$initrd_dir/init"
    
    # 复制busybox（如果可用）
    if which busybox >/dev/null 2>&1; then
        cp $(which busybox) "$initrd_dir/busybox"
        chmod +x "$initrd_dir/busybox"
        for app in sh mount umount echo cat ls; do
            ln -s busybox "$initrd_dir/$app" 2>/dev/null || true
        done
    fi
    
    (cd "$initrd_dir" && find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$output")
    rm -rf "$initrd_dir"
    echo "✅ 最小initramfs创建完成"
}
CHROOT_EOF

chmod +x "${CHROOT_DIR}/setup.sh"

# 挂载文件系统
echo "🔗 挂载文件系统到chroot..."
for fs in proc dev sys; do
    mount --bind /$fs "${CHROOT_DIR}/$fs"
done

# 复制resolv.conf
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true

# 执行chroot配置
echo "⚙️  在chroot内执行配置..."
if chroot "${CHROOT_DIR}" /bin/bash /setup.sh 2>&1 | tee /tmp/chroot.log; then
    echo "✅ chroot配置完成"
else
    echo "⚠️  chroot配置返回错误"
    echo "最后10行日志:"
    tail -10 /tmp/chroot.log
fi

# 卸载文件系统
for fs in proc dev sys; do
    umount "${CHROOT_DIR}/$fs" 2>/dev/null || true
done

# 检查内核和initramfs
echo "🔍 检查内核和initramfs..."
KERNEL_FILE=$(find "${CHROOT_DIR}/boot" -name "vmlinuz*" 2>/dev/null | head -1)
INITRD_FILE=$(find "${CHROOT_DIR}/boot" -name "initrd*" 2>/dev/null | head -1)

if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
    echo "✅ 找到内核: $(basename "$KERNEL_FILE")"
    echo "  大小: $(ls -lh "$KERNEL_FILE" | awk '{print $5}')"
else
    echo "❌ 未找到内核，使用宿主内核"
    if [ -f "/boot/vmlinuz" ]; then
        mkdir -p "${CHROOT_DIR}/boot"
        cp "/boot/vmlinuz" "${CHROOT_DIR}/boot/vmlinuz-host"
        KERNEL_FILE="${CHROOT_DIR}/boot/vmlinuz-host"
    else
        echo "❌ 没有可用的内核"
        exit 1
    fi
fi

if [ -n "$INITRD_FILE" ] && [ -f "$INITRD_FILE" ]; then
    echo "✅ 找到initrd: $(basename "$INITRD_FILE")"
    echo "  大小: $(ls -lh "$INITRD_FILE" | awk '{print $5}')"
else
    echo "⚠️  未找到initrd，使用宿主initrd"
    if [ -f "/boot/initrd.img" ] || [ -f "/boot/initramfs.img" ]; then
        mkdir -p "${CHROOT_DIR}/boot"
        find /boot -name "initrd*" -o -name "initramfs*" | head -1 | xargs -I {} cp {} "${CHROOT_DIR}/boot/initrd-host"
        INITRD_FILE="${CHROOT_DIR}/boot/initrd-host"
    else
        echo "❌ 没有可用的initrd"
        exit 1
    fi
fi

# 压缩chroot为squashfs
echo "📦 创建squashfs文件系统..."
if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp gzip \
    -b 1M \
    -noappend \
    -wildcards \
    -e "proc/*" "sys/*" "dev/*" "run/*" "tmp/*" "var/cache/*" "var/lib/apt/*"; then
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

# 创建引导配置文件（关键：使用正确的引导参数）
echo "⚙️  创建引导配置..."
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
PROMPT 0
TIMEOUT 30
UI menu.c32

MENU TITLE OpenWRT Installer
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std

LABEL live
  MENU LABEL ^Install OpenWRT (Normal)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live nomodeset quiet splash
  TEXT HELP
  Normal installation mode
  ENDTEXT

LABEL live_nomodeset
  MENU LABEL Install OpenWRT (^Safe Mode)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live nomodeset vga=normal quiet
  TEXT HELP
  Safe mode for compatibility
  ENDTEXT

LABEL live_text
  MENU LABEL Install OpenWRT (^Text Mode)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live nomodeset textonly
  TEXT HELP
  Text mode only
  ENDTEXT

LABEL debug
  MENU LABEL ^Debug Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live debug nomodeset
  TEXT HELP
  Debug mode with verbose output
  ENDTEXT

LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live nomodeset single
  TEXT HELP
  Drop to rescue shell
  ENDTEXT
ISOLINUX_CFG

# 复制引导文件
echo "📋 复制引导文件..."
# 查找isolinux.bin
for path in "/usr/lib/ISOLINUX/isolinux.bin" "/usr/lib/syslinux/isolinux.bin" "/usr/share/syslinux/isolinux.bin"; do
    if [ -f "$path" ]; then
        cp "$path" "${STAGING_DIR}/isolinux/"
        break
    fi
done

# 查找menu.c32
for path in "/usr/lib/syslinux/modules/bios/menu.c32" "/usr/share/syslinux/menu.c32"; do
    if [ -f "$path" ]; then
        cp "$path" "${STAGING_DIR}/isolinux/"
        break
    fi
done

# 检查引导文件
if [ ! -f "${STAGING_DIR}/isolinux/isolinux.bin" ]; then
    echo "❌ 未找到isolinux.bin，安装syslinux"
    apt-get install -y syslinux
    cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
fi

# 创建Grub配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (Normal)" {
    linux /live/vmlinuz boot=live nomodeset quiet splash
    initrd /live/initrd
}

menuentry "Install OpenWRT (Safe Mode)" {
    linux /live/vmlinuz boot=live nomodeset vga=normal quiet
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live nomodeset single
    initrd /live/initrd
}
GRUB_CFG

# 构建ISO（简化参数）
echo "🔥 构建ISO镜像..."
echo "使用简化构建命令..."

xorriso -as mkisofs \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -V "OPENWRT_INSTALL" \
    -quiet \
    "${STAGING_DIR}"

# 验证ISO
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "  大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo "  系统: Ubuntu 20.04 LTS"
    echo "  内核: $(basename "$KERNEL_FILE")"
    echo ""
    echo "🎉 构建完成！"
    echo ""
    echo "重要提示："
    echo "  如果启动时遇到内核恐慌，请尝试："
    echo "  1. 'Safe Mode' - 安全模式"
    echo "  2. 'Text Mode' - 纯文本模式"
    echo "  3. 'Debug Mode' - 查看详细错误信息"
    echo ""
    echo "启动后运行: start-install"
else
    echo "❌ ISO构建失败"
    exit 1
fi

echo "✅ 所有步骤完成！"
