#!/bin/bash
# build-iso-modern.sh - 使用现代Ubuntu版本
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

# 使用Ubuntu 22.04 LTS（jammy）或 Debian 12（bookworm）
echo "🔧 配置Ubuntu 22.04 LTS源..."
cat > /etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse
EOF

# 添加Ubuntu GPG密钥（修复签名问题）
echo "🔑 添加Ubuntu GPG密钥..."
apt-get update 2>/dev/null || true
apt-get install -y gnupg curl
curl -fsSL https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x871920D1991BC93C | apt-key add - 2>/dev/null || true

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
    grub-efi-amd64-bin \
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

# 引导Ubuntu 22.04最小系统
echo "🔄 引导Ubuntu 22.04最小系统..."
debootstrap --arch=amd64 --variant=minbase \
    jammy "${CHROOT_DIR}" \
    http://archive.ubuntu.com/ubuntu || {
    echo "尝试备用源..."
    debootstrap --arch=amd64 --variant=minbase \
        jammy "${CHROOT_DIR}" \
        http://mirrors.aliyun.com/ubuntu || {
        echo "尝试使用国内源..."
        debootstrap --arch=amd64 --variant=minbase \
            jammy "${CHROOT_DIR}" \
            http://mirrors.tuna.tsinghua.edu.cn/ubuntu || {
            echo "❌ debootstrap失败"
            exit 1
        }
    }
}

# 创建chroot安装脚本
echo "📝 创建chroot配置脚本..."
cat > "${CHROOT_DIR}/setup.sh" << 'CHROOT_EOF'
#!/bin/bash
set -e

echo "🔧 开始配置chroot环境..."

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源（Ubuntu 22.04）
cat > /etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse
EOF

# 如果使用国内网络，可以使用阿里云镜像
# cat > /etc/apt/sources.list << EOF
# deb http://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse
# deb http://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse
# deb http://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse
# EOF

# 配置DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 更新包列表
echo "🔄 更新包列表..."
apt-get update

# 安装必要软件
echo "📦 安装必要软件..."
apt-get install -y --no-install-recommends \
    linux-image-generic \
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
    console-setup \
    initramfs-tools

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

# 创建安装脚本
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT安装脚本

clear
echo ""
echo "========================================"
echo "      OpenWRT 一键安装程序"
echo "========================================"
echo ""

# 等待系统就绪
sleep 2

# 检查镜像
if [ ! -f "/openwrt.img" ]; then
    echo "❌ 错误: 未找到OpenWRT镜像"
    echo "按Enter进入Shell..."
    read dummy
    exec /bin/bash
fi

echo "✅ 找到OpenWRT镜像"
echo ""

# 显示磁盘
echo "可用磁盘:"
echo "----------------------------------------"
lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null || fdisk -l | grep '^Disk /dev/'
echo "----------------------------------------"
echo ""

# 选择磁盘
while true; do
    read -p "请输入目标磁盘 (如: sda): " target
    
    if [ -z "$target" ]; then
        echo "请输入磁盘名称"
        continue
    fi
    
    if lsblk -d -n -o NAME 2>/dev/null | grep -q "^$target$"; then
        break
    elif fdisk -l 2>/dev/null | grep -q "^Disk /dev/$target"; then
        break
    else
        echo "❌ 磁盘 /dev/$target 不存在"
    fi
done

# 确认
echo ""
echo "⚠️  警告: 将擦除 /dev/$target 上的所有数据！"
read -p "确认安装? (输入 yes): " confirm

if [ "$confirm" != "yes" ]; then
    echo "安装取消"
    exit 0
fi

# 安装
echo "开始安装..."
dd if=/openwrt.img of="/dev/$target" bs=4M status=progress
sync

echo "✅ 安装完成！"
echo "系统将在10秒后重启..."

for i in {10..1}; do
    echo -ne "重启倒计时: $i 秒\r"
    sleep 1
done

echo ""
echo "正在重启..."
reboot
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 配置自动启动
cat > /etc/rc.local << 'RCLOCAL'
#!/bin/bash
# 自动启动安装程序

sleep 3

if [ "$(tty)" = "/dev/tty1" ]; then
    /opt/install-openwrt.sh
fi

exit 0
RCLOCAL
chmod +x /etc/rc.local

# 生成initramfs
update-initramfs -c

echo "✅ chroot配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/setup.sh"

# 挂载文件系统
for fs in proc dev sys; do
    mount --bind /$fs "${CHROOT_DIR}/$fs"
done

# 复制resolv.conf
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true

# 执行chroot配置
chroot "${CHROOT_DIR}" /bin/bash /setup.sh

# 卸载
for fs in proc dev sys; do
    umount "${CHROOT_DIR}/$fs"
done

# 复制内核和initrd
echo "🔍 查找内核和initrd..."
KERNEL_FILE=$(find "${CHROOT_DIR}/boot" -name "vmlinuz*" | head -1)
INITRD_FILE=$(find "${CHROOT_DIR}/boot" -name "initrd*" | head -1)

if [ -f "$KERNEL_FILE" ]; then
    cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
    echo "✅ 复制内核: $(basename "$KERNEL_FILE")"
else
    echo "❌ 未找到内核"
    exit 1
fi

if [ -f "$INITRD_FILE" ]; then
    cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"
    echo "✅ 复制initrd: $(basename "$INITRD_FILE")"
else
    echo "❌ 未找到initrd"
    exit 1
fi

# 压缩chroot为squashfs
echo "📦 创建squashfs文件系统..."
mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp gzip \
    -b 1M \
    -noappend \
    -wildcards \
    -e "proc/*" "sys/*" "dev/*" "tmp/*"

echo "✅ squashfs创建成功"

# 创建引导配置
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
PROMPT 0
TIMEOUT 30
UI menu.c32

MENU TITLE OpenWRT Installer

LABEL live
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live nomodeset quiet

LABEL shell
  MENU LABEL Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live single
ISOLINUX_CFG

# 复制引导文件
echo "📋 复制引导文件..."
# 尝试多个可能的路径
if [ -f "/usr/lib/ISOLINUX/isolinux.bin" ]; then
    cp "/usr/lib/ISOLINUX/isolinux.bin" "${STAGING_DIR}/isolinux/"
elif [ -f "/usr/lib/syslinux/isolinux.bin" ]; then
    cp "/usr/lib/syslinux/isolinux.bin" "${STAGING_DIR}/isolinux/"
elif [ -f "/usr/share/syslinux/isolinux.bin" ]; then
    cp "/usr/share/syslinux/isolinux.bin" "${STAGING_DIR}/isolinux/"
else
    echo "⚠️  未找到isolinux.bin，尝试安装syslinux"
    apt-get install -y syslinux
    cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
fi

# 复制menu.c32
if [ -f "/usr/lib/syslinux/modules/bios/menu.c32" ]; then
    cp "/usr/lib/syslinux/modules/bios/menu.c32" "${STAGING_DIR}/isolinux/"
elif [ -f "/usr/share/syslinux/menu.c32" ]; then
    cp "/usr/share/syslinux/menu.c32" "${STAGING_DIR}/isolinux/"
fi

# 创建Grub配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live nomodeset quiet
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live single
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
    -V "OPENWRT_INSTALL" \
    "${STAGING_DIR}"

# 验证ISO
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "  大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo "  系统: Ubuntu 22.04 LTS"
    echo ""
    echo "🎉 构建完成！"
else
    echo "❌ ISO构建失败"
    exit 1
fi

echo "✅ 所有步骤完成！"
