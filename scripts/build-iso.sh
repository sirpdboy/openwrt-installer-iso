#!/bin/sh
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
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
    
    local rootfs_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ARCH}.tar.gz"
    local rootfs_file="${WORK_DIR}/alpine-minirootfs.tar.gz"
    
    wget -q --show-progress -O "${rootfs_file}" "${rootfs_url}" || \
    wget -O "${rootfs_file}" "${rootfs_url}" || \
    error "Failed to download Alpine rootfs"
    
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
}

# 安装必要的包
install_packages() {
    info "Installing essential packages..."
    
    # 使用 chroot 安装包
    chroot "${ROOTFS}" /bin/sh <<EOF
# 设置仓库
echo "${ALPINE_MIRROR}/v${ALPINE_VERSION}/main" > /etc/apk/repositories
echo "${ALPINE_MIRROR}/v${ALPINE_VERSION}/community" >> /etc/apk/repositories

# 更新并安装基础包
apk update
apk add --no-cache \
    alpine-base \
    linux-lts \
    syslinux \
    grub-efi \
    efibootmgr \
    dosfstools \
    mtools \
    squashfs-tools \
    xorriso
EOF
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
    
    # 创建 isolinux.cfg (BIOS 引导菜单)
    cat > "${BIOS_DIR}/boot/syslinux/isolinux.cfg" << 'EOF'
DEFAULT vesamenu.c32
PROMPT 0
MENU TITLE Alpine Linux Boot Menu
TIMEOUT 50
TIMEOUT_TOTAL 50

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

    # 复制内核和 initramfs
    cp "${ROOTFS}/boot/vmlinuz-lts" "${WORK_DIR}/"
    cp "${ROOTFS}/boot/initramfs-lts" "${WORK_DIR}/"
    cp "${ROOTFS}/boot/modloop-lts" "${WORK_DIR}/"
}

# 创建 squashfs 根文件系统
create_squashfs() {
    info "Creating squashfs root filesystem..."
    
    # 清理不必要的文件以减小体积
    rm -rf "${ROOTFS}/var/cache/apk/*"
    rm -rf "${ROOTFS}/usr/share/man/*"
    rm -rf "${ROOTFS}/usr/share/doc/*"
    
    # 创建 squashfs
    mksquashfs "${ROOTFS}" "${WORK_DIR}/rootfs.squashfs" -comp xz -b 1M -noappend
}

# 准备 ISO 目录结构
prepare_iso_structure() {
    info "Preparing ISO directory structure..."
    
    # 复制引导文件
    cp -r "${BIOS_DIR}/boot" "${ISO_DIR}/"
    cp -r "${EFI_DIR}/boot" "${ISO_DIR}/efiboot/"
    
    # 复制内核文件
    mkdir -p "${ISO_DIR}/boot"
    cp "${WORK_DIR}/vmlinuz-lts" "${ISO_DIR}/boot/"
    cp "${WORK_DIR}/initramfs-lts" "${ISO_DIR}/boot/"
    cp "${WORK_DIR}/modloop-lts" "${ISO_DIR}/boot/"
    
    # 复制根文件系统
    cp "${WORK_DIR}/rootfs.squashfs" "${ISO_DIR}/"
    
    # 创建引导信息文件
    echo "Alpine Linux Minimal ${ALPINE_VERSION} - Dual Boot (BIOS/UEFI)" > "${ISO_DIR}/README.TXT"
}

# 创建混合 ISO
create_hybrid_iso() {
    info "Creating hybrid ISO image..."
    
    cd "${WORK_DIR}"
    
    # 使用 xorriso 创建支持 BIOS 和 EFI 的混合 ISO
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "ALPINEMINIMAL" \
        -eltorito-boot boot/syslinux/isolinux.bin \
        -eltorito-catalog boot/syslinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${ROOTFS}/usr/share/syslinux/isohdpfx.bin" \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        "${ISO_DIR}/"
    
    # 检查 ISO 是否创建成功
    if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
        info "ISO created successfully: ${OUTPUT_DIR}/${ISO_NAME}"
        
        # 显示 ISO 信息
        du -h "${OUTPUT_DIR}/${ISO_NAME}"
        echo ""
        info "ISO build completed!"
        info "File: ${ISO_NAME}"
        info "Size: $(du -h ${OUTPUT_DIR}/${ISO_NAME} | cut -f1)"
        info "Supported: BIOS and UEFI boot"
    else
        error "Failed to create ISO"
    fi
}

# 主执行流程
main() {
    info "Starting Alpine Linux minimal ISO build..."
    info "Version: ${ALPINE_VERSION}"
    info "Architecture: ${ARCH}"
    
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
}

# 执行主函数
main
