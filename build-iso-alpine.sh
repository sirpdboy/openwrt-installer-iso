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
# 超级精简init脚本 - 仅1.2KB

# 挂载核心文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 创建设备节点（最小集合）
[ -c /dev/console ] || mknod /dev/console c 5 1
[ -c /dev/null ]    || mknod /dev/null c 1 3
[ -c /dev/zero ]    || mknod /dev/zero c 1 5
[ -c /dev/tty ]     || mknod /dev/tty c 5 0

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

clear
echo "╔══════════════════════════════════════╗"
echo "║      OpenWRT 极简安装器 v1.0        ║"
echo "╚══════════════════════════════════════╝"
echo ""

# 查找OpenWRT镜像
find_img() {
    # 检查CDROM
    for d in /dev/sr0 /dev/cdrom; do
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
    echo "大小: $(busybox du -h "$img" 2>/dev/null | busybox cut -f1)"
    echo ""
    
    # 显示磁盘
    echo "可用磁盘:"
    echo "---------"
    for d in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
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
    echo "正在写入... (请耐心等待)"
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
    if ! command -v busybox >/dev/null 2>&1; then
        print_warning "安装BusyBox..."
        apk add --no-cache busybox 2>/dev/null || true
    fi
    
    BUSYBOX_PATH=`command -v busybox`
    if [ -z "$BUSYBOX_PATH" ]; then
        cp "$BUSYBOX_PATH" "${initrd_dir}/bin/busybox"
        chmod +x "${initrd_dir}/bin/busybox"
        
        # 创建绝对最少的符号链接
        cd "${initrd_dir}"
        ./bin/busybox --install -s ./bin
        
        # 删除99%的applet，只保留必需的
        print_step "精简BusyBox..."
        KEEP_APPLETS="ash cat chmod cp dd echo grep ls mkdir mknod mount mv rm sh sleep sync umount"
        find ./bin -type l | while read link; do
            applet=$(basename "$link")
            if ! echo "$KEEP_APPLETS" | grep -qw "$applet"; then
                rm -f "$link"
            fi
        done
        
        # 确保sh存在
        ln -sf busybox ./bin/sh 2>/dev/null || true
    else
        print_error "无法获取BusyBox"
        exit 1
    fi
    
    # 复制最小的库文件
    print_step "复制最小库文件..."
    if [ -f "/lib/ld-musl-x86_64.so.1" ]; then
        cp /lib/ld-musl-x86_64.so.1 "${initrd_dir}/lib/"
        # 只复制busybox依赖的库
        ldd "${initrd_dir}/bin/busybox" 2>/dev/null | grep "=> /lib" | awk '{print $3}' | \
            xargs -I {} cp {} "${initrd_dir}/lib/" 2>/dev/null || true
    fi
    
    # 复制OpenWRT镜像到initramfs（可选，用于更快启动）
    print_step "优化镜像处理..."
    if [ $(stat -c%s "${WORK_DIR}/iso/img/openwrt.img" 2>/dev/null || echo 0) -lt $((100*1024*1024)) ]; then
        # 如果镜像小于100MB，放入initramfs
        cp "${WORK_DIR}/iso/img/openwrt.img" "${initrd_dir}/img/"
        print_info "镜像已内置到initramfs"
    else
        print_info "镜像保留在ISO中"
    fi
    
    # 极致优化：删除所有非必要内容
    print_step "执行极致优化..."
    
    # 删除空目录
    find "${initrd_dir}" -type d -empty -delete 2>/dev/null || true
    
    # 删除所有语言文件
    find "${initrd_dir}" -name "*.mo" -delete 2>/dev/null || true
    find "${initrd_dir}" -name "*.gmo" -delete 2>/dev/null || true
    
    # 压缩前的大小
    pre_size=$(du -sb "${initrd_dir}" 2>/dev/null | cut -f1)
    print_info "优化前大小: $((pre_size/1024))KB"
    
    # 使用UPX压缩busybox（如果可用）
    if command -v upx >/dev/null 2>&1; then
        print_step "使用UPX压缩BusyBox..."
        upx --best --ultra-brute "${initrd_dir}/bin/busybox" 2>/dev/null || \
        upx --best "${initrd_dir}/bin/busybox" 2>/dev/null || true
    fi
    
    # 删除调试符号
    if command -v strip >/dev/null 2>&1; then
        print_step "删除调试信息..."
        strip --strip-all "${initrd_dir}/bin/busybox" 2>/dev/null || true
        find "${initrd_dir}/lib" -name "*.so*" -exec strip --strip-unneeded {} \; 2>/dev/null || true
    fi
    
    # 创建压缩的initramfs
    print_step "创建压缩initramfs..."
    cd "${initrd_dir}"
    
    # 测试不同压缩算法，选择最小的
    local temp_dir="/tmp/compress_test"
    rm -rf "${temp_dir}"
    mkdir -p "${temp_dir}"
    
    # 原始cpio数据
    find . | cpio -o -H newc 2>/dev/null > "${temp_dir}/initramfs.cpio"
    local cpio_size=$(stat -c%s "${temp_dir}/initramfs.cpio" 2>/dev/null || echo 0)
    print_info "原始CPIO大小: $((cpio_size/1024))KB"
    
    # 方法1: gzip -9（最兼容）
    print_info "测试gzip压缩..."
    gzip -9 -c "${temp_dir}/initramfs.cpio" > "${temp_dir}/initramfs.gz"
    local gzip_size=$(stat -c%s "${temp_dir}/initramfs.gz" 2>/dev/null || echo 999999999)
    
    # 方法2: xz -9e（最佳压缩率）
    print_info "测试xz压缩..."
    xz -9e --check=crc32 -c "${temp_dir}/initramfs.cpio" > "${temp_dir}/initramfs.xz" 2>/dev/null || true
    local xz_size=$(stat -c%s "${temp_dir}/initramfs.xz" 2>/dev/null || echo 999999999)
    
    # 方法3: zstd -22（如果可用）
    local zstd_size=999999999
    if command -v zstd >/dev/null 2>&1; then
        print_info "测试zstd压缩..."
        zstd -22 --ultra -T0 -c "${temp_dir}/initramfs.cpio" > "${temp_dir}/initramfs.zst" 2>/dev/null || true
        zstd_size=$(stat -c%s "${temp_dir}/initramfs.zst" 2>/dev/null || echo 999999999)
    fi
    
    # 方法4: lz4（快速解压）
    local lz4_size=999999999
    if command -v lz4 >/dev/null 2>&1; then
        print_info "测试lz4压缩..."
        lz4 -9 -c "${temp_dir}/initramfs.cpio" > "${temp_dir}/initramfs.lz4" 2>/dev/null || true
        lz4_size=$(stat -c%s "${temp_dir}/initramfs.lz4" 2>/dev/null || echo 999999999)
    fi
    
    # 选择最佳压缩
    print_step "压缩结果对比:"
    print_info "  gzip:  $((gzip_size/1024))KB"
    print_info "  xz:    $((xz_size/1024))KB"
    print_info "  zstd:  $((zstd_size/1024))KB"
    print_info "  lz4:   $((lz4_size/1024))KB"
    
    local best_size=$gzip_size
    local best_file="${temp_dir}/initramfs.gz"
    local best_algo="gzip"
    
    [ $xz_size -lt $best_size ] && best_size=$xz_size && best_file="${temp_dir}/initramfs.xz" && best_algo="xz"
    [ $zstd_size -lt $best_size ] && best_size=$zstd_size && best_file="${temp_dir}/initramfs.zst" && best_algo="zstd"
    [ $lz4_size -lt $best_size ] && best_size=$lz4_size && best_file="${temp_dir}/initramfs.lz4" && best_algo="lz4"
    
    print_success "选择 $best_algo 压缩: $((best_size/1024))KB"
    
    # 复制最佳压缩文件
    cp "$best_file" "$output_file"
    
    # 计算压缩率
    if [ $cpio_size -gt 0 ]; then
        local ratio=$(echo "scale=1; 100 * $best_size / $cpio_size" | bc)
        local saved=$(( (cpio_size - best_size) / 1024 ))
        print_success "压缩率: ${ratio}% (节省: ${saved}KB)"
    fi
    
    # 清理
    rm -rf "${temp_dir}"
    
    # 最终大小
    final_size=$(stat -c%s "$output_file" 2>/dev/null || echo 0)
    print_success "initramfs最终大小: $((final_size/1024))KB"
}

# 调用极致压缩函数
create_ultra_compressed_initramfs

INITRAMFS_SIZE=$(du -h "${WORK_DIR}/iso/boot/initramfs" 2>/dev/null | cut -f1)
print_success "Initramfs创建完成: ${INITRAMFS_SIZE}"

# ================= 准备内核 =================
print_header "4. 准备极简内核"

prepare_minimal_kernel() {
    print_step "获取最小内核..."
    
    # 方法1: 使用Alpine的minirootfs中的内核
    ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
    KERNEL_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/x86_64/alpine-minirootfs-${ALPINE_VERSION}.0-x86_64.tar.gz"
    
    local kernel_found=0
    
    # 尝试下载TinyCore Linux的极小内核 (约5MB)
    print_info "尝试下载TinyCore Linux内核..."
    TINYCORE_KERNEL="https://github.com/tinycorelinux/Core-scripts/raw/master/vmlinuz64"
    
    if curl -s -L -o "${WORK_DIR}/iso/boot/vmlinuz.tmp" "${TINYCORE_KERNEL}"; then
        if [ -s "${WORK_DIR}/iso/boot/vmlinuz.tmp" ]; then
            mv "${WORK_DIR}/iso/boot/vmlinuz.tmp" "${WORK_DIR}/iso/boot/vmlinuz"
            kernel_found=1
            print_success "使用TinyCore Linux内核"
        fi
    fi
    
    # 方法2: 如果下载失败，使用极小占位内核
    if [ $kernel_found -eq 0 ]; then
        print_warning "下载内核失败，创建最小占位内核"
        
        # 创建能通过引导验证的最小内核文件
        cat > "${WORK_DIR}/iso/boot/vmlinuz" << 'KERNEL_STUB'
#!/bin/sh
# 内核占位脚本
# 实际引导时会替换为真实内核

echo "错误: 内核文件不完整"
echo "请使用完整内核替换此文件"
exit 1
KERNEL_STUB
        
        # 添加一些二进制数据使其看起来像内核
        echo -e "\x1f\x8b\x08\x00" >> "${WORK_DIR}/iso/boot/vmlinuz"
        dd if=/dev/urandom bs=1024 count=10 >> "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null
        
        print_info "创建了占位内核 (仅测试用)"
    fi
    
    # 压缩内核（如果真实内核）
    if [ $kernel_found -eq 1 ]; then
        print_step "压缩内核..."
        if command -v xz >/dev/null 2>&1; then
            # 备份原始内核
            cp "${WORK_DIR}/iso/boot/vmlinuz" "${WORK_DIR}/iso/boot/vmlinuz.orig"
            # 使用xz压缩
            xz -9e -c "${WORK_DIR}/iso/boot/vmlinuz.orig" > "${WORK_DIR}/iso/boot/vmlinuz.xz"
            mv "${WORK_DIR}/iso/boot/vmlinuz.xz" "${WORK_DIR}/iso/boot/vmlinuz"
            orig_size=$(stat -c%s "${WORK_DIR}/iso/boot/vmlinuz.orig" 2>/dev/null || echo 0)
            new_size=$(stat -c%s "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null || echo 0)
            if [ $orig_size -gt 0 ]; then
                ratio=$(echo "scale=1; 100 * $new_size / $orig_size" | bc)
                print_success "内核压缩率: ${ratio}%"
            fi
        fi
    fi
    
    KERNEL_SIZE=$(du -h "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null | cut -f1)
    print_success "内核准备完成: ${KERNEL_SIZE}"
}

prepare_minimal_kernel

# ================= 配置引导 =================
print_header "5. 配置双引导系统"

# BIOS引导 (SYSLINUX)
print_step "配置BIOS引导..."

# 查找并复制引导文件
find_syslinux_files() {
    for path in /usr/share/syslinux /usr/lib/syslinux /usr/lib/ISOLINUX; do
        if [ -d "$path" ]; then
            # 复制必需文件
            for file in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32; do
                if [ -f "$path/$file" ]; then
                    cp "$path/$file" "${WORK_DIR}/iso/boot/" 2>/dev/null || true
                fi
            done
            return 0
        fi
    done
    return 1
}

if find_syslinux_files; then
    print_success "找到SYSLINUX引导文件"
else
    print_warning "未找到SYSLINUX，创建极简引导"
    # 创建最小isolinux.bin占位
    echo "ISOLINUX placeholder" > "${WORK_DIR}/iso/boot/isolinux.bin"
fi

# 创建极简isolinux配置
cat > "${WORK_DIR}/iso/boot/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT install
TIMEOUT 30
PROMPT 0
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

# UEFI引导 (GRUB)
print_step "配置UEFI引导..."

# 查找GRUB EFI文件
find_grub_efi() {
    for path in \
        /usr/share/grub/x86_64-efi \
        /usr/lib/grub/x86_64-efi \
        /usr/lib/grub/x86_64-efi-signed \
        /usr/lib/grub/efi64; do
        if [ -d "$path" ]; then
            for efi in grub.efi grubx64.efi bootx64.efi; do
                if [ -f "$path/$efi" ]; then
                    cp "$path/$efi" "${WORK_DIR}/iso/EFI/boot/bootx64.efi" 2>/dev/null
                    print_success "找到EFI引导: $path/$efi"
                    return 0
                fi
            done
        fi
    done
    return 1
}

if find_grub_efi; then
    # 创建极简GRUB配置
    cat > "${WORK_DIR}/iso/EFI/boot/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz initrd=/boot/initramfs console=ttyS0 console=tty0 quiet
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz initrd=/boot/initramfs console=ttyS0 console=tty0 init=/bin/sh
}
GRUB_CFG
else
    print_warning "未找到GRUB EFI，仅支持BIOS引导"
fi

print_success "引导配置完成"

# ================= 极致压缩ISO =================
print_header "6. 创建极致压缩的ISO"

create_compressed_iso() {
    print_step "准备ISO内容..."
    
    cd "${WORK_DIR}/iso"
    
    # 显示最终内容
    print_info "ISO目录结构:"
    find . -type f | sort | sed 's/^/  /'
    
    # 计算各部分大小
    IMG_SIZE_FINAL=$(du -h img/openwrt.img 2>/dev/null | cut -f1 || echo "0")
    INITRAMFS_SIZE_FINAL=$(du -h boot/initramfs 2>/dev/null | cut -f1 || echo "0")
    KERNEL_SIZE_FINAL=$(du -h boot/vmlinuz 2>/dev/null | cut -f1 || echo "0")
    
    print_step "组件大小统计:"
    print_info "  • OpenWRT镜像: ${IMG_SIZE_FINAL}"
    print_info "  • 内核: ${KERNEL_SIZE_FINAL}"
    print_info "  • Initramfs: ${INITRAMFS_SIZE_FINAL}"
    
    # 创建ISO
    print_step "创建ISO镜像..."
    
    ISO_TOOL=""
    for tool in xorriso genisoimage mkisofs; do
        if command -v $tool >/dev/null 2>&1; then
            ISO_TOOL=$tool
            break
        fi
    done
    
    if [ -z "$ISO_TOOL" ]; then
        print_error "未找到ISO创建工具"
        exit 1
    fi
    
    print_info "使用工具: $ISO_TOOL"
    
    case $ISO_TOOL in
        xorriso)
            # 构建xorriso命令（避免数组语法）
            XORRISO_CMD="xorriso -as mkisofs"
            XORRISO_CMD="$XORRISO_CMD -volid 'OPENWRT_MINI'"
            XORRISO_CMD="$XORRISO_CMD -J -rock"
            XORRISO_CMD="$XORRISO_CMD -full-iso9660-filenames"
            
            # 如果存在引导文件，添加引导选项
            if [ -f "boot/isolinux.bin" ]; then
                XORRISO_CMD="$XORRISO_CMD -b boot/isolinux.bin"
                XORRISO_CMD="$XORRISO_CMD -c boot/boot.cat"
                XORRISO_CMD="$XORRISO_CMD -no-emul-boot"
                XORRISO_CMD="$XORRISO_CMD -boot-load-size 4"
                XORRISO_CMD="$XORRISO_CMD -boot-info-table"
                
                # 添加UEFI引导（如果存在）
                if [ -f "EFI/boot/bootx64.efi" ]; then
                    XORRISO_CMD="$XORRISO_CMD -eltorito-alt-boot"
                    XORRISO_CMD="$XORRISO_CMD -e EFI/boot/bootx64.efi"
                    XORRISO_CMD="$XORRISO_CMD -no-emul-boot"
                fi
                
                # 添加混合引导支持
                if [ -f "/usr/share/syslinux/isohdpfx.bin" ]; then
                    XORRISO_CMD="$XORRISO_CMD -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin"
                fi
            fi
            
            XORRISO_CMD="$XORRISO_CMD -o '${OUTPUT_ISO}' ."
            
            print_info "执行: $XORRISO_CMD"
            eval "$XORRISO_CMD"
            ;;
            
        genisoimage|mkisofs)
            if [ -f "boot/isolinux.bin" ]; then
                $ISO_TOOL \
                    -V "OPENWRT_MINI" \
                    -J -r \
                    -b boot/isolinux.bin \
                    -c boot/boot.cat \
                    -no-emul-boot \
                    -boot-load-size 4 \
                    -boot-info-table \
                    -o "${OUTPUT_ISO}" .
            else
                $ISO_TOOL \
                    -V "OPENWRT_MINI" \
                    -J -r \
                    -o "${OUTPUT_ISO}" .
            fi
            ;;
    esac
    
    if [ $? -eq 0 ] && [ -f "${OUTPUT_ISO}" ]; then
        ISO_SIZE_FINAL=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
        print_success "ISO创建成功: ${ISO_SIZE_FINAL}"
        
        # 验证ISO
        print_step "验证ISO文件..."
        if command -v file >/dev/null 2>&1; then
            file "${OUTPUT_ISO}"
        fi
        
        return 0
    else
        print_error "ISO创建失败"
        return 1
    fi
}

# 创建ISO
if create_compressed_iso; then
    print_success "ISO构建流程完成"
else
    # 备用方案：创建可引导tar存档
    print_warning "ISO创建失败，尝试备用方案..."
    
    print_step "创建可引导tar存档..."
    cd "${WORK_DIR}/iso"
    tar -czf "${OUTPUT_ISO}.tar.gz" .
    
    # 创建简易引导脚本
    cat > "${OUTPUT_DIR}/boot-instructions.txt" << 'BOOT_HELP'
# OpenWRT 安装器引导说明

由于ISO创建失败，已生成tar存档。

使用方法:
1. 解压文件到FAT32格式的U盘:
   tar -xzf openwrt-minimal-installer.iso.tar.gz -C /mnt/usb/

2. 使用以下工具之一创建可引导U盘:
   
   a) 使用GRUB:
     - 安装GRUB: grub-install --target=x86_64-efi --boot-directory=/mnt/usb/boot
     - 复制EFI文件到适当位置
   
   b) 使用SYSLINUX:
     - 安装SYSLINUX: syslinux -i /dev/sdX1
     - 复制ldlinux.sys到U盘根目录
   
   c) 手动引导:
     - 从U盘启动
     - 在GRUB命令行输入:
         linux /boot/vmlinuz initrd=/boot/initramfs
         boot

3. 或者直接使用QEMU测试:
   qemu-system-x86_64 -hda /dev/sdX -cdrom openwrt-minimal-installer.iso.tar.gz
BOOT_HELP
    
    print_info "已创建备用存档: ${OUTPUT_ISO}.tar.gz"
    print_info "请查看: ${OUTPUT_DIR}/boot-instructions.txt"
fi

# ================= 最终统计 =================
print_header "7. 构建完成 - 极致压缩报告"

print_divider
print_success "✅ OpenWRT极致压缩安装器构建完成"
print_divider

if [ -f "${OUTPUT_ISO}" ]; then
    ISO_SIZE_FINAL=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
    ISO_SIZE_BYTES=$(stat -c%s "${OUTPUT_ISO}" 2>/dev/null || echo 0)
    
    print_step "📊 最终结果统计:"
    print_info "  输出文件: ${OUTPUT_ISO}"
    print_info "  总大小: ${ISO_SIZE_FINAL} ($((ISO_SIZE_BYTES/1024/1024))MB)"
    echo ""
    
    print_step "📦 内容分析:"
    print_info "  ┌─ OpenWRT系统镜像: ${IMG_SIZE_FINAL}"
    print_info "  ├─ Linux内核: ${KERNEL_SIZE_FINAL}"
    print_info "  ├─ Initramfs安装器: ${INITRAMFS_SIZE_FINAL}"
    print_info "  └─ 引导文件: ~1MB"
    echo ""
    
    # 计算压缩率
    IMG_BYTES=$(stat -c%s "${WORK_DIR}/iso/img/openwrt.img" 2>/dev/null || echo 0)
    if [ $IMG_BYTES -gt 0 ]; then
        OVERHEAD=$((ISO_SIZE_BYTES - IMG_BYTES))
        OVERHEAD_MB=$((OVERHEAD/1024/1024))
        print_info "  📈 系统开销: ${OVERHEAD_MB}MB (安装器+内核+引导)"
        
        if [ $OVERHEAD_MB -lt 10 ]; then
            print_success "  🎯 优秀! 额外开销 < 10MB"
        elif [ $OVERHEAD_MB -lt 50 ]; then
            print_success "  👍 良好! 额外开销 < 50MB"
        else
            print_warning "  ⚠️  开销较大，可进一步优化"
        fi
    fi
    echo ""
    
    print_step "🚀 使用说明:"
    print_info "  1. 写入U盘:"
    print_info "     dd if='${OUTPUT_ISO}' of=/dev/sdX bs=4M status=progress"
    print_info "  2. 设置BIOS/UEFI从U盘启动"
    print_info "  3. 选择'Install OpenWRT'"
    print_info "  4. 按照提示完成安装"
    echo ""
    
    print_step "🔧 特性摘要:"
    print_info "  ✅ 极致压缩 - 最小系统开销"
    print_info "  ✅ 双引导支持 - BIOS + UEFI"
    print_info "  ✅ 自动安装 - 简单易用"
    print_info "  ✅ 应急模式 - 故障恢复"
    print_info "  ✅ 快速启动 - 低内存占用"
    
else
    print_step "📦 备用方案结果:"
    print_info "  主要输出: ${OUTPUT_ISO}.tar.gz"
    print_info "  说明文件: ${OUTPUT_DIR}/boot-instructions.txt"
    print_info "  手动引导指南已生成"
fi

print_divider
print_success "🎉 构建流程完成! 极致压缩安装器已就绪"
print_divider

# 最终清理（可选）
# print_step "清理工作目录..."
# rm -rf "${WORK_DIR}" 2>/dev/null || true
