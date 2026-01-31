#!/bin/sh
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }

# 检查 root 权限
[ "$(id -u)" -ne 0 ] && log_error "This script must be run as root"

# 配置变量
ALPINE_VERSION="3.19"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ARCH="x86_64"
OUTPUT_DIR="$(pwd)/output"
ISO_NAME="alpine-minimal-${ALPINE_VERSION}-${ARCH}-dual.iso"
WORK_DIR="${OUTPUT_DIR}/work"
ROOTFS="${WORK_DIR}/rootfs"
BOOT_DIR="${WORK_DIR}/boot"
ISO_DIR="${WORK_DIR}/iso"

# 清理函数
cleanup() {
    log_info "Cleaning up..."
    for mount_point in "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/dev"; do
        umount -f "$mount_point" 2>/dev/null || true
    done
    rm -rf "${OUTPUT_DIR}" 2>/dev/null || true
}

# 错误处理
trap cleanup EXIT INT TERM

# 准备目录结构
prepare_dirs() {
    log_info "Preparing directory structure..."
    mkdir -p "${OUTPUT_DIR}" "${WORK_DIR}" "${ROOTFS}" "${BOOT_DIR}" "${ISO_DIR}"
}

# 获取最新的 Alpine 版本
get_latest_release() {
    local version_file="${WORK_DIR}/latest-version.txt"
    wget -q -O "$version_file" "${ALPINE_MIRROR}/latest-stable/releases/${ARCH}/"
    
    # 提取最新的 minirootfs
    local latest_rootfs=$(grep -o "alpine-minirootfs-[0-9.]*-${ARCH}.tar.gz" "$version_file" | head -1 | sed 's/alpine-minirootfs-\(.*\)-'"${ARCH}"'.tar.gz/\1/')
    
    if [ -n "$latest_rootfs" ]; then
        echo "$latest_rootfs"
    else
        echo "${ALPINE_VERSION}.1"
    fi
}

# 下载并提取 rootfs
download_rootfs() {
    log_info "Downloading Alpine minirootfs..."
    
    local RELEASE_VERSION=$(get_latest_release)
    log_info "Using Alpine version: ${RELEASE_VERSION}"
    
    local ROOTFS_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/alpine-minirootfs-${RELEASE_VERSION}-${ARCH}.tar.gz"
    local ROOTFS_FILE="${WORK_DIR}/alpine-minirootfs.tar.gz"
    
    if ! wget -q --show-progress -O "$ROOTFS_FILE" "$ROOTFS_URL"; then
        log_error "Failed to download rootfs from: ${ROOTFS_URL}"
    fi
    
    log_info "Extracting rootfs..."
    tar -xzf "$ROOTFS_FILE" -C "$ROOTFS" --no-same-owner
    rm -f "$ROOTFS_FILE"
}

# 配置基础系统
configure_base_system() {
    log_info "Configuring base system..."
    
    # 设置基本的配置
    cat > "${ROOTFS}/etc/hosts" << EOF
127.0.0.1    localhost localhost.localdomain
::1          localhost localhost.localdomain
EOF
    
    cat > "${ROOTFS}/etc/resolv.conf" << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
    
    # 设置仓库
    cat > "${ROOTFS}/etc/apk/repositories" << EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
#${ALPINE_MIRROR}/edge/main
#${ALPINE_MIRROR}/edge/community
EOF
    
    # 创建 fstab
    cat > "${ROOTFS}/etc/fstab" << EOF
/dev/cdrom    /media/cdrom    iso9660    ro    0 0
none          /dev/shm        tmpfs      defaults,nosuid,nodev 0 0
EOF
    
    # 设置时区
    ln -sf /usr/share/zoneinfo/UTC "${ROOTFS}/etc/localtime" 2>/dev/null || true
    
    # 创建 motd
    cat > "${ROOTFS}/etc/motd" << 'EOF'

    █████╗ ██╗     ██████╗ ██╗███╗   ██╗███████╗
   ██╔══██╗██║     ██╔══██╗██║████╗  ██║██╔════╝
   ███████║██║     ██████╔╝██║██╔██╗ ██║█████╗  
   ██╔══██║██║     ██╔═══╝ ██║██║╚██╗██║██╔══╝  
   ██║  ██║███████╗██║     ██║██║ ╚████║███████╗
   ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝╚═╝  ╚═══╝╚══════╝

   Alpine Linux Minimal ${ALPINE_VERSION}
   Dual Boot (BIOS/UEFI) - Built $(date +%Y-%m-%d)
   
EOF
}

# chroot 环境管理
setup_chroot() {
    log_info "Setting up chroot environment..."
    
    # 挂载必要的文件系统
    mount -t proc proc "${ROOTFS}/proc"
    mount -t sysfs sys "${ROOTFS}/sys"
    mount -o bind /dev "${ROOTFS}/dev"
    mount -o bind /dev/pts "${ROOTFS}/dev/pts"
    
    # 复制 DNS 配置
    cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf"
}

cleanup_chroot() {
    log_info "Cleaning chroot environment..."
    
    # 卸载文件系统
    umount -f "${ROOTFS}/dev/pts" 2>/dev/null || true
    umount -f "${ROOTFS}/dev" 2>/dev/null || true
    umount -f "${ROOTFS}/sys" 2>/dev/null || true
    umount -f "${ROOTFS}/proc" 2>/dev/null || true
}

# chroot 执行命令
chroot_exec() {
    chroot "$ROOTFS" /bin/sh -c "$1"
}

# 安装必要的软件包
install_packages() {
    log_info "Installing required packages..."
    
    setup_chroot
    
    # 更新并安装基础包（最小化安装）
    chroot_exec "apk update"
    
    # 安装核心系统包
    chroot_exec "apk add --no-cache \
        alpine-base \
        linux-lts \
        alpine-conf \
        setup-disk \
        openrc \
        busybox-initscripts"
    
    # 安装引导相关包
    chroot_exec "apk add --no-cache \
        syslinux \
        grub grub-efi \
        efibootmgr \
        mtools \
        dosfstools"
    
    # 安装构建工具
    chroot_exec "apk add --no-cache \
        xorriso \
        squashfs-tools \
        mkinitfs"
    
    # 创建内核模块
    log_info "Setting up kernel modules..."
    local KERNEL_VERSION=$(chroot_exec "ls /lib/modules | head -1 | tr -d '\n'")
    
    # 配置 mkinitfs
    cat > "${ROOTFS}/etc/mkinitfs/mkinitfs.conf" << EOF
features="ata base cdrom ext4 mmc nvme scsi usb virtio"
kernel_opts="console=tty0 console=ttyS0,115200 quiet"
modules=""
builtin_modules=""
EOF
    
    # 创建 initramfs
    log_info "Creating initramfs for kernel: ${KERNEL_VERSION}"
    chroot_exec "mkinitfs -q ${KERNEL_VERSION}"
    
    # 验证 initramfs 创建
    if ! chroot_exec "ls -la /boot/ | grep initramfs"; then
        log_warn "Initramfs not found in /boot/, creating manually..."
        chroot_exec "mkinitfs -q -b / ${KERNEL_VERSION}"
    fi
    
    # 禁用不需要的服务
    chroot_exec "rc-update del devfs sysinit 2>/dev/null || true"
    chroot_exec "rc-update del dmesg sysinit 2>/dev/null || true"
    chroot_exec "rc-update del mdev sysinit 2>/dev/null || true"
    
    cleanup_chroot
}

# 准备引导文件
prepare_boot_files() {
    log_info "Preparing boot files..."
    
    # 获取内核版本
    local KERNEL_VERSION=$(ls "${ROOTFS}/lib/modules" | head -1)
    
    # 复制内核文件
    cp "${ROOTFS}/boot/vmlinuz-${KERNEL_VERSION}" "${BOOT_DIR}/vmlinuz-lts"
    cp "${ROOTFS}/boot/initramfs-${KERNEL_VERSION}" "${BOOT_DIR}/initramfs-lts"
    
    # 复制 modloop（如果存在）
    if [ -f "${ROOTFS}/boot/modloop-${KERNEL_VERSION}" ]; then
        cp "${ROOTFS}/boot/modloop-${KERNEL_VERSION}" "${BOOT_DIR}/modloop-lts"
    else
        # 尝试下载 modloop
        log_info "Downloading modloop..."
        local MODLOOP_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/modloop-lts"
        if wget -q -O "${BOOT_DIR}/modloop-lts" "$MODLOOP_URL"; then
            log_info "Modloop downloaded successfully"
        else
            log_warn "Modloop not available, continuing without it"
        fi
    fi
    
    # 验证文件存在
    for file in vmlinuz-lts initramfs-lts; do
        if [ ! -f "${BOOT_DIR}/${file}" ]; then
            log_error "Missing boot file: ${file}"
        fi
    done
}

# 创建 BIOS 引导配置
setup_bios_boot() {
    log_info "Setting up BIOS bootloader..."
    
    local SYSLINUX_DIR="${ISO_DIR}/boot/syslinux"
    mkdir -p "$SYSLINUX_DIR"
    
    # 复制 syslinux 文件
    cp "${ROOTFS}/usr/share/syslinux/isolinux.bin" "$SYSLINUX_DIR/"
    cp "${ROOTFS}/usr/share/syslinux/ldlinux.c32" "$SYSLINUX_DIR/"
    cp "${ROOTFS}/usr/share/syslinux/libutil.c32" "$SYSLINUX_DIR/"
    cp "${ROOTFS}/usr/share/syslinux/menu.c32" "$SYSLINUX_DIR/"
    cp "${ROOTFS}/usr/share/syslinux/vesamenu.c32" "$SYSLINUX_DIR/"
    
    # 创建 isolinux.cfg
    cat > "${SYSLINUX_DIR}/isolinux.cfg" << 'EOF'
DEFAULT vesamenu.c32
PROMPT 0
TIMEOUT 300
ONTIMEOUT linux

MENU TITLE Alpine Linux Minimal
MENU BACKGROUND /boot/syslinux/splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std

MENU WIDTH 78
MENU MARGIN 4
MENU ROWS 10
MENU VSHIFT 3
MENU TABMSGROW 14
MENU CMDLINEROW 14
MENU HELPMSGROW 16
MENU HELPMSGENDROW 29

LABEL linux
  MENU LABEL ^Boot Alpine Linux
  MENU DEFAULT
  KERNEL /boot/vmlinuz-lts
  INITRD /boot/initramfs-lts
  APPEND root=/dev/ram0 alpine_dev=cdrom:vfat modules=loop,squashfs,sd-mod,usb-storage quiet console=tty0 console=ttyS0,115200

LABEL local
  MENU LABEL ^Boot from local drive
  LOCALBOOT 0
EOF
    
    # 创建简单的 splash 图像（文本格式）
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==" | base64 -d > "${SYSLINUX_DIR}/splash.png" 2>/dev/null || \
    echo "Splash" > "${SYSLINUX_DIR}/splash.png"
}

# 创建 EFI 引导配置
setup_efi_boot() {
    log_info "Setting up UEFI bootloader..."
    
    local EFI_DIR="${ISO_DIR}/EFI/BOOT"
    local GRUB_DIR="${ISO_DIR}/boot/grub"
    mkdir -p "$EFI_DIR" "$GRUB_DIR"
    
    # 创建 grub.cfg
    cat > "${GRUB_DIR}/grub.cfg" << 'EOF'
set timeout=5
set default=0

if loadfont /boot/grub/font.pf2 ; then
    set gfxmode=auto
    insmod efi_gop
    insmod efi_uga
    insmod gfxterm
    terminal_output gfxterm
fi

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Boot Alpine Linux" {
    linux /boot/vmlinuz-lts root=/dev/ram0 alpine_dev=cdrom:vfat modules=loop,squashfs,sd-mod,usb-storage quiet console=tty0 console=ttyS0,115200
    initrd /boot/initramfs-lts
}

menuentry "Boot from local drive" {
    exit
}
EOF
    
    # 复制 GRUB EFI 文件
    if [ -f "${ROOTFS}/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" ]; then
        cp "${ROOTFS}/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" "${EFI_DIR}/BOOTX64.EFI"
    elif [ -f "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" ]; then
        cp "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" "${EFI_DIR}/BOOTX64.EFI"
    else
        # 使用 grub-mkstandalone 创建 EFI 镜像
        log_info "Creating GRUB EFI image..."
        grub-mkstandalone \
            --format=x86_64-efi \
            --output="${EFI_DIR}/BOOTX64.EFI" \
            --locales="" \
            --fonts="" \
            --modules="part_gpt part_msdos fat iso9660" \
            "boot/grub/grub.cfg=${GRUB_DIR}/grub.cfg"
    fi
    
    # 创建 EFI 引导镜像
    log_info "Creating EFI boot image..."
    dd if=/dev/zero of="${ISO_DIR}/boot/grub/efiboot.img" bs=1M count=10 2>/dev/null
    mkfs.vfat -n "ALPINEFI" "${ISO_DIR}/boot/grub/efiboot.img" 2>/dev/null
    
    # 挂载并复制 EFI 文件
    local EFI_MOUNT=$(mktemp -d)
    mount -o loop "${ISO_DIR}/boot/grub/efiboot.img" "$EFI_MOUNT"
    mkdir -p "${EFI_MOUNT}/EFI/BOOT"
    cp "${EFI_DIR}/BOOTX64.EFI" "${EFI_MOUNT}/EFI/BOOT/"
    umount "$EFI_MOUNT"
    rmdir "$EFI_MOUNT"
}

# 创建 squashfs 根文件系统
create_squashfs() {
    log_info "Creating squashfs root filesystem..."
    
    # 清理不必要的文件
    log_info "Cleaning rootfs..."
    rm -rf "${ROOTFS}/var/cache/apk/*" 2>/dev/null || true
    rm -rf "${ROOTFS}/usr/share/man/*" 2>/dev/null || true
    rm -rf "${ROOTFS}/usr/share/doc/*" 2>/dev/null || true
    rm -rf "${ROOTFS}/boot/*" 2>/dev/null || true
    find "${ROOTFS}/var/log" -type f -delete 2>/dev/null || true
    
    # 创建 squashfs（使用 xz 压缩以获得更好的压缩比）
    mksquashfs "${ROOTFS}" "${ISO_DIR}/alpine-rootfs.squashfs" \
        -comp xz \
        -b 1M \
        -no-progress \
        -noappend \
        -all-root \
        -no-exports \
        -no-recovery
    
    local squashfs_size=$(du -h "${ISO_DIR}/alpine-rootfs.squashfs" | cut -f1)
    log_info "Squashfs created: ${squashfs_size}"
}

# 复制引导文件到 ISO 目录
copy_boot_files() {
    log_info "Copying boot files to ISO directory..."
    
    # 创建 boot 目录
    mkdir -p "${ISO_DIR}/boot"
    
    # 复制内核文件
    cp "${BOOT_DIR}/vmlinuz-lts" "${ISO_DIR}/boot/"
    cp "${BOOT_DIR}/initramfs-lts" "${ISO_DIR}/boot/"
    
    # 复制 modloop（如果存在）
    if [ -f "${BOOT_DIR}/modloop-lts" ]; then
        cp "${BOOT_DIR}/modloop-lts" "${ISO_DIR}/boot/"
    fi
    
    # 创建版本信息文件
    cat > "${ISO_DIR}/alpine-version" << EOF
Alpine Linux Minimal ${ALPINE_VERSION}
Architecture: ${ARCH}
Build date: $(date)
Kernel: $(basename "${BOOT_DIR}/vmlinuz-lts")
Initramfs: $(basename "${BOOT_DIR}/initramfs-lts")
EOF
}

# 创建混合 ISO
create_hybrid_iso() {
    log_info "Creating hybrid ISO image..."
    
    cd "$WORK_DIR"
    
    # 查找 isohdpfx.bin
    local ISOHDPFX=""
    for path in \
        "/usr/lib/ISOLINUX/isohdpfx.bin" \
        "/usr/lib/syslinux/isohdpfx.bin" \
        "/usr/share/syslinux/isohdpfx.bin" \
        "${ROOTFS}/usr/share/syslinux/isohdpfx.bin"; do
        if [ -f "$path" ]; then
            ISOHDPFX="$path"
            break
        fi
    done
    
    if [ -z "$ISOHDPFX" ]; then
        log_warn "isohdpfx.bin not found, creating simple one..."
        dd if=/dev/zero of=/tmp/isohdpfx.bin bs=512 count=1 2>/dev/null
        printf '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' | \
            dd of=/tmp/isohdpfx.bin conv=notrunc bs=1 count=16 2>/dev/null
        ISOHDPFX="/tmp/isohdpfx.bin"
    fi
    
    log_info "Creating ISO with xorriso..."
    
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "ALPINEMIN" \
        -appid "Alpine Linux Minimal ${ALPINE_VERSION}" \
        -publisher "Alpine Linux Development Team" \
        -preparer "built with GitHub Actions" \
        \
        -eltorito-boot boot/syslinux/isolinux.bin \
        -eltorito-catalog boot/syslinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr "$ISOHDPFX" \
        \
        -eltorito-alt-boot \
        -e boot/grub/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        \
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        "$ISO_DIR" 2>&1 | grep -v "UPDATE-ISOHYDRATE" | grep -v "libisofs" || true
    
    # 验证 ISO 创建
    if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
        local iso_size=$(du -h "${OUTPUT_DIR}/${ISO_NAME}" | cut -f1)
        log_info "✓ ISO created successfully: ${iso_size}"
        
        # 显示 ISO 信息
        echo ""
        echo "=== ISO Information ==="
        isoinfo -d -i "${OUTPUT_DIR}/${ISO_NAME}" 2>/dev/null | \
            grep -E "Volume id|Volume size|Directory" || true
        
        return 0
    else
        log_error "Failed to create ISO"
    fi
}

# 验证构建
verify_build() {
    log_info "Verifying build..."
    
    # 检查关键文件
    local required_files=(
        "${ISO_DIR}/boot/vmlinuz-lts"
        "${ISO_DIR}/boot/initramfs-lts"
        "${ISO_DIR}/alpine-rootfs.squashfs"
        "${ISO_DIR}/boot/syslinux/isolinux.bin"
        "${ISO_DIR}/boot/grub/efiboot.img"
    )
    
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "Missing required file: $(basename "$file")"
        fi
    done
    
    log_info "✓ All required files present"
}

# 主构建流程
main() {
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║   Alpine Linux Minimal ISO Builder       ║"
    echo "║   Version: ${ALPINE_VERSION}                    ║"
    echo "║   Arch: ${ARCH}                          ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    
    # 执行构建步骤
    prepare_dirs
    download_rootfs
    configure_base_system
    install_packages
    prepare_boot_files
    setup_bios_boot
    setup_efi_boot
    create_squashfs
    copy_boot_files
    verify_build
    create_hybrid_iso
    
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║         BUILD SUCCESSFUL!                ║"
    echo "╠══════════════════════════════════════════╣"
    echo "║ ISO: ${ISO_NAME} ║"
    echo "║ Size: $(du -h "${OUTPUT_DIR}/${ISO_NAME}" | cut -f1)                        ║"
    echo "║ Support: BIOS & UEFI                     ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    
    # 显示最终文件信息
    ls -lh "${OUTPUT_DIR}/"*.iso 2>/dev/null || true
}

# 运行主函数
main "$@"
