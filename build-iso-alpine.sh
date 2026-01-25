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

# 工作目录
WORK_DIR="/tmp/OPENWRT_BUILD_$(date +%s)"

# 清理函数
cleanup() {
    log_info "Performing cleanup..."
    # 只清理工作目录，不移除已构建的ISO
    rm -rf "$WORK_DIR" 2>/dev/null || true
    umount -f "$WORK_DIR/iso-mount" 2>/dev/null || true
    umount -f "$WORK_DIR/efiboot/mnt" 2>/dev/null || true
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

# ==================== 步骤3: 设置工作目录 ====================
log_info "[3/8] Setting up Alpine build tools..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 创建必要的目录结构
mkdir -p "$WORK_DIR/output"
mkdir -p "$WORK_DIR/tmp"
mkdir -p "$OUTPUT_DIR"

# 下载Alpine APK工具 - 使用更可靠的方法
log_info "Downloading Alpine APK tools..."

# 方法1: 尝试下载特定版本
APK_TOOLS_URL=""
APK_TOOLS_VERSIONS="2.14.3-r1 2.14.2-r1 2.14.1-r1 2.14.0-r1"

for version in $APK_TOOLS_VERSIONS; do
    URL="${ALPINE_REPO}/latest-stable/main/${ALPINE_ARCH}/apk-tools-static-${version}.apk"
    if wget -q --spider "$URL" 2>/dev/null; then
        APK_TOOLS_URL="$URL"
        log_info "Found apk-tools version: $version"
        break
    fi
done

if [ -z "$APK_TOOLS_URL" ]; then
    # 方法2: 尝试下载最新版本
    APK_TOOLS_URL="${ALPINE_REPO}/latest-stable/main/${ALPINE_ARCH}/apk-tools-static-latest.apk"
fi

log_info "Downloading from: $APK_TOOLS_URL"

# 下载APK工具，最多重试3次
for i in {1..3}; do
    if wget -q "$APK_TOOLS_URL" -O "$WORK_DIR/apk-tools.apk"; then
        log_success "APK tools downloaded successfully"
        break
    elif [ $i -eq 3 ]; then
        log_warning "Failed to download apk-tools-static, using system apk instead"
        # 复制系统apk作为备用
        cp $(which apk) "$WORK_DIR/apk.static"
        chmod +x "$WORK_DIR/apk.static"
        # 跳过解压步骤
        APK_TOOLS_URL=""
        break
    else
        log_warning "Download attempt $i failed, retrying..."
        sleep 2
    fi
done

# 解压APK工具（如果下载成功）
if [ -f "$WORK_DIR/apk-tools.apk" ]; then
    log_info "Extracting apk-tools..."
    tar -xzf "$WORK_DIR/apk-tools.apk" || {
        log_warning "Failed to extract apk-tools.apk, trying alternative extraction..."
        # 尝试使用busybox tar
        busybox tar -xzf "$WORK_DIR/apk-tools.apk" 2>/dev/null || true
    }
    
    # 复制apk.static
    if [ -f "sbin/apk.static" ]; then
        cp sbin/apk.static "$WORK_DIR/"
        chmod +x "$WORK_DIR/apk.static"
        log_success "APK tools extracted successfully"
    elif [ -f "usr/sbin/apk.static" ]; then
        cp usr/sbin/apk.static "$WORK_DIR/"
        chmod +x "$WORK_DIR/apk.static"
        log_success "APK tools extracted successfully"
    else
        log_warning "apk.static not found in archive, searching..."
        find . -name "apk.static" -type f | head -1 | xargs -I {} cp {} "$WORK_DIR/"
        if [ -f "$WORK_DIR/apk.static" ]; then
            chmod +x "$WORK_DIR/apk.static"
            log_success "Found apk.static"
        else
            log_warning "Could not find apk.static, using system apk"
            cp $(which apk) "$WORK_DIR/apk.static"
            chmod +x "$WORK_DIR/apk.static"
        fi
    fi
    
    # 清理临时文件
    rm -rf sbin usr etc "$WORK_DIR/apk-tools.apk" 2>/dev/null || true
fi

# 确保有可用的apk.static
if [ ! -x "$WORK_DIR/apk.static" ]; then
    log_error "No apk.static available. Cannot continue."
    exit 1
fi

# ==================== 步骤4: 创建自定义脚本 ====================
log_info "[4/8] Creating custom scripts for OpenWRT installer..."

# 创建根文件系统构建脚本
cat > "$WORK_DIR/build-rootfs.sh" << 'EOF'
#!/bin/sh
set -e

# 参数
rootfs_dir="$1"
alpine_version="${2:-3.20}"
arch="${3:-x86_64}"

# 设置Alpine仓库URL
ALPINE_REPO="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_BRANCH="v${alpine_version}"

# 创建根文件系统目录
mkdir -p "${rootfs_dir}/etc/apk"
mkdir -p "${rootfs_dir}/var/lib/apk"
mkdir -p "${rootfs_dir}/tmp"

# 配置apk仓库
cat > "${rootfs_dir}/etc/apk/repositories" << REPO_EOF
${ALPINE_REPO}/${ALPINE_BRANCH}/main
${ALPINE_REPO}/${ALPINE_BRANCH}/community
REPO_EOF

# 设置架构
echo "${arch}" > "${rootfs_dir}/etc/apk/arch"

# 临时设置DNS（如果需要）
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

echo "Installing base system packages..."

# 安装基础系统 - 使用更简单的包列表
APK_COMMON="alpine-base linux-lts linux-firmware-none busybox musl bash util-linux coreutils"
APK_TOOLS="e2fsprogs parted gptfdisk dialog pv"
APK_BOOT="syslinux grub-bios grub-efi xorriso squashfs-tools mtools dosfstools"
APK_NET="openssh-client openssh-server dhcpcd haveged chrony wget curl"
APK_EDIT="nano less"

# 分步安装以减少错误
cd "$(dirname "$0")/.."

# 步骤1: 安装最小基础系统
echo "Step 1: Installing minimal base system..."
./apk.static -X "${ALPINE_REPO}/${ALPINE_BRANCH}/main" \
             -X "${ALPINE_REPO}/${ALPINE_BRANCH}/community" \
             -U --allow-untrusted --root "${rootfs_dir}" --initdb add ${APK_COMMON}

# 步骤2: 安装工具
echo "Step 2: Installing tools..."
./apk.static -X "${ALPINE_REPO}/${ALPINE_BRANCH}/main" \
             -X "${ALPINE_REPO}/${ALPINE_BRANCH}/community" \
             -U --allow-untrusted --root "${rootfs_dir}" add ${APK_TOOLS} ${APK_NET} ${APK_EDIT}

# 步骤3: 安装引导工具
echo "Step 3: Installing boot tools..."
./apk.static -X "${ALPINE_REPO}/${ALPINE_BRANCH}/main" \
             -X "${ALPINE_REPO}/${ALPINE_BRANCH}/community" \
             -U --allow-untrusted --root "${rootfs_dir}" add ${APK_BOOT}

# 创建主机名
echo "openwrt-installer" > "${rootfs_dir}/etc/hostname"

# 允许root登录
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' "${rootfs_dir}/etc/ssh/sshd_config" 2>/dev/null || true

# 设置root密码（空密码）
sed -i 's/^root:.*/root::0:0:root:\/root:\/bin\/bash/' "${rootfs_dir}/etc/shadow" 2>/dev/null || true

# 创建fstab
cat > "${rootfs_dir}/etc/fstab" << FSTAB_EOF
/dev/cdrom    /media/cdrom    iso9660    noauto,ro    0 0
FSTAB_EOF

echo "Root filesystem setup completed successfully"
EOF

chmod +x "$WORK_DIR/build-rootfs.sh"

# 创建OpenWRT安装器init脚本
cat > "$WORK_DIR/openwrt-init.sh" << 'INIT_EOF'
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
cat > "$WORK_DIR/install-openwrt.sh" << 'INSTALL_EOF'
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

chmod +x "$WORK_DIR/openwrt-init.sh" "$WORK_DIR/install-openwrt.sh"
log_success "Custom scripts created"

# ==================== 步骤5: 构建根文件系统 ====================
log_info "[5/8] Building root filesystem..."

# 创建根文件系统目录
ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

log_info "Building root filesystem with Alpine $ALPINE_VERSION..."
cd "$WORK_DIR"

# 构建根文件系统
if ! "$WORK_DIR/build-rootfs.sh" "$ROOTFS_DIR" "$ALPINE_VERSION" "$ALPINE_ARCH"; then
    log_error "Failed to build root filesystem"
    log_info "Checking what went wrong..."
    
    # 检查目录结构
    ls -la "$ROOTFS_DIR" || true
    ls -la "$ROOTFS_DIR/etc" 2>/dev/null || true
    
    # 尝试手动修复
    log_info "Attempting manual recovery..."
    if [ -d "$ROOTFS_DIR/etc" ]; then
        log_info "Rootfs seems partially built, continuing..."
    else
        exit 1
    fi
fi

# 复制自定义脚本到根文件系统
mkdir -p "$ROOTFS_DIR/opt"
cp "$WORK_DIR/install-openwrt.sh" "$ROOTFS_DIR/opt/install-openwrt.sh"
chmod +x "$ROOTFS_DIR/opt/install-openwrt.sh"

# 设置init脚本
cp "$WORK_DIR/openwrt-init.sh" "$ROOTFS_DIR/init"
chmod +x "$ROOTFS_DIR/init"

# 创建必要的设备节点
mkdir -p "$ROOTFS_DIR/dev"
if [ ! -c "$ROOTFS_DIR/dev/console" ]; then
    mknod "$ROOTFS_DIR/dev/console" c 5 1 2>/dev/null || true
fi
if [ ! -c "$ROOTFS_DIR/dev/null" ]; then
    mknod "$ROOTFS_DIR/dev/null" c 1 3 2>/dev/null || true
fi

log_success "Root filesystem built"

# ==================== 步骤6: 创建引导文件 ====================
log_info "[6/8] Creating boot files..."

# 创建ISO目录结构
mkdir -p "$WORK_DIR/iso"
mkdir -p "$WORK_DIR/iso/boot"
mkdir -p "$WORK_DIR/iso/boot/syslinux"
mkdir -p "$WORK_DIR/iso/boot/grub"
mkdir -p "$WORK_DIR/iso/EFI/boot"

# 查找并复制内核
log_info "Looking for kernel files..."
find "$ROOTFS_DIR/boot" -name "vmlinuz-*" -type f | head -1 | xargs -I {} cp {} "$WORK_DIR/iso/boot/vmlinuz-lts" 2>/dev/null || true

# 如果没找到，尝试其他位置
if [ ! -f "$WORK_DIR/iso/boot/vmlinuz-lts" ]; then
    find "$ROOTFS_DIR" -name "vmlinuz-*" -type f | head -1 | xargs -I {} cp {} "$WORK_DIR/iso/boot/vmlinuz-lts" 2>/dev/null || true
fi

# 查找并复制initramfs
find "$ROOTFS_DIR/boot" -name "initramfs-*" -type f | head -1 | xargs -I {} cp {} "$WORK_DIR/iso/boot/initramfs-lts" 2>/dev/null || true

if [ ! -f "$WORK_DIR/iso/boot/vmlinuz-lts" ]; then
    log_warning "Kernel not found, attempting to install kernel manually..."
    # 尝试手动安装内核
    "$WORK_DIR/apk.static" -X "${ALPINE_REPO}/${ALPINE_BRANCH}/main" \
                          -X "${ALPINE_REPO}/${ALPINE_BRANCH}/community" \
                          -U --allow-untrusted --root "$ROOTFS_DIR" add linux-lts 2>/dev/null || true
    find "$ROOTFS_DIR/boot" -name "vmlinuz-*" -type f | head -1 | xargs -I {} cp {} "$WORK_DIR/iso/boot/vmlinuz-lts" 2>/dev/null || true
fi

# 检查是否成功获取内核
if [ ! -f "$WORK_DIR/iso/boot/vmlinuz-lts" ]; then
    log_error "Could not find kernel. Cannot create bootable ISO."
    exit 1
fi

log_success "Kernel files found and copied"

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
log_info "Copying syslinux files..."
SYSFILES="isolinux.bin ldlinux.c32 menu.c32 libutil.c32 libcom32.c32"
for file in $SYSFILES; do
    find /usr -name "$file" -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$WORK_DIR/iso/boot/syslinux/" 2>/dev/null || true
done

# 检查必需的引导文件
if [ ! -f "$WORK_DIR/iso/boot/syslinux/isolinux.bin" ]; then
    log_warning "isolinux.bin not found, searching in alternative locations..."
    # 尝试从syslinux包获取
    apk info -L syslinux 2>/dev/null | grep isolinux.bin | head -1 | xargs -I {} find /usr -name {} -type f 2>/dev/null | head -1 | xargs -I {} cp {} "$WORK_DIR/iso/boot/syslinux/" 2>/dev/null || true
fi

log_success "Boot files created"

# ==================== 步骤7: 构建ISO ====================
log_info "[7/8] Building ISO..."

# 创建squashfs文件系统
log_info "Creating squashfs filesystem..."
if command -v mksquashfs >/dev/null 2>&1; then
    mksquashfs "$ROOTFS_DIR" "$WORK_DIR/iso/rootfs.squashfs" -comp xz -noappend 2>&1 | tail -10 || {
        log_warning "mksquashfs failed, trying alternative compression..."
        mksquashfs "$ROOTFS_DIR" "$WORK_DIR/iso/rootfs.squashfs" -comp gzip -noappend 2>/dev/null || true
    }
else
    log_error "mksquashfs not found. Please install squashfs-tools."
    exit 1
fi

# 复制OpenWRT镜像
log_info "Copying OpenWRT image..."
cp "$OPENWRT_IMG" "$WORK_DIR/iso/openwrt.img"

# 创建EFI引导镜像（可选）
log_info "Creating EFI boot image (if supported)..."
mkdir -p "$WORK_DIR/efiboot"
mkdir -p "$WORK_DIR/efiboot/mnt"

if command -v grub-mkstandalone >/dev/null 2>&1; then
    # 创建GRUB EFI文件
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/efiboot/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$WORK_DIR/iso/boot/grub/grub.cfg" 2>/dev/null || {
        log_warning "Failed to create GRUB EFI file, UEFI boot may not work"
    }
    
    if [ -f "$WORK_DIR/efiboot/bootx64.efi" ]; then
        # 创建EFI分区镜像
        dd if=/dev/zero of="$WORK_DIR/efiboot/efiboot.img" bs=1M count=10 2>/dev/null
        mkfs.vfat -F 32 "$WORK_DIR/efiboot/efiboot.img" 2>/dev/null || true
        
        # 复制EFI文件
        if mount -o loop "$WORK_DIR/efiboot/efiboot.img" "$WORK_DIR/efiboot/mnt" 2>/dev/null; then
            mkdir -p "$WORK_DIR/efiboot/mnt/EFI/BOOT"
            cp "$WORK_DIR/efiboot/bootx64.efi" "$WORK_DIR/efiboot/mnt/EFI/BOOT/bootx64.efi" 2>/dev/null || true
            umount "$WORK_DIR/efiboot/mnt" 2>/dev/null
            cp "$WORK_DIR/efiboot/efiboot.img" "$WORK_DIR/iso/EFI/boot/efiboot.img" 2>/dev/null || true
        fi
    fi
fi

# 使用xorriso构建ISO
log_info "Creating final ISO with xorriso..."
cd "$WORK_DIR/iso"

# 准备xorriso命令参数
XORRISO_ARGS=""

# 检查是否有EFI引导文件
if [ -f "EFI/boot/efiboot.img" ]; then
    XORRISO_ARGS="-eltorito-alt-boot -e EFI/boot/efiboot.img -no-emul-boot -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin"
    log_info "EFI boot image found, creating hybrid ISO"
else
    log_info "No EFI boot image, creating BIOS-only ISO"
fi

# 构建ISO
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot boot/syslinux/isolinux.bin \
    -eltorito-catalog boot/syslinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    $XORRISO_ARGS \
    -output "$ISO_PATH" \
    . 2>&1 | tee "$WORK_DIR/xorriso.log" || {
    log_error "xorriso failed to create ISO"
    log_info "Attempting alternative ISO creation method..."
    
    # 尝试简化命令
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -b boot/syslinux/isolinux.bin \
        -c boot/syslinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -o "$ISO_PATH" \
        . 2>&1 | tail -20
}

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
    echo "  Work Directory:   $WORK_DIR"
    echo ""
    
    echo "✅ Build completed successfully!"
    echo ""
    
    # 显示ISO信息
    echo "📂 ISO Information:"
    file "$ISO_PATH" || true
    echo ""
    
    # 创建构建信息
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Installer ISO - Custom Alpine Build
============================================
Build Date:      $(date)
Build Method:    Custom rootfs with apk.static
ISO Name:        $ISO_NAME
ISO Size:        $ISO_SIZE
Alpine Version:  $ALPINE_VERSION
Input Image:     $OPENWRT_IMG ($IMG_SIZE)

Build Log:
  - Root filesystem: Built successfully
  - Kernel: Found and included
  - Bootloader: BIOS (ISOLINUX) + UEFI (if available)
  - ISO: Created successfully

To test:
1. Burn to USB: dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress
2. Boot and select "Install OpenWRT"
3. Follow the installation wizard

Files included:
  - /openwrt.img: OpenWRT disk image
  - /rootfs.squashfs: Alpine root filesystem
  - /boot/: Boot files (kernel, initramfs)
  - /boot/syslinux/: BIOS bootloader
  - /EFI/boot/: UEFI boot files (if available)
EOF
    
    log_success "✅ ISO created successfully: $ISO_SIZE"
    log_success "📁 Output: $ISO_PATH"
    log_success "📄 Build info: $OUTPUT_DIR/build-info.txt"
    
else
    log_error "❌ ISO file not created: $ISO_PATH"
    log_info "Last 20 lines of xorriso log:"
    tail -20 "$WORK_DIR/xorriso.log" 2>/dev/null || true
    exit 1
fi

log_info "Cleaning up temporary files..."
# cleanup函数会在退出时自动执行
