#!/bin/bash
# build-iso-final.sh - 构建OpenWRT自动安装ISO（修复版）
set -e

echo "开始构建OpenWRT安装ISO（修复版）..."
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
    exit 1
fi

# 修复Debian buster源
log_info "配置Debian buster源..."
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
deb http://archive.debian.org/debian-security buster/updates main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# 安装必要工具
log_info "安装构建工具..."
apt-get update
apt-get -y install \
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
    pv \
    kpartx

# 创建目录结构
log_info "创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/boot,boot/grub/x86_64-efi,isolinux,live}
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${WORK_DIR}/tmp"

# 复制OpenWRT镜像
log_info "复制OpenWRT镜像到临时位置..."
mkdir -p "${WORK_DIR}/openwrt"
cp "${OPENWRT_IMG}" "${WORK_DIR}/openwrt/image.img"
OPENWRT_SIZE=$(stat -c%s "${WORK_DIR}/openwrt/image.img")
log_success "OpenWRT镜像已复制 (${OPENWRT_SIZE} bytes)"

# ====== 修复1：使用更简单的debootstrap命令 ======
log_info "引导极简Debian系统（修复版）..."

# 先尝试官方源
DEBIAN_MIRROR="http://archive.debian.org/debian"

# 使用更小的包列表
DEBOOTSTRAP_PACKAGES="locales,linux-image-amd64,live-boot,systemd-sysv,parted,ssh"

if ! debootstrap \
    --arch=amd64 \
    --variant=minbase \
    --include="${DEBOOTSTRAP_PACKAGES}" \
    buster "${CHROOT_DIR}" "${DEBIAN_MIRROR}" 2>&1 | tee /tmp/debootstrap.log; then
    
    log_warning "官方源失败，尝试archive源..."
    DEBIAN_MIRROR="http://archive.debian.org/debian"
    
    if ! debootstrap \
        --arch=amd64 \
        --variant=minbase \
        --include="${DEBOOTSTRAP_PACKAGES}" \
        buster "${CHROOT_DIR}" "${DEBIAN_MIRROR}" 2>&1 | tee -a /tmp/debootstrap.log; then
        
        log_error "debootstrap完全失败"
        cat /tmp/debootstrap.log | tail -50
        exit 1
    fi
fi

# 检查debootstrap是否真的成功
if [ ! -f "${CHROOT_DIR}/bin/bash" ]; then
    log_error "debootstrap未成功创建基本系统"
    exit 1
fi

log_success "Debian极简系统引导成功"

# ====== 修复2：先配置chroot内的APT源，再安装locale-gen ======
log_info "配置chroot内的APT源..."

# 创建chroot配置文件
cat > "${CHROOT_DIR}/chroot-setup.sh" << 'CHROOT_SETUP_EOF'
#!/bin/bash
set -e

echo "🔧 配置chroot环境..."

# 设置环境变量
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C.UTF-8

# 配置APT源
cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian buster main
deb http://archive.debian.org/debian-security buster/updates main
EOF

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

# 更新包列表
apt-get update

# 安装locale-gen和locales
echo "安装locales..."
apt-get install -y --no-install-recommends locales

# 配置locale
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF.UTF-8 2>/dev/null || locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# 安装必要的工具
echo "安装必要工具..."
apt-get install -y --no-install-recommends \
    dialog \
    pv \
    parted \
    openssh-server \
    ssh

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "✅ chroot基础配置完成"
CHROOT_SETUP_EOF

chmod +x "${CHROOT_DIR}/chroot-setup.sh"

# 挂载文件系统到chroot
log_info "挂载文件系统..."
mount -t proc none "${CHROOT_DIR}/proc"
mount -o bind /dev "${CHROOT_DIR}/dev"
mount -o bind /dev/pts "${CHROOT_DIR}/dev/pts"
mount -o bind /sys "${CHROOT_DIR}/sys"

# 复制resolv.conf
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"

# 在chroot内执行基础配置
log_info "在chroot内执行基础配置..."
chroot "${CHROOT_DIR}" /bin/bash -c "/chroot-setup.sh" 2>&1 | tee "${WORK_DIR}/chroot-setup.log"

# 检查是否成功
if ! chroot "${CHROOT_DIR}" /bin/bash -c "command -v locale-gen" >/dev/null 2>&1; then
    log_warning "locale-gen未安装，尝试直接安装..."
    chroot "${CHROOT_DIR}" /bin/bash -c "apt-get update && apt-get install -y locales"
fi

# ====== 修复3：创建完整的安装脚本 ======
log_info "创建完整的安装脚本..."
cat > "${CHROOT_DIR}/install-chroot.sh" << 'CHROOT_EOF'
#!/bin/bash
# OpenWRT安装系统chroot配置脚本（完整版）
set -e

echo "🔧 开始配置安装环境..."

# 设置环境
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=en_US.UTF-8

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 配置DNS（使用系统默认）
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# ====== 修复4：确保内核安装成功 ======
echo "检查内核..."
if [ ! -f /boot/vmlinuz-* ] && [ ! -f /vmlinuz ]; then
    echo "未找到内核，安装linux-image-amd64..."
    apt-get update
    apt-get install -y --no-install-recommends linux-image-amd64
fi

# 检查initrd
if [ ! -f /boot/initrd.img-* ] && [ ! -f /initrd.img ]; then
    echo "生成initrd..."
    update-initramfs -c -k all 2>/dev/null || true
fi

# === 配置自动登录和自动启动 ===
echo "配置自动登录和启动..."

# 1. 设置root无密码登录
usermod -p '*' root
passwd -d root 2>/dev/null || true

# 2. 创建启动脚本目录
mkdir -p /opt

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

sleep 3

# 挂载OpenWRT镜像
if [ -f /mnt/openwrt/image.img ]; then
    echo "✅ OpenWRT image found"
    if [ ! -f /openwrt.img ]; then
        cp /mnt/openwrt/image.img /openwrt.img
    fi
    echo "Image size: $(ls -lh /openwrt.img 2>/dev/null | awk '{print $5}' || echo 'unknown')"
else
    echo "⚠️  WARNING: OpenWRT image not found in /mnt/openwrt/"
    echo "Looking for alternative locations..."
    find / -name "*.img" -type f 2>/dev/null | head -5
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

# 检查OpenWRT镜像
if [ ! -f /openwrt.img ]; then
    echo "❌ ERROR: OpenWRT image not found!"
    echo ""
    echo "Available image files:"
    find / -name "*.img" -type f 2>/dev/null || echo "No image files found"
    echo ""
    echo "Press Enter for shell..."
    read
    exec /bin/bash
fi

echo "✅ OpenWRT image found: /openwrt.img"
echo "Size: $(ls -lh /openwrt.img | awk '{print $5}')"
echo ""

while true; do
    # 显示磁盘
    echo "Available disks:"
    echo "================="
    lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null || echo "No disks found"
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
        SYNC_RESULT=$?
    else
        echo "Using dd without progress bar..."
        dd if=/openwrt.img of="/dev/$DISK" bs=4M status=progress conv=fsync
        SYNC_RESULT=$?
    fi
    
    sync
    
    if [ $SYNC_RESULT -eq 0 ]; then
        echo ""
        echo "✅ Installation complete!"
        echo ""
        
        echo "Installation successful!"
        echo "1. Press 'R' to reboot"
        echo "2. Press 'S' to start shell"
        echo "3. Press any other key to install another disk"
        echo ""
        read -n1 -t30 -p "Choice: " CHOICE
        echo ""
        
        case "$CHOICE" in
            [Rr]) reboot -f ;;
            [Ss]) exec /bin/bash ;;
            *) continue ;;
        esac
    else
        echo ""
        echo "❌ Installation failed!"
        echo "Error code: $SYNC_RESULT"
        echo ""
        echo "Press Enter to continue..."
        read
    fi
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

# 6. 创建自动启动服务
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

# 7. 启用服务
systemctl enable autoinstall.service
systemctl enable ssh

# 8. 配置SSH
mkdir -p /root/.ssh
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "PermitEmptyPasswords yes" >> /etc/ssh/sshd_config

# 9. 创建bash配置
cat > /root/.bashrc << 'BASHRC'
# OpenWRT安装系统bash配置
export PS1='\[\e[1;32m\]\u@openwrt-installer\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
alias ll='ls -la'
alias l='ls -l'
BASHRC

# 10. 创建挂载点
mkdir -p /mnt/openwrt

# 11. 删除machine-id
rm -f /etc/machine-id
ln -s /run/machine-id /etc/machine-id 2>/dev/null || true

# 12. 配置live-boot
echo "live" > /etc/live/boot.conf
mkdir -p /etc/live/boot

# 13. 清理系统
echo "清理系统..."
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/*

# 删除不必要的文档
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* 2>/dev/null || true

# 保留必要的locale
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en*' ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true

echo "✅ chroot配置完成"

# 14. 验证内核存在
echo "验证内核文件..."
if ls /boot/vmlinuz-* 1> /dev/null 2>&1; then
    echo "✅ 内核文件存在"
    ls -la /boot/vmlinuz-* | head -5
else
    echo "❌ 内核文件不存在，尝试修复..."
    # 尝试重新安装内核
    apt-get update
    apt-get install -y --reinstall linux-image-amd64
fi

if ls /boot/initrd.img-* 1> /dev/null 2>&1; then
    echo "✅ initrd文件存在"
    ls -la /boot/initrd.img-* | head -5
fi
CHROOT_EOF

chmod +x "${CHROOT_DIR}/install-chroot.sh"

# 执行安装脚本
log_info "在chroot内执行安装脚本..."
chroot "${CHROOT_DIR}" /bin/bash -c "/install-chroot.sh" 2>&1 | tee "${WORK_DIR}/chroot-install.log"

# 清理临时脚本
rm -f "${CHROOT_DIR}/chroot-setup.sh"
rm -f "${CHROOT_DIR}/install-chroot.sh"

# ====== 修复5：检查内核文件并复制 ======
log_info "检查内核文件..."

# 查找内核文件
KERNEL_FILES=$(find "${CHROOT_DIR}" -name "vmlinuz*" -type f | grep -v '\.bak$' | head -5)
INITRD_FILES=$(find "${CHROOT_DIR}" -name "initrd*" -type f | head -5)

echo "找到的内核文件:"
echo "$KERNEL_FILES"

echo "找到的initrd文件:"
echo "$INITRD_FILES"

# 如果没有内核文件，尝试手动复制
if [ -z "$KERNEL_FILES" ]; then
    log_warning "未找到内核文件，从主机系统复制..."
    
    # 检查主机系统的内核
    HOST_KERNEL=$(find /boot -name "vmlinuz-*" -type f | head -1)
    if [ -f "$HOST_KERNEL" ]; then
        cp "$HOST_KERNEL" "${CHROOT_DIR}/boot/vmlinuz-$(uname -r)"
        log_success "从主机复制内核: $(basename $HOST_KERNEL)"
        KERNEL_FILES="${CHROOT_DIR}/boot/vmlinuz-$(uname -r)"
    else
        log_error "主机系统也找不到内核文件"
        exit 1
    fi
fi

# 如果没有initrd，尝试生成
if [ -z "$INITRD_FILES" ]; then
    log_warning "未找到initrd，尝试生成..."
    chroot "${CHROOT_DIR}" /bin/bash -c "update-initramfs -c -k all 2>&1 || true"
    INITRD_FILES=$(find "${CHROOT_DIR}" -name "initrd*" -type f | head -5)
fi

# 选择最新的内核文件
KERNEL_FILE=$(echo "$KERNEL_FILES" | sort -V | tail -1)
INITRD_FILE=$(echo "$INITRD_FILES" | sort -V | tail -1)
echo  "test:  ============= $KERNEL_FILE  $INITRD_FILE"
if [ ! -f "$KERNEL_FILE" ]; then
    log_error "内核文件不存在: $KERNEL_FILE"
    exit 1
fi

if [ ! -f "$INITRD_FILE" ]; then
    log_warning "initrd文件不存在，继续构建但可能无法启动"
fi

# 卸载chroot文件系统
log_info "卸载chroot文件系统..."
umount "${CHROOT_DIR}/proc" 2>/dev/null || true
umount "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
umount "${CHROOT_DIR}/dev" 2>/dev/null || true
umount "${CHROOT_DIR}/sys" 2>/dev/null || true

# ====== 修复6：简化squashfs创建，不使用排除列表 ======
log_info "复制OpenWRT镜像到live目录..."
mkdir -p "${STAGING_DIR}/live/openwrt"
cp "${WORK_DIR}/openwrt/image.img" "${STAGING_DIR}/live/openwrt/image.img"

log_info "创建squashfs文件系统..."

# 首先检查chroot目录大小
CHROOT_SIZE=$(du -sh "${CHROOT_DIR}" | cut -f1)
log_info "chroot目录大小: ${CHROOT_SIZE}"

# 创建squashfs（使用简单方法）
SQUASHFS_FILE="${STAGING_DIR}/live/filesystem.squashfs"
echo "开始创建squashfs，这可能需要几分钟..."

# 使用更简单的排除选项
if mksquashfs "${CHROOT_DIR}" "${SQUASHFS_FILE}" \
    -comp xz \
    -b 1M \
    -noappend \
    -no-recovery \
    -no-progress \
    -e "boot/*" \
    -e "dev/*" \
    -e "proc/*" \
    -e "sys/*" \
    -e "tmp/*" \
    -e "run/*" \
    -e "${CHROOT_DIR}/tmp/*" \
    -e "${CHROOT_DIR}/var/tmp/*" \
    -e "${CHROOT_DIR}/var/cache/*" \
    -e "${CHROOT_DIR}/var/log/*" 2>&1 | tee /tmp/mksquashfs.log; then
    
    SQUASHFS_SIZE=$(stat -c%s "${SQUASHFS_FILE}")
    log_success "squashfs创建成功 (${SQUASHFS_SIZE} bytes)"
else
    log_warning "第一次尝试失败，使用更简单的方法..."
    
    # 备份重要文件后删除整个chroot，再创建
    mkdir -p "${WORK_DIR}/backup"
    cp "$KERNEL_FILE" "${WORK_DIR}/backup/vmlinuz" 2>/dev/null || true
    cp "$INITRD_FILE" "${WORK_DIR}/backup/initrd" 2>/dev/null || true
    
    # 删除chroot中的大目录
    rm -rf "${CHROOT_DIR}/usr/share/doc" \
           "${CHROOT_DIR}/usr/share/man" \
           "${CHROOT_DIR}/usr/share/info" \
           "${CHROOT_DIR}/var/lib/apt/lists"
    
    # 再次尝试
    mksquashfs "${CHROOT_DIR}" "${SQUASHFS_FILE}" \
        -comp gzip \
        -b 1M \
        -noappend 2>&1 | tee -a /tmp/mksquashfs.log || {
        log_error "squashfs创建失败"
        exit 1
    }
fi

# 创建live-boot需要的文件
echo "live" > "${STAGING_DIR}/live/filesystem.squashfs.type"

# ====== 修复7：复制内核和initrd到正确位置 ======
log_info "复制内核和initrd到live目录..."

# 确保有内核文件
if [ -f "$KERNEL_FILE" ]; then
    cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
    log_success "内核复制成功: $(basename $KERNEL_FILE)"
    
    # 同时复制到boot目录用于grub
    mkdir -p "${STAGING_DIR}/boot"
    cp "$KERNEL_FILE" "${STAGING_DIR}/boot/vmlinuz"
else
    log_error "找不到内核文件"
    # 尝试从备份恢复
    if [ -f "${WORK_DIR}/backup/vmlinuz" ]; then
        cp "${WORK_DIR}/backup/vmlinuz" "${STAGING_DIR}/live/vmlinuz"
        log_warning "使用备份的内核文件"
    else
        exit 1
    fi
fi
INITRD_FILE=/boot/initrd.img-4.19.0-21-amd64
if [ -f "$INITRD_FILE" ]; then
    cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"
    log_success "initrd复制成功: $(basename $INITRD_FILE)"
    
    # 同时复制到boot目录
    cp "$INITRD_FILE" "${STAGING_DIR}/boot/initrd.img"
else
    log_warning "找不到initrd文件，ISO可能无法正常启动"
    touch "${STAGING_DIR}/live/initrd"  # 创建空文件避免错误
fi
echo "  vmlinuz: $(du -h ${STAGING_DIR}/live/vmlinuz | cut -f1)"
echo "  initrd.img: $(du -h ${STAGING_DIR}/live/initrd.img | cut -f1)"
    

# ====== 创建引导配置文件 ======
log_info "创建引导配置..."

# 1. ISOLINUX配置
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT live
PROMPT 0
TIMEOUT 50
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

# 复制必要的syslinux模块
for module in ldlinux.c32 libcom32.c32 libutil.c32 menu.c32; do
    if [ -f "/usr/lib/syslinux/modules/bios/${module}" ]; then
        cp "/usr/lib/syslinux/modules/bios/${module}" "${STAGING_DIR}/isolinux/" 2>/dev/null || true
	echo -${module}
    fi
done

# 创建UEFI引导
log_info "创建UEFI引导..."
if command -v grub-mkstandalone >/dev/null 2>&1; then
    mkdir -p "${WORK_DIR}/grub-efi"
    
    # 创建GRUB standalone配置
    cat > "${WORK_DIR}/grub-efi/grub.cfg" << 'GRUB_EFI_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd
}
GRUB_EFI_CFG
    
    # 生成EFI文件
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="${WORK_DIR}/grub-efi/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=${WORK_DIR}/grub-efi/grub.cfg" 2>&1 | tee /tmp/grub.log || \
        log_warning "GRUB standalone创建失败"
    
    # 如果成功，创建EFI映像
    if [ -f "${WORK_DIR}/grub-efi/bootx64.efi" ]; then
        EFI_SIZE=$(( $(stat -c%s "${WORK_DIR}/grub-efi/bootx64.efi") + 1048576 ))
        
        dd if=/dev/zero of="${STAGING_DIR}/EFI/boot/efiboot.img" bs=1 count=0 seek=${EFI_SIZE}
        mkfs.vfat -F 32 "${STAGING_DIR}/EFI/boot/efiboot.img" >/dev/null 2>&1 || true
        
        # 复制EFI文件
        mmd -i "${STAGING_DIR}/EFI/boot/efiboot.img" ::/EFI 2>/dev/null || true
        mmd -i "${STAGING_DIR}/EFI/boot/efiboot.img" ::/EFI/BOOT 2>/dev/null || true
        mcopy -i "${STAGING_DIR}/EFI/boot/efiboot.img" \
            "${WORK_DIR}/grub-efi/bootx64.efi" ::/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true
        
        log_success "UEFI引导文件创建完成"
    fi
fi

# ====== 构建ISO镜像 ======
log_info "构建ISO镜像..."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# 基础xorriso命令
XORRISO_CMD="xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid 'OPENWRT_INSTALL' \
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
        -no-emul-boot"
fi

# 执行构建
echo "执行命令: $XORRISO_CMD"
eval $XORRISO_CMD 2>&1 | tee /tmp/xorriso.log

# 验证ISO
if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    ISO_SIZE_BYTES=$(stat -c%s "$ISO_PATH")
    
    echo ""
    echo "================================================================================"
    log_success "✅ ISO构建成功！"
    echo "================================================================================"
    echo ""
    echo "📊 构建摘要："
    echo "  文件: ${ISO_NAME}"
    echo "  大小: ${ISO_SIZE} (${ISO_SIZE_BYTES} bytes)"
    echo "  位置: ${ISO_PATH}"
    echo "  内核: $(basename $KERNEL_FILE)"
    echo "  initrd: $(basename $INITRD_FILE 2>/dev/null || echo 'N/A')"
    echo "  squashfs: $(ls -lh "${SQUASHFS_FILE}" | awk '{print $5}')"
    echo ""
    
    # 显示ISO信息
    echo "🔍 ISO信息："
    echo ""
    
    # 创建构建信息文件
    cat > "${OUTPUT_DIR}/build-info.txt" << BUILD_INFO
OpenWRT Auto Installer ISO
===========================
构建时间: $(date)
ISO文件: ${ISO_NAME}
文件大小: ${ISO_SIZE} (${ISO_SIZE_BYTES} bytes)
内核版本: $(basename $KERNEL_FILE)
initrd版本: $(basename $INITRD_FILE 2>/dev/null || echo 'N/A')
支持引导: BIOS $( [ -f "${STAGING_DIR}/EFI/boot/efiboot.img" ] && echo "+ UEFI" )
引导菜单:
  1. Install OpenWRT (Automatic) - 自动安装OpenWRT
  2. Rescue Shell - 救援Shell

使用方法:
  1. 刻录到U盘: sudo dd if=${ISO_NAME} of=/dev/sdX bs=4M status=progress
  2. 从U盘启动计算机
  3. 系统将自动启动安装程序
  4. 选择目标磁盘并确认安装
  5. 等待安装完成

警告: 安装会完全擦除目标磁盘上的所有数据！
BUILD_INFO
    
    log_success "构建信息已保存到: ${OUTPUT_DIR}/build-info.txt"
    
    echo ""
    echo "🎉 构建完成！现在可以使用该ISO安装OpenWRT。"
    echo ""
    
else
    log_error "ISO构建失败"
    echo "xorriso错误日志:"
    tail -20 /tmp/xorriso.log
    exit 1
fi

# 清理工作目录（可选）
# log_info "清理工作目录..."
# rm -rf "${WORK_DIR}"

log_success "所有步骤完成！"
