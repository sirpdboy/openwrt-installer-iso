#!/bin/bash
# 主构建脚本：构建支持BIOS/UEFI双引导的OpenWRT Alpine安装ISO
# 参数：无（通过环境变量传递）

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
print_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
print_step() { echo -e "${BLUE}[STEP]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# 环境变量检查
check_env() {
    print_step "检查环境变量..."
    
    # 必需的环境变量
    : "${INPUT_IMG:?环境变量 INPUT_IMG 未设置}"
    : "${OUTPUT_ISO_FILENAME:?环境变量 OUTPUT_ISO_FILENAME 未设置}"
    
    # 可选环境变量，设置默认值
    ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
    ISO_LABEL="${ISO_LABEL:-OPENWRT_INSTALL}"
    ISO_VOLUME="${ISO_VOLUME:-OpenWRT_Installer}"
    
    print_info "Alpine版本: ${ALPINE_VERSION}"
    print_info "输入IMG文件: ${INPUT_IMG}"
    print_info "输出ISO文件名: ${OUTPUT_ISO_FILENAME}"
    print_info "ISO卷标: ${ISO_LABEL}"
    print_info "ISO卷名: ${ISO_VOLUME}"
    
    # 检查输入文件是否存在
    if [[ ! -f "${INPUT_IMG}" ]]; then
        print_error "输入文件不存在: ${INPUT_IMG}"
        return 1
    fi
    
    # 检查文件类型
    if ! file "${INPUT_IMG}" | grep -q "DOS/MBR boot sector\|Linux.*filesystem data"; then
        print_warn "输入文件可能不是有效的IMG文件"
    fi
}

# 清理临时文件
cleanup() {
    print_step "清理临时文件..."
    umount -qf /tmp/rootfs/boot 2>/dev/null || true
    umount -qf /tmp/rootfs 2>/dev/null || true
    umount -qf /tmp/efi 2>/dev/null || true
    rm -rf /tmp/iso /tmp/rootfs /tmp/efi /tmp/bios /tmp/grub.img /tmp/efiboot.img
}

# 准备ISO目录结构
prepare_iso_structure() {
    print_step "准备ISO目录结构..."
    
    # 创建ISO目录结构
    mkdir -p /tmp/iso/{boot/grub,boot/isolinux,EFI/boot,images}
    
    # 复制必要的文件
    cp /usr/share/syslinux/isolinux.bin /tmp/iso/boot/isolinux/
    cp /usr/share/syslinux/ldlinux.c32 /tmp/iso/boot/isolinux/
    cp /usr/share/syslinux/libutil.c32 /tmp/iso/boot/isolinux/
    cp /usr/share/syslinux/menu.c32 /tmp/iso/boot/isolinux/
    cp /usr/share/syslinux/libcom32.c32 /tmp/iso/boot/isolinux/
}

# 创建GRUB配置文件
create_grub_config() {
    print_step "创建GRUB配置文件..."
    
    # 创建GRUB配置文件
    cat > /tmp/iso/boot/grub/grub.cfg << 'EOF'
set default=0
set timeout=5
set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue

menuentry "Install OpenWRT to Disk (UEFI Mode)" {
    echo "Loading OpenWRT installer..."
    linux /boot/vmlinuz root=/dev/ram0 console=tty0 console=ttyS0,115200n8
    initrd /boot/initramfs
}

menuentry "Install OpenWRT to Disk (Legacy BIOS Mode)" {
    echo "Loading OpenWRT installer..."
    linux /boot/vmlinuz root=/dev/ram0 console=tty0 console=ttyS0,115200n8
    initrd /boot/initramfs
}

menuentry "Boot from Hard Disk (UEFI)" {
    echo "Booting from local disk..."
    exit 1
}

menuentry "Boot from Hard Disk (BIOS)" {
    echo "Booting from local disk..."
    exit 2
}
EOF

    # 创建ISOLINUX配置文件
    cat > /tmp/iso/boot/isolinux/isolinux.cfg << 'EOF'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 50
ONTIMEOUT install

MENU TITLE OpenWRT Installer
MENU BACKGROUND /boot/isolinux/splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

LABEL install
    MENU LABEL Install OpenWRT to Disk
    KERNEL /boot/vmlinuz
    APPEND root=/dev/ram0 console=tty0 console=ttyS0,115200n8 initrd=/boot/initramfs

LABEL bootlocal
    MENU LABEL Boot from local disk
    LOCALBOOT 0x80

LABEL reboot
    MENU LABEL Reboot
    COM32 reboot.c32
EOF
}

# 准备OpenWRT镜像
prepare_openwrt_image() {
    print_step "准备OpenWRT镜像..."
    
    local img_size=$(stat -c%s "${INPUT_IMG}")
    print_info "OpenWRT镜像大小: $((img_size/1024/1024)) MB"
    
    # 复制OpenWRT镜像到ISO目录
    cp "${INPUT_IMG}" /tmp/iso/images/openwrt.img
    
    # 如果需要，可以在这里压缩镜像
    if [[ "${COMPRESS_IMG:-false}" == "true" ]]; then
        print_info "压缩OpenWRT镜像..."
        gzip -9 /tmp/iso/images/openwrt.img
        mv /tmp/iso/images/openwrt.img.gz /tmp/iso/images/openwrt.img.gz
    fi
}

# 创建可引导文件系统
create_bootable_filesystem() {
    print_step "创建可引导文件系统..."
    
    # 创建initramfs（最小系统）
    cat > /tmp/initramfs.list << 'EOF'
# 最小initramfs内容
dir /dev 0755 0 0
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /mnt 0755 0 0
dir /tmp 0755 0 0
dir /root 0700 0 0

# 设备节点
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/zero 0666 0 0 c 1 5
nod /dev/tty 0666 0 0 c 5 0
nod /dev/tty0 0600 0 0 c 4 0
nod /dev/tty1 0600 0 0 c 4 1
nod /dev/ram0 0600 0 0 b 1 0

# 基本文件
file /init /usr/local/include/init.sh 0755 0 0
file /sbin/init /usr/local/include/init.sh 0755 0 0
EOF
    
    # 使用Alpine的mkinitfs创建initramfs（如果有的话）
    if command -v mkinitfs &>/dev/null; then
        print_info "使用mkinitfs创建initramfs..."
        mkinitfs -o /tmp/iso/boot/initramfs
    else
        print_info "使用busybox创建initramfs..."
        # 创建简单的initramfs
        (cd /tmp && find . -print0 | cpio -0 -H newc -o | gzip -9 > /tmp/iso/boot/initramfs)
    fi
    
    # 复制内核（使用Alpine的内核）
    if [[ -f "/boot/vmlinuz-lts" ]]; then
        cp /boot/vmlinuz-lts /tmp/iso/boot/vmlinuz
    elif [[ -f "/boot/vmlinuz-hardened" ]]; then
        cp /boot/vmlinuz-hardened /tmp/iso/boot/vmlinuz
    elif [[ -f "/boot/vmlinuz" ]]; then
        cp /boot/vmlinuz /tmp/iso/boot/vmlinuz
    else
        # 下载Alpine内核
        print_warn "未找到内核，下载Alpine内核..."
        local kernel_url="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION%.*}/releases/x86_64/alpine-mini-${ALPINE_VERSION}-x86_64.iso"
        wget -q -O /tmp/alpine-mini.iso "${kernel_url}"
        7z e -o/tmp /tmp/alpine-mini.iso boot/vmlinuz-lts 2>/dev/null || true
        if [[ -f "/tmp/vmlinuz-lts" ]]; then
            cp /tmp/vmlinuz-lts /tmp/iso/boot/vmlinuz
        else
            print_error "无法获取内核文件"
            return 1
        fi
    fi
}

# 创建EFI引导镜像
create_efi_boot_image() {
    print_step "创建EFI引导镜像..."
    
    # 创建EFI分区镜像
    dd if=/dev/zero of=/tmp/efiboot.img bs=1M count=10
    mkfs.vfat -F 32 /tmp/efiboot.img
    
    # 挂载并准备EFI分区
    mkdir -p /tmp/efi_mnt
    mount -o loop /tmp/efiboot.img /tmp/efi_mnt
    mkdir -p /tmp/efi_mnt/EFI/BOOT
    
    # 复制EFI引导文件
    if [[ -f "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" ]]; then
        cp /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi /tmp/efi_mnt/EFI/BOOT/bootx64.efi
    elif [[ -f "/usr/share/grub/grubx64.efi" ]]; then
        cp /usr/share/grub/grubx64.efi /tmp/efi_mnt/EFI/BOOT/bootx64.efi
    else
        # 生成GRUB EFI可执行文件
        print_info "生成GRUB EFI可执行文件..."
        grub-mkimage \
            -O x86_64-efi \
            -o /tmp/efi_mnt/EFI/BOOT/bootx64.efi \
            -p /boot/grub \
            fat iso9660 part_gpt part_msdos normal boot linux configfile loopback chain \
            efifwsetup efi_gop efi_uga ls search search_label search_fs_uuid search_fs_file \
            gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 \
            echo true probe terminal
    fi
    
    # 复制GRUB配置文件
    mkdir -p /tmp/efi_mnt/boot/grub
    cp /tmp/iso/boot/grub/grub.cfg /tmp/efi_mnt/boot/grub/
    
    # 卸载
    umount /tmp/efi_mnt
    rmdir /tmp/efi_mnt
    
    # 移动EFI引导镜像到ISO目录
    mv /tmp/efiboot.img /tmp/iso/EFI/boot/efiboot.img
}

# 创建BIOS引导镜像
create_bios_boot_image() {
    print_step "创建BIOS引导镜像..."
    
    # 创建GRUB BIOS引导镜像
    dd if=/dev/zero of=/tmp/grub.img bs=1M count=2
    mkfs.ext2 -F /tmp/grub.img
    
    # 挂载并准备GRUB
    mkdir -p /tmp/grub_mnt
    mount -o loop /tmp/grub.img /tmp/grub_mnt
    mkdir -p /tmp/grub_mnt/boot/grub
    
    # 复制GRUB模块
    cp -r /usr/lib/grub/i386-pc/* /tmp/grub_mnt/boot/grub/ 2>/dev/null || true
    
    # 创建GRUB core.img
    grub-mkimage \
        -O i386-pc \
        -o /tmp/grub_mnt/boot/grub/core.img \
        -p /boot/grub \
        biosdisk iso9660 part_msdos ext2
    
    # 安装GRUB到镜像
    echo "(hd0) /tmp/grub.img" > /tmp/device.map
    grub-bios-setup \
        --device-map=/tmp/device.map \
        --directory=/tmp/grub_mnt/boot/grub \
        --boot-image=boot/grub/core.img \
        /tmp/grub.img
    
    # 卸载
    umount /tmp/grub_mnt
    rmdir /tmp/grub_mnt
    
    # 移动GRUB引导镜像到ISO目录
    mv /tmp/grub.img /tmp/iso/boot/grub/grub.img
}

# 创建最终的ISO
create_final_iso() {
    print_step "创建最终的ISO..."
    
    local output_path="/output/${OUTPUT_ISO_FILENAME}"
    
    # 使用xorriso创建支持BIOS/UEFI双引导的ISO
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "${ISO_VOLUME}" \
        -eltorito-boot boot/isolinux/isolinux.bin \
        -eltorito-catalog boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot \
        -append_partition 2 0xef /tmp/iso/EFI/boot/efiboot.img \
        -o "${output_path}" \
        /tmp/iso
    
    # 检查ISO是否创建成功
    if [[ $? -eq 0 ]] && [[ -f "${output_path}" ]]; then
        local iso_size=$(du -h "${output_path}" | cut -f1)
        print_info "✓ ISO创建成功!"
        print_info "文件: ${output_path}"
        print_info "大小: ${iso_size}"
        
        # 显示ISO信息
        if command -v isoinfo >/dev/null 2>&1; then
            print_info "ISO详细信息:"
            isoinfo -d -i "${output_path}" | grep -E "Volume id|Volume size|Bootable" || true
        fi
        
        # 验证ISO可引导性
        if file "${output_path}" | grep -q "bootable"; then
            print_info "✓ ISO是可引导的"
        else
            print_warn "⚠ ISO可能不可引导"
        fi
        
        return 0
    else
        print_error "ISO创建失败"
        return 1
    fi
}

# 主函数
main() {
    print_info "开始构建OpenWRT安装ISO..."
    
    # 设置陷阱，确保清理
    trap cleanup EXIT INT TERM
    
    # 检查环境
    check_env || exit 1
    
    # 清理旧文件
    cleanup
    
    # 执行构建步骤
    prepare_iso_structure
    create_grub_config
    prepare_openwrt_image
    create_bootable_filesystem
    create_efi_boot_image
    create_bios_boot_image
    create_final_iso
    
    print_info "构建完成！"
}

# 运行主函数
main "$@"
