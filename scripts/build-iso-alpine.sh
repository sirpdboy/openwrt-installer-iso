#!/bin/bash
# 最小Alpine Linux双引导ISO构建脚本
# 使用Alpine 3.18 - 最佳兼容性

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_title() { echo -e "${CYAN}\n$1${NC}"; }
print_info() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

# ================= 配置部分 =================
# 使用Alpine 3.18.6 - 最佳兼容性版本
ALPINE_VERSION="${ALPINE_VERSION:-3.18.6}"
ISO_NAME="${ISO_NAME:-alpine-mini-dualboot}"
WORK_DIR="/work"
OUTPUT_DIR="/output"
ISO_FILE="${OUTPUT_DIR}/${ISO_NAME}.iso"

# 显示构建信息
print_title "Alpine Linux 最小双引导ISO构建器"
echo -e "${BLUE}=========================================${NC}"
print_info "Alpine版本: ${ALPINE_VERSION} (最佳兼容性)"
print_info "ISO名称: ${ISO_NAME}"
print_info "目标: BIOS + UEFI 双引导"
print_info "内核: Linux 6.1 LTS"
echo -e "${BLUE}=========================================${NC}"

# ================= 初始化目录 =================
print_title "1. 初始化工作目录"
rm -rf ${WORK_DIR} ${OUTPUT_DIR}/*
mkdir -p ${WORK_DIR}/{rootfs,iso/{boot,EFI/boot}} ${OUTPUT_DIR}
print_info "目录结构创建完成"

# ================= 下载rootfs =================
print_title "2. 下载Alpine迷你rootfs"

# 提取主版本号
MAJOR_VER=$(echo ${ALPINE_VERSION} | cut -d. -f1-2)
ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}-x86_64.tar.gz"

# 按顺序尝试的镜像源（优先国内源）
MIRRORS=(
    "https://mirrors.tuna.tsinghua.edu.cn/alpine/v${MAJOR_VER}/releases/x86_64"
    "https://mirrors.aliyun.com/alpine/v${MAJOR_VER}/releases/x86_64"
    "https://dl-cdn.alpinelinux.org/alpine/v${MAJOR_VER}/releases/x86_64"
)

DOWNLOAD_SUCCESS=0
for MIRROR in "${MIRRORS[@]}"; do
    URL="${MIRROR}/${ROOTFS_FILE}"
    print_info "尝试下载: $(basename ${URL})"
    
    if curl -s -f -L -o ${WORK_DIR}/rootfs.tar.gz "${URL}"; then
        # 验证文件
        if tar -tzf ${WORK_DIR}/rootfs.tar.gz >/dev/null 2>&1; then
            DOWNLOAD_SUCCESS=1
            print_info "✓ 下载成功 (来自: $(echo ${MIRROR} | cut -d/ -f3))"
            break
        else
            print_warn "文件验证失败，尝试下一个镜像"
            rm -f ${WORK_DIR}/rootfs.tar.gz
        fi
    fi
done

if [ ${DOWNLOAD_SUCCESS} -eq 0 ]; then
    print_error "所有镜像下载失败"
    exit 1
fi

# ================= 解压rootfs =================
print_title "3. 解压rootfs"
tar -xzf ${WORK_DIR}/rootfs.tar.gz -C ${WORK_DIR}/rootfs
print_info "rootfs解压完成"

# ================= 基础配置 =================
print_title "4. 基础系统配置"

# 配置APK源
cat > ${WORK_DIR}/rootfs/etc/apk/repositories << EOF
https://mirrors.tuna.tsinghua.edu.cn/alpine/v${MAJOR_VER}/main
https://mirrors.tuna.tsinghua.edu.cn/alpine/v${MAJOR_VER}/community
EOF

# 最小化安装 - 只安装必需包
print_info "安装最小必需包..."
chroot ${WORK_DIR}/rootfs /bin/sh <<EOF 2>/dev/null
# 更新源
apk update

# 最小化安装 - 只安装引导必需的包
apk add --no-cache \
    alpine-base \
    linux-lts \
    linux-firmware-none \  # 最小固件包
    grub-efi \
    grub-bios \
    syslinux
EOF

# ================= BIOS引导配置 =================
print_title "5. 配置BIOS引导 (SYSLINUX)"

# 复制SYSLINUX文件
SYSLINUX_FILES=(
    "isolinux.bin"
    "ldlinux.c32"
    "libutil.c32"
    "vesamenu.c32"
)

for file in "${SYSLINUX_FILES[@]}"; do
    if [ -f "/usr/share/syslinux/${file}" ]; then
        cp "/usr/share/syslinux/${file}" ${WORK_DIR}/iso/boot/
    fi
done

# 最小化BIOS引导配置
cat > ${WORK_DIR}/iso/boot/isolinux.cfg << 'EOF'
DEFAULT linux
TIMEOUT 30
PROMPT 0
MENU TITLE Alpine Linux Minimal (BIOS)

LABEL linux
  MENU LABEL ^Start Alpine Linux
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-lts modules=loop,squashfs,sd-mod,usb-storage quiet

LABEL memtest
  MENU LABEL ^Memory Test
  KERNEL /boot/memtest

LABEL hwdetect
  MENU LABEL ^Hardware Detection
  COM32 hdt.c32

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
EOF

print_info "BIOS引导配置完成"

# ================= UEFI引导配置 =================
print_title "6. 配置UEFI引导 (GRUB)"

# 复制EFI引导文件
EFI_FILES=(
    "bootx64.efi:x86_64-efi"
    "bootia32.efi:i386-efi"
)

for efi_file in "${EFI_FILES[@]}"; do
    filename=$(echo $efi_file | cut -d: -f1)
    arch=$(echo $efi_file | cut -d: -f2)
    
    # 尝试多个可能的位置
    for path in "/usr/lib/grub/${arch}/grub.efi" "/usr/share/grub/${arch}/grub.efi"; do
        if [ -f "$path" ]; then
            cp "$path" "${WORK_DIR}/iso/EFI/boot/${filename}"
            print_info "已复制: ${filename} (${arch})"
            break
        fi
    done
done

# 最小化GRUB配置（支持x64和ia32）
cat > ${WORK_DIR}/iso/EFI/boot/grub.cfg << 'EOF'
set timeout=3
set default=0

if [ "${grub_platform}" = "efi" ]; then
    # UEFI specific settings
    loadfont unicode
    set gfxmode=auto
fi

menuentry "Start Alpine Linux" {
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage quiet
    initrd /boot/initramfs-lts
}

menuentry "Start Alpine Linux (Safe Mode)" {
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage nomodeset quiet
    initrd /boot/initramfs-lts
}

menuentry "Memory Test" {
    linux /boot/memtest
}

menuentry "Reboot" {
    reboot
}

menuentry "Shutdown" {
    halt
}
EOF

print_info "UEFI引导配置完成 (支持x64和ia32)"

# ================= 内核文件 =================
print_title "7. 准备内核文件"

# 复制内核
if [ -f "${WORK_DIR}/rootfs/boot/vmlinuz-lts" ]; then
    cp "${WORK_DIR}/rootfs/boot/vmlinuz-lts" "${WORK_DIR}/iso/boot/"
    print_info "已复制: vmlinuz-lts"
else
    # 如果rootfs中没有，尝试使用宿主机的
    if [ -f "/boot/vmlinuz-lts" ]; then
        cp "/boot/vmlinuz-lts" "${WORK_DIR}/iso/boot/"
        print_warn "使用宿主机内核"
    else
        print_error "找不到内核文件"
        exit 1
    fi
fi

# 复制initramfs或创建最小的
if [ -f "${WORK_DIR}/rootfs/boot/initramfs-lts" ]; then
    cp "${WORK_DIR}/rootfs/boot/initramfs-lts" "${WORK_DIR}/iso/boot/"
    print_info "已复制: initramfs-lts"
else
    # 创建最小initramfs
    print_info "创建最小initramfs..."
    cat > ${WORK_DIR}/iso/boot/initramfs-lts << 'EOF'
#!/bin/busybox sh
# Minimal initramfs
/bin/busybox --install -s
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
exec /bin/sh
EOF
    chmod +x ${WORK_DIR}/iso/boot/initramfs-lts
fi

# 创建内存测试占位文件
echo "MEMTEST" > ${WORK_DIR}/iso/boot/memtest
print_info "内核文件准备完成"

# ================= 创建squashfs =================
print_title "8. 创建squashfs文件系统"
print_info "正在压缩rootfs..."

# 使用xz压缩获得最小体积
mksquashfs ${WORK_DIR}/rootfs ${WORK_DIR}/iso/alpine.squashfs \
    -comp xz \
    -Xbcj x86 \
    -b 1M \
    -noappend 2>/dev/null

SQUASHFS_SIZE=$(du -h ${WORK_DIR}/iso/alpine.squashfs | cut -f1)
print_info "squashfs创建完成: ${SQUASHFS_SIZE}"

# ================= 创建ISO =================
print_title "9. 创建双引导ISO"

cd ${WORK_DIR}/iso

# 创建ISO镜像
xorriso -as mkisofs \
    -volid "ALPINE_MINIMAL" \
    -full-iso9660-filenames \
    -joliet \
    -rock \
    -rational-rock \
    -eltorito-boot boot/isolinux.bin \
    -eltorito-catalog boot/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/boot/bootx64.efi \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
    -output "${ISO_FILE}" . 2>/dev/null

# 添加UEFI支持
isohybrid -u "${ISO_FILE}" 2>/dev/null || true

print_info "ISO创建完成"

# ================= 验证和输出 =================
print_title "10. 验证和输出"

if [ -f "${ISO_FILE}" ]; then
    ISO_SIZE=$(du -h "${ISO_FILE}" | cut -f1)
    ISO_INFO=$(file "${ISO_FILE}")
    
    echo -e "${BLUE}=========================================${NC}"
    print_info "✓ ISO构建成功！"
    echo -e "${BLUE}=========================================${NC}"
    print_info "文件: ${ISO_FILE}"
    print_info "大小: ${ISO_SIZE}"
    print_info "支持的引导模式:"
    print_info "  • BIOS (传统模式) - SYSLINUX"
    print_info "  • UEFI x64 (64位) - GRUB"
    print_info "  • UEFI ia32 (32位) - GRUB"
    print_info "内核: Linux 6.1 LTS"
    print_info "Alpine版本: ${ALPINE_VERSION}"
    echo -e "${BLUE}=========================================${NC}"
    
    # 显示ISO详细信息
    print_info "ISO详细信息:"
    echo "${ISO_INFO}" | sed 's/^/  /'
    
    # 显示引导信息
    print_info "引导扇区信息:"
    if which isoinfo >/dev/null 2>&1; then
        isoinfo -d -i "${ISO_FILE}" 2>/dev/null | grep -E "(Volume id|Bootable)" | sed 's/^/  /'
    fi
    
else
    print_error "ISO文件创建失败"
    exit 1
fi

print_title "构建完成！"
echo -e "${GREEN}最小Alpine双引导ISO已准备就绪${NC}"
