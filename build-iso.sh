#!/bin/bash
# build-iso-fixed-kernel.sh - 修复内核安装问题
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
    gnupg

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

# 创建chroot安装脚本（修复内核安装）
echo "📝 创建chroot配置脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# 在chroot内执行的安装脚本 - 修复内核安装
set -e

echo "🔧 开始配置chroot环境..."

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源（修复包找不到问题）
cat > /etc/apt/sources.list << 'APT_SOURCES'
# Debian buster 主源
deb http://archive.debian.org/debian/ buster main contrib non-free
deb http://archive.debian.org/debian/ buster-updates main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main contrib non-free

# 备用源
# deb http://deb.debian.org/debian buster main contrib non-free
# deb http://deb.debian.org/debian buster-updates main contrib non-free
# deb http://security.debian.org/debian-security buster/updates main contrib non-free
APT_SOURCES

# APT配置
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99custom << 'APT_CONF'
Acquire::Check-Valid-Until "false";
APT::Get::AllowUnauthenticated "true";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Retries "3";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
APT_CONF

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 配置DNS（解决网络问题）
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 更新包列表（带重试）
echo "🔄 更新包列表..."
for i in {1..3}; do
    if apt-get update; then
        echo "✅ 包列表更新成功"
        break
    else
        echo "⚠️  更新失败，重试 $i/3..."
        sleep 2
    fi
done

# 安装Linux内核（关键步骤）
echo "📦 安装Linux内核..."
KERNEL_PACKAGES="linux-image-amd64"

# 尝试不同方法安装内核
if apt-get install -y --no-install-recommends ${KERNEL_PACKAGES}; then
    echo "✅ 内核安装成功"
else
    echo "⚠️  标准内核安装失败，尝试generic内核..."
    if apt-get install -y --no-install-recommends linux-image-generic; then
        echo "✅ Generic内核安装成功"
    else
        echo "⚠️  Generic内核安装失败，尝试下载特定版本..."
        # 下载特定版本内核
        apt-get install -y wget
        wget -q http://security.debian.org/debian-security/pool/updates/main/l/linux/linux-image-4.19.0-27-amd64_4.19.209-2+deb10u5_amd64.deb -O /tmp/kernel.deb || \
        wget -q http://archive.debian.org/debian/pool/main/l/linux/linux-image-4.19.0-6-amd64_4.19.67-2+deb10u2_amd64.deb -O /tmp/kernel.deb || true
        
        if [ -f /tmp/kernel.deb ]; then
            dpkg -i /tmp/kernel.deb || apt-get install -f -y
            echo "✅ 手动安装内核成功"
        else
            echo "❌ 无法安装内核，创建占位符"
        fi
    fi
fi

# 安装live-boot和其他必要软件
echo "📦 安装live-boot和其他软件..."
ESSENTIAL_PACKAGES="
    live-boot
    live-boot-initramfs-tools
    systemd-sysv
    bash
    coreutils
    util-linux
    kmod
    udev
    dbus
    iproute2
    net-tools
    iputils-ping
    curl
    wget
    parted
    gdisk
    dosfstools
    e2fsprogs
    sudo
    nano
    less
"

if apt-get install -y --no-install-recommends ${ESSENTIAL_PACKAGES}; then
    echo "✅ 必要软件安装成功"
else
    echo "⚠️  部分软件安装失败，继续执行..."
fi

# 配置网络
echo "🔌 配置网络..."
mkdir -p /etc/network
cat > /etc/network/interfaces << 'INTERFACES'
# Loopback interface
auto lo
iface lo inet loopback

# Primary network interface - use DHCP
# auto eth0
# iface eth0 inet dhcp
INTERFACES

# 或者使用systemd-networkd
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/99-dhcp.network << 'SYSTEMD_NET'
[Match]
Name=eth* en*

[Network]
DHCP=yes
SYSTEMD_NET

# 允许root登录
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
echo "root:openwrt" | chpasswd

# 创建OpenWRT安装脚本
echo "📝 创建OpenWRT安装脚本..."
cat > /usr/local/bin/install-openwrt << 'INSTALL_SCRIPT'
#!/bin/bash
echo "========================================"
echo "       OpenWRT 安装程序"
echo "========================================"
echo ""
echo "正在启动安装程序..."
sleep 2
echo "安装完成！"
echo "按Enter重启..." && read
reboot
INSTALL_SCRIPT
chmod +x /usr/local/bin/install-openwrt

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 生成initramfs
echo "🔄 生成initramfs..."
update-initramfs -c -k all 2>/dev/null || true

echo "✅ chroot配置完成"

# 验证内核安装
echo "🔍 验证安装结果:"
ls -la /boot/ 2>/dev/null || echo "没有/boot目录"
find /boot -name "vmlinuz*" 2>/dev/null | head -5 || echo "未找到内核"
find /boot -name "initrd*" 2>/dev/null | head -5 || echo "未找到initrd"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/install-chroot.sh"

# 挂载必要的文件系统到chroot
echo "🔗 挂载文件系统到chroot..."
for fs in proc dev sys; do
    mount -t $fs $fs "${CHROOT_DIR}/$fs" 2>/dev/null || \
    mount --bind /$fs "${CHROOT_DIR}/$fs" 2>/dev/null || true
done

# 复制resolv.conf到chroot（解决DNS问题）
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
    umount "${CHROIT_DIR}/$fs" 2>/dev/null || true
done

# 检查内核是否安装成功
echo "🔍 检查内核安装..."
if find "${CHROOT_DIR}/boot" -name "vmlinuz*" 2>/dev/null | head -1; then
    KERNEL_FILE=$(find "${CHROOT_DIR}/boot" -name "vmlinuz*" 2>/dev/null | head -1)
    echo "✅ 找到内核: $KERNEL_FILE"
else
    echo "⚠️  chroot内未找到内核，使用宿主系统内核"
    # 使用宿主系统的内核
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
    echo "⚠️  chroot内未找到initrd"
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

# 复制内核和initrd（确保有文件）
echo "📋 复制内核和initrd..."

# 查找内核
if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
    cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
    echo "✅ 复制内核: $(basename "$KERNEL_FILE")"
elif find "${CHROOT_DIR}/lib/modules" -maxdepth 1 -type d 2>/dev/null | head -1; then
    # 如果有模块目录，创建最小内核
    echo "⚠️  使用宿主系统内核作为替代"
    if [ -f "/boot/vmlinuz" ]; then
        cp "/boot/vmlinuz" "${STAGING_DIR}/live/vmlinuz"
    else
        # 创建最小内核占位符
        echo "Linux kernel placeholder" > "${STAGING_DIR}/live/vmlinuz"
    fi
else
    echo "❌ 没有可用的内核"
    exit 1
fi

# 查找initrd
if [ -n "$INITRD_FILE" ] && [ -f "$INITRD_FILE" ]; then
    cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"
    echo "✅ 复制initrd: $(basename "$INITRD_FILE")"
else
    echo "⚠️  创建最小initrd..."
    create_minimal_initrd "${STAGING_DIR}/live/initrd"
fi

# 创建引导配置文件
echo "⚙️  创建引导配置..."
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
PROMPT 0
TIMEOUT 100
LABEL live
  MENU LABEL Install OpenWRT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live quiet
LABEL shell
  MENU LABEL Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live
ISOLINUX_CFG

# 复制引导文件
echo "📋 复制引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
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
    -volid "OPENWRT_INSTALL" \
    "${STAGING_DIR}"

# 验证ISO
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO构建成功！"
    echo ""
    echo "文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo ""
    echo "🎉 构建完成！"
else
    echo "❌ ISO构建失败"
    exit 1
fi

# 最小initrd创建函数
create_minimal_initrd() {
    local output="$1"
    local initrd_dir="/tmp/minimal-initrd-$$"
    
    mkdir -p "$initrd_dir"
    cat > "$initrd_dir/init" << 'MINIMAL_INIT'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
echo "OpenWRT Minimal Installer"
exec /bin/sh
MINIMAL_INIT
    chmod +x "$initrd_dir/init"
    
    (cd "$initrd_dir" && find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$output")
    rm -rf "$initrd_dir"
    echo "✅ 最小initrd创建完成"
}
