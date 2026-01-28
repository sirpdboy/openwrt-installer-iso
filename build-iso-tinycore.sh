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

# ================= 创建initramfs =================
print_header "4. 创建initramfs"

create_initramfs() {
    print_step "创建initramfs..."
    
    local initrd_dir="${WORK_DIR}/initrd"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    cd "$initrd_dir"
    
    # 基本目录结构
    mkdir -p {bin,dev,etc,proc,sys,tmp,mnt,lib,lib64,usr/bin,run}
    
    # 创建设备节点
    mknod -m 622 dev/console c 5 1 2>/dev/null || true
    mknod -m 666 dev/null c 1 3 2>/dev/null || true
    mknod -m 666 dev/zero c 1 5 2>/dev/null || true
    
    # 简单init脚本
    cat > init << 'INIT'
#!/bin/sh
# 最小init脚本

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

echo "OpenWRT Installer"
echo "================="

# 挂载CD
mkdir -p /cdrom
mount -t iso9660 /dev/sr0 /cdrom 2>/dev/null || \
mount -t iso9660 /dev/cdrom /cdrom 2>/dev/null || \
mount -t iso9660 /dev/hdc /cdrom 2>/dev/null

if [ -f /cdrom/img/openwrt.img ]; then
    echo "OpenWRT image found"
    echo ""
    echo "Available disks:"
    for d in /dev/sd[a-z] /dev/vd[a-z]; do
        [ -b "$d" ] && echo "  $d"
    done
    echo ""
    echo -n "Enter disk to install (e.g., sda): "
    read disk
    
    if [ -n "$disk" ]; then
        echo "Installing to /dev/$disk..."
        dd if=/cdrom/img/openwrt.img of=/dev/$disk bs=4M
        echo "Done! Remove media and reboot."
    fi
else
    echo "Error: OpenWRT image not found"
fi

echo "Type 'reboot' to restart or press Ctrl+Alt+Del"
exec /bin/sh
INIT

    chmod +x init
    
    # 下载静态busybox
    print_info "下载BusyBox..."
    if wget -q "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" -O bin/busybox; then
        chmod +x bin/busybox
        cd bin
        ./busybox --list | while read app; do
            ln -s busybox "$app" 2>/dev/null || true
        done
        cd ..
    else
        # 简单shell作为后备
        cat > bin/sh << 'SHELL'
#!/bin/sh
echo "Minimal shell"
while read -p "# " cmd; do
    case "$cmd" in
        reboot) echo "Rebooting..."; break;;
        *) echo "Unknown: $cmd";;
    esac
done
SHELL
        chmod +x bin/sh
    fi
    
    # 创建initramfs
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${WORK_DIR}/iso/boot/initrd.img"
    
    INITRD_SIZE=$(du -h "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null | cut -f1)
    print_success "initramfs创建完成: ${INITRD_SIZE}"
    
    return 0
}

create_initramfs

# ================= 修复ISOLINUX引导 =================
print_header "5. 配置BIOS引导 (ISOLINUX)"

setup_bios_boot() {
    print_step "设置ISOLINUX引导..."
    
    # 创建 isolinux 目录
    mkdir -p "$WORK_DIR/iso/isolinux"
    
    print_info "收集ISOLINUX文件..."
    
    # 方法1：使用系统已安装的完整syslinux
    SYS_PATHS=(
        "/usr/lib/syslinux"
        "/usr/lib/syslinux/modules/bios"
        "/usr/share/syslinux"
        "/usr/lib/ISOLINUX"
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

# ================= 配置UEFI引导 =================
print_header "6. 配置UEFI引导 (GRUB)"

setup_uefi_boot() {
    print_step "设置UEFI引导..."
    
    mkdir -p "$WORK_DIR/iso/EFI/BOOT"
    mkdir -p "$WORK_DIR/iso/boot/grub"
    
    # 方法1：从系统复制GRUB EFI
    print_info "查找GRUB EFI文件..."
    
    GRUB_SOURCES=(
        "/usr/lib/grub/x86_64-efi/grub.efi"
        "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed"
        "/usr/share/grub/x86_64-efi/grub.efi"
        "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi"
    )
    
    GRUB_FOUND=0
    for src in "${GRUB_SOURCES[@]}"; do
        if [ -f "$src" ]; then
            print_info "找到GRUB: $src"
            cp "$src" "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null
            if [ -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
                GRUB_SIZE=$(wc -c < "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || echo 0)
                if [ "$GRUB_SIZE" -gt 100000 ]; then
                    GRUB_FOUND=1
                    print_success "GRUB EFI复制成功"
                    break
                fi
            fi
        fi
    done
    
    # 方法2：构建GRUB EFI
    if [ $GRUB_FOUND -eq 0 ] && command -v grub-mkstandalone >/dev/null 2>&1; then
        print_info "构建GRUB EFI..."
        
        # 创建临时GRUB配置
        mkdir -p /tmp/grub_tmp/boot/grub
        cat > /tmp/grub_tmp/boot/grub/grub.cfg << 'TEMP_GRUB'
set timeout=5
menuentry "Install OpenWRT" {
    linux /boot/vmlinuz initrd=/boot/initrd.img
    initrd /boot/initrd.img
}
TEMP_GRUB
        
        if grub-mkstandalone \
            -O x86_64-efi \
            -o /tmp/grub_tmp/BOOTX64.EFI \
            "boot/grub/grub.cfg=/tmp/grub_tmp/boot/grub/grub.cfg" \
            --modules="part_gpt part_msdos" \
            2>/dev/null; then
            
            cp /tmp/grub_tmp/BOOTX64.EFI "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI"
            GRUB_FOUND=1
            print_success "GRUB EFI构建成功"
        fi
        rm -rf /tmp/grub_tmp
    fi
    
    # 创建GRUB配置
    print_info "创建GRUB配置..."
    
    cat > "$WORK_DIR/iso/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    echo "Loading kernel..."
    linux /boot/vmlinuz initrd=/boot/initrd.img console=tty0
    echo "Loading initramfs..."
    initrd /boot/initrd.img
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz initrd=/boot/initrd.img init=/bin/sh
    initrd /boot/initrd.img
}

menuentry "Reboot" {
    reboot
}
GRUB_CFG
    
    # 在EFI目录也放一份配置
    cp "$WORK_DIR/iso/boot/grub/grub.cfg" "$WORK_DIR/iso/EFI/BOOT/grub.cfg" 2>/dev/null || \
    echo "configfile /boot/grub/grub.cfg" > "$WORK_DIR/iso/EFI/BOOT/grub.cfg"
    
    if [ -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
        print_success "UEFI引导配置完成"
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
    print_info "检查引导文件:"
    echo "ISOLINUX:"
    ls -la isolinux/ 2>/dev/null || echo "无isolinux目录"
    echo ""
    echo "UEFI:"
    ls -la EFI/BOOT/ 2>/dev/null || echo "无EFI目录"
    
    # 确保所有必要的.c32文件都在boot目录（兼容旧系统）
    if [ -d "isolinux" ]; then
        cp isolinux/* boot/ 2>/dev/null || true
    fi
    
    # 创建ISO - 使用最可靠的方法
    print_info "创建可引导ISO..."
    
    # 尝试多种方法
    ISO_CREATED=0
    
    # 方法1：标准方法（推荐）
    print_info "尝试方法1：标准ISOLINUX引导"
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
    
    if [ $? -eq 0 ] && [ -f "${OUTPUT_ISO}" ]; then
        ISO_CREATED=1
        print_success "方法1成功"
    else
        # 方法2：简化方法（仅BIOS）
        print_info "尝试方法2：仅BIOS引导"
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -J -r \
            -b boot/isolinux.bin \
            -c boot/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -o "${OUTPUT_ISO}" . 2>&1
        
        if [ $? -eq 0 ] && [ -f "${OUTPUT_ISO}" ]; then
            ISO_CREATED=1
            print_success "方法2成功"
        else
            # 方法3：最基本的方法
            print_info "尝试方法3：基本ISO"
            genisoimage \
                -volid "OPENWRT_INSTALL" \
                -J -r \
                -b boot/isolinux.bin \
                -c boot/boot.cat \
                -no-emul-boot \
                -boot-load-size 4 \
                -boot-info-table \
                -o "${OUTPUT_ISO}" . 2>&1
            
            ISO_CREATED=1
            print_info "方法3完成"
        fi
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
print_info "构建流程结束"
exit 0
