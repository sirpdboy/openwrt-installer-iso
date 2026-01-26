#!/bin/ash
# OpenWRT Alpine Installer ISO Builder
# 支持BIOS/UEFI双引导
# 作者：基于Alpine Linux

set -e

# ==================== 配置参数 ====================
OPENWRT_IMG="${1:-/mnt/ezopwrt.img}"
ISO_NAME="${2:-openwrt-alpine-installer.iso}"
WORK_DIR="/tmp/openwrt_alpine_build_$(date +%s)"
OUTPUT_DIR="/output"
CHROOT_DIR="$WORK_DIR/alpine_root"
ISO_FILE="$OUTPUT_DIR/$ISO_NAME"

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 日志函数 ====================
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ==================== 检查输入文件 ====================
check_prerequisites() {
    log_info "检查依赖和输入文件..."
    
    # 检查OpenWRT镜像
    if [ ! -f "$OPENWRT_IMG" ]; then
        log_error "未找到OpenWRT镜像: $OPENWRT_IMG"
        exit 1
    fi
    
    # 安装必要工具
    apk add --no-cache alpine-sdk xorriso syslinux grub grub-efi mtools dosfstools \
        squashfs-tools parted e2fsprogs pv dialog coreutils findutils grep
    
    # 创建工作目录
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR" "$CHROOT_DIR" "$OUTPUT_DIR"
    mkdir -p "$WORK_DIR/iso/boot/grub"
    mkdir -p "$WORK_DIR/iso/EFI/BOOT"
    
    log_success "环境检查完成"
}

# ==================== 创建Alpine基础系统 ====================
create_alpine_base() {
    log_info "创建Alpine Linux基础系统..."
    
    # 设置Alpine源
    cat > /etc/apk/repositories << EOF
http://dl-cdn.alpinelinux.org/alpine/v3.19/main
http://dl-cdn.alpinelinux.org/alpine/v3.19/community
EOF
    
    # 使用apk工具创建最小系统
    apk --root "$CHROOT_DIR" --initdb add alpine-base busybox \
        syslinux grub-bios grub-efi dosfstools mtools parted \
        e2fsprogs sfdisk bash dialog pv
    
    # 创建基本目录结构
    mkdir -p "$CHROOT_DIR"/{dev,proc,sys,tmp,run,var}
    mount -t proc proc "$CHROOT_DIR/proc"
    mount -t sysfs sysfs "$CHROOT_DIR/sys"
    mount -o bind /dev "$CHROOT_DIR/dev"
    
    # 配置系统
    cat > "$CHROOT_DIR/etc/inittab" << 'INITTAB'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# Set up a couple of getty's
tty1::respawn:/sbin/getty 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3
tty4::respawn:/sbin/getty 38400 tty4
tty5::respawn:/sbin/getty 38400 tty5
tty6::respawn:/sbin/getty 38400 tty6

# Put a getty on the serial port
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100

# Stuff to do before rebooting
::shutdown:/sbin/openrc shutdown
INITTAB

    # 配置网络
    cat > "$CHROOT_DIR/etc/network/interfaces" << 'NETWORK'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NETWORK

    # 配置DNS
    echo "nameserver 8.8.8.8" > "$CHROOT_DIR/etc/resolv.conf"
    echo "nameserver 1.1.1.1" >> "$CHROOT_DIR/etc/resolv.conf"
    
    log_success "Alpine基础系统创建完成"
}

# ==================== 创建安装系统 ====================
create_installer_system() {
    log_info "创建安装系统..."
    
    # 复制OpenWRT镜像
    cp "$OPENWRT_IMG" "$CHROOT_DIR/openwrt.img"
    
    # 创建启动脚本
    cat > "$CHROOT_DIR/sbin/init" << 'INIT_SCRIPT'
#!/bin/ash
# Alpine init script for OpenWRT installer

# 挂载必要的文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts

# 设置控制台
echo "Setting up console..."
exec < /dev/tty1 > /dev/tty1 2>&1
chvt 1

# 显示欢迎信息
clear
cat << "WELCOME"
╔═══════════════════════════════════════════════════════╗
║       OpenWRT Alpine Installer System                 ║
║        支持 BIOS 和 UEFI 双引导                      ║
╚═══════════════════════════════════════════════════════╝

系统启动中，请稍候...
WELCOME

sleep 2

# 检查OpenWRT镜像
if [ ! -f "/openwrt.img" ]; then
    clear
    echo ""
    echo "❌ 错误: 未找到OpenWRT镜像文件"
    echo ""
    echo "镜像文件应位于: /openwrt.img"
    echo ""
    echo "按回车键进入shell..."
    read
    exec /bin/ash
fi

# 启动安装程序
exec /sbin/openwrt-installer
INIT_SCRIPT
    chmod +x "$CHROOT_DIR/sbin/init"
    
    # 创建OpenWRT安装脚本
    cat > "$CHROOT_DIR/sbin/openwrt-installer" << 'INSTALLER_SCRIPT'
#!/bin/ash
# OpenWRT安装程序主脚本

# 清理屏幕
clear

# 显示标题
show_header() {
    clear
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              OpenWRT Alpine 安装程序                     ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
}

# 获取磁盘列表
get_disks() {
    show_header
    echo "扫描可用磁盘..."
    echo ""
    
    local index=1
    for disk in /sys/block/*; do
        local disk_name=$(basename "$disk")
        
        # 排除虚拟设备
        case "$disk_name" in
            loop*|ram*|fd*|sr*)
                continue
                ;;
        esac
        
        # 获取磁盘信息
        if [ -f "$disk/device/model" ]; then
            local model=$(cat "$disk/device/model" 2>/dev/null | tr -d '\n')
        else
            local model="Unknown"
        fi
        
        local size=$(cat "$disk/size" 2>/dev/null)
        if [ -n "$size" ]; then
            size=$((size * 512 / 1024 / 1024 / 1024))
            size="${size}GB"
        else
            size="Unknown"
        fi
        
        echo "  [$index] /dev/$disk_name - $size - $model"
        eval "DISK_$index=\"/dev/$disk_name\""
        index=$((index + 1))
    done
    
    TOTAL_DISKS=$((index - 1))
}

# 安装OpenWRT
install_openwrt() {
    local target_disk="$1"
    
    show_header
    echo "目标磁盘: $target_disk"
    echo "镜像大小: $(ls -lh /openwrt.img | awk '{print $5}')"
    echo ""
    echo "⚠️  警告: 这将清除 $target_disk 上的所有数据！"
    echo ""
    echo "请确认以下信息:"
    echo "1. 已备份重要数据"
    echo "2. 目标磁盘正确"
    echo ""
    
    echo -n "输入 'YES' 继续安装: "
    read confirm
    
    if [ "$confirm" != "YES" ]; then
        echo "安装已取消"
        sleep 2
        return 1
    fi
    
    # 开始安装
    clear
    show_header
    echo "正在安装OpenWRT到 $target_disk ..."
    echo "这可能需要几分钟，请稍候..."
    echo ""
    
    # 使用dd写入镜像
    if command -v pv >/dev/null 2>&1; then
        # 使用pv显示进度
        total_size=$(stat -c%s /openwrt.img)
        pv -s $total_size /openwrt.img | dd of="$target_disk" bs=4M 2>/dev/null
    else
        # 简单进度显示
        echo "正在写入镜像..."
        dd if=/openwrt.img of="$target_disk" bs=4M status=progress 2>&1
    fi
    
    # 检查结果
    if [ $? -eq 0 ]; then
        sync
        echo ""
        echo "✅ OpenWRT安装成功！"
        echo ""
        echo "下一步操作:"
        echo "1. 移除安装介质"
        echo "2. 从 $target_disk 启动"
        echo "3. OpenWRT将自动启动"
        echo ""
        
        # 倒计时重启
        echo "系统将在10秒后重启..."
        for i in $(seq 10 -1 1); do
            echo -ne "重启倒计时: ${i}秒...\r"
            sleep 1
        done
        
        echo -e "\n正在重启..."
        reboot -f
    else
        echo ""
        echo "❌ 安装失败！"
        echo ""
        echo "可能的原因:"
        echo "1. 磁盘可能被挂载或使用中"
        echo "2. 磁盘空间不足"
        echo "3. 磁盘损坏"
        echo ""
        echo "按回车键返回..."
        read
    fi
}

# 主循环
main_menu() {
    while true; do
        get_disks
        
        if [ $TOTAL_DISKS -eq 0 ]; then
            echo ""
            echo "❌ 未检测到磁盘！"
            echo ""
            echo "按回车键重新扫描..."
            read
            continue
        fi
        
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo "请选择目标磁盘 (1-$TOTAL_DISKS):"
        echo -n "输入磁盘编号或 'q' 退出: "
        read choice
        
        case "$choice" in
            [Qq])
                echo "退出安装程序"
                exec /bin/ash
                ;;
            [0-9]*)
                if [ "$choice" -ge 1 ] && [ "$choice" -le "$TOTAL_DISKS" ]; then
                    eval "target_disk=\"\$DISK_$choice\""
                    install_openwrt "$target_disk"
                else
                    echo "无效的选择"
                    sleep 2
                fi
                ;;
            *)
                echo "无效的输入"
                sleep 2
                ;;
        esac
    done
}

# 启动主菜单
main_menu
INSTALLER_SCRIPT
    chmod +x "$CHROOT_DIR/sbin/openwrt-installer"
    
    # 创建fstab
    cat > "$CHROOT_DIR/etc/fstab" << 'FSTAB'
tmpfs           /tmp            tmpfs   defaults        0       0
tmpfs           /var/log        tmpfs   defaults        0       0
tmpfs           /var/tmp        tmpfs   defaults        0       0
FSTAB
    
    # 清理不必要的文件
    rm -rf "$CHROOT_DIR/var/cache/apk/*"
    
    log_success "安装系统创建完成"
}

# ==================== 创建引导配置 ====================
create_boot_config() {
    log_info "创建引导配置..."
    
    # 1. 复制内核和initramfs
    cp "$CHROOT_DIR/boot/vmlinuz-lts" "$WORK_DIR/iso/boot/vmlinuz"
    
    # 创建initramfs（简化版）
    cat > "$CHROOT_DIR/init" << 'MINI_INIT'
#!/bin/sh
# Minimal init for OpenWRT installer

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Run installer
exec /sbin/openwrt-installer
MINI_INIT
    chmod +x "$CHROOT_DIR/init"
    
    # 创建简单的initramfs
    (cd "$CHROOT_DIR" && find . | cpio -o -H newc | gzip -9 > "$WORK_DIR/iso/boot/initrd.img") 2>/dev/null
    
    # 2. 创建SYSLINUX配置（BIOS引导）
    cat > "$WORK_DIR/iso/boot/syslinux.cfg" << 'SYSLINUX_CFG'
DEFAULT openwrt
TIMEOUT 50
PROMPT 0

LABEL openwrt
    MENU LABEL Install OpenWRT (BIOS)
    KERNEL /boot/vmlinuz
    INITRD /boot/initrd.img
    APPEND console=tty0 console=ttyS0,115200
SYSLINUX_CFG

    # 复制SYSLINUX文件
    cp /usr/share/syslinux/isolinux.bin "$WORK_DIR/iso/boot/"
    cp /usr/share/syslinux/ldlinux.c32 "$WORK_DIR/iso/boot/"
    cp /usr/share/syslinux/libutil.c32 "$WORK_DIR/iso/boot/"
    cp /usr/share/syslinux/menu.c32 "$WORK_DIR/iso/boot/"
    
    # 3. 创建GRUB配置（UEFI引导）
    cat > "$WORK_DIR/iso/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (UEFI)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}
GRUB_CFG

    log_success "引导配置创建完成"
}

# ==================== 创建UEFI引导文件 ====================
create_uefi_boot() {
    log_info "创建UEFI引导文件..."
    
    # 创建EFI目录结构
    mkdir -p "$WORK_DIR/efi/EFI/BOOT"
    
    # 使用grub-mkimage创建UEFI引导文件
    grub-mkimage \
        -o "$WORK_DIR/efi/EFI/BOOT/bootx64.efi" \
        -p /boot/grub \
        -O x86_64-efi \
        boot linux search normal configfile part_gpt part_msdos fat ext2 iso9660
    
    # 复制GRUB模块
    mkdir -p "$WORK_DIR/efi/boot/grub/x86_64-efi"
    cp -r /usr/lib/grub/x86_64-efi/* "$WORK_DIR/efi/boot/grub/x86_64-efi/" 2>/dev/null || true
    
    # 复制grub.cfg到EFI分区
    cp "$WORK_DIR/iso/boot/grub/grub.cfg" "$WORK_DIR/efi/boot/grub/"
    
    # 创建EFI引导镜像
    dd if=/dev/zero of="$WORK_DIR/efiboot.img" bs=1M count=32
    mkfs.vfat -F 32 "$WORK_DIR/efiboot.img"
    
    # 挂载并复制文件
    mount_point="$WORK_DIR/efi_mount"
    mkdir -p "$mount_point"
    
    # 尝试挂载
    mount -o loop "$WORK_DIR/efiboot.img" "$mount_point" 2>/dev/null || {
        # 如果挂载失败，使用mcopy
        mcopy -i "$WORK_DIR/efiboot.img" -s "$WORK_DIR/efi/EFI" ::
        mcopy -i "$WORK_DIR/efiboot.img" -s "$WORK_DIR/efi/boot" ::
    } && {
        # 如果挂载成功，直接复制
        cp -r "$WORK_DIR/efi/EFI" "$mount_point/"
        cp -r "$WORK_DIR/efi/boot" "$mount_point/"
        umount "$mount_point"
    }
    
    # 清理挂载点
    rm -rf "$mount_point"
    
    # 复制到ISO目录
    cp "$WORK_DIR/efiboot.img" "$WORK_DIR/iso/EFI/BOOT/"
    
    log_success "UEFI引导文件创建完成"
}

# ==================== 构建ISO镜像 ====================
build_iso() {
    log_info "构建ISO镜像..."
    
    # 创建ISO
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
        -c boot/boot.cat \
        -b boot/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/BOOT/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -output "$ISO_FILE" \
        "$WORK_DIR/iso"
    
    # 检查ISO是否创建成功
    if [ -f "$ISO_FILE" ]; then
        ISO_SIZE=$(ls -lh "$ISO_FILE" | awk '{print $5}')
        log_success "✅ ISO创建成功: $ISO_FILE ($ISO_SIZE)"
        
        # 显示构建信息
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo "OpenWRT Alpine Installer ISO 构建完成"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        echo "📦 输出文件: $ISO_FILE"
        echo "📏 文件大小: $ISO_SIZE"
        echo ""
        echo "✅ 引导支持:"
        echo "   - BIOS (Legacy) 引导"
        echo "   - UEFI 引导"
        echo ""
        echo "🚀 使用方法:"
        echo "   1. 制作启动U盘:"
        echo "      dd if=\"$ISO_FILE\" of=/dev/sdX bs=4M status=progress"
        echo "   2. 从U盘启动"
        echo "   3. 选择安装OpenWRT"
        echo "   4. 选择目标磁盘"
        echo "   5. 等待安装完成"
        echo ""
        echo "⚠️  注意: 安装会清除目标磁盘的所有数据！"
        echo "══════════════════════════════════════════════════════════"
    else
        log_error "ISO创建失败"
        exit 1
    fi
}

# ==================== 清理工作 ====================
cleanup() {
    log_info "清理临时文件..."
    
    # 卸载chroot目录
    umount "$CHROOT_DIR/proc" 2>/dev/null || true
    umount "$CHROOT_DIR/sys" 2>/dev/null || true
    umount "$CHROOT_DIR/dev" 2>/dev/null || true
    
    # 删除工作目录
    rm -rf "$WORK_DIR"
    
    log_success "清理完成"
}

# ==================== 主执行流程 ====================
main() {
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "    OpenWRT Alpine Installer ISO Builder"
    echo "    支持 BIOS 和 UEFI 双引导"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    
    # 执行所有步骤
    check_prerequisites
    create_alpine_base
    create_installer_system
    create_boot_config
    create_uefi_boot
    build_iso
    cleanup
    
    echo ""
    log_success "🎉 全部构建任务完成！"
    echo ""
}

# 执行主函数
main "$@"
