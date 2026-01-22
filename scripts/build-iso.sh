#!/bin/bash
set -euo pipefail

# 配置
ISO_NAME="openwrt-installer"
WORK_DIR="/tmp/iso-build"
STAGING_DIR="${WORK_DIR}/staging"
ASSETS_DIR="./assets"
OUTPUT_DIR="/tmp"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[*]${NC} $1"; }
log_success() { echo -e "${GREEN}[+]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[-]${NC} $1"; }

# 清理并创建目录
cleanup() {
    log_info "清理工作目录..."
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"
    mkdir -p "${STAGING_DIR}"/{isolinux,live,boot/grub/x86_64-efi,EFI/BOOT}
}

# 创建最小initrd
create_initrd() {
    log_info "创建最小initrd..."
    
    # 创建initrd目录结构
    local initrd_dir="${WORK_DIR}/initrd-root"
    rm -rf "${initrd_dir}"
    mkdir -p "${initrd_dir}"/{bin,dev,etc,lib,lib64,mnt,proc,root,run,sbin,sys,tmp,usr/{bin,lib,sbin}}
    
    # 复制busybox
    if ! command -v busybox &> /dev/null; then
        log_info "下载busybox..."
        wget -q https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox -O "${initrd_dir}/bin/busybox"
        chmod +x "${initrd_dir}/bin/busybox"
    else
        cp $(which busybox) "${initrd_dir}/bin/busybox" 2>/dev/null || true
    fi
    
    # 创建必要的符号链接
    local busybox_path="${initrd_dir}/bin/busybox"
    if [ -f "${busybox_path}" ]; then
        cd "${initrd_dir}/bin"
        "${busybox_path}" --install -s .
        cd -
    fi
    
    # 创建init脚本
    cat > "${initrd_dir}/init" << 'EOF'
#!/bin/busybox sh

# 挂载必要的文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# 设置环境
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# 创建设备节点
mknod /dev/console c 5 1
mknod /dev/null c 1 3
mknod /dev/zero c 1 5

# 启动shell
echo ""
echo "========================================"
echo "    OpenWRT Installer - Minimal Shell"
echo "========================================"
echo ""

# 检查是否有OpenWRT镜像
if [ -f /mnt/openwrt.img ]; then
    echo "找到OpenWRT镜像: /mnt/openwrt.img"
    echo "运行 'install-openwrt' 开始安装"
    cp /mnt/openwrt.img /tmp/openwrt.img
else
    echo "错误: 未找到OpenWRT镜像"
fi

# 挂载ISO内容
mkdir -p /mnt/iso
mount -t iso9660 /dev/sr0 /mnt/iso 2>/dev/null || true
mount -t vfat /dev/sda1 /mnt/iso 2>/dev/null || true

# 复制安装脚本
cat > /tmp/install-openwrt << 'INSTALL_EOF'
#!/bin/busybox sh

echo "=== OpenWRT 安装程序 ==="
echo ""

# 查找磁盘
echo "可用磁盘:"
echo "----------------------"
/bin/busybox blkid | grep -v "TYPE=\"iso9660\"" || true
echo "----------------------"
echo ""

echo -n "输入目标磁盘 (如: sda): " && read DISK
[ -z "$DISK" ] && echo "无效输入" && exit 1

echo -n "确认安装到 /dev/$DISK? 输入 'yes' 确认: " && read CONFIRM
if [ "$CONFIRM" = "yes" ]; then
    echo "正在安装..."
    if dd if=/tmp/openwrt.img of=/dev/$DISK bs=4M status=progress; then
        echo "安装完成! 请重启系统。"
        echo -n "按回车重启..." && read
        /bin/busybox reboot -f
    else
        echo "安装失败!"
    fi
else
    echo "安装取消"
fi
INSTALL_EOF

chmod +x /tmp/install-openwrt
ln -s /tmp/install-openwrt /bin/install-openwrt

# 启动交互shell
exec /bin/busybox sh
EOF
    
    chmod +x "${initrd_dir}/init"
    
    # 打包initrd
    cd "${initrd_dir}"
    find . | cpio -H newc -o | gzip -9 > "${STAGING_DIR}/live/initrd.img"
    cd -
    
    log_success "initrd创建完成: $(ls -lh "${STAGING_DIR}/live/initrd.img")"
}

# 配置引导文件
setup_bootloaders() {
    log_info "配置引导加载程序..."
    
    # 复制ISOLINUX文件
    cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/"
    cp /usr/lib/syslinux/modules/bios/*.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true
    
    # ISOLINUX配置
    cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'EOF'
DEFAULT install
PROMPT 0
TIMEOUT 100
UI vesamenu.c32

MENU TITLE OpenWRT Installer
MENU BACKGROUND /isolinux/background.png
MENU COLOR border       30;44   #00000000 #00000000 none
MENU COLOR title        1;36;44 #ffffffff #00000000 none
MENU COLOR sel          7;37;40 #ff000000 #ffffffff none
MENU COLOR unsel        37;44   #ffffffff #00000000 none
MENU COLOR help         37;40   #cccccccc #00000000 none

LABEL install
    MENU LABEL ^Install OpenWRT
    MENU DEFAULT
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img console=ttyS0 console=tty0 quiet
    
LABEL shell
    MENU LABEL ^Debug Shell
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img console=ttyS0 console=tty0
    
LABEL memtest
    MENU LABEL ^Memory Test
    KERNEL /isolinux/memtest
    APPEND -
    
LABEL reboot
    MENU LABEL ^Reboot
    COM32 reboot.c32
EOF
    
    # GRUB配置 (UEFI)
    cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'EOF'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz console=ttyS0 console=tty0 quiet
    initrd /live/initrd.img
}

menuentry "Debug Shell" {
    linux /live/vmlinuz console=ttyS0 console=tty0
    initrd /live/initrd.img
}

menuentry "Reboot" {
    reboot
}
EOF
    
    cp "${STAGING_DIR}/boot/grub/grub.cfg" "${STAGING_DIR}/EFI/BOOT/"
    
    # 下载或使用精简内核
    local kernel_url="https://mirrors.edge.kernel.org/pub/linux/kernel/v5.x/linux-5.15.135.tar.xz"
    local kernel_dir="${WORK_DIR}/kernel"
    
    mkdir -p "${kernel_dir}"
    if [ ! -f "${kernel_dir}/.configured" ]; then
        log_info "下载精简内核..."
        wget -q "${kernel_url}" -O "${kernel_dir}/linux.tar.xz"
        tar -xf "${kernel_dir}/linux.tar.xz" -C "${kernel_dir}" --strip-components=1
        
        # 最小配置
        cd "${kernel_dir}"
        make defconfig
        # 仅启用必要功能
        sed -i 's/CONFIG_MODULES=y/CONFIG_MODULES=n/' .config
        sed -i 's/CONFIG_DEBUG_INFO=y/CONFIG_DEBUG_INFO=n/' .config
        echo "CONFIG_BLK_DEV_INITRD=y" >> .config
        echo "CONFIG_RD_GZIP=y" >> .config
        echo "CONFIG_DEVTMPFS=y" >> .config
        echo "CONFIG_TTY=y" >> .config
        echo "CONFIG_VT=y" >> .config
        echo "CONFIG_CONSOLE_TRANSLATIONS=y" >> .config
        echo "CONFIG_VT_CONSOLE=y" >> .config
        echo "CONFIG_HW_RANDOM=n" >> .config
        echo "CONFIG_NET=n" >> .config
        echo "CONFIG_SCSI=n" >> .config
        
        make -j$(nproc) bzImage
        cp arch/x86/boot/bzImage "${STAGING_DIR}/live/vmlinuz"
        cd -
        touch "${kernel_dir}/.configured"
    else
        cp "${kernel_dir}/arch/x86/boot/bzImage" "${STAGING_DIR}/live/vmlinuz" 2>/dev/null || \
        cp /boot/vmlinuz-$(uname -r) "${STAGING_DIR}/live/vmlinuz"
    fi
}

# 复制OpenWRT镜像
copy_openwrt_image() {
    log_info "复制OpenWRT镜像..."
    
    if [ -f "${ASSETS_DIR}/openwrt.img" ]; then
        cp "${ASSETS_DIR}/openwrt.img" "${STAGING_DIR}/live/openwrt.img"
        log_success "OpenWRT镜像已复制: $(ls -lh "${STAGING_DIR}/live/openwrt.img")"
    else
        log_warning "未找到OpenWRT镜像，创建测试文件..."
        dd if=/dev/zero of="${STAGING_DIR}/live/openwrt.img" bs=1M count=50
        mkfs.ext4 "${STAGING_DIR}/live/openwrt.img" >/dev/null 2>&1
    fi
}

# 生成EFI引导文件
create_efi_boot() {
    log_info "创建EFI引导文件..."
    
    # 生成GRUB EFI映像
    grub-mkstandalone -O x86_64-efi \
        --modules="part_gpt part_msdos fat iso9660" \
        --locales="" \
        --themes="" \
        --fonts="" \
        --output="${STAGING_DIR}/EFI/BOOT/BOOTx64.EFI" \
        "boot/grub/grub.cfg=${STAGING_DIR}/boot/grub/grub.cfg"
    
    grub-mkstandalone -O i386-efi \
        --modules="part_gpt part_msdos fat iso9660" \
        --locales="" \
        --themes="" \
        --fonts="" \
        --output="${STAGING_DIR}/EFI/BOOT/BOOTIA32.EFI" \
        "boot/grub/grub.cfg=${STAGING_DIR}/boot/grub/grub.cfg"
    
    # 创建EFI分区镜像
    dd if=/dev/zero of="${STAGING_DIR}/efiboot.img" bs=1M count=10
    mkfs.vfat -F 32 "${STAGING_DIR}/efiboot.img"
    
    mmd -i "${STAGING_DIR}/efiboot.img" ::/EFI ::/EFI/BOOT
    mcopy -i "${STAGING_DIR}/efiboot.img" \
        "${STAGING_DIR}/EFI/BOOT/BOOTx64.EFI" \
        "${STAGING_DIR}/EFI/BOOT/BOOTIA32.EFI" \
        "${STAGING_DIR}/boot/grub/grub.cfg" \
        ::/EFI/BOOT/
}

# 创建ISO
build_iso() {
    log_info "创建ISO镜像..."
    
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "OPENWRT_INSTALL" \
        -eltorito-boot isolinux/isolinux.bin \
        -boot-load-size 4 \
        -boot-info-table \
        -no-emul-boot \
        -eltorito-catalog isolinux/isolinux.cat \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -eltorito-alt-boot \
        -e efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -output "${OUTPUT_DIR}/${ISO_NAME}.iso" \
        "${STAGING_DIR}"
    
    # 使ISO支持USB启动
    isohybrid --uefi "${OUTPUT_DIR}/${ISO_NAME}.iso" 2>/dev/null || true
    
    log_success "ISO创建完成: ${OUTPUT_DIR}/${ISO_NAME}.iso"
    ls -lh "${OUTPUT_DIR}/${ISO_NAME}.iso"
}

# 主函数
main() {
    log_info "开始构建OpenWRT安装ISO..."
    
    cleanup
    copy_openwrt_image
    create_initrd
    setup_bootloaders
    create_efi_boot
    build_iso
    
    log_success "构建完成!"
    echo ""
    echo "下载链接:"
    echo "https://github.com/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
}

# 异常处理
trap 'log_error "构建过程出错"; exit 1' ERR

main "$@"
