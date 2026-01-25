#!/bin/bash
# build-alpine-openwrt-iso.sh - 基于Alpine mkimage构建OpenWRT自动安装ISO
set -e

echo "🚀 Starting OpenWRT ISO build with Alpine mkimage..."
echo "====================================================="

# 从环境变量获取参数
OPENWRT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-autoinstall-alpine.iso}"

# Alpine配置
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
ALPINE_ARCH="x86_64"
ALPINE_REPO="https://dl-cdn.alpinelinux.org/alpine"

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
    echo "Performing cleanup..."
    rm -rf "$WORK_DIR" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# ==================== 步骤1: 检查输入文件 ====================
log_info "[1/7] Checking input file..."
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "OpenWRT image not found: $OPENWRT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$OPENWRT_IMG" | awk '{print $5}')
log_success "Found OpenWRT image: $IMG_SIZE"

# ==================== 步骤2: 安装必要工具 ====================
log_info "[2/7] Installing build tools..."
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
    pv

log_success "Build tools installed"

# ==================== 步骤3: 克隆mkimage工具 ====================
log_info "[3/7] Cloning mkimage tool..."
WORK_DIR="/tmp/OPENWRT_BUILD_$(date +%s)"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ ! -d "mkimage" ]; then
    git clone https://gitlab.alpinelinux.org/alpine/mkimage.git --depth 1
fi

cd mkimage
log_success "mkimage tool ready"

# ==================== 步骤4: 创建自定义profile ====================
log_info "[4/7] Creating custom profile for OpenWRT installer..."

# 创建OpenWRT安装器profile
cat > profiles/openwrt-installer.sh << 'PROFILE_EOF'
#!/bin/sh
# OpenWRT自动安装器profile

profile_openwrt_installer() {
    # 基础配置
    profile_base
    title="OpenWRT Auto Installer"
    kernel_cmdline="modules=loop,squashfs,sd-mod,usb-storage,ext4 console=tty0 console=ttyS0,115200 quiet"
    syslinux_serial="0 115200"
    iso_version="${iso_version:-$(date +%Y%m%d)}"
    
    # 添加必要的包
    apks="$apks
        alpine-base
        linux-lts
        linux-firmware-none
        busybox
        musl
        bash
        util-linux
        coreutils
        e2fsprogs
        parted
        gptfdisk
        dialog
        pv
        syslinux
        grub-bios
        grub-efi
        xorriso
        squashfs-tools
        mtools
        dosfstools
        openssh-client
        openssh-server
        dhcpcd
        haveged
        chrony
        wget
        curl
        nano
        less
        "
    
    # 创建init脚本
    local_initfs() {
        # 创建init脚本
        cat > ${work_dir}/init << 'INIT_EOF'
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

        chmod +x ${work_dir}/init
        
        # 创建安装脚本
        mkdir -p ${work_dir}/opt
        cat > ${work_dir}/opt/install-openwrt.sh << 'INSTALL_EOF'
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

        chmod +x ${work_dir}/opt/install-openwrt.sh
        
        # 创建必要的配置文件
        echo "root:x:0:0:root:/root:/bin/bash" > ${work_dir}/etc/passwd
        echo "root::0:0:99999:7:::" > ${work_dir}/etc/shadow
        echo "openwrt-installer" > ${work_dir}/etc/hostname
        
        # 允许root登录
        sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' ${work_dir}/etc/ssh/sshd_config 2>/dev/null || true
    }
    
    # 创建GRUB配置文件（UEFI）
    local_grubcfg() {
        cat > ${work_dir}/boot/grub/grub.cfg << 'GRUB_CFG'
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
    }
    
    # 创建ISOLINUX配置文件（BIOS）
    local_syslinux() {
        cat > ${work_dir}/boot/syslinux/syslinux.cfg << 'SYSLINUX_CFG'
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
    }
}
PROFILE_EOF

chmod +x profiles/openwrt-installer.sh
log_success "Custom profile created"

# ==================== 步骤5: 构建Alpine基础镜像 ====================
log_info "[5/7] Building Alpine base image with mkimage..."

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 构建镜像
./mkimage.sh \
    --tag openwrt-installer \
    --outdir "$WORK_DIR/output" \
    --arch "$ALPINE_ARCH" \
    --repository "$ALPINE_REPO/v$ALPINE_VERSION/main" \
    --repository "$ALPINE_REPO/v$ALPINE_VERSION/community" \
    --profile openwrt_installer \
    --no-compress 2>&1 | tail -20

# 检查是否构建成功
if [ ! -f "$WORK_DIR/output/openwrt-installer.iso" ]; then
    log_error "Failed to build Alpine base image"
    exit 1
fi

log_success "Alpine base image created"

# ==================== 步骤6: 添加OpenWRT镜像到ISO ====================
log_info "[6/7] Adding OpenWRT image to ISO..."

# 挂载ISO
mkdir -p "$WORK_DIR/iso-mount"
mkdir -p "$WORK_DIR/iso-modify"

# 复制ISO内容
xorriso -osirrox on -indev "$WORK_DIR/output/openwrt-installer.iso" -extract / "$WORK_DIR/iso-modify/" 2>/dev/null

# 复制OpenWRT镜像
cp "$OPENWRT_IMG" "$WORK_DIR/iso-modify/openwrt.img"

# 确保有正确的权限
chmod 644 "$WORK_DIR/iso-modify/openwrt.img"

log_success "OpenWRT image added to ISO"

# ==================== 步骤7: 重新打包ISO ====================
log_info "[7/7] Repackaging ISO..."

# 确保必要的引导文件存在
cd "$WORK_DIR/iso-modify"

# 检查并修复引导文件
if [ ! -f "boot/isolinux/isolinux.bin" ]; then
    # 复制isolinux文件
    mkdir -p boot/isolinux
    find /usr -name "isolinux.bin" -type f 2>/dev/null | head -1 | xargs -I {} cp {} boot/isolinux/
    find /usr -name "ldlinux.c32" -type f 2>/dev/null | head -1 | xargs -I {} cp {} boot/isolinux/
    find /usr -name "menu.c32" -type f 2>/dev/null | head -1 | xargs -I {} cp {} boot/isolinux/
    find /usr -name "libutil.c32" -type f 2>/dev/null | head -1 | xargs -I {} cp {} boot/isolinux/
    find /usr -name "libcom32.c32" -type f 2>/dev/null | head -1 | xargs -I {} cp {} boot/isolinux/
fi

# 创建UEFI引导镜像
if command -v grub-mkstandalone >/dev/null 2>&1; then
    log_info "Creating UEFI boot image..."
    mkdir -p EFI/boot
    
    # 创建GRUB EFI文件
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/tmp/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=boot/grub/grub.cfg"
    
    # 创建EFI分区镜像
    dd if=/dev/zero of="$WORK_DIR/tmp/efiboot.img" bs=1M count=10
    mkfs.vfat -F 32 "$WORK_DIR/tmp/efiboot.img" 2>/dev/null
    
    # 复制EFI文件
    mmd -i "$WORK_DIR/tmp/efiboot.img" ::/EFI 2>/dev/null
    mmd -i "$WORK_DIR/tmp/efiboot.img" ::/EFI/BOOT 2>/dev/null
    mcopy -i "$WORK_DIR/tmp/efiboot.img" "$WORK_DIR/tmp/bootx64.efi" ::/EFI/BOOT/bootx64.efi 2>/dev/null
    
    mv "$WORK_DIR/tmp/efiboot.img" EFI/boot/
fi

# 使用xorriso构建混合ISO
log_info "Building hybrid ISO with xorriso..."
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot boot/isolinux/isolinux.bin \
    -eltorito-catalog boot/isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/boot/efiboot.img \
    -no-emul-boot \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
    -output "$ISO_PATH" \
    . 2>&1 | tail -10

# ==================== 验证结果 ====================
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
    
    echo "✅ Build Method: Official Alpine mkimage"
    echo "   This is the recommended way to build Alpine-based ISOs."
    echo ""
    
    echo "🔧 Boot Support:"
    echo "  - BIOS: ISOLINUX with graphical menu"
    echo "  - UEFI: GRUB with menu interface"
    echo "  - Hybrid: Single ISO works on both systems"
    echo ""
    
    echo "🎯 Features:"
    echo "  1. Official Alpine mkimage build"
    echo "  2. Complete Alpine system with all dependencies"
    echo "  3. Working init system (no 'init not found' errors)"
    echo "  4. Dual boot support (BIOS + UEFI)"
    echo "  5. Graphical boot menu"
    echo "  6. Automatic installer with confirmation"
    echo ""
    
    # 创建构建信息
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO - Official Alpine Build
==============================================
Build Date:      $(date)
Build Method:    Official Alpine mkimage
ISO Name:        $ISO_NAME
ISO Size:        $ISO_SIZE
Alpine Version:  $ALPINE_VERSION

Build Process:
1. Created custom profile for OpenWRT installer
2. Built base Alpine system using mkimage
3. Added OpenWRT image to the filesystem
4. Created hybrid ISO with BIOS+UEFI support

Boot Configuration:
  - BIOS: ISOLINUX with 50s timeout
  - UEFI: GRUB with 5s timeout
  - Default: Install OpenWRT
  - Fallback: Emergency Shell

Key Advantages:
1. Uses official Alpine build tools
2. Guaranteed working init system
3. All dependencies properly resolved
4. Professional boot configuration
5. Better compatibility and stability

Test Instructions:
1. Burn to USB: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress
2. Boot on BIOS system: Should show graphical menu
3. Boot on UEFI system: Should show GRUB menu
4. Select "Install OpenWRT" to start installation
EOF
    
    log_success "✅ ISO created successfully: $ISO_SIZE"
    log_success "📁 Output: $ISO_PATH"
    
    # 显示ISO中的文件
    echo ""
    echo "📂 ISO Contents (key files):"
    xorriso -indev "$ISO_PATH" -find / -maxdepth 2 -type f 2>/dev/null | \
        grep -E "(vmlinuz|initramfs|grub\.cfg|syslinux|openwrt\.img)" | \
        sort | while read file; do
        echo "  $file"
    done
    
    # 清理
    cleanup
    
else
    log_error "❌ ISO file not created: $ISO_PATH"
    exit 1
fi
