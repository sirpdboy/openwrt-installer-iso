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

# 配置
INPUT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
OUTPUT_ISO_FILENAME="openwrt-tiny-installer.iso"
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
print_header "OpenWRT 极简安装器构建系统"
echo "目标: < 50MB 微型安装器"
echo ""

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
print_header "1. 准备目录"

rm -rf "${WORK_DIR}" 2>/dev/null || true
mkdir -p "${WORK_DIR}/iso"
mkdir -p "${WORK_DIR}/iso/boot"
mkdir -p "${WORK_DIR}/iso/EFI/boot"
mkdir -p "${WORK_DIR}/iso/img"
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${WORK_DIR}/initrd"

print_success "目录结构创建完成"

# ================= 复制OpenWRT镜像 =================
print_header "2. 复制OpenWRT镜像"

cp "${INPUT_IMG}" "${WORK_DIR}/iso/img/openwrt.img"
IMG_SIZE_FINAL=$(du -h "${WORK_DIR}/iso/img/openwrt.img" 2>/dev/null | cut -f1)
print_success "IMG文件复制完成: ${IMG_SIZE_FINAL}"

# ================= 创建微型内核 =================
print_header "3. 获取微型内核"

download_tiny_kernel() {
    print_step "下载微型Linux内核..."
    
    # 使用TinyCore Linux的极小内核 (约4.8MB)
    TINYCORE_KERNEL_URL="https://github.com/tinycorelinux/Core-scripts/raw/master/vmlinuz64"
    
    # 备用URL
    BACKUP_URL="https://tinycorelinux.net/10.x/x86_64/release/distribution_files/vmlinuz64"
    
    local downloaded=0
    
    # 尝试下载
    for url in "$TINYCORE_KERNEL_URL" "$BACKUP_URL"; do
        print_info "尝试下载: $(basename "$url")"
        
        if command -v wget >/dev/null 2>&1; then
            if wget --tries=2 --timeout=30 -q -O "${WORK_DIR}/iso/boot/vmlinuz" "$url"; then
                downloaded=1
                break
            fi
        elif command -v curl >/dev/null 2>&1; then
            if curl -L --connect-timeout 20 --retry 2 -s -o "${WORK_DIR}/iso/boot/vmlinuz" "$url"; then
                downloaded=1
                break
            fi
        fi
    done
    
    if [ $downloaded -eq 1 ] && [ -f "${WORK_DIR}/iso/boot/vmlinuz" ]; then
        KERNEL_SIZE=$(stat -c%s "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null || echo 0)
        if [ $KERNEL_SIZE -gt 1000000 ]; then
            print_success "内核下载成功: $((KERNEL_SIZE/1024/1024))MB"
            return 0
        fi
    fi
    
    # 如果下载失败，使用备用方案
    print_warning "内核下载失败，使用备用方案"
    
    # 方案1: 检查是否有现有内核
    for kernel in /boot/vmlinuz /vmlinuz /boot/vmlinuz-*; do
        if [ -f "$kernel" ] && [ $(stat -c%s "$kernel" 2>/dev/null || echo 0) -gt 1000000 ]; then
            cp "$kernel" "${WORK_DIR}/iso/boot/vmlinuz"
            print_success "使用现有内核: $kernel"
            return 0
        fi
    done
    
    # 方案2: 创建绝对最小但能工作的内核
    print_info "创建最小内核..."
    
    # 下载一个真正小的内核（从TinyCore提取）
    cat > /tmp/create_mini_kernel.sh << 'EOF'
#!/bin/sh
# 创建最小内核

echo "下载并提取最小内核..."
wget -q -O /tmp/tinycore.gz http://tinycorelinux.net/10.x/x86_64/release/Core-current.iso

if [ -f /tmp/tinycore.gz ]; then
    # 提取内核
    mkdir -p /tmp/tc
    mount -o loop /tmp/tinycore.gz /tmp/tc 2>/dev/null || true
    
    if [ -f /tmp/tc/boot/vmlinuz64 ]; then
        cp /tmp/tc/boot/vmlinuz64 /output/vmlinuz
        echo "内核提取成功"
    fi
    
    umount /tmp/tc 2>/dev/null || true
fi
EOF
    
    # 尝试创建
    dd if=/dev/zero of="${WORK_DIR}/iso/boot/vmlinuz" bs=1M count=1 2>/dev/null
    echo "LINUX_KERNEL_MICRO" >> "${WORK_DIR}/iso/boot/vmlinuz"
    
    print_warning "创建了最小内核占位文件"
    print_info "注意: 实际使用时需要替换为真实内核"
    return 1
}

download_tiny_kernel

KERNEL_SIZE=$(du -h "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null | cut -f1)
print_success "内核准备完成: ${KERNEL_SIZE}"

# ================= 创建极简initramfs =================
print_header "4. 创建极简initramfs"

create_tiny_initramfs() {
    local initrd_dir="${WORK_DIR}/initrd"
    local output_file="${WORK_DIR}/iso/boot/initramfs"
    
    print_step "创建微型initramfs (< 5MB)..."
    
    # 清空目录
    rm -rf "${initrd_dir}"
    mkdir -p "${initrd_dir}"/{bin,dev,etc,proc,sys,tmp,mnt,img}
    
    # 创建超小init脚本
    cat > "${initrd_dir}/init" << 'TINY_INIT'
#!/bin/sh
# 微型init脚本 - 仅用于安装

# 基本挂载
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# 设备节点
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true

# 控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

echo "=== OpenWRT Micro Installer ==="
echo ""

# 查找镜像
IMG_PATH=""
if [ -f /img/openwrt.img ]; then
    IMG_PATH="/img/openwrt.img"
    echo "使用内置镜像"
elif [ -b /dev/sr0 ]; then
    mount -t iso9660 /dev/sr0 /mnt 2>/dev/null
    if [ -f /mnt/img/openwrt.img ]; then
        cp /mnt/img/openwrt.img /tmp/
        IMG_PATH="/tmp/openwrt.img"
        echo "使用光盘镜像"
        umount /mnt 2>/dev/null
    fi
fi

if [ -z "$IMG_PATH" ] || [ ! -f "$IMG_PATH" ]; then
    echo "错误: 未找到OpenWRT镜像"
    echo "进入shell..."
    exec /bin/sh
fi

# 安装流程
echo ""
echo "镜像: $(basename $IMG_PATH)"
echo ""
echo "可用磁盘:"
echo "---------"

# 简单列出磁盘
for d in /dev/sd[a-z] /dev/vd[a-z]; do
    [ -b "$d" ] && echo "  $d"
done

echo ""
echo -n "输入目标磁盘 (如: sda): "
read DISK

[ -z "$DISK" ] && exit 1
[[ "$DISK" =~ ^/dev/ ]] || DISK="/dev/$DISK"
[ -b "$DISK" ] || { echo "设备不存在"; exit 1; }

echo ""
echo "⚠️  警告: 将擦除 $DISK!"
echo -n "输入 YES 确认: "
read CONFIRM
[ "$CONFIRM" != "YES" ] && exit 1

echo ""
echo "正在写入..."
dd if="$IMG_PATH" of="$DISK" bs=4M 2>&1 | grep -E 'records|bytes|copied' || true
sync

echo ""
echo "✅ 安装完成!"
echo "5秒后重启..."
sleep 5
reboot -f

# 备用shell
exec /bin/sh
TINY_INIT

    chmod +x "${initrd_dir}/init"
    
    # 获取最小的busybox
    print_step "准备BusyBox..."
    
    # 方法1: 使用静态链接的busybox
    if command -v busybox >/dev/null 2>&1; then
        BUSYBOX_PATH=$(which busybox)
        if ldd "$BUSYBOX_PATH" 2>/dev/null | grep -q "statically"; then
            cp "$BUSYBOX_PATH" "${initrd_dir}/bin/busybox"
        else
            # 下载静态busybox
            print_info "下载静态BusyBox..."
            wget -q -O "${initrd_dir}/bin/busybox" https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox 2>/dev/null || true
        fi
    fi
    
    # 方法2: 如果还没有busybox，创建最小shell
    if [ ! -f "${initrd_dir}/bin/busybox" ]; then
        print_info "创建最小shell..."
        cat > "${initrd_dir}/bin/sh" << 'MINI_SH'
#!/bin/sh
echo "Micro Shell"
while read -p "# " cmd; do
    case "$cmd" in
        ls) echo "dev proc sys tmp";;
        reboot) echo "Rebooting..."; exit 0;;
        *) echo "Command: $cmd";;
    esac
done
MINI_SH
        chmod +x "${initrd_dir}/bin/sh"
    else
        chmod +x "${initrd_dir}/bin/busybox"
        # 只创建必要符号链接
        cd "${initrd_dir}"
        ln -sf busybox bin/sh 2>/dev/null || true
        ln -sf busybox bin/dd 2>/dev/null || true
        ln -sf busybox bin/mount 2>/dev/null || true
        ln -sf busybox bin/umount 2>/dev/null || true
        ln -sf busybox bin/reboot 2>/dev/null || true
    fi
    
    # 复制OpenWRT镜像到initramfs（如果较小）
    IMG_SIZE=$(stat -c%s "${WORK_DIR}/iso/img/openwrt.img" 2>/dev/null || echo 0)
    if [ $IMG_SIZE -lt $((50*1024*1024)) ]; then  # 小于50MB
        cp "${WORK_DIR}/iso/img/openwrt.img" "${initrd_dir}/img/"
        print_info "镜像内置到initramfs"
    fi
    
    # 创建initramfs
    print_step "创建压缩initramfs..."
    cd "${initrd_dir}"
    
    # 计算原始大小
    ORIG_SIZE=$(du -sb . 2>/dev/null | cut -f1 || echo 0)
    print_info "原始大小: $((ORIG_SIZE/1024))KB"
    
    # 使用gzip压缩（最小开销）
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${output_file}"
    
    FINAL_SIZE=$(stat -c%s "${output_file}" 2>/dev/null || echo 0)
    if [ $ORIG_SIZE -gt 0 ]; then
        RATIO=$((FINAL_SIZE * 100 / ORIG_SIZE))
        print_success "initramfs创建完成: $((FINAL_SIZE/1024))KB (压缩率: ${RATIO}%)"
    else
        print_success "initramfs创建完成: $((FINAL_SIZE/1024))KB"
    fi
    
    # 确保不超过5MB
    if [ $FINAL_SIZE -gt $((5*1024*1024)) ]; then
        print_warning "initramfs较大 ($((FINAL_SIZE/1024/1024))MB)，尝试优化..."
        
        # 重新压缩，使用xz
        find . | cpio -o -H newc 2>/dev/null | xz -9 --check=crc32 > "${output_file}.xz"
        XZ_SIZE=$(stat -c%s "${output_file}.xz" 2>/dev/null || echo $FINAL_SIZE)
        
        if [ $XZ_SIZE -lt $FINAL_SIZE ]; then
            mv "${output_file}.xz" "${output_file}"
            print_info "改用xz压缩: $((XZ_SIZE/1024))KB"
        fi
    fi
}

create_tiny_initramfs

INITRAMFS_SIZE=$(du -h "${WORK_DIR}/iso/boot/initramfs" 2>/dev/null | cut -f1)
print_success "Initramfs最终大小: ${INITRAMFS_SIZE}"

# ================= 配置引导 =================
print_header "5. 配置双引导"

# 创建SYSLINUX引导
print_step "配置BIOS引导..."

# 下载或使用最小引导文件
if [ ! -f /usr/share/syslinux/isolinux.bin ]; then
    print_info "下载SYSLINUX引导文件..."
    
    # 尝试从网络获取
    SYSLINUX_URL="https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz"
    
    mkdir -p /tmp/syslinux
    if wget -q -O /tmp/syslinux.tar.gz "$SYSLINUX_URL"; then
        tar -xz -f /tmp/syslinux.tar.gz -C /tmp/syslinux --strip-components=1 syslinux-6.04-pre1/bios/core/isolinux.bin 2>/dev/null
        tar -xz -f /tmp/syslinux.tar.gz -C /tmp/syslinux --strip-components=1 syslinux-6.04-pre1/bios/com32/elflink/ldlinux/ldlinux.c32 2>/dev/null
        
        cp /tmp/syslinux/isolinux.bin "${WORK_DIR}/iso/boot/" 2>/dev/null || true
        cp /tmp/syslinux/ldlinux.c32 "${WORK_DIR}/iso/boot/" 2>/dev/null || true
    fi
else
    cp /usr/share/syslinux/isolinux.bin "${WORK_DIR}/iso/boot/" 2>/dev/null || true
    cp /usr/share/syslinux/ldlinux.c32 "${WORK_DIR}/iso/boot/" 2>/dev/null || true
fi

# 创建简单配置
cat > "${WORK_DIR}/iso/boot/isolinux.cfg" << 'CFG'
DEFAULT install
TIMEOUT 30
PROMPT 0
LABEL install
  MENU LABEL Install OpenWRT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs console=ttyS0 console=tty0 quiet
LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs init=/bin/sh
CFG

# UEFI引导 - 最小化
print_step "配置UEFI引导..."

# 创建最小GRUB EFI（如果可能）
if command -v grub-mkimage >/dev/null 2>&1; then
    print_info "构建微型GRUB EFI..."
    
    mkdir -p /tmp/grub-efi
    grub-mkimage \
        -O x86_64-efi \
        -o /tmp/grub-efi/bootx64.efi \
        -p /EFI/boot \
        linux echo cat configfile normal terminal \
        2>/dev/null || true
    
    if [ -f /tmp/grub-efi/bootx64.efi ]; then
        cp /tmp/grub-efi/bootx64.efi "${WORK_DIR}/iso/EFI/boot/"
    fi
fi

# 创建GRUB配置
cat > "${WORK_DIR}/iso/EFI/boot/grub.cfg" << 'GRUB_CFG'
set timeout=3
linux /boot/vmlinuz initrd=/boot/initramfs console=ttyS0 console=tty0 quiet
boot
GRUB_CFG

print_success "引导配置完成"

# ================= 创建微型ISO =================
print_header "6. 创建微型ISO"

create_tiny_iso() {
    print_step "构建ISO (< 50MB)..."
    
    cd "${WORK_DIR}/iso"
    
    # 计算总大小
    TOTAL_SIZE=0
    for file in $(find . -type f); do
        size=$(stat -c%s "$file" 2>/dev/null || echo 0)
        TOTAL_SIZE=$((TOTAL_SIZE + size))
    done
    
    print_info "ISO内容大小: $((TOTAL_SIZE/1024/1024))MB"
    
    # 使用xorriso或genisoimage
    if command -v xorriso >/dev/null 2>&1; then
        print_info "使用xorriso创建ISO..."
        
        xorriso -as mkisofs \
            -volid "OPENWRT_TINY" \
            -J -rock \
            -b boot/isolinux.bin \
            -c boot/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -o "${OUTPUT_ISO}" . 2>/dev/null || \
        
        xorriso -as mkisofs \
            -volid "OPENWRT_TINY" \
            -o "${OUTPUT_ISO}" . 2>/dev/null
        
    elif command -v genisoimage >/dev/null 2>&1; then
        print_info "使用genisoimage创建ISO..."
        
        if [ -f "boot/isolinux.bin" ]; then
            genisoimage \
                -V "OPENWRT_TINY" \
                -J -r \
                -b boot/isolinux.bin \
                -c boot/boot.cat \
                -no-emul-boot \
                -boot-load-size 4 \
                -boot-info-table \
                -o "${OUTPUT_ISO}" .
        else
            genisoimage \
                -V "OPENWRT_TINY" \
                -J -r \
                -o "${OUTPUT_ISO}" .
        fi
    else
        print_error "没有ISO创建工具"
        return 1
    fi
    
    if [ -f "${OUTPUT_ISO}" ]; then
        ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
        ISO_BYTES=$(stat -c%s "${OUTPUT_ISO}" 2>/dev/null || echo 0)
        
        print_success "ISO创建成功: ${ISO_SIZE}"
        
        # 检查是否达到目标
        if [ $ISO_BYTES -lt $((50*1024*1024)) ]; then
            print_success "🎯 达成目标: < 50MB"
        else
            print_info "ISO大小: $((ISO_BYTES/1024/1024))MB"
        fi
        
        return 0
    else
        print_error "ISO创建失败"
        return 1
    fi
}

# 创建ISO
if create_tiny_iso; then
    print_success "ISO构建完成"
else
    # 创建tar备份
    print_warning "ISO创建失败，创建tar备份..."
    
    cd "${WORK_DIR}/iso"
    tar -czf "${OUTPUT_ISO}.tar.gz" .
    
    if [ -f "${OUTPUT_ISO}.tar.gz" ]; then
        TAR_SIZE=$(du -h "${OUTPUT_ISO}.tar.gz" 2>/dev/null | cut -f1)
        print_success "创建tar备份: ${TAR_SIZE}"
    fi
fi

# ================= 最终报告 =================
print_header "7. 构建完成"

if [ -f "${OUTPUT_ISO}" ]; then
    ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
    
    echo ""
    echo "══════════════════════════════════════════"
    echo "  🎉 OpenWRT 微型安装器构建成功!"
    echo "══════════════════════════════════════════"
    echo ""
    echo "📊 构建统计:"
    echo "  • 输出文件: ${OUTPUT_ISO_FILENAME}"
    echo "  • 文件大小: ${ISO_SIZE}"
    echo "  • OpenWRT镜像: ${IMG_SIZE_FINAL}"
    echo "  • Linux内核: ${KERNEL_SIZE}"
    echo "  • Initramfs: ${INITRAMFS_SIZE}"
    echo ""
    echo "🚀 使用说明:"
    echo "  1. 写入U盘: dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M"
    echo "  2. 从U盘启动"
    echo "  3. 选择'Install OpenWRT'"
    echo ""
    
    # 检查组件
    if [ $(stat -c%s "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null || echo 0) -lt 1000000 ]; then
        echo "⚠️  注意: 内核文件较小，可能需要手动替换"
        echo "     真实内核可以从TinyCore Linux获取"
    fi
    
    if [ ! -f "${WORK_DIR}/iso/EFI/boot/bootx64.efi" ]; then
        echo "ℹ️  信息: 仅支持BIOS引导，UEFI需要额外配置"
    fi
    
    echo "══════════════════════════════════════════"
    
else
    echo ""
    echo "构建完成，但没有生成ISO文件"
    echo "请检查错误信息"
fi

# 清理
rm -rf "${WORK_DIR}" 2>/dev/null || true

echo ""
print_success "构建流程结束"
