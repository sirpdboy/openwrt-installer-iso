#!/bin/bash
# build-openwrt-installer.sh - 构建OpenWRT自动安装ISO
set -e

echo "开始构建OpenWRT安装ISO..."
echo "========================================"

# 基础配置
WORK_DIR="${HOME}/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/chroot"
STAGING_DIR="${WORK_DIR}/staging"
OUTPUT_DIR="/output"
OPENWRT_IMG="/mnt/ezopwrt.img"
ISO_NAME="openwrt-autoinstall.iso"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查必要文件
log_info "检查必要文件..."
if [ ! -f "${OPENWRT_IMG}" ]; then
    log_error "找不到OpenWRT镜像: ${OPENWRT_IMG}"
    echo "请确保OpenWRT镜像文件存在"
    exit 1
fi

# 修复Debian buster源
log_info "配置Debian buster源..."
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
# deb http://archive.debian.org/debian buster-updates main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

# 安装必要工具
log_info "安装构建工具..."
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
    git \
    pv \
    file

# 添加Debian存档密钥
log_info "添加Debian存档密钥..."
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 04EE7237B7D453EC 648ACFD622F3D138 2>/dev/null || true
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 0E98404D386FA1D9 6ED0E7B82643E131 2>/dev/null || true

# 创建目录结构
log_info "创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/boot,boot/grub/x86_64-efi,isolinux,live}
mkdir -p "${OUTPUT_DIR}"

# 复制OpenWRT镜像
log_info "复制OpenWRT镜像..."
mkdir -p "${CHROOT_DIR}"
if cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img"; then
    log_success "OpenWRT镜像已复制"
else
    log_error "复制OpenWRT镜像失败"
    exit 1
fi

# 引导Debian最小系统
log_info "引导Debian最小系统..."
DEBIAN_MIRROR="http://archive.debian.org/debian"
if debootstrap --arch=amd64 --variant=minbase \
    buster "${CHROOT_DIR}" \
    "${DEBIAN_MIRROR}" 2>&1 | tee /tmp/debootstrap.log; then
    log_success "Debian最小系统引导成功"
else
    log_warning "第一次引导失败，尝试备用源..."
    DEBIAN_MIRROR="http://deb.debian.org/debian"
    if debootstrap --arch=amd64 --variant=minbase \
        buster "${CHROOT_DIR}" \
        "${DEBIAN_MIRROR}" 2>&1 | tee -a /tmp/debootstrap.log; then
        log_success "备用源引导成功"
    else
        log_error "debootstrap失败"
        cat /tmp/debootstrap.log
        exit 1
    fi
fi

# 创建chroot安装脚本
log_info "创建chroot配置脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# OpenWRT安装系统chroot配置脚本
set -e


# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

echo "openwrt-installer" > /etc/hostname

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# 配置DNS
cat > /etc/resolv.conf << 'RESOLV'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 208.67.222.222
RESOLV

echo Install security updates and apt-utils
apt-get update
apt-get -y install apt || true
apt-get -y upgrade

echo Set locale
apt-get -y install locales
sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
dpkg-reconfigure --frontend=noninteractive locales
update-locale LANG=en_US.UTF-8

echo Install packages
apt-get install -y --no-install-recommends linux-image-amd64 live-boot systemd-sysv
apt-get install -y parted openssh-server bash-completion cifs-utils curl dbus dosfstools firmware-linux-free gddrescue gdisk iputils-ping isc-dhcp-client less nfs-common ntfs-3g openssh-client open-vm-tools procps vim wimtools wget

echo Clean apt post-install
apt-get clean

echo Enable systemd-networkd as network manager
systemctl enable systemd-networkd

echo Set resolv.conf to use systemd-resolved
rm /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf



# === 配置自动登录和自动启动 ===
echo "配置自动登录和启动..."

# 1. 设置root无密码登录
usermod -p '*' root
cat > /etc/passwd << 'PASSWD'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin
sys:x:3:3:sys:/dev:/usr/sbin/nologin
PASSWD

cat > /etc/shadow << 'SHADOW'
root:*:18507:0:99999:7:::
daemon:*:18507:0:99999:7:::
bin:*:18507:0:99999:7:::
sys:*:18507:0:99999:7:::
SHADOW

systemctl enable ssh

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
# OpenWRT安装系统启动脚本

sleep 3
clear

cat << "WELCOME"

╔═══════════════════════════════════════════════════════╗
║       OpenWRT Auto Install System                     ║
╚═══════════════════════════════════════════════════════╝

System is starting up, please wait...
WELCOME
sleep 2
if [ ! -f "/openwrt.img" ]; then
    clear
    echo ""
    echo "❌ Error: OpenWRT image not found"
    echo ""
    echo "Image file should be at: /openwrt.img"
    echo ""
    echo "Press Enter to enter shell..."
    read
    exec /bin/bash
fi

exec /opt/install-openwrt.sh
START_SCRIPT
chmod +x /opt/start-installer.sh

systemctl enable autoinstall.service

mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
Type=idle
GETTY_OVERRIDE

cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'

#!/bin/bash

clear
cat << "EOF"

╔═══════════════════════════════════════════════════════╗
║               OpenWRT Auto Installer                  ║
╚═══════════════════════════════════════════════════════╝

EOF

echo ""
echo "Checking OpenWRT image..."
if [ ! -f "/openwrt.img" ]; then
    echo "❌ ERROR: OpenWRT image not found!"
    echo ""
    echo "Press Enter for shell..."
    read
    exec /bin/bash
fi

echo "✅ OpenWRT image found: $(ls -lh /openwrt.img | awk '{print $5}')"
echo ""

while true; do
    # 显示磁盘
    echo "Available disks:"
    echo "================="
    lsblk -d -n -o NAME,SIZE,MODEL | grep -E '^(sd|hd|nvme)' || echo "No disks found"
    echo "================="
    echo ""
    
    read -p "Enter target disk (e.g., sda): " DISK
    
    if [ -z "$DISK" ]; then
        echo "Please enter a disk name"
        continue
    fi
    
    if [ ! -b "/dev/$DISK" ]; then
        echo "❌ Disk /dev/$DISK not found!"
        continue
    fi
    
    # 确认
    echo ""
    echo "⚠️  WARNING: This will erase ALL data on /dev/$DISK!"
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        continue
    fi
    
    # 安装
    clear
    echo ""
    echo "Installing OpenWRT to /dev/$DISK..."
    echo ""

    if command -v pv >/dev/null 2>&1; then
        pv -pet /openwrt.img | dd of="/dev/$disk" bs=4M status=none oflag=sync
    else
        dd if=/openwrt.img of="/dev/$disk" bs=4M status=progress oflag=sync 2>&1 || \
        dd if=/openwrt.img of="/dev/$disk" bs=4M 2>&1 | tail -1
    fi
    sync
    echo ""
    echo "✅ Installation complete!"
    echo ""
    echo "System will reboot in 10 seconds..."
    echo "Press any key to cancel."
    
    for i in {10..1}; do
        echo -ne "Rebooting in $i seconds...\r"
        if read -t 1 -n 1; then
            echo ""
            echo "Reboot cancelled."
            echo "Type 'reboot' to restart."
            exec /bin/bash
        fi
    done
    
    reboot -f
done
INSTALL_SCRIPT



chmod +x /opt/install-openwrt.sh
# === 创建bash配置 ===
cat > /root/.bashrc << 'BASHRC'
# OpenWRT安装系统bash配置

# 如果不是交互式shell，直接退出
case $- in
    *i*) ;;
      *) return;;
esac

# 设置PS1
PS1='\[\e[1;32m\]\u@openwrt-installer\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# 别名
alias ll='ls -la'
alias l='ls -l'
alias cls='clear'

if [ "$(tty)" = "/dev/tty1" ]; then
    echo ""
    echo "Welcome to OpenWRT Installer System"
    echo ""
    echo "If installer doesn't start automatically, run:"
    echo "  /opt/install-openwrt.sh"
    echo ""
fi
BASHRC

echo Remove machine-id
rm /etc/machine-id

echo List installed packages
dpkg --get-selections|tee /packages.txt
# 清理
echo "🧹 清理系统..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*



echo "✅ chroot配置完成"
CHROOT_EOF

cat > $CHROOT_DIR/etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main contrib non-free
deb-src http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
deb-src http://archive.debian.org/debian-security buster/updates main
EOF

chmod +x "${CHROOT_DIR}/install-chroot.sh"

# 复制resolv.conf到chroot
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true

# 挂载必要的文件系统到chroot
log_info "Mounting dev / proc / sys"
mount -t proc none ${CHROOT_DIR}/proc
mount -o bind /dev ${CHROOT_DIR}/dev
mount -o bind /sys ${CHROOT_DIR}/sys

# 在chroot内执行安装脚本
log_info "在chroot内执行安装..."
if chroot "${CHROOT_DIR}" /bin/bash -c "/install-chroot.sh 2>&1 | tee /install.log"; then
    log_success "chroot安装完成"
else
    log_warning "chroot安装返回错误，继续处理..."
    if [ -f "${CHROOT_DIR}/install.log" ]; then
        echo "=== chroot安装日志 ==="
        tail -50 "${CHROOT_DIR}/install.log"
        echo "====================="
    fi
fi

echo Cleanup chroot
rm -v ${CHROOT_DIR}/install-chroot.sh
mv -v ${CHROOT_DIR}/packages.txt /output/packages.txt


echo Copy in systemd-networkd config

cat > ${CHROOT_DIR}/etc/systemd/network/99-dhcp-en.network <<EOF
[Match]
Name=e*

[Network]
DHCP=yes

[DHCP]
ClientIdentifier=mac
EOF

chown -v root:root ${CHROOT_DIR}/etc/systemd/network/99-dhcp-en.network
chmod -v 644 ${CHROOT_DIR}/etc/systemd/network/99-dhcp-en.network

echo Enable autologin

mkdir -p ${CHROOT_DIR}/etc/systemd/system/getty@tty1.service.d/
cat > ${CHROOT_DIR}/etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
Type=idle
GETTY_OVERRIDE

# 卸载chroot文件系统
log_info "卸载chroot文件系统..."
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
umount "${CHROOT_DIR}/sys" 2>/dev/null || true
umount "${CHROOT_DIR}/dev" 2>/dev/null || true

mkdir -p ${WORK_DIR}/{staging/{EFI/boot,boot/grub/x86_64-efi,isolinux,live},tmp}

echo Compress the chroot environment into a Squash filesystem.
# cp /mnt/armbian.img ${CHROOT_DIR}/mnt/
ls ${CHROOT_DIR}/mnt/
mksquashfs ${CHROOT_DIR} ${STAGING_DIR}/live/filesystem.squashfs -e boot

# 检查内核和initramfs
log_info "检查内核和initramfs..."
KERNEL_FILE=$(find "${CHROOT_DIR}/boot" -name "vmlinuz*" -type f 2>/dev/null | head -1)
INITRD_FILE=$(find "${CHROOT_DIR}/boot" -name "initrd*" -type f 2>/dev/null | head -1)

if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
    log_success "找到内核: $(basename $KERNEL_FILE)"
    cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
else
cp -v ${CHROOT_DIR}/boot/vmlinuz-* ${STAGING_DIR}/live/vmlinuz

    log_error "未找到内核文件"
fi

if [ -n "$INITRD_FILE" ] && [ -f "$INITRD_FILE" ]; then
    log_success "找到initrd: $(basename $INITRD_FILE)"
    cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"
else
cp -v ${CHROOT_DIR}/boot/initrd.img-* ${STAGING_DIR}/live/initrd
    log_error "未找到initrd文件"
fi

# 创建引导配置文件
log_info "创建引导配置..."
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT install
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE OpenWRT Auto Installer
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR hotsel       1;37;44 #ff000000 #20ffffff all
MENU COLOR hotkey       37;44   #ff000000 #20ffffff all

LABEL install
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live
  TEXT HELP
  Automatically start OpenWRT installer
  ENDTEXT

ISOLINUX_CFG

# 创建Grub配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
search --set=root --file /DEBIAN_CUSTOM
set timeout=5
set default=0
insmod efi_gop
insmod font
if loadfont ${prefix}/fonts/unicode.pf2
then
        insmod gfxterm
        set gfxmode=auto
        set gfxpayload=keep
        terminal_output gfxterm
fi

menuentry "Install OpenWRT (Auto Install)" {
    linux ($root)/live/vmlinuz boot=live
    initrd /live/initrd
}

GRUB_CFG

# 创建Grub配置
cat > "${WORK_DIR}/tmp/grub-standalone.cfg" << 'STAD_CFG'
search --set=root --file /DEBIAN_CUSTOM
set prefix=($root)/boot/grub/
configfile /boot/grub/grub.cfg

STAD_CFG
touch ${STAGING_DIR}/DEBIAN_CUSTOM



# 复制引导文件
log_info "复制引导文件..."
if [ -f /usr/lib/ISOLINUX/isolinux.bin ]; then
    cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/"
elif [ -f /usr/lib/syslinux/isolinux.bin ]; then
    cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/"
else
    log_warning "找不到isolinux.bin，尝试从包中提取"
    apt-get download syslinux-common 2>/dev/null || true
    dpkg -x syslinux-common*.deb /tmp/syslinux 2>/dev/null || true
    cp /tmp/syslinux/usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
fi

# 复制syslinux模块
if [ -d /usr/lib/syslinux/modules/bios ]; then
    cp /usr/lib/syslinux/modules/bios/*.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null
fi

cp -v -r /usr/lib/grub/x86_64-efi/* "${STAGING_DIR}/boot/grub/x86_64-efi/"
# 压缩chroot为squashfs
log_info "创建squashfs文件系统..."
EXCLUDE_LIST="boot/lost+found boot/*.old-dkms proc sys dev tmp run mnt media var/cache var/tmp var/log var/lib/apt/lists"
EXCLUDE_OPT=""
for item in $EXCLUDE_LIST; do
    EXCLUDE_OPT="$EXCLUDE_OPT -e $item"
done

if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp xz \
    -b 1M \
    -noappend \
    -no-recovery \
    -no-progress \
    $EXCLUDE_OPT 2>&1 | tee /tmp/mksquashfs.log; then
    SQUASHFS_SIZE=$(ls -lh "${STAGING_DIR}/live/filesystem.squashfs" | awk '{print $5}')
    log_success "squashfs创建成功: $SQUASHFS_SIZE"
else
    log_error "squashfs创建失败"
    cat /tmp/mksquashfs.log
    exit 1
fi

# 创建live文件夹结构
touch "${STAGING_DIR}/live/filesystem.squashfs-"

echo Make UEFI grub files
grub-mkstandalone --format=x86_64-efi --output=${WORK_DIR}/tmp/bootx64.efi --locales=""  --fonts="" "boot/grub/grub.cfg=$HOME/LIVE_BOOT/tmp/grub-standalone.cfg"


# === 创建UEFI引导文件 ===
log_info "创建UEFI引导文件..."
EFI_IMG_SIZE=32

cd ${WORK_DIR}/staging/EFI/boot
SIZE=`expr $(stat --format=%s ${WORK_DIR}/tmp/bootx64.efi) + 65536`
dd if=/dev/zero of=efiboot.img bs=$SIZE count=1
/sbin/mkfs.vfat efiboot.img
mmd -i efiboot.img efi efi/boot
mcopy -vi efiboot.img ${WORK_DIR}/tmp/bootx64.efi ::efi/boot/


# 构建ISO镜像
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# 检查xorriso版本
XORRISO_VERSION=$(xorriso --version 2>/dev/null | head -1 | grep -o '[0-9]\+\.[0-9]\+' | head -1)

XORRISO_CMD="xorriso -as mkisofs \
    -iso-level 3 \
    -output \"$ISO_PATH\" \
    -full-iso9660-filenames \
    -volid \"OPENWRT_INSTALL\" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-boot isolinux/isolinux.bin \
    --eltorito-catalog isolinux/isolinux.cat \
    -eltorito-alt-boot \
    -e /EFI/boot/efiboot.img \
    -isohybrid-gpt-basdat \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \

    -append_partition 2 0xef ${STAGING_DIR}/EFI/boot/efiboot.img \
    \"${STAGING_DIR}\""


log_info "执行构建命令..."
eval $XORRISO_CMD

# 验证ISO
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    ISO_MD5=$(md5sum "$ISO_PATH" | awk '{print $1}' | cut -c1-8)
    
    echo ""
    log_success "✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: $ISO_PATH"
    echo "  大小: $ISO_SIZE"
    echo "  MD5: $ISO_MD5"
    echo "  卷标: OPENWRT_INSTALL"
    echo ""
    echo "🎉 构建完成！"
    echo ""
    echo "使用说明："
    echo "  1. 刻录ISO到U盘: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress"
    echo "  2. 从U盘启动计算机"
    echo "  3. 系统自动启动安装程序"
    echo "  4. 选择目标磁盘并确认安装"
    echo "  5. 等待安装完成自动重启"
    echo ""
    echo "注意："
    echo "  • 安装会完全擦除目标磁盘"
    echo "  • 默认50秒后自动启动安装"
    echo "  • 按ESC键可显示引导菜单"
    echo "  • 支持UEFI和传统BIOS启动"
    echo ""
    
    # 创建构建摘要
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Auto Installer ISO
===========================
构建时间: $(date)
ISO文件: $ISO_NAME
文件大小: $ISO_SIZE
MD5: $ISO_MD5
内核版本: $(basename $KERNEL_FILE)
Initrd: $(basename $INITRD_FILE)
SquashFS大小: $SQUASHFS_SIZE
支持引导: BIOS + UEFI
引导菜单: 自动安装/安全模式/调试模式/救援Shell
BUILD_INFO
    
    log_success "构建摘要已保存到: ${OUTPUT_DIR}/build-info.txt"
else
    log_error "ISO构建失败"
    exit 1
fi

log_success "所有步骤完成！"
