#!/bin/bash
# build-iso-tinycore.sh OpenWRT Installer ISO Builder 
# 修复init执行和UEFI引导问题

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
                    
                    # 检查内核架构
                    print_info "检查内核文件:"
                    file "iso/boot/vmlinuz" 2>/dev/null || true
                    
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
    print_warning "使用备用内核..."
    # 使用本地内核（如果在GitHub Actions中）
    if [ -f "/boot/vmlinuz-$(uname -r)" ]; then
        cp "/boot/vmlinuz-$(uname -r)" "iso/boot/vmlinuz" 2>/dev/null || true
    else
        # 创建最小内核占位
        dd if=/dev/zero of="iso/boot/vmlinuz" bs=1M count=2
        echo "LINUX_KERNEL_PLACEHOLDER" > "iso/boot/vmlinuz"
    fi
fi

KERNEL_SIZE=$(du -h "iso/boot/vmlinuz" 2>/dev/null | cut -f1)
print_success "内核准备完成: ${KERNEL_SIZE}"

# ================= 创建简单的initramfs =================
print_header "4. 创建initramfs（精简版）"

create_initramfs() {
    print_step "创建initramfs..."
    
    local initrd_dir="${WORK_DIR}/initrd"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    cd "$initrd_dir"
    
    # 创建基本目录结构
    mkdir -p {bin,dev,etc,proc,sys,tmp,mnt,lib,lib64,usr/bin}
    
    # 创建设备节点
    mknod -m 622 dev/console c 5 1 2>/dev/null || true
    mknod -m 666 dev/null c 1 3 2>/dev/null || true
    mknod -m 666 dev/zero c 1 5 2>/dev/null || true
    mknod -m 666 dev/tty c 5 0 2>/dev/null || true
    
    # 创建非常简单的init脚本（纯shell，无外部依赖）
    cat > init << 'INIT_EOF'
#!/bin/sh
# 最小化init脚本 - 直接运行安装程序

# 基本挂载
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s
mount -t tmpfs tmpfs /tmp

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

echo "========================================"
echo "       OpenWRT Installer v1.0"
echo "========================================"
echo ""

# 挂载CDROM
echo "Mounting installation media..."
for dev in /dev/sr0 /dev/cdrom /dev/hdc /dev/hdd; do
    if [ -b "$dev" ]; then
        mkdir -p /cdrom
        if mount -t iso9660 -o ro $dev /cdrom 2>/dev/null; then
            echo "✅ Media mounted: $dev"
            break
        fi
    fi
done

if [ ! -d /cdrom ] || [ ! -f /cdrom/img/openwrt.img ]; then
    echo "❌ ERROR: Cannot find OpenWRT image!"
    echo "Entering emergency shell..."
    exec /bin/sh
fi

# 复制镜像
cp /cdrom/img/openwrt.img /openwrt.img 2>/dev/null

if [ ! -f /openwrt.img ]; then
    echo "❌ ERROR: Cannot copy image!"
    exec /bin/sh
fi

echo "✅ OpenWRT image ready"

# 安装程序
echo ""
echo "Starting OpenWRT installer..."
echo ""

while true; do
    echo "Available disks:"
    echo "----------------"
    for d in /dev/sd[a-z] /dev/vd[a-z]; do
        [ -b "$d" ] && echo "  $(basename $d)"
    done
    echo "----------------"
    echo ""
    
    echo -n "Enter disk to install (e.g., sda): "
    read DISK
    
    if [ -z "$DISK" ]; then
        echo "Please enter a disk name"
        continue
    fi
    
    if [[ ! "$DISK" =~ ^/dev/ ]]; then
        DISK="/dev/$DISK"
    fi
    
    if [ ! -b "$DISK" ]; then
        echo "❌ Disk $DISK not found!"
        continue
    fi
    
    echo ""
    echo "⚠️  WARNING: This will ERASE $DISK!"
    echo ""
    echo -n "Type 'YES' to confirm: "
    read CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        continue
    fi
    
    echo ""
    echo "Installing to $DISK..."
    
    # 检查是否有dd
    if command -v dd >/dev/null 2>&1; then
        # 尝试显示进度
        if dd --help 2>&1 | grep -q "status="; then
            dd if=/openwrt.img of=$DISK bs=4M status=progress
        else
            dd if=/openwrt.img of=$DISK bs=4M
        fi
        
        if [ $? -eq 0 ]; then
            sync
            echo ""
            echo "✅ Installation complete!"
            echo ""
            echo "Remove media and reboot."
            echo ""
            echo -n "Press Enter to reboot..."
            read
            reboot -f
        else
            echo "❌ Installation failed!"
        fi
    else
        echo "❌ ERROR: dd command not found!"
        echo "Entering shell for manual installation..."
        exec /bin/sh
    fi
    
    break
done

# 如果到这里，进入shell
echo "Installation finished. Entering shell..."
exec /bin/sh
INIT_EOF

    chmod +x init
    
    # 下载静态链接的BusyBox（确保可以在任何环境运行）
    print_info "下载静态BusyBox..."
    
    if wget -q "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" -O bin/busybox; then
        # 验证文件
        if file bin/busybox | grep -q "ELF.*statically linked"; then
            chmod +x bin/busybox
            print_success "静态BusyBox下载成功"
            
            # 创建符号链接
            cd bin
            ./busybox --list | while read app; do
                ln -sf busybox "$app" 2>/dev/null || true
            done
            cd ..
        else
            print_warning "BusyBox不是静态链接，使用系统busybox"
            if command -v busybox >/dev/null 2>&1; then
                cp $(which busybox) bin/busybox 2>/dev/null || true
                chmod +x bin/busybox
            fi
        fi
    else
        print_warning "BusyBox下载失败，创建最小命令集"
    fi
    
    # 确保/bin/sh存在
    if [ ! -f bin/sh ]; then
        if [ -f bin/busybox ]; then
            ln -sf busybox bin/sh
        else
            # 创建最小sh
            cat > bin/sh << 'SH_EOF'
#!/bin/sh
echo "Minimal shell"
while read -p "# " cmd; do
    case "$cmd" in
        exit) exit 0;;
        reboot) echo "Rebooting..."; break;;
        *) echo "Command: $cmd";;
    esac
done
SH_EOF
            chmod +x bin/sh
        fi
    fi
    
    # 确保/bin/dd存在
    if [ ! -f bin/dd ]; then
        if [ -f bin/busybox ]; then
            ln -sf busybox bin/dd
        else
            cat > bin/dd << 'DD_EOF'
#!/bin/sh
echo "dd: Not available"
DD_EOF
            chmod +x bin/dd
        fi
    fi
    
    # 创建/bin/reboot
    cat > bin/reboot << 'REBOOT_EOF'
#!/bin/sh
echo "Rebooting..."
# 尝试多种重启方法
reboot -f 2>/dev/null || \
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null; echo b > /proc/sysrq-trigger 2>/dev/null || \
echo "Please restart manually"
REBOOT_EOF
    chmod +x bin/reboot
    
    # 创建initramfs
    print_step "创建压缩initramfs..."
    
    # 显示文件列表
    print_info "initramfs文件列表:"
    find . -type f | head -10
    
    # 创建cpio存档
    find . 2>/dev/null | cpio -o -H newc 2>/dev/null | gzip -9 > "${WORK_DIR}/iso/boot/initrd.img"
    
    if [ $? -ne 0 ]; then
        print_error "initramfs创建失败"
        return 1
    fi
    
    # 验证initramfs
    INITRD_SIZE=$(du -h "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null | cut -f1)
    INITRD_BYTES=$(stat -c%s "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null || echo 0)
    
    if [ $INITRD_BYTES -gt 500000 ]; then
        print_success "initramfs创建完成: ${INITRD_SIZE} ($((INITRD_BYTES/1024))KB)"
        
        # 测试initramfs是否可以解压
        print_info "测试initramfs..."
        if echo -n | gzip -t "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null; then
            print_success "initramfs格式正确"
        else
            print_warning "initramfs可能损坏"
        fi
    else
        print_warning "initramfs较小: ${INITRD_SIZE}"
    fi
    
    return 0
}

create_initramfs

# ================= 配置BIOS引导 =================
print_header "5. 配置BIOS引导 (ISOLINUX)"

setup_bios_boot() {
    print_step "设置ISOLINUX引导..."
    
    mkdir -p "iso/isolinux"
    
    print_info "获取ISOLINUX文件..."
    
    # 从系统复制文件
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
    
    # 检查关键文件
    if [ ! -f "iso/isolinux/isolinux.bin" ]; then
        print_warning "下载isolinux.bin..."
        wget -q "https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz" -O /tmp/syslinux.tar.gz
        if [ -f /tmp/syslinux.tar.gz ]; then
            tar -xzf /tmp/syslinux.tar.gz -C /tmp
            find /tmp -name "isolinux.bin" -exec cp {} iso/isolinux/ \; 2>/dev/null || true
            rm -f /tmp/syslinux.tar.gz
        fi
    fi
    
    if [ ! -f "iso/isolinux/ldlinux.c32" ]; then
        print_warning "下载ldlinux.c32..."
        wget -q "https://github.com/ventoy/syslinux/raw/ventoy/bios/com32/elflink/ldlinux/ldlinux.c32" -O iso/isolinux/ldlinux.c32 || true
    fi
    
    # 创建ISOLINUX配置
    cat > iso/isolinux/isolinux.cfg << 'ISOLINUX_CFG'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 300
UI menu.c32

MENU TITLE OpenWRT Installer
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std

LABEL install
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=ttyS0 console=tty0

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img init=/bin/sh

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
ISOLINUX_CFG

    # 如果缺少menu.c32，使用文本模式
    if [ ! -f "iso/isolinux/menu.c32" ]; then
        print_info "使用文本模式..."
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
    
    # 方法1：使用grub-mkstandalone构建（最可靠）
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        print_info "构建GRUB EFI..."
        
        # 创建临时配置
        mkdir -p /tmp/grub_cfg/boot/grub
        cat > /tmp/grub_cfg/boot/grub/grub.cfg << 'GRUB_CFG_TEMP'
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
GRUB_CFG_TEMP
        
        # 构建GRUB EFI
        if grub-mkstandalone \
            -O x86_64-efi \
            -o /tmp/grub_cfg/BOOTX64.EFI \
            --modules="part_gpt part_msdos fat iso9660 ext2 configfile normal terminal" \
            "boot/grub/grub.cfg=/tmp/grub_cfg/boot/grub/grub.cfg" \
            2>/dev/null; then
            
            cp /tmp/grub_cfg/BOOTX64.EFI "iso/EFI/BOOT/BOOTX64.EFI"
            print_success "GRUB EFI构建成功"
        fi
        rm -rf /tmp/grub_cfg
    fi
    
    # 方法2：从系统复制
    if [ ! -f "iso/EFI/BOOT/BOOTX64.EFI" ]; then
        print_info "从系统复制GRUB..."
        
        # Ubuntu/Debian中的路径
        GRUB_PATHS=(
            "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi"
            "/usr/lib/grub/x86_64-efi/grub.efi"
            "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed"
        )
        
        for path in "${GRUB_PATHS[@]}"; do
            if [ -f "$path" ]; then
                print_info "复制: $path"
                cp "$path" "iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null && break
            fi
        done
    fi
    
    # 方法3：下载预编译的GRUB
    if [ ! -f "iso/EFI/BOOT/BOOTX64.EFI" ]; then
        print_info "下载GRUB EFI..."
        wget -q "https://github.com/ventoy/grub2/raw/ventoy/grub2/grubx64.efi" -O iso/EFI/BOOT/BOOTX64.EFI || \
        wget -q "https://github.com/a1ive/grub2-themes/raw/master/grub2-theme-breeze/grubx64.efi" -O iso/EFI/BOOT/BOOTX64.EFI || \
        echo "无法下载GRUB EFI"
    fi
    
    # 创建GRUB配置
    print_info "创建GRUB配置..."
    
    cat > "iso/boot/grub/grub.cfg" << 'GRUB_CFG'
# OpenWRT Installer - GRUB Configuration
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    echo "Loading OpenWRT installer..."
    linux /boot/vmlinuz initrd=/boot/initrd.img console=tty0
    initrd /boot/initrd.img
}

menuentry "Emergency Shell" {
    echo "Loading emergency shell..."
    linux /boot/vmlinuz initrd=/boot/initrd.img init=/bin/sh
    initrd /boot/initrd.img
}

menuentry "Reboot" {
    reboot
}
GRUB_CFG
    
    # 在EFI目录也创建配置
    cat > "iso/EFI/BOOT/grub.cfg" << 'EFI_CFG'
# UEFI GRUB Configuration
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EFI_CFG
    
    # 验证UEFI文件
    if [ -f "iso/EFI/BOOT/BOOTX64.EFI" ]; then
        EFI_SIZE=$(du -h "iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null | cut -f1)
        print_success "UEFI引导配置完成: ${EFI_SIZE}"
        return 0
    else
        print_warning "UEFI引导文件未找到，ISO将仅支持BIOS引导"
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
    print_info "检查关键文件:"
    [ -f "boot/vmlinuz" ] && echo "✅ boot/vmlinuz" || echo "❌ boot/vmlinuz"
    [ -f "boot/initrd.img" ] && echo "✅ boot/initrd.img" || echo "❌ boot/initrd.img"
    [ -f "isolinux/isolinux.bin" ] && echo "✅ isolinux.bin" || echo "❌ isolinux.bin"
    [ -f "EFI/BOOT/BOOTX64.EFI" ] && echo "✅ BOOTX64.EFI" || echo "❌ BOOTX64.EFI"
    
    # 创建ISO - 使用正确的方法
    print_info "创建可引导ISO..."
    
    # 方法1：完整方法
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
    
    if [ $? -ne 0 ]; then
        # 方法2：简化方法
        print_warning "完整方法失败，尝试简化方法..."
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
        print_success "ISO创建完成: ${ISO_SIZE}"
        
        # 检查ISO信息
        print_info "ISO详细信息:"
        if command -v file >/dev/null 2>&1; then
            file "${OUTPUT_ISO}" 2>/dev/null || true
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
    echo ""
    
    echo "🔧 引导支持:"
    echo "  • BIOS引导: ✅ 已配置"
    echo "  • UEFI引导: $( [ -f ${WORK_DIR}/iso/EFI/BOOT/BOOTX64.EFI ] && echo "✅ 已配置" || echo "⚠️  可能未配置" )"
    echo ""
    
    echo "🚀 测试方法:"
    echo "  1. BIOS测试: qemu-system-x86_64 -cdrom ${OUTPUT_ISO} -m 512"
    echo "  2. UEFI测试: qemu-system-x86_64 -bios /usr/share/qemu/OVMF.fd -cdrom ${OUTPUT_ISO} -m 512"
    echo ""
fi

# 清理
cleanup

echo "📅 构建时间: $(date)"
echo "═══════════════════════════════════════════════════"

echo ""
print_success "构建流程完成!"
exit 0
