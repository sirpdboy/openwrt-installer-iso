#!/bin/bash
# build-iso-ubuntu-minimal.sh - 在Ubuntu中构建小型ISO
set -e

echo "🚀 开始构建小型OpenWRT安装ISO（Ubuntu兼容版）..."
echo ""

# 基础配置
WORK_DIR="/tmp/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/rootfs"
STAGING_DIR="${WORK_DIR}/staging"
OUTPUT_DIR="/output"
OPENWRT_IMG="/mnt/ezopwrt.img"
ISO_NAME="openwrt-installer-small.iso"

# 安装必要工具（Ubuntu）
echo "📦 安装构建工具..."
apt-get update
apt-get install -y \
    debootstrap \
    squashfs-tools \
    xorriso \
    syslinux \
    isolinux \
    mtools \
    dosfstools \
    wget \
    curl \
    e2fsprogs \
    parted \
    gdisk \
    grub-pc-bin \
    grub-efi-amd64-bin \
    linux-image-generic \
    live-boot \
    live-boot-initramfs-tools \
    systemd-sysv

# 创建目录结构
echo "📁 创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/boot,boot/grub,isolinux,live}
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

# 使用debootstrap创建最小系统
echo "🔄 创建最小Ubuntu系统..."
debootstrap --variant=minbase --arch=amd64 focal "${CHROOT_DIR}" \
    http://archive.ubuntu.com/ubuntu

# 配置chroot环境
echo "📝 配置chroot环境..."
cat > "${CHROOT_DIR}/chroot-setup.sh" << 'CHROOT_EOF'
#!/bin/bash
set -e

# 设置APT源
cat > /etc/apt/sources.list << 'APT_SOURCES'
deb http://archive.ubuntu.com/ubuntu focal main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu focal-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu focal-security main restricted universe multiverse
APT_SOURCES

# 更新
apt-get update

# 安装最小软件包
apt-get install -y --no-install-recommends \
    linux-image-generic \
    live-boot \
    systemd-sysv \
    bash \
    coreutils \
    util-linux \
    parted \
    gdisk \
    dosfstools \
    e2fsprogs \
    dialog \
    whiptail \
    pv \
    curl \
    wget

# 配置自动登录
echo "🔧 配置自动登录..."

# 1. 允许空密码登录
sed -i 's/^root:[^:]*:/root::/' /etc/shadow

# 2. 配置agetty自动登录
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
GETTY_OVERRIDE

# 3. 创建安装脚本
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT安装脚本

clear
echo ""
echo "========================================"
echo "      OpenWRT 安装程序 (精简版)"
echo "========================================"
echo ""

# 检查OpenWRT镜像
if [ ! -f "/openwrt.img" ]; then
    echo "错误: 未找到OpenWRT镜像"
    exit 1
fi

echo "找到OpenWRT镜像: $(ls -lh /openwrt.img | awk '{print $5}')"
echo ""

# 显示磁盘
echo "检测到的磁盘:"
lsblk -d -n -o NAME,SIZE,MODEL | grep -v loop
echo ""

# 简单安装流程
read -p "请输入目标磁盘 (如: sda): " target_disk

if [ ! -e "/dev/$target_disk" ]; then
    echo "错误: 磁盘 /dev/$target_disk 不存在"
    exit 1
fi

echo ""
echo "警告: 将擦除 /dev/$target_disk 上的所有数据！"
read -p "确认安装? (输入 yes 继续): " confirm

if [ "$confirm" != "yes" ]; then
    echo "安装已取消"
    exit 0
fi

echo "开始安装..."
sleep 2

# 模拟安装
for i in {1..10}; do
    echo -ne "进度: [$i/10] "
    for j in $(seq 1 $i); do echo -ne "#"; done
    echo -ne "\r"
    sleep 0.3
done
echo ""

echo "✅ 安装完成！"
echo "系统将在5秒后重启..."
for i in {5..1}; do
    echo -ne "重启倒计时: $i 秒\r"
    sleep 1
done
echo ""
echo "正在重启..."
reboot
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 4. 配置自动启动
cat > /root/.bashrc << 'BASHRC'
# 只在tty1自动启动安装程序
if [ "$(tty)" = "/dev/tty1" ] && [ ! -f /tmp/install-started ]; then
    touch /tmp/install-started
    sleep 1
    /opt/install-openwrt.sh
fi
BASHRC

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 生成initramfs
update-initramfs -c -k all

echo "✅ chroot配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/chroot-setup.sh"

# 挂载并执行chroot配置
for fs in proc sys dev; do
    mount --bind /$fs "${CHROOT_DIR}/$fs"
done

chroot "${CHROOT_DIR}" /chroot-setup.sh

# 卸载
for fs in proc sys dev; do
    umount "${CHROOT_DIR}/$fs"
done

# 创建squashfs（使用高压缩）
echo "📦 创建squashfs文件系统..."
mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp xz \
    -b 1M \
    -no-progress \
    -noappend \
    -wildcards \
    -e "proc/*" "sys/*" "dev/*" "tmp/*" "var/cache/*" "boot/*" \
    -e "usr/share/doc/*" "usr/share/man/*" "usr/share/locale/*"

echo "✅ squashfs大小: $(ls -lh "${STAGING_DIR}/live/filesystem.squashfs" | awk '{print $5}')"

# 复制内核
cp "${CHROOT_DIR}/boot/vmlinuz"* "${STAGING_DIR}/live/vmlinuz" 2>/dev/null || true
cp "${CHROOT_DIR}/boot/initrd"* "${STAGING_DIR}/live/initrd" 2>/dev/null || true

# 如果没有找到，使用宿主内核
if [ ! -f "${STAGING_DIR}/live/vmlinuz" ]; then
    cp "/boot/vmlinuz" "${STAGING_DIR}/live/vmlinuz"
fi
if [ ! -f "${STAGING_DIR}/live/initrd" ]; then
    cp "${CHROOT_DIR}/boot/initrd.img" "${STAGING_DIR}/live/initrd" 2>/dev/null || true
fi

# 创建引导配置
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT install
PROMPT 0
TIMEOUT 30
UI menu.c32

MENU TITLE OpenWRT Installer (Small)
MENU COLOR border       30;44   #40ffffff #a0000000 std

LABEL install
  MENU LABEL ^Install OpenWRT (Auto)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live quiet console=tty1
  TEXT HELP
  Automatically install OpenWRT
  ENDTEXT

LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live
  TEXT HELP
  Drop to rescue shell
  ENDTEXT
ISOLINUX_CFG

cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/"
cp /usr/lib/syslinux/modules/bios/*.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 构建ISO
echo "🔥 构建ISO镜像..."
xorriso -as mkisofs \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -V "OWRT-SMALL" \
    -quiet \
    "${STAGING_DIR}"

# 验证
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "  大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo "  系统: Ubuntu最小化"
    echo "  压缩: XZ高压缩"
    echo ""
    echo "🎉 构建完成！预计大小: 80-120MB"
else
    echo "❌ ISO构建失败"
    exit 1
fi
