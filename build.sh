#!/bin/bash
set -e

# 配置变量
WORKDIR="${HOME}/OPENWRT_INSTALLER"
CHROOT_DIR="${WORKDIR}/chroot"
STAGING_DIR="${WORKDIR}/staging"
ISO_NAME="openwrt-installer.iso"
OPENWRT_IMG="openwrt-x86-64-generic-squashfs-combined.img"
DEBIAN_MIRROR="http://ftp.us.debian.org/debian/"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[-]${NC} $1"
}

# 检查依赖
check_dependencies() {
    print_status "检查依赖包..."
    local deps=(
        debootstrap squashfs-tools xorriso isolinux syslinux-efi
        grub-pc-bin grub-efi-amd64-bin grub-efi-ia32-bin
        mtools dosfstools
    )
    
    for dep in "${deps[@]}"; do
        if ! dpkg -l | grep -q "^ii  $dep "; then
            print_error "缺少依赖: $dep"
            print_status "正在安装依赖包..."
            sudo apt-get update
            sudo apt-get install -y "${deps[@]}"
            break
        fi
    done
}

# 创建工作目录
setup_workspace() {
    print_status "设置工作目录..."
    rm -rf "${WORKDIR}"
    mkdir -p "${WORKDIR}"
    mkdir -p "${CHROOT_DIR}"
    mkdir -p "${STAGING_DIR}"/{EFI/BOOT,boot/grub/x86_64-efi,isolinux,live}
    mkdir -p "${WORKDIR}/tmp"
}

# 引导Debian最小系统
bootstrap_debian() {
    print_status "引导Debian最小系统..."
    sudo debootstrap \
        --arch=amd64 \
        --variant=minbase \
        --include=linux-image-amd64,linux-headers-amd64,live-boot,systemd-sysv \
        stable \
        "${CHROOT_DIR}" \
        "${DEBIAN_MIRROR}"
    
    # 设置主机名
    echo "openwrt-installer" | sudo tee "${CHROOT_DIR}/etc/hostname"
    
    # 配置网络
    cat << EOF | sudo tee "${CHROOT_DIR}/etc/network/interfaces"
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
}

# 自定义chroot环境
customize_chroot() {
    print_status "自定义chroot环境..."
    
    # 安装必要软件包（最小化）
    sudo chroot "${CHROOT_DIR}" /bin/bash << 'EOF'
apt-get update
apt-get install -y --no-install-recommends \
    dialog \
    pciutils \
    usbutils \
    fdisk \
    gdisk \
    parted \
    e2fsprogs \
    dosfstools \
    ntfs-3g \
    bash \
    coreutils \
    util-linux \
    less \
    nano \
    wget \
    curl \
    iproute2 \
    net-tools \
    iwd \
    openssh-client \
    ca-certificates \
    sudo \
    kmod
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
EOF
    
    # 设置root密码（空密码，live环境允许root登录）
    sudo chroot "${CHROOT_DIR}" passwd -d root
    
    # 允许root通过串口登录
    echo "ttyS0:23:respawn:/sbin/getty -L ttyS0 115200 vt100" | sudo tee -a "${CHROOT_DIR}/etc/inittab"
    
    # 创建安装脚本目录
    sudo mkdir -p "${CHROOT_DIR}/usr/local/bin"
}

# 复制OpenWRT安装脚本
copy_install_scripts() {
    print_status "复制安装脚本..."
    
    # 核心安装脚本
    cat << 'EOF' | sudo tee "${CHROOT_DIR}/usr/local/bin/install-openwrt.sh" > /dev/null
#!/bin/bash
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[*]${NC} $1"; }
log_success() { echo -e "${GREEN}[+]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[-]${NC} $1"; }

# 显示标题
clear
echo "================================================"
echo "       OpenWRT 安装程序"
echo "================================================"
echo ""

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "需要root权限运行此脚本"
    exit 1
fi

# 查找OpenWRT镜像
OPENWRT_IMG="/live/openwrt.img"
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "找不到OpenWRT镜像: $OPENWRT_IMG"
    exit 1
fi

log_info "找到OpenWRT镜像: $(ls -lh "$OPENWRT_IMG")"

# 显示磁盘列表
log_info "检测可用磁盘..."
echo ""
echo "可用磁盘列表:"
echo "--------------------------------"

DISKS=()
while IFS= read -r line; do
    if [[ "$line" =~ ^/dev/[sv]d[a-z] ]]; then
        disk=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $4}')
        model=$(echo "$line" | awk '{print $3}')
        DISKS+=("$disk")
        printf "  %-10s %-10s %s\n" "$disk" "$size" "$model"
    fi
done < <(lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "NAME")

echo "--------------------------------"
echo ""

if [ ${#DISKS[@]} -eq 0 ]; then
    log_error "未找到可用磁盘"
    exit 1
fi

# 选择磁盘
while true; do
    read -p "请输入要安装OpenWRT的磁盘 (例如: /dev/sda): " TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        log_warning "请输入磁盘设备路径"
        continue
    fi
    
    if [[ ! "$TARGET_DISK" =~ ^/dev/[sv]d[a-z]$ ]]; then
        log_warning "无效的磁盘设备路径。请使用类似 /dev/sda 的格式"
        continue
    fi
    
    if [ ! -b "$TARGET_DISK" ]; then
        log_warning "磁盘 $TARGET_DISK 不存在"
        continue
    fi
    
    # 确认选择
    DISK_INFO=$(lsblk -d -o SIZE,MODEL "$TARGET_DISK" 2>/dev/null | tail -1)
    if [ -z "$DISK_INFO" ]; then
        log_warning "无法获取磁盘信息"
        continue
    fi
    
    echo ""
    log_warning "警告：这将完全擦除磁盘 $TARGET_DISK 上的所有数据！"
    echo "磁盘信息: $DISK_INFO"
    echo ""
    
    read -p "确认安装到 $TARGET_DISK ？输入 'y' 确认: " CONFIRM
    
    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
        break
    else
        echo "取消选择，请重新选择磁盘"
        echo ""
    fi
done

# 确认安装
echo ""
echo "================================================"
log_warning "最终确认"
echo "================================================"
echo "目标磁盘: $TARGET_DISK"
echo "源镜像: $OPENWRT_IMG"
echo ""
echo "此操作将："
echo "1. 擦除 $TARGET_DISK 上的所有分区和数据"
echo "2. 写入OpenWRT系统镜像"
echo "3. 磁盘将无法恢复原有数据"
echo ""

read -p "输入 'yes' 确认开始安装: " FINAL_CONFIRM

if [ "$FINAL_CONFIRM" != "yes" ]; then
    log_error "安装已取消"
    exit 0
fi

# 开始安装
echo ""
log_info "开始安装OpenWRT到 $TARGET_DISK ..."
echo ""

# 卸载所有相关分区
for partition in $(lsblk -lno NAME "$TARGET_DISK" | grep -v "^$(basename "$TARGET_DISK")$"); do
    umount "/dev/$partition" 2>/dev/null || true
done

# 使用dd写入镜像
log_info "正在写入镜像，这可能需要几分钟..."
if ! dd if="$OPENWRT_IMG" of="$TARGET_DISK" bs=4M status=progress; then
    log_error "镜像写入失败"
    exit 1
fi

# 同步磁盘
sync

echo ""
log_success "OpenWRT安装完成！"
echo ""
log_info "请执行以下操作："
echo "1. 移除安装介质"
echo "2. 设置从 $TARGET_DISK 启动"
echo "3. 重启系统"
echo ""
read -p "按Enter键重启系统，或按Ctrl+C取消..." </dev/tty

# 重启
reboot
EOF
    
    sudo chmod +x "${CHROOT_DIR}/usr/local/bin/install-openwrt.sh"
    
    # 创建自动启动脚本
    cat << 'EOF' | sudo tee "${CHROOT_DIR}/etc/init.d/installer-autorun" > /dev/null
#!/bin/sh
### BEGIN INIT INFO
# Provides:          installer-autorun
# Required-Start:    $local_fs $network $named $time $syslog
# Required-Stop:     $local_fs $network $named $time $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Description:       OpenWRT Installer Auto-run
### END INIT INFO

case "$1" in
    start)
        # 检查是否在live环境中
        if [ -d /live ]; then
            # 等待控制台就绪
            sleep 3
            
            # 检查是否已经安装过
            if [ ! -f /tmp/installer-run ]; then
                touch /tmp/installer-run
                /usr/local/bin/install-openwrt.sh
            fi
        fi
        ;;
    stop)
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac

exit 0
EOF
    
    sudo chmod +x "${CHROOT_DIR}/etc/init.d/installer-autorun"
    sudo chroot "${CHROOT_DIR}" update-rc.d installer-autorun defaults
}

# 准备引导文件
prepare_boot_files() {
    print_status "准备引导文件..."
    
    # 压缩chroot为squashfs
    print_status "创建squashfs文件系统..."
    sudo mksquashfs \
        "${CHROOT_DIR}" \
        "${STAGING_DIR}/live/filesystem.squashfs" \
        -comp xz \
        -b 1M \
        -noappend \
        -no-recovery \
        -always-use-fragments \
        -no-duplicates \
        -e boot
    
    # 复制内核和initrd
    cp "${CHROOT_DIR}/boot"/vmlinuz-* \
        "${STAGING_DIR}/live/vmlinuz" 2>/dev/null || true
    cp "${CHROOT_DIR}/boot"/initrd.img-* \
        "${STAGING_DIR}/live/initrd" 2>/dev/null || true
    
    # 如果没找到，使用通用名称
    if [ ! -f "${STAGING_DIR}/live/vmlinuz" ]; then
        cp "$(ls ${CHROOT_DIR}/boot/vmlinuz* | head -1)" \
            "${STAGING_DIR}/live/vmlinuz"
    fi
    if [ ! -f "${STAGING_DIR}/live/initrd" ]; then
        cp "$(ls ${CHROOT_DIR}/boot/initrd.img* | head -1)" \
            "${STAGING_DIR}/live/initrd"
    fi
    
    # 复制OpenWRT镜像到live目录
    if [ -f "assets/${OPENWRT_IMG}" ]; then
        cp "assets/${OPENWRT_IMG}" "${STAGING_DIR}/live/openwrt.img"
    else
        print_warning "未找到OpenWRT镜像，请将镜像放入assets/目录"
        touch "${STAGING_DIR}/live/openwrt.img"  # 创建空文件用于测试
    fi
}

# 创建引导菜单
create_boot_menus() {
    print_status "创建引导菜单..."
    
    # BIOS/ISOLINUX菜单
    cat << 'EOF' > "${STAGING_DIR}/isolinux/isolinux.cfg"
UI vesamenu.c32

MENU TITLE OpenWRT Installer
DEFAULT install
TIMEOUT 300
PROMPT 0
MENU RESOLUTION 800 600
MENU BACKGROUND /isolinux/background.png

MENU COLOR screen       37;40   #00000000 #00000000 none
MENU COLOR border       30;44   #00000000 #00000000 none
MENU COLOR title        1;36;44 #ffffffff #00000000 none
MENU COLOR unsel        37;44   #ffffffff #00000000 none
MENU COLOR hotkey       1;37;44 #ffffffff #00000000 none
MENU COLOR sel          7;37;40 #ff000000 #ffffffff none
MENU COLOR hotsel       1;7;37;40 #ff000000 #ffffffff none
MENU COLOR disabled     1;30;44 #cccccccc #00000000 none
MENU COLOR scrollbar    30;44   #00000000 #00000000 none
MENU COLOR tabmsg       31;40   #ffffffff #00000000 none
MENU COLOR cmdmark      1;36;40 #ffffffff #00000000 none
MENU COLOR cmdline      37;40   #ffffffff #00000000 none
MENU COLOR pwdborder    30;47   #ffffffff #00000000 none
MENU COLOR pwdheader    31;47   #ffffffff #00000000 none
MENU COLOR pwdentry     30;47   #ffffffff #00000000 none
MENU COLOR timeout_msg  37;40   #ffffffff #00000000 none
MENU COLOR timeout      1;37;40 #ffffffff #00000000 none
MENU COLOR help         37;40   #cccccccc #00000000 none
MENU COLOR msg07        37;40   #90ffffff #00000000 none

LABEL install
    MENU LABEL ^Install OpenWRT
    MENU DEFAULT
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd boot=live components quiet splash --
    
LABEL shell
    MENU LABEL ^Open Shell (Debug)
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd boot=live components quiet splash --
    TEXT HELP
        进入调试shell
    ENDTEXT
    
LABEL memtest
    MENU LABEL ^Memory Test
    KERNEL /isolinux/memtest
    
LABEL reboot
    MENU LABEL ^Reboot
    COM32 reboot.c32
EOF
    
    # GRUB菜单 (EFI)
    cat << 'EOF' > "${STAGING_DIR}/boot/grub/grub.cfg"
insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660
insmod ext2
insmod all_video
insmod font

if loadfont /boot/grub/fonts/unicode.pf2; then
    set gfxmode=auto
    insmod efi_gop
    insmod efi_uga
    insmod video_bochs
    insmod video_cirrus
    insmod gfxterm
    terminal_output gfxterm
fi

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray
set timeout=30
set default=0

menuentry "Install OpenWRT" {
    search --no-floppy --set=root --label OPENWRT_INSTALLER
    linux /live/vmlinuz boot=live components quiet splash --
    initrd /live/initrd
}

menuentry "Open Shell (Debug Mode)" {
    search --no-floppy --set=root --label OPENWRT_INSTALLER
    linux /live/vmlinuz boot=live components quiet splash --
    initrd /live/initrd
}

menuentry "Memory Test (memtest86+)" {
    search --no-floppy --set=root --label OPENWRT_INSTALLER
    linux16 /isolinux/memtest
}

menuentry "Reboot" {
    reboot
}
EOF
    
    # 复制GRUB配置到EFI目录
    cp "${STAGING_DIR}/boot/grub/grub.cfg" "${STAGING_DIR}/EFI/BOOT/"
    
    # 嵌入式GRUB配置
    cat << 'EOF' > "${WORKDIR}/tmp/grub-embed.cfg"
search --file --set=root /live/vmlinuz
if [ -f /boot/grub/grub.cfg ]; then
    configfile /boot/grub/grub.cfg
else
    configfile /EFI/BOOT/grub.cfg
fi
EOF
}

# 复制引导文件
copy_boot_files() {
    print_status "复制引导文件..."
    
    # BIOS文件
    cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/"
    cp /usr/lib/syslinux/modules/bios/*.c32 "${STAGING_DIR}/isolinux/"
    cp /usr/lib/ISOLINUX/isohdpfx.bin "${WORKDIR}/tmp/"
    
    # EFI文件
    cp -r /usr/lib/grub/x86_64-efi/* "${STAGING_DIR}/boot/grub/x86_64-efi/"
    
    # 生成EFI引导镜像
    print_status "生成EFI引导镜像..."
    
    # 32位EFI
    grub-mkstandalone -O i386-efi \
        --modules="part_gpt part_msdos fat iso9660 ext2" \
        --locales="" \
        --themes="" \
        --fonts="" \
        --output="${STAGING_DIR}/EFI/BOOT/BOOTIA32.EFI" \
        "boot/grub/grub.cfg=${WORKDIR}/tmp/grub-embed.cfg"
    
    # 64位EFI
    grub-mkstandalone -O x86_64-efi \
        --modules="part_gpt part_msdos fat iso9660 ext2" \
        --locales="" \
        --themes="" \
        --fonts="" \
        --output="${STAGING_DIR}/EFI/BOOT/BOOTx64.EFI" \
        "boot/grub/grub.cfg=${WORKDIR}/tmp/grub-embed.cfg"
    
    # 创建EFI引导磁盘镜像
    print_status "创建EFI磁盘镜像..."
    (
        cd "${STAGING_DIR}"
        dd if=/dev/zero of=efiboot.img bs=1M count=32
        mkfs.vfat -F 32 efiboot.img
        mmd -i efiboot.img ::/EFI ::/EFI/BOOT
        mcopy -i efiboot.img \
            EFI/BOOT/BOOTIA32.EFI \
            EFI/BOOT/BOOTx64.EFI \
            boot/grub/grub.cfg \
            ::/EFI/BOOT/
    )
}

# 创建ISO镜像
create_iso() {
    print_status "创建ISO镜像..."
    
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "OPENWRT_INSTALLER" \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/isolinux.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${WORKDIR}/tmp/isohdpfx.bin" \
        -eltorito-alt-boot \
        -e efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -output "${WORKDIR}/${ISO_NAME}" \
        "${STAGING_DIR}"
    
    # 使ISO可USB启动
    isohybrid --uefi "${WORKDIR}/${ISO_NAME}" 2>/dev/null || true
    
    print_success "ISO创建完成: ${WORKDIR}/${ISO_NAME}"
    print_info "文件大小: $(du -h "${WORKDIR}/${ISO_NAME}" | cut -f1)"
}

# 主函数
main() {
    echo "========================================"
    echo "    OpenWRT安装ISO构建工具"
    echo "========================================"
    echo ""
    
    check_dependencies
    setup_workspace
    bootstrap_debian
    customize_chroot
    copy_install_scripts
    prepare_boot_files
    create_boot_menus
    copy_boot_files
    create_iso
    
    echo ""
    print_status "构建完成！"
    echo ""
    echo "使用说明:"
    echo "1. 将 ${WORKDIR}/${ISO_NAME} 写入USB或刻录光盘"
    echo "2. 从该介质启动计算机"
    echo "3. 选择 'Install OpenWRT' 进入安装程序"
    echo "4. 按照提示选择磁盘并确认安装"
    echo ""
}

# 运行主函数
main "$@"
