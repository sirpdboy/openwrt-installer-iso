#!/bin/bash
# build-iso-initramfs-fixed.sh - 修复initramfs挂载问题和自动登录
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
    live-boot-initramfs-tools \
    git

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

# 安装基本系统
echo "📦 安装基本系统..."
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    linux-headers-amd64 \
    live-boot \
    live-boot-initramfs-tools \
    live-tools \
    systemd \
    systemd-sysv \
    systemd-timesyncd \
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
    console-setup \
    locales \
    nano \
    less \
    iputils-ping \
    net-tools \
    sudo \
    kmod \
    udev \
    initramfs-tools-core

# 确保内核模块目录存在
echo "🔧 配置内核模块..."
# 获取已安装的内核版本
KERNEL_VERSION=$(dpkg -l | grep 'linux-image-' | grep -v dbg | head -1 | awk '{print $2}' | cut -d'-' -f3-)
echo "检测到内核版本: $KERNEL_VERSION"

if [ -n "$KERNEL_VERSION" ]; then
    # 创建内核模块目录
    mkdir -p /lib/modules/${KERNEL_VERSION}
    
    # 复制内核模块（如果存在）
    if [ -d /usr/lib/modules/${KERNEL_VERSION} ]; then
        cp -r /usr/lib/modules/${KERNEL_VERSION}/* /lib/modules/${KERNEL_VERSION}/ 2>/dev/null || true
    fi
fi

# 安装额外的内核模块
echo "📦 安装额外内核模块..."
apt-get install -y --no-install-recommends \
    firmware-linux-free \
    firmware-linux-nonfree \
    firmware-misc-nonfree \
    irqbalance \
    hwdata \
    pciutils \
    usbutils
    

echo "🔄 准备内核模块..."
# 确保depmod使用正确的内核版本
if [ -z "$KERNEL_VERSION" ]; then
    # 尝试从/boot查找
    KERNEL_VERSION=$(ls /boot/vmlinuz-* 2>/dev/null | head -1 | sed 's|/boot/vmlinuz-||')
fi

if [ -n "$KERNEL_VERSION" ]; then
    echo "使用内核版本: $KERNEL_VERSION"
    
    # 创建必要的符号链接
    ln -sf /boot/vmlinuz-${KERNEL_VERSION} /boot/vmlinuz 2>/dev/null || true
    ln -sf /boot/initrd.img-${KERNEL_VERSION} /boot/initrd.img 2>/dev/null || true
    
    # 复制所有内核模块
    if [ ! -d "/lib/modules/${KERNEL_VERSION}" ]; then
        echo "⚠️  内核模块目录不存在，创建并初始化..."
        mkdir -p "/lib/modules/${KERNEL_VERSION}"
        
        # 安装基础模块
        apt-get install -y --no-install-recommends \
            linux-modules-${KERNEL_VERSION} \
            linux-modules-extra-${KERNEL_VERSION} 2>/dev/null || true
    fi
fi

# 设置locale
echo "🌐 配置locale..."
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# === 关键：配置自动登录和自动启动 ===
echo "🔧 配置自动登录和启动..."

# 1. 设置root密码为空（允许无密码登录）
usermod -p '*' root
echo 'root:x:0:0:root:/root:/bin/bash' > /etc/passwd
echo 'root::::::::' > /etc/shadow

# 2. 创建自动启动服务
cat > /etc/systemd/system/autoinstall.service << 'AUTOINSTALL_SERVICE'
[Unit]
Description=OpenWRT Auto Installer
After=getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/start-installer.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
AUTOINSTALL_SERVICE

# 3. 创建启动脚本
cat > /opt/start-installer.sh << 'START_SCRIPT'
#!/bin/bash
# 启动OpenWRT安装程序

# 等待控制台就绪
sleep 2

# 清屏
clear

# 显示欢迎信息
echo ""
echo "========================================"
echo "      OpenWRT 自动安装系统"
echo "========================================"
echo ""
echo "系统启动完成，正在启动安装程序..."
echo ""

# 等待网络（如果需要）
sleep 1

# 执行安装程序
exec /opt/install-openwrt.sh
START_SCRIPT
chmod +x /opt/start-installer.sh

# 4. 禁用getty@tty1.service，用我们的服务替代
systemctl disable getty@tty1.service || true
systemctl enable autoinstall.service

# 5. 配置agetty备用方案
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
GETTY_OVERRIDE

# === 配置live-boot ===
echo "🔧 配置live-boot..."

# 创建live-boot配置
mkdir -p /etc/live/boot
cat > /etc/live/boot.conf << 'LIVE_BOOT'
LIVE_BOOT=live-boot
LIVE_MEDIA=cdrom
LIVE_CONFIG=noautologin
PERSISTENCE=
BOOT_OPTIONS="boot=live components quiet splash"
LIVE_BOOT

# 配置initramfs
cat > /etc/initramfs-tools/conf.d/live << 'INITRAMFS_CONF'
export LIVE_BOOT=live-boot
export LIVE_MEDIA=cdrom
export NFSROOT=auto
export BOOT_OPTIONS="boot=live components quiet splash"
INITRAMFS_CONF

# === 创建OpenWRT安装脚本 ===
echo "📝 创建安装脚本..."
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT自动安装脚本

# 设置环境
export TERM=linux
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# 清屏函数
clear_screen() {
    printf "\033c"
}

# 显示标题
show_title() {
    clear_screen
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║           OpenWRT 一键安装程序                   ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
}

# 检查OpenWRT镜像
check_openwrt_image() {
    if [ ! -f "/openwrt.img" ]; then
        show_title
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
}

# 显示磁盘列表
show_disks() {
    echo "扫描可用磁盘..."
    echo "========================================"
    
    # 使用lsblk显示磁盘信息
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -n -o NAME,SIZE,MODEL,TYPE | grep -v loop
    else
        fdisk -l 2>/dev/null | grep '^Disk /dev/' | head -10
    fi
    
    echo "========================================"
    echo ""
}

# 获取磁盘列表
get_disk_list() {
    local disks=""
    if command -v lsblk >/dev/null 2>&1; then
        disks=$(lsblk -d -n -o NAME | grep -E '^(sd|hd|nvme|vd)')
    else
        disks=$(fdisk -l 2>/dev/null | grep '^Disk /dev/' | awk -F'[/:]' '{print $3}' | sort | uniq)
    fi
    echo "$disks"
}

# 选择磁盘
select_disk() {
    local disks=$(get_disk_list)
    local selected_disk=""
    
    while true; do
        show_title
        check_openwrt_image
        show_disks
        
        echo "可用磁盘:"
        for disk in $disks; do
            echo "  /dev/$disk"
        done
        echo ""
        
        read -p "请输入目标磁盘名称 (如: sda 或 nvme0n1): " TARGET_DISK
        
        if [ -z "$TARGET_DISK" ]; then
            echo "❌ 请输入磁盘名称"
            sleep 2
            continue
        fi
        
        # 检查磁盘是否存在
        if echo " $disks " | grep -q " $TARGET_DISK "; then
            selected_disk="$TARGET_DISK"
            break
        else
            echo "❌ 磁盘 /dev/$TARGET_DISK 不存在"
            sleep 2
        fi
    done
    
    echo "$selected_disk"
}

# 确认安装
confirm_installation() {
    local disk="$1"
    
    show_title
    echo "⚠️ ⚠️ ⚠️  重要警告  ⚠️ ⚠️ ⚠️"
    echo ""
    echo "这将完全擦除 /dev/$disk 上的所有数据！"
    echo ""
    echo "目标磁盘: /dev/$disk"
    echo "OpenWRT镜像大小: $(ls -lh /openwrt.img | awk '{print $5}')"
    echo ""
    echo "请确认:"
    echo "1. 已备份重要数据"
    echo "2. 确定要安装到 /dev/$disk"
    echo ""
    
    read -p "确认安装? (输入 YES 确认): " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        return 1
    fi
    return 0
}

# 执行安装
perform_installation() {
    local disk="$1"
    
    show_title
    echo "🚀 开始安装 OpenWRT"
    echo "目标磁盘: /dev/$disk"
    echo ""
    
    # 显示进度
    echo "正在准备磁盘..."
    sleep 1
    
    echo "正在写入OpenWRT镜像..."
    echo ""
    
    # 获取镜像大小
    IMG_BYTES=$(stat -c%s /openwrt.img 2>/dev/null || echo "0")
    if [ "$IMG_BYTES" -gt 0 ]; then
        IMG_MB=$((IMG_BYTES / 1024 / 1024))
        echo "镜像信息:"
        echo "  大小: ${IMG_MB} MB"
        echo "  目标: /dev/$disk"
        echo ""
    fi
    
    # 使用dd写入
    echo "正在写入，请勿中断电源..."
    echo "这可能需要几分钟时间，请耐心等待..."
    echo ""
    
    # 显示进度条的函数
    show_progress() {
        local pid=$1
        local delay=0.5
        local spinstr='|/-\'
        while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
            local temp=${spinstr#?}
            printf "  [%c] 正在写入...\r" "$spinstr"
            local spinstr=$temp${spinstr%"$temp"}
            sleep $delay
        done
        printf "                   \r"
    }
    
    # 开始写入
    if command -v pv >/dev/null 2>&1; then
        # 使用pv显示进度
        pv -pet /openwrt.img | dd of="/dev/$disk" bs=4M status=none
    else
        # 使用dd并显示简单进度
        echo "开始写入..."
        dd if=/openwrt.img of="/dev/$disk" bs=4M status=progress 2>&1 || \
        dd if=/openwrt.img of="/dev/$disk" bs=4M 2>&1 | tail -1
    fi
    
    # 检查dd是否成功
    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ 写入完成！"
    else
        echo ""
        echo "❌ 写入失败，请检查磁盘状态"
        return 1
    fi
    
    # 同步磁盘
    sync
    sleep 2
    
    echo ""
    echo "🎉 OpenWRT安装成功！"
    echo ""
    echo "安装信息:"
    echo "  目标磁盘: /dev/$disk"
    echo "  镜像大小: $(ls -lh /openwrt.img | awk '{print $5}')"
    echo "  安装时间: $(date)"
    echo ""
    
    return 0
}

# 重启系统
reboot_system() {
    echo "系统将在10秒后自动重启..."
    echo "按任意键取消重启并进入Shell"
    echo ""
    
    for i in {10..1}; do
        echo -ne "重启倒计时: $i 秒\r"
        if read -t 1 -n 1; then
            echo ""
            echo "重启已取消"
            echo ""
            echo "可用命令:"
            echo "  重启系统: reboot"
            echo "  重新安装: /opt/install-openwrt.sh"
            echo "  Shell: bash"
            echo ""
            exec /bin/bash
        fi
    done
    
    echo ""
    echo "正在重启..."
    sleep 2
    reboot -f
}

# 主函数
main() {
    while true; do
        # 选择磁盘
        DISK=$(select_disk)
        
        # 确认安装
        if confirm_installation "$DISK"; then
            # 执行安装
            if perform_installation "$DISK"; then
                # 重启系统
                reboot_system
                break
            else
                echo ""
                echo "安装失败，请检查错误信息"
                echo "按Enter键重新开始..."
                read dummy
            fi
        else
            echo ""
            echo "安装已取消"
            echo "按Enter键重新开始..."
            read dummy
        fi
    done
}

# 执行主函数
main
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 创建简单的bash配置
cat > /root/.bashrc << 'BASHRC'
# ~/.bashrc

# 如果不是交互式shell，直接退出
case $- in
    *i*) ;;
      *) return;;
esac

PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# 检查是否在tty1上，如果是则启动安装程序
if [ "$(tty)" = "/dev/tty1" ]; then
    echo ""
    echo "启动OpenWRT安装程序..."
    sleep 2
    /opt/install-openwrt.sh
fi
BASHRC

# 清理
echo "🧹 清理系统..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# === 生成initramfs ===
echo "🔄 生成initramfs..."
# 确保必要的模块
echo "🔄 生成initramfs..."

# 获取实际的内核版本
ACTUAL_KERNEL=$(ls /lib/modules/ 2>/dev/null | head -1)
if [ -z "$ACTUAL_KERNEL" ]; then
    # 如果没有模块目录，尝试从/boot获取内核
    ACTUAL_KERNEL=$(basename $(ls /boot/vmlinuz-* 2>/dev/null | head -1) | sed 's/vmlinuz-//')
fi

if [ -n "$ACTUAL_KERNEL" ]; then
    echo "为内核生成initramfs: $ACTUAL_KERNEL"
    
    # 配置initramfs模块
    cat > /etc/initramfs-tools/modules << 'MODULES'
# 基础模块
loop
squashfs
overlay
# 文件系统
ext4
ext3
ext2
vfat
ntfs
iso9660
udf
# 存储控制器
ahci
sd_mod
nvme
usb-storage
uhci_hcd
ehci_pci
ehci_hcd
xhci_pci
xhci_hcd
# 网络（可选）
e1000
e1000e
r8169
# 显卡
fbcon
vesafb
vga16fb
MODULES
    
    # 更新initramfs配置
    cat > /etc/initramfs-tools/conf.d/live << 'INITRAMFS_LIVE'
export LIVE_BOOT=live-boot
export LIVE_MEDIA=cdrom
export NFSROOT=auto
export BOOT_OPTIONS="boot=live components quiet splash"
INITRAMFS_LIVE
    
    # 运行depmod（忽略错误）
    depmod -a ${ACTUAL_KERNEL} 2>/dev/null || true
    
    # 生成initramfs
    update-initramfs -c -k ${ACTUAL_KERNEL} -v
    
    # 检查是否生成成功
    if [ ! -f "/boot/initrd.img-${ACTUAL_KERNEL}" ]; then
        echo "⚠️  标准方法失败，尝试手动生成..."
        mkinitramfs -k -o /boot/initrd.img-${ACTUAL_KERNEL} ${ACTUAL_KERNEL} 2>/dev/null || true
    fi
    
    # 创建符号链接
    ln -sf /boot/initrd.img-${ACTUAL_KERNEL} /boot/initrd.img 2>/dev/null || true
    ln -sf /boot/vmlinuz-${ACTUAL_KERNEL} /boot/vmlinuz 2>/dev/null || true
    
else
    echo "❌ 无法确定内核版本，使用备用方案..."
    # 安装最小化内核
    apt-get install -y --no-install-recommends linux-image-4.19.0-20-amd64 2>/dev/null || true
    
    # 尝试生成通用initramfs
    update-initramfs -c 2>/dev/null || true
    
    # 如果还失败，创建一个最小化的initramfs
    if [ ! -f "/boot/initrd.img" ]; then
        echo "创建最小化initramfs..."
        cat > /tmp/mini-init.sh << 'MINI_INIT'
#!/bin/sh
# 最小化initramfs脚本

PREREQ=""
prereqs() { echo "$PREREQ"; }

case "$1" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

echo "Loading mini initramfs..."
sleep 2

# 挂载根文件系统
mkdir -p /newroot
mount -t tmpfs tmpfs /newroot

# 创建最小系统
mkdir -p /newroot/{bin,dev,etc,lib,proc,sys,tmp}
cp /bin/{bash,sh,mount,umount} /newroot/bin/ 2>/dev/null || true

# 切换到新根
exec switch_root /newroot /bin/bash
MINI_INIT
        
        # 创建简单的initramfs
        (cd /tmp && echo "mini-init" | cpio -H newc -o | gzip > /boot/initrd.img 2>/dev/null) || true
    fi
fi


if [ $? -ne 0 ]; then
    echo "⚠️  标准initramfs生成失败，尝试备用方法..."
    mkinitramfs -o /boot/initrd.img 2>/dev/null || true
fi

echo "✅ chroot配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/install-chroot.sh"

# 复制resolv.conf到chroot
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true

# 挂载必要的文件系统到chroot
echo "🔗 挂载文件系统到chroot..."
mount --bind /proc "${CHROOT_DIR}/proc"
mount --bind /sys "${CHROOT_DIR}/sys"
mount --bind /dev "${CHROOT_DIR}/dev"

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
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
umount "${CHROOT_DIR}/sys" 2>/dev/null || true
umount "${CHROOT_DIR}/dev" 2>/dev/null || true

# 检查内核和initramfs
echo "🔍 检查内核和initramfs..."
KERNEL_FILE=$(find "${CHROOT_DIR}/boot" -name "vmlinuz*" -type f 2>/dev/null | head -1)
INITRD_FILE=$(find "${CHROOT_DIR}/boot" -name "initrd*" -type f 2>/dev/null | head -1)

if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
    echo "✅ 找到内核: $KERNEL_FILE"
    cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
else
    echo "❌ 未找到内核"
    exit 1
fi

if [ -n "$INITRD_FILE" ] && [ -f "$INITRD_FILE" ]; then
    echo "✅ 找到initrd: $INITRD_FILE"
    cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"
else
    echo "❌ 未找到initrd"
    exit 1
fi

# 压缩chroot为squashfs（排除不必要的目录）
echo "📦 创建squashfs文件系统..."
EXCLUDE_DIRS="boot proc sys dev tmp run mnt media var/cache var/tmp var/log"
EXCLUDE_OPT=""
for dir in $EXCLUDE_DIRS; do
    EXCLUDE_OPT="$EXCLUDE_OPT -e $CHROOT_DIR/$dir"
done

if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp xz \
    -b 1M \
    -noappend \
    $EXCLUDE_OPT; then
    echo "✅ squashfs创建成功"
    echo "大小: $(ls -lh "${STAGING_DIR}/live/filesystem.squashfs" | awk '{print $5}')"
else
    echo "❌ squashfs创建失败"
    exit 1
fi

# 创建live文件夹结构
echo "🔧 创建live文件夹结构..."
mkdir -p "${STAGING_DIR}/live"
touch "${STAGING_DIR}/live/filesystem.squashfs-"

# 创建引导配置文件
echo "⚙️  创建引导配置..."
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT install
PROMPT 0
TIMEOUT 30
UI menu.c32

MENU TITLE OpenWRT Auto Installer
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std

LABEL install
  MENU LABEL ^Install OpenWRT (Auto Boot)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components toram=filesystem.squashfs quiet splash console=tty1 console=ttyS0,115200
  TEXT HELP
  Automatically boot and install OpenWRT
  ENDTEXT

LABEL install_nomodeset
  MENU LABEL Install OpenWRT (^Safe Graphics)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components nomodeset quiet console=tty1
  TEXT HELP
  Safe graphics mode for compatibility
  ENDTEXT

LABEL install_toram
  MENU LABEL Install OpenWRT (^Copy to RAM)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components toram quiet console=tty1
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
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 复制syslinux模块
if [ -d /usr/lib/syslinux/modules/bios ]; then
    cp /usr/lib/syslinux/modules/bios/*.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true
fi

# 创建memtest文件
touch "${STAGING_DIR}/live/memtest"

# 创建Grub配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=3
set default=0

menuentry "Install OpenWRT (Auto Boot)" {
    linux /live/vmlinuz boot=live components toram=filesystem.squashfs quiet splash console=tty1 console=ttyS0,115200
    initrd /live/initrd
}

menuentry "Install OpenWRT (Safe Graphics)" {
    linux /live/vmlinuz boot=live components nomodeset quiet console=tty1
    initrd /live/initrd
}

menuentry "Install OpenWRT (Copy to RAM)" {
    linux /live/vmlinuz boot=live components toram quiet console=tty1
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

# === 创建UEFI引导文件 ===
echo "🔧 创建UEFI引导文件..."
EFI_IMG_SIZE=64M
dd if=/dev/zero of="${STAGING_DIR}/boot/grub/efi.img" bs=1M count=64
mkfs.vfat -F 32 "${STAGING_DIR}/boot/grub/efi.img"

# 挂载并复制文件
mkdir -p /mnt/efi_tmp
if mount -o loop "${STAGING_DIR}/boot/grub/efi.img" /mnt/efi_tmp 2>/dev/null; then
    mkdir -p /mnt/efi_tmp/EFI/BOOT
    
    # 查找grub EFI文件
    GRUB_EFI_SOURCES=(
        "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed"
        "/usr/lib/grub/x86_64-efi/grub.efi"
        "/usr/lib/grub/efi/grub.efi"
        "/usr/lib/grub/x86_64-efi/monolithic/grub.efi"
    )
    
    for efi_file in "${GRUB_EFI_SOURCES[@]}"; do
        if [ -f "$efi_file" ]; then
            cp "$efi_file" /mnt/efi_tmp/EFI/BOOT/bootx64.efi
            echo "✅ 复制UEFI引导文件: $efi_file"
            break
        fi
    done
    
    # 复制grub模块
    mkdir -p /mnt/efi_tmp/EFI/BOOT/x86_64-efi
    if [ -d /usr/lib/grub/x86_64-efi ]; then
        cp -r /usr/lib/grub/x86_64-efi/* /mnt/efi_tmp/EFI/BOOT/x86_64-efi/ 2>/dev/null || true
    fi
    
    # 创建grub.cfg
    cat > /mnt/efi_tmp/EFI/BOOT/grub.cfg << 'UEFI_GRUB'
set timeout=3
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet splash console=tty1
    initrd /live/initrd
}

menuentry "Safe Graphics Mode" {
    linux /live/vmlinuz boot=live components nomodeset quiet console=tty1
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live components single
    initrd /live/initrd
}
UEFI_GRUB
    
    umount /mnt/efi_tmp
    rmdir /mnt/efi_tmp
    echo "✅ UEFI引导文件创建完成"
else
    echo "⚠️  无法创建UEFI引导文件，继续使用BIOS引导"
fi

# 构建ISO镜像
echo "🔥 构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output "$ISO_PATH" \
    "${STAGING_DIR}"

# 验证ISO
if [ -f "$ISO_PATH" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: $ISO_PATH"
    echo "  大小: $(ls -lh "$ISO_PATH" | awk '{print $5}')"
    echo "  卷标: OPENWRT_INSTALL"
    echo ""
    echo "🎉 构建完成！"
    echo ""
    echo "使用说明："
    echo "  1. 刻录ISO到U盘或光盘"
    echo "  2. 从U盘/光盘启动计算机"
    echo "  3. 系统将自动启动安装程序"
    echo "  4. 按照提示选择目标磁盘"
    echo "  5. 确认后自动刷入OpenWRT"
    echo ""
    echo "注意："
    echo "  • 安装会擦除目标磁盘所有数据"
    echo "  • 默认30秒后自动启动安装"
    echo "  • 按ESC键可显示引导菜单"
    echo ""
else
    echo "❌ ISO构建失败"
    exit 1
fi
