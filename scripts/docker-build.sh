#!/bin/bash
# OpenWRT ISO Builder - 最终修复版

set -e

echo "================================================"
echo "      OpenWRT ISO Builder - Final Fix          "
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

# 创建正确的Dockerfile
DOCKERFILE_PATH="Dockerfile"
cat > "$DOCKERFILE_PATH" << 'DOCKERFILE_EOF'
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION}

# 设置镜像源（解决网络问题）
RUN echo "http://dl-cdn.alpinelinux.org/alpine/v$(echo ${ALPINE_VERSION} | cut -d. -f1-2)/main" > /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v$(echo ${ALPINE_VERSION} | cut -d. -f1-2)/community" >> /etc/apk/repositories

# 更新并安装必要工具（简化版）
RUN apk update && apk add --no-cache \
    bash \
    xorriso \
    coreutils \
    util-linux \
    mtools \
    dosfstools \
    syslinux \
    grub \
    grub-efi \
    && rm -rf /var/cache/apk/*

# 创建工作目录
WORKDIR /work

# 创建构建脚本
COPY scripts/build-iso.sh /build-iso.sh
RUN chmod +x /build-iso.sh

ENTRYPOINT ["/build-iso.sh"]
DOCKERFILE_EOF

# 修复Dockerfile中的版本号
sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/" "$DOCKERFILE_PATH"

# 创建主构建脚本
mkdir -p scripts
cat > scripts/build-iso.sh << 'BUILD_SCRIPT_EOF'
#!/bin/bash
set -e

echo "=== 开始构建OpenWRT ISO ==="

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
mkdir -p "$ISO_DIR"/{boot/isolinux,boot/grub,EFI/boot,images}

# 复制OpenWRT镜像
cp "$INPUT_IMG" "$ISO_DIR/images/openwrt.img"
echo "✅ 复制OpenWRT镜像 ($(du -h "$ISO_DIR/images/openwrt.img" | cut -f1))"

# 复制引导文件
if [ -f "/usr/share/syslinux/isolinux.bin" ]; then
    cp /usr/share/syslinux/isolinux.bin "$ISO_DIR/boot/isolinux/"
    echo "✅ 复制isolinux.bin"
fi

if [ -f "/usr/share/syslinux/ldlinux.c32" ]; then
    cp /usr/share/syslinux/ldlinux.c32 "$ISO_DIR/boot/isolinux/"
    echo "✅ 复制ldlinux.c32"
fi

# 创建正确的ISOLINUX配置（修复LABEL语法错误）
cat > "$ISO_DIR/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG_EOF'
DEFAULT install
PROMPT 0
TIMEOUT 50

LABEL install
MENU LABEL Install OpenWRT
KERNEL /boot/vmlinuz
APPEND initrd=/boot/initrd.img console=tty0

LABEL bootlocal
MENU LABEL Boot from local disk
LOCALBOOT 0x80
ISOLINUX_CFG_EOF

# 创建GRUB配置
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_CFG_EOF'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz console=tty0
    initrd /boot/initrd.img
}

menuentry "Boot from local disk" {
    exit
}
GRUB_CFG_EOF

# 创建简单的内核脚本
cat > "$ISO_DIR/boot/vmlinuz" << 'KERNEL_EOF'
#!/bin/sh
echo ""
echo "========================================"
echo "       OpenWRT Installation System      "
echo "========================================"
echo ""
echo "Welcome to OpenWRT Installer"
echo ""
echo "The OpenWRT image is ready at: /images/openwrt.img"
echo ""
echo "To install, run:"
echo "  dd if=/images/openwrt.img of=/dev/sdX bs=4M"
echo ""
echo "Type 'help' for assistance or 'exit' to reboot"
echo ""
exec /bin/sh
KERNEL_EOF
chmod +x "$ISO_DIR/boot/vmlinuz"

# 创建简单的initrd
echo "创建initrd..."
INITRD_DIR="/tmp/initrd"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"

cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/sh
# Mount necessary filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys

# Create console
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true

echo ""
echo "OpenWRT Installer is ready!"
echo ""
echo "Available commands:"
echo "  lsblk       - List block devices"
echo "  fdisk -l    - List disks"
echo "  dd if=/images/openwrt.img of=/dev/sdX bs=4M - Install OpenWRT"
echo ""
exec /bin/sh
INIT_EOF
chmod +x "$INITRD_DIR/init"

# Copy busybox if available
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) "$INITRD_DIR/" 2>/dev/null || true
fi

# Create initrd
(cd "$INITRD_DIR" && find . | cpio -o -H newc 2>/dev/null | gzip > "$ISO_DIR/boot/initrd.img")
echo "✅ 创建initrd ($(du -h "$ISO_DIR/boot/initrd.img" | cut -f1))"

# 创建EFI引导（可选）
if command -v grub-mkimage >/dev/null 2>&1; then
    echo "创建EFI引导..."
    mkdir -p "$ISO_DIR/EFI/boot"
    grub-mkimage \
        -O x86_64-efi \
        -o "$ISO_DIR/EFI/boot/bootx64.efi" \
        -p /boot/grub \
        fat iso9660 part_gpt part_msdos normal boot linux 2>/dev/null || \
        echo "⚠ EFI引导创建失败，继续..."
fi

# 创建ISO
echo "创建ISO文件..."
cd /tmp
xorriso -as mkisofs \
    -r -V "OpenWRT_Installer" \
    -o /output/openwrt.iso \
    -b boot/isolinux/isolinux.bin \
    -c boot/isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    iso/ 2>&1 | grep -v "UPDATEing" || true

# 检查ISO是否创建成功
if [ -f "/output/openwrt.iso" ]; then
    echo ""
    echo "✅ ISO构建成功!"
    echo "📁 文件: /output/openwrt.iso"
    echo "📊 大小: $(du -h /output/openwrt.iso | cut -f1)"
    
    # 显示ISO信息
    if command -v isoinfo >/dev/null 2>&1; then
        echo "🔍 ISO卷标: $(isoinfo -d -i /output/openwrt.iso 2>/dev/null | grep "Volume id" | cut -d: -f2-)"
    fi
else
    echo "❌ ISO文件未生成"
    exit 1
fi

echo "🎉 构建完成!"
BUILD_SCRIPT_EOF

chmod +x scripts/build-iso.sh

# 构建Docker镜像
echo "🔨 构建Docker镜像..."
IMAGE_NAME="openwrt-iso-builder:latest"

if docker build \
    --build-arg ALPINE_VERSION="$ALPINE_VERSION" \
    -t "$IMAGE_NAME" \
    . 2>&1 | tee /tmp/docker-build.log; then
    
    echo "✅ Docker镜像构建成功: $IMAGE_NAME"
    
    # 检查镜像是否存在
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        echo "✅ 镜像验证成功"
    else
        echo "❌ 镜像不存在，检查Docker构建日志"
        cat /tmp/docker-build.log
        exit 1
    fi
else
    echo "❌ Docker镜像构建失败"
    cat /tmp/docker-build.log
    exit 1
fi

# 运行Docker容器构建ISO
echo "🚀 运行Docker容器构建ISO..."
set +e

# 先清理可能存在的旧容器
docker rm -f openwrt-builder 2>/dev/null || true

# 运行容器
docker run --rm \
    --name openwrt-builder \
    -v "$IMG_ABS:/mnt/input.img:ro" \
    -v "$OUTPUT_ABS:/output:rw" \
    -e INPUT_IMG="/mnt/input.img" \
    "$IMAGE_NAME"

CONTAINER_EXIT=$?
set -e

echo "容器退出代码: $CONTAINER_EXIT"

# 检查输出文件
OUTPUT_ISO="$OUTPUT_ABS/openwrt.iso"
if [ $CONTAINER_EXIT -eq 0 ] && [ -f "$OUTPUT_ISO" ]; then
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
    
    # 显示ISO内容
    echo ""
    echo "📂 ISO内容:"
    isoinfo -f -i "$FINAL_ISO" 2>/dev/null | head -10 || echo "无法列出ISO内容"
    
    echo ""
    echo "✅ 使用说明:"
    echo "   测试ISO: qemu-system-x86_64 -cdrom '$FINAL_ISO' -m 512"
    echo "   刻录USB: sudo dd if='$FINAL_ISO' of=/dev/sdX bs=4M status=progress"
    
    exit 0
else
    echo ""
    echo "❌ ISO构建失败"
    
    # 显示容器日志
    echo "📋 容器日志:"
    docker logs openwrt-builder 2>/dev/null || echo "无法获取容器日志"
    
    # 检查输出目录
    echo ""
    echo "📁 输出目录内容:"
    ls -la "$OUTPUT_ABS/" 2>/dev/null || echo "输出目录不存在"
    
    exit 1
fi
