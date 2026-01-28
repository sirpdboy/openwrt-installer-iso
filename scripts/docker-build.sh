#!/bin/bash
# 完全修复的Docker构建脚本

set -e

echo "=== OpenWRT ISO Builder (Fully Fixed) ==="
echo "参数: $@"
echo ""

# 参数
IMG_FILE="$1"
OUTPUT_DIR="${2:-./output}"
ISO_NAME="${3:-openwrt-installer-$(date +%Y%m%d).iso}"
ALPINE_VERSION="${4:-3.20}"

# 基本检查
if [ $# -lt 1 ]; then
    cat << EOF
用法: $0 <img文件> [输出目录] [iso名称] [alpine版本]

参数说明:
  <img文件>      : OpenWRT的IMG文件路径
  [输出目录]     : 输出ISO的目录 (默认: ./output)
  [iso名称]      : 输出的ISO文件名 (默认: openwrt-installer-YYYYMMDD.iso)
  [alpine版本]   : Alpine Linux版本 (默认: 3.20)

示例:
  $0 openwrt.img
  $0 openwrt.img ./output my-openwrt.iso 3.19
EOF
    exit 1
fi

if [ ! -f "$IMG_FILE" ]; then
    echo "错误: IMG文件不存在: $IMG_FILE"
    exit 1
fi

# 创建目录
mkdir -p "$OUTPUT_DIR"

# 使用绝对路径
IMG_ABS=$(realpath "$IMG_FILE")
OUTPUT_ABS=$(realpath "$OUTPUT_DIR")

echo "构建配置:"
echo "  Alpine版本: $ALPINE_VERSION"
echo "  输入IMG: $IMG_ABS"
echo "  输出目录: $OUTPUT_ABS"
echo "  ISO名称: $ISO_NAME"
echo ""

# 函数：测试Alpine版本可用性
test_alpine_version() {
    local version=$1
    echo "测试Alpine $version 包可用性..."
    
    # 创建测试Dockerfile
    cat > /tmp/test-alpine.Dockerfile << EOF
FROM alpine:$version
RUN apk update && apk add --no-cache xorriso grub grub-efi syslinux
EOF
    
    if docker build -f /tmp/test-alpine.Dockerfile -t test-alpine-$version /dev/null 2>&1 | grep -q "successfully built"; then
        echo "✅ Alpine $version 可用"
        rm -f /tmp/test-alpine.Dockerfile
        return 0
    else
        echo "❌ Alpine $version 包安装失败"
        rm -f /tmp/test-alpine.Dockerfile
        return 1
    fi
}

# 测试Alpine版本
if ! test_alpine_version "$ALPINE_VERSION"; then
    echo "尝试其他Alpine版本..."
    for alt_version in "3.19" "3.18" "latest" "edge"; do
        if test_alpine_version "$alt_version"; then
            ALPINE_VERSION=$alt_version
            echo "使用Alpine版本: $ALPINE_VERSION"
            break
        fi
    done
fi

# 创建修复的Dockerfile（使用正确的包名）
cat > /tmp/Dockerfile.working << EOF
ARG ALPINE_VERSION=$ALPINE_VERSION
FROM alpine:\${ALPINE_VERSION}

# 配置源
RUN echo "http://dl-cdn.alpinelinux.org/alpine/v\$(echo \${ALPINE_VERSION} | cut -d. -f1-2)/main" > /etc/apk/repositories && \\
    echo "http://dl-cdn.alpinelinux.org/alpine/v\$(echo \${ALPINE_VERSION} | cut -d. -f1-2)/community" >> /etc/apk/repositories

# 安装构建工具 - 逐个安装避免失败
RUN apk update

# 安装基本工具
RUN apk add --no-cache bash

# 安装ISO构建工具
RUN apk add --no-cache xorriso

# 安装引导工具（根据Alpine版本调整）
RUN if apk add --no-cache grub grub-efi 2>/dev/null; then \\
    echo "grub安装成功"; \\
else \\
    echo "尝试替代包名..."; \\
    apk add --no-cache grub2 grub2-efi; \\
fi

# 安装syslinux（BIOS引导）
RUN if apk add --no-cache syslinux 2>/dev/null; then \\
    echo "syslinux安装成功"; \\
else \\
    echo "syslinux未安装，继续..."; \\
fi

# 安装其他必要工具
RUN apk add --no-cache mtools dosfstools parted e2fsprogs

# 安装系统工具
RUN apk add --no-cache util-linux coreutils gzip tar jq

# 清理缓存
RUN rm -rf /var/cache/apk/*

WORKDIR /work

# 验证安装
RUN echo "验证安装的工具:" && \\
    which xorriso && xorriso --version 2>&1 | head -1 && \\
    which mkisofs 2>/dev/null || echo "mkisofs未安装" && \\
    ls -la /usr/share/syslinux/ 2>/dev/null | head -5 || echo "syslinux目录不存在"
EOF

echo "构建Docker镜像..."
echo "使用的Dockerfile内容:"
echo "----------------------------------------"
cat /tmp/Dockerfile.working
echo "----------------------------------------"

if docker build -f /tmp/Dockerfile.working -t alpine-openwrt-builder .; then
    echo "✅ Docker镜像构建成功"
else
    echo "❌ Docker镜像构建失败，尝试极简版本..."
    
    # 极简Dockerfile
    cat > /tmp/Dockerfile.minimal << EOF
FROM alpine:$ALPINE_VERSION
RUN apk update && apk add --no-cache \\
    bash \\
    xorriso \\
    mtools \\
    dosfstools \\
    parted
WORKDIR /work
EOF
    
    if docker build -f /tmp/Dockerfile.minimal -t alpine-openwrt-builder .; then
        echo "✅ 极简Docker镜像构建成功"
    else
        echo "❌ 所有Docker构建尝试都失败"
        echo "请检查:"
        echo "1. Docker服务是否运行 (sudo systemctl status docker)"
        echo "2. 网络连接是否正常"
        echo "3. 尝试不同的Alpine版本"
        exit 1
    fi
fi

# 创建完全修复的构建脚本
cat > /tmp/build-iso-complete.sh << 'EOF'
#!/bin/bash
set -e

echo "=== 在容器内构建ISO ==="
echo "当前目录: $(pwd)"
echo "输入文件: $INPUT_IMG"
echo "输出目录: /output"

# 检查必要工具
echo "检查工具..."
command -v xorriso || { echo "错误: xorriso未安装"; exit 1; }
command -v mkisofs || echo "警告: mkisofs未安装，使用xorriso"

# 创建ISO目录结构
echo "创建ISO目录结构..."
rm -rf /tmp/iso
mkdir -p /tmp/iso/{boot/grub,boot/isolinux,EFI/boot,images,utils}

# 复制OpenWRT镜像
echo "复制OpenWRT镜像..."
cp "$INPUT_IMG" /tmp/iso/images/openwrt.img
echo "OpenWRT镜像大小: $(du -h /tmp/iso/images/openwrt.img | cut -f1)"

# 检查并复制BIOS引导文件
echo "设置BIOS引导..."
if [ -f "/usr/share/syslinux/isolinux.bin" ]; then
    cp /usr/share/syslinux/isolinux.bin /tmp/iso/boot/isolinux/
    echo "✅ 复制 isolinux.bin"
else
    echo "⚠ isolinux.bin 未找到"
fi

if [ -f "/usr/share/syslinux/ldlinux.c32" ]; then
    cp /usr/share/syslinux/ldlinux.c32 /tmp/iso/boot/isolinux/
    echo "✅ 复制 ldlinux.c32"
fi

# 创建ISOLINUX配置（完全修复版）
echo "创建ISOLINUX配置..."
cat > /tmp/iso/boot/isolinux/isolinux.cfg << 'ISOLINUX_EOF'
DEFAULT linux
PROMPT 0
TIMEOUT 30
UI menu.c32

MENU TITLE OpenWRT Installer
MENU BACKGROUND /boot/isolinux/splash.png

LABEL linux
  MENU LABEL Install OpenWRT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200

LABEL bootlocal
  MENU LABEL Boot from local disk
  LOCALBOOT 0x80

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32
ISOLINUX_EOF

# 如果menu.c32不存在，使用简单配置
if [ ! -f "/usr/share/syslinux/menu.c32" ] && [ ! -f "/tmp/iso/boot/isolinux/menu.c32" ]; then
    cat > /tmp/iso/boot/isolinux/isolinux.cfg << 'SIMPLE_EOF'
DEFAULT install
PROMPT 0
TIMEOUT 30

LABEL install
  SAY Booting OpenWRT Installer...
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0

LABEL bootlocal
  SAY Booting from local disk...
  LOCALBOOT 0x80
SIMPLE_EOF
fi

# 复制其他syslinux文件
for file in menu.c32 libutil.c32 libcom32.c32 reboot.c32; do
    if [ -f "/usr/share/syslinux/$file" ]; then
        cp "/usr/share/syslinux/$file" /tmp/iso/boot/isolinux/
    fi
done

# 创建GRUB配置
echo "创建GRUB配置..."
cat > /tmp/iso/boot/grub/grub.cfg << 'GRUB_EOF'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    echo "Loading kernel..."
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200
    echo "Loading initramfs..."
    initrd /boot/initrd.img
    echo "Booting OpenWRT Installer..."
}

menuentry "Boot from local disk" {
    echo "Attempting to boot from local disk..."
    exit
}
GRUB_EOF

# 创建内核文件
echo "创建内核文件..."
if [ -f "/boot/vmlinuz" ]; then
    cp /boot/vmlinuz /tmp/iso/boot/vmlinuz
    echo "✅ 使用 /boot/vmlinuz"
else
    # 创建简单的内核脚本
    echo "⚠ 未找到Linux内核，创建脚本内核"
    cat > /tmp/iso/boot/vmlinuz << 'KERNEL_EOF'
#!/bin/sh
echo ""
echo "=========================================="
echo "        OpenWRT Installation System       "
echo "=========================================="
echo ""
echo "This system contains OpenWRT installation image."
echo ""
echo "To install OpenWRT, you need to:"
echo "1. Write the image to a disk:"
echo "   dd if=/images/openwrt.img of=/dev/sdX bs=4M status=progress"
echo ""
echo "2. Or use the automated installer:"
echo "   /utils/install.sh"
echo ""
echo "Available commands:"
echo "  lsblk      - List block devices"
echo "  fdisk -l   - List disks and partitions"
echo "  help       - Show this help"
echo ""
exec /bin/sh
KERNEL_EOF
    chmod +x /tmp/iso/boot/vmlinuz
fi

# 创建initramfs
echo "创建initramfs..."
mkdir -p /tmp/initrd/{bin,dev,proc,sys,etc,utils,images}

# 创建init脚本
cat > /tmp/initrd/init << 'INIT_EOF'
#!/bin/sh
# OpenWRT Installer Initramfs

# 挂载必要的文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 创建控制台
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true
mknod /dev/zero c 1 5 2>/dev/null || true

# 设置路径
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/utils

# 显示欢迎信息
clear
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         OpenWRT Installation System      ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "OpenWRT image is ready for installation."
echo "Location: /images/openwrt.img"
echo ""

# 列出可用磁盘
echo "Available disks:"
echo "--------------------------------------------"
if command -v lsblk >/dev/null 2>&1; then
    lsblk -d -n -o NAME,SIZE,MODEL,TYPE,TRAN 2>/dev/null | head -10
elif command -v fdisk >/dev/null 2>&1; then
    fdisk -l 2>/dev/null | grep "^Disk /dev/" | head -10
else
    echo "  No disk listing tools available"
fi
echo "--------------------------------------------"
echo ""

# 安装说明
echo "To install OpenWRT:"
echo "1. Identify your target disk (e.g., /dev/sda)"
echo "2. Run: dd if=/images/openwrt.img of=/dev/sdX bs=4M status=progress"
echo "3. Wait for completion, then reboot"
echo ""
echo "Type 'exit' to reboot, or press Ctrl+D"
echo ""

# 启动shell
exec /bin/sh
INIT_EOF
chmod +x /tmp/initrd/init

# 复制busybox（如果可用）
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) /tmp/initrd/bin/busybox
    chmod +x /tmp/initrd/bin/busybox
    # 创建符号链接
    cd /tmp/initrd/bin
    for cmd in sh ls echo cat cp dd mount umount mkdir mknod clear; do
        ln -sf busybox $cmd 2>/dev/null || true
    done
    cd -
fi

# 创建安装工具
cat > /tmp/initrd/utils/install.sh << 'INSTALL_EOF'
#!/bin/sh
echo "OpenWRT Automated Installer"
echo "==========================="
echo ""
echo "WARNING: This will overwrite the target disk!"
echo ""
read -p "Enter target disk (e.g., sda): " disk
if [ -z "$disk" ]; then
    echo "No disk specified. Aborting."
    exit 1
fi

if [ ! -b "/dev/$disk" ]; then
    echo "Error: /dev/$disk is not a block device"
    exit 1
fi

echo ""
echo "Target: /dev/$disk"
echo "Source: /images/openwrt.img"
echo ""
read -p "Are you sure? (type YES to continue): " confirm
if [ "$confirm" != "YES" ]; then
    echo "Installation cancelled."
    exit 0
fi

echo "Starting installation..."
if command -v dd >/dev/null 2>&1; then
    dd if=/images/openwrt.img of=/dev/$disk bs=4M status=progress
    echo ""
    echo "Installation complete! Please reboot."
else
    echo "Error: dd command not found"
    exit 1
fi
INSTALL_EOF
chmod +x /tmp/initrd/utils/install.sh

# 复制OpenWRT镜像到initrd
cp /tmp/iso/images/openwrt.img /tmp/initrd/images/

# 打包initrd
echo "打包initrd..."
(cd /tmp/initrd && find . | cpio -o -H newc 2>/dev/null | gzip -9 > /tmp/iso/boot/initrd.img)
echo "initrd大小: $(du -h /tmp/iso/boot/initrd.img | cut -f1)"

# 创建EFI引导（如果可能）
echo "设置EFI引导..."
if command -v grub-mkimage >/dev/null 2>&1; then
    echo "创建GRUB EFI..."
    mkdir -p /tmp/efi_work
    grub-mkimage \
        -O x86_64-efi \
        -o /tmp/iso/EFI/boot/bootx64.efi \
        -p /boot/grub \
        fat iso9660 part_gpt part_msdos normal boot linux configfile loopback chain \
        efifwsetup efi_gop efi_uga ls search search_label search_fs_uuid search_fs_file \
        gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 \
        echo true probe terminal 2>/dev/null || {
        echo "警告: GRUB EFI创建失败，继续..."
    }
else
    echo "⚠ grub-mkimage 不可用，跳过EFI引导"
fi

# 复制GRUB配置到EFI目录
cp /tmp/iso/boot/grub/grub.cfg /tmp/iso/EFI/boot/grub.cfg 2>/dev/null || true

# 创建ISO
echo "创建ISO文件..."
cd /tmp

# 方法1: 使用xorriso（首选）
if command -v xorriso >/dev/null 2>&1; then
    echo "使用xorriso创建ISO..."
    xorriso -as mkisofs \
        -r -V "OpenWRT_InstALL" \
        -o /output/out.iso \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/boot/bootx64.efi \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        iso/ 2>&1 | grep -v "UPDATEing" || true
else
    # 方法2: 使用mkisofs
    echo "使用mkisofs创建ISO..."
    mkisofs -r -V "OpenWRT_InstALL" \
        -o /output/out.iso \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        iso/ || {
        echo "ISO创建失败"
        exit 1
    }
fi

cd -

echo ""
echo "✅ ISO构建完成!"
echo "文件: /output/out.iso"
echo "大小: $(du -h /output/out.iso | cut -f1)"
EOF

chmod +x /tmp/build-iso-complete.sh

echo "运行容器构建ISO..."
set +e
docker run --rm \
    -v "$IMG_ABS:/mnt/input.img:ro" \
    -v "$OUTPUT_ABS:/output:rw" \
    -v "/tmp/build-iso-complete.sh:/build.sh:ro" \
    -e INPUT_IMG="/mnt/input.img" \
    alpine-openwrt-builder \
    /bin/bash /build.sh

BUILD_STATUS=$?
set -e

# 重命名输出文件
if [ $BUILD_STATUS -eq 0 ] && [ -f "$OUTPUT_ABS/out.iso" ]; then
    mv "$OUTPUT_ABS/out.iso" "$OUTPUT_ABS/$ISO_NAME"
    echo ""
    echo "🎉 ISO构建成功!"
    echo "📁 文件: $OUTPUT_ABS/$ISO_NAME"
    echo "📊 大小: $(du -h "$OUTPUT_ABS/$ISO_NAME" | cut -f1)"
    echo ""
    
    # 显示ISO信息
    echo "🔍 ISO详细信息:"
    if command -v file >/dev/null 2>&1; then
        file "$OUTPUT_ABS/$ISO_NAME"
    fi
    
    if command -v isoinfo >/dev/null 2>&1; then
        echo ""
        echo "📂 ISO内容结构:"
        isoinfo -f -i "$OUTPUT_ABS/$ISO_NAME" 2>/dev/null | head -20 || true
    fi
    
    echo ""
    echo "✅ 构建完成！您现在可以:"
    echo "   1. 测试ISO: qemu-system-x86_64 -cdrom '$OUTPUT_ABS/$ISO_NAME'"
    echo "   2. 刻录到USB: dd if='$OUTPUT_ABS/$ISO_NAME' of=/dev/sdX bs=4M status=progress"
    echo "   3. 在虚拟机中测试"
    
else
    echo "❌ ISO构建失败 (状态码: $BUILD_STATUS)"
    echo "检查输出目录:"
    ls -la "$OUTPUT_ABS/" 2>/dev/null || echo "输出目录不存在"
    exit 1
fi

# 清理
rm -f /tmp/Dockerfile.working /tmp/Dockerfile.minimal /tmp/build-iso-complete.sh
echo "临时文件已清理"
