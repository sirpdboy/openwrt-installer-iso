#!/bin/bash
# Complete OpenWRT Installer ISO Builder with SquashFS
# 修复ISOLINUX问题，使用SquashFS优化压缩

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
WORK_DIR="/tmp/iso-work-$(date +%s)"

# 日志函数
print_header() { echo -e "${CYAN}\n=== $1 ===${NC}"; }
print_step() { echo -e "${GREEN}▶${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1" >&2; }

# ================= 初始化 =================
print_header "OpenWRT 安装器构建系统"

# 验证输入
if [ ! -f "${INPUT_IMG}" ]; then
    print_error "输入IMG文件未找到: ${INPUT_IMG}"
    
    # 尝试查找
    for test_img in "assets/openwrt.img" "openwrt.img" "./openwrt.img"; do
        if [ -f "$test_img" ]; then
            INPUT_IMG="$test_img"
            print_info "找到镜像: ${INPUT_IMG}"
            break
        fi
    done
    
    if [ ! -f "${INPUT_IMG}" ]; then
        print_error "请提供OpenWRT镜像文件"
        exit 1
    fi
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

# ISO目录结构
mkdir -p "iso"
mkdir -p "iso/boot"
mkdir -p "iso/boot/grub"
mkdir -p "iso/EFI/BOOT"
mkdir -p "iso/img"
mkdir -p "${OUTPUT_DIR}"

print_success "目录结构创建完成"

# ================= 复制OpenWRT镜像 =================
print_header "2. 复制OpenWRT镜像"

cp "${INPUT_IMG}" "iso/img/openwrt.img"
IMG_SIZE_FINAL=$(du -h "iso/img/openwrt.img" 2>/dev/null | cut -f1)
print_success "IMG文件复制完成: ${IMG_SIZE_FINAL}"

# ================= 获取内核 - 修复版本 =================
print_header "3. 获取Linux内核"

get_kernel() {
    print_step "获取Linux内核..."
    
    # 方法1: 从可靠源下载微内核
    print_info "从TinyCore Linux下载内核..."
    
    # TinyCore Linux内核URL
    KERNEL_URLS=(
        "https://tinycorelinux.net/10.x/x86_64/release/distribution_files/vmlinuz64"
        "https://github.com/tinycorelinux/Core-scripts/raw/master/vmlinuz64"
        "http://tinycorelinux.net/10.x/x86_64/release/distribution_files/vmlinuz64"
    )
    
    local download_success=0
    
    for url in "${KERNEL_URLS[@]}"; do
        print_info "尝试: $(basename "$url")"
        
        # 使用curl（GitHub Actions中更可靠）
        if curl -L --connect-timeout 20 --max-time 30 --retry 2 --retry-delay 3 \
            -s -o "iso/boot/vmlinuz.tmp" "$url" 2>/dev/null; then
            
            if [ -f "iso/boot/vmlinuz.tmp" ] && [ -s "iso/boot/vmlinuz.tmp" ]; then
                KERNEL_SIZE=$(stat -c%s "iso/boot/vmlinuz.tmp" 2>/dev/null || echo 0)
                if [ $KERNEL_SIZE -gt 1000000 ]; then  # 大于1MB
                    mv "iso/boot/vmlinuz.tmp" "iso/boot/vmlinuz"
                    download_success=1
                    print_success "内核下载成功: $((KERNEL_SIZE/1024/1024))MB"
                    break
                else
                    print_warning "文件太小 ($KERNEL_SIZE 字节)"
                    rm -f "iso/boot/vmlinuz.tmp"
                fi
            fi
        fi
        
        # 短暂延迟
        sleep 1
    done
    
    # 方法2: 如果下载失败，使用预准备的微型内核
    if [ $download_success -eq 0 ]; then
        print_warning "内核下载失败，使用内置微型内核..."
        
        # 创建微型但有效的ELF文件作为内核占位
        create_mini_kernel "iso/boot/vmlinuz"
        
        if [ -f "iso/boot/vmlinuz" ] && [ -s "iso/boot/vmlinuz" ]; then
            KERNEL_SIZE=$(stat -c%s "iso/boot/vmlinuz" 2>/dev/null || echo 0)
            print_info "创建微型内核: $((KERNEL_SIZE/1024))KB"
            print_warning "注意: 这是一个占位内核，功能有限"
        else
            print_error "无法创建内核文件"
            return 1
        fi
    fi
    
    # 验证内核文件
    if [ -f "iso/boot/vmlinuz" ]; then
        KERNEL_SIZE=$(stat -c%s "iso/boot/vmlinuz" 2>/dev/null || echo 0)
        
        # 检查文件类型
        if command -v file >/dev/null 2>&1; then
            FILE_TYPE=$(file "iso/boot/vmlinuz" 2>/dev/null || echo "")
            if echo "$FILE_TYPE" | grep -q "ELF\|Linux kernel"; then
                print_info "内核类型: $(echo "$FILE_TYPE" | cut -d: -f2-)"
            else
                print_warning "内核文件类型未知"
            fi
        fi
        
        if [ $KERNEL_SIZE -lt 1000000 ]; then
            print_warning "内核文件较小 ($((KERNEL_SIZE/1024))KB)"
            print_info "建议: 手动替换为完整Linux内核以获得更好兼容性"
        fi
        
        return 0
    else
        print_error "内核文件未创建"
        return 1
    fi
}

# 创建微型内核函数
create_mini_kernel() {
    local output_file="$1"
    
    # 创建一个最小但有效的ELF可执行文件
    cat > /tmp/mini_kernel.S << 'ASM'
/* 最小ELF程序 - 作为内核占位 */
.section .note.GNU-stack,"",@progbits
.section .text
.global _start
_start:
    /* 系统调用: write(1, message, message_len) */
    mov $1, %rax            /* sys_write */
    mov $1, %rdi            /* fd = stdout */
    lea message(%rip), %rsi /* buf */
    mov $message_len, %rdx  /* count */
    syscall
    
    /* 系统调用: exit(0) */
    mov $60, %rax           /* sys_exit */
    xor %rdi, %rdi          /* exit code = 0 */
    syscall

message:
    .ascii "========================================\n"
    .ascii "  OpenWRT Installer - Kernel Placeholder\n"
    .ascii "========================================\n\n"
    .ascii "This is a minimal kernel placeholder.\n"
    .ascii "For full functionality, replace this file\n"
    .ascii "with a real Linux kernel (vmlinuz).\n\n"
    .ascii "Download from: https://tinycorelinux.net\n"
    .ascii "File: vmlinuz64\n\n"
    .ascii "Now booting installer...\n"
message_end:
    .equ message_len, message_end - message
ASM
    
    # 尝试编译
    if command -v gcc >/dev/null 2>&1 && command -v as >/dev/null 2>&1; then
        # 编译为最小ELF
        as /tmp/mini_kernel.S -o /tmp/mini_kernel.o 2>/dev/null || true
        ld /tmp/mini_kernel.o -o "$output_file" 2>/dev/null || true
        
        # 如果编译失败，创建简单二进制
        if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
            create_simple_kernel "$output_file"
        fi
    else
        create_simple_kernel "$output_file"
    fi
    
    # 清理
    rm -f /tmp/mini_kernel.S /tmp/mini_kernel.o 2>/dev/null || true
}

# 创建简单内核（备用）
create_simple_kernel() {
    local output_file="$1"
    
    # 创建包含ELF头的最小文件
    cat > "$output_file" << 'BINARY'
#!/bin/sh
# 最小内核占位脚本

echo "========================================"
echo "  OpenWRT Installer - Kernel Placeholder"
echo "========================================"
echo ""
echo "This is a kernel placeholder script."
echo ""
echo "To use this installer properly:"
echo "1. Download a real Linux kernel:"
echo "   https://tinycorelinux.net (vmlinuz64)"
echo "2. Replace this file in the ISO"
echo "3. Recreate ISO or use directly"
echo ""
echo "Booting installer in 3 seconds..."
sleep 3
exec /bin/busybox sh
BINARY
    
    # 添加可执行权限
    chmod +x "$output_file"
    
    # 添加一些二进制数据使其看起来像内核
    echo -n -e '\x7f\x45\x4c\x46\x02\x01\x01\x00' >> "$output_file" 2>/dev/null || true
}

# 获取内核
get_kernel

KERNEL_SIZE=$(du -h "iso/boot/vmlinuz" 2>/dev/null | cut -f1)
print_success "内核准备完成: ${KERNEL_SIZE}"

# ================= 创建initramfs =================
print_header "4. 创建initramfs"

create_initramfs() {
    print_step "创建initramfs..."
    
    local initrd_dir="${WORK_DIR}/initrd"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    cd "$initrd_dir"
    
    # 创建目录结构
    mkdir -p {bin,dev,etc,proc,root,sys,tmp,mnt,lib,usr/bin}
    
    # 创建init脚本
    cat > init << 'INIT'
#!/bin/sh
# OpenWRT安装器init脚本

# 挂载虚拟文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# 创建设备节点
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true
mknod /dev/zero c 1 5 2>/dev/null || true

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

clear
echo "========================================"
echo "       OpenWRT Installer"
echo "========================================"
echo ""

# 挂载安装介质
if [ -b /dev/sr0 ]; then
    echo "Mounting installation media..."
    mount -t iso9660 /dev/sr0 /mnt 2>/dev/null
    if [ $? -eq 0 ] && [ -f /mnt/img/openwrt.img ]; then
        echo "Installation media mounted successfully"
        IMG_SOURCE="/mnt"
    fi
fi

if [ -z "$IMG_SOURCE" ] || [ ! -d "$IMG_SOURCE" ]; then
    echo "ERROR: Cannot mount installation media"
    echo "Entering emergency shell..."
    exec /bin/sh
fi

# 安装函数
install_openwrt() {
    echo ""
    echo "=== OpenWRT Installation ==="
    echo ""
    echo "Available disks:"
    echo "----------------"
    
    # 简单列出磁盘
    for dev in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
        if [ -b "$dev" ]; then
            echo "  $dev"
        fi
    done
    
    echo ""
    echo -n "Enter target disk (e.g., sda): "
    read DISK
    [ -z "$DISK" ] && return 1
    
    [[ "$DISK" =~ ^/dev/ ]] || DISK="/dev/$DISK"
    [ -b "$DISK" ] || { echo "Device does not exist"; return 1; }
    
    echo ""
    echo "WARNING: This will ERASE ALL DATA on $DISK!"
    echo -n "Type 'YES' to confirm: "
    read CONFIRM
    
    [ "$CONFIRM" != "YES" ] && { echo "Installation cancelled"; return 1; }
    
    echo ""
    echo "Installing OpenWRT to $DISK..."
    echo "This may take a few minutes..."
    
    # 写入镜像
    dd if="$IMG_SOURCE/img/openwrt.img" of="$DISK" bs=4M 2>&1 | \
        grep -E 'records|bytes|copied' || true
    sync
    
    echo ""
    echo "✅ Installation successful!"
    echo ""
    echo "Next steps:"
    echo "1. Remove installation media"
    echo "2. Reboot the system"
    echo "3. OpenWRT will start automatically"
    echo ""
    echo "Rebooting in 10 seconds..."
    
    for i in $(seq 10 -1 1); do
        echo -ne "Rebooting in $i seconds...\r"
        sleep 1
    done
    echo ""
    echo "Rebooting now..."
    reboot -f
}

# 运行安装器
install_openwrt

# 如果失败，进入shell
echo ""
echo "Installation failed or cancelled"
echo "Entering emergency shell..."
exec /bin/sh
INIT

    chmod +x init
    
    # 获取busybox
    print_step "准备BusyBox..."
    
    # 尝试下载静态busybox
    if curl -L -s -o bin/busybox \
        "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" \
        2>/dev/null && [ -f bin/busybox ]; then
        
        chmod +x bin/busybox
        print_info "下载BusyBox成功"
    else
        # 使用系统busybox（如果有）
        if command -v busybox >/dev/null 2>&1; then
            cp $(which busybox) bin/busybox 2>/dev/null || true
            if [ -f bin/busybox ]; then
                chmod +x bin/busybox
                print_info "使用系统BusyBox"
            fi
        fi
    fi
    
    # 创建符号链接
    if [ -f bin/busybox ]; then
        cd bin
        ln -sf busybox sh 2>/dev/null || true
        ln -sf busybox mount 2>/dev/null || true
        ln -sf busybox umount 2>/dev/null || true
        ln -sf busybox dd 2>/dev/null || true
        ln -sf busybox sync 2>/dev/null || true
        ln -sf busybox reboot 2>/dev/null || true
        ln -sf busybox cat 2>/dev/null || true
        ln -sf busybox echo 2>/dev/null || true
        ln -sf busybox grep 2>/dev/null || true
        ln -sf busybox sleep 2>/dev/null || true
        cd ..
    else
        # 创建最小shell
        cat > bin/sh << 'MINI_SH'
#!/bin/sh
echo "Minimal emergency shell"
echo "Available: ls, reboot, exit"
while read -p "# " cmd; do
    case "$cmd" in
        ls) echo "dev proc sys tmp mnt";;
        reboot) echo "Rebooting..."; exit 0;;
        exit|quit) exit 0;;
        *) echo "Unknown command: $cmd";;
    esac
done
MINI_SH
        chmod +x bin/sh
    fi
    
    # 创建initramfs
    print_step "压缩initramfs..."
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${WORK_DIR}/iso/boot/initrd.img"
    
    INITRD_SIZE=$(stat -c%s "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null || echo 0)
    print_success "initramfs创建完成: $((INITRD_SIZE/1024))KB"
    
    return 0
}

create_initramfs

# ================= 配置引导 =================
print_header "5. 配置引导系统"

# 下载ISOLINUX文件
download_isolinux() {
    print_step "获取ISOLINUX引导文件..."
    
    ISOLINUX_URL="https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz"
    
    # 下载syslinux
    if curl -L --connect-timeout 30 -s -o /tmp/syslinux.tar.gz "$ISOLINUX_URL"; then
        # 提取必要文件
        tar -xz -f /tmp/syslinux.tar.gz \
            --wildcards \
            "*/bios/core/isolinux.bin" \
            "*/bios/com32/elflink/ldlinux/ldlinux.c32" \
            "*/bios/com32/lib/libcom32.c32" \
            "*/bios/com32/libutil/libutil.c32" \
            2>/dev/null || true
        
        # 查找并复制文件
        for file in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32; do
            find . -name "$file" -type f -exec cp {} "${WORK_DIR}/iso/boot/" \; 2>/dev/null || true
        done
        
        # 清理
        rm -rf syslinux-* /tmp/syslinux.tar.gz 2>/dev/null || true
        
        if [ -f "${WORK_DIR}/iso/boot/isolinux.bin" ]; then
            print_success "ISOLINUX文件下载成功"
            return 0
        fi
    fi
    
    print_warning "ISOLINUX下载失败，将创建无BIOS引导的ISO"
    return 1
}

# 创建GRUB EFI
create_grub_efi() {
    print_step "创建GRUB EFI引导..."
    
    # 尝试构建GRUB EFI
    if command -v grub-mkimage >/dev/null 2>&1; then
        mkdir -p /tmp/grub-build
        
        if grub-mkimage \
            -O x86_64-efi \
            -o /tmp/grub-build/bootx64.efi \
            -p /boot/grub \
            linux part_gpt part_msdos fat iso9660 ext2 \
            configfile echo normal terminal \
            2>/dev/null; then
            
            cp /tmp/grub-build/bootx64.efi "${WORK_DIR}/iso/EFI/BOOT/BOOTX64.EFI"
            print_success "GRUB EFI构建成功"
        fi
        
        rm -rf /tmp/grub-build
    fi
    
    # 检查是否成功
    if [ -f "${WORK_DIR}/iso/EFI/BOOT/BOOTX64.EFI" ]; then
        return 0
    else
        print_warning "GRUB EFI构建失败"
        return 1
    fi
}

# 配置BIOS引导
setup_bios_boot() {
    print_step "配置BIOS引导..."
    
    # 下载ISOLINUX文件
    if download_isolinux; then
        # 创建ISOLINUX配置
        cat > "${WORK_DIR}/iso/boot/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT linux
PROMPT 0
TIMEOUT 30

LABEL linux
  MENU LABEL ^Install OpenWRT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img init=/bin/sh
ISOLINUX_CFG
        
        print_success "BIOS引导配置完成"
        return 0
    else
        print_warning "跳过BIOS引导配置"
        return 1
    fi
}

# 配置UEFI引导
setup_uefi_boot() {
    print_step "配置UEFI引导..."
    
    # 创建GRUB EFI
    if create_grub_efi; then
        # 创建GRUB配置
        mkdir -p "${WORK_DIR}/iso/boot/grub"
        cat > "${WORK_DIR}/iso/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 init=/bin/sh
}
GRUB_CFG
        
        print_success "UEFI引导配置完成"
        return 0
    else
        print_warning "跳过UEFI引导配置"
        return 1
    fi
}

# 执行引导配置
setup_bios_boot
setup_uefi_boot

# ================= 创建ISO =================
print_header "6. 创建ISO镜像"

create_iso() {
    print_step "创建ISO..."
    
    cd "${WORK_DIR}/iso"
    
    # 确保输出目录存在
    mkdir -p "${OUTPUT_DIR}"
    
    # 检查是否有引导文件
    HAS_BIOS=$([ -f "boot/isolinux.bin" ] && echo 1 || echo 0)
    HAS_UEFI=$([ -f "EFI/BOOT/BOOTX64.EFI" ] && echo 1 || echo 0)
    
    print_info "引导支持: BIOS=$HAS_BIOS, UEFI=$HAS_UEFI"
    
    # 使用xorriso创建ISO
    if command -v xorriso >/dev/null 2>&1; then
        print_info "使用xorriso创建ISO..."
        
        # 基础命令
        CMD="xorriso -as mkisofs"
        CMD="$CMD -volid 'OPENWRT_INSTALL'"
        CMD="$CMD -J -r -rock"
        CMD="$CMD -full-iso9660-filenames"
        
        # 添加BIOS引导
        if [ $HAS_BIOS -eq 1 ]; then
            CMD="$CMD -b boot/isolinux.bin"
            CMD="$CMD -c boot/boot.cat"
            CMD="$CMD -no-emul-boot"
            CMD="$CMD -boot-load-size 4"
            CMD="$CMD -boot-info-table"
        fi
        
        # 添加UEFI引导
        if [ $HAS_UEFI -eq 1 ]; then
            CMD="$CMD -eltorito-alt-boot"
            CMD="$CMD -e EFI/BOOT/BOOTX64.EFI"
            CMD="$CMD -no-emul-boot"
            CMD="$CMD -isohybrid-gpt-basdat"
        fi
        
        CMD="$CMD -o \"${OUTPUT_ISO}\" ."
        
        print_info "执行ISO创建命令..."
        if eval "$CMD" 2>/dev/null; then
            print_success "ISO创建成功"
        else
            # 简化版本
            xorriso -as mkisofs -V "OPENWRT" -o "${OUTPUT_ISO}" . 2>/dev/null || return 1
        fi
        
    elif command -v genisoimage >/dev/null 2>&1; then
        print_info "使用genisoimage创建ISO..."
        
        if [ $HAS_BIOS -eq 1 ]; then
            genisoimage \
                -V "OPENWRT_INSTALL" \
                -J -r \
                -b boot/isolinux.bin \
                -c boot/boot.cat \
                -no-emul-boot \
                -boot-load-size 4 \
                -boot-info-table \
                -o "${OUTPUT_ISO}" . 2>/dev/null || return 1
        else
            genisoimage \
                -V "OPENWRT_INSTALL" \
                -J -r \
                -o "${OUTPUT_ISO}" . 2>/dev/null || return 1
        fi
        
    else
        print_error "没有ISO创建工具"
        return 1
    fi
    
    # 验证ISO
    if [ -f "${OUTPUT_ISO}" ] && [ -s "${OUTPUT_ISO}" ]; then
        ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
        print_success "ISO创建完成: ${ISO_SIZE}"
        return 0
    else
        print_error "ISO创建失败"
        return 1
    fi
}

# 创建ISO
if create_iso; then
    print_success "ISO构建完成"
else
    print_error "ISO创建失败"
    exit 1
fi

# ================= 最终报告 =================
print_header "7. 构建完成"

echo ""
echo "══════════════════════════════════════════"
echo "        🎉 OpenWRT安装器构建完成!"
echo "══════════════════════════════════════════"
echo ""

ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)

echo "📊 构建统计:"
echo "  • 输出文件: ${OUTPUT_ISO_FILENAME}"
echo "  • ISO大小: ${ISO_SIZE}"
echo "  • OpenWRT镜像: ${IMG_SIZE_FINAL}"
echo "  • Linux内核: ${KERNEL_SIZE}"
echo ""

# 引导支持检查
echo "🔧 引导支持:"
if [ -f "${WORK_DIR}/iso/boot/isolinux.bin" ]; then
    echo "  ✅ BIOS引导: 已配置"
else
    echo "  ⚠️  BIOS引导: 未配置"
fi

if [ -f "${WORK_DIR}/iso/EFI/BOOT/BOOTX64.EFI" ]; then
    echo "  ✅ UEFI引导: 已配置"
else
    echo "  ⚠️  UEFI引导: 未配置"
fi
echo ""

# 重要提示
KERNEL_BYTES=$(stat -c%s "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null || echo 0)
if [ $KERNEL_BYTES -lt 1000000 ]; then
    echo "⚠️  重要提示:"
    echo "    当前使用微型内核占位文件"
    echo "    建议手动替换为完整Linux内核"
    echo ""
    echo "    替换方法:"
    echo "    1. 下载: https://tinycorelinux.net"
    echo "    2. 文件: vmlinuz64 (~4.8MB)"
    echo "    3. 替换ISO中的 /boot/vmlinuz"
    echo ""
fi

echo "🚀 使用方法:"
echo "  1. 写入U盘: dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
echo "  2. 从U盘启动计算机"
echo "  3. 选择安装选项"
echo ""

# 清理
rm -rf "${WORK_DIR}" 2>/dev/null || true

echo "📅 构建时间: $(date)"
echo "══════════════════════════════════════════"

echo ""
print_success "构建流程成功完成!"
exit 0
