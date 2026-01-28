#!/bin/bash
# OpenWRT Installer ISO Builder - 完整修复版

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
mkdir -p "iso/EFI/BOOT"
mkdir -p "iso/img"
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
        "https://tinycorelinux.net/10.x/x86_64/release/distribution_files/vmlinuz64"
        "https://github.com/tinycorelinux/Core-scripts/raw/master/vmlinuz64"
        "http://distro.ibiblio.org/tinycorelinux/10.x/x86_64/release/distribution_files/vmlinuz64"
    )
    
    for url in "${KERNEL_URLS[@]}"; do
        print_info "尝试: $(basename "$url")"
        
        if curl -L --connect-timeout 15 --max-time 30 --retry 2 \
            -s -o "iso/boot/vmlinuz" "$url" 2>/dev/null; then
            
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
    
    # 如果下载失败，创建有效的ELF内核
    print_warning "内核下载失败，创建最小ELF内核"
    
    # 创建最小ELF文件
    cat > /tmp/mini_kernel.c << 'EOF'
// 最小ELF程序
const char msg[] = "OpenWRT Installer - Minimal Kernel\n";
void _start() {
    asm volatile(
        "mov $1, %%rax\n"
        "mov $1, %%rdi\n"
        "lea msg(%%rip), %%rsi\n"
        "mov $35, %%rdx\n"
        "syscall\n"
        "mov $60, %%rax\n"
        "mov $0, %%rdi\n"
        "syscall\n"
        ::: "rax", "rdi", "rsi", "rdx"
    );
}
EOF
    
    # 尝试编译
    if command -v gcc >/dev/null 2>&1; then
        gcc -nostdlib -static -o "iso/boot/vmlinuz" /tmp/mini_kernel.c 2>/dev/null || true
    fi
    
    # 确保文件存在
    if [ ! -f "iso/boot/vmlinuz" ] || [ ! -s "iso/boot/vmlinuz" ]; then
        dd if=/dev/zero of="iso/boot/vmlinuz" bs=1M count=2 2>/dev/null
        echo "LINUX_KERNEL_PLACEHOLDER" >> "iso/boot/vmlinuz"
    fi
    
    print_warning "使用最小内核占位文件"
    print_info "建议手动替换为完整内核: https://tinycorelinux.net"
    return 1
}

get_kernel

KERNEL_SIZE=$(du -h "iso/boot/vmlinuz" 2>/dev/null | cut -f1)
print_success "内核准备完成: ${KERNEL_SIZE}"

# ================= 创建完整的initramfs =================
print_header "4. 创建initramfs"

create_initramfs() {
    print_step "创建initramfs..."
    
    local initrd_dir="${WORK_DIR}/initrd"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    cd "$initrd_dir"
    
    # 创建完整的目录结构
    mkdir -p {bin,dev,etc,proc,sys,tmp,mnt,lib,usr/bin,usr/lib}
    
    # 创建完整的init脚本
    cat > init << 'INIT'
#!/bin/sh
# OpenWRT安装器init脚本

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# 挂载虚拟文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# 创建设备节点
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true
mknod /dev/zero c 1 5 2>/dev/null || true
mknod /dev/tty c 5 0 2>/dev/null || true
mknod /dev/tty1 c 4 1 2>/dev/null || true

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

echo "========================================"
echo "       OpenWRT Installer"
echo "========================================"

# 挂载安装介质
MOUNT_SUCCESS=0
for device in /dev/sr0 /dev/cdrom /dev/hdc /dev/hdd; do
    if [ -b "$device" ]; then
        echo "尝试挂载 $device..."
        mount -t iso9660 -o ro "$device" /mnt 2>/dev/null
        if [ $? -eq 0 ]; then
            if [ -f /mnt/img/openwrt.img ]; then
                MOUNT_SUCCESS=1
                echo "安装介质挂载成功"
                break
            else
                umount /mnt 2>/dev/null
            fi
        fi
    fi
done

if [ $MOUNT_SUCCESS -ne 1 ]; then
    echo "错误: 无法挂载安装介质"
    echo "进入应急shell..."
    exec /bin/sh
fi

# 安装器主函数
main_menu() {
    clear
    echo "=== OpenWRT Installation ==="
    echo ""
    echo "目标系统: OpenWRT"
    echo "镜像文件: openwrt.img"
    echo ""
    
    # 显示可用磁盘
    echo "可用磁盘:"
    echo "---------"
    
    # 尝试多种方法列出磁盘
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -E '^(sd|hd|vd|nvme)' || true
    elif command -v fdisk >/dev/null 2>&1; then
        fdisk -l 2>/dev/null | grep -E '^Disk /dev/(sd|hd|vd|nvme)' | sed 's/^Disk //' || true
    else
        # 简单列出
        for dev in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
            [ -b "$dev" ] && echo "  $dev"
        done
    fi
    
    echo ""
    echo -n "请输入目标磁盘 (例如: sda): "
    read DISK
    
    if [ -z "$DISK" ]; then
        echo "未选择磁盘"
        return 1
    fi
    
    # 规范化磁盘路径
    if [[ ! "$DISK" =~ ^/dev/ ]]; then
        DISK="/dev/$DISK"
    fi
    
    # 验证磁盘存在
    if [ ! -b "$DISK" ]; then
        echo "错误: 磁盘 $DISK 不存在"
        return 1
    fi
    
    # 确认
    echo ""
    echo "⚠️  ⚠️  ⚠️  严重警告 ⚠️  ⚠️  ⚠️"
    echo "这将完全擦除磁盘: $DISK"
    echo "所有数据将永久丢失!"
    echo ""
    echo -n "请输入 'YES' 确认: "
    read CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "安装取消"
        return 1
    fi
    
    # 开始安装
    echo ""
    echo "开始安装 OpenWRT 到 $DISK ..."
    echo "这可能需要几分钟，请耐心等待..."
    
    # 写入镜像
    dd if="/mnt/img/openwrt.img" of="$DISK" bs=4M 2>&1 | \
        while read line; do
            echo "$line" | grep -E 'records|bytes|copied' || true
        done
    
    sync
    
    echo ""
    echo "✅ 安装完成!"
    echo ""
    echo "下一步:"
    echo "1. 移除安装介质 (U盘/CD)"
    echo "2. 重启计算机"
    echo "3. OpenWRT 将自动启动"
    echo ""
    echo "系统将在10秒后重启..."
    
    for i in $(seq 10 -1 1); do
        echo -ne "重启倒计时: ${i}秒\r"
        sleep 1
    done
    echo ""
    echo "正在重启..."
    reboot -f
}

# 运行安装器
while true; do
    if main_menu; then
        break
    else
        echo ""
        echo -n "按回车键重试，或输入 'shell' 进入命令行: "
        read CHOICE
        if [ "$CHOICE" = "shell" ]; then
            echo "进入应急shell..."
            exec /bin/sh
        fi
    fi
done

# 如果到这里，执行shell
exec /bin/sh
INIT

    chmod +x init
    
    # 获取busybox
    print_step "准备BusyBox和工具..."
    
    # 下载静态busybox
    print_info "下载BusyBox..."
    if curl -L -s -o bin/busybox \
        "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" \
        2>/dev/null && [ -f bin/busybox ]; then
        chmod +x bin/busybox
        BUSYBOX_OK=1
    else
        # 尝试使用系统busybox
        if command -v busybox >/dev/null 2>&1; then
            BUSYBOX_PATH=$(which busybox)
            cp "$BUSYBOX_PATH" bin/busybox 2>/dev/null || true
            if [ -f bin/busybox ]; then
                chmod +x bin/busybox
                BUSYBOX_OK=1
            fi
        fi
    fi
    
    if [ "${BUSYBOX_OK:-0}" -eq 1 ]; then
        # 创建符号链接
        print_info "创建BusyBox符号链接..."
        cd bin
        ./busybox --list | while read applet; do
            ln -sf busybox "$applet" 2>/dev/null || true
        done
        cd ..
    else
        # 创建最小shell
        print_warning "无法获取BusyBox，创建最小shell"
        cat > bin/sh << 'MINI_SH'
#!/bin/sh
echo "Minimal emergency shell"
echo "Commands: ls, reboot, exit"
while read -p "# " cmd; do
    case "$cmd" in
        ls) ls /dev/ /proc/ 2>/dev/null || echo "dev proc sys";;
        reboot) echo "Rebooting..."; exit 0;;
        exit|quit) exit 0;;
        *) echo "Unknown command: $cmd";;
    esac
done
MINI_SH
        chmod +x bin/sh
    fi
    
    # 复制必要的库文件
    print_step "复制库文件..."
    
    # 复制ld-linux
    for lib in /lib64/ld-linux-x86-64.so.2 /lib/ld-musl-x86_64.so.1; do
        if [ -f "$lib" ]; then
            cp "$lib" lib/ 2>/dev/null || true
            break
        fi
    done
    
    # 复制busybox依赖的库
    if [ -f bin/busybox ] && command -v ldd >/dev/null 2>&1; then
        ldd bin/busybox 2>/dev/null | grep "=> /" | awk '{print $3}' | \
            while read lib; do
                if [ -f "$lib" ]; then
                    cp "$lib" lib/ 2>/dev/null || true
                fi
            done
    fi
    
    # 显示initramfs大小
    print_info "initramfs内容大小:"
    du -sh . || du -sb . | awk '{print $1}'
    
    # 创建initramfs
    print_step "创建压缩initramfs..."
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${WORK_DIR}/iso/boot/initrd.img"
    
    # 验证initramfs
    if [ -f "${WORK_DIR}/iso/boot/initrd.img" ]; then
        INITRD_SIZE=$(du -h "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null | cut -f1)
        INITRD_BYTES=$(stat -c%s "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null || echo 0)
        
        print_success "initramfs创建完成: ${INITRD_SIZE}"
        
        if [ $INITRD_BYTES -lt 500000 ]; then
            print_warning "initramfs较小 ($((INITRD_BYTES/1024))KB)，可能缺少文件"
        else
            print_info "initramfs大小正常: $((INITRD_BYTES/1024))KB"
        fi
    else
        print_error "initramfs创建失败"
        return 1
    fi
    
    return 0
}

create_initramfs

# ================= 修复ISOLINUX引导 =================
print_header "5. 配置BIOS引导 (ISOLINUX)"

setup_bios_boot() {
    print_step "设置ISOLINUX引导..."
    
    # 确保boot目录存在
    if [ ! -d "iso/boot" ]; then
        mkdir -p "iso/boot"
    fi
    
    # 下载syslinux包
    print_info "下载syslinux包..."
    
    SYSLINUX_URL="https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz"
    
    if curl -L --connect-timeout 30 -s -o /tmp/syslinux.tar.gz "$SYSLINUX_URL"; then
        print_info "解压syslinux..."
        
        # 创建临时目录
        mkdir -p /tmp/syslinux-extract
        tar -xz -f /tmp/syslinux.tar.gz -C /tmp/syslinux-extract
        
        # 查找并复制文件
        SYS_FILES=(
            "isolinux.bin"
            "ldlinux.c32"
            "libcom32.c32"
            "libutil.c32"
            "menu.c32"
            "chain.c32"
            "reboot.c32"
            "poweroff.c32"
            "hd0.c32"
            "hd1.c32"
        )
        
        for file in "${SYS_FILES[@]}"; do
            # 在解压的目录中查找文件
            find /tmp/syslinux-extract -name "$file" -type f | while read found_file; do
                print_info "复制: $(basename "$found_file")"
                cp "$found_file" "iso/boot/" 2>/dev/null && break
            done
        done
        
        # 清理
        rm -rf /tmp/syslinux-extract /tmp/syslinux.tar.gz
        
        # 验证关键文件
        if [ -f "iso/boot/isolinux.bin" ] && [ -f "iso/boot/ldlinux.c32" ]; then
            print_success "ISOLINUX文件准备完成"
        else
            print_error "缺少关键ISOLINUX文件"
            return 1
        fi
    else
        print_error "无法下载syslinux"
        return 1
    fi
    
    # 创建ISOLINUX配置
    cat > iso/boot/isolinux.cfg << 'ISOLINUX_CFG'
DEFAULT linux
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

LABEL linux
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
    
    print_success "BIOS引导配置完成"
    return 0
}

setup_bios_boot

# ================= 配置UEFI引导 =================
print_header "6. 配置UEFI引导 (GRUB)"

setup_uefi_boot() {
    print_step "设置UEFI引导..."
    
    # 确保EFI目录存在
    mkdir -p "iso/EFI/BOOT"
    
    # 方法1: 尝试从系统复制GRUB EFI
    print_info "查找GRUB EFI文件..."
    
    GRUB_PATHS=(
        "/usr/lib/grub/x86_64-efi/grubx64.efi"
        "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed"
        "/usr/share/grub/x86_64-efi/grubx64.efi"
        "/usr/lib/grub/x86_64-efi-core/grubx64.efi"
    )
    
    GRUB_FOUND=0
    for path in "${GRUB_PATHS[@]}"; do
        if [ -f "$path" ]; then
            cp "$path" "iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null
            if [ -f "iso/EFI/BOOT/BOOTX64.EFI" ]; then
                print_success "复制GRUB EFI: $path"
                GRUB_FOUND=1
                break
            fi
        fi
    done
    
    # 方法2: 如果找不到，构建一个
    if [ $GRUB_FOUND -eq 0 ] && command -v grub-mkimage >/dev/null 2>&1; then
        print_info "构建GRUB EFI..."
        
        mkdir -p /tmp/grub-build
        if grub-mkimage \
            -O x86_64-efi \
            -o /tmp/grub-build/grubx64.efi \
            -p /EFI/BOOT \
            linux part_gpt part_msdos fat iso9660 ext2 \
            configfile echo normal terminal \
            2>/dev/null; then
            
            cp /tmp/grub-build/grubx64.efi "iso/EFI/BOOT/BOOTX64.EFI"
            print_success "GRUB EFI构建成功"
            GRUB_FOUND=1
        fi
        rm -rf /tmp/grub-build
    fi
    
    # 创建GRUB配置
    mkdir -p "iso/boot/grub"
    cat > "iso/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    echo "Loading kernel..."
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet
    echo "Loading initramfs..."
    initrd /boot/initrd.img
    echo "Booting OpenWRT installer..."
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 init=/bin/sh
    initrd /boot/initrd.img
}

menuentry "Reboot" {
    reboot
}
GRUB_CFG
    
    # 在EFI目录也放一个配置
    cat > "iso/EFI/BOOT/grub.cfg" << 'EFI_CFG'
configfile /boot/grub/grub.cfg
EFI_CFG
    
    if [ -f "iso/EFI/BOOT/BOOTX64.EFI" ]; then
        print_success "UEFI引导配置完成"
        return 0
    else
        print_warning "UEFI引导文件缺失"
        return 1
    fi
}

setup_uefi_boot

# ================= 创建ISO =================
print_header "7. 创建ISO镜像"

create_iso() {
    print_step "创建ISO..."
    
    cd "${WORK_DIR}/iso"
    
    # 显示ISO内容
    print_info "ISO目录内容:"
    find . -type f | sort | head -20
    
    # 检查关键文件
    print_info "检查关键文件:"
    [ -f "boot/vmlinuz" ] && echo "✅ boot/vmlinuz" || echo "❌ boot/vmlinuz"
    [ -f "boot/initrd.img" ] && echo "✅ boot/initrd.img" || echo "❌ boot/initrd.img"
    [ -f "boot/isolinux.bin" ] && echo "✅ boot/isolinux.bin" || echo "❌ boot/isolinux.bin"
    [ -f "boot/ldlinux.c32" ] && echo "✅ boot/ldlinux.c32" || echo "❌ boot/ldlinux.c32"
    [ -f "EFI/BOOT/BOOTX64.EFI" ] && echo "✅ EFI/BOOT/BOOTX64.EFI" || echo "❌ EFI/BOOT/BOOTX64.EFI"
    [ -f "img/openwrt.img" ] && echo "✅ img/openwrt.img" || echo "❌ img/openwrt.img"
    
    # 创建ISO
    print_info "使用xorriso创建ISO..."
    
    # 基础命令
    XORRISO_CMD="xorriso -as mkisofs"
    XORRISO_CMD="$XORRISO_CMD -volid 'OPENWRT_INSTALL'"
    XORRISO_CMD="$XORRISO_CMD -J -r -rock"
    XORRISO_CMD="$XORRISO_CMD -full-iso9660-filenames"
    
    # BIOS引导
    if [ -f "boot/isolinux.bin" ]; then
        XORRISO_CMD="$XORRISO_CMD -b boot/isolinux.bin"
        XORRISO_CMD="$XORRISO_CMD -c boot/boot.cat"
        XORRISO_CMD="$XORRISO_CMD -no-emul-boot"
        XORRISO_CMD="$XORRISO_CMD -boot-load-size 4"
        XORRISO_CMD="$XORRISO_CMD -boot-info-table"
    fi
    
    # UEFI引导
    if [ -f "EFI/BOOT/BOOTX64.EFI" ]; then
        XORRISO_CMD="$XORRISO_CMD -eltorito-alt-boot"
        XORRISO_CMD="$XORRISO_CMD -e EFI/BOOT/BOOTX64.EFI"
        XORRISO_CMD="$XORRISO_CMD -no-emul-boot"
        XORRISO_CMD="$XORRISO_CMD -isohybrid-gpt-basdat"
    fi
    
    XORRISO_CMD="$XORRISO_CMD -o '${OUTPUT_ISO}' ."
    
    print_info "执行命令:"
    echo "$XORRISO_CMD"
    
    if eval "$XORRISO_CMD" 2>&1; then
        print_success "ISO创建成功"
    else
        print_warning "主命令失败，尝试简化版本..."
        
        # 简化版本
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -b boot/isolinux.bin \
            -c boot/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -o "${OUTPUT_ISO}" . 2>/dev/null || \
        
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -o "${OUTPUT_ISO}" . 2>/dev/null || return 1
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

create_iso

# ================= 最终报告 =================
print_header "8. 构建完成"

echo ""
echo "══════════════════════════════════════════"
echo "        🎉 OpenWRT安装器构建成功!"
echo "══════════════════════════════════════════"
echo ""

ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)

echo "📊 构建统计:"
echo "  • 输出文件: ${OUTPUT_ISO_FILENAME}"
echo "  • ISO大小: ${ISO_SIZE}"
echo "  • OpenWRT镜像: ${IMG_SIZE_FINAL}"
echo "  • Linux内核: ${KERNEL_SIZE}"
echo "  • Initramfs: $(du -h ${WORK_DIR}/iso/boot/initrd.img 2>/dev/null | cut -f1)"
echo ""

echo "🔧 引导支持:"
echo "  • BIOS引导: $( [ -f ${WORK_DIR}/iso/boot/isolinux.bin ] && echo "✅ 已配置" || echo "❌ 未配置" )"
echo "  • UEFI引导: $( [ -f ${WORK_DIR}/iso/EFI/BOOT/BOOTX64.EFI ] && echo "✅ 已配置" || echo "❌ 未配置" )"
echo ""

echo "🚀 使用方法:"
echo "  1. 写入U盘: dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
echo "  2. 从U盘启动计算机"
echo "  3. 选择'Install OpenWRT'"
echo ""

# 清理
rm -rf "${WORK_DIR}" 2>/dev/null || true

echo "📅 构建时间: $(date)"
echo "══════════════════════════════════════════"

echo ""
print_success "构建流程完成!"
exit 0
