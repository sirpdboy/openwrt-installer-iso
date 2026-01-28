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
WORK_DIR="/tmp/iso-work"

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
mkdir -p "iso/squashfs"  # 用于squashfs根文件系统
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
    print_step "获取Linux内核..."
    
    # 方法1: 尝试下载TinyCore内核
    KERNEL_URLS=(
        "https://github.com/tinycorelinux/Core-scripts/raw/master/vmlinuz64"
        "https://tinycorelinux.net/10.x/x86_64/release/distribution_files/vmlinuz64"
    )
    
    for url in "${KERNEL_URLS[@]}"; do
        print_info "尝试下载: $(basename "$url")"
        
        if command -v wget >/dev/null 2>&1; then
            if wget --tries=1 --timeout=15 -q -O "iso/boot/vmlinuz" "$url"; then
                if [ -s "iso/boot/vmlinuz" ]; then
                    KERNEL_SIZE=$(stat -c%s "iso/boot/vmlinuz" 2>/dev/null || echo 0)
                    if [ $KERNEL_SIZE -gt 1000000 ]; then
                        print_success "内核下载成功: $((KERNEL_SIZE/1024/1024))MB"
                        return 0
                    fi
                fi
            fi
        fi
    done
    
    # 方法2: 使用系统内核
    print_info "检查系统内核..."
    for kernel in /boot/vmlinuz-* /boot/vmlinuz /vmlinuz; do
        if [ -f "$kernel" ] && [ -s "$kernel" ]; then
            cp "$kernel" "iso/boot/vmlinuz"
            KERNEL_SIZE=$(stat -c%s "iso/boot/vmlinuz" 2>/dev/null || echo 0)
            print_success "使用系统内核: $kernel ($((KERNEL_SIZE/1024/1024))MB)"
            return 0
        fi
    done
    
    # 方法3: 创建最小内核占位
    print_warning "创建内核占位文件"
    dd if=/dev/zero of="iso/boot/vmlinuz" bs=1M count=2 2>/dev/null
    echo "LINUX_KERNEL_PLACEHOLDER" >> "iso/boot/vmlinuz"
    
    print_info "注意：建议手动替换为真实内核"
    return 1
}

get_kernel

KERNEL_SIZE=$(du -h "iso/boot/vmlinuz" 2>/dev/null | cut -f1)
print_success "内核准备完成: ${KERNEL_SIZE}"

# ================= 创建SquashFS根文件系统 =================
print_header "4. 创建SquashFS根文件系统"

create_squashfs_rootfs() {
    print_step "创建极简根文件系统..."
    
    local rootfs_dir="${WORK_DIR}/rootfs"
    rm -rf "$rootfs_dir"
    mkdir -p "$rootfs_dir"
    
    # 创建目录结构
    mkdir -p "$rootfs_dir"/{bin,dev,etc,proc,root,sys,tmp,usr/bin,usr/lib,lib,mnt}
    
    # 创建init脚本
    cat > "$rootfs_dir/init" << 'INIT'
#!/bin/sh
# 极简init脚本

# 挂载虚拟文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 必要设备
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true
mknod /dev/zero c 1 5 2>/dev/null || true

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

clear
echo "========================================"
echo "     OpenWRT Installer"
echo "========================================"
echo ""

# 查找安装介质
if [ -b /dev/sr0 ]; then
    mount -t iso9660 /dev/sr0 /mnt 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "找到安装介质"
        INSTALL_MEDIA="/mnt"
    fi
fi

if [ -z "$INSTALL_MEDIA" ] || [ ! -d "$INSTALL_MEDIA" ]; then
    echo "错误: 无法挂载安装介质"
    echo "进入应急shell..."
    exec /bin/sh
fi

# 检查文件
if [ ! -f "$INSTALL_MEDIA/img/openwrt.img" ]; then
    echo "错误: 未找到OpenWRT镜像"
    exec /bin/sh
fi

# 安装器函数
install_openwrt() {
    clear
    echo "=== OpenWRT 安装 ==="
    echo ""
    echo "镜像: openwrt.img"
    echo ""
    
    # 显示磁盘
    echo "可用磁盘:"
    echo "---------"
    lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -E '^(sd|hd|vd|nvme)' || \
    for d in /dev/sd[a-z] /dev/vd[a-z]; do
        [ -b "$d" ] && echo "  $d"
    done
    echo ""
    
    echo -n "输入目标磁盘 (如: sda): "
    read DISK
    [ -z "$DISK" ] && return 1
    
    [[ "$DISK" =~ ^/dev/ ]] || DISK="/dev/$DISK"
    [ -b "$DISK" ] || { echo "设备不存在"; return 1; }
    
    echo ""
    echo "⚠️  警告: 将完全擦除 $DISK!"
    echo -n "输入 YES 确认: "
    read CONFIRM
    [ "$CONFIRM" != "YES" ] && { echo "安装取消"; return 1; }
    
    echo ""
    echo "正在写入..."
    dd if="$INSTALL_MEDIA/img/openwrt.img" of="$DISK" bs=4M 2>&1 | \
        grep -E 'records|bytes|copied' || true
    sync
    
    echo ""
    echo "✅ 安装完成!"
    echo "系统将在10秒后重启..."
    for i in $(seq 10 -1 1); do
        echo -ne "倒计时: ${i}s\r"
        sleep 1
    done
    echo ""
    echo "重启..."
    reboot -f
}

# 运行安装器
install_openwrt

# 如果失败，进入shell
echo ""
echo "安装失败，进入应急shell..."
exec /bin/sh
INIT

    chmod +x "$rootfs_dir/init"
    
    # 获取busybox
    print_step "获取BusyBox..."
    if command -v busybox >/dev/null 2>&1; then
        BUSYBOX_PATH=$(which busybox)
        cp "$BUSYBOX_PATH" "$rootfs_dir/bin/busybox"
        chmod +x "$rootfs_dir/bin/busybox"
        
        # 创建符号链接
        cd "$rootfs_dir"
        ln -sf busybox bin/sh 2>/dev/null || true
        ln -sf busybox bin/mount 2>/dev/null || true
        ln -sf busybox bin/umount 2>/dev/null || true
        ln -sf busybox bin/dd 2>/dev/null || true
        ln -sf busybox bin/sync 2>/dev/null || true
        ln -sf busybox bin/reboot 2>/dev/null || true
        ln -sf busybox bin/ls 2>/dev/null || true
        ln -sf busybox bin/cat 2>/dev/null || true
        ln -sf busybox bin/echo 2>/dev/null || true
        ln -sf busybox bin/grep 2>/dev/null || true
        ln -sf busybox bin/sleep 2>/dev/null || true
    else
        # 下载静态busybox
        print_info "下载静态BusyBox..."
        wget -q -O "$rootfs_dir/bin/busybox" \
            "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" 2>/dev/null || true
        
        if [ -f "$rootfs_dir/bin/busybox" ]; then
            chmod +x "$rootfs_dir/bin/busybox"
            cd "$rootfs_dir"
            ln -s busybox bin/sh 2>/dev/null || true
        fi
    fi
    
    # 复制必要库文件
    print_step "复制库文件..."
    if [ -f "/lib/ld-musl-x86_64.so.1" ]; then
        cp /lib/ld-musl-x86_64.so.1 "$rootfs_dir/lib/" 2>/dev/null || true
    elif [ -f "/lib64/ld-linux-x86-64.so.2" ]; then
        cp /lib64/ld-linux-x86-64.so.2 "$rootfs_dir/lib/" 2>/dev/null || true
    fi
    
    # 创建squashfs
    print_step "创建SquashFS文件系统..."
    if command -v mksquashfs >/dev/null 2>&1; then
        # 压缩前大小
        ORIG_SIZE=$(du -sb "$rootfs_dir" 2>/dev/null | cut -f1 || echo 0)
        
        # 创建squashfs（使用xz压缩）
        mksquashfs "$rootfs_dir" "iso/squashfs/rootfs.squashfs" \
            -comp xz \
            -b 131072 \
            -no-exports \
            -no-progress \
            -all-root 2>/dev/null
        
        SQUASHFS_SIZE=$(stat -c%s "iso/squashfs/rootfs.squashfs" 2/dev/null || echo 0)
        
        if [ $ORIG_SIZE -gt 0 ] && [ $SQUASHFS_SIZE -gt 0 ]; then
            RATIO=$((SQUASHFS_SIZE * 100 / ORIG_SIZE))
            print_success "SquashFS创建完成: $((SQUASHFS_SIZE/1024))KB (压缩率: ${RATIO}%)"
        else
            print_success "SquashFS创建完成"
        fi
        
        # 创建initramfs来挂载squashfs
        create_squashfs_initramfs
        
    else
        print_warning "mksquashfs未找到，使用传统initramfs"
        create_traditional_initramfs
    fi
    
    rm -rf "$rootfs_dir"
}

create_squashfs_initramfs() {
    print_step "创建SquashFS加载器initramfs..."
    
    local initrd_dir="${WORK_DIR}/squashfs-initrd"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    
    # 创建加载squashfs的init脚本
    cat > "$initrd_dir/init" << 'SQUASHFS_INIT'
#!/bin/sh
# SquashFS加载器

# 挂载proc和sys
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# 必要设备
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

echo "加载SquashFS根文件系统..."

# 挂载安装介质
if [ -b /dev/sr0 ]; then
    mount -t iso9660 /dev/sr0 /mnt 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "安装介质挂载成功"
        
        # 挂载squashfs
        if [ -f /mnt/squashfs/rootfs.squashfs ]; then
            echo "找到SquashFS文件系统"
            mkdir -p /newroot
            mount -t squashfs /mnt/squashfs/rootfs.squashfs /newroot
            
            if [ $? -eq 0 ]; then
                echo "SquashFS挂载成功"
                umount /mnt 2>/dev/null
                
                # 切换到新根
                exec switch_root /newroot /init
            fi
        fi
        umount /mnt 2>/dev/null
    fi
fi

echo "错误: 无法加载SquashFS"
echo "进入应急shell..."
exec /bin/sh
SQUASHFS_INIT

    chmod +x "$initrd_dir/init"
    
    # 复制必要工具
    if command -v busybox >/dev/null 2>&1; then
        cp $(which busybox) "$initrd_dir/busybox" 2>/dev/null || true
    fi
    
    # 创建initramfs
    cd "$initrd_dir"
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "iso/boot/initrd.img"
    
    INITRD_SIZE=$(stat -c%s "iso/boot/initrd.img" 2>/dev/null || echo 0)
    print_success "initramfs创建完成: $((INITRD_SIZE/1024))KB"
}

create_traditional_initramfs() {
    print_step "创建传统initramfs..."
    
    local initrd_dir="${WORK_DIR}/initrd"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    
    # 复制前面创建的rootfs到initramfs
    cp -r "${WORK_DIR}/rootfs"/* "$initrd_dir/" 2>/dev/null || true
    
    # 创建initramfs
    cd "$initrd_dir"
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "iso/boot/initrd.img"
    
    INITRD_SIZE=$(stat -c%s "iso/boot/initrd.img" 2>/dev/null || echo 0)
    print_success "传统initramfs创建完成: $((INITRD_SIZE/1024))KB"
}

# 创建根文件系统
create_squashfs_rootfs

# ================= 修复ISOLINUX引导 =================
print_header "5. 配置BIOS引导 (ISOLINUX)"

setup_bios_boot() {
    print_step "配置ISOLINUX引导..."
    
    # 安装syslinux（如果未安装）
    if ! command -v syslinux >/dev/null 2>&1; then
        print_info "尝试安装syslinux..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y syslinux isolinux 2>/dev/null || true
        elif command -v apk >/dev/null 2>&1; then
            apk add syslinux 2>/dev/null || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y syslinux 2>/dev/null || true
        fi
    fi
    
    # 查找ISOLINUX文件
    SYSLINUX_PATHS=(
        "/usr/lib/syslinux"
        "/usr/share/syslinux"
        "/usr/lib/ISOLINUX"
        "/lib/syslinux"
    )
    
    local files_found=0
    SYSLINUX_FILES=("isolinux.bin" "ldlinux.c32" "libcom32.c32" "libutil.c32" "menu.c32")
    
    for file in "${SYSLINUX_FILES[@]}"; do
        for path in "${SYSLINUX_PATHS[@]}"; do
            if [ -f "$path/$file" ]; then
                cp "$path/$file" "iso/boot/" 2>/dev/null
                files_found=1
                print_info "找到: $path/$file"
                break
            fi
        done
    done
    
    if [ $files_found -eq 0 ]; then
        print_warning "未找到ISOLINUX文件，尝试下载..."
        
        # 尝试从网络下载
        SYSLINUX_URL="https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz"
        
        if command -v wget >/dev/null 2>&1; then
            wget -q -O /tmp/syslinux.tar.gz "$SYSLINUX_URL" 2>/dev/null || true
        fi
        
        if [ -f /tmp/syslinux.tar.gz ]; then
            mkdir -p /tmp/syslinux-extract
            tar -xz -f /tmp/syslinux.tar.gz -C /tmp/syslinux-extract --strip-components=1 \
                syslinux-6.04-pre1/bios/core/isolinux.bin \
                syslinux-6.04-pre1/bios/com32/elflink/ldlinux/ldlinux.c32 \
                syslinux-6.04-pre1/bios/com32/lib/libcom32.c32 \
                syslinux-6.04-pre1/bios/com32/libutil/libutil.c32 \
                2>/dev/null || true
            
            # 复制文件
            for file in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32; do
                if [ -f "/tmp/syslinux-extract/$file" ]; then
                    cp "/tmp/syslinux-extract/$file" "iso/boot/"
                    files_found=1
                fi
            done
            
            rm -rf /tmp/syslinux-extract /tmp/syslinux.tar.gz
        fi
    fi
    
    if [ $files_found -eq 0 ]; then
        print_error "无法获取ISOLINUX文件，跳过BIOS引导"
        return 1
    fi
    
    # 创建ISOLINUX配置
    cat > "iso/boot/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT linux
PROMPT 0
TIMEOUT 30
UI menu.c32

MENU TITLE OpenWRT Installer

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

# ================= 配置UEFI引导 =================
print_header "6. 配置UEFI引导 (GRUB)"

setup_uefi_boot() {
    print_step "配置GRUB UEFI引导..."
    
    # 创建GRUB EFI文件
    if command -v grub-mkimage >/dev/null 2>&1; then
        print_info "构建GRUB EFI映像..."
        
        mkdir -p /tmp/grub-build
        if grub-mkimage \
            -O x86_64-efi \
            -o /tmp/grub-build/grubx64.efi \
            -p /boot/grub \
            linux part_gpt part_msdos fat iso9660 ext2 \
            configfile echo normal terminal \
            2>/dev/null; then
            
            cp /tmp/grub-build/grubx64.efi "iso/EFI/BOOT/BOOTX64.EFI"
            print_success "GRUB EFI构建成功"
        fi
        rm -rf /tmp/grub-build
    fi
    
    # 如果构建失败，尝试复制现有文件
    if [ ! -f "iso/EFI/BOOT/BOOTX64.EFI" ]; then
        for path in \
            /usr/lib/grub/x86_64-efi/grub.efi \
            /usr/share/grub/x86_64-efi/grub.efi \
            /usr/lib/grub/x86_64-efi-core/grub.efi \
            /usr/lib/grub/x86_64-efi/grubx64.efi; do
            
            if [ -f "$path" ]; then
                cp "$path" "iso/EFI/BOOT/BOOTX64.EFI"
                print_success "复制GRUB EFI: $path"
                break
            fi
        done
    fi
    
    # 创建GRUB配置
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
GRUB_CFG
    
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
    
    # 确保输出目录存在
    mkdir -p "${OUTPUT_DIR}"
    
    # 使用xorriso创建混合ISO
    if command -v xorriso >/dev/null 2>&1; then
        print_info "使用xorriso创建ISO..."
        
        # 构建命令
        CMD="xorriso -as mkisofs"
        CMD="$CMD -volid 'OPENWRT_INSTALL'"
        CMD="$CMD -J -r -rock"
        CMD="$CMD -full-iso9660-filenames"
        
        # BIOS引导
        if [ -f "boot/isolinux.bin" ]; then
            CMD="$CMD -b boot/isolinux.bin"
            CMD="$CMD -c boot/boot.cat"
            CMD="$CMD -no-emul-boot"
            CMD="$CMD -boot-load-size 4"
            CMD="$CMD -boot-info-table"
            
            # 添加混合引导支持
            if [ -f "/usr/share/syslinux/isohdpfx.bin" ]; then
                CMD="$CMD -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin"
            fi
        fi
        
        # UEFI引导
        if [ -f "EFI/BOOT/BOOTX64.EFI" ]; then
            CMD="$CMD -eltorito-alt-boot"
            CMD="$CMD -e EFI/BOOT/BOOTX64.EFI"
            CMD="$CMD -no-emul-boot"
            CMD="$CMD -isohybrid-gpt-basdat"
        fi
        
        CMD="$CMD -o \"${OUTPUT_ISO}\" ."
        
        print_info "执行ISO创建..."
        if eval "$CMD" 2>/dev/null; then
            print_success "ISO创建成功"
        else
            # 简单回退
            xorriso -as mkisofs -V "OPENWRT" -o "${OUTPUT_ISO}" . 2>/dev/null || return 1
        fi
        
    elif command -v genisoimage >/dev/null 2>&1; then
        print_info "使用genisoimage创建ISO..."
        
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
        print_success "ISO文件创建完成: ${ISO_SIZE}"
        return 0
    else
        print_error "ISO文件创建失败"
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
    
    ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
    print_info "ISO大小: ${ISO_SIZE}"
    
    # 使用file检查
    if command -v file >/dev/null 2>&1; then
        print_info "文件类型:"
        file "${OUTPUT_ISO}"
    fi
    
    # 使用xorriso检查内容
    if command -v xorriso >/dev/null 2>&1; then
        print_info "ISO内容检查:"
        
        CHECK_FILES=(
            "/boot/vmlinuz"
            "/boot/initrd.img"
            "/boot/isolinux.bin"
            "/boot/grub/grub.cfg"
            "/EFI/BOOT/BOOTX64.EFI"
            "/img/openwrt.img"
            "/squashfs/rootfs.squashfs"
        )
        
        for file in "${CHECK_FILES[@]}"; do
            if xorriso -indev "${OUTPUT_ISO}" -ls "$file" 2>&1 | grep -q "$file"; then
                print_success "✓ $file"
            else
                print_warning "⚠ $file (缺失)"
            fi
        done
    fi
    
    print_success "ISO验证完成"
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

ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
INITRD_SIZE=$(du -h "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null | cut -f1 || echo "N/A")

echo "📊 构建统计:"
echo "  • 输出文件: ${OUTPUT_ISO_FILENAME}"
echo "  • ISO大小: ${ISO_SIZE}"
echo "  • OpenWRT镜像: ${IMG_SIZE_FINAL}"
echo "  • Linux内核: ${KERNEL_SIZE}"
echo "  • 根文件系统: ${INITRD_SIZE}"
echo ""

# 引导支持
echo "🔧 引导支持:"
if [ -f "${WORK_DIR}/iso/boot/isolinux.bin" ]; then
    echo "  ✅ BIOS引导: 已配置 (ISOLINUX)"
else
    echo "  ❌ BIOS引导: 未配置"
fi

if [ -f "${WORK_DIR}/iso/EFI/BOOT/BOOTX64.EFI" ]; then
    echo "  ✅ UEFI引导: 已配置 (GRUB)"
else
    echo "  ❌ UEFI引导: 未配置"
fi
echo ""

# 使用说明
echo "🚀 使用方法:"
echo "  1. 写入U盘:"
echo "     sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
echo "  2. 设置BIOS/UEFI从U盘启动"
echo "  3. 选择'Install OpenWRT'"
echo "  4. 按照屏幕提示完成安装"
echo ""

# 清理
rm -rf "${WORK_DIR}" 2>/dev/null || true

echo "📅 构建时间: $(date)"
echo "══════════════════════════════════════════"

echo ""
print_success "构建流程成功完成!"
exit 0
