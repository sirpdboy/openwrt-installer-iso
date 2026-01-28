#!/bin/bash
# 修复的简化版Docker构建脚本

set -e

echo "=== OpenWRT ISO Builder (Fixed) ==="
echo "参数: $@"
echo ""

# 参数
IMG_FILE="$1"
OUTPUT_DIR="${2:-./output}"
ISO_NAME="${3:-openwrt-installer-$(date +%Y%m%d).iso}"
ALPINE_VERSION="${4:-3.20}"

# 基本检查
if [ $# -lt 1 ]; then
    echo "用法: $0 <img文件> [输出目录] [iso名称] [alpine版本]"
    echo "示例: $0 openwrt.img ./output openwrt.iso 3.20"
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

# 创建修复的Dockerfile
cat > /tmp/Dockerfile.fixed << 'EOF'
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION}

# 使用官方源
RUN echo "http://dl-cdn.alpinelinux.org/alpine/v$(echo ${ALPINE_VERSION} | cut -d. -f1-2)/main" > /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v$(echo ${ALPINE_VERSION} | cut -d. -f1-2)/community" >> /etc/apk/repositories

# 安装构建工具（分步安装避免冲突）
RUN apk update && \
    apk add --no-cache bash && \
    apk add --no-cache xorriso syslinux grub grub-efi && \
    apk add --no-cache mtools dosfstools parted e2fsprogs && \
    apk add --no-cache util-linux coreutils gzip tar jq && \
    rm -rf /var/cache/apk/*

WORKDIR /work
EOF

echo "构建Docker镜像..."
if docker build -f /tmp/Dockerfile.fixed --build-arg ALPINE_VERSION="$ALPINE_VERSION" -t alpine-openwrt-builder .; then
    echo "✅ Docker镜像构建成功"
else
    echo "❌ Docker镜像构建失败"
    exit 1
fi

# 创建修复的构建脚本
cat > /tmp/build-iso-fixed.sh << 'EOF'
#!/bin/bash
set -e

echo "=== 在容器内构建ISO ==="

# 创建ISO目录结构
mkdir -p /tmp/iso/{boot/grub,boot/isolinux,EFI/boot,images}

# 复制BIOS引导文件
cp /usr/share/syslinux/isolinux.bin /tmp/iso/boot/isolinux/
cp /usr/share/syslinux/ldlinux.c32 /tmp/iso/boot/isolinux/

# 创建ISOLINUX配置（修复内核参数）
cat > /tmp/iso/boot/isolinux/isolinux.cfg << 'ISOLINUX_EOF'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 50
MENU TITLE OpenWRT Installer

LABEL install
  MENU LABEL Install OpenWRT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200 earlyprintk

LABEL bootlocal
  MENU LABEL Boot from local disk
  LOCALBOOT 0x80

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32
ISOLINUX_EOF

# 创建GRUB配置
cat > /tmp/iso/boot/grub/grub.cfg << 'GRUB_EOF'
set timeout=5
menuentry "Install OpenWRT" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 earlyprintk
    initrd /boot/initrd.img
}
GRUB_EOF

# 复制UEFI GRUB配置
cp /tmp/iso/boot/grub/grub.cfg /tmp/iso/EFI/boot/grub.cfg

# 创建可引导内核（使用Alpine的内核）
if [ -f /boot/vmlinuz-lts ]; then
    cp /boot/vmlinuz-lts /tmp/iso/boot/vmlinuz
    echo "使用内核: vmlinuz-lts"
elif [ -f /boot/vmlinuz ]; then
    cp /boot/vmlinuz /tmp/iso/boot/vmlinuz
    echo "使用内核: vmlinuz"
else
    # 创建简单内核脚本
    cat > /tmp/iso/boot/vmlinuz << 'KERNEL_EOF'
#!/bin/sh
echo "========================================"
echo "   OpenWRT Installer - Installation Menu"
echo "========================================"
echo ""
echo "Available commands:"
echo "  install-openwrt <device>  - Install OpenWRT to device"
echo "  list-disks               - List available disks"
echo "  shell                    - Enter rescue shell"
echo ""
echo "Type 'help' for more information"
echo ""
exec /bin/sh
KERNEL_EOF
    chmod +x /tmp/iso/boot/vmlinuz
    echo "使用脚本内核"
fi

# 创建initrd（修复版）
echo "创建initrd..."
mkdir -p /tmp/initrd/{bin,dev,proc,sys,etc}

# 创建init脚本
cat > /tmp/initrd/init << 'INIT_EOF'
#!/bin/sh
# 挂载文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# 设备节点
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true

# 显示信息
echo "OpenWRT Installer is ready"
echo ""
echo "To install OpenWRT, run:"
echo "  dd if=/images/openwrt.img of=/dev/sdX bs=4M status=progress"
echo ""
echo "Available disks:"
if command -v fdisk >/dev/null 2>&1; then
    fdisk -l 2>/dev/null | grep "^Disk /dev/" || true
fi
echo ""
/bin/sh
INIT_EOF
chmod +x /tmp/initrd/init

# 复制busybox
if [ -f /bin/busybox ]; then
    cp /bin/busybox /tmp/initrd/bin/
    chmod +x /tmp/initrd/bin/busybox
    # 创建符号链接
    for cmd in sh ls echo cat dd mount umount; do
        ln -s busybox /tmp/initrd/bin/$cmd 2>/dev/null || true
    done
fi

# 打包initrd
(cd /tmp/initrd && find . | cpio -o -H newc | gzip -9 > /tmp/iso/boot/initrd.img)

# 复制OpenWRT镜像
cp /mnt/input.img /tmp/iso/images/openwrt.img

# 创建EFI引导文件
if command -v grub-mkimage >/dev/null 2>&1; then
    echo "创建EFI引导文件..."
    grub-mkimage \
        -O x86_64-efi \
        -o /tmp/iso/EFI/boot/bootx64.efi \
        -p /boot/grub \
        fat iso9660 part_gpt part_msdos normal boot linux
else
    echo "警告: 无法创建EFI引导文件"
fi

# 创建ISO（支持BIOS/UEFI）
echo "创建ISO文件..."
xorriso -as mkisofs \
    -r -V "OpenWRT_Installer" \
    -o /output/out.iso \
    -b boot/isolinux/isolinux.bin \
    -c boot/isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/boot/bootx64.efi \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    /tmp/iso

echo "✅ ISO构建完成"
EOF

chmod +x /tmp/build-iso-fixed.sh

echo "运行容器构建ISO..."
docker run --rm \
    -v "$IMG_ABS:/mnt/input.img:ro" \
    -v "$OUTPUT_ABS:/output:rw" \
    -v "/tmp/build-iso-fixed.sh:/build.sh:ro" \
    alpine-openwrt-builder \
    /bin/bash /build.sh

# 重命名输出文件
if [ -f "$OUTPUT_ABS/out.iso" ]; then
    mv "$OUTPUT_ABS/out.iso" "$OUTPUT_ABS/$ISO_NAME"
    echo ""
    echo "✅ ISO构建成功!"
    echo "文件: $OUTPUT_ABS/$ISO_NAME"
    echo "大小: $(du -h "$OUTPUT_ABS/$ISO_NAME" | cut -f1)"
    echo ""
    
    # 显示ISO信息
    if command -v isoinfo >/dev/null 2>&1; then
        echo "ISO信息:"
        isoinfo -d -i "$OUTPUT_ABS/$ISO_NAME" 2>/dev/null | grep -E "Volume id|Volume size" || true
    fi
    
    echo "✅ 构建完成！"
else
    echo "❌ ISO构建失败"
    exit 1
fi

# 清理
rm -f /tmp/Dockerfile.fixed /tmp/build-iso-fixed.sh
echo "临时文件已清理"
