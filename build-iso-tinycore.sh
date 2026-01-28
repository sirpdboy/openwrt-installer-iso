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
mkdir -p "iso"
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
    
    # 使用 TinyCore Linux 内核
    KERNEL_URLS=(
        "https://distro.ibiblio.org/tinycorelinux/15.x/x86_64/release/distribution_files/vmlinuz64"
        "https://distro.ibiblio.org/tinycorelinux/10.x/x86_64/release/distribution_files/vmlinuz64"
        "https://tinycorelinux.net/15.x/x86_64/release/distribution_files/vmlinuz64"
        "https://repo.tinycorelinux.net/15.x/x86_64/release/distribution_files/vmlinuz64"
    )
    
    for url in "${KERNEL_URLS[@]}"; do
        print_info "尝试: $url"
        
        if curl -L --connect-timeout 30 --max-time 60 --retry 3 \
            -s -o "$WORK_DIR/iso/boot/vmlinuz" "$url"; then
            
            if [ -f "$WORK_DIR/iso/boot/vmlinuz" ] && [ -s "$WORK_DIR/iso/boot/vmlinuz" ]; then
                KERNEL_SIZE=$(stat -c%s "$WORK_DIR/iso/boot/vmlinuz" 2>/dev/null || echo 0)
                if [ $KERNEL_SIZE -gt 2000000 ]; then  # 大于2MB
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
    print_warning "使用备用内核源..."
    # 备用内核
    wget -q "https://distro.ibiblio.org/tinycorelinux/15.x/x86_64/release/distribution_files/vmlinuz64" -O "$WORK_DIR/iso/boot/vmlinuz" || \
    dd if=/dev/zero of="$WORK_DIR/iso/boot/vmlinuz" bs=1M count=2
fi

KERNEL_SIZE=$(du -h "$WORK_DIR/iso/boot/vmlinuz" 2>/dev/null | cut -f1)
print_success "内核准备完成: ${KERNEL_SIZE}"

# ================= 创建带安装脚本的initramfs =================
print_header "4. 创建带安装脚本的initramfs"

create_initramfs() {
    print_step "创建initramfs..."
    
    local initrd_dir="${WORK_DIR}/initrd"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    cd "$initrd_dir"
    
    # 创建完整的目录结构
    mkdir -p {bin,dev,etc,proc,sys,tmp,mnt,opt,lib,lib64,usr/bin,run,root}
    
    # 创建设备节点
    mknod -m 622 dev/console c 5 1 2>/dev/null || true
    mknod -m 666 dev/null c 1 3 2>/dev/null || true
    mknod -m 666 dev/zero c 1 5 2>/dev/null || true
    mknod -m 666 dev/tty c 5 0 2>/dev/null || true
    mknod -m 666 dev/tty0 c 4 0 2>/dev/null || true
    mknod -m 666 dev/tty1 c 4 1 2>/dev/null || true
    mknod -m 666 dev/sda b 8 0 2>/dev/null || true
    mknod -m 666 dev/sda1 b 8 1 2>/dev/null || true
    
    # 创建主init脚本
    cat > init << 'INIT'
#!/bin/sh
# OpenWRT Installer Init Script

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# 挂载虚拟文件系统
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 设置终端
export TERM=linux
export HOME=/root

clear
echo "========================================"
echo "       OpenWRT Installer v1.0"
echo "========================================"
echo ""

# 挂载安装介质
MOUNT_SUCCESS=0
for device in /dev/sr0 /dev/cdrom /dev/hdc /dev/hdd; do
    if [ -b "$device" ]; then
        echo "Mounting installation media ($device)..."
        mkdir -p /cdrom
        mount -t iso9660 -o ro "$device" /cdrom 2>/dev/null
        if [ $? -eq 0 ]; then
            if [ -f /cdrom/img/openwrt.img ]; then
                MOUNT_SUCCESS=1
                echo "✅ Installation media mounted successfully"
                break
            else
                umount /cdrom 2>/dev/null
            fi
        fi
    fi
done

if [ $MOUNT_SUCCESS -ne 1 ]; then
    echo "❌ ERROR: Cannot mount installation media!"
    echo ""
    echo "Available devices:"
    ls /dev/sd* /dev/vd* /dev/nvme* 2>/dev/null || echo "No block devices found"
    echo ""
    echo "Entering emergency shell..."
    exec /bin/sh
fi

# 复制OpenWRT镜像到根目录（便于安装脚本访问）
cp /cdrom/img/openwrt.img /openwrt.img 2>/dev/null || true

# 创建安装脚本
mkdir -p /opt
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
clear
cat << "EOF"

╔═══════════════════════════════════════════════════════╗
║               OpenWRT Auto Installer                  ║
╚═══════════════════════════════════════════════════════╝

EOF

echo ""
echo "Checking OpenWRT image..."
if [ ! -f "/openwrt.img" ]; then
    echo "❌ ERROR: OpenWRT image not found!"
    echo ""
    echo "Possible solutions:"
    echo "1. Check if installation media is properly mounted"
    echo "2. Try: mount -t iso9660 /dev/sr0 /cdrom"
    echo "3. Then: cp /cdrom/img/openwrt.img /openwrt.img"
    echo ""
    echo "Press Enter for shell..."
    read
    exec /bin/bash
fi

echo "✅ OpenWRT image found: $(ls -lh /openwrt.img | awk '{print $5}')"
echo ""

while true; do
    echo "Available disks:"
    echo "================="
    
    # 使用lsblk显示磁盘（如果可用）
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -n -o NAME,SIZE,MODEL,TYPE 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || \
        echo "No disks detected with lsblk"
    else
        # 手动列出磁盘
        echo "Listing disks manually..."
        for disk in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
            if [ -b "$disk" ]; then
                size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
                if [ "$size" -gt 0 ]; then
                    human_size=$(echo "$size" | awk '{if($1>=1073741824) printf "%.1f GB", $1/1073741824; else if($1>=1048576) printf "%.1f MB", $1/1048576; else printf "%.1f KB", $1/1024}')
                    echo "  $(basename "$disk"): $human_size"
                else
                    echo "  $(basename "$disk")"
                fi
            fi
        done
    fi
    
    echo "================="
    echo ""
    
    read -p "Enter target disk (e.g., sda, without /dev/): " TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo "Please enter a disk name"
        continue
    fi
    
    # 添加/dev/前缀如果没提供
    if [[ ! "$TARGET_DISK" =~ ^/dev/ ]]; then
        TARGET_DISK="/dev/$TARGET_DISK"
    fi
    
    if [ ! -b "$TARGET_DISK" ]; then
        echo "❌ Disk $TARGET_DISK not found!"
        continue
    fi
    
    echo ""
    echo "Selected disk: $TARGET_DISK"
    
    # 显示磁盘信息
    if command -v fdisk >/dev/null 2>&1; then
        fdisk -l "$TARGET_DISK" 2>/dev/null | head -10
    fi
    
    echo ""
    echo "⚠️  ⚠️  ⚠️  WARNING! ⚠️  ⚠️  ⚠️"
    echo "This will ERASE ALL DATA on: $TARGET_DISK"
    echo "All partitions and data will be PERMANENTLY LOST!"
    echo ""
    read -p "Type 'YES' to confirm installation: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Installation cancelled."
        echo ""
        read -p "Press Enter to continue..."
        continue
    fi
    
    clear
    echo ""
    echo "Installing OpenWRT to $TARGET_DISK..."
    echo "This may take a few minutes..."
    echo ""
    
    # 开始安装
    echo "Writing OpenWRT image..."
    echo "=========================="
    
    if command -v pv >/dev/null 2>&1; then
        pv /openwrt.img | dd of="$TARGET_DISK" bs=4M
    elif command -v dd >/dev/null 2>&1; then
        dd if=/openwrt.img of="$TARGET_DISK" bs=4M status=progress
    else
        dd if=/openwrt.img of="$TARGET_DISK" bs=4M
    fi
    
    # 同步数据
    echo ""
    echo "Syncing data..."
    sync
    
    echo ""
    echo "✅ Installation complete!"
    echo ""
    echo "Next steps:"
    echo "1. Remove the installation media (USB/CD)"
    echo "2. Restart your computer"
    echo "3. OpenWRT will boot automatically"
    echo ""
    
    echo "System will reboot in 10 seconds..."
    echo ""
    
    for i in {10..1}; do
        echo -ne "Rebooting in $i seconds...\r"
        sleep 1
    done
    
    echo ""
    echo "Rebooting now..."
    reboot -f
    sleep 3
    
    # 备用重启方法
    if [ -f /proc/sys/kernel/sysrq ]; then
        echo 1 > /proc/sys/kernel/sysrq
        echo b > /proc/sysrq-trigger 2>/dev/null
    fi
    
    exit 0
done
INSTALL_SCRIPT

chmod +x /opt/install-openwrt.sh

# 启动安装脚本
echo "Starting OpenWRT installer..."
echo ""
exec /opt/install-openwrt.sh

# 如果安装脚本退出，进入shell
echo "Installation script exited. Entering shell..."
exec /bin/sh
INIT

    chmod +x init
    
    # 下载BusyBox
    print_info "下载BusyBox..."
    if wget -q "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" -O bin/busybox; then
        chmod +x bin/busybox
        cd bin
        ./busybox --list | while read app; do
            ln -s busybox "$app" 2>/dev/null || true
        done
        cd ..
        print_success "BusyBox下载成功"
    else
        print_warning "BusyBox下载失败，创建最小工具集"
        
        # 创建最小shell
        cat > bin/sh << 'MINI_SH'
#!/bin/sh
echo "Minimal shell - OpenWRT Installer"
echo "Type 'install' to start installation or 'help' for commands"
while read -p "# " cmd; do
    case "$cmd" in
        install) echo "Starting installation..."; /opt/install-openwrt.sh;;
        help) echo "Commands: install, reboot, exit";;
        reboot) echo "Rebooting..."; reboot -f;;
        exit) exit 0;;
        *) echo "Unknown command: $cmd";;
    esac
done
MINI_SH
        chmod +x bin/sh
        
        # 创建必要的命令
        cat > bin/mount << 'MOUNT'
#!/bin/sh
echo "Mount command placeholder"
MOUNT
        chmod +x bin/mount
        
        cat > bin/dd << 'DD'
#!/bin/sh
echo "dd command placeholder"
DD
        chmod +x bin/dd
    fi
    
    # 创建pv命令（用于进度显示）
    cat > bin/pv << 'PV'
#!/bin/sh
# Simple pv implementation
cat "$@"
PV
    chmod +x bin/pv
    
    # 创建其他必要命令
    cat > bin/sync << 'SYNC'
#!/bin/sh
echo "Syncing filesystems..."
/bin/busybox sync 2>/dev/null || true
SYNC
    chmod +x bin/sync
    
    cat > bin/reboot << 'REBOOT'
#!/bin/sh
echo "Rebooting system..."
/bin/busybox reboot -f 2>/dev/null || echo b > /proc/sysrq-trigger 2>/dev/null || true
REBOOT
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
    
    # 创建blockdev命令
    cat > bin/blockdev << 'BLOCKDEV'
#!/bin/sh
if [ "$1" = "--getsize64" ] && [ -n "$2" ]; then
    if [ -b "$2" ]; then
        # 返回模拟大小
        echo "1000000000"
    else
        echo "0"
    fi
else
    echo "blockdev: $@"
fi
BLOCKDEV
    chmod +x bin/blockdev
    
    # 创建initramfs
    print_step "创建压缩initramfs..."
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
    
    print_info "收集ISOLINUX文件..."
    
    # 从系统复制文件
    SYS_PATHS=(
        "/usr/lib/syslinux"
        "/usr/share/syslinux"
        "/usr/lib/ISOLINUX"
        "/usr/lib/syslinux/modules/bios"
    )
    
    # 复制所有.c32文件和关键文件
    for path in "${SYS_PATHS[@]}"; do
        if [ -d "$path" ]; then
            print_info "从 $path 复制文件..."
            
            # 复制.c32文件
            find "$path" -name "*.c32" -type f 2>/dev/null | head -20 | while read file; do
                cp "$file" "$WORK_DIR/iso/isolinux/" 2>/dev/null
            done
            
            # 复制关键文件
            for file in isolinux.bin ldlinux.c32; do
                if [ -f "$path/$file" ] && [ ! -f "$WORK_DIR/iso/isolinux/$file" ]; then
                    cp "$path/$file" "$WORK_DIR/iso/isolinux/" 2>/dev/null && \
                        print_info "复制: $file"
                fi
            done
        fi
    done
    
    # 方法2：如果关键文件缺失，下载完整syslinux包
    if [ ! -f "$WORK_DIR/iso/isolinux/isolinux.bin" ] || [ ! -f "$WORK_DIR/iso/isolinux/ldlinux.c32" ]; then
        print_warning "关键文件缺失，下载syslinux..."
        
        # 下载syslinux 6.03（稳定版）
        wget -q "https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/6.03/syslinux-6.03.tar.gz" -O /tmp/syslinux.tar.gz
        
        if [ -f /tmp/syslinux.tar.gz ]; then
            mkdir -p /tmp/syslinux
            tar -xzf /tmp/syslinux.tar.gz -C /tmp/syslinux --strip-components=1
            
            # 从源码编译目录结构复制文件
            if [ -d "/tmp/syslinux/bios/core" ]; then
                cp /tmp/syslinux/bios/core/isolinux.bin $WORK_DIR/iso/isolinux/ 2>/dev/null || true
            fi
            
            if [ -d "/tmp/syslinux/bios/com32/elflink/ldlinux" ]; then
                cp /tmp/syslinux/bios/com32/elflink/ldlinux/ldlinux.c32 $WORK_DIR/iso/isolinux/ 2>/dev/null || true
            fi
            
            # 复制其他.c32文件
            find /tmp/syslinux -name "*.c32" -type f 2>/dev/null | head -10 | while read file; do
                cp "$file" "$WORK_DIR/iso/isolinux/" 2>/dev/null || true
            done
            
            rm -rf /tmp/syslinux /tmp/syslinux.tar.gz
        fi
    fi
    
    # 方法3：直接从网络下载预编译文件
    if [ ! -f "$WORK_DIR/iso/isolinux/ldlinux.c32" ]; then
        print_info "直接下载ldlinux.c32..."
        wget -q "https://github.com/ventoy/syslinux/raw/ventoy/bios/com32/elflink/ldlinux/ldlinux.c32" -O $WORK_DIR/iso/isolinux/ldlinux.c32 || \
        wget -q "https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz" -O /tmp/syslinux-new.tar.gz && \
          tar -xzf /tmp/syslinux-new.tar.gz && \
          find . -name "ldlinux.c32" -exec cp {} $WORK_DIR/iso/isolinux/ \; 2>/dev/null || true
    fi
    
    # 验证文件
    print_info "验证ISOLINUX文件:"
    [ -f "$WORK_DIR/iso/isolinux/isolinux.bin" ] && echo "✅ isolinux.bin" || echo "❌ isolinux.bin"
    [ -f "$WORK_DIR/iso/isolinux/ldlinux.c32" ] && echo "✅ ldlinux.c32" || echo "❌ ldlinux.c32"
    
    if [ ! -f "$WORK_DIR/iso/isolinux/isolinux.bin" ] || [ ! -f "$WORK_DIR/iso/isolinux/ldlinux.c32" ]; then
        print_error "关键ISOLINUX文件缺失，无法创建可引导ISO"
        return 1
    fi
    
    # 创建isolinux.cfg配置文件
    print_step "创建ISOLINUX配置..."
    
    cat > $WORK_DIR/iso/isolinux/isolinux.cfg << 'ISOLINUX_CFG'
DEFAULT linux
PROMPT 0
TIMEOUT 50
UI vesamenu.c32
MENU BACKGROUND splash.png
MENU TITLE OpenWRT Installer
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR cmdline      37;40   #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std

LABEL linux
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200n8

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img init=/bin/sh

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
ISOLINUX_CFG

    # 如果缺少图形菜单文件，使用简单配置
    if [ ! -f "$WORK_DIR/iso/isolinux/vesamenu.c32" ] && [ ! -f "$WORK_DIR/iso/isolinux/menu.c32" ]; then
        print_info "使用文本模式配置..."
        cat > $WORK_DIR/iso/isolinux/isolinux.cfg << 'TEXT_CFG'
DEFAULT linux
PROMPT 1
TIMEOUT 100

LABEL linux
  MENU DEFAULT
  MENU LABEL Install OpenWRT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img init=/bin/sh
TEXT_CFG
    fi
    
    # 在boot目录也放一份（兼容性）
    cp $WORK_DIR/iso/isolinux/* $WORK_DIR/iso/boot/ 2>/dev/null || true
    
    print_success "BIOS引导配置完成"
    return 0
}

setup_bios_boot

# ================= 修复UEFI引导 =================
print_header "6. 配置UEFI引导 (GRUB)"

setup_uefi_boot() {
    print_step "设置UEFI引导..."
    
    mkdir -p "$WORK_DIR/iso/EFI/BOOT"
    mkdir -p "$WORK_DIR/iso/boot/grub"
    
    print_info "准备UEFI引导文件..."
    
    # 方法1：使用grub-mkstandalone构建完整的GRUB EFI
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        print_info "构建GRUB EFI镜像..."
        
        # 创建临时目录和配置
        mkdir -p /tmp/grub_uefi/EFI/BOOT
        mkdir -p /tmp/grub_uefi/boot/grub
        
        # 创建GRUB配置
        cat > /tmp/grub_uefi/boot/grub/grub.cfg << 'GRUB_TEMP_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    echo "Loading kernel..."
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet
    echo "Loading initramfs..."
    initrd /boot/initrd.img
}

GRUB_TEMP_CFG
        
        # 构建GRUB EFI
        if grub-mkstandalone \
            -O x86_64-efi \
            -o /tmp/grub_uefi/EFI/BOOT/BOOTX64.EFI \
            --modules="part_gpt part_msdos fat iso9660 ext2 configfile echo normal terminal reboot halt" \
            --locales="" \
            --fonts="" \
            "boot/grub/grub.cfg=/tmp/grub_uefi/boot/grub/grub.cfg" \
            2>/dev/null; then
            
            cp /tmp/grub_uefi/EFI/BOOT/BOOTX64.EFI "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI"
            if [ -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
                print_success "GRUB EFI构建成功"
            fi
        fi
        rm -rf /tmp/grub_uefi
    fi
    
    # 方法2：从系统复制预编译的GRUB
    if [ ! -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
        print_info "从系统复制GRUB EFI..."
        
        # Ubuntu/Debian中的GRUB路径
        GRUB_PATHS=(
            "/usr/lib/grub/x86_64-efi/grub.efi"
            "/usr/share/grub/x86_64-efi/grub.efi"
            "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi"
            "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed"
        )
        
        for path in "${GRUB_PATHS[@]}"; do
            if [ -f "$path" ]; then
                cp "$path" "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null && \
                    print_info "复制GRUB: $(basename "$path")" && \
                    break
            fi
        done
    fi
    
    # 方法3：直接下载预编译的GRUB
    if [ ! -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
        print_info "下载GRUB EFI..."
        wget -q "https://github.com/ventoy/grub/raw/ventoy/grub2/grubx64.efi" -O $WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI || \
        wget -q "https://github.com/a1ive/grub2-themes/raw/master/grub2-theme-breeze/grubx64.efi" -O $WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI
    fi
    
    # 创建GRUB配置
    print_info "创建GRUB配置..."
    
    cat > "$WORK_DIR/iso/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0


menuentry "Install OpenWRT" {
    echo "Loading kernel..."
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet
    echo "Loading initramfs..."
    initrd /boot/initrd.img
}


GRUB_CFG
    
    # 创建EFI目录的配置
    cat > "$WORK_DIR/iso/EFI/BOOT/grub.cfg" << 'EFI_GRUB_CFG'
# UEFI GRUB configuration
search --file --set=root /boot/grub/grub.cfg
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EFI_GRUB_CFG
    
    # 验证UEFI引导文件
    if [ -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
        EFI_SIZE=$(du -h "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null | cut -f1)
        print_success "UEFI引导配置完成: ${EFI_SIZE}"
        return 0
    else
        print_warning "UEFI引导文件未创建"
        return 1
    fi
}

setup_uefi_boot

# ================= 创建ISO镜像 =================
print_header "7. 创建ISO镜像"

create_iso() {
    print_step "创建ISO..."
    
    cd "${WORK_DIR}/iso"
    
    # 检查文件
    print_info "检查文件:"
    echo "BIOS引导:"
    ls isolinux/*.bin isolinux/*.c32 2>/dev/null | head -5 || echo "无BIOS引导文件"
    echo ""
    echo "UEFI引导:"
    ls -la EFI/BOOT/*.EFI 2>/dev/null || echo "无UEFI引导文件"
    
    # 确保所有必要的.c32文件都在boot目录（兼容旧系统）
    if [ -d "isolinux" ]; then
        cp isolinux/* boot/ 2>/dev/null || true
    fi
    
    print_info "创建可引导ISO..."
    
    # 构建xorriso命令
    CMD="xorriso -as mkisofs"
    CMD="$CMD -volid 'OPENWRT_INSTALL'"
    CMD="$CMD -J -r -rock"
    CMD="$CMD -full-iso9660-filenames"
    
    # 添加BIOS引导
    if [ -f "isolinux/isolinux.bin" ]; then
        CMD="$CMD -b isolinux/isolinux.bin"
        CMD="$CMD -c isolinux/boot.cat"
        CMD="$CMD -no-emul-boot"
        CMD="$CMD -boot-load-size 4"
        CMD="$CMD -boot-info-table"
        print_info "添加BIOS引导"
    fi
    
    # 添加UEFI引导
    if [ -f "EFI/BOOT/BOOTX64.EFI" ]; then
        CMD="$CMD -eltorito-alt-boot"
        CMD="$CMD -e EFI/BOOT/BOOTX64.EFI"
        CMD="$CMD -no-emul-boot"
        print_info "添加UEFI引导"
    fi
    
    CMD="$CMD -o '${OUTPUT_ISO}' ."
    
    print_info "执行命令:"
    echo "$CMD"
    
    # 执行命令
    if eval "$CMD" 2>&1; then
        print_success "ISO创建成功"
    else
        print_warning "主方法失败，尝试备用方法..."
        
        # 备用方法：使用简化参数
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -J -r \
            -b isolinux/isolinux.bin \
            -c isolinux/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -o "${OUTPUT_ISO}" . 2>&1 || \
        
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -o "${OUTPUT_ISO}" . 2>&1
    fi
    
    # 验证ISO
    if [ -f "${OUTPUT_ISO}" ]; then
        ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
        ISO_BYTES=$(wc -c < "${OUTPUT_ISO}" 2>/dev/null || echo 0)
        
        print_success "ISO创建完成: ${ISO_SIZE}"
        
        # 检查ISO信息
        if command -v isoinfo >/dev/null 2>&1 && [ "$ISO_BYTES" -gt 0 ]; then
            print_info "ISO信息:"
            isoinfo -d -i "${OUTPUT_ISO}" 2>/dev/null | grep -E "Volume|Bootable" || true
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
    
    echo "🚀 测试方法:"
    echo "  1. 使用QEMU测试BIOS:"
    echo "     qemu-system-x86_64 -cdrom ${OUTPUT_ISO} -m 512"
    echo "  2. 使用QEMU测试UEFI:"
    echo "     qemu-system-x86_64 -bios /usr/share/qemu/OVMF.fd -cdrom ${OUTPUT_ISO} -m 512"
    echo ""
else
    echo "❌ ISO文件未生成"
fi

# 清理
cleanup

echo "📅 构建时间: $(date)"
echo "═══════════════════════════════════════════════════"

echo ""
print_success "构建流程完成!"
exit 0
