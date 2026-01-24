#!/bin/bash
# build-openwrt-autoinstaller.sh
# 基于 Debian Live 手册和指定存档源的最小化 OpenWRT 自动安装器构建脚本
set -e

echo "🚀 开始构建最小化 OpenWRT 自动安装器 ISO..."
echo "基于 Debian buster (存档源) 和 live-boot 构建"
echo "=============================================="

# 基础配置
WORK_DIR="${HOME}/OPENWRT_AUTOINSTALL"
CHROOT_DIR="${WORK_DIR}/chroot"
STAGING_DIR="${WORK_DIR}/staging"
OUTPUT_DIR="/output"
OPENWRT_IMG="/mnt/ezopwrt.img"
ISO_NAME="openwrt-autoinstaller.iso"

# 🔧 1. 安装构建依赖
echo "📦 1. 安装构建工具..."
apt-get update
apt-get install -y \
    debootstrap \
    squashfs-tools \
    xorriso \
    isolinux \
    syslinux \
    grub-pc-bin \
    mtools \
    dosfstools \
    parted \
    wget \
    live-boot \
    live-boot-initramfs-tools

# 📁 2. 创建目录结构
echo "📁 2. 创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{boot/grub,isolinux,live}
mkdir -p "${OUTPUT_DIR}"

# 📋 3. 复制 OpenWRT 镜像
echo "📋 3. 准备 OpenWRT 镜像..."
if [ -f "${OPENWRT_IMG}" ]; then
    mkdir -p "${CHROOT_DIR}"
    cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img"
    echo "✅ OpenWRT 镜像已复制到 chroot"
else
    echo "❌ 错误: 找不到 OpenWRT 镜像 ${OPENWRT_IMG}"
    exit 1
fi

# 🌱 4. 引导最小 Debian 系统 (使用您指定的存档源)
echo "🌱 4. 引导最小 Debian buster 系统..."
echo "   使用存档源: http://archive.debian.org/debian"
debootstrap --arch=amd64 --variant=minbase \
    buster "${CHROOT_DIR}" \
    http://archive.debian.org/debian

# ⚙️ 5. 配置 chroot 环境 (核心步骤)
echo "⚙️ 5. 配置 chroot 环境 (自动登录 + 安装脚本)..."
cat > "${CHROOT_DIR}/configure.sh" << 'CHROOT_EOF'
#!/bin/bash
set -e

echo "🔧 开始在 chroot 内配置..."

# 5.1 配置 APT 源 (使用存档源，关键！)
cat > /etc/apt/sources.list << 'APT_SOURCES'
# Debian buster 存档源
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
APT_SOURCES

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check

# 5.2 配置 DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# 5.3 安装绝对最少的必要软件包
apt-get update
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    live-boot \
    live-boot-initramfs-tools \
    systemd-sysv \
    bash \
    coreutils \
    util-linux \
    parted \
    dosfstools

# 5.4 配置自动登录 (关键！)
echo "🔧 配置自动登录 root..."
# 清空 root 密码
echo "root::0:0:root:/root:/bin/bash" > /etc/shadow
# 创建 systemd 覆盖文件实现 tty1 自动登录
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
Type=idle
GETTY_OVERRIDE

# 5.5 创建自动安装脚本 (核心功能)
echo "📝 创建 OpenWRT 自动安装脚本..."
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT 全自动安装脚本

# 清屏
clear

echo ""
echo "========================================"
echo "    OpenWRT 全自动安装程序"
echo "========================================"
echo ""
echo "系统已启动，正在准备安装环境..."
echo ""

# 短暂等待，确保系统就绪
sleep 3

# 检查 OpenWRT 镜像
if [ ! -f "/openwrt.img" ]; then
    echo "❌ 错误: 未找到 OpenWRT 镜像！"
    echo "镜像应位于: /openwrt.img"
    echo ""
    echo "按 Enter 键进入救援模式..."
    read
    exec /bin/bash
fi

echo "✅ 找到 OpenWRT 镜像: $(ls -lh /openwrt.img | awk '{print $5}')"
echo ""

# 自动选择第一个可用磁盘 (可根据需求修改逻辑)
echo "🔍 正在检测安装目标磁盘..."
TARGET_DISK=$(lsblk -d -n -o NAME | grep -E '^(sd|hd|nvme|vd)' | head -1)

if [ -z "$TARGET_DISK" ]; then
    echo "❌ 错误: 未找到可用磁盘！"
    echo "请检查磁盘连接。"
    exit 1
fi

echo "✅ 自动选择目标磁盘: /dev/${TARGET_DISK}"
echo ""
echo "⚠️  警告: 即将擦除 /dev/${TARGET_DISK} 上的所有数据！"
echo ""
echo "安装将在 5 秒后开始..."
echo "按 Ctrl+C 取消安装"

for i in {5..1}; do
    echo -ne "倒计时: ${i} 秒\r"
    sleep 1
done

echo ""
echo "🚀 开始安装 OpenWRT..."
echo "目标: /dev/${TARGET_DISK}"
echo ""

# 使用 dd 写入镜像 (静默模式以保持界面简洁)
if dd if=/openwrt.img of="/dev/${TARGET_DISK}" bs=4M status=progress; then
    sync
    echo ""
    echo "✅ ✅ ✅ OpenWRT 安装成功！"
    echo ""
    echo "系统将在 10 秒后自动重启..."
    for i in {10..1}; do
        echo -ne "重启倒计时: ${i} 秒\r"
        sleep 1
    done
    echo ""
    echo "正在重启..."
    reboot
else
    echo ""
    echo "❌ 安装失败！"
    echo "请检查磁盘状态和镜像完整性。"
    exit 1
fi
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 5.6 配置启动时自动执行安装脚本
# 方法：通过 .bash_profile 自动执行（简单可靠）
cat > /root/.bash_profile << 'BASHPROFILE'
#!/bin/bash
# 只在首次登录 tty1 时运行安装程序
if [ "$(tty)" = "/dev/tty1" ] && [ ! -f /tmp/install-started ]; then
    touch /tmp/install-started
    /opt/install-openwrt.sh
fi
BASHPROFILE

# 5.7 清理和生成 initramfs
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
update-initramfs -c

echo "✅ chroot 环境配置完成！"
CHROOT_EOF

# 6. 在 chroot 内执行配置
chmod +x "${CHROOT_DIR}/configure.sh"
for fs in proc dev sys; do mount --bind /$fs "${CHROOT_DIR}/$fs"; done
chroot "${CHROOT_DIR}" /bin/bash /configure.sh
for fs in proc dev sys; do umount "${CHROOT_DIR}/$fs"; done

# 📦 7. 创建 SquashFS 根文件系统
echo "📦 7. 创建 SquashFS 文件系统..."
mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp gzip -b 1M -noappend

# 📋 8. 复制内核和 initrd
echo "📋 8. 复制内核和引导文件..."
cp "${CHROOT_DIR}/boot"/vmlinuz-* "${STAGING_DIR}/live/vmlinuz" 2>/dev/null || true
cp "${CHROOT_DIR}/boot"/initrd.img-* "${STAGING_DIR}/live/initrd" 2>/dev/null || true

# 如果上述方法失败，尝试直接查找
if [ ! -f "${STAGING_DIR}/live/vmlinuz" ]; then
    find "${CHROOT_DIR}/boot" -name "vmlinuz*" -exec cp {} "${STAGING_DIR}/live/vmlinuz" \;
fi
if [ ! -f "${STAGING_DIR}/live/initrd" ]; then
    find "${CHROOT_DIR}/boot" -name "initrd*" -exec cp {} "${STAGING_DIR}/live/initrd" \;
fi

# ⚙️ 9. 配置引导菜单
echo "⚙️ 9. 配置引导菜单..."
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT autoinstall
PROMPT 0
TIMEOUT 10
UI menu.c32

MENU TITLE OpenWRT Auto Installer

LABEL autoinstall
  MENU LABEL ^Auto Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live quiet
  TEXT HELP
  自动登录并启动 OpenWRT 刷机程序
  ENDTEXT

LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live single
  TEXT HELP
  进入救援命令行
  ENDTEXT
ISOLINUX_CFG

# 复制引导文件
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/menu.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 🔥 10. 构建 ISO 镜像
echo "🔥 10. 构建 ISO 镜像..."
xorriso -as mkisofs \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -V "OPENWRT_AUTO" \
    -quiet \
    "${STAGING_DIR}"

# ✅ 11. 完成验证
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ 构建成功！"
    echo "=============================================="
    echo "📦 输出文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "📊 文件大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo "🎯 引导方式: 传统 BIOS (ISOLINUX)"
    echo ""
    echo "🚀 使用说明："
    echo "1. 将 ISO 写入 U 盘: dd if=xxx.iso of=/dev/sdX bs=4M status=progress"
    echo "2. 从 U 盘启动计算机"
    echo "3. 选择 'Auto Install OpenWRT' (10秒后自动选择)"
    echo "4. 系统将:"
    echo "   - 自动登录 root"
    echo "   - 自动运行刷机脚本"
    echo "   - 自动选择第一个磁盘并写入 OpenWRT"
    echo "   - 完成后自动重启"
    echo ""
    echo "💡 提示：如需修改自动选择的磁盘，请编辑 chroot 中的"
    echo "      /opt/install-openwrt.sh 脚本。"
    echo "=============================================="
else
    echo "❌ ISO 构建失败！"
    exit 1
fi

echo "🎉 所有步骤已完成！"
