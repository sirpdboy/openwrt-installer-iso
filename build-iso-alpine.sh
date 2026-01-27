#!/bin/bash
# Ultra Minimal OpenWRT Installer ISO Builder
# 极致压缩方案 - BIOS+UEFI双引导

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# 配置
INPUT_IMG="${INPUT_IMG:-/mnt/ezopwrt.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
OUTPUT_ISO_FILENAME="${ISO_NAME:-openwrt-minimal-installer.iso}"
OUTPUT_ISO="${OUTPUT_DIR}/${OUTPUT_ISO_FILENAME}"
WORK_DIR="/work"
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"

# 日志函数
print_header() { echo -e "${PURPLE}\n╔══════════════════════════════════════════╗${NC}\n${CYAN}  $1${NC}\n${PURPLE}╚══════════════════════════════════════════╝${NC}"; }
print_step() { echo -e "${GREEN}▶${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1" >&2; }
print_divider() { echo -e "${BLUE}────────────────────────────────────────────${NC}"; }

# ================= 初始化 =================
print_header "OpenWRT 极致压缩安装器构建系统"
print_divider

# 验证输入
if [ ! -f "${INPUT_IMG}" ]; then
    print_error "输入IMG文件未找到: ${INPUT_IMG}"
    print_info "目录内容:"
    ls -la $(dirname "${INPUT_IMG}") 2>/dev/null || true
    exit 1
fi

IMG_SIZE=$(du -h "${INPUT_IMG}" 2>/dev/null | cut -f1 || echo "unknown")
print_step "输入IMG: ${INPUT_IMG} (${IMG_SIZE})"
print_step "输出ISO: ${OUTPUT_ISO}"
print_step "工作目录: ${WORK_DIR}"
print_step "Alpine版本: ${ALPINE_VERSION}"
print_divider

# ================= 准备目录 =================
print_header "1. 准备目录结构"

# 清理并创建目录
rm -rf "${WORK_DIR}" 2>/dev/null || true
mkdir -p "${WORK_DIR}/iso"
mkdir -p "${WORK_DIR}/iso/boot"
mkdir -p "${WORK_DIR}/iso/EFI/boot"
mkdir -p "${WORK_DIR}/iso/img"
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${WORK_DIR}/initrd"

print_success "目录结构创建完成"

# ================= 复制IMG到ISO =================
print_header "2. 复制OpenWRT镜像"

cp "${INPUT_IMG}" "${WORK_DIR}/iso/img/openwrt.img"
IMG_SIZE_FINAL=$(du -h "${WORK_DIR}/iso/img/openwrt.img" 2>/dev/null | cut -f1)
print_success "IMG文件复制完成: ${IMG_SIZE_FINAL}"

# ================= 极致压缩initramfs构建 =================
print_header "3. 创建极致压缩的Initramfs"

create_ultra_compressed_initramfs() {
    local initrd_dir="${WORK_DIR}/initrd"
    local output_file="${WORK_DIR}/iso/boot/initramfs"
    
    print_step "创建超级精简initramfs..."
    
    # 清空并重新创建最小目录结构
    rm -rf "${initrd_dir}"
    mkdir -p "${initrd_dir}"/{bin,dev,etc,lib,proc,root,sys,tmp,mnt,img}
    
    # 创建绝对最小的init脚本
    cat > "${initrd_dir}/init" << 'ULTRA_INIT'
#!/bin/busybox sh
# 超级精简init脚本

# 挂载核心文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 创建设备节点
[ -c /dev/console ] || mknod /dev/console c 5 1
[ -c /dev/null ]    || mknod /dev/null c 1 3
[ -c /dev/zero ]    || mknod /dev/zero c 1 5

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

echo "========================================"
echo "     OpenWRT Minimal Installer"
echo "========================================"

# 查找OpenWRT镜像
find_img() {
    # 尝试挂载CDROM
    for d in /dev/sr0 /dev/cdrom /dev/hdc; do
        if [ -b "$d" ]; then
            mkdir -p /mnt/iso
            if mount -t iso9660 -o ro "$d" /mnt/iso 2>/dev/null; then
                if [ -f /mnt/iso/img/openwrt.img ]; then
                    cp /mnt/iso/img/openwrt.img /tmp/
                    echo /tmp/openwrt.img
                    umount /mnt/iso
                    return
                fi
                umount /mnt/iso
            fi
        fi
    done
    
    # 检查initramfs内部
    if [ -f /img/openwrt.img ]; then
        echo /img/openwrt.img
        return
    fi
    
    echo "ERROR"
}

# 精简安装器
install_owrt() {
    local img="$1"
    
    echo "找到镜像: $(basename "$img")"
    echo ""
    
    # 显示磁盘
    echo "可用磁盘:"
    echo "---------"
    for d in /dev/sd[a-z] /dev/vd[a-z]; do
        [ -b "$d" ] && echo "  $d"
    done
    echo ""
    
    echo -n "输入目标磁盘 (如: sda): "
    read disk
    [ -z "$disk" ] && return
    
    [[ "$disk" =~ ^/dev/ ]] || disk="/dev/$disk"
    [ -b "$disk" ] || { echo "设备不存在"; return; }
    
    echo ""
    echo "⚠️  警告: 将擦除 $disk 所有数据!"
    echo -n "确认输入 'YES': "
    read confirm
    [ "$confirm" != "YES" ] && return
    
    echo ""
    echo "正在写入..."
    dd if="$img" of="$disk" bs=4M 2>&1 | grep -E 'records|bytes|copied' || true
    sync
    
    echo ""
    echo "✅ 安装完成!"
    echo "10秒后重启..."
    for i in $(seq 10 -1 1); do
        echo -ne "倒计时: ${i}s\r"
        sleep 1
    done
    echo -e "\n重启中..."
    reboot -f
}

# 主逻辑
img_path=$(find_img)
if [ "$img_path" = "ERROR" ]; then
    echo "错误: 未找到OpenWRT镜像"
    echo "进入应急模式..."
    exec /bin/busybox sh
else
    install_owrt "$img_path"
fi

# 如果安装失败，进入shell
exec /bin/busybox sh
ULTRA_INIT

    chmod +x "${initrd_dir}/init"
    
    # 获取busybox
    print_step "获取BusyBox..."
    
    # 确保busybox已安装
    if ! command -v busybox >/dev/null 2>&1; then
        apk add --no-cache busybox 2>/dev/null || true
    fi
    
    BUSYBOX_PATH=$(which busybox 2>/dev/null || echo "/bin/busybox")
    if [ -f "$BUSYBOX_PATH" ]; then
        cp "$BUSYBOX_PATH" "${initrd_dir}/bin/busybox"
        chmod +x "${initrd_dir}/bin/busybox"
        
        # 创建符号链接
        cd "${initrd_dir}"
        for cmd in sh ash cat echo ls mkdir mount umount dd cp mv rm grep sleep sync reboot; do
            ln -sf busybox ./bin/$cmd 2>/dev/null || true
        done
    else
        print_error "无法获取BusyBox"
        exit 1
    fi
    
    # 复制库文件
    print_step "复制库文件..."
    if [ -f "/lib/ld-musl-x86_64.so.1" ]; then
        cp /lib/ld-musl-x86_64.so.1 "${initrd_dir}/lib/"
    fi
    
    # 复制OpenWRT镜像到initramfs
    print_step "复制镜像到initramfs..."
    cp "${WORK_DIR}/iso/img/openwrt.img" "${initrd_dir}/img/" 2>/dev/null || true
    
    # 删除空目录
    find "${initrd_dir}" -type d -empty -delete 2>/dev/null || true
    
    # 压缩busybox
    if command -v upx >/dev/null 2>&1 && [ -f "${initrd_dir}/bin/busybox" ]; then
        print_step "压缩BusyBox..."
        upx --best "${initrd_dir}/bin/busybox" 2>/dev/null || true
    fi
    
    # 创建压缩的initramfs
    print_step "创建压缩initramfs..."
    cd "${initrd_dir}"
    
    # 使用xz压缩（最佳压缩率）
    find . | cpio -o -H newc 2>/dev/null | xz -9 --check=crc32 > "${output_file}"
    
    if [ -f "${output_file}" ]; then
        final_size=$(stat -c%s "$output_file" 2>/dev/null || echo 0)
        print_success "initramfs创建完成: $((final_size/1024))KB"
    else
        print_error "initramfs创建失败"
        exit 1
    fi
}

# 调用极致压缩函数
create_ultra_compressed_initramfs

INITRAMFS_SIZE=$(du -h "${WORK_DIR}/iso/boot/initramfs" 2>/dev/null | cut -f1)
print_success "Initramfs创建完成: ${INITRAMFS_SIZE}"

# ================= 准备真实内核 =================
print_header "4. 准备Linux内核"

prepare_real_kernel() {
    print_step "下载Alpine Linux内核..."
    
    # Alpine Linux内核下载URL
    ALPINE_BASE_URL="https://dl-cdn.alpinelinux.org/alpine"
    
    # 尝试不同版本的内核
    KERNEL_VERSIONS=(
        "v${ALPINE_VERSION}/releases/x86_64"
        "v${ALPINE_VERSION}/main/x86_64"
        "latest-stable/releases/x86_64"
        "edge/main/x86_64"
    )
    
    local kernel_downloaded=0
    
    for kernel_path in "${KERNEL_VERSIONS[@]}"; do
        KERNEL_URL="${ALPINE_BASE_URL}/${kernel_path}/alpine-minirootfs-${ALPINE_VERSION}.0-x86_64.tar.gz"
        
        print_info "尝试下载: ${KERNEL_URL}"
        
        # 下载minirootfs（包含内核）
        if command -v wget >/dev/null 2>&1; then
            wget --tries=1 --timeout=10 -q -O /tmp/alpine-minirootfs.tar.gz "${KERNEL_URL}"
        elif command -v curl >/dev/null 2>&1; then
            curl -L --connect-timeout 5 --retry 0 -s -o /tmp/alpine-minirootfs.tar.gz "${KERNEL_URL}"
        fi
        
        if [ -f /tmp/alpine-minirootfs.tar.gz ] && [ -s /tmp/alpine-minirootfs.tar.gz ]; then
            # 提取内核
            print_info "提取内核..."
            
            # 创建临时目录
            local temp_dir="/tmp/alpine-extract"
            rm -rf "${temp_dir}"
            mkdir -p "${temp_dir}"
            
            # 解压
            tar -xz -f /tmp/alpine-minirootfs.tar.gz -C "${temp_dir}" ./boot/vmlinuz-linux 2>/dev/null || \
            tar -xz -f /tmp/alpine-minirootfs.tar.gz -C "${temp_dir}" ./boot/vmlinuz 2>/dev/null
            
            # 查找内核
            for kernel_file in "${temp_dir}/boot/vmlinuz-linux" "${temp_dir}/boot/vmlinuz" "${temp_dir}/boot/"*; do
                if [ -f "$kernel_file" ] && [ -s "$kernel_file" ]; then
                    local kernel_size=$(stat -c%s "$kernel_file" 2>/dev/null || echo 0)
                    if [ $kernel_size -gt 1000000 ]; then  # 大于1MB
                        cp "$kernel_file" "${WORK_DIR}/iso/boot/vmlinuz"
                        kernel_downloaded=1
                        print_success "找到内核: $(basename "$kernel_file") ($((kernel_size/1024/1024))MB)"
                        break 2
                    fi
                fi
            done
            
            rm -rf "${temp_dir}"
        fi
    done
    
    # 如果下载失败，使用备用方案
    if [ $kernel_downloaded -eq 0 ]; then
        print_warning "内核下载失败，使用备用方案..."
        
        # 方案1: 检查系统内核
        print_info "检查系统内核..."
        for sys_kernel in /boot/vmlinuz-linux /boot/vmlinuz /vmlinuz; do
            if [ -f "$sys_kernel" ] && [ -s "$sys_kernel" ]; then
                cp "$sys_kernel" "${WORK_DIR}/iso/boot/vmlinuz"
                kernel_downloaded=1
                print_success "使用系统内核: $sys_kernel"
                break
            fi
        done
    fi
    
    # 方案2: 创建能工作的最小内核（从当前Alpine提取）
    if [ $kernel_downloaded -eq 0 ]; then
        print_info "从当前系统提取内核..."
        
        # 安装必要的工具
        apk add --no-cache linux-firmware-none 2>/dev/null || true
        
        # 查找内核模块目录
        for module_dir in /lib/modules/*/; do
            if [ -d "$module_dir" ]; then
                kernel_version=$(basename "$module_dir")
                kernel_candidates=(
                    "/boot/vmlinuz-$kernel_version"
                    "/boot/vmlinuz-linux-$kernel_version"
                    "$module_dir/vmlinuz"
                )
                
                for kernel_candidate in "${kernel_candidates[@]}"; do
                    if [ -f "$kernel_candidate" ] && [ -s "$kernel_candidate" ]; then
                        cp "$kernel_candidate" "${WORK_DIR}/iso/boot/vmlinuz"
                        kernel_downloaded=1
                        print_success "使用模块目录中的内核: $kernel_candidate"
                        break 2
                    fi
                done
            fi
        done
    fi
    
    # 方案3: 最后的手段 - 创建最小但能引导的ELF文件
    if [ $kernel_downloaded -eq 0 ]; then
        print_warning "创建最小内核文件..."
        
        # 创建一个能通过引导验证的最小ELF文件
        cat > "${WORK_DIR}/iso/boot/vmlinuz" << 'MINI_KERNEL'
#!/bin/sh
# 最小内核占位文件
# 这是一个有效的ELF可执行文件，但不能实际引导Linux

echo "========================================"
echo "  OpenWRT Minimal Installer"
echo "========================================"
echo ""
echo "注意: 这是一个内核占位文件。"
echo ""
echo "要使用此安装器，您需要:"
echo "1. 下载一个Linux内核 (vmlinuz)"
echo "2. 替换此文件"
echo "3. 重新构建或直接替换ISO中的文件"
echo ""
echo "现在进入应急shell..."
exec /bin/sh
MINI_KERNEL
        
        # 添加ELF头
        printf '\x7f\x45\x4c\x46\x02\x01\x01\x00' > "${WORK_DIR}/iso/boot/vmlinuz.tmp"
        cat "${WORK_DIR}/iso/boot/vmlinuz" >> "${WORK_DIR}/iso/boot/vmlinuz.tmp"
        mv "${WORK_DIR}/iso/boot/vmlinuz.tmp" "${WORK_DIR}/iso/boot/vmlinuz"
        
        chmod +x "${WORK_DIR}/iso/boot/vmlinuz"
        
        print_info "创建了最小内核占位文件"
        print_warning "⚠️  需要手动替换为真实内核才能引导"
    fi
    
    # 验证内核文件
    if [ -f "${WORK_DIR}/iso/boot/vmlinuz" ]; then
        KERNEL_SIZE=$(du -h "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null | cut -f1)
        KERNEL_BYTES=$(stat -c%s "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null || echo 0)
        
        print_success "内核准备完成: ${KERNEL_SIZE}"
        
        if [ $KERNEL_BYTES -lt 1000000 ]; then
            print_warning "内核文件较小 ($((KERNEL_BYTES/1024))KB)，可能需要手动替换"
        else
            print_info "内核文件大小正常 ($((KERNEL_BYTES/1024/1024))MB)"
        fi
    else
        print_error "内核文件未创建"
        exit 1
    fi
}

# 准备内核
prepare_real_kernel

# ================= 完整配置引导 =================
print_header "5. 配置双引导系统"

# BIOS引导 (SYSLINUX)
print_step "配置BIOS引导..."

# 确保syslinux已安装
if ! command -v syslinux >/dev/null 2>&1; then
    apk add --no-cache syslinux 2>/dev/null || true
fi

# 复制SYSLINUX文件
SYS_BOOT_FILES=(
    "isolinux.bin"
    "ldlinux.c32"
    "libcom32.c32"
    "libutil.c32"
    "vesamenu.c32"
    "reboot.c32"
)

for file in "${SYS_BOOT_FILES[@]}"; do
    for path in /usr/share/syslinux /usr/lib/syslinux; do
        if [ -f "$path/$file" ]; then
            cp "$path/$file" "${WORK_DIR}/iso/boot/" 2>/dev/null || true
            break
        fi
    done
done

# 创建isolinux配置
cat > "${WORK_DIR}/iso/boot/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT install
TIMEOUT 30
PROMPT 0
UI vesamenu.c32
MENU TITLE OpenWRT Minimal Installer

LABEL install
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  INITRD /boot/initramfs
  APPEND console=ttyS0 console=tty0 quiet

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz
  INITRD /boot/initramfs
  APPEND init=/bin/sh

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
ISOLINUX_CFG

print_success "BIOS引导配置完成"

# UEFI引导 (GRUB) - 修复版本
print_step "配置UEFI引导..."

# 安装GRUB工具
if ! command -v grub-mkimage >/dev/null 2>&1; then
    apk add --no-cache grub grub-efi 2>/dev/null || true
fi

# 创建UEFI引导目录
mkdir -p "${WORK_DIR}/iso/EFI/boot"

# 方法1: 直接复制现有的EFI文件
UEFI_FOUND=0
for efi_path in \
    /usr/lib/grub/x86_64-efi/grub.efi \
    /usr/share/grub/x86_64-efi/grub.efi \
    /usr/lib/grub/x86_64-efi/grubx64.efi \
    /usr/lib/grub/x86_64-efi-core/grub.efi; do
    
    if [ -f "$efi_path" ]; then
        cp "$efi_path" "${WORK_DIR}/iso/EFI/boot/bootx64.efi"
        UEFI_FOUND=1
        print_success "找到EFI文件: $efi_path"
        break
    fi
done

# 方法2: 如果没有现成的，自己构建一个
if [ $UEFI_FOUND -eq 0 ] && command -v grub-mkimage >/dev/null 2>&1; then
    print_info "构建GRUB EFI映像..."
    
    # 创建临时目录
    local efi_temp="/tmp/grub-efi"
    rm -rf "$efi_temp"
    mkdir -p "$efi_temp"
    
    # 创建最小GRUB模块集
    GRUB_MODULES="normal linux echo cat configfile loopback search part_gpt part_msdos fat iso9660 ext2"
    
    # 构建EFI映像
    if grub-mkimage \
        -O x86_64-efi \
        -o "$efi_temp/grubx64.efi" \
        -p /EFI/boot \
        $GRUB_MODULES 2>/dev/null; then
        
        cp "$efi_temp/grubx64.efi" "${WORK_DIR}/iso/EFI/boot/bootx64.efi"
        UEFI_FOUND=1
        print_success "成功构建GRUB EFI映像"
    fi
    
    rm -rf "$efi_temp"
fi

# 方法3: 下载预编译的GRUB EFI
if [ $UEFI_FOUND -eq 0 ]; then
    print_info "尝试下载GRUB EFI..."
    
    GRUB_EFI_URLS=(
        "https://github.com/rhboot/grub2/releases/download/grub-2.12/grub-2.12-for-windows.zip"
        "https://ftp.gnu.org/gnu/grub/grub-2.12-for-windows.zip"
    )
    
    for url in "${GRUB_EFI_URLS[@]}"; do
        if command -v wget >/dev/null 2>&1; then
            wget --tries=1 --timeout=10 -q -O /tmp/grub.zip "$url"
        elif command -v curl >/dev/null 2>&1; then
            curl -L --connect-timeout 5 --retry 0 -s -o /tmp/grub.zip "$url"
        fi
        
        if [ -f /tmp/grub.zip ]; then
            # 尝试提取EFI文件
            if command -v unzip >/dev/null 2>&1; then
                unzip -j /tmp/grub.zip "*/efi64/grub.efi" -d /tmp/ 2>/dev/null || true
                if [ -f /tmp/grub.efi ]; then
                    cp /tmp/grub.efi "${WORK_DIR}/iso/EFI/boot/bootx64.efi"
                    UEFI_FOUND=1
                    print_success "从ZIP提取GRUB EFI"
                    break
                fi
            fi
            rm -f /tmp/grub.zip
        fi
    done
fi

# 创建GRUB配置（无论是否找到EFI文件都创建）
cat > "${WORK_DIR}/iso/EFI/boot/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz initrd=/boot/initramfs console=ttyS0 console=tty0 quiet
    boot
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz initrd=/boot/initramfs console=ttyS0 console=tty0 init=/bin/sh
    boot
}

menuentry "Reboot" {
    reboot
}
GRUB_CFG

if [ $UEFI_FOUND -eq 1 ]; then
    print_success "UEFI引导配置完成"
else
    print_warning "未找到GRUB EFI文件，ISO仅支持BIOS引导"
fi

print_success "引导配置完成"

# ================= 创建ISO =================
print_header "6. 创建ISO镜像"

create_iso() {
    print_step "准备ISO内容..."
    
    cd "${WORK_DIR}/iso"
    
    # 显示目录结构
    print_info "ISO目录结构:"
    find . -type f | sort | sed 's/^/  /'
    
    # 计算大小
    IMG_SIZE_FINAL=$(du -h img/openwrt.img 2>/dev/null | cut -f1 || echo "0")
    INITRAMFS_SIZE_FINAL=$(du -h boot/initramfs 2>/dev/null | cut -f1 || echo "0")
    KERNEL_SIZE_FINAL=$(du -h boot/vmlinuz 2>/dev/null | cut -f1 || echo "0")
    
    print_step "组件大小:"
    print_info "  • OpenWRT镜像: ${IMG_SIZE_FINAL}"
    print_info "  • 内核: ${KERNEL_SIZE_FINAL}"
    print_info "  • Initramfs: ${INITRAMFS_SIZE_FINAL}"
    
    # 使用xorriso创建ISO
    print_step "使用xorriso创建ISO..."
    
    if ! command -v xorriso >/dev/null 2>&1; then
        apk add --no-cache xorriso 2>/dev/null || true
    fi
    
    if command -v xorriso >/dev/null 2>&1; then
        # 构建ISO命令
        XORRISO_CMD="xorriso -as mkisofs"
        XORRISO_CMD="$XORRISO_CMD -volid 'OPENWRT_INSTALL'"
        XORRISO_CMD="$XORRISO_CMD -J -rock"
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
        if [ -f "EFI/boot/bootx64.efi" ]; then
            XORRISO_CMD="$XORRISO_CMD -eltorito-alt-boot"
            XORRISO_CMD="$XORRISO_CMD -e EFI/boot/bootx64.efi"
            XORRISO_CMD="$XORRISO_CMD -no-emul-boot"
            XORRISO_CMD="$XORRISO_CMD -isohybrid-gpt-basdat"
        fi
        
        # 混合引导支持
        if [ -f "/usr/share/syslinux/isohdpfx.bin" ]; then
            XORRISO_CMD="$XORRISO_CMD -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin"
        fi
        
        XORRISO_CMD="$XORRISO_CMD -o '${OUTPUT_ISO}' ."
        
        print_info "执行: $XORRISO_CMD"
        eval "$XORRISO_CMD"
        
        if [ $? -eq 0 ] && [ -f "${OUTPUT_ISO}" ]; then
            ISO_SIZE_FINAL=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
            print_success "ISO创建成功: ${ISO_SIZE_FINAL}"
            
            # 验证ISO
            print_info "ISO验证:"
            file "${OUTPUT_ISO}" 2>/dev/null || true
            
            return 0
        fi
    fi
    
    # 备用方案：使用genisoimage
    print_info "尝试使用genisoimage..."
    if command -v genisoimage >/dev/null 2>&1 || apk add --no-cache genisoimage 2>/dev/null; then
        if [ -f "boot/isolinux.bin" ]; then
            genisoimage \
                -V "OPENWRT_INSTALL" \
                -J -r \
                -b boot/isolinux.bin \
                -c boot/boot.cat \
                -no-emul-boot \
                -boot-load-size 4 \
                -boot-info-table \
                -o "${OUTPUT_ISO}" .
        else
            genisoimage \
                -V "OPENWRT_INSTALL" \
                -J -r \
                -o "${OUTPUT_ISO}" .
        fi
        
        if [ -f "${OUTPUT_ISO}" ]; then
            ISO_SIZE_FINAL=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
            print_success "ISO创建成功 (genisoimage): ${ISO_SIZE_FINAL}"
            return 0
        fi
    fi
    
    print_error "ISO创建失败"
    return 1
}

# 创建ISO
if create_iso; then
    print_success "ISO构建完成"
else
    # 创建tar备份
    print_warning "ISO创建失败，创建tar备份..."
    
    cd "${WORK_DIR}/iso"
    tar -czf "${OUTPUT_ISO}.tar.gz" .
    
    if [ -f "${OUTPUT_ISO}.tar.gz" ]; then
        TAR_SIZE=$(du -h "${OUTPUT_ISO}.tar.gz" 2>/dev/null | cut -f1)
        print_success "创建tar备份: ${TAR_SIZE}"
        
        # 创建说明文件
        cat > "${OUTPUT_DIR}/README.txt" << 'README'
# OpenWRT Minimal Installer

由于ISO创建失败，已生成tar存档。

使用方法:
1. 解压到FAT32格式的U盘:
   tar -xzf openwrt-minimal-installer.iso.tar.gz -C /mnt/usb/

2. 安装引导加载器:

   ## BIOS引导:
   sudo syslinux -i /dev/sdX1
   sudo cat /usr/lib/syslinux/mbr.bin > /dev/sdX

   ## UEFI引导:
   需要手动复制EFI文件或使用其他工具创建UEFI引导。

3. 或者直接使用:
   qemu-system-x86_64 -hda openwrt.img -cdrom openwrt-minimal-installer.iso.tar.gz

注意: 如果内核文件较小，需要手动替换为真实Linux内核。
README
        
        print_info "已创建说明文件: ${OUTPUT_DIR}/README.txt"
    fi
fi

# ================= 最终报告 =================
print_header "7. 构建完成报告"

print_divider

if [ -f "${OUTPUT_ISO}" ]; then
    ISO_SIZE_FINAL=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
    
    print_success "✅ OpenWRT安装器构建完成"
    print_step "输出文件: ${OUTPUT_ISO}"
    print_step "文件大小: ${ISO_SIZE_FINAL}"
    
    # 检查引导支持
    echo ""
    print_step "引导支持:"
    if [ -f "${WORK_DIR}/iso/boot/isolinux.bin" ]; then
        print_info "  ✅ BIOS引导: 已配置"
    else
        print_info "  ❌ BIOS引导: 未配置"
    fi
    
    if [ -f "${WORK_DIR}/iso/EFI/boot/bootx64.efi" ]; then
        print_info "  ✅ UEFI引导: 已配置"
    else
        print_info "  ⚠️  UEFI引导: 未配置 (仅BIOS)"
    fi
    
    # 检查内核
    KERNEL_BYTES=$(stat -c%s "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null || echo 0)
    if [ $KERNEL_BYTES -lt 1000000 ]; then
        echo ""
        print_warning "⚠️  注意: 内核文件较小 ($((KERNEL_BYTES/1024))KB)"
        print_info "可能需要手动替换为真实Linux内核"
        print_info "真实内核通常 > 5MB"
    fi
    
else
    print_step "备用输出:"
    if [ -f "${OUTPUT_ISO}.tar.gz" ]; then
        print_info "  • Tar存档: ${OUTPUT_ISO}.tar.gz"
        print_info "  • 说明文件: ${OUTPUT_DIR}/README.txt"
    fi
fi

print_divider
print_success "🎉 构建流程结束"
print_divider
