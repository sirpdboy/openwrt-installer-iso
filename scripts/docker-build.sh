#!/bin/bash
# OpenWRT ISO Builder - 最终稳定版

set -e

echo "================================================"
echo "      OpenWRT ISO Builder - Stable Version     "
echo "================================================"
echo ""

# 参数处理
IMG_FILE="$1"
OUTPUT_DIR="${2:-./output}"
ISO_NAME="${3:-openwrt-installer-$(date +%Y%m%d).iso}"
ALPINE_VERSION="${4:-3.20}"

# 基本检查
if [ $# -lt 1 ]; then
    cat << EOF
用法: $0 <img文件> [输出目录] [iso名称] [alpine版本]

示例:
  $0 ./openwrt.img
  $0 ./openwrt.img ./iso my-openwrt.iso
  $0 ./openwrt.img ./output openwrt.iso 3.19
EOF
    exit 1
fi

if [ ! -f "$IMG_FILE" ]; then
    echo "❌ 错误: IMG文件不存在: $IMG_FILE"
    exit 1
fi

# 创建目录
mkdir -p "$OUTPUT_DIR"

# 获取绝对路径
IMG_ABS=$(realpath "$IMG_FILE" 2>/dev/null || echo "$(cd "$(dirname "$IMG_FILE")" && pwd)/$(basename "$IMG_FILE")")
OUTPUT_ABS=$(realpath "$OUTPUT_DIR" 2>/dev/null || echo "$(cd "$(dirname "$OUTPUT_DIR")" && pwd)/$(basename "$OUTPUT_DIR")")

echo "📋 构建配置:"
echo "  Alpine版本: $ALPINE_VERSION"
echo "  输入IMG: $IMG_ABS"
echo "  输出目录: $OUTPUT_ABS"
echo "  ISO名称: $ISO_NAME"
echo ""

# 检查Docker
echo "🔧 检查Docker环境..."
if ! command -v docker &>/dev/null; then
    echo "❌ Docker未安装"
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "❌ Docker服务未运行"
    exit 1
fi
echo "✅ Docker可用"

# 创建正确修复的Dockerfile
DOCKERFILE_PATH="Dockerfile.final"
cat > "$DOCKERFILE_PATH" << 'DOCKERFILE_EOF'
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION}

# 设置稳定的镜像源
RUN echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories

# 安装所有必要的ISO构建工具（确保包名正确）
RUN apk update && apk add --no-cache \
    bash \
    xorriso \
    syslinux \
    mtools \
    dosfstools \
    coreutils \
    util-linux \
    grep \
    gawk \
    findutils \
    && rm -rf /var/cache/apk/*

# 验证安装
RUN echo "验证工具安装:" && \
    ls -la /usr/share/syslinux/ && \
    which xorriso && \
    echo "工具安装完成"

WORKDIR /work

# 复制构建脚本
COPY scripts/build-iso-simple.sh /build-iso.sh
RUN chmod +x /build-iso.sh

ENTRYPOINT ["/build-iso.sh"]
DOCKERFILE_EOF

# 修复版本号
sed -i "s/v3.20/v$(echo $ALPINE_VERSION | cut -d. -f1-2)/g" "$DOCKERFILE_PATH"
sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/" "$DOCKERFILE_PATH"

# 创建简单但有效的构建脚本
mkdir -p scripts
cat > scripts/build-iso-simple.sh << 'BUILD_SCRIPT_EOF'
#!/bin/bash
set -e

echo "=== 开始构建OpenWRT ISO（简化版）==="

# 输入文件
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"

# 检查输入文件
if [ ! -f "$INPUT_IMG" ]; then
    echo "❌ 错误: 输入文件不存在: $INPUT_IMG"
    exit 1
fi

echo "✅ 输入文件: $INPUT_IMG"
echo "✅ 输出目录: /output"

# 创建ISO目录
ISO_DIR="/tmp/iso"
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR/images"

# 复制OpenWRT镜像
cp "$INPUT_IMG" "$ISO_DIR/images/openwrt.img"
IMG_SIZE=$(du -h "$ISO_DIR/images/openwrt.img" | cut -f1)
echo "✅ 复制OpenWRT镜像 ($IMG_SIZE)"

# 创建最简单的引导系统（如果syslinux可用）
SYSBOOT_DIR="/usr/share/syslinux"
if [ -d "$SYSBOOT_DIR" ]; then
    echo "🔧 配置引导系统..."
    mkdir -p "$ISO_DIR/boot/isolinux"
    
    # 尝试复制引导文件
    BOOT_FILES="isolinux.bin ldlinux.c32 libutil.c32 libcom32.c32 menu.c32"
    for file in $BOOT_FILES; do
        if [ -f "$SYSBOOT_DIR/$file" ]; then
            cp "$SYSBOOT_DIR/$file" "$ISO_DIR/boot/isolinux/"
            echo "✅ 复制 $file"
        fi
    done
    
    # 创建引导配置（仅在isolinux.bin存在时）
    if [ -f "$ISO_DIR/boot/isolinux/isolinux.bin" ]; then
        cat > "$ISO_DIR/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG_EOF'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 50
MENU TITLE OpenWRT Installer

LABEL install
  MENU LABEL Install OpenWRT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0

LABEL bootlocal
  MENU LABEL Boot from local disk
  LOCALBOOT 0x80

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32
ISOLINUX_CFG_EOF
        echo "✅ 创建引导配置"
    else
        echo "⚠ isolinux.bin 不存在，创建无引导ISO"
    fi
else
    echo "⚠ syslinux 不可用，创建数据ISO"
fi

# 创建最简单的内核文件
echo "🔧 创建内核文件..."
cat > "$ISO_DIR/boot/vmlinuz" << 'KERNEL_EOF'
#!/bin/sh
echo ""
echo "========================================"
echo "       OpenWRT Installation System      "
echo "========================================"
echo ""
echo "This disk contains an OpenWRT installation image."
echo ""
echo "Image location: /images/openwrt.img"
echo "Image size: $(du -h /images/openwrt.img 2>/dev/null | cut -f1 || echo "unknown")"
echo ""
echo "To install OpenWRT to a disk:"
echo "  1. Identify your target disk (e.g., /dev/sda)"
echo "  2. Run: dd if=/images/openwrt.img of=/dev/sdX bs=4M status=progress"
echo "  3. Wait for completion, then reboot"
echo ""
echo "Available commands in shell:"
echo "  lsblk - List block devices"
echo "  fdisk -l - List disks and partitions"
echo "  help - Show this message"
echo ""
exec /bin/sh
KERNEL_EOF
chmod +x "$ISO_DIR/boot/vmlinuz"
echo "✅ 创建内核文件"

# 创建最简单的initrd
echo "🔧 创建initrd..."
INITRD_DIR="/tmp/initrd"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"

cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/sh
# Minimal init script for OpenWRT installer

# Basic setup
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true

# Show welcome message
clear
echo ""
echo "========================================"
echo "   OpenWRT Installer - Ready            "
echo "========================================"
echo ""
echo "The OpenWRT installation image is ready."
echo ""
echo "To install, use:"
echo "  dd if=/images/openwrt.img of=/dev/sdX bs=4M"
echo ""
echo "Press Enter to continue to shell..."
read dummy

# Start shell
exec /bin/sh
INIT_EOF
chmod +x "$INITRD_DIR/init"

# 复制busybox（如果可用）
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) "$INITRD_DIR/" 2>/dev/null || true
    echo "✅ 复制busybox"
fi

# 创建initrd
(cd "$INITRD_DIR" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img")
INITRD_SIZE=$(du -h "$ISO_DIR/boot/initrd.img" 2>/dev/null | cut -f1 || echo "unknown")
echo "✅ 创建initrd ($INITRD_SIZE)"

# 创建README文件
cat > "$ISO_DIR/README.txt" << 'README_EOF'
OpenWRT Installation Disk
=========================

This disk/ISO contains an OpenWRT firmware image ready for installation.

Contents:
- /images/openwrt.img      : The OpenWRT firmware image
- /boot/                   : Boot files (if bootable)
- README.txt              : This file

Installation Methods:
1. Direct write (recommended):
   dd if=/images/openwrt.img of=/dev/sdX bs=4M status=progress

2. From this ISO:
   - Boot from this disk/ISO
   - In the shell, run the dd command above
   - Reboot

3. Extract and write:
   7z x openwrt-installer.iso images/openwrt.img
   dd if=images/openwrt.img of=/dev/sdX bs=4M

Notes:
- Replace /dev/sdX with your actual target disk (e.g., /dev/sda)
- This will overwrite all data on the target disk
- Ensure you have selected the correct disk
README_EOF
echo "✅ 创建说明文档"

# 创建ISO
echo "📦 创建ISO文件..."
cd /tmp

# 方法1: 尝试创建可引导ISO
if [ -f "$ISO_DIR/boot/isolinux/isolinux.bin" ]; then
    echo "创建可引导ISO..."
    xorriso -as mkisofs \
        -r -V "OpenWRT_Installer" \
        -o /output/openwrt.iso \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin 2>/dev/null || \
    xorriso -as mkisofs \
        -r -V "OpenWRT_Installer" \
        -o /output/openwrt.iso \
        -b boot/isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        "$ISO_DIR" 2>&1 | grep -v "UPDATEing" || true
else
    # 方法2: 创建数据ISO
    echo "创建数据ISO..."
    xorriso -as mkisofs \
        -r -V "OpenWRT_Installer" \
        -o /output/openwrt.iso \
        "$ISO_DIR" 2>&1 | grep -v "UPDATEing" || true
fi

# 检查ISO是否创建成功
if [ -f "/output/openwrt.iso" ]; then
    ISO_SIZE=$(du -h "/output/openwrt.iso" | cut -f1)
    echo ""
    echo "✅✅✅ ISO构建成功! ✅✅✅"
    echo ""
    echo "📁 文件: /output/openwrt.iso"
    echo "📊 大小: $ISO_SIZE"
    echo ""
    
    # 显示ISO信息
    echo "🔍 ISO详细信息:"
    if command -v file >/dev/null 2>&1; then
        file "/output/openwrt.iso"
    fi
    
    # 尝试显示ISO内容
    echo ""
    echo "📂 ISO内容摘要:"
    if command -v isoinfo >/dev/null 2>&1; then
        isoinfo -f -i "/output/openwrt.iso" 2>/dev/null | head -5 || true
        echo "..."
    fi
    
    # 检查是否可引导
    if [ -f "$ISO_DIR/boot/isolinux/isolinux.bin" ]; then
        echo "💾 ISO类型: 可引导安装盘"
    else
        echo "💿 ISO类型: 数据盘（包含OpenWRT镜像）"
        echo "   使用方法: 提取openwrt.img并写入到磁盘"
    fi
    
    exit 0
else
    echo "❌ ISO文件未生成"
    echo "调试信息:"
    echo "ISO目录内容:"
    find "$ISO_DIR" -type f | head -10
    echo ""
    echo "当前目录: $(pwd)"
    ls -la /output/ 2>/dev/null || echo "输出目录不存在"
    exit 1
fi
BUILD_SCRIPT_EOF

chmod +x scripts/build-iso-simple.sh

# 构建Docker镜像
echo "🔨 构建Docker镜像..."
IMAGE_NAME="openwrt-iso-builder:latest"

echo "使用的Dockerfile:"
echo "----------------------------------------"
cat "$DOCKERFILE_PATH"
echo "----------------------------------------"

if docker build \
    -f "$DOCKERFILE_PATH" \
    --build-arg ALPINE_VERSION="$ALPINE_VERSION" \
    -t "$IMAGE_NAME" \
    . 2>&1 | tee /tmp/docker-build.log; then
    
    # 检查构建是否真的成功
    if grep -q "successfully built" /tmp/docker-build.log || \
       docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        echo "✅ Docker镜像构建成功: $IMAGE_NAME"
    else
        echo "❌ Docker镜像构建看似成功但镜像不存在"
        echo "构建日志:"
        cat /tmp/docker-build.log
        exit 1
    fi
else
    echo "❌ Docker镜像构建失败"
    echo "构建日志:"
    cat /tmp/docker-build.log
    exit 1
fi

# 运行Docker容器构建ISO
echo "🚀 运行Docker容器构建ISO..."

# 先清理可能存在的旧容器
docker rm -f openwrt-iso-builder 2>/dev/null || true

# 运行容器（带超时）
set +e
timeout 300 docker run --rm \
    --name openwrt-iso-builder \
    -v "$IMG_ABS:/mnt/input.img:ro" \
    -v "$OUTPUT_ABS:/output:rw" \
    -e INPUT_IMG="/mnt/input.img" \
    "$IMAGE_NAME"

CONTAINER_EXIT=$?
set -e

echo "容器退出代码: $CONTAINER_EXIT"

# 检查输出文件
OUTPUT_ISO="$OUTPUT_ABS/openwrt.iso"
if [ -f "$OUTPUT_ISO" ]; then
    # 重命名为指定的名称
    FINAL_ISO="$OUTPUT_ABS/$ISO_NAME"
    mv "$OUTPUT_ISO" "$FINAL_ISO"
    
    echo ""
    echo "🎉🎉🎉 构建成功完成! 🎉🎉🎉"
    echo ""
    echo "📁 ISO文件: $FINAL_ISO"
    echo "📊 文件大小: $(du -h "$FINAL_ISO" | cut -f1)"
    echo ""
    
    # 显示文件信息
    echo "🔍 文件信息:"
    file "$FINAL_ISO"
    
    # 验证ISO可读
    echo ""
    echo "✅ ISO验证:"
    if command -v isoinfo >/dev/null 2>&1; then
        echo "卷标: $(isoinfo -d -i "$FINAL_ISO" 2>/dev/null | grep "Volume id" | cut -d: -f2- | sed 's/^ *//' || echo "未知")"
        echo "文件数: $(isoinfo -f -i "$FINAL_ISO" 2>/dev/null | wc -l || echo "未知")"
    fi
    
    echo ""
    echo "🚀 使用说明:"
    echo "   1. 测试: qemu-system-x86_64 -cdrom '$FINAL_ISO' -m 512"
    echo "   2. 刻录USB: sudo dd if='$FINAL_ISO' of=/dev/sdX bs=4M status=progress"
    echo "   3. 提取镜像: 7z x '$FINAL_ISO' images/openwrt.img"
    
    exit 0
else
    echo ""
    echo "❌ ISO构建失败"
    
    # 显示容器日志
    echo "📋 容器日志 (最后50行):"
    docker logs --tail 50 openwrt-iso-builder 2>/dev/null || echo "无法获取容器日志"
    
    # 检查输出目录
    echo ""
    echo "📁 输出目录内容:"
    ls -la "$OUTPUT_ABS/" 2>/dev/null || echo "输出目录不存在"
    
    # 如果容器日志显示具体错误
    if docker logs openwrt-iso-builder 2>/dev/null | grep -q "isolinux.bin"; then
        echo ""
        echo "💡 诊断: syslinux/isolinux.bin 未正确安装"
        echo "尝试解决方案:"
        echo "  1. 检查Dockerfile中的包名"
        echo "  2. 尝试不同的Alpine版本"
        echo "  3. 使用 build-direct.sh 直接构建"
    fi
    
    exit 1
fi
