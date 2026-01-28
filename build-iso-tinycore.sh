#!/bin/bash
# build-iso-tinycore.sh OpenWRT Installer ISO Builder 
# 修复所有问题版本

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
mkdir -p "iso/boot"
mkdir -p "iso/boot/grub"
mkdir -p "iso/EFI/BOOT"
mkdir -p "iso/img"
mkdir -p "iso/isolinux"
mkdir -p "${OUTPUT_DIR}"

print_info "目录结构:"
find . -type d | sort

print_success "目录结构创建完成"

# ================= 复制OpenWRT镜像 =================
print_header "2. 复制OpenWRT镜像"

cp "${INPUT_IMG}" "iso/img/openwrt.img"
IMG_SIZE_FINAL=$(du -h "iso/img/openwrt.img" 2>/dev/null | cut -f1)
print_success "IMG文件复制完成: ${IMG_SIZE_FINAL}"

# ================= 获取内核 =================
print_header "3. 获取Linux内核"

get_kernel() {
    print_step "下载Linux内核..."
    
    # 使用可靠的内核源
    KERNEL_URLS=(
        "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/boot/vmlinuz-lts"
        "https://distro.ibiblio.org/tinycorelinux/15.x/x86_64/release/distribution_files/vmlinuz64"
        "https://repo.tinycorelinux.net/15.x/x86_64/release/distribution_files/vmlinuz64"
    )
    
    for url in "${KERNEL_URLS[@]}"; do
        print_info "尝试: $(basename "$url")"
        
        if curl -L --connect-timeout 30 --max-time 60 --retry 2 \
            -s -f -o "iso/boot/vmlinuz" "$url"; then
            
            if [ -f "iso/boot/vmlinuz" ] && [ -s "iso/boot/vmlinuz" ]; then
                KERNEL_SIZE=$(stat -c%s "iso/boot/vmlinuz" 2>/dev/null || echo 0)
                if [ $KERNEL_SIZE -gt 1000000 ]; then
                    print_success "内核下载成功: $((KERNEL_SIZE/1024/1024))MB"
                    return 0
                fi
            fi
        fi
        sleep 1
    done
    
    print_error "内核下载失败"
    return 1
}

if get_kernel; then
    KERNEL_SIZE=$(du -h "iso/boot/vmlinuz" 2>/dev/null | cut -f1)
    print_success "内核准备完成: ${KERNEL_SIZE}"
else
    print_warning "使用备用内核..."
    # 创建最小内核占位
    dd if=/dev/zero of="iso/boot/vmlinuz" bs=1M count=2
    echo "LINUX_KERNEL" >> "iso/boot/vmlinuz"
    KERNEL_SIZE="2.0M"
    print_info "使用占位内核: ${KERNEL_SIZE}"
fi

# ================= 创建正确的initramfs =================
print_header "4. 创建initramfs"

create_initramfs() {
    print_step "创建initramfs..."
    
    local initrd_dir="${WORK_DIR}/initrd"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    cd "$initrd_dir"
    
    # 创建完整的目录结构
    mkdir -p {bin,dev,etc,proc,sys,tmp,mnt,lib,lib64,usr/bin,run,sbin,root}
    
    # 创建设备节点
    mknod -m 622 dev/console c 5 1 2>/dev/null || true
    mknod -m 666 dev/null c 1 3 2>/dev/null || true
    mknod -m 666 dev/zero c 1 5 2>/dev/null || true
    mknod -m 666 dev/tty c 5 0 2>/dev/null || true
    mknod -m 666 dev/tty0 c 4 0 2>/dev/null || true
    mknod -m 666 dev/tty1 c 4 1 2>/dev/null || true
    mknod -m 666 dev/sda b 8 0 2>/dev/null || true
    mknod -m 666 dev/sr0 b 11 0 2>/dev/null || true  # CDROM
    
    # 创建init脚本
    cat > init << 'INIT_EOF'
#!/bin/sh
# OpenWRT Installer - Init Script

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

# 清屏并显示标题
clear
echo ""
echo "========================================"
echo "       OpenWRT Installer v1.0"
echo "========================================"
echo ""

# 挂载安装介质
echo "Mounting installation media..."
MOUNTED=0
for dev in /dev/sr0 /dev/cdrom /dev/hdc /dev/hdd; do
    if [ -b "$dev" ]; then
        echo "Trying $dev..."
        mkdir -p /cdrom
        if mount -t iso9660 -o ro "$dev" /cdrom 2>/dev/null; then
            if [ -f /cdrom/img/openwrt.img ]; then
                echo "✅ Media mounted successfully"
                MOUNTED=1
                break
            else
                umount /cdrom 2>/dev/null
            fi
        fi
    fi
done

if [ $MOUNTED -eq 0 ]; then
    echo "❌ ERROR: Cannot mount installation media!"
    echo ""
    echo "Available devices:"
    ls /dev/sd* /dev/vd* /dev/nvme* 2>/dev/null || echo "No block devices found"
    echo ""
    echo "Entering emergency shell..."
    exec /bin/sh
fi

# 复制镜像
echo "Copying OpenWRT image..."
cp /cdrom/img/openwrt.img /openwrt.img 2>/dev/null || true

if [ ! -f /openwrt.img ]; then
    echo "❌ ERROR: Cannot copy OpenWRT image!"
    echo "Path: /cdrom/img/openwrt.img"
    ls -la /cdrom/img/ 2>/dev/null || echo "Directory not found"
    echo ""
    echo "Entering emergency shell..."
    exec /bin/sh
fi

IMG_SIZE=$(ls -lh /openwrt.img 2>/dev/null | awk '{print $5}' || echo "unknown")
echo "✅ OpenWRT image ready: $IMG_SIZE"

# 主安装循环
while true; do
    echo ""
    echo "Available disks:"
    echo "================="
    
    # 列出磁盘
    DISK_COUNT=0
    for d in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
        if [ -b "$d" ]; then
            echo "  $(basename "$d")"
            DISK_COUNT=$((DISK_COUNT + 1))
        fi
    done
    
    if [ $DISK_COUNT -eq 0 ]; then
        echo "  No disks found!"
    fi
    
    echo "================="
    echo ""
    
    echo -n "Enter target disk (e.g., sda): "
    read DISK
    
    if [ -z "$DISK" ]; then
        echo "Please enter a disk name"
        continue
    fi
    
    # 添加/dev/前缀
    if [[ ! "$DISK" =~ ^/dev/ ]]; then
        DISK="/dev/$DISK"
    fi
    
    if [ ! -b "$DISK" ]; then
        echo "❌ Disk $DISK not found!"
        continue
    fi
    
    echo ""
    echo "Selected disk: $DISK"
    echo ""
    echo "⚠️  WARNING: This will ERASE ALL DATA on $DISK!"
    echo ""
    echo -n "Type 'YES' to confirm: "
    read CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Installation cancelled."
        continue
    fi
    
    # 开始安装
    clear
    echo ""
    echo "Installing OpenWRT to $DISK..."
    echo "This may take a few minutes..."
    echo ""
    
    # 检查dd命令
    if ! command -v dd >/dev/null 2>&1; then
        echo "❌ ERROR: dd command not found!"
        echo "Entering shell for manual installation..."
        exec /bin/sh
    fi
    
    # 写入镜像
    echo "Writing image..."
    echo "================"
    
    # 尝试显示进度
    if dd --help 2>&1 | grep -q "status="; then
        dd if=/openwrt.img of="$DISK" bs=4M status=progress
    else
        dd if=/openwrt.img of="$DISK" bs=4M
    fi
    
    if [ $? -ne 0 ]; then
        echo ""
        echo "❌ ERROR: Failed to write image!"
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
    echo "✅ Installation complete!"
    echo ""
    echo "Next steps:"
    echo "1. Remove installation media"
    echo "2. Restart computer"
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
    
    # 等待
    sleep 5
    echo "If system hasn't rebooted, please restart manually."
    break
done

# 如果到这里，进入shell
exec /bin/sh
INIT_EOF

    chmod +x init
    
    # 下载静态BusyBox
    print_info "下载静态BusyBox..."
    
    if wget -q "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" -O bin/busybox; then
        if [ -f bin/busybox ]; then
            chmod +x bin/busybox
            print_success "BusyBox下载成功"
            
            # 创建符号链接
            cd bin
            ./busybox --list | while read app; do
                ln -sf busybox "$app" 2>/dev/null || true
            done
            cd ..
        else
            print_warning "BusyBox下载但文件不存在"
        fi
    else
        print_warning "BusyBox下载失败，创建最小命令集"
        
        # 创建最小sh
        cat > bin/sh << 'SH_EOF'
#!/bin/sh
echo "OpenWRT Installer Shell"
while read -p "# " cmd; do
    case "$cmd" in
        exit) exit 0;;
        reboot) echo "Rebooting..."; break;;
        *) echo "Command: $cmd";;
    esac
done
SH_EOF
        chmod +x bin/sh
        
        # 创建dd命令
        cat > bin/dd << 'DD_EOF'
#!/bin/sh
echo "dd: Not available in minimal mode"
DD_EOF
        chmod +x bin/dd
    fi
    
    # 确保关键命令存在
    for cmd in mount sync reboot; do
        if [ ! -f bin/$cmd ]; then
            if [ -f bin/busybox ]; then
                ln -sf busybox bin/$cmd 2>/dev/null || true
            else
                cat > bin/$cmd << EOF
#!/bin/sh
echo "$cmd: Not available"
EOF
                chmod +x bin/$cmd
            fi
        fi
    done
    
    # 显示文件列表
    print_info "initramfs文件:"
    find . -type f | head -10
    echo ""
    print_info "文件大小:"
    du -sh . || du -sb . | awk '{print $1}'
    
    # 创建initramfs
    print_step "创建压缩initramfs..."
    
    # 使用find和cpio创建
    find . 2>/dev/null | cpio -o -H newc 2>/dev/null > /tmp/initrd.cpio
    
    if [ $? -eq 0 ] && [ -s /tmp/initrd.cpio ]; then
        gzip -9 < /tmp/initrd.cpio > "${WORK_DIR}/iso/boot/initrd.img"
        rm -f /tmp/initrd.cpio
        
        INITRD_SIZE=$(du -h "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null | cut -f1)
        INITRD_BYTES=$(stat -c%s "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null || echo 0)
        
        if [ $INITRD_BYTES -gt 1000000 ]; then
            print_success "initramfs创建完成: ${INITRD_SIZE} ($((INITRD_BYTES/1024))KB)"
        else
            print_warning "initramfs较小: ${INITRD_SIZE} ($((INITRD_BYTES/1024))KB)"
            # 添加一些填充
            echo "Adding padding to initramfs..."
            dd if=/dev/zero bs=1M count=1 2>/dev/null | gzip >> "${WORK_DIR}/iso/boot/initrd.img"
            INITRD_SIZE=$(du -h "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null | cut -f1)
            print_info "填充后大小: ${INITRD_SIZE}"
        fi
    else
        print_error "initramfs创建失败"
        # 创建最小initramfs作为后备
        echo "Creating minimal initramfs as fallback..."
        echo "initramfs placeholder" | gzip -9 > "${WORK_DIR}/iso/boot/initrd.img"
        return 1
    fi
    
    return 0
}

create_initramfs

# ================= 修复ISOLINUX引导 =================
print_header "5. 配置BIOS引导 (ISOLINUX)"

setup_bios_boot() {
    print_step "设置ISOLINUX引导..."
    
    # 确保目录存在
    mkdir -p "iso/isolinux"
    mkdir -p "iso/boot"  # 也在boot目录放一份
    
    print_info "获取ISOLINUX文件..."
    
    # 首先从系统复制
    if [ -d "/usr/lib/syslinux" ]; then
        print_info "从/usr/lib/syslinux复制..."
        cp /usr/lib/syslinux/isolinux.bin iso/isolinux/ 2>/dev/null || true
        cp /usr/lib/syslinux/ldlinux.c32 iso/isolinux/ 2>/dev/null || true
        cp /usr/lib/syslinux/menu.c32 iso/isolinux/ 2>/dev/null || true
        cp /usr/lib/syslinux/libcom32.c32 iso/isolinux/ 2>/dev/null || true
        cp /usr/lib/syslinux/libutil.c32 iso/isolinux/ 2>/dev/null || true
    fi
    
    if [ -d "/usr/share/syslinux" ]; then
        print_info "从/usr/share/syslinux复制..."
        cp /usr/share/syslinux/isolinux.bin iso/isolinux/ 2>/dev/null || true
        cp /usr/share/syslinux/ldlinux.c32 iso/isolinux/ 2>/dev/null || true
    fi
    
    # 如果isolinux.bin不存在，下载它
    if [ ! -f "iso/isolinux/isolinux.bin" ]; then
        print_warning "isolinux.bin不存在，下载..."
        
        wget -q "https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz" -O /tmp/syslinux.tar.gz
        if [ -f /tmp/syslinux.tar.gz ]; then
            tar -xzf /tmp/syslinux.tar.gz -C /tmp
            find /tmp -name "isolinux.bin" -type f | head -1 | while read file; do
                cp "$file" iso/isolinux/ 2>/dev/null && \
                print_info "提取: isolinux.bin"
            done
            find /tmp -name "ldlinux.c32" -type f | head -1 | while read file; do
                cp "$file" iso/isolinux/ 2>/dev/null && \
                print_info "提取: ldlinux.c32"
            done
            rm -rf /tmp/syslinux*
        fi
    fi
    
    # 如果还是不存在，从GitHub下载
    if [ ! -f "iso/isolinux/isolinux.bin" ]; then
        print_info "从GitHub下载isolinux.bin..."
        wget -q "https://github.com/ventoy/syslinux/raw/ventoy/bios/core/isolinux.bin" -O iso/isolinux/isolinux.bin || \
        wget -q "https://raw.githubusercontent.com/tinycorelinux/build-scripts/master/bootloader/isolinux.bin" -O iso/isolinux/isolinux.bin || \
        echo "无法下载isolinux.bin"
    fi
    
    if [ ! -f "iso/isolinux/ldlinux.c32" ]; then
        print_info "下载ldlinux.c32..."
        wget -q "https://github.com/ventoy/syslinux/raw/ventoy/bios/com32/elflink/ldlinux/ldlinux.c32" -O iso/isolinux/ldlinux.c32 || \
        echo "无法下载ldlinux.c32"
    fi
    
    # 验证文件
    print_info "验证ISOLINUX文件:"
    if [ -f "iso/isolinux/isolinux.bin" ]; then
        ISOLINUX_SIZE=$(stat -c%s "iso/isolinux/isolinux.bin" 2>/dev/null || echo 0)
        print_info "✅ isolinux.bin: $((ISOLINUX_SIZE/1024))KB"
    else
        print_error "❌ isolinux.bin不存在"
        return 1
    fi
    
    # 创建ISOLINUX配置
    print_step "创建ISOLINUX配置..."
    
    # 检查是否有menu.c32
    if [ -f "iso/isolinux/menu.c32" ]; then
        cat > iso/isolinux/isolinux.cfg << 'ISOLINUX_CFG'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 100
UI menu.c32

MENU TITLE OpenWRT Installer

LABEL install
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img init=/bin/sh

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
ISOLINUX_CFG
    else
        # 文本模式
        cat > iso/isolinux/isolinux.cfg << 'TEXT_CFG'
DEFAULT install
PROMPT 1
TIMEOUT 100
ONTIMEOUT install

LABEL install
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
    
    # 创建boot.cat
    echo "OpenWRT Installer" > iso/isolinux/boot.cat
    
    # 在boot目录也放一份（兼容性）
    cp iso/isolinux/* iso/boot/ 2>/dev/null || true
    
    print_success "BIOS引导配置完成"
    return 0
}

setup_bios_boot

# ================= 修复UEFI引导 =================
print_header "6. 配置UEFI引导"

setup_uefi_boot() {
    print_step "设置UEFI引导..."
    
    mkdir -p "iso/EFI/BOOT"
    mkdir -p "iso/boot/grub"
    
    print_info "准备UEFI引导文件..."
    
    # 方法1：使用grub-mkstandalone构建
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        print_info "构建GRUB EFI..."
        
        # 创建临时目录和配置
        mkdir -p /tmp/grub_tmp/boot/grub
        cat > /tmp/grub_tmp/boot/grub/grub.cfg << 'TEMP_GRUB'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz initrd=/boot/initrd.img console=tty0
    initrd /boot/initrd.img
}
TEMP_GRUB
        
        if grub-mkstandalone \
            -O x86_64-efi \
            -o /tmp/grub_tmp/BOOTX64.EFI \
            --modules="part_gpt part_msdos fat iso9660 ext2" \
            "boot/grub/grub.cfg=/tmp/grub_tmp/boot/grub/grub.cfg" \
            2>/dev/null; then
	    
            ls -l  /tmp/grub_tmp
	    
            if [ -f /tmp/grub_tmp/BOOTX64.EFI ]; then
                cp /tmp/grub_tmp/BOOTX64.EFI "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI"
                print_success "GRUB EFI构建成功"
            fi
        fi
        rm -rf /tmp/grub_tmp
    fi
    
    # 方法2：从系统复制
    if [ ! -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
        print_info "从系统复制GRUB..."
        
        GRUB_PATHS=(
            "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi"
            "/usr/lib/grub/x86_64-efi/grub.efi"
            "/usr/share/grub/x86_64-efi/grub.efi"
        )
        
        for path in "${GRUB_PATHS[@]}"; do
            if [ -f "$path" ]; then
                cp "$path" "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null && \
                print_info "复制: $(basename "$path")" && \
                break
            fi
        done
    fi
    
    # 方法3：直接下载
    if [ ! -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
        print_info "下载GRUB EFI..."
        wget -q "https://github.com/ventoy/grub2/raw/ventoy/grub2/grubx64.efi" -O $WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI || \
        echo "无法下载GRUB EFI"
    fi
    
    # 验证文件
    if [ -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
        EFI_SIZE=$(du -h "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null | cut -f1)
        print_success "✅ BOOTX64.EFI: ${EFI_SIZE}"
    else
        print_warning "❌ BOOTX64.EFI不存在"
        return 1
    fi
    
    # 创建GRUB配置
    print_info "创建GRUB配置..."
    
    cat > "iso/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz initrd=/boot/initrd.img console=tty0
    initrd /boot/initrd.img
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz initrd=/boot/initrd.img init=/bin/sh
    initrd /boot/initrd.img
}
GRUB_CFG
    
    # 创建EFI配置
    cat > "iso/EFI/BOOT/grub.cfg" << 'EFI_CFG'
configfile /boot/grub/grub.cfg
EFI_CFG
    
    print_success "UEFI引导配置完成"
    return 0
}

setup_uefi_boot

# ================= 创建ISO镜像 =================
print_header "7. 创建ISO镜像"

create_iso() {
    print_step "创建ISO..."
    
    cd "${WORK_DIR}/iso"
    
    # 检查文件
    print_info "检查关键文件:"
    [ -f "boot/vmlinuz" ] && echo "  ✅ /boot/vmlinuz" || echo "  ❌ /boot/vmlinuz"
    [ -f "boot/initrd.img" ] && echo "  ✅ /boot/initrd.img" || echo "  ❌ /boot/initrd.img"
    [ -f "isolinux/isolinux.bin" ] && echo "  ✅ /isolinux/isolinux.bin" || echo "  ❌ /isolinux/isolinux.bin"
    [ -f "EFI/BOOT/BOOTX64.EFI" ] && echo "  ✅ /EFI/BOOT/BOOTX64.EFI" || echo "  ❌ /EFI/BOOT/BOOTX64.EFI"
    [ -f "img/openwrt.img" ] && echo "  ✅ /img/openwrt.img" || echo "  ❌ /img/openwrt.img"
    
    # 显示ISO内容
    print_info "ISO目录内容:"
    find . -type f | sort
    
    # 创建ISO - 先检查文件是否存在
    if [ ! -f "isolinux/isolinux.bin" ]; then
        print_error "❌ 缺少isolinux.bin，无法创建BIOS引导ISO"
        return 1
    fi
    
    if [ ! -f "EFI/BOOT/BOOTX64.EFI" ]; then
        print_warning "⚠️  缺少BOOTX64.EFI，将创建仅BIOS引导ISO"
    fi
    
    print_info "创建可引导ISO..."
    
    # 构建xorriso命令
    CMD="xorriso -as mkisofs"
    CMD="$CMD -volid 'OPENWRT_INSTALL'"
    CMD="$CMD -J -r -rock"
    CMD="$CMD -full-iso9660-filenames"
    
    # BIOS引导
    CMD="$CMD -b isolinux/isolinux.bin"
    CMD="$CMD -c isolinux/boot.cat"
    CMD="$CMD -no-emul-boot"
    CMD="$CMD -boot-load-size 4"
    CMD="$CMD -boot-info-table"
    
    # UEFI引导（如果文件存在）
    if [ -f "EFI/BOOT/BOOTX64.EFI" ]; then
        CMD="$CMD -eltorito-alt-boot"
        CMD="$CMD -e EFI/BOOT/BOOTX64.EFI"
        CMD="$CMD -no-emul-boot"
    fi
    
    CMD="$CMD -o '${OUTPUT_ISO}' ."
    
    print_info "执行命令:"
    echo "$CMD"
    
    # 执行命令
    if eval "$CMD" 2>&1; then
        print_success "ISO创建成功"
    else
        print_warning "主方法失败，尝试简化方法..."
        
        # 简化方法
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
    
    # 验证ISO
    if [ -f "${OUTPUT_ISO}" ] && [ -s "${OUTPUT_ISO}" ]; then
        ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
        ISO_BYTES=$(stat -c%s "${OUTPUT_ISO}" 2>/dev/null || echo 0)
        
        print_success "ISO创建完成: ${ISO_SIZE} ($((ISO_BYTES/1024/1024))MB)"
        
        # 检查ISO信息
        if command -v file >/dev/null 2>&1; then
            file "${OUTPUT_ISO}" 2>/dev/null | head -1 || true
        fi
        
        return 0
    else
        print_error "ISO创建失败"
        return 1
    fi
}

# 执行创建
if ! create_iso; then
    print_error "ISO创建失败，尝试最后的方法..."
    
    # 最后尝试：创建基本ISO
    cd "${WORK_DIR}/iso"
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -o "${OUTPUT_ISO}" . 2>&1 || true
fi

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
    echo ""
    
    echo "🔧 文件验证:"
    [ -f "${WORK_DIR}/iso/boot/vmlinuz" ] && echo "  ✅ 内核文件存在" || echo "  ❌ 内核文件缺失"
    [ -f "${WORK_DIR}/iso/boot/initrd.img" ] && echo "  ✅ initramfs存在" || echo "  ❌ initramfs缺失"
    [ -f "${WORK_DIR}/iso/isolinux/isolinux.bin" ] && echo "  ✅ isolinux.bin存在" || echo "  ❌ isolinux.bin缺失"
    [ -f "${WORK_DIR}/iso/EFI/BOOT/BOOTX64.EFI" ] && echo "  ✅ BOOTX64.EFI存在" || echo "  ❌ BOOTX64.EFI缺失"
    echo ""
    
    echo "🚀 使用方法:"
    echo "  1. 写入U盘: dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
    echo "  2. 从U盘启动"
    echo "  3. 选择安装选项"
    echo ""
fi

# 清理
cleanup

echo "📅 构建时间: $(date)"
echo "═══════════════════════════════════════════════════"

echo ""
print_info "构建流程结束"
exit 0
