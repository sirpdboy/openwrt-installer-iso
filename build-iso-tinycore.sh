#!/bin/bash
# Ultra Tiny OpenWRT Installer ISO Builder
# 目标：< 50MB，双引导，无需Alpine完整系统

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置 - 修复路径问题
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_IMG="${1:-${SCRIPT_DIR}/assets/openwrt.img}"
OUTPUT_DIR="${2:-${SCRIPT_DIR}/output}"
OUTPUT_ISO_FILENAME="${3:-"openwrt-tiny-installer.iso"}"
OUTPUT_ISO="${OUTPUT_DIR}/${OUTPUT_ISO_FILENAME}"
WORK_DIR="/tmp/tiny-iso-work"

# 日志函数
print_header() { echo -e "${CYAN}\n=== $1 ===${NC}"; }
print_step() { echo -e "${GREEN}▶${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1" >&2; }

# ================= 初始化 =================
print_header "OpenWRT 微型安装器构建系统"

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

# 正确的ISO目录结构
mkdir -p "iso"
mkdir -p "iso/boot"
mkdir -p "iso/boot/grub"           # 重要：GRUB需要这个目录
mkdir -p "iso/EFI/BOOT"            # 重要：UEFI标准路径
mkdir -p "iso/img"
mkdir -p "${OUTPUT_DIR}"

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
    
    # 尝试从多个源下载TinyCore内核
    KERNEL_URLS=(
        "https://github.com/tinycorelinux/Core-scripts/raw/master/vmlinuz64"
        "https://tinycorelinux.net/10.x/x86_64/release/distribution_files/vmlinuz64"
        "https://mirrors.aliyun.com/tinycorelinux/10.x/x86_64/release/distribution_files/vmlinuz64"
    )
    
    for url in "${KERNEL_URLS[@]}"; do
        print_info "尝试: $(basename "$url")"
        
        if command -v wget >/dev/null 2>&1; then
            if wget --tries=1 --timeout=20 -q -O "iso/boot/vmlinuz" "$url"; then
                if [ -s "iso/boot/vmlinuz" ]; then
                    print_success "内核下载成功"
                    return 0
                fi
            fi
        elif command -v curl >/dev/null 2>&1; then
            if curl -L --connect-timeout 15 --retry 1 -s -o "iso/boot/vmlinuz" "$url"; then
                if [ -s "iso/boot/vmlinuz" ]; then
                    print_success "内核下载成功"
                    return 0
                fi
            fi
        fi
    done
    
    # 如果下载失败，检查系统内核
    print_warning "内核下载失败，检查系统内核..."
    
    for kernel in /boot/vmlinuz-* /boot/vmlinuz /vmlinuz; do
        if [ -f "$kernel" ] && [ -s "$kernel" ]; then
            cp "$kernel" "iso/boot/vmlinuz"
            print_success "使用系统内核: $kernel"
            return 0
        fi
    done
    
    # 最后的手段：创建占位文件
    print_warning "创建内核占位文件"
    dd if=/dev/zero of="iso/boot/vmlinuz" bs=1M count=1 2>/dev/null
    echo "LINUX_KERNEL_PLACEHOLDER" >> "iso/boot/vmlinuz"
    
    print_info "注意：需要手动替换为真实内核"
    return 1
}

get_kernel

KERNEL_SIZE=$(du -h "iso/boot/vmlinuz" 2>/dev/null | cut -f1)
KERNEL_BYTES=$(stat -c%s "iso/boot/vmlinuz" 2>/dev/null || echo 0)
print_success "内核准备完成: ${KERNEL_SIZE}"

if [ $KERNEL_BYTES -lt 1000000 ]; then
    print_warning "⚠️  内核文件较小 ($((KERNEL_BYTES/1024))KB)"
    print_info "建议替换为完整Linux内核 (>5MB)"
fi

# ================= 创建initramfs =================
print_header "4. 创建initramfs"

create_initramfs() {
    local initrd_dir="${WORK_DIR}/initrd"
    
    print_step "创建initramfs..."
    
    # 创建initramfs目录
    rm -rf "${initrd_dir}"
    mkdir -p "${initrd_dir}"
    cd "${initrd_dir}"
    
    # 创建目录结构
    mkdir -p bin dev etc proc sys tmp mnt
    
    # 创建init脚本
    cat > init << 'INIT'
#!/bin/sh
# 简单init脚本

# 挂载文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# 创建设备
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true
mknod /dev/zero c 1 5 2>/dev/null || true

# 控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

echo "========================================"
echo "     OpenWRT Installer"
echo "========================================"

# 查找OpenWRT镜像
if [ -b /dev/sr0 ]; then
    mount -t iso9660 /dev/sr0 /mnt 2>/dev/null
    if [ -f /mnt/img/openwrt.img ]; then
        IMG="/mnt/img/openwrt.img"
        echo "找到镜像: $IMG"
    fi
fi

if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
    echo "错误: 未找到OpenWRT镜像"
    echo "进入shell..."
    exec /bin/sh
fi

# 简单安装界面
echo ""
echo "可用磁盘:"
for d in /dev/sd[a-z] /dev/vd[a-z]; do
    [ -b "$d" ] && echo "  $d"
done

echo ""
echo -n "输入磁盘 (如 sda): "
read disk
[ -z "$disk" ] && exec /bin/sh

[[ "$disk" =~ ^/dev/ ]] || disk="/dev/$disk"
[ -b "$disk" ] || { echo "设备不存在"; exec /bin/sh; }

echo ""
echo "警告: 将擦除 $disk !"
echo -n "输入 YES 确认: "
read confirm
[ "$confirm" != "YES" ] && exec /bin/sh

echo ""
echo "正在安装..."
dd if="$IMG" of="$disk" bs=4M 2>&1 | grep -E 'records|bytes|copied' || true
sync

echo ""
echo "✅ 安装完成!"
echo "5秒后重启..."
sleep 5
reboot -f

exec /bin/sh
INIT

    chmod +x init
    
    # 获取busybox
    if command -v busybox >/dev/null 2>&1; then
        cp $(which busybox) bin/busybox
        chmod +x bin/busybox
        cd bin
        ln -s busybox sh 2>/dev/null || true
        ln -s busybox mount 2>/dev/null || true
        ln -s busybox umount 2>/dev/null || true
        ln -s busybox dd 2>/dev/null || true
        ln -s busybox reboot 2>/dev/null || true
        cd ..
    else
        # 创建最小shell
        cat > bin/sh << 'SHELL'
#!/bin/sh
echo "Minimal shell"
while read -p "# " cmd; do
    case "$cmd" in
        ls) echo "dev proc sys";;
        reboot) exit 0;;
        *) echo "Unknown: $cmd";;
    esac
done
SHELL
        chmod +x bin/sh
    fi
    
    # 创建initramfs
    print_step "压缩initramfs..."
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${WORK_DIR}/iso/boot/initrd.img"
    
    INITRD_SIZE=$(du -h "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null | cut -f1)
    print_success "initramfs创建完成: ${INITRD_SIZE}"
    
    return 0
}

create_initramfs

# ================= 配置BIOS引导 (ISOLINUX) =================
print_header "5. 配置BIOS引导 (ISOLINUX)"

setup_bios_boot() {
    print_step "设置ISOLINUX引导..."
    
    # 检查syslinux
    if ! command -v syslinux >/dev/null 2>&1; then
        print_warning "syslinux未安装，跳过BIOS引导"
        return 1
    fi
    
    # 复制引导文件到正确位置
    SYSLINUX_FILES=(
        "isolinux.bin"
        "ldlinux.c32"
        "libcom32.c32"
        "libutil.c32"
    )
    
    local files_found=0
    for file in "${SYSLINUX_FILES[@]}"; do
        for path in /usr/share/syslinux /usr/lib/syslinux; do
            if [ -f "$path/$file" ]; then
                cp "$path/$file" "iso/boot/"
                files_found=1
                break
            fi
        done
    done
    
    if [ $files_found -eq 0 ]; then
        print_warning "未找到ISOLINUX文件"
        return 1
    fi
    
    # 创建ISOLINUX配置文件
    cat > "iso/boot/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT linux
PROMPT 0
TIMEOUT 30
UI menu.c32

MENU TITLE OpenWRT Installer
MENU BACKGROUND splash.png

LABEL linux
  MENU LABEL ^Install OpenWRT
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

    print_success "ISOLINUX配置完成"
    return 0
}

setup_bios_boot

# ================= 配置UEFI引导 (GRUB) =================
print_header "6. 配置UEFI引导 (GRUB)"

setup_uefi_boot() {
    print_step "设置GRUB UEFI引导..."
    
    # 创建GRUB EFI文件
    if command -v grub-mkimage >/dev/null 2>&1; then
        print_info "构建GRUB EFI映像..."
        
        # 创建临时目录
        local grub_temp="/tmp/grub-efi"
        rm -rf "$grub_temp"
        mkdir -p "$grub_temp"
        
        # 构建EFI映像
        if grub-mkimage \
            -O x86_64-efi \
            -o "$grub_temp/grubx64.efi" \
            -p /boot/grub \
            linux part_gpt part_msdos fat iso9660 \
            configfile echo normal terminal \
            2>/dev/null; then
            
            cp "$grub_temp/grubx64.efi" "iso/EFI/BOOT/BOOTX64.EFI"
            print_success "GRUB EFI构建成功"
        else
            print_warning "GRUB EFI构建失败"
        fi
        
        rm -rf "$grub_temp"
    fi
    
    # 如果构建失败，尝试复制现有文件
    if [ ! -f "iso/EFI/BOOT/BOOTX64.EFI" ]; then
        for path in \
            /usr/lib/grub/x86_64-efi/grub.efi \
            /usr/share/grub/x86_64-efi/grub.efi \
            /usr/lib/grub/x86_64-efi-core/grub.efi; do
            
            if [ -f "$path" ]; then
                cp "$path" "iso/EFI/BOOT/BOOTX64.EFI"
                print_success "复制GRUB EFI: $path"
                break
            fi
        done
    fi
    
    # 创建GRUB配置文件
    mkdir -p "iso/boot/grub"
    cat > "iso/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 init=/bin/sh
}

menuentry "Reboot" {
    reboot
}
GRUB_CFG
    
    # 也在EFI目录创建简化配置
    cat > "iso/EFI/BOOT/grub.cfg" << 'EFI_GRUB_CFG'
configfile /boot/grub/grub.cfg
EFI_GRUB_CFG
    
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
    print_step "创建可引导ISO..."
    
    cd "${WORK_DIR}/iso"
    
    # 显示内容
    print_info "ISO目录结构:"
    find . -type f | sort
    
    # 确保有引导文件
    if [ ! -f "boot/isolinux.bin" ] && [ ! -f "EFI/BOOT/BOOTX64.EFI" ]; then
        print_error "没有找到引导文件"
        return 1
    fi
    
    # 使用xorriso创建混合ISO
    if command -v xorriso >/dev/null 2>&1; then
        print_info "使用xorriso创建混合引导ISO..."
        
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
            XORRISO_CMD="$XORRISO_CMD -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin 2>/dev/null"
        fi
        
        # UEFI引导
        if [ -f "EFI/BOOT/BOOTX64.EFI" ]; then
            XORRISO_CMD="$XORRISO_CMD -eltorito-alt-boot"
            XORRISO_CMD="$XORRISO_CMD -e EFI/BOOT/BOOTX64.EFI"
            XORRISO_CMD="$XORRISO_CMD -no-emul-boot"
            XORRISO_CMD="$XORRISO_CMD -isohybrid-gpt-basdat"
        fi
        
        XORRISO_CMD="$XORRISO_CMD -o '${OUTPUT_ISO}' ."
        
        print_info "执行命令..."
        if eval "$XORRISO_CMD" 2>/dev/null; then
            print_success "xorriso执行成功"
        else
            print_warning "xorriso执行有误，尝试简单模式..."
            # 简单模式
            xorriso -as mkisofs -V "OPENWRT" -o "${OUTPUT_ISO}" . 2>/dev/null || return 1
        fi
        
    elif command -v genisoimage >/dev/null 2>&1; then
        print_info "使用genisoimage创建ISO..."
        
        # 检查引导文件
        if [ -f "boot/isolinux.bin" ]; then
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
        print_success "ISO创建成功: ${ISO_SIZE}"
        
        # 验证文件
        if command -v file >/dev/null 2>&1; then
            print_info "文件类型:"
            file "${OUTPUT_ISO}"
        fi
        
        return 0
    else
        print_error "ISO文件未生成"
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

# ================= 验证ISO =================
print_header "8. 验证ISO文件"

verify_iso() {
    print_step "验证ISO内容..."
    
    if [ ! -f "${OUTPUT_ISO}" ]; then
        print_error "ISO文件不存在"
        return 1
    fi
    
    # 检查ISO大小
    ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
    print_info "ISO大小: ${ISO_SIZE}"
    
    # 检查引导信息
    if command -v xorriso >/dev/null 2>&1; then
        print_info "ISO引导信息:"
        xorriso -indev "${OUTPUT_ISO}" -toc 2>&1 | grep -E "(Boot|boot)" || true
        
        echo ""
        print_info "检查关键文件:"
        
        # 检查内核
        if xorriso -indev "${OUTPUT_ISO}" -find /boot -name "vmlinuz" 2>&1 | grep -q "vmlinuz"; then
            print_success "✓ 内核文件存在"
        else
            print_error "✗ 内核文件缺失"
        fi
        
        # 检查initramfs
        if xorriso -indev "${OUTPUT_ISO}" -find /boot -name "initrd.img" 2>&1 | grep -q "initrd.img"; then
            print_success "✓ initramfs文件存在"
        else
            print_error "✗ initramfs文件缺失"
        fi
        
        # 检查BIOS引导
        if xorriso -indev "${OUTPUT_ISO}" -find /boot -name "isolinux.bin" 2>&1 | grep -q "isolinux.bin"; then
            print_success "✓ BIOS引导文件存在"
        else
            print_warning "⚠ BIOS引导文件缺失"
        fi
        
        # 检查UEFI引导
        if xorriso -indev "${OUTPUT_ISO}" -find /EFI -name "BOOTX64.EFI" 2>&1 | grep -q "BOOTX64.EFI"; then
            print_success "✓ UEFI引导文件存在"
        else
            print_warning "⚠ UEFI引导文件缺失"
        fi
        
        # 检查OpenWRT镜像
        if xorriso -indev "${OUTPUT_ISO}" -find /img -name "openwrt.img" 2>&1 | grep -q "openwrt.img"; then
            print_success "✓ OpenWRT镜像存在"
        else
            print_error "✗ OpenWRT镜像缺失"
        fi
    fi
    
    return 0
}

verify_iso

# ================= 最终报告 =================
print_header "9. 构建完成"

echo ""
echo "══════════════════════════════════════════"
echo "        🎉 OpenWRT安装器构建完成!"
echo "══════════════════════════════════════════"
echo ""

# 总结信息
ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)

echo "📊 构建统计:"
echo "  • 输出文件: ${OUTPUT_ISO_FILENAME}"
echo "  • 文件大小: ${ISO_SIZE}"
echo "  • OpenWRT镜像: ${IMG_SIZE_FINAL}"
echo "  • Linux内核: ${KERNEL_SIZE}"
echo ""

# 引导支持检查
echo "🔧 引导支持:"
if [ -f "${WORK_DIR}/iso/boot/isolinux.bin" ]; then
    echo "  ✅ BIOS引导: 已配置"
else
    echo "  ❌ BIOS引导: 未配置"
fi

if [ -f "${WORK_DIR}/iso/EFI/BOOT/BOOTX64.EFI" ]; then
    echo "  ✅ UEFI引导: 已配置"
else
    echo "  ❌ UEFI引导: 未配置"
fi
echo ""

# 使用说明
echo "🚀 使用方法:"
echo "  1. 写入U盘:"
echo "     sudo dd if=${OUTPUT_ISO_FILENAME} of=/dev/sdX bs=4M status=progress"
echo "  2. 设置BIOS/UEFI从U盘启动"
echo "  3. 选择'Install OpenWRT'"
echo "  4. 按照提示完成安装"
echo ""

# 注意事项
if [ $KERNEL_BYTES -lt 1000000 ]; then
    echo "⚠️  重要提示:"
    echo "    检测到内核文件较小 ($((KERNEL_BYTES/1024))KB)"
    echo "    可能需要手动替换为完整Linux内核"
    echo ""
    echo "    替换方法:"
    echo "    1. 从TinyCore Linux下载: https://tinycorelinux.net"
    echo "    2. 文件: vmlinuz64 (约4.8MB)"
    echo "    3. 替换ISO中的 /boot/vmlinuz 文件"
    echo ""
fi

echo "📅 构建时间: $(date)"
echo "══════════════════════════════════════════"

# 清理
rm -rf "${WORK_DIR}" 2>/dev/null || true

echo ""
print_success "构建流程结束"
exit 0
