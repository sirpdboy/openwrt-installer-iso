#!/bin/sh
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root"
fi

# 配置变量
ALPINE_VERSION="3.19"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ARCH="x86_64"
OUTPUT_DIR="$(pwd)/output"
ISO_DIR="${OUTPUT_DIR}/iso"
ISO_NAME="alpine-minimal-${ALPINE_VERSION}-dual-boot.iso"
WORK_DIR="${OUTPUT_DIR}/work"
EFI_DIR="${WORK_DIR}/efi"
BIOS_DIR="${WORK_DIR}/bios"
ROOTFS="${WORK_DIR}/rootfs"

# 清理并创建目录
cleanup() {
    info "Cleaning up previous build..."
    rm -rf "${OUTPUT_DIR}" 2>/dev/null || true
}

prepare_dirs() {
    info "Preparing directories..."
    mkdir -p "${OUTPUT_DIR}" "${ISO_DIR}" "${WORK_DIR}" "${EFI_DIR}" "${BIOS_DIR}" "${ROOTFS}"
}

# 下载 Alpine 最小 rootfs
download_rootfs() {
    info "Downloading Alpine Linux minimal rootfs..."
    
    # 获取最新的小版本号
    local releases_list="${WORK_DIR}/releases.txt"
    wget -q -O "${releases_list}" "${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/"
    
    # 查找最新的 rootfs
    local rootfs_name=$(grep -o "alpine-minirootfs-[0-9.]*-${ARCH}.tar.gz" "${releases_list}" | head -1)
    
    if [ -z "$rootfs_name" ]; then
        # 如果无法解析，使用硬编码的版本
        rootfs_name="alpine-minirootfs-${ALPINE_VERSION}.1-${ARCH}.tar.gz"
    fi
    
    local rootfs_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/${rootfs_name}"
    local rootfs_file="${WORK_DIR}/alpine-minirootfs.tar.gz"
    
    info "Downloading from: ${rootfs_url}"
    wget -q --show-progress -O "${rootfs_file}" "${rootfs_url}" || \
    error "Failed to download Alpine rootfs"
    
    info "Extracting rootfs..."
    tar -xzf "${rootfs_file}" -C "${ROOTFS}" --no-same-owner
    rm -f "${rootfs_file}"
}

# 配置基础系统
configure_base_system() {
    info "Configuring base system..."
    
    # 设置 hosts
    cat > "${ROOTFS}/etc/hosts" << EOF
127.0.0.1   localhost localhost.localdomain
::1         localhost localhost.localdomain
EOF

    # 设置 resolv.conf
    cat > "${ROOTFS}/etc/resolv.conf" << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

    # 创建 fstab
    cat > "${ROOTFS}/etc/fstab" << EOF
# <file system> <mount point> <type> <options> <dump> <pass>
/dev/cdrom /media/cdrom iso9660 ro 0 0
EOF

    # 设置时区
    ln -sf /usr/share/zoneinfo/UTC "${ROOTFS}/etc/localtime" 2>/dev/null || true
    
    # 创建默认网络配置
    mkdir -p "${ROOTFS}/etc/network"
    cat > "${ROOTFS}/etc/network/interfaces" << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

    # 创建 motd
    cat > "${ROOTFS}/etc/motd" << EOF
=============================================
Minimal Alpine Linux System
Built on $(date)
Dual Boot (BIOS/UEFI)
=============================================
EOF
    
    # 创建必要的设备节点
    mknod -m 666 "${ROOTFS}/dev/null" c 1 3 2>/dev/null || true
    mknod -m 666 "${ROOTFS}/dev/zero" c 1 5 2>/dev/null || true
    mknod -m 666 "${ROOTFS}/dev/random" c 1 8 2>/dev/null || true
    mknod -m 666 "${ROOTFS}/dev/urandom" c 1 9 2>/dev/null || true
}

# 准备 chroot 环境
prepare_chroot() {
    info "Preparing chroot environment..."
    
    # 挂载必要的文件系统
    mount --bind /proc "${ROOTFS}/proc" 2>/dev/null || true
    mount --bind /sys "${ROOTFS}/sys" 2>/dev/null || true
    mount --bind /dev "${ROOTFS}/dev" 2>/dev/null || true
    
    # 复制 DNS 配置
    cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf" 2>/dev/null || true
}

# 清理 chroot 环境
cleanup_chroot() {
    info "Cleaning up chroot environment..."
    umount -f "${ROOTFS}/proc" 2>/dev/null || true
    umount -f "${ROOTFS}/sys" 2>/dev/null || true
    umount -f "${ROOTFS}/dev" 2>/dev/null || true
}

# 在 chroot 中执行命令
chroot_exec() {
    chroot "${ROOTFS}" /bin/sh -c "$1"
}

# 安装必要的包
install_packages() {
    info "Installing essential packages..."
    
    # 设置仓库（使用社区仓库获取更多包）
    cat > "${ROOTFS}/etc/apk/repositories" << EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
${ALPINE_MIRROR}/edge/main
${ALPINE_MIRROR}/edge/community
EOF
    
    prepare_chroot
    
    # 更新并安装基础包
    info "Installing base packages..."
    chroot_exec "apk update"
    
    # 安装最小必要包集
    chroot_exec "apk add --no-cache \
        alpine-base \
        linux-lts \
        syslinux \
        grub grub-efi grub-bios \
        efibootmgr \
        dosfstools \
        mtools \
        squashfs-tools"
    
    # 安装 xorriso 用于构建 ISO
    chroot_exec "apk add --no-cache xorriso"
    
    # 创建 initramfs 配置
    cat > "${ROOTFS}/etc/mkinitfs/mkinitfs.conf" << EOF
features="base cdrom ext4 squashfs usb virtio"
kernel_opts=""
modules=""
builtin_modules=""
files=""
EOF
    
    # 获取内核版本
    KERNEL_VERSION=$(chroot_exec "ls /lib/modules | head -1" | tr -d '\r')
    info "Detected kernel version: ${KERNEL_VERSION}"
    
    # 创建 initramfs
    info "Creating initramfs..."
    chroot_exec "mkinitfs -c /etc/mkinitfs/mkinitfs.conf -b / ${KERNEL_VERSION}"
    
    cleanup_chroot
}

# 配置引导加载器
configure_bootloader() {
    info "Configuring bootloaders..."
    
    # 创建 BIOS 引导目录结构
    mkdir -p "${BIOS_DIR}/boot/syslinux"
    
    # 复制 syslinux 文件
    if [ -f "${ROOTFS}/usr/share/syslinux/isolinux.bin" ]; then
        cp "${ROOTFS}/usr/share/syslinux/isolinux.bin" "${BIOS_DIR}/boot/syslinux/"
    else
        # 尝试其他位置
        find "${ROOTFS}" -name "isolinux.bin" -exec cp {} "${BIOS_DIR}/boot/syslinux/" \; 2>/dev/null || true
    fi
    
    # 复制其他必要的 syslinux 文件
    for file in ldlinux.c32 libutil.c32 menu.c32 vesamenu.c32; do
        if [ -f "${ROOTFS}/usr/share/syslinux/${file}" ]; then
            cp "${ROOTFS}/usr/share/syslinux/${file}" "${BIOS_DIR}/boot/syslinux/"
        fi
    done
    
    # 创建 isolinux.cfg (BIOS 引导菜单) - 简化版本
    cat > "${BIOS_DIR}/boot/syslinux/isolinux.cfg" << 'EOF'
DEFAULT linux
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE Alpine Linux Boot Menu

LABEL linux
    MENU LABEL Boot Alpine Linux
    KERNEL /boot/vmlinuz-lts
    INITRD /boot/initramfs-lts
    APPEND root=/dev/ram0 alpine_dev=cdrom:vfat modules=loop,squashfs quiet
    TEXT HELP
    Start Alpine Linux Minimal System
    ENDTEXT

LABEL local
    MENU LABEL Boot from local drive
    LOCALBOOT 0
EOF

    # 创建 grub.cfg (EFI 引导菜单) - 简化版本
    mkdir -p "${EFI_DIR}/EFI/BOOT"
    cat > "${EFI_DIR}/EFI/BOOT/grub.cfg" << 'EOF'
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

    # 创建 EFI 引导镜像
    info "Creating EFI boot image..."
    dd if=/dev/zero of="${EFI_DIR}/efiboot.img" bs=1M count=10 2>/dev/null
    mkfs.vfat -F 12 "${EFI_DIR}/efiboot.img" 2>/dev/null
    
    # 挂载并复制 GRUB EFI 文件
    MOUNT_POINT=$(mktemp -d)
    mount -t vfat -o loop "${EFI_DIR}/efiboot.img" "${MOUNT_POINT}"
    
    # 复制 GRUB EFI 文件
    if [ -f "${ROOTFS}/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" ]; then
        mkdir -p "${MOUNT_POINT}/EFI/BOOT"
        cp "${ROOTFS}/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" \
           "${MOUNT_POINT}/EFI/BOOT/BOOTX64.EFI"
        info "✓ Found and copied grubx64.efi"
    elif [ -f "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" ]; then
        mkdir -p "${MOUNT_POINT}/EFI/BOOT"
        cp "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" \
           "${MOUNT_POINT}/EFI/BOOT/BOOTX64.EFI"
        info "✓ Used host system grubx64.efi"
    else
        # 尝试使用 grub-mkimage 生成
        warn "GRUB EFI file not found, trying to generate..."
        if command -v grub-mkimage >/dev/null 2>&1; then
            mkdir -p "${MOUNT_POINT}/EFI/BOOT"
            grub-mkimage -O x86_64-efi -o "${MOUNT_POINT}/EFI/BOOT/BOOTX64.EFI" \
                -p /EFI/BOOT part_gpt part_msdos fat iso9660
            info "✓ Generated grubx64.efi using grub-mkimage"
        else
            warn "EFI boot may not work without grubx64.efi"
        fi
    fi
    
    # 复制 grub.cfg
    mkdir -p "${MOUNT_POINT}/EFI/BOOT"
    cp "${EFI_DIR}/EFI/BOOT/grub.cfg" "${MOUNT_POINT}/EFI/BOOT/"
    
    umount "${MOUNT_POINT}"
    rmdir "${MOUNT_POINT}"

    # 复制内核文件
    info "Copying kernel files..."
    
    # 查找内核文件
    KERNEL_FILE=$(find "${ROOTFS}/boot" -name "vmlinuz-*" | head -1)
    INITRD_FILE=$(find "${ROOTFS}/boot" -name "initramfs-*" | head -1)
    
    if [ -n "$KERNEL_FILE" ] && [ -n "$INITRD_FILE" ]; then
        cp "$KERNEL_FILE" "${WORK_DIR}/vmlinuz-lts"
        cp "$INITRD_FILE" "${WORK_DIR}/initramfs-lts"
        info "✓ Found kernel: $(basename $KERNEL_FILE)"
        info "✓ Found initrd: $(basename $INITRD_FILE)"
    else
        error "Could not find kernel files in ${ROOTFS}/boot"
    fi
    
    # 查找并复制 modloop（如果存在）
    if [ -f "${ROOTFS}/boot/modloop-lts" ]; then
        cp "${ROOTFS}/boot/modloop-lts" "${WORK_DIR}/"
        info "✓ Found modloop-lts"
    else
        # 尝试下载 modloop
        info "Downloading modloop file..."
        wget -q -O "${WORK_DIR}/modloop-lts" \
            "${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/modloop-lts" && \
        info "✓ Downloaded modloop-lts" || \
        warn "Modloop not available, system may have limited functionality"
    fi
}

# 创建 squashfs 根文件系统
create_squashfs() {
    info "Creating squashfs root filesystem..."
    
    # 清理不必要的文件以减小体积
    rm -rf "${ROOTFS}/var/cache/apk/*" 2>/dev/null || true
    rm -rf "${ROOTFS}/usr/share/man/*" 2>/dev/null || true
    rm -rf "${ROOTFS}/usr/share/doc/*" 2>/dev/null || true
    
    # 移除开发工具以减小体积
    chroot_exec "apk del --no-cache .build-deps 2>/dev/null || true"
    
    # 创建 squashfs（使用 gzip 压缩以获得更好的兼容性）
    mksquashfs "${ROOTFS}" "${WORK_DIR}/rootfs.squashfs" \
        -comp gzip \
        -b 1048576 \
        -no-progress \
        -noappend \
        -all-root
    
    local squashfs_size=$(du -h "${WORK_DIR}/rootfs.squashfs" | cut -f1)
    info "✓ Squashfs created: ${squashfs_size}"
}

# 准备 ISO 目录结构
prepare_iso_structure() {
    info "Preparing ISO directory structure..."
    
    # 创建 ISO 目录结构
    mkdir -p "${ISO_DIR}/boot/syslinux"
    mkdir -p "${ISO_DIR}/boot/grub"
    mkdir -p "${ISO_DIR}/EFI/BOOT"
    
    # 复制 BIOS 引导文件
    cp -r "${BIOS_DIR}/boot/syslinux"/* "${ISO_DIR}/boot/syslinux/" 2>/dev/null || true
    
    # 复制 EFI 引导镜像
    cp "${EFI_DIR}/efiboot.img" "${ISO_DIR}/boot/grub/"
    
    # 复制内核文件
    cp "${WORK_DIR}/vmlinuz-lts" "${ISO_DIR}/boot/"
    cp "${WORK_DIR}/initramfs-lts" "${ISO_DIR}/boot/"
    
    if [ -f "${WORK_DIR}/modloop-lts" ]; then
        cp "${WORK_DIR}/modloop-lts" "${ISO_DIR}/boot/"
    fi
    
    # 复制根文件系统
    cp "${WORK_DIR}/rootfs.squashfs" "${ISO_DIR}/"
    
    # 创建引导信息文件
    cat > "${ISO_DIR}/README.TXT" << EOF
Alpine Linux Minimal ${ALPINE_VERSION}
Dual Boot ISO (BIOS/UEFI)
Build date: $(date)

Boot options:
- BIOS/Legacy: Press any key for boot menu
- UEFI: Automatic boot with 5 second timeout

Default boot entry: "Boot Alpine Linux"
Kernel: $(basename $(find "${ROOTFS}/boot" -name "vmlinuz-*" | head -1))
Initramfs: $(basename $(find "${ROOTFS}/boot" -name "initramfs-*" | head -1))

System will boot into RAM. No installation required.
EOF
    
    info "✓ ISO directory structure prepared"
}

# 创建混合 ISO
create_hybrid_iso() {
    info "Creating hybrid ISO image..."
    
    cd "${WORK_DIR}"
    
    # 查找 isohdpfx.bin（用于创建混合 ISO）
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
        warn "isohdpfx.bin not found, creating simple MBR..."
        dd if=/dev/zero of=/tmp/isohdpfx.bin bs=512 count=1 2>/dev/null
        printf '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' | \
            dd of=/tmp/isohdpfx.bin conv=notrunc bs=1 count=16 2>/dev/null
        ISOHDPFX="/tmp/isohdpfx.bin"
    fi
    
    info "Using bootloader: ${ISOHDPFX}"
    
    # 使用 xorriso 创建支持 BIOS 和 EFI 的混合 ISO
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "ALPINEMIN" \
        -appid "Alpine Linux Minimal ${ALPINE_VERSION}" \
        -publisher "GitHub Actions" \
        -preparer "build-iso.sh" \
        \
        # BIOS 引导
        -eltorito-boot boot/syslinux/isolinux.bin \
        -eltorito-catalog boot/syslinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        \
        # EFI 引导
        -eltorito-alt-boot \
        -e boot/grub/efiboot.img \
        -no-emul-boot \
        \
        # 混合模式支持
        -isohybrid-mbr "${ISOHDPFX}" \
        \
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        "${ISO_DIR}" 2>&1 | grep -v "libisofs-WARNING" | grep -v "UPDATE-ISOHYDRATE" || true
    
    # 检查 ISO 是否创建成功
    if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
        local iso_size=$(du -h "${OUTPUT_DIR}/${ISO_NAME}" | cut -f1)
        info "✓ ISO created successfully!"
        info "  File: ${OUTPUT_DIR}/${ISO_NAME}"
        info "  Size: ${iso_size}"
        
        # 显示 ISO 信息
        info "ISO details:"
        isoinfo -d -i "${OUTPUT_DIR}/${ISO_NAME}" 2>/dev/null | \
            grep -E "Volume id:|Volume size:|Directory tree" || true
        
        return 0
    else
        error "Failed to create ISO"
    fi
}

# 主执行流程
main() {
    info "========================================"
    info "Alpine Linux Minimal ISO Builder"
    info "Version: ${ALPINE_VERSION}"
    info "Architecture: ${ARCH}"
    info "Output: ${ISO_NAME}"
    info "========================================"
    
    # 设置退出时的清理
    trap 'cleanup_chroot; info "Build process interrupted."; exit 1' INT TERM
    
    cleanup
    prepare_dirs
    download_rootfs
    configure_base_system
    install_packages
    configure_bootloader
    create_squashfs
    prepare_iso_structure
    create_hybrid_iso
    
    info "========================================"
    info "✓ Build completed successfully!"
    info "  ISO file: ${OUTPUT_DIR}/${ISO_NAME}"
    info "  Support: BIOS & UEFI dual boot"
    info "  Minimal system ready for use"
    info "========================================"
    
    # 显示最终的 ISO 位置
    ls -lh "${OUTPUT_DIR}/"*.iso 2>/dev/null || true
}

# 执行主函数
main "$@"
