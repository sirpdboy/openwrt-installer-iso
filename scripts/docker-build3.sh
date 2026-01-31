#!/bin/sh
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
    exit 1
}

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
fi

# 配置变量
ALPINE_VERSION="3.20"
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
    
    # 卸载挂载点
    for mount_point in "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/dev"; do
        umount -f "$mount_point" 2>/dev/null || true
    done
    
    # 清理工作目录
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
LATEST_VERSION=''
KERNEL_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/latest-releases.yaml"
if command -v curl >/dev/null 2>&1; then
    LATEST_ISO=$(curl -s "$KERNEL_URL" | grep -o "alpine-minirootfs-.*-${ARCH}.iso" | head -1)
    if [ -z "$LATEST_ISO" ]; then
        LATEST_ISO="alpine-minirootfs-${ALPINE_VERSION}.9-x86_64.iso"
    fi
    LATEST_VERSION=$(echo "$LATEST_ISO" | sed 's/alpine-minirootfs-//' | sed 's/-x86_64.iso//')
else
    LATEST_VERSION="${ALPINE_VERSION}.9"
    LATEST_ISO="alpine-minirootfs-${LATEST_VERSION}-x86_64.iso"
fi
    if [ -n "$LATEST_VERSION" ]; then
        echo "$LATEST_VERSION"
    else
        echo "${LATEST_VERSION}.1"
    fi
}

# 下载并提取 rootfs
download_rootfs() {
    log_info "Downloading Alpine minirootfs..."
    
    local RELEASE_VERSION=$(get_latest_release)
    log_info "Using Alpine version: ${RELEASE_VERSION}"
    
    local ROOTFS_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/alpine-minirootfs-${RELEASE_VERSION}-${ARCH}.tar.gz"
    local ROOTFS_FILE="${WORK_DIR}/alpine-minirootfs.tar.gz"
    
    log_info "Downloading from: ${ROOTFS_URL}"
    if ! wget -q --show-progress -O "$ROOTFS_FILE" "$ROOTFS_URL"; then
        log_error "Failed to download rootfs"
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
    
    # 设置仓库 - 只使用稳定版本
    cat > "${ROOTFS}/etc/apk/repositories" << EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
EOF
    
    # 创建 fstab
    cat > "${ROOTFS}/etc/fstab" << EOF
/dev/cdrom    /media/cdrom    iso9660    ro    0 0
none          /dev/shm        tmpfs      defaults,nosuid,nodev 0 0
EOF
    
    # 设置时区
    ln -sf /usr/share/zoneinfo/UTC "${ROOTFS}/etc/localtime" 2>/dev/null || true
    
    # 创建 motd
    cat > "${ROOTFS}/etc/motd" << EOF

Alpine Linux Minimal ${ALPINE_VERSION}
Dual Boot (BIOS/UEFI)
Built: $(date +%Y-%m-%d)

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
    
    # 安装绝对必要的包（简化安装）
    log_info "Installing core packages..."
    chroot_exec "apk add --no-cache alpine-base"
    
    # 安装 Linux 内核
    log_info "Installing Linux kernel..."
    chroot_exec "apk add --no-cache linux-lts"
    
    # 安装引导相关包（使用正确的包名）
    log_info "Installing bootloader packages..."
    chroot_exec "apk add --no-cache syslinux grub grub-efi"
    
    # 安装必要的工具
    log_info "Installing build tools..."
    chroot_exec "apk add --no-cache xorriso squashfs-tools mkinitfs"
    
    # 安装文件系统工具
    chroot_exec "apk add --no-cache dosfstools mtools"
    
    # 获取内核版本
    KERNEL_VERSION=$(chroot_exec "ls /lib/modules | head -1 | tr -d '\n'")
    log_info "Detected kernel version: ${KERNEL_VERSION}"
    
    # 创建 initramfs 配置文件
    cat > "${ROOTFS}/etc/mkinitfs/mkinitfs.conf" << EOF
features="base cdrom squashfs"
kernel_opts="console=tty0 console=ttyS0,115200 quiet"
EOF
    
    # 创建 initramfs
    log_info "Creating initramfs..."
    chroot_exec "mkinitfs -c /etc/mkinitfs/mkinitfs.conf ${KERNEL_VERSION}"
    
    cleanup_chroot
}

# 准备引导文件
prepare_boot_files() {
    log_info "Preparing boot files..."
    
    # 获取内核版本
    KERNEL_VERSION=$(ls "${ROOTFS}/lib/modules" 2>/dev/null | head -1)
    if [ -z "$KERNEL_VERSION" ]; then
        log_error "No kernel modules found"
    fi
    
    log_info "Using kernel version: ${KERNEL_VERSION}"
    
    # 复制内核文件
    VMLINUZ_SOURCE="${ROOTFS}/boot/vmlinuz-${KERNEL_VERSION}"
    INITRAMFS_SOURCE="${ROOTFS}/boot/initramfs-${KERNEL_VERSION}"
    
    if [ -f "$VMLINUZ_SOURCE" ]; then
        cp "$VMLINUZ_SOURCE" "${BOOT_DIR}/vmlinuz-lts"
        log_info "Copied kernel: vmlinuz-${KERNEL_VERSION}"
    else
        log_error "Cannot find kernel image"
    fi
    
    if [ -f "$INITRAMFS_SOURCE" ]; then
        cp "$INITRAMFS_SOURCE" "${BOOT_DIR}/initramfs-lts"
        log_info "Copied initramfs: initramfs-${KERNEL_VERSION}"
    else
        log_error "Cannot find initramfs"
    fi
    
    # 复制 modloop（如果存在）
    if [ -f "${ROOTFS}/boot/modloop-${KERNEL_VERSION}" ]; then
        cp "${ROOTFS}/boot/modloop-${KERNEL_VERSION}" "${BOOT_DIR}/modloop-lts"
        log_info "Copied modloop"
    elif [ -f "${ROOTFS}/boot/modloop-lts" ]; then
        cp "${ROOTFS}/boot/modloop-lts" "${BOOT_DIR}/modloop-lts"
        log_info "Copied modloop-lts"
    else
        # 尝试下载 modloop
        log_info "Downloading modloop..."
        MODLOOP_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/modloop-lts"
        if wget -q -O "${BOOT_DIR}/modloop-lts" "$MODLOOP_URL"; then
            log_info "Modloop downloaded"
        else
            log_warn "Modloop not available"
        fi
    fi
}

# 创建 BIOS 引导配置
setup_bios_boot() {
    log_info "Setting up BIOS bootloader..."
    
    SYSLINUX_DIR="${ISO_DIR}/boot/syslinux"
    mkdir -p "$SYSLINUX_DIR"
    
    # 复制 syslinux 文件
    # 首先在 chroot 环境中查找
    if [ -f "${ROOTFS}/usr/share/syslinux/isolinux.bin" ]; then
        cp "${ROOTFS}/usr/share/syslinux/isolinux.bin" "$SYSLINUX_DIR/"
        cp "${ROOTFS}/usr/share/syslinux/ldlinux.c32" "$SYSLINUX_DIR/"
        cp "${ROOTFS}/usr/share/syslinux/libutil.c32" "$SYSLINUX_DIR/"
        cp "${ROOTFS}/usr/share/syslinux/menu.c32" "$SYSLINUX_DIR/"
        cp "${ROOTFS}/usr/share/syslinux/vesamenu.c32" "$SYSLINUX_DIR/"
    else
        # 在主机系统中查找
        for file in isolinux.bin ldlinux.c32 libutil.c32 menu.c32 vesamenu.c32; do
            if [ -f "/usr/lib/syslinux/${file}" ]; then
                cp "/usr/lib/syslinux/${file}" "$SYSLINUX_DIR/"
            elif [ -f "/usr/share/syslinux/${file}" ]; then
                cp "/usr/share/syslinux/${file}" "$SYSLINUX_DIR/"
            fi
        done
    fi
    
    # 验证 isolinux.bin 是否存在
    if [ ! -f "${SYSLINUX_DIR}/isolinux.bin" ]; then
        log_error "isolinux.bin not found"
    fi
    
    # 创建 isolinux.cfg
    cat > "${SYSLINUX_DIR}/isolinux.cfg" << EOF
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

LABEL linux
  MENU LABEL Boot Alpine Linux
  MENU DEFAULT
  KERNEL /boot/vmlinuz-lts
  INITRD /boot/initramfs-lts
  APPEND root=/dev/ram0 alpine_dev=cdrom:vfat modules=loop,squashfs quiet

LABEL local
  MENU LABEL Boot from local drive
  LOCALBOOT 0
EOF
    
    # 创建简单的 splash 图像
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==" | base64 -d > "${SYSLINUX_DIR}/splash.png" 2>/dev/null || \
    echo "Splash" > "${SYSLINUX_DIR}/splash.png"
}

# 创建 EFI 引导配置
setup_efi_boot() {
    log_info "Setting up UEFI bootloader..."
    
    EFI_DIR="${ISO_DIR}/EFI/BOOT"
    GRUB_DIR="${ISO_DIR}/boot/grub"
    mkdir -p "$EFI_DIR" "$GRUB_DIR"
    
    # 创建 grub.cfg
    cat > "${GRUB_DIR}/grub.cfg" << EOF
set timeout=5
set default=0

menuentry "Boot Alpine Linux" {
    linux /boot/vmlinuz-lts root=/dev/ram0 alpine_dev=cdrom:vfat modules=loop,squashfs quiet
    initrd /boot/initramfs-lts
}

menuentry "Boot from local drive" {
    exit
}
EOF
    
    # 查找 GRUB EFI 文件
    GRUB_EFI_FOUND=false
    
    # 检查 chroot 环境中的文件
    if [ -f "${ROOTFS}/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" ]; then
        cp "${ROOTFS}/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" "${EFI_DIR}/BOOTX64.EFI"
        GRUB_EFI_FOUND=true
        log_info "Using GRUB EFI from Alpine rootfs"
    fi
    
    # 检查主机系统中的文件
    if [ "$GRUB_EFI_FOUND" = "false" ] && [ -f "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" ]; then
        cp "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" "${EFI_DIR}/BOOTX64.EFI"
        GRUB_EFI_FOUND=true
        log_info "Using GRUB EFI from host system"
    fi
    
    # 如果都没有找到，尝试生成
    if [ "$GRUB_EFI_FOUND" = "false" ] && command -v grub-mkstandalone >/dev/null 2>&1; then
        log_info "Generating GRUB EFI with grub-mkstandalone..."
        grub-mkstandalone \
            --format=x86_64-efi \
            --output="${EFI_DIR}/BOOTX64.EFI" \
            --locales="" \
            --fonts="" \
            --modules="part_gpt part_msdos fat iso9660" \
            "boot/grub/grub.cfg=${GRUB_DIR}/grub.cfg"
        GRUB_EFI_FOUND=true
    fi
    
    if [ "$GRUB_EFI_FOUND" = "false" ]; then
        log_warn "GRUB EFI file not found, UEFI boot may not work"
    fi
    
    # 创建 EFI 引导镜像
    log_info "Creating EFI boot image..."
    dd if=/dev/zero of="${ISO_DIR}/boot/grub/efiboot.img" bs=1M count=10 status=none
    mkfs.vfat -n "ALPINEFI" "${ISO_DIR}/boot/grub/efiboot.img" >/dev/null 2>&1
    
    # 挂载并复制 EFI 文件
    EFI_MOUNT=$(mktemp -d)
    if mount -o loop "${ISO_DIR}/boot/grub/efiboot.img" "$EFI_MOUNT" 2>/dev/null; then
        mkdir -p "${EFI_MOUNT}/EFI/BOOT"
        
        if [ -f "${EFI_DIR}/BOOTX64.EFI" ]; then
            cp "${EFI_DIR}/BOOTX64.EFI" "${EFI_MOUNT}/EFI/BOOT/"
        fi
        
        cp "${GRUB_DIR}/grub.cfg" "${EFI_MOUNT}/EFI/BOOT/" 2>/dev/null || true
        
        umount "$EFI_MOUNT"
        rmdir "$EFI_MOUNT"
    else
        log_warn "Failed to mount EFI image"
    fi
}

# 创建 squashfs 根文件系统
create_squashfs() {
    log_info "Creating squashfs root filesystem..."
    
    # 清理不必要的文件
    log_info "Cleaning rootfs..."
    rm -rf "${ROOTFS}/var/cache/apk/*" 2>/dev/null || true
    rm -rf "${ROOTFS}/usr/share/man/*" 2>/dev/null || true
    rm -rf "${ROOTFS}/usr/share/doc/*" 2>/dev/null || true
    
    # 创建 squashfs
    mksquashfs "${ROOTFS}" "${ISO_DIR}/alpine-rootfs.squashfs" \
        -comp gzip \
        -b 1M \
        -no-progress \
        -noappend \
        -all-root
    
    SQUASHFS_SIZE=$(du -h "${ISO_DIR}/alpine-rootfs.squashfs" | cut -f1)
    log_info "Squashfs created: ${SQUASHFS_SIZE}"
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
    
    log_info "Boot files copied"
}

# 验证构建
verify_build() {
    log_info "Verifying build..."
    
    # 检查关键文件
    if [ ! -f "${ISO_DIR}/boot/vmlinuz-lts" ]; then
        log_error "Missing kernel file"
    fi
    
    if [ ! -f "${ISO_DIR}/boot/initramfs-lts" ]; then
        log_error "Missing initramfs file"
    fi
    
    if [ ! -f "${ISO_DIR}/alpine-rootfs.squashfs" ]; then
        log_error "Missing squashfs rootfs"
    fi
    
    if [ ! -f "${ISO_DIR}/boot/syslinux/isolinux.bin" ]; then
        log_warn "Missing isolinux.bin"
    fi
    
    log_info "✓ Build verification passed"
}

# 创建混合 ISO
create_hybrid_iso() {
    log_info "Creating hybrid ISO image..."
    
    cd "$WORK_DIR"
    
    # 查找 isohdpfx.bin
    ISOHDPFX=""
    for path in \
        "/usr/lib/syslinux/isohdpfx.bin" \
        "/usr/share/syslinux/isohdpfx.bin" \
        "${ROOTFS}/usr/share/syslinux/isohdpfx.bin"; do
        if [ -f "$path" ]; then
            ISOHDPFX="$path"
            break
        fi
    done
    
    if [ -z "$ISOHDPFX" ]; then
        log_warn "isohdpfx.bin not found, using fallback"
        dd if=/dev/zero of=/tmp/isohdpfx.bin bs=512 count=1 status=none
        ISOHDPFX="/tmp/isohdpfx.bin"
    fi
    
    log_info "Creating ISO with xorriso..."
    
    # 创建 ISO
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "ALPINEMIN" \
        -appid "Alpine Linux Minimal ${ALPINE_VERSION}" \
        -publisher "GitHub Actions" \
        -preparer "built on $(date)" \
        -eltorito-boot boot/syslinux/isolinux.bin \
        -eltorito-catalog boot/syslinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr "$ISOHDPFX" \
        -eltorito-alt-boot \
        -e boot/grub/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        "$ISO_DIR"
    
    # 验证 ISO
    if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
        ISO_SIZE=$(du -h "${OUTPUT_DIR}/${ISO_NAME}" | cut -f1)
        log_info "✓ ISO created: ${ISO_SIZE}"
    else
        log_error "Failed to create ISO"
    fi
}

# 主构建流程
main() {
    echo ""
    echo "========================================"
    echo "  Alpine Linux Minimal ISO Builder"
    echo "  Version: ${ALPINE_VERSION}"
    echo "  Architecture: ${ARCH}"
    echo "========================================"
    
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
    echo "========================================"
    echo "✓ BUILD COMPLETED SUCCESSFULLY"
    echo "  Output: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "========================================"
    
    # 显示结果
    ls -lh "${OUTPUT_DIR}/"*.iso 2>/dev/null || true
}

# 运行主函数
main "$@"
