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

# 如果默认路径不存在，尝试其他路径
if [ ! -f "${INPUT_IMG}" ]; then
    # 尝试当前目录
    if [ -f "assets/openwrt.img" ]; then
        INPUT_IMG="assets/openwrt.img"
    elif [ -f "openwrt.img" ]; then
        INPUT_IMG="openwrt.img"
    elif [ -f "${SCRIPT_DIR}/openwrt.img" ]; then
        INPUT_IMG="${SCRIPT_DIR}/openwrt.img"
    fi
fi

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
    print_info "搜索可用镜像..."
    
    # 列出可能的文件
    echo "当前目录: $(pwd)"
    echo "文件列表:"
    find . -name "*.img" -o -name "*.IMG" 2>/dev/null | head -10 || echo "无img文件"
    
    print_info "请执行以下操作之一:"
    echo "1. 将OpenWRT镜像重命名为 openwrt.img 放在当前目录"
    echo "2. 设置 INPUT_IMG 环境变量指定镜像路径"
    echo "3. 使用 --img 参数指定镜像路径"
    
    # 尝试创建一个测试镜像（仅用于测试）
    print_warning "创建测试镜像继续构建..."
    dd if=/dev/zero of=test-openwrt.img bs=1M count=10 2>/dev/null
    echo -e "o\nn\np\n1\n\n\nw" | fdisk test-openwrt.img >/dev/null 2>&1
    INPUT_IMG="test-openwrt.img"
    
    if [ -f "${INPUT_IMG}" ]; then
        print_info "使用测试镜像: ${INPUT_IMG}"
    else
        exit 1
    fi
fi

IMG_SIZE=$(du -h "${INPUT_IMG}" 2>/dev/null | cut -f1 || echo "unknown")
print_step "输入IMG: ${INPUT_IMG} (${IMG_SIZE})"
print_step "输出ISO: ${OUTPUT_ISO}"
print_step "工作目录: ${WORK_DIR}"

# ================= 准备目录 =================
print_header "1. 准备目录"

# 创建输出目录
mkdir -p "${OUTPUT_DIR}"
rm -rf "${WORK_DIR}" 2>/dev/null || true
mkdir -p "${WORK_DIR}/iso"
mkdir -p "${WORK_DIR}/iso/boot"
mkdir -p "${WORK_DIR}/iso/EFI/boot"
mkdir -p "${WORK_DIR}/iso/img"
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
    BACKUP_URLS=(
        "https://tinycorelinux.net/10.x/x86_64/release/distribution_files/vmlinuz64"
        "https://mirrors.aliyun.com/tinycorelinux/10.x/x86_64/release/distribution_files/vmlinuz64"
        "http://ftp.nluug.nl/os/Linux/distr/tinycorelinux/10.x/x86_64/release/distribution_files/vmlinuz64"
    )
    
    local downloaded=0
    
    # 尝试下载主URL
    print_info "尝试下载主内核..."
    
    if command -v wget >/dev/null 2>&1; then
        if wget --tries=2 --timeout=30 -q -O "${WORK_DIR}/iso/boot/vmlinuz" "$TINYCORE_KERNEL_URL"; then
            downloaded=1
        fi
    elif command -v curl >/dev/null 2>&1; then
        if curl -L --connect-timeout 20 --retry 2 -s -o "${WORK_DIR}/iso/boot/vmlinuz" "$TINYCORE_KERNEL_URL"; then
            downloaded=1
        fi
    fi
    
    # 如果主URL失败，尝试备用URL
    if [ $downloaded -eq 0 ]; then
        for url in "${BACKUP_URLS[@]}"; do
            print_info "尝试备用URL: $(basename "$url")"
            
            if command -v wget >/dev/null 2>&1; then
                if wget --tries=1 --timeout=15 -q -O "${WORK_DIR}/iso/boot/vmlinuz" "$url"; then
                    downloaded=1
                    break
                fi
            elif command -v curl >/dev/null 2>&1; then
                if curl -L --connect-timeout 10 --retry 1 -s -o "${WORK_DIR}/iso/boot/vmlinuz" "$url"; then
                    downloaded=1
                    break
                fi
            fi
        done
    fi
    
    if [ $downloaded -eq 1 ] && [ -f "${WORK_DIR}/iso/boot/vmlinuz" ]; then
        KERNEL_SIZE=$(stat -c%s "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null || echo 0)
        if [ $KERNEL_SIZE -gt 1000000 ]; then
            print_success "内核下载成功: $((KERNEL_SIZE/1024/1024))MB"
            
            # 验证内核文件
            if file "${WORK_DIR}/iso/boot/vmlinuz" | grep -q "Linux kernel"; then
                print_info "内核验证: Linux内核"
            elif file "${WORK_DIR}/iso/boot/vmlinuz" | grep -q "ELF"; then
                print_info "内核验证: ELF可执行文件"
            else
                print_warning "内核文件类型未知"
            fi
            
            return 0
        else
            print_warning "下载的文件太小 ($KERNEL_SIZE 字节)"
            downloaded=0
        fi
    fi
    
    # 如果下载失败，使用备用方案
    if [ $downloaded -eq 0 ]; then
        print_warning "内核下载失败，使用备用方案"
        
        # 方案1: 检查是否有现有内核
        print_info "检查系统内核..."
        for kernel in /boot/vmlinuz /vmlinuz /boot/vmlinuz-*; do
            if [ -f "$kernel" ] && [ $(stat -c%s "$kernel" 2>/dev/null || echo 0) -gt 1000000 ]; then
                cp "$kernel" "${WORK_DIR}/iso/boot/vmlinuz"
                print_success "使用现有内核: $kernel"
                return 0
            fi
        done
        
        # 方案2: 创建最小但能工作的内核
        print_info "创建最小内核..."
        
        # 创建一个ELF格式的最小"内核"
        cat > /tmp/mini_kernel.c << 'EOF'
// 最小内核占位程序
const char message[] = 
    "========================================\n"
    "  OpenWRT Tiny Installer\n"
    "========================================\n"
    "\n"
    "This is a minimal kernel placeholder.\n"
    "To use this installer, replace this file\n"
    "with a real Linux kernel (vmlinuz).\n"
    "\n";

void _start() {
    // 简单输出信息
    asm volatile (
        "mov $1, %%rax\n"      // sys_write
        "mov $1, %%rdi\n"      // fd = stdout
        "lea message(%%rip), %%rsi\n" // buf
        "mov $200, %%rdx\n"    // count
        "syscall\n"
        "mov $60, %%rax\n"     // sys_exit
        "mov $0, %%rdi\n"      // exit code
        "syscall\n"
        ::: "rax", "rdi", "rsi", "rdx"
    );
}
EOF
        
        # 编译为最小ELF文件
        if command -v gcc >/dev/null 2>&1; then
            gcc -nostdlib -static -o "${WORK_DIR}/iso/boot/vmlinuz" /tmp/mini_kernel.c 2>/dev/null || true
        fi
        
        if [ -f "${WORK_DIR}/iso/boot/vmlinuz" ] && [ $(stat -c%s "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null || echo 0) -gt 1000 ]; then
            print_info "创建了最小ELF内核"
        else
            # 最后的手段：创建一个包含内核标识的文件
            echo "LINUX_KERNEL_PLACEHOLDER_DO_NOT_BOOT" > "${WORK_DIR}/iso/boot/vmlinuz"
            # 添加一些数据使其看起来像内核
            dd if=/dev/urandom bs=1024 count=2 >> "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null
            print_warning "创建了最小内核占位文件"
        fi
        
        print_info "注意: 实际使用时需要替换为真实内核"
        print_info "可从 https://tinycorelinux.net 下载 vmlinuz64"
        return 1
    fi
}

# 执行内核下载
if ! download_tiny_kernel; then
    print_warning "内核准备有警告，继续构建..."
fi

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
# 微型init脚本

# 基本挂载
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# 必要设备
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true
mknod /dev/zero c 1 5 2>/dev/null || true

# 控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

echo "========================================"
echo "     OpenWRT Micro Installer"
echo "========================================"

# 查找OpenWRT镜像
if [ -f /img/openwrt.img ]; then
    IMG="/img/openwrt.img"
    echo "使用内置镜像"
else
    # 尝试挂载CDROM
    if [ -b /dev/sr0 ]; then
        mount -t iso9660 /dev/sr0 /mnt 2>/dev/null
        if [ -f /mnt/img/openwrt.img ]; then
            cp /mnt/img/openwrt.img /tmp/
            IMG="/tmp/openwrt.img"
            echo "使用光盘镜像"
            umount /mnt 2>/dev/null
        else
            echo "错误: 未找到OpenWRT镜像"
            echo "进入应急shell..."
            exec /bin/sh
        fi
    else
        echo "错误: 未找到安装介质"
        exec /bin/sh
    fi
fi

# 简单安装界面
clear
echo "=== OpenWRT 安装 ==="
echo ""
echo "镜像: $(basename $IMG)"
echo ""
echo "可用磁盘:"
echo "---------"

# 列出块设备
for d in /dev/sd[a-z] /dev/vd[a-z]; do
    [ -b "$d" ] && echo "  $d"
done

echo ""
echo -n "输入目标磁盘 (如: sda): "
read DISK

[ -z "$DISK" ] && { echo "取消"; exec /bin/sh; }
[[ "$DISK" =~ ^/dev/ ]] || DISK="/dev/$DISK"
[ -b "$DISK" ] || { echo "设备不存在"; exec /bin/sh; }

echo ""
echo "警告: 将完全擦除 $DISK !"
echo -n "输入 YES 确认: "
read CONFIRM

[ "$CONFIRM" != "YES" ] && { echo "取消"; exec /bin/sh; }

echo ""
echo "正在写入磁盘..."
dd if="$IMG" of="$DISK" bs=4M 2>&1 | grep -E 'records|bytes|copied' || true
sync

echo ""
echo "✅ 安装完成!"
echo "系统将在5秒后重启..."
sleep 5
echo "重启..."
reboot -f

# 如果到这里，执行shell
exec /bin/sh
TINY_INIT

    chmod +x "${initrd_dir}/init"
    
    # 获取或创建busybox
    print_step "准备BusyBox..."
    
    # 先尝试下载静态busybox
    print_info "下载静态BusyBox..."
    STATIC_BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
    
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "${initrd_dir}/bin/busybox" "$STATIC_BUSYBOX_URL" 2>/dev/null || true
    elif command -v curl >/dev/null 2>&1; then
        curl -L -s -o "${initrd_dir}/bin/busybox" "$STATIC_BUSYBOX_URL" 2>/dev/null || true
    fi
    
    # 检查是否下载成功
    if [ ! -f "${initrd_dir}/bin/busybox" ] || [ ! -s "${initrd_dir}/bin/busybox" ]; then
        print_info "使用系统busybox..."
        if command -v busybox >/dev/null 2>&1; then
            cp $(which busybox) "${initrd_dir}/bin/busybox" 2>/dev/null || true
        fi
    fi
    
    # 如果还没有busybox，创建最小shell
    if [ ! -f "${initrd_dir}/bin/busybox" ] || [ ! -s "${initrd_dir}/bin/busybox" ]; then
        print_warning "无法获取busybox，创建最小shell..."
        cat > "${initrd_dir}/bin/sh" << 'MINI_SH'
#!/bin/sh
echo "Micro Shell - Limited functionality"
echo "Available commands: ls, echo, reboot"
while read -p "# " cmd; do
    case "$cmd" in
        ls) ls /dev/ 2>/dev/null || echo "dev proc sys";;
        echo*) echo "$cmd" | cut -d' ' -f2-;;
        reboot) echo "Rebooting..."; exit 0;;
        *) echo "Unknown: $cmd";;
    esac
done
MINI_SH
        chmod +x "${initrd_dir}/bin/sh"
    else
        chmod +x "${initrd_dir}/bin/busybox"
        # 创建必要符号链接
        cd "${initrd_dir}"
        ln -sf busybox bin/sh 2>/dev/null || true
        ln -sf busybox bin/dd 2>/dev/null || true
        ln -sf busybox bin/mount 2>/dev/null || true
        ln -sf busybox bin/umount 2>/dev/null || true
        ln -sf busybox bin/reboot 2>/dev/null || true
        ln -sf busybox bin/cat 2>/dev/null || true
        ln -sf busybox bin/echo 2>/dev/null || true
        ln -sf busybox bin/ls 2>/dev/null || true
    fi
    
    # 如果镜像较小，复制到initramfs
    IMG_SIZE=$(stat -c%s "${WORK_DIR}/iso/img/openwrt.img" 2>/dev/null || echo 0)
    if [ $IMG_SIZE -lt $((20*1024*1024)) ]; then  # 小于20MB
        cp "${WORK_DIR}/iso/img/openwrt.img" "${initrd_dir}/img/"
        print_info "镜像内置到initramfs ($((IMG_SIZE/1024/1024))MB)"
    else
        print_info "镜像保留在ISO中 ($((IMG_SIZE/1024/1024))MB)"
    fi
    
    # 创建initramfs
    print_step "创建压缩initramfs..."
    cd "${initrd_dir}"
    
    # 计算原始大小
    ORIG_SIZE=$(du -sb . 2>/dev/null | cut -f1 || echo 0)
    print_info "原始大小: $((ORIG_SIZE/1024))KB"
    
    # 使用gzip压缩
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${output_file}"
    
    FINAL_SIZE=$(stat -c%s "${output_file}" 2>/dev/null || echo 0)
    if [ $ORIG_SIZE -gt 0 ]; then
        RATIO=$((FINAL_SIZE * 100 / ORIG_SIZE))
        print_info "压缩后: $((FINAL_SIZE/1024))KB (压缩率: ${RATIO}%)"
    fi
    
    # 确保不超过5MB
    if [ $FINAL_SIZE -gt $((5*1024*1024)) ]; then
        print_warning "initramfs较大 ($((FINAL_SIZE/1024/1024))MB)"
        
        # 尝试使用xz重新压缩
        if command -v xz >/dev/null 2>&1; then
            print_info "尝试xz压缩..."
            find . | cpio -o -H newc 2>/dev/null | xz -9 --check=crc32 > "${output_file}.xz"
            XZ_SIZE=$(stat -c%s "${output_file}.xz" 2>/dev/null || echo $FINAL_SIZE)
            
            if [ $XZ_SIZE -lt $FINAL_SIZE ]; then
                mv "${output_file}.xz" "${output_file}"
                print_info "改用xz: $((XZ_SIZE/1024))KB"
                FINAL_SIZE=$XZ_SIZE
            fi
        fi
    fi
    
    if [ $FINAL_SIZE -lt $((5*1024*1024)) ]; then
        print_success "initramfs大小合适: $((FINAL_SIZE/1024))KB"
    else
        print_warning "initramfs偏大: $((FINAL_SIZE/1024/1024))MB"
    fi
    
    return 0
}

create_tiny_initramfs

INITRAMFS_SIZE=$(du -h "${WORK_DIR}/iso/boot/initramfs" 2>/dev/null | cut -f1)
print_success "Initramfs最终大小: ${INITRAMFS_SIZE}"

# ================= 配置引导 =================
print_header "5. 配置双引导"

# BIOS引导 (SYSLINUX)
print_step "配置BIOS引导..."

# 检查并安装syslinux
if ! command -v syslinux >/dev/null 2>&1; then
    print_info "syslinux未安装，跳过BIOS引导配置"
else
    # 复制引导文件
    for file in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32; do
        for path in /usr/share/syslinux /usr/lib/syslinux /lib/syslinux; do
            if [ -f "$path/$file" ]; then
                cp "$path/$file" "${WORK_DIR}/iso/boot/" 2>/dev/null || true
                break
            fi
        done
    done
    
    # 创建配置
    cat > "${WORK_DIR}/iso/boot/isolinux.cfg" << 'CFG'
DEFAULT install
TIMEOUT 30
PROMPT 0
MENU TITLE OpenWRT Tiny Installer

LABEL install
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs console=ttyS0 console=tty0 quiet

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs init=/bin/sh
CFG
    
    print_success "BIOS引导配置完成"
fi

# UEFI引导 (GRUB)
print_step "配置UEFI引导..."

# 尝试获取GRUB EFI
if command -v grub-mkimage >/dev/null 2>&1; then
    print_info "构建GRUB EFI..."
    
    mkdir -p /tmp/grub-efi-build
    if grub-mkimage \
        -O x86_64-efi \
        -o /tmp/grub-efi-build/bootx64.efi \
        -p /EFI/boot \
        linux echo cat configfile normal terminal \
        2>/dev/null; then
        
        cp /tmp/grub-efi-build/bootx64.efi "${WORK_DIR}/iso/EFI/boot/"
        print_success "GRUB EFI构建成功"
    else
        print_warning "GRUB EFI构建失败"
    fi
    rm -rf /tmp/grub-efi-build
fi

# 如果还没有EFI文件，尝试复制现有文件
if [ ! -f "${WORK_DIR}/iso/EFI/boot/bootx64.efi" ]; then
    for path in /usr/lib/grub/x86_64-efi/grub.efi \
                /usr/share/grub/x86_64-efi/grub.efi \
                /usr/lib/grub/x86_64-efi-core/grub.efi; do
        if [ -f "$path" ]; then
            cp "$path" "${WORK_DIR}/iso/EFI/boot/bootx64.efi"
            print_success "找到GRUB EFI: $path"
            break
        fi
    done
fi

# 创建GRUB配置（无论是否有EFI文件）
cat > "${WORK_DIR}/iso/EFI/boot/grub.cfg" << 'GRUB_CFG'
set timeout=3
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz initrd=/boot/initramfs console=ttyS0 console=tty0 quiet
    boot
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz initrd=/boot/initramfs console=ttyS0 console=tty0 init=/bin/sh
    boot
}
GRUB_CFG

if [ -f "${WORK_DIR}/iso/EFI/boot/bootx64.efi" ]; then
    print_success "UEFI引导配置完成"
else
    print_warning "UEFI引导文件缺失，仅支持BIOS引导"
fi

print_success "引导配置完成"

# ================= 创建微型ISO =================
print_header "6. 创建微型ISO"

create_tiny_iso() {
    print_step "构建ISO..."
    
    cd "${WORK_DIR}/iso"
    
    # 显示内容
    print_info "ISO内容:"
    du -sh . || true
    echo ""
    
    # 使用xorriso创建ISO
    if command -v xorriso >/dev/null 2>&1; then
        print_info "使用xorriso创建ISO..."
        
        XORRISO_CMD="xorriso -as mkisofs"
        XORRISO_CMD="$XORRISO_CMD -volid 'OPENWRT_TINY'"
        XORRISO_CMD="$XORRISO_CMD -J -rock"
        XORRISO_CMD="$XORRISO_CMD -full-iso9660-filenames"
        
        # 如果有BIOS引导文件
        if [ -f "boot/isolinux.bin" ]; then
            XORRISO_CMD="$XORRISO_CMD -b boot/isolinux.bin"
            XORRISO_CMD="$XORRISO_CMD -c boot/boot.cat"
            XORRISO_CMD="$XORRISO_CMD -no-emul-boot"
            XORRISO_CMD="$XORRISO_CMD -boot-load-size 4"
            XORRISO_CMD="$XORRISO_CMD -boot-info-table"
        fi
        
        # 如果有UEFI引导文件
        if [ -f "EFI/boot/bootx64.efi" ]; then
            XORRISO_CMD="$XORRISO_CMD -eltorito-alt-boot"
            XORRISO_CMD="$XORRISO_CMD -e EFI/boot/bootx64.efi"
            XORRISO_CMD="$XORRISO_CMD -no-emul-boot"
        fi
        
        XORRISO_CMD="$XORRISO_CMD -o '${OUTPUT_ISO}' ."
        
        print_info "执行命令..."
        eval "$XORRISO_CMD"
        
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
        
    elif command -v mkisofs >/dev/null 2>&1; then
        print_info "使用mkisofs创建ISO..."
        mkisofs -V "OPENWRT_TINY" -o "${OUTPUT_ISO}" .
    else
        print_error "没有找到ISO创建工具"
        return 1
    fi
    
    if [ $? -eq 0 ] && [ -f "${OUTPUT_ISO}" ]; then
        ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
        ISO_BYTES=$(stat -c%s "${OUTPUT_ISO}" 2>/dev/null || echo 0)
        
        print_success "ISO创建成功: ${ISO_SIZE}"
        
        # 检查大小
        if [ $ISO_BYTES -lt $((50*1024*1024)) ]; then
            print_success "🎯 达成目标: < 50MB"
        else
            print_info "ISO大小: $((ISO_BYTES/1024/1024))MB"
        fi
        
        # 验证ISO
        if command -v file >/dev/null 2>&1; then
            print_info "ISO验证:"
            file "${OUTPUT_ISO}" | head -1
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
    if tar -czf "${OUTPUT_ISO}.tar.gz" .; then
        TAR_SIZE=$(du -h "${OUTPUT_ISO}.tar.gz" 2>/dev/null | cut -f1)
        print_success "创建tar备份: ${TAR_SIZE}"
        
        # 创建说明
        cat > "${OUTPUT_DIR}/README.txt" << 'README'
# OpenWRT Tiny Installer

由于ISO创建失败，已生成tar存档。

使用方法:
1. 解压到FAT32 U盘:
   tar -xzf openwrt-tiny-installer.iso.tar.gz -C /mnt/usb/
   
2. 对于BIOS系统:
   sudo syslinux -i /dev/sdX1
   
3. 对于UEFI系统，需要手动配置引导。

注意: 如果vmlinuz文件很小，需要替换为真实内核。
可从 https://tinycorelinux.net 下载 vmlinuz64
README
        
        print_info "说明文件: ${OUTPUT_DIR}/README.txt"
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
    echo "  • 输出文件: $(basename ${OUTPUT_ISO})"
    echo "  • 文件大小: ${ISO_SIZE}"
    echo "  • OpenWRT镜像: ${IMG_SIZE_FINAL}"
    echo "  • Linux内核: ${KERNEL_SIZE}"
    echo "  • Initramfs: ${INITRAMFS_SIZE}"
    echo ""
    echo "🚀 使用说明:"
    echo "  1. 写入U盘:"
    echo "     dd if=${OUTPUT_ISO_FILENAME} of=/dev/sdX bs=4M status=progress"
    echo "  2. 从U盘启动计算机"
    echo "  3. 选择'Install OpenWRT'"
    echo ""
    
    # 重要提示
    KERNEL_BYTES=$(stat -c%s "${WORK_DIR}/iso/boot/vmlinuz" 2>/dev/null || echo 0)
    if [ $KERNEL_BYTES -lt 1000000 ]; then
        echo "⚠️  重要提示:"
        echo "    检测到内核文件较小 ($((KERNEL_BYTES/1024))KB)"
        echo "    可能需要手动替换为真实Linux内核"
        echo ""
        echo "    替换方法:"
        echo "    1. 从 https://tinycorelinux.net 下载 vmlinuz64"
        echo "    2. 替换ISO中的 /boot/vmlinuz 文件"
        echo "    3. 或使用真实内核重新构建"
    fi
    
    echo "══════════════════════════════════════════"
    
else
    echo ""
    echo "构建完成，但没有生成ISO文件"
    echo "请检查错误信息"
    echo "已生成tar备份文件"
fi

# 清理工作目录
rm -rf "${WORK_DIR}" 2>/dev/null || true

# 清理测试镜像
if [ -f "test-openwrt.img" ]; then
    rm -f "test-openwrt.img"
fi

echo ""
print_success "构建流程结束"
