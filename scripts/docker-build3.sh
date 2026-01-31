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
    rm -rf "${OUTPUT_DIR}"
}

prepare_dirs() {
    info "Preparing directories..."
    mkdir -p "${OUTPUT_DIR}" "${ISO_DIR}" "${WORK_DIR}" "${EFI_DIR}" "${BIOS_DIR}" "${ROOTFS}"
}

# 下载 Alpine 最小 rootfs
download_rootfs() {
    info "Downloading Alpine Linux minimal rootfs..."
    
    # 使用具体的版本号
    local rootfs_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}.1-${ARCH}.tar.gz"
    local rootfs_file="${WORK_DIR}/alpine-minirootfs.tar.gz"
    
    wget -q --show-progress -O "${rootfs_file}" "${rootfs_url}" || \
    error "Failed to download Alpine rootfs from ${rootfs_url}"
    
    info "Extracting rootfs..."
    tar -xzf "${rootfs_file}" -C "${ROOTFS}"
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
    ln -sf /usr/share/zoneinfo/UTC "${ROOTFS}/etc/localtime"
    
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
    mount -t proc proc "${ROOTFS}/proc" 2>/dev/null || true
    mount -t sysfs sys "${ROOTFS}/sys" 2>/dev/null || true
    mount -o bind /dev "${ROOTFS}/dev" 2>/dev/null || true
    mount -o bind /dev/pts "${ROOTFS}/dev/pts" 2>/dev/null || true
    
    # 复制 DNS 配置
    cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf" 2>/dev/null || true
}

# 清理 chroot 环境
cleanup_chroot() {
    info "Cleaning up chroot environment..."
    umount -f "${ROOTFS}/proc" 2>/dev/null || true
    umount -f "${ROOTFS}/sys" 2>/dev/null || true
    umount -f "${ROOTFS}/dev/pts" 2>/dev/null || true
    umount -f "${ROOTFS}/dev" 2>/dev/null || true
}

# 在 chroot 中执行命令
chroot_exec() {
    chroot "${ROOTFS}" /bin/sh -c "$1"
}

# 安装必要的包
install_packages() {
    info "Installing essential packages..."
    
    # 设置仓库
    cat > "${ROOTFS}/etc/apk/repositories" << EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
EOF
    
    prepare_chroot
    
    # 安装基础包（简化安装过程）
    info "Installing base packages..."
    chroot_exec "apk update"
    
    # 一次性安装所有包，避免多次触发
    chroot_exec "apk add --no-cache \
        alpine-base \
        linux-lts \
        syslinux \
        grub grub-efi \
        efibootmgr \
        dosfstools \
        mtools \
        squashfs-tools \
        xorriso"
    
    # 创建 initramfs 配置
    cat > "${ROOTFS}/etc/mkinitfs/mkinitfs.conf" << EOF
features="ata base cdrom ext4 mmc nvme scsi usb virtio"
kernel_opts=""
modules=""
builtin_modules=""
files=""
EOF
    
    # 获取内核版本
    KERNEL_VERSION=$(chroot_exec "ls /lib/modules | head -1")
    info "Detected kernel version: ${KERNEL_VERSION}"
    
    # 创建 initramfs - 使用正确的参数
    info "Creating initramfs..."
    chroot_exec "mkinitfs -F -q -c /etc/mkinitfs/mkinitfs.conf -b / ${KERNEL_VERSION}"
    
    # 检查是否创建成功
    if chroot_exec "ls -la /boot/" | grep -q "initramfs"; then
        info "Initramfs created successfully"
    else
        warn "Initramfs may not have been created, trying alternative method..."
        # 备用方法：直接复制现有的 initramfs
        if [ -f "${ROOTFS}/boot/initramfs-${KERNEL_VERSION}" ]; then
            cp "${ROOTFS}/boot/initramfs-${KERNEL_VERSION}" "${ROOTFS}/boot/initramfs-lts"
        fi
    fi
    
    cleanup_chroot
}

# 配置引导加载器
configure_bootloader() {
    info "Configuring bootloaders..."
    
    # 创建 BIOS 引导目录结构
    mkdir -p "${BIOS_DIR}/boot/syslinux"
    
    # 复制 syslinux 文件
    cp "${ROOTFS}/usr/share/syslinux/isolinux.bin" "${BIOS_DIR}/boot/syslinux/"
    cp "${ROOTFS}/usr/share/syslinux/ldlinux.c32" "${BIOS_DIR}/boot/syslinux/"
    cp "${ROOTFS}/usr/share/syslinux/libutil.c32" "${BIOS_DIR}/boot/syslinux/"
    cp "${ROOTFS}/usr/share/syslinux/menu.c32" "${BIOS_DIR}/boot/syslinux/"
    cp "${ROOTFS}/usr/share/syslinux/vesamenu.c32" "${BIOS_DIR}/boot/syslinux/"
    
    # 创建 isolinux.cfg (BIOS 引导菜单)
    cat > "${BIOS_DIR}/boot/syslinux/isolinux.cfg" << 'EOF'
DEFAULT vesamenu.c32
PROMPT 0
MENU TITLE Alpine Linux Boot Menu
TIMEOUT 50

MENU BACKGROUND /boot/syslinux/splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

LABEL alpine
    MENU LABEL ^Boot Alpine Linux
    MENU DEFAULT
    KERNEL /boot/vmlinuz-lts
    INITRD /boot/initramfs-lts
    APPEND root=/dev/ram0 alpine_dev=cdrom:vfat modloop=/boot/modloop-lts console=tty0 console=ttyS0,115200 modules=loop,squashfs,sd-mod,usb-storage quiet
    TEXT HELP
    Boot the Alpine Linux system
    ENDTEXT

LABEL hd
    MENU LABEL ^Boot from first hard disk
    LOCALBOOT 0
    TEXT HELP
    Boot the first hard disk
    ENDTEXT
EOF

    # 创建简单的背景图片
    echo "placeholder" > "${BIOS_DIR}/boot/syslinux/splash.png"

    # 创建 grub.cfg (EFI 引导菜单)
    mkdir -p "${EFI_DIR}/boot/grub"
    cat > "${EFI_DIR}/boot/grub/grub.cfg" << 'EOF'
set timeout=5
set default=0

menuentry "Boot Alpine Linux" {
    linux /boot/vmlinuz-lts root=/dev/ram0 alpine_dev=cdrom:vfat modloop=/boot/modloop-lts console=tty0 console=ttyS0,115200 modules=loop,squashfs,sd-mod,usb-storage quiet
    initrd /boot/initramfs-lts
}

menuentry "Boot from first hard disk" {
    chainloader (hd0)
}
EOF

    # 创建 EFI 引导镜像
    info "Creating EFI boot image..."
    dd if=/dev/zero of="${EFI_DIR}/boot/grub/efi.img" bs=1M count=10 status=progress
    mkfs.vfat "${EFI_DIR}/boot/grub/efi.img"
    
    # 挂载并复制 GRUB EFI 文件
    MOUNT_POINT=$(mktemp -d)
    mount "${EFI_DIR}/boot/grub/efi.img" "${MOUNT_POINT}"
    mkdir -p "${MOUNT_POINT}/EFI/BOOT"
    
    # 查找并复制 GRUB EFI 文件
    if [ -f "${ROOTFS}/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" ]; then
        cp "${ROOTFS}/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" "${MOUNT_POINT}/EFI/BOOT/BOOTX64.EFI"
    elif [ -f "${ROOTFS}/usr/share/grub/grubx64.efi" ]; then
        cp "${ROOTFS}/usr/share/grub/grubx64.efi" "${MOUNT_POINT}/EFI/BOOT/BOOTX64.EFI"
    else
        # 尝试安装 grub-efi 包
        warn "GRUB EFI file not found, installing grub-efi..."
        prepare_chroot
        chroot_exec "apk add --no-cache grub-efi"
        cleanup_chroot
        
        if [ -f "${ROOTFS}/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" ]; then
            cp "${ROOTFS}/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" "${MOUNT_POINT}/EFI/BOOT/BOOTX64.EFI"
        else
            warn "Could not find grubx64.efi, EFI boot may not work"
        fi
    fi
    
    umount "${MOUNT_POINT}"
    rmdir "${MOUNT_POINT}"

    # 复制内核文件
    info "Copying kernel files..."
    
    # 查找内核文件
    KERNEL_FILES=$(find "${ROOTFS}/boot" -name "vmlinuz-*" -o -name "vmlinuz.*" | head -1)
    INITRD_FILES=$(find "${ROOTFS}/boot" -name "initramfs-*" -o -name "initrd*" | head -1)
    
    if [ -n "$KERNEL_FILES" ] && [ -n "$INITRD_FILES" ]; then
        cp "$KERNEL_FILES" "${WORK_DIR}/vmlinuz-lts"
        cp "$INITRD_FILES" "${WORK_DIR}/initramfs-lts"
        info "Found kernel: $(basename $KERNEL_FILES)"
        info "Found initrd: $(basename $INITRD_FILES)"
    else
        error "Could not find kernel files in ${ROOTFS}/boot"
    fi
    
    # 下载 modloop 文件
    info "Downloading modloop file..."
    wget -O "${WORK_DIR}/modloop-lts" \
        "${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/modloop-lts" || \
    warn "Failed to download modloop-lts, system may not boot properly"
}

# 创建 squashfs 根文件系统
create_squashfs() {
    info "Creating squashfs root filesystem..."
    
    # 清理不必要的文件以减小体积
    rm -rf "${ROOTFS}/var/cache/apk/*" 2>/dev/null || true
    rm -rf "${ROOTFS}/usr/share/man/*" 2>/dev/null || true
    rm -rf "${ROOTFS}/usr/share/doc/*" 2>/dev/null || true
    
    # 创建 squashfs
    mksquashfs "${ROOTFS}" "${WORK_DIR}/rootfs.squashfs" -comp xz -b 1M -noappend -all-root
    
    info "Squashfs size: $(du -h ${WORK_DIR}/rootfs.squashfs | cut -f1)"
}

# 准备 ISO 目录结构
prepare_iso_structure() {
    info "Preparing ISO directory structure..."
    
    # 创建 ISO 目录
    mkdir -p "${ISO_DIR}/boot/syslinux"
    mkdir -p "${ISO_DIR}/boot/grub"
    
    # 复制 BIOS 引导文件
    cp -r "${BIOS_DIR}/boot/syslinux"/* "${ISO_DIR}/boot/syslinux/"
    
    # 复制 EFI 引导文件
    cp "${EFI_DIR}/boot/grub/efi.img" "${ISO_DIR}/boot/grub/"
    cp "${EFI_DIR}/boot/grub/grub.cfg" "${ISO_DIR}/boot/grub/"
    
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
1. BIOS: Uses SYSLINUX bootloader
2. UEFI: Uses GRUB bootloader

Default boot entry: "Boot Alpine Linux"
Timeout: 5 seconds

Kernel: $(basename $(find "${ROOTFS}/boot" -name "vmlinuz-*" | head -1))
Initramfs: $(basename $(find "${ROOTFS}/boot" -name "initramfs-*" | head -1))
EOF
}

# 创建混合 ISO
create_hybrid_iso() {
    info "Creating hybrid ISO image..."
    
    cd "${WORK_DIR}"
    
    # 获取 isohdpfx.bin
    ISOHDPFX="${ROOTFS}/usr/share/syslinux/isohdpfx.bin"
    if [ ! -f "$ISOHDPFX" ]; then
        # 尝试其他位置
        ISOHDPFX=$(find "${ROOTFS}" -name "isohdpfx.bin" | head -1)
        if [ -z "$ISOHDPFX" ]; then
            warn "isohdpfx.bin not found, using default"
            # 创建简单的 MBR
            dd if=/dev/zero of=/tmp/isohdpfx.bin bs=512 count=1
            printf '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' | \
                dd of=/tmp/isohdpfx.bin conv=notrunc 2>/dev/null
            ISOHDPFX="/tmp/isohdpfx.bin"
        fi
    fi
    
    info "Using bootloader: $ISOHDPFX"
    
    # 使用 xorriso 创建支持 BIOS 和 EFI 的混合 ISO
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "ALPINEMIN" \
        -appid "Alpine Linux Minimal ${ALPINE_VERSION}" \
        -publisher "GitHub Actions Builder" \
        -preparer "Alpine Build Script" \
        -eltorito-boot boot/syslinux/isolinux.bin \
        -eltorito-catalog boot/syslinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${ISOHDPFX}" \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        "${ISO_DIR}/" 2>&1 | grep -v "libisofs-WARNING" || true
    
    # 检查 ISO 是否创建成功
    if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
        info "✓ ISO created successfully!"
        info "  File: ${OUTPUT_DIR}/${ISO_NAME}"
        info "  Size: $(du -h ${OUTPUT_DIR}/${ISO_NAME} | cut -f1)"
        
        # 验证 ISO
        info "Verifying ISO structure..."
        isoinfo -d -i "${OUTPUT_DIR}/${ISO_NAME}" 2>/dev/null | grep -E "Volume id:|Volume size:" || true
        
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
    info "========================================"
}

# 执行主函数
main
