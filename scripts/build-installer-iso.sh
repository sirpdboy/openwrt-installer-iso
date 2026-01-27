#!/bin/bash
# OpenWRT安装ISO构建主脚本
# 支持BIOS/UEFI双引导，包含自动安装程序

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_header() { echo -e "${CYAN}\n$1${NC}"; }
print_step() { echo -e "${MAGENTA}▶${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

# ================= 配置检查 =================
print_header "OpenWRT安装ISO构建器"
echo -e "${BLUE}===============================================${NC}"

# 检查环境变量
if [ -z "${ALPINE_VERSION}" ]; then
    ALPINE_VERSION="3.18.6"
    print_warning "使用默认Alpine版本: ${ALPINE_VERSION}"
fi

if [ -z "${INPUT_IMG}" ] || [ ! -f "${INPUT_IMG}" ]; then
    print_error "未找到输入IMG文件: ${INPUT_IMG}"
    exit 1
fi

if [ -z "${OUTPUT_ISO_FILENAME}" ]; then
    OUTPUT_ISO_FILENAME="openwrt-installer.iso"
    print_warning "使用默认输出文件名: ${OUTPUT_ISO_FILENAME}"
fi

OUTPUT_ISO="/output/${OUTPUT_ISO_FILENAME}"
WORK_DIR="/work"

print_success "配置检查完成"
print_step "Alpine版本: ${ALPINE_VERSION}"
print_step "输入IMG文件: ${INPUT_IMG}"
print_step "输出ISO文件: ${OUTPUT_ISO}"
print_step "工作目录: ${WORK_DIR}"
echo -e "${BLUE}===============================================${NC}"

# ================= 清理和准备 =================
print_header "1. 准备工作目录"
rm -rf ${WORK_DIR} ${OUTPUT_ISO}
mkdir -p ${WORK_DIR}/{rootfs,iso/{boot,EFI/boot,img,mnt}} /output

print_success "目录结构创建完成"

# ================= 下载Alpine rootfs =================
print_header "2. 下载Alpine rootfs"

MAJOR_VER=$(echo ${ALPINE_VERSION} | cut -d. -f1-2)
ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}-x86_64.tar.gz"

# 尝试多个镜像源
MIRRORS=(
    "https://mirrors.tuna.tsinghua.edu.cn/alpine/v${MAJOR_VER}/releases/x86_64"
    "https://mirrors.aliyun.com/alpine/v${MAJOR_VER}/releases/x86_64"
    "https://dl-cdn.alpinelinux.org/alpine/v${MAJOR_VER}/releases/x86_64"
)

DOWNLOADED=0
for MIRROR in "${MIRRORS[@]}"; do
    URL="${MIRROR}/${ROOTFS_FILE}"
    print_step "尝试下载: $(basename ${URL})"
    
    if curl -s -f -L -o ${WORK_DIR}/rootfs.tar.gz "${URL}" && \
       tar -tzf ${WORK_DIR}/rootfs.tar.gz >/dev/null 2>&1; then
        DOWNLOADED=1
        print_success "下载成功 (源: $(echo ${MIRROR} | cut -d/ -f3))"
        break
    fi
    print_warning "下载失败，尝试下一个镜像"
done

if [ ${DOWNLOADED} -eq 0 ]; then
    print_error "所有镜像下载失败"
    exit 1
fi

# ================= 解压和配置rootfs =================
print_header "3. 配置Alpine系统"
print_step "解压rootfs..."
tar -xzf ${WORK_DIR}/rootfs.tar.gz -C ${WORK_DIR}/rootfs

# 配置APK源
cat > ${WORK_DIR}/rootfs/etc/apk/repositories << EOF
https://mirrors.tuna.tsinghua.edu.cn/alpine/v${MAJOR_VER}/main
https://mirrors.tuna.tsinghua.edu.cn/alpine/v${MAJOR_VER}/community
EOF

# 安装必需软件包
print_step "安装系统软件包..."
chroot ${WORK_DIR}/rootfs /bin/sh << 'EOF'
apk update
apk add --no-cache \
    alpine-base \
    linux-lts \
    grub-efi \
    grub-bios \
    syslinux \
    parted \
    e2fsprogs \
    util-linux \
    coreutils \
    bash \
    dialog \
    fdisk \
    grep \
    sed \
    gawk \
    lsblk \
    which
EOF

print_success "系统配置完成"

# ================= 复制IMG文件到ISO =================
print_header "4. 打包IMG文件"
IMG_SIZE=$(du -h ${INPUT_IMG} | cut -f1)
print_step "复制IMG文件: ${IMG_SIZE}"

cp ${INPUT_IMG} ${WORK_DIR}/iso/img/openwrt.img

# 创建IMG信息文件
cat > ${WORK_DIR}/iso/img/image.info << EOF
# OpenWRT系统镜像信息
IMAGE_NAME="openwrt.img"
IMAGE_SIZE=$(stat -c%s ${INPUT_IMG})
IMAGE_SIZE_HUMAN=${IMG_SIZE}
CREATED_DATE="$(date +'%Y-%m-%d %H:%M:%S')"
VERSION="1.0"
DESCRIPTION="OpenWRT路由器系统镜像"
EOF

print_success "IMG文件打包完成"

# ================= 安装自动安装脚本 =================
print_header "5. 配置自动安装系统"

# 创建自动登录配置
cat > ${WORK_DIR}/rootfs/etc/inittab << 'EOF'
# /etc/inittab

# Set default runlevel
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# Start auto-installer on tty1
tty1::respawn:/bin/sh /usr/local/bin/auto-install

# Keep some terminals open for debugging
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3
EOF

# 复制自动安装脚本
cp /usr/local/include/auto-install ${WORK_DIR}/rootfs/usr/local/bin/
chmod +x ${WORK_DIR}/rootfs/usr/local/bin/auto-install

# 创建初始化脚本
cat > ${WORK_DIR}/rootfs/etc/local.d/auto-start.start << 'EOF'
#!/bin/sh
# 启动脚本

# 挂载ISO中的IMG目录
mkdir -p /mnt/iso
mount -t iso9660 /dev/sr0 /mnt/iso 2>/dev/null || mount -t iso9660 /dev/cdrom /mnt/iso 2>/dev/null

if [ -d /mnt/iso/img ]; then
    mkdir -p /img
    cp /mnt/iso/img/openwrt.img /img/ 2>/dev/null
    cp /mnt/iso/img/image.info /img/ 2>/dev/null
fi

# 设置网络（如果需要）
ip link set up dev lo
EOF

chmod +x ${WORK_DIR}/rootfs/etc/local.d/auto-start.start

print_success "自动安装系统配置完成"

# ================= 配置引导系统 =================
print_header "6. 配置双引导系统"

# BIOS引导 (SYSLINUX)
print_step "配置BIOS引导..."
cp /usr/share/syslinux/isolinux.bin ${WORK_DIR}/iso/boot/
cp /usr/share/syslinux/ldlinux.c32 ${WORK_DIR}/iso/boot/
cp /usr/share/syslinux/libutil.c32 ${WORK_DIR}/iso/boot/
cp /usr/share/syslinux/vesamenu.c32 ${WORK_DIR}/iso/boot/
cp /usr/share/syslinux/menu.c32 ${WORK_DIR}/iso/boot/

cat > ${WORK_DIR}/iso/boot/isolinux.cfg << 'EOF'
DEFAULT autoinstall
TIMEOUT 30
PROMPT 0
MENU TITLE OpenWRT安装系统

MENU BACKGROUND splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std

LABEL autoinstall
  MENU LABEL ^自动安装OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-lts modules=loop,squashfs,sd-mod,usb-storage quiet console=tty0 console=ttyS0,115200

LABEL debug
  MENU LABEL ^调试模式
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-lts modules=loop,squashfs,sd-mod,usb-storage

LABEL shell
  MENU LABEL ^进入Shell
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-lts modules=loop,squashfs,sd-mod,usb-storage init=/bin/sh

LABEL reboot
  MENU LABEL ^重启
  COM32 reboot.c32
EOF

# UEFI引导 (GRUB)
print_step "配置UEFI引导..."
cp /usr/lib/grub/x86_64-efi/grub.efi ${WORK_DIR}/iso/EFI/boot/bootx64.efi
cp /usr/lib/grub/i386-efi/grub.efi ${WORK_DIR}/iso/EFI/boot/bootia32.efi 2>/dev/null || true

cat > ${WORK_DIR}/iso/EFI/boot/grub.cfg << 'EOF'
set timeout=5
set default=0

menuentry "自动安装OpenWRT" {
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage quiet console=tty0 console=ttyS0,115200
    initrd /boot/initramfs-lts
}

menuentry "调试模式" {
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage
    initrd /boot/initramfs-lts
}

menuentry "进入Shell" {
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage init=/bin/sh
    initrd /boot/initramfs-lts
}

menuentry "重启" {
    reboot
}
EOF

print_success "双引导系统配置完成"

# ================= 复制内核文件 =================
print_header "7. 准备内核文件"

# 复制内核
if [ -f "${WORK_DIR}/rootfs/boot/vmlinuz-lts" ]; then
    cp "${WORK_DIR}/rootfs/boot/vmlinuz-lts" "${WORK_DIR}/iso/boot/"
else
    print_warning "在rootfs中未找到内核，使用默认内核"
    cp /boot/vmlinuz-lts "${WORK_DIR}/iso/boot/" 2>/dev/null || true
fi

# 创建initramfs
print_step "创建initramfs..."
chroot ${WORK_DIR}/rootfs /bin/sh << 'EOF'
apk add --no-cache mkinitfs
mkinitfs -c /etc/mkinitfs/mkinitfs.conf -b / /boot/initramfs-lts
EOF

cp ${WORK_DIR}/rootfs/boot/initramfs-lts ${WORK_DIR}/iso/boot/ 2>/dev/null || \
touch ${WORK_DIR}/iso/boot/initramfs-lts

print_success "内核文件准备完成"

# ================= 创建squashfs =================
print_header "8. 创建系统镜像"
print_step "压缩系统文件..."

# 排除不需要的文件
cat > ${WORK_DIR}/exclude.txt << 'EOF'
boot/*
dev/*
proc/*
sys/*
tmp/*
EOF

mksquashfs ${WORK_DIR}/rootfs ${WORK_DIR}/iso/alpine.squashfs \
    -comp xz \
    -ef ${WORK_DIR}/exclude.txt \
    -noappend 2>/dev/null

SQUASHFS_SIZE=$(du -h ${WORK_DIR}/iso/alpine.squashfs | cut -f1)
print_success "系统镜像创建完成: ${SQUASHFS_SIZE}"

# ================= 创建ISO =================
print_header "9. 创建安装ISO"

cd ${WORK_DIR}/iso

# 创建ISO
xorriso -as mkisofs \
    -volid "OPENWRT_INSTALLER" \
    -full-iso9660-filenames \
    -J -joliet-long -rock \
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
    -output "${OUTPUT_ISO}" . 2>/dev/null

# 添加UEFI引导支持
isohybrid -u "${OUTPUT_ISO}" 2>/dev/null || true

print_success "ISO创建完成"

# ================= 验证输出 =================
print_header "10. 构建完成"

if [ -f "${OUTPUT_ISO}" ]; then
    ISO_SIZE=$(du -h "${OUTPUT_ISO}" | cut -f1)
    
    echo -e "${BLUE}===============================================${NC}"
    print_success "OpenWRT安装ISO构建成功！"
    echo -e "${BLUE}===============================================${NC}"
    print_step "文件: ${OUTPUT_ISO}"
    print_step "大小: ${ISO_SIZE}"
    print_step "包含IMG: $(basename ${INPUT_IMG}) (${IMG_SIZE})"
    echo ""
    print_step "支持的引导模式:"
    print_step "  • BIOS (传统模式)"
    print_step "  • UEFI x64 (64位)"
    print_step "  • UEFI ia32 (32位，如支持)"
    echo ""
    print_step "启动后功能:"
    print_step "  • 自动登录并运行安装程序"
    print_step "  • 显示硬盘选择菜单"
    print_step "  • 确认后写入IMG到硬盘"
    print_step "  • 完成后自动重启"
    echo -e "${BLUE}===============================================${NC}"
else
    print_error "ISO文件创建失败"
    exit 1
fi

print_header "准备就绪！"
echo -e "${GREEN}OpenWRT安装ISO已构建完成，可以烧录到USB或光盘使用。${NC}"
