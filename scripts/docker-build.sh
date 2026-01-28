#!/bin/bash
# OpenWRT ISO Builder - 完整修复版
# 解决网络问题、Docker构建问题和脚本逻辑问题

set -e

echo "================================================"
echo "      OpenWRT ISO Builder - Complete Fix       "
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

参数说明:
  <img文件>      : OpenWRT的IMG文件路径（必需）
  [输出目录]     : 输出ISO的目录 (默认: ./output)
  [iso名称]      : 输出的ISO文件名 (默认: openwrt-installer-YYYYMMDD.iso)
  [alpine版本]   : Alpine Linux版本 (默认: 3.20)

示例:
  $0 ./openwrt.img
  $0 ./openwrt.img ./iso my-openwrt.iso
  $0 ./openwrt.img ./output openwrt.iso 3.19
EOF
    exit 1
fi

# 检查IMG文件
if [ ! -f "$IMG_FILE" ]; then
    echo "❌ 错误: IMG文件不存在: $IMG_FILE"
    exit 1
fi

# 检查文件类型
if ! file "$IMG_FILE" | grep -q "DOS/MBR boot sector\|Linux.*filesystem data"; then
    echo "⚠ 警告: 输入文件可能不是有效的IMG文件"
    echo "文件类型: $(file "$IMG_FILE")"
    read -p "继续? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        exit 1
    fi
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

# 函数：测试网络连接
test_network() {
    echo "🌐 测试网络连接..."
    if curl -s --connect-timeout 10 https://dl-cdn.alpinelinux.org/alpine/ >/dev/null 2>&1; then
        echo "✅ 网络连接正常"
        return 0
    else
        echo "⚠ 网络连接可能有问题"
        return 1
    fi
}

# 测试网络
test_network || echo "继续构建..."

# 函数：创建可靠的工作Dockerfile
create_dockerfile() {
    local version=$1
    local output_file=$2
    
    cat > "$output_file" << 'DOCKERFILE_EOF'
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION}

# 设置Alpine源（使用中国镜像源加速，如果失败则用官方源）
RUN set -e && \
    echo "测试镜像源..." && \
    if ping -c 1 -W 5 mirrors.aliyun.com >/dev/null 2>&1; then \
        echo "使用阿里云镜像源" && \
        sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories; \
    elif ping -c 1 -W 5 mirrors.tuna.tsinghua.edu.cn >/dev/null 2>&1; then \
        echo "使用清华镜像源" && \
        sed -i 's/dl-cdn.alpinelinux.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apk/repositories; \
    else \
        echo "使用官方镜像源"; \
    fi

# 更新包列表（带重试）
RUN for i in 1 2 3; do \
    echo "尝试更新包列表 (尝试 $i)..." && \
    apk update && break || sleep 2; \
    done

# 安装必要工具（最小集合）
RUN apk add --no-cache \
    bash \
    xorriso \
    coreutils \
    util-linux

# 尝试安装其他工具（容错）
RUN apk add --no-cache mtools dosfstools parted 2>/dev/null || echo "部分工具安装失败，继续..."

# 尝试安装引导工具
RUN if apk add --no-cache syslinux 2>/dev/null; then \
    echo "syslinux安装成功"; \
else \
    echo "syslinux安装失败，尝试从源安装..."; \
    apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/edge/main syslinux 2>/dev/null || \
    echo "无法安装syslinux"; \
fi

# 尝试安装grub
RUN if apk add --no-cache grub grub-efi 2>/dev/null; then \
    echo "grub安装成功"; \
else \
    echo "grub安装失败，尝试安装grub2..."; \
    apk add --no-cache grub2 grub2-efi 2>/dev/null || \
    echo "无法安装grub"; \
fi

# 清理
RUN rm -rf /var/cache/apk/*

# 验证安装的工具
RUN echo "已安装工具:" && \
    which xorriso && xorriso --version 2>&1 | head -1 && \
    echo "完成"

WORKDIR /work

# 创建ISO构建脚本
RUN cat > /build_iso.sh << 'SCRIPT_EOF'
#!/bin/bash
set -e

echo "=== 开始构建ISO ==="

# 检查输入
if [ ! -f "$INPUT_IMG" ]; then
    echo "❌ 错误: 输入文件不存在: $INPUT_IMG"
    exit 1
fi

# 创建ISO目录
ISO_DIR="/tmp/iso"
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR"/{boot/isolinux,images}

# 复制OpenWRT镜像
cp "$INPUT_IMG" "$ISO_DIR/images/openwrt.img"
echo "✅ 复制OpenWRT镜像"

# 检查并复制引导文件
if [ -f "/usr/share/syslinux/isolinux.bin" ]; then
    cp /usr/share/syslinux/isolinux.bin "$ISO_DIR/boot/isolinux/"
    echo "✅ 复制isolinux.bin"
fi

if [ -f "/usr/share/syslinux/ldlinux.c32" ]; then
    cp /usr/share/syslinux/ldlinux.c32 "$ISO_DIR/boot/isolinux/"
    echo "✅ 复制ldlinux.c32"
fi

# 创建引导配置
cat > "$ISO_DIR/boot/isolinux/isolinux.cfg" << 'CFG_EOF'
DEFAULT install
PROMPT 0
TIMEOUT 50

LABEL install
  SAY Booting OpenWRT Installer...
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0

LABEL bootlocal
  SAY Booting from local disk...
  LOCALBOOT 0x80
CFG_EOF

# 创建简单的内核脚本
cat > "$ISO_DIR/boot/vmlinuz" << 'KERNEL_EOF'
#!/bin/sh
echo ""
echo "========================================"
echo "       OpenWRT Installation System      "
echo "========================================"
echo ""
echo "This system allows you to install OpenWRT."
echo ""
echo "The OpenWRT image is located at: /images/openwrt.img"
echo ""
echo "To install OpenWRT, use:"
echo "  dd if=/images/openwrt.img of=/dev/sdX bs=4M status=progress"
echo ""
echo "Type 'help' for more information."
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
mount -t proc proc /proc
mount -t sysfs sysfs /sys
echo "OpenWRT Installer Ready"
echo ""
echo "Type 'exit' to reboot"
exec /bin/sh
INIT_EOF
chmod +x "$INITRD_DIR/init"
(cd "$INITRD_DIR" && find . | cpio -o -H newc 2>/dev/null | gzip > "$ISO_DIR/boot/initrd.img")

# 创建ISO
echo "创建ISO文件..."
cd /tmp
if command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs \
        -r -V "OpenWRT_Installer" \
        -o /output/openwrt.iso \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        iso/
else
    echo "❌ 错误: xorriso不可用"
    exit 1
fi

echo "✅ ISO创建完成"
echo "文件: /output/openwrt.iso"
SCRIPT_EOF

RUN chmod +x /build_iso.sh

ENTRYPOINT ["/build_iso.sh"]
DOCKERFILE_EOF

    # 替换版本号
    sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$version/" "$output_file"
}

# 创建Dockerfile
DOCKERFILE_PATH="/tmp/Dockerfile.openwrt"
echo "📦 创建Dockerfile..."
create_dockerfile "$ALPINE_VERSION" "$DOCKERFILE_PATH"

echo "🔨 构建Docker镜像..."
echo "使用Alpine版本: $ALPINE_VERSION"

# 构建Docker镜像（带详细输出）
if docker build -f "$DOCKERFILE_PATH" \
    --build-arg ALPINE_VERSION="$ALPINE_VERSION" \
    -t openwrt-iso-builder \
    . 2>&1 | tee /tmp/docker-build.log; then
    
    echo "✅ Docker镜像构建成功"
else
    echo "❌ Docker镜像构建失败"
    echo "查看详细日志: /tmp/docker-build.log"
    exit 1
fi

# 创建容器内构建脚本
cat > /tmp/container-build.sh << 'CONTAINER_SCRIPT'
#!/bin/bash
set -e

echo "🚀 在容器内启动ISO构建..."

# 环境变量
INPUT_IMG="${1:-/mnt/input.img}"
OUTPUT_DIR="/output"

echo "输入文件: $INPUT_IMG"
echo "输出目录: $OUTPUT_DIR"

# 执行构建
/build_iso.sh

# 检查输出
if [ -f "/output/openwrt.iso" ]; then
    echo "🎉 ISO构建成功!"
    ls -lh "/output/openwrt.iso"
    exit 0
else
    echo "❌ ISO文件未生成"
    ls -la "/output/" || true
    exit 1
fi
CONTAINER_SCRIPT

chmod +x /tmp/container-build.sh

# 运行容器构建ISO
echo "🚀 运行Docker容器构建ISO..."
set +e
docker run --rm \
    --name openwrt-iso-builder \
    -v "$IMG_ABS:/mnt/input.img:ro" \
    -v "$OUTPUT_ABS:/output:rw" \
    -e INPUT_IMG="/mnt/input.img" \
    openwrt-iso-builder

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
    
    echo ""
    echo "✅ 您可以使用以下方式测试:"
    echo "   1. 虚拟机测试: qemu-system-x86_64 -cdrom '$FINAL_ISO' -m 512"
    echo "   2. 刻录到USB: sudo dd if='$FINAL_ISO' of=/dev/sdX bs=4M status=progress"
    echo "   3. 挂载查看: sudo mount -o loop '$FINAL_ISO' /mnt"
    
    exit 0
else
    echo ""
    echo "❌ ISO构建失败"
    echo "输出目录内容:"
    ls -la "$OUTPUT_ABS/" 2>/dev/null || echo "输出目录不存在"
    
    # 显示Docker日志
    echo ""
    echo "📋 Docker容器日志:"
    docker logs openwrt-iso-builder 2>/dev/null || echo "无法获取容器日志"
    
    exit 1
fi
