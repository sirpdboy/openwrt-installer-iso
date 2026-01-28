#!/bin/bash
# 主构建脚本：构建支持BIOS/UEFI双引导的OpenWRT Alpine安装ISO

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
    
    return 0
}

# 清理临时文件
cleanup() {
    print_step "清理临时文件..."
    umount -qf /tmp/rootfs 2>/dev/null || true
    umount -qf /tmp/efi_mnt 2>/dev/null || true
    umount -qf /tmp/grub_mnt 2>/dev/null || true
    rm -rf /tmp/iso /tmp/rootfs /tmp/efi_mnt /tmp/grub_mnt /tmp/grub.img /tmp/efiboot.img /tmp/initramfs 2>/dev/null || true
}

# 准备ISO目录结构
prepare_iso_structure() {
    print_step "准备ISO目录结构..."
    
    # 清理旧的ISO目录
    rm -rf /tmp/iso
    mkdir -p /tmp/iso/{boot/grub,boot/isolinux,EFI/boot,images}
    
    # 复制BIOS引导文件
    cp /usr/share/syslinux/isolinux.bin /tmp/iso/boot/isolinux/
    cp /usr/share/syslinux/ldlinux.c32 /tmp/iso/boot/isolinux/
    cp /usr/share/syslinux/libutil.c32 /tmp/iso/boot/isolinux/
    cp /usr/share/syslinux/menu.c32 /tmp/iso/boot/isolinux/
    cp /usr/share/syslinux/libcom32.c32 /tmp/iso/boot/isolinux/
    cp /usr/share/syslinux/vesamenu.c32 /tmp/iso/boot/isolinux/ 2>/dev/null || true
    
    # 创建基本的引导文件
    cat > /tmp/iso/boot/isolinux/isolinux.cfg << 'EOF'
DEFAULT vesamenu.c32
PROMPT 0
TIMEOUT 50
MENU TITLE OpenWRT Installer
MENU BACKGROUND /boot/isolinux/splash.png

LABEL install
  MENU LABEL Install OpenWRT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200n8

LABEL bootlocal
  MENU LABEL Boot from local disk
  LOCALBOOT 0x80

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32
EOF
    
    # 如果vesamenu.c32不存在，使用简单的配置
    if [[ ! -f "/tmp/iso/boot/isolinux/vesamenu.c32" ]]; then
        cat > /tmp/iso/boot/isolinux/isolinux.cfg << 'EOF'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 50
MENU TITLE OpenWRT Installer

LABEL install
  MENU LABEL Install OpenWRT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200n8

LABEL bootlocal
  MENU LABEL Boot from local disk
  LOCALBOOT 0x80

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32
EOF
    fi
}

# 创建GRUB配置文件
create_grub_config() {
    print_step "创建GRUB配置文件..."
    
    # 创建GRUB目录
    mkdir -p /tmp/iso/boot/grub
    
    # 创建GRUB配置文件
    cat > /tmp/iso/boot/grub/grub.cfg << 'EOF'
set default=0
set timeout=5
set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue

insmod all_video
insmod gfxterm
insmod png
terminal_output gfxterm

menuentry "Install OpenWRT" {
    echo "Loading kernel..."
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8
    echo "Loading initrd..."
    initrd /boot/initrd.img
    echo "Booting..."
}

menuentry "Boot from Hard Disk" {
    echo "Booting from local disk..."
    exit
}
EOF
    
    # 创建UEFI GRUB配置
    cat > /tmp/iso/EFI/boot/grub.cfg << 'EOF'
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EOF
}

# 准备OpenWRT镜像
prepare_openwrt_image() {
    print_step "准备OpenWRT镜像..."
    
    local img_size=$(stat -c%s "${INPUT_IMG}")
    print_info "OpenWRT镜像大小: $((img_size/1024/1024)) MB"
    
    # 复制OpenWRT镜像到ISO目录
    cp "${INPUT_IMG}" /tmp/iso/images/openwrt.img
    
    # 创建镜像信息文件
    echo "OpenWRT Installation Image" > /tmp/iso/images/README.txt
    echo "Size: $((img_size/1024/1024)) MB" >> /tmp/iso/images/README.txt
    echo "Date: $(date)" >> /tmp/iso/images/README.txt
}

# 创建可引导内核和initrd
create_boot_files() {
    print_step "创建可引导文件..."
    
    # 尝试获取Alpine的内核
    local kernel_found=false
    
    # 查找内核文件
    for kernel in /boot/vmlinuz-* /boot/vmlinuz-lts /boot/vmlinuz-hardened /boot/vmlinuz; do
        if [[ -f "$kernel" ]]; then
            cp "$kernel" /tmp/iso/boot/vmlinuz
            print_info "使用内核: $(basename "$kernel")"
            kernel_found=true
            break
        fi
    done
    
    # 如果没找到内核，创建一个最小的内核占位文件
    if [[ "$kernel_found" = false ]]; then
        print_warn "未找到内核文件，创建占位文件"
        cat > /tmp/iso/boot/vmlinuz << 'EOF'
#!/bin/sh
echo "========================================"
echo "   OpenWRT Installer - Minimal Edition  "
echo "========================================"
echo ""
echo "This is a placeholder kernel."
echo "For production use, replace with a real Linux kernel."
echo ""
echo "Detected disks:"
lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null || echo "Could not list disks"
echo ""
exec /bin/sh
EOF
        chmod +x /tmp/iso/boot/vmlinuz
    fi
    
    # 创建initramfs
    print_info "创建initramfs..."
    
    # 创建init脚本
    mkdir -p /tmp/initramfs/{bin,dev,proc,sys,lib,usr/bin}
    
    # 创建init文件
    cat > /tmp/initramfs/init << 'EOF'
#!/bin/sh
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# 挂载必要的文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 创建必要的设备节点
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true
mknod /dev/zero c 1 5 2>/dev/null || true

# 显示欢迎信息
clear
echo "========================================"
echo "   OpenWRT Installer - Ready to Install "
echo "========================================"
echo ""
echo "Available disks:"
if command -v lsblk >/dev/null 2>&1; then
    lsblk -d -n -o NAME,SIZE,MODEL | while read line; do
        echo "  $line"
    done
else
    echo "  (list disks command not available)"
fi
echo ""
echo "The OpenWRT image is located at: /images/openwrt.img"
echo ""
echo "To install OpenWRT:"
echo "1. Identify your target disk (e.g., /dev/sda)"
echo "2. Run: dd if=/images/openwrt.img of=/dev/sdX bs=4M"
echo "3. Reboot the system"
echo ""
echo "Type 'exit' to reboot, or press Ctrl+D"
echo ""

# 启动shell
exec /bin/sh
EOF
    chmod +x /tmp/initramfs/init
    
    # 复制busybox（如果可用）
    if command -v busybox >/dev/null 2>&1; then
        cp $(which busybox) /tmp/initramfs/bin/busybox
        chmod +x /tmp/initramfs/bin/busybox
        # 创建符号链接
        for cmd in sh ls echo cat dd mount umount mknod clear; do
            ln -sf /bin/busybox /tmp/initramfs/bin/$cmd 2>/dev/null || true
        done
    fi
    
    # 打包initramfs
    (cd /tmp/initramfs && find . | cpio -H newc -o | gzip -9 > /tmp/iso/boot/initrd.img)
    
    print_info "initrd大小: $(stat -c%s /tmp/iso/boot/initrd.img) bytes"
}

# 创建EFI引导镜像
create_efi_boot() {
    print_step "创建EFI引导..."
    
    # 创建EFI目录
    mkdir -p /tmp/iso/EFI/boot
    
    # 复制EFI引导文件
    if [[ -f "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" ]]; then
        cp /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi /tmp/iso/EFI/boot/bootx64.efi
    elif [[ -f "/usr/share/grub/grubx64.efi" ]]; then
        cp /usr/share/grub/grubx64.efi /tmp/iso/EFI/boot/bootx64.efi
    elif command -v grub-mkimage >/dev/null 2>&1; then
        print_info "生成GRUB EFI可执行文件..."
        # 创建临时目录
        mkdir -p /tmp/grub_efi
        # 生成GRUB EFI
        grub-mkimage \
            -O x86_64-efi \
            -o /tmp/iso/EFI/boot/bootx64.efi \
            -p /boot/grub \
            fat iso9660 part_gpt part_msdos normal boot linux configfile loopback chain \
            efifwsetup efi_gop efi_uga ls search search_label search_fs_uuid search_fs_file \
            gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 \
            echo true probe terminal
    else
        print_warn "无法创建EFI引导文件，ISO将只支持BIOS引导"
    fi
    
    # 检查是否成功创建EFI文件
    if [[ -f "/tmp/iso/EFI/boot/bootx64.efi" ]]; then
        print_info "EFI引导文件创建成功"
    else
        print_warn "未创建EFI引导文件"
    fi
}

# 创建最终的ISO
create_final_iso() {
    print_step "创建最终的ISO..."
    
    local output_path="/output/${OUTPUT_ISO_FILENAME}"
    
    print_info "创建ISO文件到: ${output_path}"
    
    # 创建ISO，支持BIOS和UEFI双引导
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "${ISO_VOLUME}" \
        -eltorito-boot boot/isolinux/isolinux.bin \
        -eltorito-catalog boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
        -eltorito-alt-boot \
        -e EFI/boot/bootx64.efi \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -append_partition 2 0xef /tmp/iso/EFI/boot/bootx64.efi \
        -o "${output_path}" \
        /tmp/iso 2>&1 | while read line; do
            print_info "xorriso: $line"
        done
    
    # 检查ISO是否创建成功
    if [[ $? -eq 0 ]] && [[ -f "${output_path}" ]]; then
        local iso_size=$(du -h "${output_path}" | cut -f1)
        print_info "✅ ISO创建成功!"
        print_info "文件: ${output_path}"
        print_info "大小: ${iso_size}"
        
        # 验证ISO可引导性
        if file "${output_path}" | grep -q "bootable"; then
            print_info "✅ ISO是可引导的"
        else
            print_warn "⚠ ISO可能不可引导"
        fi
        
        # 显示ISO信息
        if command -v isoinfo >/dev/null 2>&1; then
            print_info "ISO结构信息:"
            isoinfo -f -i "${output_path}" 2>/dev/null | head -20 || true
        fi
        
        return 0
    else
        print_error "❌ ISO创建失败"
        
        # 尝试创建简单的ISO
        print_info "尝试创建简单的ISO..."
        xorriso -as mkisofs \
            -r -V "${ISO_VOLUME}" \
            -o "${output_path}" \
            /tmp/iso
            
        if [[ -f "${output_path}" ]]; then
            print_info "✅ 简单ISO创建成功（可能不支持引导）"
        else
            return 1
        fi
    fi
}

# 验证构建
verify_build() {
    print_step "验证构建..."
    
    local output_path="/output/${OUTPUT_ISO_FILENAME}"
    
    if [[ ! -f "${output_path}" ]]; then
        print_error "ISO文件未生成"
        return 1
    fi
    
    # 检查文件大小
    local iso_size=$(stat -c%s "${output_path}")
    if [[ $iso_size -lt 1048576 ]]; then  # 小于1MB
        print_warn "ISO文件大小异常: $((iso_size/1024)) KB"
    else
        print_info "ISO文件大小正常: $((iso_size/1024/1024)) MB"
    fi
    
    # 检查文件类型
    local file_type=$(file "${output_path}" 2>/dev/null || echo "unknown")
    print_info "文件类型: $file_type"
    
    return 0
}

# 主函数
main() {
    print_info "开始构建OpenWRT安装ISO..."
    print_info "========================================"
    
    # 设置陷阱，确保清理
    trap cleanup EXIT INT TERM
    
    # 检查环境
    if ! check_env; then
        exit 1
    fi
    
    # 清理旧文件
    cleanup
    
    # 执行构建步骤
    prepare_iso_structure
    create_grub_config
    prepare_openwrt_image
    create_boot_files
    create_efi_boot
    create_final_iso
    
    # 验证构建
    if verify_build; then
        print_info "========================================"
        print_info "🎉 构建完成！"
        print_info "ISO文件已生成: /output/${OUTPUT_ISO_FILENAME}"
        print_info "========================================"
    else
        print_error "❌ 构建验证失败"
        exit 1
    fi
}

# 运行主函数
main "$@"
