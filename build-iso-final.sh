#!/bin/bash
# build-iso-final.sh - 构建OpenWRT自动安装ISO（优化版）
set -e

echo "开始构建OpenWRT安装ISO（优化版）..."
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
deb http://archive.debian.org/debian buster main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

# 安装必要工具（最小化）
log_info "安装最小构建工具集..."
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
    parted \
    wget \
    curl

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
cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img"
log_success "OpenWRT镜像已复制"

# 引导Debian最小系统（使用buildd变体，更小）
log_info "引导Debian最小系统..."
DEBIAN_MIRROR="http://archive.debian.org/debian"
if ! debootstrap --arch=amd64 --variant=minbase \
    --include=apt,locales,linux-image-amd64,systemd-sysv,live-boot,bash,dash \
    buster "${CHROOT_DIR}" \
    "${DEBIAN_MIRROR}" 2>&1 | tee /tmp/debootstrap.log; then
    log_error "debootstrap失败"
    cat /tmp/debootstrap.log
    exit 1
fi
log_success "Debian最小系统引导成功"

# 创建chroot安装脚本（优化版）
log_info "创建chroot配置脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# OpenWRT安装系统chroot配置脚本（优化版）
set -e

echo "🔧 开始配置chroot环境..."

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源（最小化）
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
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

# 更新包列表
echo "更新包列表..."
apt-get update

echo "安装最小系统..."
# 只安装绝对必要的包
apt-get install -y --no-install-recommends \
    live-boot \
    systemd-sysv \
    parted \
    dosfstools \
    gdisk \
    bash \
    dash

# 清理不必要的包
echo "清理不必要的包..."
apt-get purge -y --auto-remove \
    man-db \
    info \
    perl \
    python* \
    ruby* \
    lua* \
    texinfo \
    docbook* \
    sgml-base \
    xml-core \
    2>/dev/null || true

# 配置locale（最小化）
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_MESSAGES=C

# 清理包缓存
apt-get clean
rm -rf /var/lib/apt/lists/*

# 创建最小化的自动登录和启动配置
echo "配置自动启动..."

# 1. 设置root无密码登录
usermod -p '*' root

# 2. 创建最小化的启动脚本
cat > /opt/start-installer.sh << 'START_SCRIPT'
#!/bin/bash
# OpenWRT安装系统启动脚本

clear
cat << "WELCOME"

╔══════════════════════════════════════════╗
║     OpenWRT Auto Install System          ║
╚══════════════════════════════════════════╝

WELCOME

sleep 2

if [ ! -f "/openwrt.img" ]; then
    echo "❌ Error: OpenWRT image not found"
    echo "Press Enter for shell..."
    read
    exec /bin/bash
fi

exec /opt/install-openwrt.sh
START_SCRIPT
chmod +x /opt/start-installer.sh

# 3. 创建OpenWRT安装脚本
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT自动安装脚本

clear
cat << "EOF"

╔══════════════════════════════════════════╗
║         OpenWRT Auto Installer           ║
╚══════════════════════════════════════════╝

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

echo "✅ OpenWRT image found"
echo ""

while true; do
    # 显示磁盘
    echo "Available disks:"
    echo "================="
    lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || echo "No disks found"
    echo "================="
    echo ""
    
    read -p "Enter target disk (e.g., sda): " DISK
    
    if [ -z "$DISK" ]; then
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
    
    dd if=/openwrt.img of="/dev/$DISK" bs=4M status=progress
    
    sync
    echo ""
    echo "✅ Installation complete!"
    echo ""
    
    for i in {10..1}; do
        echo -ne "Rebooting in $i seconds... (Press any key to cancel)\r"
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

# 4. 配置systemd自动启动
cat > /etc/systemd/system/openwrt-installer.service << 'SERVICE'
[Unit]
Description=OpenWRT Auto Installer
After=getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=simple
ExecStart=/opt/start-installer.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1

[Install]
WantedBy=multi-user.target
SERVICE

# 启用服务
systemctl enable openwrt-installer.service

# 5. 配置agetty自动登录
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
Type=idle
GETTY_OVERRIDE

# 6. 最小化bash配置
cat > /root/.bashrc << 'BASHRC'
if [ "$(tty)" = "/dev/tty1" ]; then
    echo ""
    echo "Welcome to OpenWRT Installer System"
    echo "Type 'install-openwrt' to start installer"
    echo ""
fi
alias install-openwrt='/opt/install-openwrt.sh'
BASHRC

# 7. 删除machine-id
rm -f /etc/machine-id

# 8. 删除不必要的文档和文件
echo "清理系统文件..."
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/locale/* /var/cache/*
find /usr/share -name '*.gz' -delete
find /usr/share -name '*.pyc' -delete
find /usr/share -name '*.mo' -delete

# 9. 删除不必要的内核模块（只保留最基本的）
if [ -d /lib/modules ]; then
    KERNEL_VERSION=$(ls /lib/modules | head -1)
    if [ -n "$KERNEL_VERSION" ]; then
        # 只保留必要的内核模块
        KEEP_MODULES="kernel/drivers/block kernel/drivers/ata kernel/drivers/scsi kernel/drivers/usb/storage kernel/fs kernel/lib"
        for module in $KEEP_MODULES; do
            mkdir -p "/lib/modules/$KERNEL_VERSION/$module"
        done
        # 删除其他模块
        find /lib/modules/$KERNEL_VERSION -type f -name '*.ko' | \
            grep -v -E '(block|ata|scsi|usb-storage|ext[234]|fat|ntfs|vfat|iso9660|nls_)' | \
            xargs rm -f 2>/dev/null || true
        depmod $KERNEL_VERSION
    fi
fi

# 10. 配置live-boot
echo "live" > /etc/live/boot.conf

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

# 卸载chroot文件系统
log_info "卸载chroot文件系统..."
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
umount "${CHROOT_DIR}/sys" 2>/dev/null || true
umount "${CHROOT_DIR}/dev" 2>/dev/null || true
rm -f "${CHROOT_DIR}/install-chroot.sh"

# 额外清理chroot目录
log_info "执行额外清理..."
# 删除缓存文件
rm -rf "${CHROOT_DIR}"/var/cache/apt/*
rm -rf "${CHROOT_DIR}"/var/lib/apt/lists/*
rm -rf "${CHROOT_DIR}"/tmp/*

# 删除日志文件
find "${CHROOT_DIR}/var/log" -type f -exec truncate -s 0 {} \;

# 创建squashfs文件系统（高压缩）
log_info "创建squashfs文件系统（使用xz高压缩）..."
if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp xz \
    -Xdict-size 1M \
    -b 1M \
    -noappend \
    -no-recovery \
    -no-progress \
    -e boot \
    -e usr/share/doc \
    -e usr/share/man \
    -e usr/share/info \
    -e var/cache/apt; then
    log_success "squashfs创建成功"
    
    # 删除chroot目录以释放空间
    rm -rf "${CHROOT_DIR}"
else
    log_error "squashfs创建失败"
    exit 1
fi

# 复制最小化的内核和initrd
log_info "复制内核和initrd..."
KERNEL_IMG=$(ls "${STAGING_DIR}/live/filesystem.squashfs" 2>/dev/null)
if [ -f "$KERNEL_IMG" ]; then
    # 使用unmkinitramfs从squashfs中提取（更小）
    unsquashfs -f -d /tmp/squashfs-root "${STAGING_DIR}/live/filesystem.squashfs" \
        boot/vmlinuz-* boot/initrd.img-* 2>/dev/null || true
    
    if ls /tmp/squashfs-root/boot/vmlinuz-* 1>/dev/null 2>&1; then
        VMLINUZ=$(ls /tmp/squashfs-root/boot/vmlinuz-* | head -1)
        INITRD=$(ls /tmp/squashfs-root/boot/initrd.img-* | head -1)
        
        cp "$VMLINUZ" "${STAGING_DIR}/live/vmlinuz"
        cp "$INITRD" "${STAGING_DIR}/live/initrd"
        
        # 压缩initrd
        if command -v xz >/dev/null 2>&1; then
            log_info "压缩initrd..."
            xz -9 -T0 "${STAGING_DIR}/live/initrd"
            mv "${STAGING_DIR}/live/initrd.xz" "${STAGING_DIR}/live/initrd"
        fi
        
        log_success "内核和initrd复制成功"
    else
        # 备用方案：使用最小的内核
        log_warning "无法从squashfs提取内核，使用备用方案"
        # 这里可以添加下载最小内核的代码
        log_error "需要内核文件"
        exit 1
    fi
    rm -rf /tmp/squashfs-root
fi

echo "live" > "${STAGING_DIR}/live/filesystem.squashfs.type"

# 创建最小引导配置
log_info "创建最小引导配置..."

# 1. ISOLINUX配置
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
TIMEOUT 30
PROMPT 0
SERIAL 0 115200

LABEL live
  MENU LABEL Install OpenWRT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live quiet
ISOLINUX_CFG

# 2. GRUB配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=3
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live quiet
    initrd /live/initrd
}
GRUB_CFG

# 复制引导文件
log_info "复制引导文件..."
# ISOLINUX
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || \
cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# GRUB EFI
mkdir -p "${STAGING_DIR}/EFI/boot"
if [ -f /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed ]; then
    cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed \
        "${STAGING_DIR}/EFI/boot/bootx64.efi"
elif [ -f /usr/lib/grub/x86_64-efi/grub.efi ]; then
    cp /usr/lib/grub/x86_64-efi/grub.efi \
        "${STAGING_DIR}/EFI/boot/bootx64.efi"
fi

# 创建EFI映像（优化大小）
if [ -f "${STAGING_DIR}/EFI/boot/bootx64.efi" ]; then
    log_info "创建EFI引导映像..."
    EFI_SIZE=2048  # 2MB足够
    dd if=/dev/zero of="${STAGING_DIR}/EFI/boot/efiboot.img" \
        bs=1M count=${EFI_SIZE} 2>/dev/null
    mkfs.vfat -F 32 "${STAGING_DIR}/EFI/boot/efiboot.img" 2>/dev/null
    
    # 挂载并复制文件
    MOUNT_POINT=$(mktemp -d)
    mount -t vfat -o loop "${STAGING_DIR}/EFI/boot/efiboot.img" "${MOUNT_POINT}"
    mkdir -p "${MOUNT_POINT}/EFI/boot"
    cp "${STAGING_DIR}/EFI/boot/bootx64.efi" "${MOUNT_POINT}/EFI/boot/"
    umount "${MOUNT_POINT}"
    rm -rf "${MOUNT_POINT}"
    
    log_success "UEFI引导文件创建完成"
fi

# 清理不需要的文件
log_info "清理staging目录..."
find "${STAGING_DIR}" -name "*.md" -delete
find "${STAGING_DIR}" -name "*.txt" -delete
find "${STAGING_DIR}" -name "README*" -delete
rm -rf "${STAGING_DIR}"/usr/share/doc
rm -rf "${STAGING_DIR}"/usr/share/man
rm -rf "${STAGING_DIR}"/usr/share/info

# 构建优化的ISO镜像
log_info "构建优化的ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

if [ -f "${STAGING_DIR}/EFI/boot/efiboot.img" ]; then
    # 构建支持BIOS+UEFI的ISO
    xorriso -as mkisofs \
        -iso-level 3 \
        -volid "OPENWRT_INSTALL" \
        -eltorito-boot isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "${ISO_PATH}" \
        "${STAGING_DIR}" 2>&1 | tee /tmp/xorriso.log
else
    # 只支持BIOS的ISO
    xorriso -as mkisofs \
        -iso-level 3 \
        -volid "OPENWRT_INSTALL" \
        -eltorito-boot isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "${ISO_PATH}" \
        "${STAGING_DIR}" 2>&1 | tee /tmp/xorriso.log
fi

# 验证ISO
if [ -f "$ISO_PATH" ]; then
    # 可选：进一步压缩ISO
    log_info "优化ISO文件..."
    
    # 1. 使用isohybrid使其可直接dd到USB
    if command -v isohybrid >/dev/null 2>&1; then
        isohybrid "${ISO_PATH}" 2>/dev/null || true
    fi
    
    # 2. 记录大小
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    ISO_SIZE_BYTES=$(stat -c%s "$ISO_PATH")
    
    echo ""
    log_success "✅ ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: $ISO_PATH"
    echo "  大小: $ISO_SIZE ($ISO_SIZE_BYTES 字节)"
    echo "  压缩比: $(echo "scale=2; $(du -sb "${STAGING_DIR}" 2>/dev/null | awk '{print $1}') / $ISO_SIZE_BYTES" | bc)x"
    echo ""
    echo "🎉 优化完成！文件大小已最小化。"
    
    # 创建构建摘要
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Auto Installer ISO
===========================
构建时间: $(date)
ISO文件: $ISO_NAME
文件大小: $ISO_SIZE ($ISO_SIZE_BYTES 字节)
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

# 清理工作目录
log_info "清理工作目录..."
rm -rf "${WORK_DIR}"
rm -rf "${STAGING_DIR}" 2>/dev/null || true

log_success "所有步骤完成！"
