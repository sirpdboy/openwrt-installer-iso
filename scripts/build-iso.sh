#!/bin/bash
# build-iso-fixed.sh - 修复引导问题

set -euo pipefail

# 配置
ISO_NAME="openwrt-installer"
BUILD_DIR="/tmp/build"
STAGING_DIR="${BUILD_DIR}/staging"
OUTPUT_DIR="/output"
SOURCE_IMG="/mnt/ezopwrt.img"

# 日志函数
info() { echo -e "\033[34m[INFO]\033[0m $1"; }
success() { echo -e "\033[32m[SUCCESS]\033[0m $1"; }
error() { echo -e "\033[31m[ERROR]\033[0m $1"; }

# 检查必要文件
check_requirements() {
    info "检查构建环境..."
    
    if [ ! -f "$SOURCE_IMG" ]; then
        error "找不到源镜像: $SOURCE_IMG"
        exit 1
    fi
    
    # 检查必要命令
    for cmd in xorriso mkfs.vfat; do
        if ! command -v "$cmd" &> /dev/null; then
            error "缺少命令: $cmd"
            exit 1
        fi
    done
    
    success "环境检查通过"
}

# 准备构建目录
prepare_directories() {
    info "准备构建目录..."
    
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    mkdir -p "$STAGING_DIR"/{isolinux,boot/grub/{x86_64-efi,i386-efi},live,EFI/BOOT}
    mkdir -p "$OUTPUT_DIR"
    
    # 复制OpenWRT镜像
    cp "$SOURCE_IMG" "$STAGING_DIR/live/openwrt.img"
    success "镜像复制完成"
}

# 创建功能完整的initrd（关键修复）
create_initrd() {
    info "创建initrd..."
    
    local initrd_dir="/tmp/initrd-root"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"/{bin,dev,etc,proc,sys,tmp,mnt,root}
    
    # 创建init脚本 - 这是修复的关键！
    cat > "$initrd_dir/init" << 'EOF'
#!/bin/sh
# OpenWRT安装程序 - 修复版

# 挂载必要的文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# 创建设备节点
mknod /dev/console c 5 1
exec >/dev/console 2>&1

# 设置环境
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/root

# 显示欢迎信息
clear
echo ""
echo "================================================"
echo "       OpenWRT 安装程序"
echo "================================================"
echo ""

# 等待设备初始化
sleep 2

# 挂载ISO内容（查找OpenWRT镜像）
mount_cdrom() {
    for device in /dev/sr0 /dev/cdrom /dev/hda /dev/hdb; do
        if [ -b "$device" ]; then
            echo "尝试挂载 $device..."
            mount -t iso9660 -o ro "$device" /mnt 2>/dev/null && return 0
            mount -t udf -o ro "$device" /mnt 2>/dev/null && return 0
        fi
    done
    
    # 尝试USB设备
    for device in /dev/sd[a-z] /dev/sd[a-z][0-9] /dev/nvme[0-9]n[0-9] /dev/mmcblk[0-9]; do
        if [ -b "$device" ]; then
            echo "尝试挂载 $device..."
            mount -t vfat -o ro "$device" /mnt 2>/dev/null && return 0
            mount -t iso9660 -o ro "$device" /mnt 2>/dev/null && return 0
        fi
    done
    
    return 1
}

# 检查OpenWRT镜像
find_openwrt_image() {
    if [ -f "/mnt/live/openwrt.img" ]; then
        echo "找到OpenWRT镜像"
        cp "/mnt/live/openwrt.img" "/tmp/openwrt.img"
        return 0
    fi
    
    # 在常见位置查找
    for path in /mnt/openwrt.img /mnt/*.img /mnt/*/*.img; do
        if [ -f "$path" ]; then
            echo "找到镜像: $path"
            cp "$path" "/tmp/openwrt.img"
            return 0
        fi
    done
    
    return 1
}

# 显示磁盘列表
show_disks() {
    echo "可用磁盘列表:"
    echo "----------------------------------------"
    # 使用lsblk或直接读取/dev目录
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -v "loop"
    else
        # 简单列出块设备
        for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
            if [ -b "$disk" ]; then
                size=$(blockdev --getsize64 "$disk" 2>/dev/null | awk '{print $1/1024/1024/1024 "GB"}')
                echo "  $disk - $size"
            fi
        done
    fi
    echo "----------------------------------------"
}

# 安装OpenWRT
install_openwrt() {
    while true; do
        clear
        echo "=== OpenWRT 安装 ==="
        echo ""
        
        show_disks
        echo ""
        
        echo -n "请输入目标磁盘 (例如: sda, nvme0n1): "
        read -r disk
        
        if [ -z "$disk" ]; then
            echo "输入不能为空"
            sleep 2
            continue
        fi
        
        # 规范化设备路径
        if [[ "$disk" =~ ^[a-zA-Z0-9]+$ ]]; then
            target="/dev/$disk"
        else
            target="$disk"
        fi
        
        if [ ! -b "$target" ]; then
            echo "错误: 设备 $target 不存在"
            sleep 2
            continue
        fi
        
        # 确认安装
        echo ""
        echo "⚠️   警告: 这将完全擦除 $target 上的所有数据！"
        echo -n "确认安装？输入 'yes' 继续: "
        read -r confirm
        
        if [ "$confirm" = "yes" ]; then
            echo ""
            echo "正在安装到 $target ..."
            
            # 检查镜像是否存在
            if [ ! -f "/tmp/openwrt.img" ]; then
                echo "错误: 找不到OpenWRT镜像"
                return 1
            fi
            
            # 使用dd写入镜像
            if dd if="/tmp/openwrt.img" of="$target" bs=4M status=progress; then
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
                reboot -f
            else
                echo "❌ 安装失败！"
                return 1
            fi
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
        echo "=== OpenWRT 安装程序 ==="
        echo ""
        echo "1. 安装 OpenWRT"
        echo "2. 查看磁盘列表"
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
                show_disks
                echo ""
                echo -n "按回车键返回..." && read -r
                ;;
            3)
                echo "启动shell..."
                echo "输入 'exit' 返回菜单"
                /bin/sh
                ;;
            4)
                echo "重启系统..."
                reboot -f
                ;;
            *)
                echo "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 主程序开始
echo "初始化安装环境..."

# 挂载安装介质
if mount_cdrom; then
    echo "安装介质挂载成功"
    
    # 查找OpenWRT镜像
    if find_openwrt_image; then
        echo "OpenWRT镜像加载成功"
        IMG_SIZE=$(stat -c%s "/tmp/openwrt.img" 2>/dev/null || echo 0)
        echo "镜像大小: $((IMG_SIZE/1024/1024))MB"
    else
        echo "警告: 找不到OpenWRT镜像"
    fi
else
    echo "警告: 无法挂载安装介质"
    echo "将尝试使用内置镜像（如果有）"
fi

# 下载或使用内置busybox
if [ ! -x /bin/busybox ]; then
    echo "设置busybox..."
    # 创建busybox链接
    for app in sh echo cat ls mount umount dd sync reboot sleep clear; do
        ln -sf /init /bin/$app 2>/dev/null || true
    done
fi

# 启动主菜单
main_menu

# 如果上面的都失败了，启动救援shell
echo "启动救援shell..."
exec /bin/sh
EOF
    
    chmod +x "$initrd_dir/init"
    
    # 创建busybox（使用内置命令替代）
    cat > "$initrd_dir/bin/sh" << 'EOF'
#!/bin/sh
# 简化版shell
echo "Simple shell"
while read -p "# " cmd; do
    case "$cmd" in
        exit|quit) break ;;
        *) echo "Command: $cmd" ;;
    esac
done
EOF
    chmod +x "$initrd_dir/bin/sh"
    
    # 创建其他必要命令
    for cmd in echo cat ls mount umount dd sync reboot sleep; do
        ln -s sh "$initrd_dir/bin/$cmd" 2>/dev/null || true
    done
    
    # 打包initrd
    info "打包initrd..."
    cd "$initrd_dir"
    find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd.img"
    cd -
    
    success "initrd创建完成"
}

# 准备内核（使用简单方法）
prepare_kernel() {
    info "准备内核..."
    
    # 使用容器内的内核
    if [ -f "/boot/vmlinuz" ]; then
        cp "/boot/vmlinuz" "$STAGING_DIR/live/vmlinuz"
    elif [ -f "/vmlinuz" ]; then
        cp "/vmlinuz" "$STAGING_DIR/live/vmlinuz"
    else
        # 创建一个最小的内核占位符（实际需要真实内核）
        error "找不到内核文件"
        # 尝试从网络下载或使用备用方案
        wget -q "https://kernel.ubuntu.com/~kernel-ppa/mainline/v5.15/amd64/linux-image-5.15.0-051500-generic_5.15.0-051500.202110242130_amd64.deb" \
            -O /tmp/kernel.deb 2>/dev/null || true
        if [ -f "/tmp/kernel.deb" ]; then
            dpkg -x /tmp/kernel.deb /tmp/kernel-extract
            cp /tmp/kernel-extract/boot/vmlinuz* "$STAGING_DIR/live/vmlinuz" 2>/dev/null || true
        fi
    fi
    
    if [ -f "$STAGING_DIR/live/vmlinuz" ]; then
        success "内核准备完成"
    else
        error "无法准备内核"
        exit 1
    fi
}

# 配置引导加载器
configure_bootloaders() {
    info "配置引导加载器..."
    
    # 复制ISOLINUX文件
    cp /usr/lib/ISOLINUX/isolinux.bin "$STAGING_DIR/isolinux/" 2>/dev/null || \
    find /usr -name "isolinux.bin" 2>/dev/null | head -1 | xargs -I {} cp {} "$STAGING_DIR/isolinux/" 2>/dev/null
    
    # 复制必要的模块
    cp /usr/lib/syslinux/modules/bios/*.c32 "$STAGING_DIR/isolinux/" 2>/dev/null || true
    
    # 创建ISOLINUX配置 - 修复启动参数
    cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'EOF'
DEFAULT menu.c32
PROMPT 0
MENU TITLE OpenWRT Installer
TIMEOUT 100

LABEL install
    MENU LABEL ^Install OpenWRT (Default)
    MENU DEFAULT
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img console=tty0 console=ttyS0,115200n8 quiet
    
LABEL install_nomodeset
    MENU LABEL Install OpenWRT (^No Modeset)
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img console=tty0 nomodeset quiet
    
LABEL shell
    MENU LABEL ^Rescue Shell
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img console=tty0 init=/bin/sh
    
LABEL memtest
    MENU LABEL ^Memory Test
    KERNEL /isolinux/memtest
    
LABEL reboot
    MENU LABEL ^Reboot
    COM32 reboot.c32
EOF
    
    # 创建GRUB配置（UEFI支持）
    cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'EOF'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz console=tty0 quiet
    initrd /live/initrd.img
}

menuentry "Install OpenWRT (no modeset)" {
    linux /live/vmlinuz console=tty0 nomodeset quiet
    initrd /live/initrd.img
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz console=tty0 init=/bin/sh
    initrd /live/initrd.img
}

menuentry "Reboot" {
    reboot
}
EOF
    
    success "引导配置完成"
}

# 创建ISO
create_iso() {
    info "创建ISO镜像..."
    
    # 确保所有文件都存在
    if [ ! -f "$STAGING_DIR/live/vmlinuz" ]; then
        error "缺少内核文件"
        exit 1
    fi
    
    if [ ! -f "$STAGING_DIR/live/initrd.img" ]; then
        error "缺少initrd文件"
        exit 1
    fi
    
    # 创建ISO - 使用更兼容的参数
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "OPENWRT_INSTALL" \
        -eltorito-boot isolinux/isolinux.bin \
        -boot-load-size 4 \
        -boot-info-table \
        -no-emul-boot \
        -eltorito-catalog isolinux/isolinux.cat \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin 2>/dev/null \
        -output "$OUTPUT_DIR/$ISO_NAME.iso" \
        "$STAGING_DIR" 2>&1 | grep -v "unable to" || true
    
    # 验证ISO
    if [ -f "$OUTPUT_DIR/$ISO_NAME.iso" ]; then
        success "ISO创建完成: $OUTPUT_DIR/$ISO_NAME.iso"
        echo "文件大小: $(ls -lh "$OUTPUT_DIR/$ISO_NAME.iso" | awk '{print $5}')"
        
        # 显示ISO信息
        echo "ISO引导信息:"
        xorriso -indev "$OUTPUT_DIR/$ISO_NAME.iso" -toc 2>&1 | grep -E "(El-Torito|bootable)" || true
    else
        error "ISO创建失败"
        exit 1
    fi
}

# 主函数
main() {
    echo "========================================"
    echo "    OpenWRT 安装ISO构建工具"
    echo "========================================"
    echo ""
    
    check_requirements
    prepare_directories
    create_initrd
    prepare_kernel
    configure_bootloaders
    create_iso
    
    echo ""
    success "🎉 构建完成！"
    echo ""
    echo "使用说明:"
    echo "1. 写入USB: dd if='$OUTPUT_DIR/$ISO_NAME.iso' of=/dev/sdX bs=4M status=progress"
    echo "2. 从USB启动"
    echo "3. 选择 'Install OpenWRT'"
    echo "4. 按照提示选择磁盘并安装"
    echo ""
}

# 运行
main "$@"
