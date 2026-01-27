#!/bin/bash
# Docker构建包装脚本
# 参数: 1.Alpine版本号 2.IMG文件路径 3.输出ISO路径

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 显示帮助
show_help() {
    echo "使用方法: $0 <alpine_version> <img_file> <output_iso>"
    echo "示例: $0 3.18.6 ./openwrt.img ./output/installer.iso"
    echo ""
    echo "参数说明:"
    echo "  alpine_version : Alpine Linux版本号 (如: 3.18.6, 3.19.1)"
    echo "  img_file       : 要打包的IMG文件路径"
    echo "  output_iso     : 输出的ISO文件路径"
    exit 1
}

# 检查参数
if [ $# -ne 3 ]; then
    show_help
fi

ALPINE_VERSION="$1"
IMG_FILE="$2"
OUTPUT_ISO="$3"

# 检查IMG文件是否存在
if [ ! -f "$IMG_FILE" ]; then
    print_error "IMG文件不存在: $IMG_FILE"
    exit 1
fi

# 获取绝对路径
IMG_FILE_ABS=$(readlink -f "$IMG_FILE")
OUTPUT_DIR=$(dirname "$(readlink -f "$OUTPUT_ISO")")
OUTPUT_FILENAME=$(basename "$OUTPUT_ISO")

print_info "开始构建OpenWRT安装ISO..."
print_info "Alpine版本: ${ALPINE_VERSION}"
print_info "IMG文件: ${IMG_FILE_ABS}"
print_info "输出ISO: ${OUTPUT_ISO}"

# 创建输出目录
mkdir -p "${OUTPUT_DIR}"

# 构建Docker镜像
print_info "构建Docker镜像..."
docker build -t alpine-installer-builder:latest -f - . << EOF
FROM alpine:${ALPINE_VERSION}

# 安装构建工具
RUN apk add --no-cache \
    bash \
    curl \
    wget \
    xorriso \
    mtools \
    dosfstools \
    grub-efi \
    grub-bios \
    syslinux \
    syslinux-bios \
    squashfs-tools \
    parted \
    e2fsprogs \
    util-linux \
    coreutils \
    findutils \
    grep \
    sed \
    gzip \
    tar

# 创建工作目录
RUN mkdir -p /work /output

# 复制构建脚本
COPY scripts/build-installer-iso.sh /usr/local/bin/
COPY scripts/include/ /usr/local/include/

# 设置执行权限
RUN chmod +x /usr/local/bin/build-installer-iso.sh
RUN chmod +x /usr/local/include/*

# 设置工作目录
WORKDIR /work

# 入口点
ENTRYPOINT ["/usr/local/bin/build-installer-iso.sh"]
EOF

if [ $? -ne 0 ]; then
    print_error "Docker镜像构建失败"
    exit 1
fi

print_info "Docker镜像构建成功"

# 运行Docker容器构建ISO
print_info "启动Docker容器构建ISO..."
docker run --rm \
    -v "${IMG_FILE_ABS}:/mnt/input.img:ro" \
    -v "${OUTPUT_DIR}:/output" \
    -e ALPINE_VERSION="${ALPINE_VERSION}" \
    -e INPUT_IMG="/mnt/input.img" \
    -e OUTPUT_ISO_FILENAME="${OUTPUT_FILENAME}" \
    alpine-installer-builder:latest

# 检查是否构建成功
if [ -f "${OUTPUT_ISO}" ]; then
    ISO_SIZE=$(du -h "${OUTPUT_ISO}" | cut -f1)
    print_info "✓ ISO构建成功!"
    print_info "文件: ${OUTPUT_ISO}"
    print_info "大小: ${ISO_SIZE}"
    
    # 显示ISO信息
    echo ""
    print_info "ISO引导信息:"
    if command -v isoinfo >/dev/null 2>&1; then
        isoinfo -d -i "${OUTPUT_ISO}" 2>/dev/null | grep -E "Volume id|Bootable" || true
    fi
else
    print_error "ISO文件未生成: ${OUTPUT_ISO}"
    exit 1
fi

print_info "构建完成！"
