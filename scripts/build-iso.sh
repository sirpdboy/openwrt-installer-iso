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
    
    local rootfs_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}.1-${ARCH}.tar.gz"
    local rootfs_file="${WORK_DIR}/alpine-minirootfs.tar.gz"
    
    # 使用版本 3.19.1 替代 3.19.0
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
    mknod -m 666 "${ROOTFS}/dev/null" c 1 3
    mknod -m 666 "${ROOTFS}/dev/zero" c 1 5
    mknod -m 666 "${ROOTFS}/dev/random" c 1 8
    mknod -m 666 "${ROOTFS}/dev/urandom" c 1 9
}

# 准备 chroot 环境
prepare_chroot() {
    info "Preparing chroot environment..."
    
    # 挂载必要的文件系统
    mount -t proc proc "${ROOTFS}/proc"
    mount -t sysfs sys "${ROOTFS}/sys"
    mount -o bind /dev "${ROOTFS}/dev"
    mount -o bind /dev/pts "${ROOTFS}/dev/pts"
    
    # 复制 DNS 配置
    cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf"
}

# 清理 chroot 环境
cleanup_chroot() {
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
    
    # 安装基础包（分开安装以避免依赖问题）
    chroot_exec "apk update"
    
    # 先安装最基础的包
    chroot_exec "apk add --no-cache alpine-base"
    chroot_exec "apk add --no-cache linux-lts"
    
    # 安装引导相关包
    chroot_exec "apk add --no-cache syslinux"
    chroot_exec "apk add --no-cache grub grub-efi"
    
    # 安装其他必要工具
    chroot_exec "apk add --no-cache efibootmgr dosfstools mtools squashfs-tools xorriso"
    
    # 创建 initramfs 配置，避免警告
    cat > "${ROOTFS}/etc/mkinitfs/mkinitfs.conf" << EOF
features="base squashfs ext4 mmc nvme scsi usb virtio"
kernel_opts=""
modules=""
builtin_modules=""
files=""
EOF
    
    # 手动创建 initramfs，指定 root 设备
    chroot_exec "mkinitfs -c /etc/mkinitfs/mkinitfs.conf -b / /boot/initramfs-lts"
    
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

    # 创建简单的背景图片（1x1 像素）
    echo -e "P1\n1 1\n0" > "${BIOS_DIR}/boot/syslinux/splash.png" 2>/dev/null || \
    echo "" > "${BIOS_DIR}/boot/syslinux/splash.png"

    # 创建 grub.cfg (EFI 引导菜单)
    mkdir -p "${EFI_DIR}/boot/grub"
    cat > "${EFI_DIR}/boot/grub/grub.cfg" << 'EOF'
set timeout=5
set default=0

menuentry "Boot Alpine Linux" {
    echo "Loading kernel..."
    linux /boot/vmlinuz-lts root=/dev/ram0 alpine_dev=cdrom:vfat modloop=/boot/modloop-lts console=tty0 console=ttyS0,115200 modules=loop,squashfs,sd-mod,usb-storage quiet
    echo "Loading initramfs..."
    initrd /boot/initramfs-lts
}

menuentry "Boot from first hard disk" {
    echo "Booting from first hard disk..."
    chainloader (hd0)
}
EOF

    # 创建 EFI 引导镜像
    info "Creating EFI boot image..."
    dd if=/dev/zero of="${EFI_DIR}/boot/grub/efi.img" bs=1M count=10
    mkfs.vfat "${EFI_DIR}/boot/grub/efi.img"
    
    # 挂载并复制 GRUB EFI 文件
    MOUNT_POINT=$(mktemp -d)
    mount "${EFI_DIR}/boot/grub/efi.img" "${MOUNT_POINT}"
    mkdir -p "${MOUNT_POINT}/EFI/BOOT"
    
    # 复制 GRUB EFI 文件
    cp "${ROOTFS}/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" "${MOUNT_POINT}/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || \
    cp "${ROOTFS}/usr/share/grub/grubx64.efi" "${MOUNT_POINT}/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || \
    warn "Could not find grubx64.efi, EFI boot may not work"
    
    umount "${MOUNT_POINT}"
    rmdir "${MOUNT_POINT}"

    # 复制内核文件 - 使用正确的路径
    info "Copying kernel files..."
    
    # 首先检查标准位置
    if [ -f "${ROOTFS}/boot/vmlinuz-lts" ]; then
        cp "${ROOTFS}/boot/vmlinuz-lts" "${WORK_DIR}/"
        cp "${ROOTFS}/boot/initramfs-lts" "${WORK_DIR}/"
        
        # 检查 modloop 文件（可能有不同的名称）
        if [ -f "${ROOTFS}/boot/modloop-lts" ]; then
            cp "${ROOTFS}/boot/modloop-lts" "${WORK_DIR}/"
        elif [ -f "${ROOTFS}/boot/initramfs-lts.extra" ]; then
            cp "${ROOTFS}/boot/initramfs-lts.extra" "${WORK_DIR}/modloop-lts"
        else
            # 下载 modloop
            warn "modloop-lts not found, downloading..."
            wget -O "${WORK_DIR}/modloop-lts" \
                "${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/modloop-lts" || \
            warn "Failed to download modloop-lts"
        fi
    else
        # 如果标准位置没有，搜索其他位置
        KERNEL_FILE=$(find "${ROOTFS}/boot" -name "vmlinuz*" | head -1)
        INITRD_FILE=$(find "${ROOTFS}/boot" -name "initramfs*" | head -1)
        
        if [ -n "$KERNEL_FILE" ] && [ -n "$INITRD_FILE" ]; then
            cp "$KERNEL_FILE" "${WORK_DIR}/vmlinuz-lts"
            cp "$INITRD_FILE" "${WORK_DIR}/initramfs-lts"
            warn "Using alternative kernel files: $(basename $KERNEL_FILE), $(basename $INITRD_FILE)"
        else
            error "Could not find kernel files in ${ROOTFS}/boot"
        fi
    fi
}

# 创建 squashfs 根文件系统
create_squashfs() {
    info "Creating squashfs root filesystem..."
    
    # 清理不必要的文件以减小体积
    rm -rf "${ROOTFS}/var/cache/apk/*" 2>/dev/null || true
    rm -rf "${ROOTFS}/usr/share/man/*" 2>/dev/null || true
    rm -rf "${ROOTFS}/usr/share/doc/*" 2>/dev/null || true
    rm -rf "${ROOTFS}/boot/initramfs-*" 2>/dev/null || true
    rm -rf "${ROOTFS}/boot/vmlinuz-*" 2>/dev/null || true
    
    # 创建 squashfs
    mksquashfs "${ROOTFS}" "${WORK_DIR}/rootfs.squashfs" -comp xz -b 1M -noappend -all-root
    
    info "Squashfs size: $(du -h ${WORK_DIR}/rootfs.squashfs | cut -f1)"
}

# 准备 ISO 目录结构
prepare_iso_structure() {
    info "Preparing ISO directory structure..."
    
    # 创建 ISO 目录
    mkdir -p "${ISO_DIR}/boot/syslinux"
    mkdir -p "${ISO_DIR}/efiboot"
    
    # 复制 BIOS 引导文件
    cp -r "${BIOS_DIR}/boot/syslinux"/* "${ISO_DIR}/boot/syslinux/"
    
    # 复制 EFI 引导文件
    mkdir -p "${ISO_DIR}/boot/grub"
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
    echo "Alpine Linux Minimal ${ALPINE_VERSION} - Dual Boot (BIOS/UEFI)" > "${ISO_DIR}/README.TXT"
    echo "Build date: $(date)" >> "${ISO_DIR}/README.TXT"
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
            warn "isohdpfx.bin not found, downloading..."
            wget -O /tmp/isohdpfx.bin https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz
            tar -Oxf /tmp/isohdpfx.bin syslinux-6.04-pre1/bios/mbr/isohdpfx.bin > /tmp/isohdpfx_extracted.bin
            ISOHDPFX="/tmp/isohdpfx_extracted.bin"
        fi
    fi
    
    # 使用 xorriso 创建支持 BIOS 和 EFI 的混合 ISO
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "ALPINEMINIMAL" \
        -appid "Alpine Linux Minimal ${ALPINE_VERSION}" \
        -publisher "Built with GitHub Actions" \
        -preparer "Alpine Linux Builder" \
        -eltorito-boot boot/syslinux/isolinux.bin \
        -eltorito-catalog boot/syslinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${ISOHDPFX}" \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        "${ISO_DIR}/" 2>&1 | grep -v "libisofs-WARNING"
    
    # 检查 ISO 是否创建成功
    if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
        info "ISO created successfully: ${OUTPUT_DIR}/${ISO_NAME}"
        
        # 显示 ISO 信息
        ISO_SIZE=$(du -h "${OUTPUT_DIR}/${ISO_NAME}" | cut -f1)
        info "ISO size: ${ISO_SIZE}"
        
        # 添加 ISO 验证信息
        info "ISO verification:"
        file "${OUTPUT_DIR}/${ISO_NAME}"
        echo ""
        isoinfo -d -i "${OUTPUT_DIR}/${ISO_NAME}" | grep -E "Volume id:|Volume size:|Boot media type:"
        
    else
        error "Failed to create ISO"
    fi
}

# 主执行流程
main() {
    info "Starting Alpine Linux minimal ISO build..."
    info "Version: ${ALPINE_VERSION}"
    info "Architecture: ${ARCH}"
    
    trap cleanup_chroot EXIT
    
    cleanup
    prepare_dirs
    download_rootfs
    configure_base_system
    install_packages
    configure_bootloader
    create_squashfs
    prepare_iso_structure
    create_hybrid_iso
    
    info "Build process completed successfully!"
    info "ISO file: ${OUTPUT_DIR}/${ISO_NAME}"
}

# 执行主函数
main
