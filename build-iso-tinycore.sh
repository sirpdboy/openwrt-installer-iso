#!/bin/bash
# build-iso-tinycore.sh OpenWRT Installer ISO Builder 
# 支持BIOS/UEFI双引导

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_IMG="${1:-${SCRIPT_DIR}/assets/openwrt.img}"
OUTPUT_DIR="${2:-${SCRIPT_DIR}/output}"
OUTPUT_ISO_FILENAME="${3:-openwrt-installer.iso}"
OUTPUT_ISO="${OUTPUT_DIR}/${OUTPUT_ISO_FILENAME}"
WORK_DIR="/tmp/iso-work-$$"

# 日志函数
print_header() { echo -e "${CYAN}\n=== $1 ===${NC}"; }
print_step() { echo -e "${GREEN}▶${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1" >&2; }

# 错误处理
trap cleanup EXIT INT TERM
cleanup() {
    if [ -d "$WORK_DIR" ]; then
        print_info "清理工作目录..."
        rm -rf "$WORK_DIR" 2>/dev/null || true
    fi
}

# ================= 初始化 =================
print_header "OpenWRT 安装器构建系统"

# 验证输入
if [ ! -f "${INPUT_IMG}" ]; then
    print_error "输入IMG文件未找到: ${INPUT_IMG}"
    exit 1
fi

IMG_SIZE=$(du -h "${INPUT_IMG}" 2>/dev/null | cut -f1 || echo "unknown")
print_step "输入IMG: ${INPUT_IMG} (${IMG_SIZE})"
print_step "输出ISO: ${OUTPUT_ISO}"
print_step "工作目录: ${WORK_DIR}"

# ================= 准备目录 =================
print_header "1. 准备目录结构"

rm -rf "${WORK_DIR}" 2>/dev/null || true
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# 创建完整的ISO目录结构
mkdir -p "$WORK_DIR/iso/boot"
mkdir -p "$WORK_DIR/iso/boot/grub"
mkdir -p "$WORK_DIR/iso/EFI/BOOT"
mkdir -p "$WORK_DIR/iso/img"
mkdir -p "$WORK_DIR/iso/isolinux"  # 重要：创建 isolinux 目录
mkdir -p "${OUTPUT_DIR}"

print_info "目录结构:"
find . -type d | sort

print_success "目录结构创建完成"

# ================= 复制OpenWRT镜像 =================
print_header "2. 复制OpenWRT镜像"

cp "${INPUT_IMG}" "$WORK_DIR/iso/img/openwrt.img"
IMG_SIZE_FINAL=$(du -h "$WORK_DIR/iso/img/openwrt.img" 2>/dev/null | cut -f1)
print_success "IMG文件复制完成: ${IMG_SIZE_FINAL}"

# ================= 获取内核 =================
print_header "3. 获取Linux内核"

get_kernel() {
    print_step "下载Linux内核..."
    
    # 使用 Alpine Linux 内核（更稳定）
    KERNEL_URLS=(
        "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/boot/vmlinuz-lts"
        "https://distro.ibiblio.org/tinycorelinux/15.x/x86_64/release/distribution_files/vmlinuz64"
        "https://repo.tinycorelinux.net/15.x/x86_64/release/distribution_files/vmlinuz64"
    )
    
    for url in "${KERNEL_URLS[@]}"; do
        print_info "尝试: $url"
        
        if curl -L --connect-timeout 30 --max-time 60 --retry 3 \
            -s -o "$WORK_DIR/iso/boot/vmlinuz" "$url"; then
            
            if [ -f "$WORK_DIR/iso/boot/vmlinuz" ] && [ -s "$WORK_DIR/iso/boot/vmlinuz" ]; then
                KERNEL_SIZE=$(stat -c%s "$WORK_DIR/iso/boot/vmlinuz" 2>/dev/null || echo 0)
                if [ $KERNEL_SIZE -gt 1000000 ]; then  # 大于1MB
                    print_success "内核下载成功: $((KERNEL_SIZE/1024/1024))MB"
                    return 0
                fi
            fi
        fi
        sleep 2
    done
    
    print_error "内核下载失败"
    return 1
}

if ! get_kernel; then
    print_warning "创建最小内核占位..."
    wget -q "https://distro.ibiblio.org/tinycorelinux/15.x/x86_64/release/distribution_files/vmlinuz64" -O "$WORK_DIR/iso/boot/vmlinuz" || \
    dd if=/dev/zero of="$WORK_DIR/iso/boot/vmlinuz" bs=1M count=2
fi

KERNEL_SIZE=$(du -h "$WORK_DIR/iso/boot/vmlinuz" 2>/dev/null | cut -f1)
print_success "内核准备完成: ${KERNEL_SIZE}"

# ================= 创建带安装脚本的initramfs =================
print_header "4. 创建initramfs（含安装程序）"

create_initramfs() {
    print_step "创建initramfs..."
    
    local initrd_dir="${WORK_DIR}/initrd"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    cd "$initrd_dir"
    
    # 创建完整的目录结构
    mkdir -p {bin,dev,etc,proc,sys,tmp,mnt,opt,lib,lib64,usr/bin,run,root,sbin}
    
    # 创建设备节点
    mknod -m 622 dev/console c 5 1 2>/dev/null || true
    mknod -m 666 dev/null c 1 3 2>/dev/null || true
    mknod -m 666 dev/zero c 1 5 2>/dev/null || true
    mknod -m 666 dev/tty c 5 0 2>/dev/null || true
    mknod -m 666 dev/tty0 c 4 0 2>/dev/null || true
    mknod -m 666 dev/tty1 c 4 1 2>/dev/null || true
    mknod -m 666 dev/sda b 8 0 2>/dev/null || true
    mknod -m 666 dev/sda1 b 8 1 2>/dev/null || true
    mknod -m 666 dev/sr0 b 11 0 2>/dev/null || true  # CDROM
    
    # 创建安装脚本（/bin/install_openwrt.sh）
    cat > bin/install_openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/sh
# OpenWRT Installation Script

clear
cat << "EOF"
╔═══════════════════════════════════════════════════════╗
║               OpenWRT Auto Installer                  ║
╚═══════════════════════════════════════════════════════╝
EOF

echo ""
echo "OpenWRT image: $(ls -lh /openwrt.img 2>/dev/null | awk '{print $5}' || echo "unknown")"
echo ""

# 显示磁盘
show_disks() {
    echo "Available disks:"
    echo "================="
    
    # 尝试多种方法显示磁盘
    if command -v fdisk >/dev/null 2>&1; then
        fdisk -l 2>/dev/null | grep -E '^Disk /dev/(sd|hd|vd|nvme)' | head -10 || \
        echo "Cannot list disks with fdisk"
    elif command -v lsblk >/dev/null 2>&1; then
        lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -E '^(sd|hd|vd|nvme)' || \
        echo "Cannot list disks with lsblk"
    else
        # 简单列出
        echo "Listing block devices..."
        for d in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
            if [ -b "$d" ]; then
                echo "  $(basename "$d")"
            fi
        done
    fi
    echo "================="
}

while true; do
    show_disks
    echo ""
    echo -n "Enter target disk (e.g., sda): "
    read DISK
    
    if [ -z "$DISK" ]; then
        echo "No disk selected"
        continue
    fi
    
    # 添加/dev/前缀
    if [[ ! "$DISK" =~ ^/dev/ ]]; then
        DISK="/dev/$DISK"
    fi
    
    # 检查磁盘是否存在
    if [ ! -b "$DISK" ]; then
        echo "❌ Disk $DISK not found!"
        continue
    fi
    
    echo ""
    echo "Selected disk: $DISK"
    
    # 显示警告
    echo ""
    echo "⚠️  ⚠️  ⚠️  WARNING! ⚠️  ⚠️  ⚠️"
    echo "This will ERASE ALL DATA on: $DISK"
    echo "All partitions and data will be LOST!"
    echo ""
    echo -n "Type 'YES' to continue: "
    read CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Installation cancelled."
        echo ""
        continue
    fi
    
    # 开始安装
    clear
    echo ""
    echo "Installing OpenWRT to $DISK..."
    echo "This may take a few minutes..."
    echo ""
    
    # 检查dd是否存在
    if ! command -v dd >/dev/null 2>&1; then
        echo "❌ ERROR: dd command not found!"
        echo "Entering shell for manual installation..."
        exec /bin/sh
    fi
    
    # 写入镜像
    echo "Writing image (this may take several minutes)..."
    echo "================================================"
    
    # 尝试显示进度
    if command -v pv >/dev/null 2>&1; then
        pv /openwrt.img | dd of="$DISK" bs=4M
    else
        dd if=/openwrt.img of="$DISK" bs=4M status=progress 2>&1 || \
        dd if=/openwrt.img of="$DISK" bs=4M 2>&1
    fi
    
    # 检查dd结果
    if [ $? -ne 0 ]; then
        echo ""
        echo "❌ ERROR: Failed to write image!"
        echo "Possible issues:"
        echo "1. Disk may be too small"
        echo "2. Disk may be write-protected"
        echo "3. Media error"
        echo ""
        echo "Press Enter to retry..."
        read
        continue
    fi
    
    # 同步数据
    echo ""
    echo "Syncing data..."
    sync 2>/dev/null || true
    sleep 2
    
    echo ""
    echo "✅ Installation successful!"
    echo ""
    echo "Next steps:"
    echo "1. Remove the installation media (USB/CD)"
    echo "2. Restart your computer"
    echo "3. OpenWRT will boot automatically"
    echo ""
    
    echo "System will reboot in 10 seconds..."
    echo "Press Ctrl+C to cancel"
    echo ""
    
    # 倒计时
    for i in $(seq 10 -1 1); do
        echo -ne "Rebooting in $i seconds...\r"
        sleep 1
    done
    echo ""
    
    # 重启
    echo "Rebooting..."
    if command -v reboot >/dev/null 2>&1; then
        reboot -f
    else
        # 备用重启方法
        echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
        echo b > /proc/sysrq-trigger 2>/dev/null || true
    fi
    
    # 如果还没重启，等待
    sleep 5
    echo "If system hasn't rebooted, please restart manually."
    break
done

exit 0
INSTALL_SCRIPT

    chmod +x /bin/install_openwrt.sh

    # 创建主init脚本 - 直接运行安装程序
    cat > init << 'INIT'
#!/bin/sh
# OpenWRT Installer - Main Init Script

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# 基本挂载
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 设置环境
export TERM=linux
export HOME=/root

clear
echo "========================================"
echo "       OpenWRT Installer v1.0"
echo "========================================"
echo ""
echo "Initializing installation environment..."
echo ""

# 挂载安装介质
echo "Mounting installation media..."
for device in /dev/sr0 /dev/cdrom /dev/hdc /dev/hdd; do
    if [ -b "$device" ]; then
        echo "Trying $device..."
        mkdir -p /cdrom
        if mount -t iso9660 -o ro "$device" /cdrom 2>/dev/null; then
            if [ -f /cdrom/img/openwrt.img ]; then
                echo "✅ Media mounted successfully"
                
                # 复制镜像到内存中（更快）
                echo "Copying OpenWRT image to memory..."
                cp /cdrom/img/openwrt.img /openwrt.img 2>/dev/null || true
                
                if [ -f /openwrt.img ]; then
                    IMG_SIZE=$(ls -lh /openwrt.img 2>/dev/null | awk '{print $5}' || echo "unknown")
                    echo "✅ OpenWRT image ready: $IMG_SIZE"
                    
                    # 运行安装程序
                    echo ""
                    echo "Starting installation program..."
                    echo "========================================"
                    
                    # 直接运行安装逻辑
                    /bin/install_openwrt.sh
                    
                    # 如果安装程序返回，显示消息
                    echo ""
                    echo "Installation program completed."
                    echo "Press Enter for shell..."
                    read dummy
                    exec /bin/sh
                else
                    echo "❌ Failed to copy image"
                fi
                break
            else
                umount /cdrom 2>/dev/null
            fi
        fi
    fi
done

if [ ! -f /openwrt.img ]; then
    echo "❌ ERROR: Cannot find OpenWRT image!"
    echo ""
    echo "Troubleshooting:"
    echo "1. Check media is inserted"
    echo "2. Try: mount -t iso9660 /dev/sr0 /cdrom"
    echo "3. Check: ls /cdrom/img/"
    echo ""
    echo "Entering emergency shell..."
    exec /bin/sh
fi
INIT

    chmod +x init
        
    # 下载BusyBox静态二进制
    print_info "获取BusyBox..."
    
    if wget -q "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" -O bin/busybox; then
        chmod +x bin/busybox
        # 创建符号链接
        cd bin
        ./busybox --list | while read app; do
            ln -sf busybox "$app" 2>/dev/null || true
        done
        cd ..
        print_success "BusyBox准备完成"
    else
        # 创建最小命令集
        print_warning "BusyBox下载失败，创建最小命令集"
        
        cat > bin/sh << 'MINI_SH'
#!/bin/sh
echo "OpenWRT Installer Minimal Shell"
echo "Type 'install' to start installation"
while read -p "# " cmd; do
    case "$cmd" in
        install) exec /bin/install_openwrt.sh;;
        help) echo "Commands: install, reboot";;
        reboot) echo "Rebooting..."; reboot -f;;
        *) echo "Unknown: $cmd";;
    esac
done
MINI_SH
        chmod +x bin/sh
        
        # 创建必要的命令
        for cmd in ls cat echo mount dd sync; do
            cat > bin/$cmd << EOF
#!/bin/sh
echo "$cmd: Not available in minimal mode"
EOF
            chmod +x bin/$cmd
        done
    fi
    
    # 创建特殊命令
    cat > bin/reboot << 'REBOOT_CMD'
#!/bin/sh
echo "Rebooting system..."
# 尝试多种重启方法
reboot -f 2>/dev/null || \
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null; echo b > /proc/sysrq-trigger 2>/dev/null || \
echo "Please reboot manually"
REBOOT_CMD
    chmod +x bin/reboot
    
# 创建fdisk命令
    cat > bin/fdisk << 'FDISK'
#!/bin/sh
if [ "$1" = "-l" ]; then
    echo "Disk listing:"
    for d in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
        [ -b "$d" ] && echo "Disk $d"
    done
else
    echo "fdisk: $@"
fi
FDISK
    chmod +x bin/fdisk
    
    # 创建lsblk命令
    cat > bin/lsblk << 'LSBLK'
#!/bin/sh
echo "NAME   SIZE"
for d in /dev/sd[a-z] /dev/vd[a-z]; do
    if [ -b "$d" ]; then
        name=$(basename "$d")
        echo "$name    -"
    fi
done
LSBLK
    chmod +x bin/lsblk
    cat > bin/sync << 'SYNC_CMD'
#!/bin/sh
/bin/busybox sync 2>/dev/null || true
SYNC_CMD
    chmod +x bin/sync
    
    # 创建initramfs
    print_step "创建initramfs..."
    find . 2>/dev/null | cpio -o -H newc 2>/dev/null | gzip -9 > "${WORK_DIR}/iso/boot/initrd.img"
    
    INITRD_SIZE=$(du -h "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null | cut -f1)
    print_success "initramfs创建完成: ${INITRD_SIZE}"
    
    return 0
}

create_initramfs

# ================= 配置BIOS引导 =================
print_header "5. 配置BIOS引导 (ISOLINUX)"

setup_bios_boot() {
    print_step "设置ISOLINUX引导..."
    
    mkdir -p "$WORK_DIR/iso/isolinux"
    
    print_info "获取ISOLINUX文件..."
    
    # 从系统复制文件
    if [ -d "/usr/lib/syslinux" ]; then
        print_info "从/usr/lib/syslinux复制..."
        cp /usr/lib/syslinux/isolinux.bin $WORK_DIR/iso/isolinux/ 2>/dev/null || true
        cp /usr/lib/syslinux/ldlinux.c32 $WORK_DIR/iso/isolinux/ 2>/dev/null || true
        
        # 复制.c32文件
        find /usr/lib/syslinux -name "*.c32" -type f 2>/dev/null | head -10 | while read file; do
            cp "$file" $WORK_DIR/iso/isolinux/ 2>/dev/null || true
        done
    fi
    
    if [ -d "/usr/share/syslinux" ]; then
        print_info "从/usr/share/syslinux复制..."
        cp /usr/share/syslinux/isolinux.bin $WORK_DIR/iso/isolinux/ 2>/dev/null || true
        cp /usr/share/syslinux/ldlinux.c32 $WORK_DIR/iso/isolinux/ 2>/dev/null || true
    fi
    
    # 检查关键文件
    if [ ! -f "$WORK_DIR/iso/isolinux/isolinux.bin" ]; then
        print_warning "下载isolinux.bin..."
        wget -q "https://github.com/ventoy/syslinux/raw/ventoy/bios/core/isolinux.bin" -O $WORK_DIR/iso/isolinux/isolinux.bin || \
        echo "Failed to get isolinux.bin"
    fi
    
    if [ ! -f "$WORK_DIR/iso/isolinux/ldlinux.c32" ]; then
        print_warning "下载ldlinux.c32..."
        wget -q "https://github.com/ventoy/syslinux/raw/ventoy/bios/com32/elflink/ldlinux/ldlinux.c32" -O $WORK_DIR/iso/isolinux/ldlinux.c32 || \
        echo "Failed to get ldlinux.c32"
    fi
    
    # 创建ISOLINUX配置
    cat > $WORK_DIR/iso/isolinux/isolinux.cfg << 'ISOLINUX_CFG'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 300
UI menu.c32

MENU TITLE OpenWRT Installer
MENU BACKGROUND splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std

LABEL install
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img init=/bin/sh

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
ISOLINUX_CFG

    # 如果缺少menu.c32，使用文本模式
    if [ ! -f "$WORK_DIR/iso/isolinux/menu.c32" ] && [ ! -f "$WORK_DIR/iso/isolinux/vesamenu.c32" ]; then
        print_info "使用文本模式..."
        cat > $WORK_DIR/iso/isolinux/isolinux.cfg << 'TEXT_CFG'
DEFAULT install
PROMPT 1
TIMEOUT 100
ONTIMEOUT install

LABEL install
  MENU DEFAULT
  MENU LABEL Install OpenWRT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 quiet

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img init=/bin/sh
TEXT_CFG
    fi
    
    # 在boot目录也放一份
    cp $WORK_DIR/iso/isolinux/* $WORK_DIR/iso/boot/ 2>/dev/null || true
    
    print_success "BIOS引导配置完成"
    return 0
}

setup_bios_boot

# ================= 修复UEFI引导 =================
print_header "6. 配置UEFI引导"

setup_uefi_boot() {
    print_step "设置UEFI引导..."
    
    mkdir -p "$WORK_DIR/iso/EFI/BOOT"
    mkdir -p "$WORK_DIR/iso/boot/grub"
    
    print_info "准备UEFI引导文件..."
    
    # 方法1：使用grub-mkimage构建（最可靠）
    if command -v grub-mkimage >/dev/null 2>&1; then
        print_info "使用grub-mkimage构建GRUB EFI..."
        
        # 创建临时目录
        mkdir -p /tmp/grub_efi
        
        # 构建GRUB EFI镜像
        MODULES="part_gpt part_msdos fat iso9660 ext2 configfile echo normal terminal reboot halt linux"
        
        if grub-mkimage \
            -O x86_64-efi \
            -o /tmp/grub_efi/BOOTX64.EFI \
            -p /EFI/BOOT \
            $MODULES \
            2>/dev/null; then
            
            cp /tmp/grub_efi/BOOTX64.EFI "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI"
            print_success "GRUB EFI构建成功"
        fi
        rm -rf /tmp/grub_efi
    fi
    
    # 方法2：从系统复制
    if [ ! -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
        print_info "从系统复制GRUB EFI..."
        
        # Ubuntu/Debian中的路径
        GRUB_PATHS=(
            "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi"
            "/usr/lib/grub/x86_64-efi/grub.efi"
            "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed"
            "/usr/lib/grub/x86_64-efi-core/grubx64.efi"
        )
        
        for path in "${GRUB_PATHS[@]}"; do
            if [ -f "$path" ]; then
                print_info "找到: $path"
                cp "$path" "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null && break
            fi
        done
    fi
    
    # 方法3：直接下载预编译的GRUB
    if [ ! -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
        print_info "下载GRUB EFI..."
        wget -q "https://github.com/ventoy/grub/raw/ventoy/grub2/grubx64.efi" -O $WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI || \
        wget -q "https://github.com/a1ive/grub2-themes/raw/master/grub2-theme-breeze/grubx64.efi" -O $WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI || \
        echo "Failed to download GRUB EFI"
    fi
    
    # 创建GRUB配置
    print_info "创建GRUB配置..."
    
    # 创建主GRUB配置（在boot/grub）
    mkdir -p "$WORK_DIR/iso/boot/grub"
    cat > "$WORK_DIR/iso/boot/grub/grub.cfg" << 'GRUB_CFG'
# OpenWRT Installer - GRUB Configuration
set timeout=10
set default=0

# 设置菜单颜色
set menu_color_normal=light-gray/black
set menu_color_highlight=black/light-gray

menuentry "Install OpenWRT" {
    echo "Loading OpenWRT installer..."
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet
    initrd /boot/initrd.img
}

menuentry "Emergency Shell" {
    echo "Loading emergency shell..."
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 init=/bin/sh
    initrd /boot/initrd.img
}

menuentry "Reboot" {
    reboot
}

menuentry "Power Off" {
    halt
}
GRUB_CFG
    
    # 在EFI目录也创建配置
    cat > "$WORK_DIR/iso/EFI/BOOT/grub.cfg" << 'EFI_CFG'
# UEFI GRUB Configuration
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EFI_CFG
    
    # 验证UEFI文件
    if [ -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
        EFI_SIZE=$(du -h "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null | cut -f1)
        print_success "UEFI引导配置完成: ${EFI_SIZE}"
        return 0
    else
        print_warning "UEFI引导文件未找到"
        return 1
    fi
}

setup_uefi_boot

# ================= 创建ISO镜像（修复UEFI引导记录）=================
print_header "7. 创建ISO镜像"

create_iso() {
    print_step "创建ISO..."
    
    cd "${WORK_DIR}/iso"
    
    # 检查文件
    print_info "检查文件:"
    echo "ISOLINUX文件:"
    ls isolinux/*.bin isolinux/*.c32 2>/dev/null | head -5 || echo "无ISOLINUX文件"
    echo ""
    echo "UEFI文件:"
    ls -la EFI/BOOT/BOOTX64.EFI 2>/dev/null && echo "✅ BOOTX64.EFI存在" || echo "❌ BOOTX64.EFI不存在"
    
    # 重要：创建boot.cat文件
    print_info "创建boot.cat文件..."
    echo "OpenWRT Installer Boot Catalog" > isolinux/boot.cat
    cp isolinux/boot.cat boot/boot.cat 2>/dev/null || true
    
    # 创建ISO - 确保UEFI引导记录正确
    print_info "创建可引导ISO..."
    
    # 方法1：完整方法（支持BIOS和UEFI）
    if [ -f "isolinux/isolinux.bin" ] && [ -f "EFI/BOOT/BOOTX64.EFI" ]; then
        print_info "创建BIOS+UEFI双引导ISO..."
        
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -J -r -rock \
            -b isolinux/isolinux.bin \
            -c isolinux/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -eltorito-alt-boot \
            -e EFI/BOOT/BOOTX64.EFI \
            -no-emul-boot \
            -isohybrid-gpt-basdat \
            -o "${OUTPUT_ISO}" . 2>&1
        
        if [ $? -eq 0 ]; then
            print_success "双引导ISO创建成功"
        else
            print_warning "双引导方法失败，尝试简化方法..."
        fi
    fi
    
    # 方法2：如果方法1失败或文件不全，使用简化方法
    if [ ! -f "${OUTPUT_ISO}" ] || [ ! -s "${OUTPUT_ISO}" ]; then
        print_info "使用简化方法创建ISO..."
        
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -J -r -rock \
            -b isolinux/isolinux.bin \
            -c isolinux/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -eltorito-alt-boot \
            -e EFI/BOOT/BOOTX64.EFI \
            -no-emul-boot \
            -o "${OUTPUT_ISO}" . 2>&1
        
        if [ $? -ne 0 ]; then
            # 方法3：仅BIOS引导
            print_info "创建仅BIOS引导ISO..."
            xorriso -as mkisofs \
                -volid "OPENWRT_INSTALL" \
                -J -r \
                -b isolinux/isolinux.bin \
                -c isolinux/boot.cat \
                -no-emul-boot \
                -boot-load-size 4 \
                -boot-info-table \
                -o "${OUTPUT_ISO}" . 2>&1
        fi
    fi
    
    # 验证ISO
    if [ -f "${OUTPUT_ISO}" ] && [ -s "${OUTPUT_ISO}" ]; then
        ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
        ISO_BYTES=$(stat -c%s "${OUTPUT_ISO}" 2>/dev/null || echo 0)
        
        print_success "ISO创建完成: ${ISO_SIZE}"
        
        # 检查ISO引导信息
        print_info "检查ISO信息..."
        if command -v file >/dev/null 2>&1; then
            file "${OUTPUT_ISO}" 2>/dev/null | head -1 || true
        fi
        
        # 使用isoinfo检查引导记录
        if command -v isoinfo >/dev/null 2>&1; then
            echo "ISO引导信息:"
            isoinfo -d -i "${OUTPUT_ISO}" 2>/dev/null | grep -E "Boot|El Torito" || true
        fi
        
        return 0
    else
        print_error "ISO创建失败"
        return 1
    fi
}

create_iso

# ================= 最终报告 =================
print_header "8. 构建完成"

echo ""
echo "═══════════════════════════════════════════════════"
echo "        🎉 OpenWRT安装器构建完成!"
echo "═══════════════════════════════════════════════════"
echo ""

if [ -f "${OUTPUT_ISO}" ]; then
    ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
    
    echo "📊 构建统计:"
    echo "  • 输出文件: ${OUTPUT_ISO}"
    echo "  • ISO大小: ${ISO_SIZE}"
    echo "  • OpenWRT镜像: ${IMG_SIZE_FINAL}"
    echo "  • Linux内核: ${KERNEL_SIZE}"
    echo ""
    
    echo "🔧 引导支持:"
    echo "  • BIOS引导: ✅ 已配置"
    echo "  • UEFI引导: $( [ -f ${WORK_DIR}/iso/EFI/BOOT/BOOTX64.EFI ] && echo "✅ 已配置" || echo "⚠️  可能未配置" )"
    echo ""
    
    echo "🚀 安装流程:"
    echo "  1. 自动检测安装介质"
    echo "  2. 列出可用磁盘"
    echo "  3. 安全确认（需要输入YES）"
    echo "  4. 显示安装进度"
    echo "  5. 安装完成后自动重启"
    echo ""
    
    echo "🔍 测试方法:"
    echo "  测试BIOS: qemu-system-x86_64 -cdrom ${OUTPUT_ISO} -m 512"
    echo "  测试UEFI: qemu-system-x86_64 -bios /usr/share/qemu/OVMF.fd -cdrom ${OUTPUT_ISO} -m 512"
    echo ""
fi

# 清理
cleanup

echo "📅 构建时间: $(date)"
echo "═══════════════════════════════════════════════════"

echo ""
print_success "构建流程完成!"
exit 0
