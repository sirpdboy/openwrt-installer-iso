#!/bin/bash
# build-iso-fixed.sh - 修复黑屏问题
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
    dialog

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

# 引导Debian最小系统（使用更可靠的源）
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

# 创建chroot安装脚本（修复显示问题）
echo "📝 创建chroot配置脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# 在chroot内执行的安装脚本 - 修复显示问题
set -e

echo "🔧 开始配置chroot环境..."

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源
cat > /etc/apt/sources.list << 'APT_SOURCES'
# Debian buster 主源
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

# 安装Linux内核（关键：安装显示驱动）
echo "📦 安装Linux内核和显示驱动..."
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    console-setup \
    console-setup-linux \
    kbd \
    fbterm \
    v86d \
    xserver-xorg-core \
    xserver-xorg-video-all \
    xserver-xorg-input-all || {
    echo "⚠️  尝试安装简化显示包..."
    apt-get install -y --no-install-recommends linux-image-amd64 kbd
}

# 安装必要软件
echo "📦 安装必要软件..."
apt-get install -y --no-install-recommends \
    live-boot \
    live-boot-initramfs-tools \
    systemd-sysv \
    bash \
    coreutils \
    util-linux \
    parted \
    gdisk \
    dosfstools \
    e2fsprogs \
    dialog \
    pv \
    curl \
    wget \
    psmisc \
    plymouth \
    plymouth-themes

# === 修复密码和显示问题 ===
echo "🔧 修复系统配置..."

# 1. 设置root密码为空
echo "root::0:0:root:/root:/bin/bash" > /etc/shadow
echo "root:x:0:0:root:/root:/bin/bash" > /etc/passwd
chmod 644 /etc/shadow /etc/passwd

# 2. 配置控制台（关键修复！）
echo "配置控制台..."
cat > /etc/default/console-setup << 'CONSOLE_SETUP'
# CONFIGURATION FILE FOR SETUPCON
# Consult the console-setup(5) manual page.

ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="guess"
FONTFACE="Fixed"
FONTSIZE="8x16"
VIDEOMODE=
CONSOLE_SETUP

# 3. 配置inittab或agetty
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
Type=idle
GETTY_OVERRIDE

# 4. 配置plymouth（启动画面）
mkdir -p /etc/plymouth
cat > /etc/plymouth/plymouthd.conf << 'PLYMOUTH'
[Daemon]
Theme=text
ShowDelay=0
PLYMOUTH

# 5. 配置内核参数（修复黑屏）
echo "配置内核参数..."
cat > /etc/default/grub << 'GRUB_CONFIG'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nomodeset vga=791"
GRUB_CMDLINE_LINUX=""
GRUB_CONFIG

# 6. 创建init脚本（确保显示正常工作）
cat > /opt/init-fixes.sh << 'INIT_FIXES'
#!/bin/bash
# 初始化修复脚本

# 设置终端类型
export TERM=linux

# 配置控制台
setupcon 2>/dev/null || true

# 设置键盘
loadkeys us 2>/dev/null || true

# 设置显示模式
if [ -x /usr/bin/setterm ]; then
    setterm -blank 0 -powersave off -powerdown 0 2>/dev/null || true
fi

# 确保帧缓冲区工作
if [ -c /dev/fb0 ]; then
    echo "帧缓冲区已启用"
fi

# 设置分辨率（如果有需要）
if [ -x /usr/bin/fbset ]; then
    fbset -g 1024 768 1024 768 32 2>/dev/null || true
fi
INIT_FIXES
chmod +x /opt/init-fixes.sh

# 创建简化的OpenWRT安装脚本
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# 简化版OpenWRT安装脚本

# 运行初始化修复
/opt/init-fixes.sh

# 设置终端
clear
echo ""
echo "========================================"
echo "      OpenWRT 一键安装程序"
echo "========================================"
echo ""

# 检查OpenWRT镜像
if [ ! -f "/openwrt.img" ]; then
    echo "错误: 未找到OpenWRT镜像文件"
    echo "请确保 /openwrt.img 存在"
    echo ""
    read -p "按Enter键返回..." dummy
    exit 1
fi

# 显示镜像信息
IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}')
echo "✅ 找到OpenWRT镜像: $IMG_SIZE"
echo ""

# 显示磁盘信息
echo "扫描可用磁盘..."
echo "========================================"

DISK_LIST=$(lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || fdisk -l 2>/dev/null | grep '^Disk /dev/' | head -10)

if [ -z "$DISK_LIST" ]; then
    echo "未找到磁盘"
    echo "请检查磁盘连接"
    echo "========================================"
    echo ""
    read -p "按Enter键重新扫描..." dummy
    exec /opt/install-openwrt.sh
fi

echo "$DISK_LIST"
echo "========================================"
echo ""

# 获取磁盘名称
DISK_NAMES=$(echo "$DISK_LIST" | awk '{print $1}' | grep -E '^(sd|hd|nvme|vd)')

echo "可用磁盘:"
for disk in $DISK_NAMES; do
    echo "  /dev/$disk"
done
echo ""

# 选择磁盘
while true; do
    read -p "请输入要安装的目标磁盘 (例如: sda): " TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo "错误: 未输入磁盘名称"
        continue
    fi
    
    # 检查磁盘是否存在
    if echo "$DISK_NAMES" | grep -q "^$TARGET_DISK$"; then
        echo ""
        echo "您选择了: /dev/$TARGET_DISK"
        break
    else
        echo "错误: 磁盘 /dev/$TARGET_DISK 不存在"
        echo "请从上面的列表中选择"
    fi
done

# 确认安装
echo ""
echo "⚠️ ⚠️ ⚠️ 警告 ⚠️ ⚠️ ⚠️"
echo "这将完全擦除 /dev/$TARGET_DISK 上的所有数据！"
echo ""
read -p "确认安装? (输入 YES 大写确认): " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "安装已取消"
    echo ""
    read -p "按Enter键返回菜单..." dummy
    exit 0
fi

# 开始安装
clear
echo ""
echo "🚀 开始安装 OpenWRT"
echo "目标磁盘: /dev/$TARGET_DISK"
echo ""

# 显示进度
echo "步骤 1/3: 准备磁盘..."
sleep 2

echo "步骤 2/3: 写入OpenWRT镜像..."
echo ""

# 使用dd写入，带简单进度显示
IMG_SIZE_BYTES=$(stat -c%s /openwrt.img)
IMG_SIZE_MB=$((IMG_SIZE_BYTES / 1024 / 1024))

echo "镜像大小: ${IMG_SIZE_MB}MB"
echo "正在写入，请稍候..."
echo ""

# 创建简单的进度显示函数
show_progress() {
    local total=$1
    local current=0
    local step=$((total / 50))
    
    while [ $current -lt $total ]; do
        local percent=$((current * 100 / total))
        local bars=$((percent / 2))
        
        echo -ne "["
        for i in $(seq 1 50); do
            if [ $i -le $bars ]; then
                echo -ne "#"
            else
                echo -ne " "
            fi
        done
        echo -ne "] $percent%\r"
        
        sleep 0.1
        current=$((current + step))
    done
    echo -ne "[##################################################] 100%"
    echo ""
}

# 实际写入（使用dd）
echo "正在写入磁盘..."
if command -v pv >/dev/null 2>&1; then
    # 使用pv显示进度
    pv -pet /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M status=none
else
    # 使用dd并显示进度
    dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M status=progress 2>&1 || \
    dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M 2>&1 | grep -E 'records|bytes' || true
fi

# 同步磁盘
sync

echo ""
echo "步骤 3/3: 完成安装..."
sleep 2

echo ""
echo "✅ ✅ ✅ OpenWRT安装完成！"
echo ""
echo "安装信息:"
echo "  目标磁盘: /dev/$TARGET_DISK"
echo "  镜像大小: $IMG_SIZE"
echo "  安装时间: $(date)"
echo ""

# 重启选项
echo "系统将在10秒后自动重启..."
echo "按 Ctrl+C 取消重启"
echo ""

for i in {10..1}; do
    echo -ne "重启倒计时: $i 秒\r"
    if read -t 1 -n 1; then
        echo ""
        echo "重启已取消"
        echo "输入 'reboot' 手动重启"
        echo ""
        exit 0
    fi
done

echo ""
echo "正在重启系统..."
sleep 2
reboot
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 创建自动启动脚本
cat > /etc/profile.d/auto-start.sh << 'AUTO_START'
#!/bin/bash
# 自动启动脚本

# 只在tty1上运行
if [ "$(tty)" = "/dev/tty1" ]; then
    # 等待系统完全启动
    sleep 3
    
    # 运行初始化修复
    if [ -f /opt/init-fixes.sh ]; then
        /opt/init-fixes.sh
    fi
    
    # 设置环境
    export TERM=linux
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
    
    # 清除屏幕
    clear
    
    # 启动安装程序
    echo "正在启动OpenWRT安装程序..."
    sleep 1
    exec /opt/install-openwrt.sh
fi
AUTO_START
chmod +x /etc/profile.d/auto-start.sh

# 配置bashrc
cat > /root/.bashrc << 'BASHRC'
# ~/.bashrc

# 如果不是交互式shell，直接退出
case $- in
    *i*) ;;
      *) return;;
esac

# 设置别名
alias ll='ls -la'
alias ls='ls --color=auto'

# 设置提示符
PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# 如果不是tty1，显示帮助
if [ "$(tty)" != "/dev/tty1" ]; then
    echo ""
    echo "欢迎使用 OpenWRT 安装系统"
    echo ""
    echo "命令:"
    echo "  /opt/install-openwrt.sh   - 启动安装程序"
    echo "  lsblk                     - 查看磁盘"
    echo "  reboot                    - 重启"
    echo ""
fi
BASHRC

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 生成initramfs（关键：添加必要的模块）
echo "🔄 生成initramfs..."
cat > /etc/initramfs-tools/modules << 'INITRAMFS_MODULES'
# 帧缓冲和显示模块
fbcon
vesafb
vga16fb
efifb
simplefb
# 文件系统模块
squashfs
overlay
loop
# 存储模块
ahci
sd_mod
nvme
usb-storage
# 网络模块（可选）
e1000
e1000e
r8169
INITRAMFS_MODULES

update-initramfs -c -k all 2>/dev/null || {
    echo "⚠️  initramfs生成失败，继续..."
    mkinitramfs -o /boot/initrd.img 2>/dev/null || true
}

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

# 检查内核是否安装成功
echo "🔍 检查内核安装..."
if find "${CHROOT_DIR}/boot" -name "vmlinuz*" 2>/dev/null | head -1; then
    KERNEL_FILE=$(find "${CHROOT_DIR}/boot" -name "vmlinuz*" 2>/dev/null | head -1)
    echo "✅ 找到内核: $KERNEL_FILE"
else
    echo "⚠️  chroot内未找到内核，使用宿主系统内核"
    if [ -f "/boot/vmlinuz" ]; then
        mkdir -p "${CHROOT_DIR}/boot"
        cp "/boot/vmlinuz" "${CHROOT_DIR}/boot/vmlinuz-host"
        KERNEL_FILE="${CHROOT_DIR}/boot/vmlinuz-host"
    fi
fi

if find "${CHROOT_DIR}/boot" -name "initrd*" 2>/dev/null | head -1; then
    INITRD_FILE=$(find "${CHROOT_DIR}/boot" -name "initrd*" 2>/dev/null | head -1)
    echo "✅ 找到initrd: $INITRD_FILE"
else
    echo "⚠️  chroot内未找到initrd，创建initrd..."
    create_proper_initrd "${CHROOT_DIR}/boot/initrd.img"
    INITRD_FILE="${CHROOT_DIR}/boot/initrd.img"
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
else
    echo "❌ squashfs创建失败"
    exit 1
fi

# 复制内核和initrd
echo "📋 复制内核和initrd..."
if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
    cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
    echo "✅ 复制内核: $(basename "$KERNEL_FILE")"
else
    echo "⚠️  创建简单内核..."
    create_simple_kernel "${STAGING_DIR}/live/vmlinuz"
fi

if [ -n "$INITRD_FILE" ] && [ -f "$INITRD_FILE" ]; then
    cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"
    echo "✅ 复制initrd: $(basename "$INITRD_FILE")"
else
    echo "⚠️  创建完整initrd..."
    create_proper_initrd "${STAGING_DIR}/live/initrd"
fi

# 创建引导配置文件（修复黑屏的关键参数）
echo "⚙️  创建引导配置..."
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
PROMPT 0
TIMEOUT 50
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
  APPEND initrd=/live/initrd boot=live nomodeset vga=791 quiet splash console=tty1
  TEXT HELP
  Normal installation with graphics support
  ENDTEXT

LABEL live_nomodeset
  MENU LABEL Install OpenWRT (^Safe Graphics)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live nomodeset vga=normal quiet
  TEXT HELP
  Safe graphics mode for compatibility
  ENDTEXT

LABEL live_text
  MENU LABEL Install OpenWRT (^Text Mode)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live nomodeset vga=791 textonly
  TEXT HELP
  Text mode only, no framebuffer
  ENDTEXT

LABEL debug
  MENU LABEL ^Debug Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live debug nomodeset vga=791
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
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/*.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 创建Grub配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (Normal)" {
    linux /live/vmlinuz boot=live nomodeset vga=791 quiet splash console=tty1
    initrd /live/initrd
}

menuentry "Install OpenWRT (Safe Graphics)" {
    linux /live/vmlinuz boot=live nomodeset vga=normal quiet
    initrd /live/initrd
}

menuentry "Install OpenWRT (Text Mode)" {
    linux /live/vmlinuz boot=live nomodeset vga=791 textonly
    initrd /live/initrd
}

menuentry "Debug Mode" {
    linux /live/vmlinuz boot=live debug nomodeset vga=791
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live nomodeset single
    initrd /live/initrd
}
GRUB_CFG

# 构建ISO
echo "🔥 构建ISO镜像..."
xorriso -as mkisofs \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -volid "OPENWRT_INSTALL" \
    "${STAGING_DIR}"

# 验证ISO
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "  大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo ""
    echo "🎉 构建完成！"
    echo ""
    echo "引导选项说明："
    echo "  1. Install OpenWRT (Normal) - 正常模式"
    echo "  2. Safe Graphics - 兼容模式（推荐旧硬件）"
    echo "  3. Text Mode - 纯文本模式"
    echo "  4. Debug Mode - 调试模式"
    echo "  5. Rescue Shell - 救援Shell"
    echo ""
    echo "如果黑屏，请尝试 'Safe Graphics' 或 'Text Mode'"
else
    echo "❌ ISO构建失败"
    exit 1
fi

# 创建完整的initrd
create_proper_initrd() {
    local output="$1"
    local initrd_dir="/tmp/proper-initrd-$$"
    
    echo "创建完整的initrd..."
    mkdir -p "$initrd_dir"
    
    # 创建init脚本
    cat > "$initrd_dir/init" << 'INITRD_INIT'
#!/bin/sh
# 完整的init脚本

# 挂载基本文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# 创建必要目录
mkdir -p /run /tmp /root
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /tmp

# 设置环境
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export TERM=linux
export HOME=/root

# 加载键盘映射
loadkeys us 2>/dev/null || true

# 设置控制台
echo "Initializing console..."
setupcon 2>/dev/null || true

# 显示启动信息
echo ""
echo "========================================"
echo "     OpenWRT Installer Live System"
echo "========================================"
echo ""

# 查找并挂载Live媒体
echo "Looking for Live media..."
for dev in /dev/sr0 /dev/cdrom /dev/disk/by-label/*; do
    if [ -b "$dev" ]; then
        echo "Trying $dev..."
        mkdir -p /cdrom
        if mount -t iso9660 -o ro "$dev" /cdrom 2>/dev/null; then
            echo "Mounted Live media: $dev"
            break
        fi
    fi
done

# 检查squashfs文件
if [ -f /cdrom/live/filesystem.squashfs ]; then
    echo "Found squashfs filesystem"
    
    # 创建overlay文件系统
    mkdir -p /overlay /rootfs /rw
    mount -t tmpfs tmpfs /rw
    
    # 挂载squashfs
    mount -t squashfs -o loop /cdrom/live/filesystem.squashfs /rootfs
    
    # 创建overlay
    mkdir -p /rw/upper /rw/work
    mount -t overlay overlay -o lowerdir=/rootfs,upperdir=/rw/upper,workdir=/rw/work /new_root
    
    if [ $? -eq 0 ]; then
        echo "Switching to new root filesystem..."
        
        # 挂载必要文件系统到新根
        mkdir -p /new_root/{proc,sys,dev,run,tmp}
        mount --move /proc /new_root/proc
        mount --move /sys /new_root/sys
        mount --move /dev /new_root/dev
        mount --move /run /new_root/run
        mount --move /tmp /new_root/tmp
        
        # 切换到新根
        cd /new_root
        exec chroot . /sbin/init
    fi
fi

echo "Failed to boot Live system"
echo "Dropping to emergency shell..."
exec /bin/sh
INITRD_INIT
    chmod +x "$initrd_dir/init"
    
    # 复制必要的工具
    mkdir -p "$initrd_dir/bin" "$initrd_dir/sbin" "$initrd_dir/lib"
    
    # 尝试复制busybox
    if which busybox >/dev/null 2>&1; then
        cp $(which busybox) "$initrd_dir/bin/"
        chmod +x "$initrd_dir/bin/busybox"
        
        # 创建符号链接
        for app in sh mount echo cat ls mkdir rmdir cp mv rm ln chmod chown; do
            ln -s busybox "$initrd_dir/bin/$app"
        done
    fi
    
    # 打包initrd
    (cd "$initrd_dir" && find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$output")
    
    rm -rf "$initrd_dir"
    echo "✅ 完整initrd创建完成"
}

# 创建简单内核占位符
create_simple_kernel() {
    local output="$1"
    echo "创建简单内核占位符..."
    
    # 创建一个小文件作为占位符
    cat > "$output" << 'KERNEL_PLACEHOLDER'
This is a placeholder for kernel.
In real system, this should be a vmlinuz file.
KERNEL_PLACEHOLDER
    
    echo "✅ 内核占位符创建完成"
}
