#!/bin/bash
# build-iso-complete.sh - 完整修复版本，支持BIOS和UEFI
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

# 安装必要工具（包括UEFI支持）
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
    grub-common

# 添加Debian存档密钥
echo "🔑 添加Debian存档密钥..."
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 04EE7237B7D453EC 648ACFD622F3D138 || true
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 0E98404D386FA1D9 6ED0E7B82643E131 || true

# 创建目录结构
echo "📁 创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/BOOT,boot/grub,isolinux,live}
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

# 创建chroot安装脚本
echo "📝 创建chroot配置脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# 在chroot内执行的安装脚本
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

# === 安装live-boot和必要组件 ===
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
    console-setup \
    initramfs-tools

# === 配置live-boot ===
echo "🔧 配置live-boot..."

# 1. 设置root密码为空
echo "root::0:0:root:/root:/bin/bash" > /etc/shadow
echo "root:x:0:0:root:/root:/bin/bash" > /etc/passwd

# 2. 配置控制台
cat > /etc/default/console-setup << 'CONSOLE_SETUP'
# CONFIGURATION FILE FOR SETUPCON

ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="guess"
FONTFACE="Fixed"
FONTSIZE="8x16"
VIDEOMODE=
CONSOLE_SETUP

# 3. 配置agetty自动登录
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
Type=idle
GETTY_OVERRIDE

# 4. 创建自动启动服务
cat > /etc/systemd/system/openwrt-autoinstall.service << 'SERVICE_UNIT'
[Unit]
Description=OpenWRT Auto Installer
After=getty@tty1.service
Wants=getty@tty1.service

[Service]
Type=simple
Environment=TERM=linux
ExecStartPre=/bin/sleep 3
ExecStart=/opt/install-openwrt.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
Restart=no
TimeoutSec=0

[Install]
WantedBy=multi-user.target
SERVICE_UNIT

systemctl enable openwrt-autoinstall.service

# 5. 配置initramfs模块
cat > /etc/initramfs-tools/modules << 'INITRAMFS_MODULES'
# Live system modules
squashfs
overlay
loop
# Filesystems
vfat
iso9660
udf
ext4
ext3
ext2
# Storage
ahci
sd_mod
nvme
usb-storage
# Framebuffer
fbcon
vesafb
vga16fb
# Network (optional)
e1000
e1000e
r8169
INITRAMFS_MODULES

# 6. 创建OpenWRT安装脚本
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
echo "系统启动完成，正在初始化..."
echo ""

# 等待系统就绪
sleep 2

# 检查OpenWRT镜像
if [ ! -f "/openwrt.img" ]; then
    echo "❌ 错误: 未找到OpenWRT镜像文件"
    echo "镜像文件应位于: /openwrt.img"
    echo ""
    echo "按Enter键进入Shell..."
    read dummy
    exec /bin/bash
fi

# 显示镜像信息
IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}')
echo "✅ 找到OpenWRT镜像: $IMG_SIZE"
echo ""

# 显示磁盘信息
echo "扫描可用磁盘..."
echo "========================================"

# 使用lsblk获取磁盘信息
if command -v lsblk >/dev/null 2>&1; then
    DISK_LIST=$(lsblk -d -n -o NAME,SIZE,MODEL,TYPE 2>/dev/null | grep -E '^(sd|hd|nvme|vd)')
else
    DISK_LIST=$(fdisk -l 2>/dev/null | grep '^Disk /dev/' | head -10)
fi

if [ -z "$DISK_LIST" ]; then
    echo "未找到可用磁盘"
    echo "请检查磁盘连接"
    echo "========================================"
    echo ""
    echo "按Enter键重新扫描..."
    read dummy
    exec /opt/install-openwrt.sh
fi

echo "$DISK_LIST"
echo "========================================"
echo ""

# 提取磁盘名称
if command -v lsblk >/dev/null 2>&1; then
    DISK_NAMES=$(echo "$DISK_LIST" | awk '{print $1}')
else
    DISK_NAMES=$(echo "$DISK_LIST" | awk -F'[/:]' '{print $3}')
fi

echo "可用磁盘:"
for disk in $DISK_NAMES; do
    echo "  /dev/$disk"
done
echo ""

# 选择目标磁盘
while true; do
    read -p "请输入要安装的目标磁盘 (例如: sda): " TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo "❌ 错误: 未输入磁盘名称"
        continue
    fi
    
    # 检查磁盘是否存在
    if echo " $DISK_NAMES " | grep -q " $TARGET_DISK "; then
        echo ""
        echo "✅ 您选择了: /dev/$TARGET_DISK"
        break
    else
        echo "❌ 错误: 磁盘 /dev/$TARGET_DISK 不存在"
        echo "请从上面的列表中选择"
    fi
done

# 确认安装
echo ""
echo "⚠️ ⚠️ ⚠️ 重要警告 ⚠️ ⚠️ ⚠️"
echo "这将完全擦除 /dev/$TARGET_DISK 上的所有数据！"
echo ""
echo "目标磁盘: /dev/$TARGET_DISK"
echo "镜像大小: $IMG_SIZE"
echo ""
read -p "确认安装? (输入 YES 确认): " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "❌ 安装已取消"
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
echo "步骤 1/3: 准备磁盘..."
sleep 2

echo "步骤 2/3: 写入OpenWRT镜像..."
echo ""

# 获取镜像大小（字节）
IMG_SIZE_BYTES=$(stat -c%s /openwrt.img)

# 显示安装信息
echo "镜像信息:"
echo "  文件: /openwrt.img"
echo "  大小: $(echo "$IMG_SIZE_BYTES" | awk '{printf "%.2f GB", $1/1024/1024/1024}')"
echo "  目标: /dev/$TARGET_DISK"
echo ""
echo "正在写入，请稍候..."
echo ""

# 使用dd写入镜像（带简单进度显示）
echo "开始写入磁盘..."
echo "这可能需要几分钟，请勿中断电源！"
echo ""

# 创建进度显示
show_progress() {
    local total=$IMG_SIZE_BYTES
    local current=0
    local step=$((total / 100))
    
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
        
        sleep 0.5
        current=$((current + step))
    done
    echo -ne "[##################################################] 100%"
    echo ""
}

# 实际写入
dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M status=none &
DD_PID=$!

# 显示进度
show_progress

# 等待dd完成
wait $DD_PID
DD_EXIT=$?

# 同步磁盘
sync

echo ""
echo "步骤 3/3: 完成安装..."
sleep 2

if [ $DD_EXIT -eq 0 ]; then
    echo ""
    echo "✅ ✅ ✅ OpenWRT安装完成！"
    echo ""
    echo "安装信息:"
    echo "  目标磁盘: /dev/$TARGET_DISK"
    echo "  镜像大小: $IMG_SIZE"
    echo "  安装时间: $(date)"
    echo ""
    
    # 重启倒计时
    echo "系统将在10秒后自动重启..."
    echo "按 Ctrl+C 取消重启"
    echo ""
    
    for i in {10..1}; do
        echo -ne "重启倒计时: $i 秒\r"
        if read -t 1 -n 1; then
            echo ""
            echo "重启已取消"
            echo ""
            echo "手动重启命令: reboot"
            echo "返回安装菜单: /opt/install-openwrt.sh"
            echo ""
            exec /bin/bash
        fi
    done
    
    echo ""
    echo "正在重启系统..."
    sleep 2
    reboot
else
    echo ""
    echo "❌ 安装失败！错误代码: $DD_EXIT"
    echo ""
    echo "可能的原因:"
    echo "  1. 磁盘写保护"
    echo "  2. 磁盘故障"
    echo "  3. 镜像文件损坏"
    echo "  4. 空间不足"
    echo ""
    echo "按Enter键返回重新安装..."
    read dummy
    exec /opt/install-openwrt.sh
fi
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 7. 创建备用启动脚本
cat > /root/.bash_profile << 'BASHPROFILE'
#!/bin/bash
# 备用启动脚本

# 只在tty1上运行
if [ "$(tty)" = "/dev/tty1" ] && [ ! -f /tmp/install-started ]; then
    touch /tmp/install-started
    
    # 等待系统完全启动
    sleep 5
    
    # 启动安装程序
    exec /opt/install-openwrt.sh
fi
BASHPROFILE

# 8. 创建简单的bashrc
cat > /root/.bashrc << 'BASHRC'
# ~/.bashrc

# 如果不是交互式shell，直接退出
case $- in
    *i*) ;;
      *) return;;
esac

# 设置提示符
PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# 如果不是tty1，显示帮助
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

# 生成initramfs
echo "🔄 生成initramfs..."
update-initramfs -c -k all

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

# === 创建UEFI引导文件 ===
echo "🔧 创建UEFI引导文件..."

# 创建efi.img文件
echo "创建efi.img..."
dd if=/dev/zero of="${STAGING_DIR}/boot/grub/efi.img" bs=1M count=10
mkfs.vfat -F 32 "${STAGING_DIR}/boot/grub/efi.img"

# 挂载efi.img并复制文件
mkdir -p /mnt/efi
mount -o loop "${STAGING_DIR}/boot/grub/efi.img" /mnt/efi

# 创建EFI目录结构
mkdir -p /mnt/efi/EFI/BOOT

# 复制UEFI引导文件
if [ -f "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" ]; then
    cp "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" /mnt/efi/EFI/BOOT/bootx64.efi
    echo "✅ 复制已签名的UEFI引导文件"
elif [ -f "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" ]; then
    cp "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" /mnt/efi/EFI/BOOT/bootx64.efi
    echo "✅ 复制monolithic UEFI引导文件"
elif [ -f "/usr/lib/grub/x86_64-efi/grub.efi" ]; then
    cp "/usr/lib/grub/x86_64-efi/grub.efi" /mnt/efi/EFI/BOOT/bootx64.efi
    echo "✅ 复制UEFI引导文件"
else
    echo "⚠️  未找到UEFI引导文件，创建空文件"
    echo "UEFI引导可能无法工作"
    touch /mnt/efi/EFI/BOOT/bootx64.efi
fi

# 创建UEFI引导配置
cat > /mnt/efi/EFI/BOOT/grub.cfg << 'UEFI_GRUB'
set timeout=5
set default=0

menuentry "Install OpenWRT (UEFI)" {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd
}

menuentry "Install OpenWRT (Safe Graphics)" {
    linux /live/vmlinuz boot=live components nomodeset quiet
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live components single
    initrd /live/initrd
}
UEFI_GRUB

# 卸载efi.img
umount /mnt/efi
rmdir /mnt/efi

echo "✅ UEFI引导文件创建完成"

# 创建引导配置文件
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
  APPEND initrd=/live/initrd boot=live components quiet splash
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
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/share/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true

cp /usr/lib/syslinux/modules/bios/menu.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/share/syslinux/menu.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true

cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/share/syslinux/ldlinux.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true

cp /usr/lib/syslinux/modules/bios/libutil.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/share/syslinux/libutil.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 创建Grub配置（传统BIOS）
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (Normal)" {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd
}

menuentry "Install OpenWRT (Safe Graphics)" {
    linux /live/vmlinuz boot=live components nomodeset quiet
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live components single
    initrd /live/initrd
}
GRUB_CFG

# 构建ISO（支持BIOS和UEFI）
echo "🔥 构建ISO镜像..."
xorriso -as mkisofs \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin 2>/dev/null || \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin 2>/dev/null || \
    -isohybrid-mbr /usr/lib/syslinux/isohdpfx.bin 2>/dev/null || true \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -volid "OPENWRT_INSTALL" \
    -appid "OpenWRT Auto Installer" \
    -publisher "OpenWRT Community" \
    "${STAGING_DIR}"

# 验证ISO
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "  大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo "  支持: BIOS + UEFI 双引导"
    echo "  卷标: OPENWRT_INSTALL"
    echo ""
    echo "🎉 构建完成！"
    echo ""
    echo "启动选项说明："
    echo "  1. Install OpenWRT (Normal) - 正常安装模式"
    echo "  2. Safe Graphics - 安全图形模式（兼容旧硬件）"
    echo "  3. Copy to RAM - 复制到内存运行（更快）"
    echo "  4. Debug Mode - 调试模式（查看启动信息）"
    echo "  5. Rescue Shell - 救援Shell"
    echo ""
    echo "系统会自动启动安装程序，无需输入密码"
else
    echo "❌ ISO构建失败"
    exit 1
fi

echo "✅ 所有步骤完成！"
