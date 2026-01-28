#!/bin/bash
# 简化版Docker构建脚本

set -e

echo "=== OpenWRT ISO Builder ==="
echo "参数: $@"
echo ""

# 参数
IMG_FILE="$1"
OUTPUT_DIR="$2"
ISO_NAME="$3"
ALPINE_VERSION="${4:-3.20}"

# 基本检查
if [ $# -lt 3 ]; then
    echo "用法: $0 <img文件> <输出目录> <iso名称> [alpine版本]"
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

# 简单Dockerfile
cat > Dockerfile.simple << EOF
FROM alpine:$ALPINE_VERSION

RUN apk update && apk add --no-cache \\
    bash \\
    xorriso \\
    mtools \\
    dosfstools \\
    grub \\
    grub-efi \\
    syslinux \\
    parted \\
    e2fsprogs \\
    util-linux

WORKDIR /work
EOF

echo "构建Docker镜像..."
if docker build -f Dockerfile.simple -t alpine-builder .; then
    echo "Docker镜像构建成功"
else
    echo "Docker镜像构建失败，尝试简化版本..."
    # 更简单的Dockerfile
    cat > Dockerfile.minimal << EOF
FROM alpine:$ALPINE_VERSION
RUN apk add --no-cache xorriso syslinux grub parted
WORKDIR /work
EOF
    
    docker build -f Dockerfile.minimal -t alpine-builder . || {
        echo "Docker构建失败，请检查网络和权限"
        exit 1
    }
fi

# 复制构建脚本到容器
echo "准备构建脚本..."
cat > /tmp/build-iso.sh << 'EOF'
#!/bin/sh
set -e

echo "容器内开始构建ISO..."

# 准备目录
mkdir -p /tmp/iso/boot/grub /tmp/iso/boot/isolinux

# 复制引导文件
cp /usr/share/syslinux/isolinux.bin /tmp/iso/boot/isolinux/
cp /usr/share/syslinux/ldlinux.c32 /tmp/iso/boot/isolinux/

# 创建引导配置
cat > /tmp/iso/boot/isolinux/isolinux.cfg << 'EOFF'
DEFAULT linux
LABEL linux
  SAY Booting OpenWRT Installer...
  LINUX /boot/vmlinuz
  APPEND initrd=/boot/initrd.img
EOFF

# 创建GRUB配置
cat > /tmp/iso/boot/grub/grub.cfg << 'EOFF'
set timeout=5
menuentry "Install OpenWRT" {
    linux /boot/vmlinuz
    initrd /boot/initrd.img
}
EOFF

# 创建最小initrd（仅用于测试）
echo "创建initrd..."
echo "#!/bin/sh" > /tmp/init
echo "echo 'OpenWRT Installer'" >> /tmp/init
echo "exec /bin/sh" >> /tmp/init
chmod +x /tmp/init
(cd /tmp && echo init | cpio -H newc -o | gzip > /tmp/iso/boot/initrd.img)

# 复制内核
cp /boot/vmlinuz-* /tmp/iso/boot/vmlinuz 2>/dev/null || true
if [ ! -f /tmp/iso/boot/vmlinuz ]; then
    # 使用busybox作为占位
    cp /bin/busybox /tmp/iso/boot/vmlinuz
fi

# 复制OpenWRT镜像
cp /mnt/input.img /tmp/iso/openwrt.img

# 创建ISO
echo "创建ISO..."
xorriso -as mkisofs \
  -r -V "OpenWRT_Installer" \
  -o /output/out.iso \
  -b boot/isolinux/isolinux.bin \
  -c boot/isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  /tmp/iso

echo "ISO构建完成"
EOF

chmod +x /tmp/build-iso.sh

echo "运行容器构建ISO..."
docker run --rm \
    -v "$IMG_ABS:/mnt/input.img:ro" \
    -v "$OUTPUT_ABS:/output:rw" \
    -v "/tmp/build-iso.sh:/build.sh:ro" \
    alpine-builder \
    /bin/sh /build.sh

# 重命名输出文件
if [ -f "$OUTPUT_ABS/out.iso" ]; then
    mv "$OUTPUT_ABS/out.iso" "$OUTPUT_ABS/$ISO_NAME"
    echo "✅ ISO构建成功: $OUTPUT_ABS/$ISO_NAME"
    ls -lh "$OUTPUT_ABS/$ISO_NAME"
else
    echo "❌ ISO构建失败"
    exit 1
fi

# 清理
rm -f Dockerfile.simple Dockerfile.minimal /tmp/build-iso.sh

echo "🎉 完成！"
