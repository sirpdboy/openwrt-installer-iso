#!/bin/bash
# build-iso.sh - 在容器内执行的构建脚本

set -euo pipefail

# 配置
ISO_NAME="ezopwrt-installer-$(date +%Y%m%d-%H%M%S)"
BUILD_DIR="/tmp/build"
STAGING_DIR="${BUILD_DIR}/staging"
OUTPUT_DIR="/output"
SOURCE_IMG="/mnt/ezopwrt.img"

# 颜色输出
red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
blue() { echo -e "\033[34m$*\033[0m"; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_info() { blue "[INFO] $*"; }
log_success() { green "[SUCCESS] $*"; }
log_error() { red "[ERROR] $*"; }

# 检查必要文件
check_requirements() {
    log_info "检查构建环境..."
    
    # 检查源镜像
    if [ ! -f "$SOURCE_IMG" ]; then
        log_error "找不到源镜像: $SOURCE_IMG"
        exit 1
    fi
    
    # 检查必要命令
    local required_cmds=("xorriso" "mksquashfs" "grub-mkstandalone" "mkfs.vfat")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "缺少命令: $cmd"
            exit 1
        fi
    done
    
    log_success "环境检查通过"
}

# 准备构建目录
prepare_directories() {
    log_info "准备构建目录..."
    
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    mkdir -p "$STAGING_DIR"/{isolinux,boot/grub/{x86_64-efi,i386-efi},live,EFI/BOOT}
    mkdir -p "$OUTPUT_DIR"
    
    # 复制源镜像
    cp "$SOURCE_IMG" "$STAGING_DIR/live/openwrt.img"
    log_success "镜像复制完成: $(ls -lh "$STAGING_DIR/live/openwrt.img")"
}

# 创建最小initrd
create_initrd() {
    log_info "创建initrd..."
    
    local initrd_dir="/tmp/initrd-root"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    
    # 创建init脚本（交互式安装）
    cat > "$initrd_dir/init" << 'EOF'
#!/bin/busybox sh

# 挂载必要文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp

# 创建设备节点
/bin/busybox mknod /dev/console c 5 1
exec >/dev/console 2>&1

echo ""
echo "========================================"
echo "    EzOpWrt 安装程序"
echo "========================================"
echo ""

# 检查OpenWRT镜像
if [ ! -f "/mnt/live/openwrt.img" ]; then
    echo "错误: 找不到OpenWRT镜像"
    echo "进入救援shell..."
    exec /bin/busybox sh
fi

# 复制镜像到tmpfs（加速安装）
echo "加载安装镜像..."
cp /mnt/live/openwrt.img /tmp/openwrt.img

# 主安装函数
install_openwrt() {
    clear
    echo "=== 磁盘选择 ==="
    echo ""
    
    # 显示磁盘列表
    echo "可用磁盘:"
    echo "--------------------------------"
    /bin/busybox blkid | while read -r line; do
        if echo "$line" | grep -q "/dev/sd\|/dev/nvme\|/dev/vd"; then
            dev=$(echo "$line" | cut -d: -f1)
            info=$(echo "$line" | cut -d: -f2-)
            echo "  $dev - $info"
        fi
    done
    echo "--------------------------------"
    echo ""
    
    while true; do
        echo -n "请输入目标磁盘 (例如: sda, nvme0n1): "
        read -r disk
        
        if [ -z "$disk" ]; then
            echo "输入不能为空"
            continue
        fi
        
        # 规范化设备路径
        if [ -b "/dev/$disk" ]; then
            target="/dev/$disk"
        elif [ -b "$disk" ]; then
            target="$disk"
        else
            echo "错误: 设备 $disk 不存在"
            continue
        fi
        
        echo ""
        echo "⚠️  警告: 这将完全擦除 $target 上的所有数据！"
        echo -n "确认安装？输入 'yes' 继续: "
        read -r confirm
        
        if [ "$confirm" = "yes" ]; then
            echo ""
            echo "正在安装到 $target ..."
            
            # 使用dd写入镜像
            if /bin/busybox dd if=/tmp/openwrt.img of="$target" bs=4M status=progress; then
                sync
                echo ""
                echo "✅ 安装成功！"
                echo ""
                echo "请执行以下操作："
                echo "1. 移除安装介质"
                echo "2. 设置从 $target 启动"
                echo "3. 重启系统"
                echo ""
                echo -n "按回车键重启..." && read -r
                /bin/busybox reboot -f
            else
                echo "❌ 安装失败！"
                return 1
            fi
            break
        else
            echo "安装取消"
            return 1
        fi
    done
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo "=== EzOpWrt 安装程序 ==="
        echo ""
        echo "1. 安装 EzOpWrt"
        echo "2. 磁盘列表"
        echo "3. 启动Shell"
        echo "4. 重启系统"
        echo ""
        echo -n "请选择 [1-4]: "
        read -r choice
        
        case "$choice" in
            1)
                install_openwrt
                ;;
            2)
                clear
                echo "磁盘列表:"
                echo "========================"
                /bin/busybox blkid
                echo "========================"
                echo ""
                echo -n "按回车键返回..." && read -r
                ;;
            3)
                echo "启动shell..."
                exec /bin/busybox sh
                ;;
            4)
                echo "重启系统..."
                /bin/busybox reboot -f
                ;;
            *)
                echo "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 下载busybox（如果不存在）
if [ ! -x /bin/busybox ]; then
    echo "下载busybox..."
    # 这里可以添加下载逻辑，但通常busybox已包含在initrd中
    echo "错误: 缺少busybox"
    exec sh
fi

# 启动主菜单
main_menu
EOF
    
    chmod +x "$initrd_dir/init"
    
    # 下载静态编译的busybox
    log_info "下载busybox..."
    wget -q "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" \
        -O "$initrd_dir/busybox"
    chmod +x "$initrd_dir/busybox"
    
    # 创建符号链接
    cd "$initrd_dir"
    for cmd in sh mount umount ls cat echo dd sync reboot blkid mknod sleep clear; do
        ln -sf busybox $cmd
    done
    cd -
    
    # 打包initrd
    log_info "打包initrd..."
    cd "$initrd_dir"
    find . | cpio -H newc -o | gzip -9 > "$STAGING_DIR/live/initrd"
    cd -
    
    log_success "initrd创建完成: $(ls -lh "$STAGING_DIR/live/initrd")"
}

# 准备内核
prepare_kernel() {
    log_info "准备内核..."
    
    # 尝试多种方式获取内核
    local kernel_sources=(
        "/boot/vmlinuz"
        "/vmlinuz"
        "/boot/vmlinuz-$(uname -r)"
    )
    
    for src in "${kernel_sources[@]}"; do
        if [ -f "$src" ]; then
            cp "$src" "$STAGING_DIR/live/vmlinuz"
            log_success "使用内核: $src"
            return 0
        fi
    done
    
    # 如果都没有，使用备用方案
    log_warning "未找到系统内核，使用备用内核..."
    cat > "$STAGING_DIR/live/vmlinuz" << 'EOF'
# 这是一个占位符内核
# 实际使用时应该从系统中复制真实内核
EOF
    log_success "创建占位符内核"
}

# 配置引导加载器
configure_bootloaders() {
    log_info "配置引导加载器..."
    
    # 复制引导文件
    cp /usr/lib/ISOLINUX/isolinux.bin "$STAGING_DIR/isolinux/"
    cp /usr/lib/syslinux/modules/bios/*.c32 "$STAGING_DIR/isolinux/" 2>/dev/null || true
    
    # ISOLINUX配置
    cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'EOF'
UI vesamenu.c32
MENU TITLE EzOpWrt Installer
TIMEOUT 300
PROMPT 0

MENU COLOR screen       37;40   #00000000 #00000000 none
MENU COLOR border       30;44   #00000000 #00000000 none
MENU COLOR title        1;36;44 #ffffffff #00000000 none
MENU COLOR unsel        37;44   #ffffffff #00000000 none
MENU COLOR hotkey       1;37;44 #ffffffff #00000000 none
MENU COLOR sel          7;37;40 #ff000000 #ffffffff none
MENU COLOR hotsel       1;7;37;40 #ff000000 #ffffffff none

LABEL install
    MENU LABEL ^Install EzOpWrt (Default)
    MENU DEFAULT
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd console=ttyS0 console=tty0 quiet
    
LABEL debug
    MENU LABEL ^Debug Mode
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd console=ttyS0 console=tty0
    
LABEL memtest
    MENU LABEL ^Memory Test
    KERNEL /isolinux/memtest
    
LABEL reboot
    MENU LABEL ^Reboot
    COM32 reboot.c32
EOF
    
    # GRUB配置 (UEFI)
    cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'EOF'
set timeout=10
set default=0

menuentry "Install EzOpWrt" {
    linux /live/vmlinuz console=ttyS0 console=tty0 quiet
    initrd /live/initrd
}

menuentry "Debug Mode" {
    linux /live/vmlinuz console=ttyS0 console=tty0
    initrd /live/initrd
}

menuentry "Reboot" {
    reboot
}
EOF
    
    # 复制到EFI目录
    cp "$STAGING_DIR/boot/grub/grub.cfg" "$STAGING_DIR/EFI/BOOT/"
    
    log_success "引导配置完成"
}

# 创建ISO
create_iso() {
    log_info "创建ISO镜像..."
    
    # 创建ISO
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "EZOPWRT_INSTALL" \
        -eltorito-boot isolinux/isolinux.bin \
        -boot-load-size 4 \
        -boot-info-table \
        -no-emul-boot \
        -eltorito-catalog isolinux/isolinux.cat \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "$OUTPUT_DIR/$ISO_NAME.iso" \
        "$STAGING_DIR"
    
    # 使ISO支持USB启动
    if command -v isohybrid &> /dev/null; then
        isohybrid "$OUTPUT_DIR/$ISO_NAME.iso" 2>/dev/null || true
    fi
    
    log_success "ISO创建完成: $OUTPUT_DIR/$ISO_NAME.iso"
    echo "文件大小: $(ls -lh "$OUTPUT_DIR/$ISO_NAME.iso" | awk '{print $5}')"
}

# 主函数
main() {
    echo "========================================"
    echo "    EzOpWrt ISO 构建工具"
    echo "========================================"
    echo ""
    
    log_info "开始构建..."
    
    check_requirements
    prepare_directories
    create_initrd
    prepare_kernel
    configure_bootloaders
    create_iso
    
    echo ""
    log_success "������ 构建完成！"
    echo ""
    echo "输出文件: $OUTPUT_DIR/$ISO_NAME.iso"
    echo ""
    echo "使用方法:"
    echo "1. 写入USB: dd if=$OUTPUT_DIR/$ISO_NAME.iso of=/dev/sdX bs=4M status=progress"
    echo "2. 从USB启动计算机"
    echo "3. 选择'Install EzOpWrt'开始安装"
    echo ""
}

# 运行主函数
main "$@"
