#!/bin/bash
# build-openwrt-installer.sh - 构建OpenWRT自动安装ISO
set -e

echo "开始构建OpenWRT安装ISO..."
echo "========================================"

# 基础配置
WORK_DIR="${HOME}/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/chroot"
STAGING_DIR="${WORK_DIR}/staging"

OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-autoinstall.iso}"

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
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

# 安装必要工具
log_info "安装构建工具..."
apt-get update
apt-get -y install --no-install-recommends \
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
    live-boot \
    live-boot-initramfs-tools \
    pv

# 创建目录结构
log_info "创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/boot,boot/grub/x86_64-efi,isolinux,live}
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${WORK_DIR}/tmp"

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
    --include=apt,apt-utils,locales \
    buster "${CHROOT_DIR}" \
    "${DEBIAN_MIRROR}" 2>&1 | tee /tmp/debootstrap.log; then
    log_success "Debian最小系统引导成功"
else
    log_warning "第一次引导失败，尝试备用源..."
    DEBIAN_MIRROR="http://deb.debian.org/debian"
    if debootstrap --arch=amd64 --variant=minbase \
        --include=apt,apt-utils,locales \
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

echo "� 开始配置chroot环境..."

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 配置DNS
cat > /etc/resolv.conf << 'RESOLV'
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLV

# 更新包列表并安装
echo "更新包列表..."
apt-get update

echo "安装基本系统..."
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    live-boot \
    systemd-sysv \
    parted \
    bash-completion \
    curl \
    dbus \
    dosfstools \
    firmware-linux-free \
    gddrescue \
    gdisk \
    less \
    nfs-common \

    procps \

    dialog \
    pv

# 配置locale
echo "配置locale..."
sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
dpkg-reconfigure --frontend=noninteractive locales
update-locale LANG=en_US.UTF-8

# 清理包缓存
apt-get clean

# === 第二阶段：精简内核模块 ===
echo "精简内核模块..."
# 保留基本的内核模块
KEEP_MODULES="
ext4
fat
vfat
ntfs
isofs
usb-storage
usbhid
uhci-hcd
ehci-hcd
ohci-hcd
xhci-hcd
sd_mod
sr_mod
cdrom
ata_generic
ata_piix
ahci
nvme
scsi_mod
sg
dm-mod
dm-crypt
cryptd
loop
"

# 清理不必要的内核模块
mkdir -p /lib/modules-backup
KERNEL_VERSION=$(ls /lib/modules/ | head -n1)
MODULES_DIR="/lib/modules/${KERNEL_VERSION}/kernel"

for dir in drivers/net/wireless drivers/media drivers/video drivers/gpu; do
    rm -rf ${MODULES_DIR}/${dir} 2>/dev/null || true
done

# 保留网卡驱动 (最小化)
for dir in drivers/net/ethernet/intel drivers/net/ethernet/realtek drivers/net/ethernet/broadcom; do
    mkdir -p /lib/modules-backup/${dir}
    mv ${MODULES_DIR}/${dir}/* /lib/modules-backup/${dir}/ 2>/dev/null || true
done

# 清理不常用的文件系统驱动
for fs in cifs nfs nfsd afs ceph coda ecryptfs f2fs hfs hfsplus jffs2 minix nilfs2 omfs orangefs qnx4 qnx6 reiserfs romfs sysv ubifs udf ufs; do
    rm -rf ${MODULES_DIR}/fs/${fs} 2>/dev/null || true
done

# === 第三阶段：创建最小化系统服务 ===
echo "配置系统服务..."

# 禁用不必要的服务
systemctl mask \
    systemd-timesyncd.service \
    systemd-resolved.service \
    apt-daily.service \
    apt-daily-upgrade.service \
    e2scrub_all.service \
    e2scrub_reap.service \
    logrotate.service \
    man-db.service \
    plymouth.service \
    ssh.service

# 配置网络 (仅dhcp)
cat > /etc/systemd/network/eth.network <<EOF
[Match]
Name=e*

[Network]
DHCP=yes
EOF

systemctl enable systemd-networkd


# 配置SSH允许root登录
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "PermitEmptyPasswords yes" >> /etc/ssh/sshd_config
systemctl enable ssh

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
root::0:0:99999:7:::
daemon:*:18507:0:99999:7:::
bin:*:18507:0:99999:7:::
sys:*:18507:0:99999:7:::
SHADOW

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

# 启用服务
systemctl enable autoinstall.service

# 4. 配置agetty自动登录
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
Type=idle
GETTY_OVERRIDE

# 5. 创建OpenWRT安装脚本
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
clear
echo "========================================"
echo "    OpenWRT 自动安装程序"
echo "========================================"
echo ""

# 等待网络
echo "等待网络连接..."
for i in {1..20}; do
    if ping -c1 -W1 8.8.8.8 &>/dev/null; then
        echo "网络就绪"
        break
    fi
    sleep 1
done

# 检查OpenWRT镜像
if [ -f /mnt/openwrt/image.img ]; then
    cp /mnt/openwrt/image.img /openwrt.img
    echo "✅ 找到OpenWRT镜像"
    echo "大小: $(ls -lh /openwrt.img | awk '{print $5}')"
else
    echo "❌ 找不到OpenWRT镜像"
    echo "按回车键进入shell..."
    read
    exec /bin/bash
fi

while true; do
    echo ""
    echo "可用磁盘:"
    lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^[sh]d|^nvme|^vd' || echo "未找到磁盘"
    echo ""
    
    read -p "输入磁盘名称 (如: sda): " DISK
    
    if [ -z "$DISK" ]; then
        continue
    fi
    
    if [ ! -b "/dev/$DISK" ]; then
        echo "❌ 磁盘 /dev/$DISK 不存在"
        continue
    fi
    
    # 显示磁盘信息
    echo ""
    echo "磁盘信息 /dev/$DISK:"
    fdisk -l "/dev/$DISK" 2>/dev/null | head -10
    
    echo ""
    echo "⚠️ ⚠️ ⚠️  警告: 将擦除 /dev/$DISK 上的所有数据！ ⚠️ ⚠️ ⚠️"
    read -p "输入 'YES' 确认: " CONFIRM
    
    if [ "$CONFIRM" = "YES" ]; then
        echo ""
        echo "正在安装到 /dev/$DISK ..."
        
        if command -v pv >/dev/null; then
            pv -pet /openwrt.img | dd of="/dev/$DISK" bs=4M status=none
        else
            dd if=/openwrt.img of="/dev/$DISK" bs=4M status=progress
        fi
        
        sync
        echo ""
        echo "✅ 安装完成！"
        echo "系统将在10秒后重启..."
        
        for i in {10..1}; do
            echo -ne "倒计时: ${i}秒\r"
            sleep 1
        done
        
        reboot -f
    else
        echo "已取消"
    fi
done

INSTALL_SCRIPT

chmod +x /opt/install-openwrt.sh

# 6. 创建bash配置
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

# 7. 删除machine-id（重要！每次启动重新生成）
rm -f /etc/machine-id

# 8. 记录安装的包
echo "记录安装的包..."
dpkg --get-selections > /packages.txt

# 9. 配置live-boot
echo "配置live-boot..."
mkdir -p /etc/live/boot
echo "live" > /etc/live/boot.conf

# 清理
echo "清理系统..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "✅ chroot配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/install-chroot.sh"

# 挂载文件系统到chroot
log_info "挂载文件系统到chroot..."
mount -t proc none "${CHROOT_DIR}/proc"
mount -o bind /dev "${CHROOT_DIR}/dev"
mount -o bind /sys "${CHROOT_DIR}/sys"

# 在chroot内执行安装脚本
log_info "在chroot内执行安装..."
chroot "${CHROOT_DIR}" /bin/bash -c "/install-chroot.sh 2>&1 | tee /install.log"

# 清理chroot
log_info "清理chroot..."
rm -f "${CHROOT_DIR}/install-chroot.sh"
if [ -f "${CHROOT_DIR}/packages.txt" ]; then
    mv "${CHROOT_DIR}/packages.txt" "/output/packages.txt"
fi

# 配置网络
cat > "${CHROOT_DIR}/etc/systemd/network/99-dhcp-en.network" <<EOF
[Match]
Name=e*

[Network]
DHCP=yes

[DHCP]
ClientIdentifier=mac
EOF
chmod 644 "${CHROOT_DIR}/etc/systemd/network/99-dhcp-en.network"

# 卸载chroot文件系统
log_info "卸载chroot文件系统..."
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
umount "${CHROOT_DIR}/sys" 2>/dev/null || true
umount "${CHROOT_DIR}/dev" 2>/dev/null || true

# 创建squashfs文件系统
log_info "创建squashfs文件系统..."
# 先复制armbian镜像（如果需要）
if [ -f "/mnt/armbian.img" ]; then
    cp /mnt/armbian.img "${CHROOT_DIR}/mnt/"
fi

# 创建squashfs，排除boot目录
if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp xz \
    -b 1M \
    -noappend \
    -e boot; then
    log_success "squashfs创建成功"
else
    log_error "squashfs创建失败"
    exit 1
fi

# 创建live-boot需要的文件
echo "live" > "${STAGING_DIR}/live/filesystem.squashfs.type"
touch "${STAGING_DIR}/live/filesystem.squashfs-"

# 复制内核和initrd
log_info "复制内核和initrd..."
if cp "${CHROOT_DIR}/boot"/vmlinuz-* "${STAGING_DIR}/live/vmlinuz" 2>/dev/null; then
    log_success "内核复制成功"
else
    log_error "内核复制失败"
    exit 1
fi

if cp "${CHROOT_DIR}/boot"/initrd.img-* "${STAGING_DIR}/live/initrd" 2>/dev/null; then
    log_success "initrd复制成功"
else
    log_error "initrd复制失败"
    exit 1
fi

# 创建引导配置文件
log_info "创建引导配置..."

# 1. ISOLINUX配置
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE OpenWRT Auto Installer

LABEL live
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet
  TEXT HELP
  Automatically start OpenWRT installer
  ENDTEXT
ISOLINUX_CFG

# 2. GRUB配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet
    initrd /live/initrd
}
GRUB_CFG

# 3. 创建GRUB standalone配置
cat > "${WORK_DIR}/tmp/grub-standalone.cfg" << 'STAD_CFG'
search --set=root --file /DEBIAN_CUSTOM
set prefix=($root)/boot/grub/
configfile /boot/grub/grub.cfg
STAD_CFG

touch "${STAGING_DIR}/DEBIAN_CUSTOM"

# 复制引导文件
log_info "复制引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 复制syslinux模块
if [ -d /usr/lib/syslinux/modules/bios ]; then
    cp /usr/lib/syslinux/modules/bios/*.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true
fi

# 复制GRUB模块
if [ -d /usr/lib/grub/x86_64-efi ]; then
    mkdir -p "${STAGING_DIR}/boot/grub/x86_64-efi"
    cp -r /usr/lib/grub/x86_64-efi/* "${STAGING_DIR}/boot/grub/x86_64-efi/" 2>/dev/null || true
fi

# 创建UEFI引导文件
log_info "创建UEFI引导文件..."
grub-mkstandalone \
    --format=x86_64-efi \
    --output="${WORK_DIR}/tmp/bootx64.efi" \
    --locales="" \
    --fonts="" \
    "boot/grub/grub.cfg=${WORK_DIR}/tmp/grub-standalone.cfg" 2>/dev/null || {
    log_warning "GRUB standalone创建失败，使用备用方案"
    # 备用：直接复制已有的EFI文件
    if [ -f /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed ]; then
        cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed "${WORK_DIR}/tmp/bootx64.efi"
    fi
}

# 创建EFI映像
cd "${STAGING_DIR}/EFI/boot"
if [ -f "${WORK_DIR}/tmp/bootx64.efi" ]; then
    EFI_SIZE=$(stat --format=%s "${WORK_DIR}/tmp/bootx64.efi" 2>/dev/null || echo 65536)
    EFI_SIZE=$((EFI_SIZE + 65536))
    
    dd if=/dev/zero of=efiboot.img bs=1 count=0 seek=${EFI_SIZE} 2>/dev/null
    /sbin/mkfs.vfat -F 32 efiboot.img 2>/dev/null || true
    
    mmd -i efiboot.img efi 2>/dev/null || true
    mmd -i efiboot.img efi/boot 2>/dev/null || true
    mcopy -i efiboot.img "${WORK_DIR}/tmp/bootx64.efi" ::efi/boot/bootx64.efi 2>/dev/null || true
    
    log_success "UEFI引导文件创建完成"
else
    log_warning "UEFI引导文件创建失败，将只支持BIOS引导"
    rm -f efiboot.img
fi

# 构建ISO镜像
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# 修复的xorriso命令
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
    -output "${ISO_PATH}" \
    "${STAGING_DIR}" 2>&1 | tee /tmp/xorriso.log

# 如果UEFI文件存在，添加UEFI引导
if [ -f "${STAGING_DIR}/EFI/boot/efiboot.img" ]; then
    log_info "添加UEFI引导支持..."
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "OPENWRT_INSTALL" \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "${ISO_PATH}" \
        "${STAGING_DIR}" 2>&1 | tee /tmp/xorriso.log
fi

# 验证ISO
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    log_success "✅ ISO构建成功！"
    echo ""
    echo "� 构建信息："
    echo "  文件: $ISO_PATH"
    echo "  大小: $ISO_SIZE"
    echo "  卷标: OPENWRT_INSTALL"
    echo ""
    echo "� 构建完成！"
    echo ""
    echo "使用方法："
    echo "  1. 刻录到U盘: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress"
    echo "  2. 从U盘启动计算机"
    echo "  3. 系统将自动启动安装程序"
    echo "  4. 选择目标磁盘并确认安装"
    echo "  5. 等待安装完成自动重启"
    echo ""
    
    # 创建构建摘要
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Auto Installer ISO
===========================
构建时间: $(date)
ISO文件: $ISO_NAME
文件大小: $ISO_SIZE
支持引导: BIOS + UEFI
引导菜单: 自动安装OpenWRT
注意事项: 安装会完全擦除目标磁盘数据
BUILD_INFO
    
    log_success "构建摘要已保存到: ${OUTPUT_DIR}/build-info.txt"
else
    log_error "ISO构建失败"
    if [ -f /tmp/xorriso.log ]; then
        echo "xorriso error:"
        tail -20 /tmp/xorriso.log
    fi
    exit 1
fi

log_success "所有步骤完成！"
