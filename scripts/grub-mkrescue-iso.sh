#!/bin/bash
# scripts/grub-mkrescue-iso.sh
# 使用grub-mkrescue构建可引导ISO

set -e

source "$(dirname "$0")/lib/utils.sh"

# 配置
BUILD_DIR="${BUILD_DIR:-$(pwd)/build_grub}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
ISO_PREFIX="grub-live"

prepare_grub_files() {
    print_step "准备GRUB文件"
    
    local iso_dir="$BUILD_DIR/iso"
    
    # 创建标准GRUB目录结构
    mkdir -p "$iso_dir/boot/grub"
    mkdir -p "$iso_dir/EFI/BOOT"
    mkdir -p "$iso_dir/kernel"
    
    # 下载内核
    wget -q -O "$iso_dir/kernel/vmlinuz" \
        "https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/x86_64/boot/vmlinuz-lts"
    wget -q -O "$iso_dir/kernel/initrd.img" \
        "https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/x86_64/boot/initramfs-lts"
    
    # 创建GRUB配置文件 (关键！)
    cat > "$iso_dir/boot/grub/grub.cfg" << 'EOF'
# Minimal Live ISO - GRUB Configuration
set timeout=5
set default=0

# 对于UEFI
if [ "${grub_platform}" = "efi" ]; then
    # UEFI-specific settings
    insmod efi_gop
    insmod efi_uga
    insmod font
    if loadfont /boot/grub/fonts/unicode.pf2; then
        insmod gfxterm
        set gfxmode=auto
        set gfxpayload=keep
        terminal_output gfxterm
    fi
fi

# 对于BIOS/Legacy
insmod iso9660
insmod linux
insmod normal

menuentry "Minimal Live Shell (BIOS/UEFI)" {
    # 显示信息
    echo "Loading Linux kernel..."
    
    # 内核参数 - 关键！
    linux /kernel/vmlinuz console=tty0 console=ttyS0,115200n8 quiet
    echo "Loading initial ramdisk..."
    initrd /kernel/initrd.img
}

menuentry "Boot from local disk" {
    set root=(hd1)
    chainloader +1
}
EOF
    
    # 复制到EFI目录
    cp "$iso_dir/boot/grub/grub.cfg" "$iso_dir/EFI/BOOT/"
    
    # 创建最小的init脚本（可选）
    mkdir -p "$iso_dir/live"
    cat > "$iso_dir/live/init.sh" << 'EOF'
#!/bin/sh
echo "========================================"
echo "  Live ISO Booted Successfully!"
echo "========================================"
exec /bin/sh
EOF
    chmod +x "$iso_dir/live/init.sh"
    
    log_info "GRUB文件准备完成"
}

build_with_grub_mkrescue() {
    print_step "使用grub-mkrescue构建ISO"
    
    local iso_dir="$BUILD_DIR/iso"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local iso_name="${ISO_PREFIX}-${timestamp}.iso"
    local iso_path="$OUTPUT_DIR/$iso_name"
    
    mkdir -p "$OUTPUT_DIR"
    
    # 关键：使用grub-mkrescue
    log_info "运行grub-mkrescue..."
    
    grub-mkrescue \
        --output="$iso_path" \
        --modules="iso9660 linux normal boot" \
        --locales="" \
        --themes="" \
        --fonts="" \
        "$iso_dir" 2>&1 | grep -E "(Creating|Writing|done)" || true
    
    if [ -f "$iso_path" ]; then
        log_info "ISO构建成功: $iso_name"
        echo "  大小: $(du -h "$iso_path" | cut -f1)"
        echo "  路径: $iso_path"
    else
        log_error "ISO构建失败"
        return 1
    fi
    
    # 验证
    verify_grub_iso "$iso_path"
}

verify_grub_iso() {
    local iso_file="$1"
    
    print_step "验证GRUB ISO"
    
    echo "=== 基本检查 ==="
    file "$iso_file"
    echo ""
    
    echo "=== 引导信息 ==="
    # 检查是否为混合ISO
    if which isoinfo >/dev/null 2>&1; then
        isoinfo -d -i "$iso_file" 2>&1 | grep -i "boot" || true
    fi
    
    # 检查引导扇区
    echo ""
    echo "=== 引导扇区分析 ==="
    dd if="$iso_file" bs=1 count=512 2>/dev/null | file - || true
    
    log_info "验证完成"
}

main() {
    print_header "使用grub-mkrescue构建可引导ISO"
    
    # 清理
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    
    # 准备文件
    prepare_grub_files
    
    # 构建ISO
    build_with_grub_mkrescue
    
    print_success "构建完成！"
    echo "ISO文件: $OUTPUT_DIR/${ISO_PREFIX}-*.iso"
    echo ""
    echo "测试命令:"
    echo "  qemu-system-x86_64 -cdrom \"$OUTPUT_DIR/${ISO_PREFIX}-*.iso\" -m 512"
}

main "$@"
