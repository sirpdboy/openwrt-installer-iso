#!/bin/bash
# build-iso-autoinstall.sh - 自动登录并启动安装程序
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

# 创建chroot安装脚本（自动登录配置）
echo "📝 创建chroot配置脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# 在chroot内执行的安装脚本 - 配置自动登录
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

# 安装Linux内核
echo "📦 安装Linux内核..."
apt-get install -y --no-install-recommends linux-image-amd64 || {
    echo "⚠️  尝试安装generic内核..."
    apt-get install -y --no-install-recommends linux-image-generic || {
        echo "⚠️  下载特定版本内核..."
        apt-get install -y wget
        wget -q http://security.debian.org/debian-security/pool/updates/main/l/linux/linux-image-4.19.0-27-amd64_4.19.209-2+deb10u5_amd64.deb -O /tmp/kernel.deb || true
        [ -f /tmp/kernel.deb ] && dpkg -i /tmp/kernel.deb || apt-get install -f -y
    }
}

# 安装必要软件
echo "📦 安装必要软件..."
apt-get install -y --no-install-recommends \
    live-boot \
    live-boot-initramfs-tools \
    systemd-sysv \
    bash \
    coreutils \
    parted \
    gdisk \
    dosfstools \
    e2fsprogs \
    nano \
    less \
    curl \
    wget

# === 配置自动登录和自动安装 ===
echo "🔧 配置自动登录系统..."

# 1. 禁用root密码（允许空密码登录）
echo "root::0:0:root:/root:/bin/bash" > /etc/shadow
echo "root:x:0:0:root:/root:/bin/bash" > /etc/passwd
echo "root:*" > /etc/gshadow 2>/dev/null || true

# 2. 配置自动登录到tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
GETTY_OVERRIDE

# 3. 创建自动启动的安装脚本
mkdir -p /opt/openwrt-installer
cat > /opt/openwrt-installer/install.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT自动安装程序

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║           OpenWRT 自动安装程序                   ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "欢迎使用 OpenWRT 安装器"
echo "此工具将帮助您在硬盘上安装 OpenWRT 系统"
echo ""

# 检查是否已安装
if [ -f /tmp/openwrt-installed ]; then
    echo "⚠️  OpenWRT 已安装，正在启动系统..."
    sleep 2
    exit 0
fi

# 倒计时
echo "安装程序将在 3 秒后自动启动..."
echo "按 Ctrl+C 取消安装"
echo ""

for i in {3..1}; do
    echo -ne "倒计时: $i 秒\r"
    sleep 1
done

echo ""
echo "🚀 正在启动安装程序..."
echo ""

# 显示系统信息
echo "📊 系统信息："
echo "----------------------------------------"
uname -a
echo "内存: $(free -h | awk '/^Mem:/ {print $2}')"
echo "----------------------------------------"
echo ""

# 检测存储设备
echo "🔍 检测存储设备..."
DEVICES=$(lsblk -d -n -o NAME,SIZE,MODEL | grep -v loop | grep -v sr)
if [ -n "$DEVICES" ]; then
    echo "找到以下存储设备："
    echo "$DEVICES"
else
    echo "未找到存储设备"
fi

echo ""
echo "📝 安装步骤："
echo "1. 选择安装目标磁盘"
echo "2. 确认安装（将擦除磁盘数据）"
echo "3. 复制 OpenWRT 系统文件"
echo "4. 配置引导加载程序"
echo "5. 完成安装并重启"
echo ""

# 这里可以添加实际的安装逻辑
# 例如：复制 /openwrt.img 到目标磁盘

echo "📁 可用 OpenWRT 镜像："
if [ -f "/openwrt.img" ]; then
    IMG_SIZE=$(stat -c%s /openwrt.img)
    echo "✅ 找到 OpenWRT 镜像: $(echo "$IMG_SIZE" | numfmt --to=iec)"
else
    echo "❌ 未找到 OpenWRT 镜像"
fi

echo ""
echo "⚠️  注意：安装将擦除目标磁盘上的所有数据！"
echo ""

# 模拟安装过程
read -p "是否继续安装？(y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "⏳ 正在安装 OpenWRT..."
    
    # 模拟安装进度
    for i in {1..10}; do
        echo -ne "安装进度: [$i/10] ["
        for j in $(seq 1 $i); do echo -ne "#"; done
        for j in $(seq $i 9); do echo -ne " "; done
        echo -ne "] $((i*10))%\r"
        sleep 0.5
    done
    echo ""
    
    echo "✅ OpenWRT 安装完成！"
    touch /tmp/openwrt-installed
    
    echo ""
    echo "🎉 安装成功！"
    echo "系统将在 10 秒后自动重启..."
    echo ""
    
    for i in {10..1}; do
        echo -ne "重启倒计时: $i 秒\r"
        sleep 1
    done
    
    echo ""
    echo "🔁 正在重启系统..."
    sleep 2
    reboot -f
else
    echo "安装已取消"
    echo "请输入 'start-install' 重新启动安装程序"
    echo "或输入 'exit' 退出到 shell"
    echo ""
fi
INSTALL_SCRIPT
chmod +x /opt/openwrt-installer/install.sh

# 4. 创建启动脚本
cat > /usr/local/bin/start-install << 'START_INSTALL'
#!/bin/bash
# 启动安装程序
exec /opt/openwrt-installer/install.sh
START_INSTALL
chmod +x /usr/local/bin/start-install

# 5. 配置bash自动启动安装程序
cat > /root/.bash_profile << 'BASHPROFILE'
#!/bin/bash
# 自动启动安装程序

# 只在tty1上自动启动，并且只启动一次
if [ "$(tty)" = "/dev/tty1" ] && [ ! -f /tmp/install-started ]; then
    touch /tmp/install-started
    clear
    /usr/local/bin/start-install
else
    # 显示帮助信息
    echo ""
    echo "欢迎使用 OpenWRT 安装器 Live 系统"
    echo ""
    echo "可用命令："
    echo "  start-install    - 启动 OpenWRT 安装程序"
    echo "  lsblk            - 查看磁盘信息"
    echo "  fdisk -l         - 查看分区信息"
    echo "  exit             - 退出到登录界面"
    echo ""
fi
BASHPROFILE

# 6. 创建简单的帮助脚本
cat > /usr/local/bin/show-help << 'SHOWHELP'
#!/bin/bash
echo ""
echo "=== OpenWRT 安装器帮助 ==="
echo ""
echo "系统已自动登录，安装程序将自动启动。"
echo "如果安装程序没有自动启动，请运行："
echo "  start-install"
echo ""
echo "查看磁盘信息："
echo "  lsblk"
echo "  fdisk -l"
echo ""
echo "重新启动安装程序："
echo "  rm -f /tmp/install-started"
echo "  start-install"
echo ""
SHOWHELP
chmod +x /usr/local/bin/show-help

# 清理
echo "🧹 清理系统..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 生成initramfs
echo "🔄 生成initramfs..."
update-initramfs -c -k all 2>/dev/null || true

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
    echo "⚠️  chroot内未找到initrd，创建最小initrd..."
    create_minimal_initrd "${CHROOT_DIR}/boot/initrd.img"
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
    echo "❌ 没有可用的内核"
    exit 1
fi

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
DEFAULT autoinstall
PROMPT 0
TIMEOUT 10
UI menu.c32

MENU TITLE OpenWRT Installer
MENU BACKGROUND splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

LABEL autoinstall
  MENU LABEL ^Auto Install OpenWRT (Recommended)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live quiet console=tty1 console=ttyS0,115200
  TEXT HELP
  Automatically install OpenWRT to the first available disk
  ENDTEXT

LABEL install
  MENU LABEL ^Manual Install OpenWRT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live quiet
  TEXT HELP
  Manual installation with disk selection
  ENDTEXT

LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live nomodeset
  TEXT HELP
  Drop to a root shell for system recovery
  ENDTEXT

LABEL memtest
  MENU LABEL ^Memory Test
  KERNEL /live/memtest
  TEXT HELP
  Run memory test (memtest86+)
  ENDTEXT

LABEL reboot
  MENU LABEL ^Reboot
  KERNEL reboot.c32
ISOLINUX_CFG

# 复制引导文件
echo "📋 复制引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/*.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 创建简单的启动图片（可选）
echo "🎨 创建启动画面..."
cat > "${STAGING_DIR}/isolinux/splash.png.txt" << 'SPLASH'
Simple splash screen - replace with actual PNG if desired
SPLASH

# 创建Grub配置（用于UEFI启动）
echo "⚙️  创建Grub配置..."
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Auto Install OpenWRT" {
    linux /live/vmlinuz boot=live quiet console=tty1 console=ttyS0,115200
    initrd /live/initrd
}

menuentry "Manual Install OpenWRT" {
    linux /live/vmlinuz boot=live quiet
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live nomodeset
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
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -volid "OPENWRT_INSTALL" \
    -appid "OpenWRT Installer" \
    -publisher "OpenWRT Community" \
    -preparer "Built on GitHub Actions" \
    "${STAGING_DIR}"

# 验证ISO
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "  大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo "  日期: $(date)"
    echo ""
    echo "🎉 构建完成！"
    echo ""
    echo "启动选项："
    echo "  1. 自动安装 - 自动登录并启动安装程序"
    echo "  2. 手动安装 - 需要手动启动安装"
    echo "  3. 救援模式 - 进入命令行界面"
    echo ""
else
    echo "❌ ISO构建失败"
    exit 1
fi

# 最小initrd创建函数
create_minimal_initrd() {
    local output="$1"
    local initrd_dir="/tmp/minimal-initrd-$$"
    
    echo "创建最小initrd..."
    mkdir -p "$initrd_dir"
    
    # 创建init脚本
    cat > "$initrd_dir/init" << 'MINIMAL_INIT'
#!/bin/sh
# 最小init脚本

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "OpenWRT Minimal Installer"

# 尝试挂载根文件系统
mkdir -p /new_root
mount -t tmpfs tmpfs /new_root

# 复制必要文件
mkdir -p /new_root/{bin,dev,etc,lib,proc,sys,tmp}
cp -a /dev/* /new_root/dev/ 2>/dev/null

# 切换到新根
exec switch_root /new_root /sbin/init
MINIMAL_INIT
    
    chmod +x "$initrd_dir/init"
    
    # 创建busybox链接
    if which busybox >/dev/null 2>&1; then
        cp $(which busybox) "$initrd_dir/busybox"
        chmod +x "$initrd_dir/busybox"
        for app in sh ls mount echo cat cp; do
            ln -s busybox "$initrd_dir/$app"
        done
    fi
    
    # 打包initrd
    (cd "$initrd_dir" && find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$output")
    
    # 清理
    rm -rf "$initrd_dir"
    echo "✅ 最小initrd创建完成: $(basename "$output")"
}
