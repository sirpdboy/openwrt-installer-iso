#!/bin/bash
# Alpine Linux双引导ISO构建脚本
# 支持BIOS和UEFI引导

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 打印带颜色的消息
print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 默认配置
ALPINE_VERSION="${ALPINE_VERSION:-latest}"
ISO_NAME="${ISO_NAME:-alpine-dualboot}"
WORK_DIR="/work"
OUTPUT_DIR="/output"
ISO_FILENAME="${ISO_NAME}.iso"

print_section "Alpine Linux 双引导ISO构建脚本"
print_info "Alpine版本: ${ALPINE_VERSION}"
print_info "ISO名称: ${ISO_NAME}"

# 创建必要的目录结构
print_section "创建目录结构"
mkdir -p ${WORK_DIR}/{rootfs,boot/efi,iso/boot,iso/EFI/boot}
mkdir -p ${OUTPUT_DIR}

# 下载Alpine rootfs
print_section "下载Alpine rootfs"
if [ "${ALPINE_VERSION}" = "latest" ]; then
    ROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/alpine-minirootfs-latest-x86_64.tar.gz"
else
    ROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/x86_64/alpine-minirootfs-${ALPINE_VERSION}.0-x86_64.tar.gz"
fi

print_info "下载rootfs: ${ROOTFS_URL}"
if ! curl -L -o ${WORK_DIR}/rootfs.tar.gz "${ROOTFS_URL}"; then
    print_error "rootfs下载失败"
    exit 1
fi

# 解压rootfs
print_section "解压rootfs"
tar -xzf ${WORK_DIR}/rootfs.tar.gz -C ${WORK_DIR}/rootfs

# 配置rootfs
print_section "配置rootfs"
# 复制必要的配置文件
cat > ${WORK_DIR}/rootfs/etc/apk/repositories << 'EOF'
https://dl-cdn.alpinelinux.org/alpine/latest-stable/main
https://dl-cdn.alpinelinux.org/alpine/latest-stable/community
EOF

# 安装基础软件包到rootfs
print_info "在rootfs中安装基础软件包"
chroot ${WORK_DIR}/rootfs /bin/sh << 'EOF'
apk update
apk add --no-cache \
    linux-lts \
    alpine-base \
    grub-efi \
    grub-bios \
    efibootmgr \
    dosfstools \
    syslinux
EOF

# 准备引导文件
print_section "准备引导文件"

## BIOS引导文件
print_info "配置BIOS引导 (SYSLINUX/ISOLINUX)"

# 复制SYSLINUX文件
cp /usr/share/syslinux/isolinux.bin ${WORK_DIR}/iso/boot/
cp /usr/share/syslinux/ldlinux.c32 ${WORK_DIR}/iso/boot/
cp /usr/share/syslinux/libutil.c32 ${WORK_DIR}/iso/boot/
cp /usr/share/syslinux/menu.c32 ${WORK_DIR}/iso/boot/

# 创建isolinux.cfg (BIOS引导菜单)
cat > ${WORK_DIR}/iso/boot/isolinux.cfg << 'EOF'
DEFAULT vesamenu.c32
PROMPT 0
MENU TITLE Alpine Linux Dual-boot
TIMEOUT 300

MENU BACKGROUND splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

LABEL alpine
  MENU LABEL ^启动 Alpine Linux
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-lts modules=loop,squashfs,sd-mod,usb-storage quiet console=tty0 console=ttyS0,115200

LABEL alpine_nomodeset
  MENU LABEL Alpine Linux (^基础显卡模式)
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-lts modules=loop,squashfs,sd-mod,usb-storage nomodeset quiet

LABEL memtest
  MENU LABEL ^内存测试
  KERNEL /boot/memtest

LABEL hdt
  MENU LABEL ^硬件检测工具
  COM32 hdt.c32

LABEL reboot
  MENU LABEL ^重启
  COM32 reboot.c32

LABEL poweroff
  MENU LABEL ^关机
  COM32 poweroff.c32
EOF

## UEFI引导文件
print_info "配置UEFI引导 (GRUB)"

# 创建UEFI目录结构
mkdir -p ${WORK_DIR}/iso/EFI/boot

# 复制GRUB EFI文件
EFI_ARCH="x86_64"
cp /usr/lib/grub/${EFI_ARCH}-efi/grub.efi ${WORK_DIR}/iso/EFI/boot/bootx64.efi

# 创建GRUB配置文件
cat > ${WORK_DIR}/iso/EFI/boot/grub.cfg << 'EOF'
set timeout=10
set default=0

menuentry "启动 Alpine Linux" {
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage quiet console=tty0 console=ttyS0,115200
    initrd /boot/initramfs-lts
}

menuentry "Alpine Linux (基础显卡模式)" {
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage nomodeset quiet
    initrd /boot/initramfs-lts
}

menuentry "内存测试" {
    linux /boot/memtest
}

menuentry "重启" {
    reboot
}

menuentry "关机" {
    halt
}
EOF

# 复制内核和initramfs
print_section "复制内核文件"
cp ${WORK_DIR}/rootfs/boot/vmlinuz-lts ${WORK_DIR}/iso/boot/vmlinuz-lts
cp ${WORK_DIR}/rootfs/boot/initramfs-lts ${WORK_DIR}/iso/boot/initramfs-lts

# 创建memtest文件
touch ${WORK_DIR}/iso/boot/memtest

# 创建squashfs文件系统
print_section "创建squashfs文件系统"
mksquashfs ${WORK_DIR}/rootfs ${WORK_DIR}/iso/alpine.squashfs -comp xz -e boot

# 创建ISO
print_section "创建ISO文件"
xorrisofs_options=(
    -volid "ALPINE_DUALBOOT"
    -full-iso9660-filenames
    -J
    -joliet-long
    -rock
    -eltorito-boot boot/isolinux.bin
    -eltorito-catalog boot/boot.cat
    -no-emul-boot
    -boot-load-size 4
    -boot-info-table
    -eltorito-alt-boot
    -e EFI/boot/bootx64.efi
    -no-emul-boot
    -isohybrid-gpt-basdat
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin
    -output ${OUTPUT_DIR}/${ISO_FILENAME}
)

cd ${WORK_DIR}/iso
xorrisofs "${xorrisofs_options[@]}" .

# 添加UEFI引导能力
print_info "添加UEFI引导能力"
isohybrid --uefi ${OUTPUT_DIR}/${ISO_FILENAME}

# 验证ISO文件
print_section "验证ISO文件"
if [ -f "${OUTPUT_DIR}/${ISO_FILENAME}" ]; then
    ISO_SIZE=$(du -h ${OUTPUT_DIR}/${ISO_FILENAME} | cut -f1)
    print_info "✓ ISO构建成功!"
    print_info "文件: ${OUTPUT_DIR}/${ISO_FILENAME}"
    print_info "大小: ${ISO_SIZE}"
    
    # 显示ISO信息
    print_info "ISO信息:"
    file ${OUTPUT_DIR}/${ISO_FILENAME}
    
    # 检查引导类型
    print_info "引导类型检查:"
    if grep -q "No bootable" <(isoinfo -d -i ${OUTPUT_DIR}/${ISO_FILENAME} 2>/dev/null); then
        print_warn "ISO可能无法引导"
    else
        print_info "✓ ISO包含引导信息"
    fi
else
    print_error "ISO文件未生成"
    exit 1
fi

print_section "构建完成"
print_info "双引导ISO已成功创建"
print_info "BIOS引导: 使用SYSLINUX/ISOLINUX"
print_info "UEFI引导: 使用GRUB EFI"
