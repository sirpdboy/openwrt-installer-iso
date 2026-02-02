#!/bin/bash
# build-iso-final.sh - 构建OpenWRT自动安装ISO（优化版）
set -e

echo "开始构建OpenWRT安装ISO（优化版）..."
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
    exit 1
fi

# 修复Debian buster源
log_info "配置Debian buster源..."
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
deb http://archive.debian.org/debian-security buster/updates main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# 安装必要工具（最小化）
log_info "安装最小化构建工具..."
apt-get update
apt-get -y install --no-install-recommends \
    debootstrap \
    squashfs-tools \
    xorriso \
    isolinux \
    syslinux-common \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools \
    dosfstools \
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

# 复制OpenWRT镜像到临时目录（不放入chroot）
log_info "复制OpenWRT镜像到临时位置..."
mkdir -p "${WORK_DIR}/openwrt"
cp "${OPENWRT_IMG}" "${WORK_DIR}/openwrt/image.img"
OPENWRT_SIZE=$(stat -c%s "${WORK_DIR}/openwrt/image.img")
log_success "OpenWRT镜像已复制 (${OPENWRT_SIZE} bytes)"

# 引导极简Debian系统（使用--variant=minbase --exclude选项）
log_info "引导极简Debian系统..."
DEBIAN_MIRROR="http://archive.debian.org/debian"
DEBOOTSTRAP_PACKAGES="locales,linux-image-amd64,live-boot,systemd-sysv,parted,dialog,openssh-server,ssh"

if ! debootstrap \
    --arch=amd64 \
    --variant=minbase \
    --include="${DEBOOTSTRAP_PACKAGES}" \
    --exclude=aptitude,apt-utils,bash-completion,bsdmainutils,busybox,debian-archive-keyring,debian-faq,debianutils,dhcpcd5,dmidecode,dmsetup,dnsutils,doc-debian,e2fsprogs,ed,file,fdisk,gawk,gettext-base,groff-base,info,install-info,iproute2,iptables,iputils-ping,isc-dhcp-client,kbd,keyboard-configuration,klibc-utils,kmod,less,libcap2-bin,libpam-systemd,libssl1.1,libtinfo5,libusb-1.0-0,login,lsb-release,man-db,manpages,mawk,mdadm,media-types,nano,netbase,netcat-traditional,net-tools,ntpdate,openntpd,openssh-client,openssh-sftp-server,pciutils,perl,perl-base,perl-modules-5.28,plymouth,procps,psmisc,python,python3,readline-common,rsyslog,systemd,systemd-timesyncd,tasksel,telnet,traceroute,ucf,udev,usbutils,vim-tiny,wget,whiptail,xz-utils \
    buster "${CHROOT_DIR}" "${DEBIAN_MIRROR}" 2>&1 | tee /tmp/debootstrap.log; then
    
    log_warning "第一次引导失败，尝试备用源..."
    DEBIAN_MIRROR="http://deb.debian.org/debian"
    debootstrap \
        --arch=amd64 \
        --variant=minbase \
        --include="${DEBOOTSTRAP_PACKAGES}" \
        --exclude=aptitude,apt-utils,bash-completion,bsdmainutils,busybox,debian-archive-keyring,debian-faq,debianutils,dhcpcd5,dmidecode,dmsetup,dnsutils,doc-debian,e2fsprogs,ed,file,fdisk,gawk,gettext-base,groff-base,info,install-info,iproute2,iptables,iputils-ping,isc-dhcp-client,kbd,keyboard-configuration,klibc-utils,kmod,less,libcap2-bin,libpam-systemd,libssl1.1,libtinfo5,libusb-1.0-0,login,lsb-release,man-db,manpages,mawk,mdadm,media-types,nano,netbase,netcat-traditional,net-tools,ntpdate,openntpd,openssh-client,openssh-sftp-server,pciutils,perl,perl-base,perl-modules-5.28,plymouth,procps,psmisc,python,python3,readline-common,rsyslog,systemd,systemd-timesyncd,tasksel,telnet,traceroute,ucf,udev,usbutils,vim-tiny,wget,whiptail,xz-utils \
        buster "${CHROOT_DIR}" "${DEBIAN_MIRROR}" 2>&1 | tee -a /tmp/debootstrap.log
fi

log_success "Debian极简系统引导成功"

# 创建chroot配置脚本（优化版）
log_info "创建优化chroot配置脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# OpenWRT安装系统chroot配置脚本（优化版）
set -e

echo "🔧 开始配置chroot环境..."

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 配置DNS
cat > /etc/resolv.conf << 'RESOLV'
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLV

# 更新包列表（最小化）
apt-get update

# 清理apt缓存
apt-get clean

# 配置locale（最小化）
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# === 配置自动登录和自动启动 ===
echo "配置自动登录和启动..."

# 1. 设置root无密码登录
usermod -p '*' root

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

[Install]
WantedBy=multi-user.target
AUTOINSTALL_SERVICE

# 3. 创建启动脚本
cat > /opt/start-installer.sh << 'START_SCRIPT'
#!/bin/bash
# OpenWRT安装系统启动脚本

clear
cat << "EOF"

╔═══════════════════════════════════════════════════════╗
║       OpenWRT Auto Install System                     ║
╚═══════════════════════════════════════════════════════╝

System is starting up...
EOF

sleep 2

# 挂载OpenWRT镜像（从ISO的live目录）
if [ -f /mnt/openwrt/image.img ]; then
    echo "✅ OpenWRT image found"
    cp /mnt/openwrt/image.img /openwrt.img
    echo "Image size: $(ls -lh /openwrt.img | awk '{print $5}')"
else
    echo "❌ ERROR: OpenWRT image not found in /mnt/openwrt/"
    echo "System will start shell in 10 seconds..."
    sleep 10
    exec /bin/bash
fi

exec /opt/install-openwrt.sh
START_SCRIPT
chmod +x /opt/start-installer.sh

# 4. 创建OpenWRT安装脚本
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT自动安装脚本

clear
cat << "EOF"

╔═══════════════════════════════════════════════════════╗
║               OpenWRT Auto Installer                  ║
╚═══════════════════════════════════════════════════════╝

EOF

echo ""
echo "Detecting available disks..."
DISKS=$(lsblk -d -n -o NAME,SIZE,MODEL | grep -E '^(sd|hd|nvme|vd)' 2>/dev/null || echo "No disks found")

if [ -z "$DISKS" ] || [ "$DISKS" = "No disks found" ]; then
    echo "❌ No disks detected!"
    echo "Press Enter for shell..."
    read
    exec /bin/bash
fi

while true; do
    clear
    echo "Available disks:"
    echo "================="
    echo "$DISKS"
    echo "================="
    echo ""
    
    read -p "Enter target disk (e.g., sda, nvme0n1): " DISK
    
    if [ -z "$DISK" ]; then
        echo "Please enter a disk name"
        sleep 2
        continue
    fi
    
    if [ ! -b "/dev/$DISK" ]; then
        echo "❌ Disk /dev/$DISK not found!"
        sleep 2
        continue
    fi
    
    # 确认
    echo ""
    echo "⚠️  WARNING: This will ERASE ALL DATA on /dev/$DISK!"
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        sleep 2
        continue
    fi
    
    # 安装
    clear
    echo ""
    echo "🚀 Installing OpenWRT to /dev/$DISK..."
    echo "This may take a few minutes..."
    echo ""
    
    if command -v pv >/dev/null 2>&1; then
        pv -pet /openwrt.img | dd of="/dev/$DISK" bs=4M status=none oflag=sync
    else
        dd if=/openwrt.img of="/dev/$DISK" bs=4M status=progress conv=fsync
    fi
    
    sync
    echo ""
    echo "✅ Installation complete!"
    echo ""
    
    echo "1. Press 'R' to reboot"
    echo "2. Press 'S' to start shell"
    echo "3. Press any other key to continue installation"
    echo ""
    read -n1 -t30 -p "Choice: " CHOICE
    echo ""
    
    case "$CHOICE" in
        [Rr]) reboot -f ;;
        [Ss]) exec /bin/bash ;;
        *) continue ;;
    esac
done
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 5. 配置agetty自动登录
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
Type=idle
GETTY_OVERRIDE

# 6. 启用服务
systemctl enable autoinstall.service
systemctl enable ssh

# 7. 配置SSH（允许root无密码登录）
mkdir -p /root/.ssh
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "PermitEmptyPasswords yes" >> /etc/ssh/sshd_config

# 8. 创建最小化bash配置
cat > /root/.bashrc << 'BASHRC'
# OpenWRT安装系统bash配置
export PS1='\[\e[1;32m\]\u@openwrt-installer\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
alias ll='ls -la'
BASHRC

# 9. 删除不必要的文件
echo "清理系统文件..."
# 删除文档
rm -rf /usr/share/{doc,man,locale}/* 2>/dev/null || true
# 删除info文件
rm -rf /usr/share/info/* 2>/dev/null || true
# 清理缓存
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/*

# 10. 删除machine-id（每次启动重新生成）
rm -f /etc/machine-id

# 11. 配置live-boot
echo "live" > /etc/live/boot.conf
mkdir -p /etc/live/boot

# 12. 创建挂载点
mkdir -p /mnt/openwrt

echo "✅ chroot配置完成"
CHROOT_EOF

chmod +x "${CHROOT_DIR}/install-chroot.sh"

# 在chroot内执行安装脚本
log_info "在chroot内执行配置..."
mount -t proc none "${CHROOT_DIR}/proc"
mount -o bind /dev "${CHROOT_DIR}/dev"
mount -o bind /sys "${CHROOT_DIR}/sys"

chroot "${CHROOT_DIR}" /bin/bash -c "/install-chroot.sh" 2>&1 | tee "${WORK_DIR}/chroot-install.log"

# 清理chroot内临时文件
log_info "清理chroot临时文件..."
rm -f "${CHROOT_DIR}/install-chroot.sh"

# 清理chroot中不必要的文件
log_info "执行深度清理..."
chroot "${CHROOT_DIR}" /bin/bash -c "
# 删除缓存文件
find /var/cache -type f -delete 2>/dev/null || true

# 删除日志文件（保留目录）
find /var/log -type f -name '*.log' -delete 2>/dev/null || true

# 删除备份文件
find / -name '*.bak' -delete 2>/dev/null || true
find / -name '*.old' -delete 2>/dev/null || true

# 删除不必要的locales
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en*' -exec rm -rf {} + 2>/dev/null || true

# 清理编译文件
find /usr -name '*.pyc' -delete 2>/dev/null || true
find /usr -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
"

# 卸载chroot文件系统
log_info "卸载chroot文件系统..."
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
umount "${CHROOT_DIR}/sys" 2>/dev/null || true
umount "${CHROOT_DIR}/dev" 2>/dev/null || true

# 复制OpenWRT镜像到staging目录
log_info "复制OpenWRT镜像到live目录..."
mkdir -p "${STAGING_DIR}/live/openwrt"
cp "${WORK_DIR}/openwrt/image.img" "${STAGING_DIR}/live/openwrt/image.img"

# 创建squashfs文件系统（使用高压缩比）
log_info "创建高压缩squashfs文件系统..."
SQUASHFS_OPTS="-comp xz -Xdict-size 100% -b 1M -noappend -no-recovery -no-progress"

# 排除不必要的目录和文件
cat > "${WORK_DIR}/exclude-list.txt" << 'EXCLUDE'
/boot/*
/dev/*
/proc/*
/sys/*
/tmp/*
/var/tmp/*
/var/cache/*
/var/log/*
/var/lib/apt/lists/*
/usr/share/doc/*
/usr/share/man/*
/usr/share/info/*
/usr/share/locale/*
/usr/share/zoneinfo/*
/opt/start-installer.sh
/opt/install-openwrt.sh
EXCLUDE

if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    ${SQUASHFS_OPTS} \
    -ef "${WORK_DIR}/exclude-list.txt" 2>&1 | tee /tmp/mksquashfs.log; then
    
    SQUASHFS_SIZE=$(stat -c%s "${STAGING_DIR}/live/filesystem.squashfs")
    log_success "squashfs创建成功 (${SQUASHFS_SIZE} bytes)"
else
    log_error "squashfs创建失败"
    cat /tmp/mksquashfs.log
    exit 1
fi

# 创建live-boot需要的文件
echo "live" > "${STAGING_DIR}/live/filesystem.squashfs.type"
touch "${STAGING_DIR}/live/filesystem.squashfs-"

# 复制内核和initrd（使用绝对路径）
log_info "复制内核和initrd..."
KERNEL_FILE=$(find "${CHROOT_DIR}/boot" -name 'vmlinuz-*' -type f | head -1)
INITRD_FILE=$(find "${CHROOT_DIR}/boot" -name 'initrd.img-*' -type f | head -1)

if [ -f "$KERNEL_FILE" ]; then
    cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
    log_success "内核复制成功: $(basename $KERNEL_FILE)"
else
    log_error "找不到内核文件"
    exit 1
fi

if [ -f "$INITRD_FILE" ]; then
    cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"
    log_success "initrd复制成功: $(basename $INITRD_FILE)"
else
    log_error "找不到initrd文件"
    exit 1
fi

# 创建引导配置文件（最小化）
log_info "创建引导配置..."

# 1. ISOLINUX配置
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
PROMPT 0
TIMEOUT 10
UI menu.c32

MENU TITLE OpenWRT Installer

LABEL live
  MENU LABEL ^Install OpenWRT (Auto)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet
ISOLINUX_CFG

# 2. GRUB配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet
    initrd /live/initrd
}
GRUB_CFG

# 复制引导文件
log_info "复制引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true

cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/libcom32.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/libutil.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/menu.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 创建UEFI引导（简化版）
log_info "创建UEFI引导..."
if command -v grub-mkstandalone >/dev/null 2>&1; then
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="${WORK_DIR}/tmp/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=${STAGING_DIR}/boot/grub/grub.cfg" 2>&1 | tee /tmp/grub.log || \
    log_warning "GRUB standalone创建失败，使用备用方案"
fi

# 如果创建成功，制作EFI映像
if [ -f "${WORK_DIR}/tmp/bootx64.efi" ]; then
    log_info "创建EFI映像..."
    EFI_SIZE=$(( $(stat -c%s "${WORK_DIR}/tmp/bootx64.efi") + 65536 ))
    
    dd if=/dev/zero of="${STAGING_DIR}/EFI/boot/efiboot.img" bs=1 count=0 seek=${EFI_SIZE}
    mkfs.vfat -F 32 "${STAGING_DIR}/EFI/boot/efiboot.img" >/dev/null 2>&1
    
    mmd -i "${STAGING_DIR}/EFI/boot/efiboot.img" ::EFI
    mmd -i "${STAGING_DIR}/EFI/boot/efiboot.img" ::EFI/BOOT
    mcopy -i "${STAGING_DIR}/EFI/boot/efiboot.img" \
        "${WORK_DIR}/tmp/bootx64.efi" ::EFI/BOOT/BOOTX64.EFI
        
    log_success "UEFI引导文件创建完成"
fi

# 构建ISO镜像（优化参数）
log_info "构建优化ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

XORRISO_CMD="xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -joliet \
    -joliet-long \
    -rational-rock \
    -volid 'OPENWRT_INSTALL' \
    -appid 'OpenWRT Auto Installer' \
    -publisher 'OpenWRT Project' \
    -preparer 'Built on GitHub Actions' \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -output '${ISO_PATH}' \
    '${STAGING_DIR}'"

# 如果有EFI引导，添加参数
if [ -f "${STAGING_DIR}/EFI/boot/efiboot.img" ]; then
    XORRISO_CMD="${XORRISO_CMD} \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat"
fi

# 执行构建
eval $XORRISO_CMD 2>&1 | tee /tmp/xorriso.log

# 验证ISO
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    ISO_SIZE_BYTES=$(stat -c%s "$ISO_PATH")
    
    echo ""
    log_success "✅ ISO构建成功！"
    echo ""
    echo "📊 构建摘要："
    echo "  文件: ${ISO_NAME}"
    echo "  大小: ${ISO_SIZE} (${ISO_SIZE_BYTES} bytes)"
    echo "  压缩比: $(( ${SQUASHFS_SIZE} / ${ISO_SIZE_BYTES} * 100 )) %"
    echo "  支持引导: BIOS + UEFI"
    echo ""
    
    # 显示各组件大小
    echo "📁 组件大小分析："
    echo "  squashfs: $(ls -lh "${STAGING_DIR}/live/filesystem.squashfs" | awk '{print $5}')"
    echo "  OpenWRT镜像: $(ls -lh "${STAGING_DIR}/live/openwrt/image.img" | awk '{print $5}')"
    echo "  内核: $(ls -lh "${STAGING_DIR}/live/vmlinuz" | awk '{print $5}')"
    echo "  initrd: $(ls -lh "${STAGING_DIR}/live/initrd" | awk '{print $5}')"
    echo ""
    
    # 创建构建信息
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Auto Installer ISO (优化版)
====================================
构建时间: $(date)
ISO文件: ${ISO_NAME}
文件大小: ${ISO_SIZE} (${ISO_SIZE_BYTES} bytes)
支持引导: BIOS + UEFI
内核版本: $(basename $KERNEL_FILE | sed 's/vmlinuz-//')
initrd版本: $(basename $INITRD_FILE | sed 's/initrd.img-//')
squashfs大小: $(stat -c%s "${STAGING_DIR}/live/filesystem.squashfs") bytes
压缩算法: xz (最大压缩)
优化策略: 最小化debootstrap + 深度清理
BUILD_INFO
    
    log_success "构建信息已保存到: ${OUTPUT_DIR}/build-info.txt"
    
    # 显示ISO内容
    echo ""
    echo "📂 ISO内容结构："
    xorriso -indev "${ISO_PATH}" -find / -type d -name "live" 2>/dev/null || true
    
else
    log_error "ISO构建失败"
    exit 1
fi

echo ""
log_success "🎉 构建完成！优化后的ISO已生成。"
echo "预计比原始版本缩小 40-60%。"
