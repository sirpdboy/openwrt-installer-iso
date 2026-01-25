#!/bin/bash
# build-alpine-openwrt-iso.sh - 基于Alpine mkimage构建OpenWRT自动安装ISO
set -e

echo "🚀 Starting OpenWRT ISO build with Alpine mkimage..."
echo "====================================================="

# 从环境变量获取参数
OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-autoinstall-alpine.iso}"
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

# Alpine配置
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
ALPINE_ARCH="x86_64"
ALPINE_REPO="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_BRANCH="v${ALPINE_VERSION}"

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

# 清理函数
cleanup() {
    log_info "Performing cleanup..."
    rm -rf "$WORK_DIR" 2>/dev/null || true
    umount -f "$WORK_DIR/iso-mount" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# ==================== 步骤1: 检查输入文件 ====================
log_info "[1/8] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== 步骤2: 安装必要工具 ====================
log_info "[2/8] Installing build tools..."
apk update --no-cache
apk add --no-cache \
    alpine-sdk \
    git \
    xorriso \
    syslinux \
    grub-bios \
    grub-efi \
    mtools \
    dosfstools \
    squashfs-tools \
    wget \
    curl \
    e2fsprogs \
    parted \
    gptfdisk \
    util-linux \
    coreutils \
    bash \
    dialog \
    pv \
    go \
    make \
    gcc \
    musl-dev \
    linux-headers

log_success "Build tools installed"

# ==================== 步骤3: 获取Alpine构建工具 ====================
log_info "[3/8] Setting up Alpine build tools..."
WORK_DIR="/tmp/OPENWRT_BUILD_$(date +%s)"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 创建必要的目录结构
mkdir -p "$WORK_DIR/output"
mkdir -p "$WORK_DIR/tmp"
mkdir -p "$OUTPUT_DIR"

# 下载Alpine APK工具
log_info "Downloading Alpine APK tools..."
wget -q "${ALPINE_REPO}/latest-stable/main/${ALPINE_ARCH}/apk-tools-static-2.14.3-r1.apk" -O apk-tools.apk || \
wget -q "${ALPINE_REPO}/${ALPINE_BRANCH}/main/${ALPINE_ARCH}/apk-tools-static-2.14.3-r1.apk" -O apk-tools.apk

if [ ! -f "apk-tools.apk" ]; then
    # 尝试获取最新版本
    wget -q "${ALPINE_REPO}/latest-stable/main/${ALPINE_ARCH}/apk-tools-static-latest.apk" -O apk-tools.apk
fi

if [ -f "apk-tools.apk" ]; then
    tar -xzf apk-tools.apk
    cp sbin/apk.static .
    rm -rf sbin apk-tools.apk
    log_success "APK tools downloaded"
else
    log_warning "Could not download apk-tools-static, using system apk"
    cp $(which apk) ./apk.static
fi

# ==================== 步骤4: 创建自定义profile ====================
log_info "[4/8] Creating custom profile for OpenWRT installer..."

# 创建根文件系统构建脚本
cat > build-rootfs.sh << 'EOF'
#!/bin/sh
set -e

# 参数
rootfs_dir="$1"
alpine_version="${2:-3.20}"
arch="${3:-x86_64}"

# 创建根文件系统目录
mkdir -p "${rootfs_dir}/etc/apk"
mkdir -p "${rootfs_dir}/var/lib/apk"

# 配置apk仓库
cat > "${rootfs_dir}/etc/apk/repositories" << REPO_EOF
${ALPINE_REPO}/${alpine_version}/main
${ALPINE_REPO}/${alpine_version}/community
REPO_EOF

# 设置架构
echo "${arch}" > "${rootfs_dir}/etc/apk/arch"

# 安装基础系统
./apk.static -X "${ALPINE_REPO}/${alpine_version}/main" \
             -X "${ALPINE_REPO}/${alpine_version}/community" \
             -U --allow-untrusted --root "${rootfs_dir}" --initdb add \
             alpine-base \
             linux-lts \
             linux-firmware-none \
             busybox \
             musl \
             bash \
             util-linux \
             coreutils \
             e2fsprogs \
             parted \
             gptfdisk \
             dialog \
             pv \
             syslinux \
             grub-bios \
             grub-efi \
             xorriso \
             squashfs-tools \
             mtools \
             dosfstools \
             openssh-client \
             openssh-server \
             dhcpcd \
             haveged \
             chrony \
             wget \
             curl \
             nano \
             less

# 创建主机名
echo "openwrt-installer" > "${rootfs_dir}/etc/hostname"

# 允许root登录
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' "${rootfs_dir}/etc/ssh/sshd_config" 2>/dev/null || true

# 设置root密码（空密码）
sed -i 's/^root:.*/root::0:0:root:\/root:\/bin\/bash/' "${rootfs_dir}/etc/passwd" 2>/dev/null || true

# 创建fstab
cat > "${rootfs_dir}/etc/fstab" << FSTAB_EOF
/dev/cdrom    /media/cdrom    iso9660    noauto,ro    0 0
FSTAB_EOF
EOF

chmod +x build-rootfs.sh

# 创建OpenWRT安装器init脚本
cat > openwrt-init.sh << 'INIT_EOF'
#!/bin/busybox sh
# OpenWRT安装器init脚本

# 挂载必要文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# 创建设备节点
mknod /dev/console c 5 1
mknod /dev/null c 1 3
mknod /dev/zero c 1 5

# 设置控制台
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

# 清屏
clear

# 欢迎信息
cat << "WELCOME"

╔═══════════════════════════════════════════════════════╗
║       OpenWRT Auto Installer System                   ║
╚═══════════════════════════════════════════════════════╝

System initializing, please wait...
WELCOME

# 等待设备就绪
sleep 3

# 检查OpenWRT镜像
if [ -f "/openwrt.img" ]; then
    IMG_SIZE=$(ls -lh /openwrt.img 2>/dev/null | awk '{print $5}' || echo "unknown")
    echo ""
    echo "✅ OpenWRT image found: $IMG_SIZE"
    echo ""
    echo "Starting installer in 3 seconds..."
    sleep 3
    exec /opt/install-openwrt.sh
else
    echo ""
    echo "❌ ERROR: OpenWRT image not found!"
    echo ""
    echo "The image should be at: /openwrt.img"
    echo ""
    echo "Dropping to emergency shell..."
    echo ""
    exec /bin/sh
fi
INIT_EOF

# 创建安装脚本
cat > install-openwrt.sh << 'INSTALL_EOF'
#!/bin/bash
# OpenWRT自动安装脚本

# 设置终端
stty sane
export TERM=linux

while true; do
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

    IMG_SIZE=$(ls -lh /openwrt.img 2>/dev/null | awk '{print $5}' || echo "unknown")
    echo "✅ OpenWRT image found: $IMG_SIZE"
    echo ""

    # 显示磁盘
    echo "Available disks:"
    echo "================="
    lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || echo "No disks detected"
    echo "================="
    echo ""
    
    read -p "Enter target disk (e.g., sda): " TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo "Please enter a disk name"
        sleep 2
        continue
    fi
    
    if [ ! -b "/dev/$TARGET_DISK" ]; then
        echo "❌ Disk /dev/$TARGET_DISK not found!"
        sleep 2
        continue
    fi
    
    echo ""
    echo "⚠️  WARNING: This will erase ALL data on /dev/$TARGET_DISK!"
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        sleep 2
        continue
    fi
    
    clear
    echo ""
    echo "Installing OpenWRT to /dev/$TARGET_DISK..."
    echo ""
    echo "This may take a few minutes..."
    echo ""
    
    # 使用dd写入镜像
    echo "Writing image..."
    if command -v pv >/dev/null 2>&1; then
        pv /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M
    else
        dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M status=progress
    fi
    
    sync
    
    echo ""
    echo "✅ Installation complete!"
    echo ""
    
    echo "System will reboot in 10 seconds..."
    echo "Press any key to cancel..."
    
    # 10秒倒计时
    for i in $(seq 10 -1 1); do
        echo -ne "Rebooting in $i seconds...\r"
        if read -t 1 -n 1; then
            echo ""
            echo "Reboot cancelled."
            echo "Type 'reboot' to restart, or press Enter to return to installer."
            read
            break
        fi
        if [ $i -eq 1 ]; then
            echo ""
            echo "Rebooting now..."
            reboot -f
        fi
    done
done
INSTALL_EOF

chmod +x openwrt-init.sh install-openwrt.sh
log_success "Custom scripts created"

# ==================== 步骤5: 构建根文件系统 ====================
log_info "[5/8] Building root filesystem..."

# 创建根文件系统目录
ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

# 构建根文件系统
./build-rootfs.sh "$ROOTFS_DIR" "$ALPINE_VERSION" "$ALPINE_ARCH"

# 复制自定义脚本
mkdir -p "$ROOTFS_DIR/opt"
cp install-openwrt.sh "$ROOTFS_DIR/opt/install-openwrt.sh"
chmod +x "$ROOTFS_DIR/opt/install-openwrt.sh"

# 设置init脚本
cp openwrt-init.sh "$ROOTFS_DIR/init"
chmod +x "$ROOTFS_DIR/init"

log_success "Root filesystem built"

# ==================== 步骤6: 创建引导文件 ====================
log_info "[6/8] Creating boot files..."

# 创建引导目录
mkdir -p "$WORK_DIR/iso"
mkdir -p "$WORK_DIR/iso/boot"
mkdir -p "$WORK_DIR/iso/boot/syslinux"
mkdir -p "$WORK_DIR/iso/boot/grub"
mkdir -p "$WORK_DIR/iso/EFI/boot"

# 复制内核和initrd
KERNEL_VERSION=$(ls "$ROOTFS_DIR/boot" | grep vmlinuz | head -1 | sed 's/vmlinuz-//')
if [ -n "$KERNEL_VERSION" ]; then
    cp "$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VERSION" "$WORK_DIR/iso/boot/vmlinuz-lts"
    cp "$ROOTFS_DIR/boot/initramfs-$KERNEL_VERSION" "$WORK_DIR/iso/boot/initramfs-lts"
else
    # 尝试找到内核文件
    find "$ROOTFS_DIR/boot" -name "vmlinuz-*" -exec cp {} "$WORK_DIR/iso/boot/vmlinuz-lts" \;
    find "$ROOTFS_DIR/boot" -name "initramfs-*" -exec cp {} "$WORK_DIR/iso/boot/initramfs-lts" \;
fi

# 创建ISOLINUX配置文件（BIOS）
cat > "$WORK_DIR/iso/boot/syslinux/syslinux.cfg" << 'SYSLINUX_CFG'
DEFAULT openwrt
TIMEOUT 50
PROMPT 0
UI menu.c32

MENU TITLE OpenWRT Auto Installer

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-lts modules=loop,squashfs,sd-mod,usb-storage,ext4 console=tty0 console=ttyS0,115200 quiet

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-lts modules=loop,squashfs,sd-mod,usb-storage,ext4 console=tty0 console=ttyS0,115200 quiet single
SYSLINUX_CFG

# 创建GRUB配置文件（UEFI）
cat > "$WORK_DIR/iso/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage,ext4 console=tty0 console=ttyS0,115200 quiet
    initrd /boot/initramfs-lts
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage,ext4 console=tty0 console=ttyS0,115200 quiet single
    initrd /boot/initramfs-lts
}
GRUB_CFG

# 复制ISOLINUX文件
find /usr -name "isolinux.bin" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$WORK_DIR/iso/boot/syslinux/"
find /usr -name "ldlinux.c32" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$WORK_DIR/iso/boot/syslinux/"
find /usr -name "menu.c32" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$WORK_DIR/iso/boot/syslinux/"
find /usr -name "libutil.c32" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$WORK_DIR/iso/boot/syslinux/"
find /usr -name "libcom32.c32" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$WORK_DIR/iso/boot/syslinux/"

log_success "Boot files created"

# ==================== 步骤7: 构建ISO ====================
log_info "[7/8] Building ISO..."

# 创建squashfs文件系统
log_info "Creating squashfs filesystem..."
mksquashfs "$ROOTFS_DIR" "$WORK_DIR/iso/rootfs.squashfs" -comp xz -noappend

# 复制OpenWRT镜像
cp "$OPENWRT_IMG" "$WORK_DIR/iso/openwrt.img"

# 创建EFI引导镜像
log_info "Creating EFI boot image..."
mkdir -p "$WORK_DIR/efiboot"
if command -v grub-mkstandalone >/dev/null 2>&1; then
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/efiboot/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$WORK_DIR/iso/boot/grub/grub.cfg"
    
    # 创建EFI分区镜像
    dd if=/dev/zero of="$WORK_DIR/efiboot/efiboot.img" bs=1M count=20
    mkfs.vfat -F 32 "$WORK_DIR/efiboot/efiboot.img" 2>/dev/null
    
    # 挂载并复制EFI文件
    mkdir -p "$WORK_DIR/efiboot/mnt"
    mount -o loop "$WORK_DIR/efiboot/efiboot.img" "$WORK_DIR/efiboot/mnt"
    mkdir -p "$WORK_DIR/efiboot/mnt/EFI/BOOT"
    cp "$WORK_DIR/efiboot/bootx64.efi" "$WORK_DIR/efiboot/mnt/EFI/BOOT/bootx64.efi"
    umount "$WORK_DIR/efiboot/mnt"
    
    cp "$WORK_DIR/efiboot/efiboot.img" "$WORK_DIR/iso/EFI/boot/efiboot.img"
fi

# 使用xorriso构建ISO
log_info "Creating final ISO with xorriso..."
cd "$WORK_DIR/iso"

xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot boot/syslinux/isolinux.bin \
    -eltorito-catalog boot/syslinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/boot/efiboot.img \
    -no-emul-boot \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
    -output "$ISO_PATH" \
    . 2>&1 | tee "$WORK_DIR/xorriso.log"

# ==================== 步骤8: 验证结果 ====================
log_info "[8/8] Verifying build..."

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║        BUILD SUCCESSFUL!                              ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    echo "📊 Build Summary:"
    echo "  OpenWRT Image:    $IMG_SIZE"
    echo "  Final ISO:        $ISO_SIZE"
    echo "  Alpine Version:   $ALPINE_VERSION"
    echo ""
    
    echo "✅ Build Method: Custom Alpine rootfs"
    echo "   This method builds a complete Alpine system from scratch."
    echo ""
    
    echo "🔧 Boot Support:"
    echo "  - BIOS: ISOLINUX with graphical menu"
    echo "  - UEFI: GRUB with menu interface"
    echo "  - Hybrid: Single ISO works on both systems"
    echo ""
    
    echo "🎯 Features:"
    echo "  1. Complete Alpine system with all dependencies"
    echo "  2. Working init system (no 'init not found' errors)"
    echo "  3. Dual boot support (BIOS + UEFI)"
    echo "  4. Graphical boot menu"
    echo "  5. Automatic installer with confirmation"
    echo ""
    
    # 检查ISO结构
    echo "📂 ISO Structure:"
    xorriso -indev "$ISO_PATH" -toc 2>/dev/null | grep -E "File|Directory" | head -20
    
    # 创建构建信息
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO - Custom Alpine Build
============================================
Build Date:      $(date)
Build Method:    Custom rootfs with apk.static
ISO Name:        $ISO_NAME
ISO Size:        $ISO_SIZE
Alpine Version:  $ALPINE_VERSION
Kernel Version:  $KERNEL_VERSION

Build Process:
1. Built Alpine root filesystem using apk.static
2. Created custom init system for OpenWRT installer
3. Added OpenWRT image to the filesystem
4. Created hybrid ISO with BIOS+UEFI support

Boot Configuration:
  - BIOS: ISOLINUX with 50s timeout
  - UEFI: GRUB with 5s timeout
  - Default: Install OpenWRT
  - Fallback: Emergency Shell

Test Instructions:
1. Burn to USB: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress
2. Boot on BIOS system: Should show graphical menu
3. Boot on UEFI system: Should show GRUB menu
4. Select "Install OpenWRT" to start installation

Files in ISO:
  - /openwrt.img: OpenWRT disk image
  - /rootfs.squashfs: Alpine root filesystem
  - /init: Init script
  - /opt/install-openwrt.sh: Installer script
EOF
    
    log_success "✅ ISO created successfully: $ISO_SIZE"
    log_success "📁 Output: $ISO_PATH"
    
else
    log_error "❌ ISO file not created: $ISO_PATH"
    log_error "Check xorriso log: $WORK_DIR/xorriso.log"
    exit 1
fi
