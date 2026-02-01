#!/bin/bash
# scripts/build-live-iso.sh
# 构建最小化双引导Live ISO

set -e  # 遇到错误立即退出

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
}

# 检查依赖
check_dependencies() {
    info "检查依赖..."
    
    local missing_deps=()
    
    for dep in xorriso grub-mkimage mkfs.vfat wget; do
        if ! command -v $dep >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        error "缺少依赖: ${missing_deps[*]}"
        exit 1
    fi
    
    info "所有依赖已安装"
}

# 创建目录结构
setup_directories() {
    info "设置目录结构..."
    
    ISO_BUILD_DIR="${1:-iso_build}"
    
    rm -rf "$ISO_BUILD_DIR"
    mkdir -p "$ISO_BUILD_DIR"
    cd "$ISO_BUILD_DIR"
    
    mkdir -p boot/grub
    mkdir -p efi/boot
    mkdir -p kernel
    mkdir -p live/filesystem
    
    info "目录结构创建完成"
}

# 下载内核
download_kernel() {
    info "下载内核文件..."
    
    KERNEL_URL="https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/x86_64/boot/vmlinuz-lts"
    INITRD_URL="https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/x86_64/boot/initramfs-lts"
    
    # 下载内核
    if ! wget -q -O kernel/vmlinuz "$KERNEL_URL"; then
        error "下载内核失败"
        exit 1
    fi
    
    # 下载initrd
    if ! wget -q -O kernel/initrd.img "$INITRD_URL"; then
        error "下载initrd失败"
        exit 1
    fi
    
    info "内核文件下载完成:"
    echo "  vmlinuz: $(du -h kernel/vmlinuz | cut -f1)"
    echo "  initrd.img: $(du -h kernel/initrd.img | cut -f1)"
}

# 创建最小rootfs
create_rootfs() {
    info "创建根文件系统..."
    
    # 下载静态busybox
    if ! wget -q -O live/filesystem/busybox \
        "https://www.busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"; then
        warn "下载busybox失败，尝试本地查找"
        if command -v busybox >/dev/null 2>&1; then
            cp $(which busybox) live/filesystem/busybox
        else
            error "无法获取busybox"
            exit 1
        fi
    fi
    
    chmod +x live/filesystem/busybox
    
    # 创建init脚本
    cat > live/filesystem/init << 'EOF'
#!/bin/busybox sh

# 挂载必要的文件系统
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev

# 设置控制台
/bin/busybox echo ""
/bin/busybox echo "========================================"
/bin/busybox echo "  Minimal Live ISO"
/bin/busybox echo "  Successfully Booted!"
/bin/busybox echo "========================================"
/bin/busybox echo ""

# 设置PATH
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

# 启动shell
exec /bin/busybox sh
EOF
    
    chmod +x live/filesystem/init
    
    # 创建符号链接
    cd live/filesystem
    for cmd in sh ls cat echo mount ps pwd cd mkdir rmdir rm cp mv ln clear; do
        ln -sf busybox $cmd 2>/dev/null || true
    done
    cd ../..
    
    info "根文件系统创建完成"
}

# 创建GRUB配置
create_grub_config() {
    info "创建GRUB配置..."
    
    cat > boot/grub/grub.cfg << 'EOF'
# Minimal Live ISO - GRUB Configuration
set timeout=5
set default=0

# 加载必要模块
insmod iso9660
insmod linux
insmod normal

menuentry "Minimal Live Shell" {
    echo "Loading kernel..."
    linux /kernel/vmlinuz console=ttyS0 console=tty0 init=/init
    echo "Loading initrd..."
    initrd /kernel/initrd.img
}

menuentry "Boot from local disk" {
    echo "Booting from first hard disk..."
    set root=(hd1)
    chainloader +1
}
EOF
    
    # 复制到EFI目录
    mkdir -p efi/boot/grub
    cp boot/grub/grub.cfg efi/boot/grub/
    
    info "GRUB配置创建完成"
}

# 创建BIOS引导
create_bios_boot() {
    info "创建BIOS引导..."
    
    if [ -f /usr/lib/grub/i386-pc/boot.img ]; then
        cp /usr/lib/grub/i386-pc/boot.img boot/grub/
        info "BIOS引导镜像已复制"
    else
        warn "未找到boot.img，尝试生成..."
        grub-mkimage -p /boot/grub -O i386-pc -o boot/grub/core.img \
            biosdisk iso9660 multiboot normal linux
        cat /usr/lib/grub/i386-pc/cdboot.img boot/grub/core.img > boot/grub/boot.img
    fi
}

# 创建EFI引导
create_efi_boot() {
    info "创建EFI引导..."
    
    # 检查可用的EFI文件
    if [ -f /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed ]; then
        cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed efi/boot/bootx64.efi
    elif [ -f /usr/lib/grub/x86_64-efi/monolithic/grub.efi ]; then
        cp /usr/lib/grub/x86_64-efi/monolithic/grub.efi efi/boot/bootx64.efi
    else
        warn "未找到预编译的EFI文件，正在生成..."
        grub-mkimage -p /efi/boot -O x86_64-efi -o efi/boot/bootx64.efi \
            iso9660 fat ext2 linux normal boot
    fi
    
    info "EFI引导文件创建完成"
}

# 构建ISO
build_iso() {
    info "构建ISO镜像..."
    
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    ISO_NAME="minimal-live-${TIMESTAMP}.iso"
    
    # 使用单行命令避免解析问题
    xorriso -as mkisofs \
        -iso-level 3 \
        -volid "MINIMAL_LIVE" \
        -rock \
        -joliet \
        -b boot/grub/boot.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e efi/boot/bootx64.efi \
        -no-emul-boot \
        -o "../${ISO_NAME}" \
        .
    
    cd ..
    
    if [ -f "$ISO_NAME" ]; then
        info "ISO构建成功: ${ISO_NAME}"
        echo "  Size: $(du -h "$ISO_NAME" | cut -f1)"
        echo "  Type: $(file "$ISO_NAME")"
    else
        error "ISO构建失败"
        exit 1
    fi
}

# 验证ISO
verify_iso() {
    local iso_file="$1"
    
    info "验证ISO文件..."
    
    if [ ! -f "$iso_file" ]; then
        error "ISO文件不存在: $iso_file"
        return 1
    fi
    
    echo "=== ISO信息 ==="
    file "$iso_file"
    echo ""
    
    echo "=== 引导记录 ==="
    xorriso -indev "$iso_file" -toc 2>&1 | grep -i -E "(boot|eltorito|efi)" || true
    echo ""
    
    echo "=== 文件列表 ==="
    xorriso -indev "$iso_file" -find / -type f 2>&1 | grep -E "(vmlinuz|initrd|grub|efi)" | head -10 || true
}

# 主函数
main() {
    info "开始构建最小化Live ISO"
    
    # 检查依赖
    check_dependencies
    
    # 设置工作目录
    local build_dir="iso_build_$(date +%s)"
    setup_directories "$build_dir"
    
    # 执行构建步骤
    download_kernel
    create_rootfs
    create_grub_config
    create_bios_boot
    create_efi_boot
    
    # 构建ISO
    build_iso
    
    # 验证ISO
    local latest_iso=$(ls -t minimal-live-*.iso | head -1)
    verify_iso "$latest_iso"
    
    info "构建完成!"
    info "ISO文件: $latest_iso"
    info "可以使用以下命令测试:"
    echo "  qemu-system-x86_64 -cdrom $latest_iso -m 512 -serial stdio"
}

# 运行主函数
main "$@"
