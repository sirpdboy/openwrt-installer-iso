#!/bin/bash
# Docker构建包装脚本
# 用法: ./docker-build.sh <img_file> <output_dir> <iso_name> [alpine_version]

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# 显示帮助
show_help() {
    cat << EOF
使用方法: $0 <img_file> <output_dir> <iso_name> [alpine_version]

参数说明:
  img_file       : OpenWRT IMG文件路径
  output_dir     : 输出目录
  iso_name       : 输出的ISO文件名（如：openwrt-installer.iso）
  alpine_version : Alpine版本（默认：3.20）

示例:
  $0 ./openwrt.img ./output openwrt-installer.iso 3.20
  $0 ./openwrt.img ./output openwrt-installer.iso
EOF
    exit 1
}

# 检查参数
if [[ $# -lt 3 ]]; then
    show_help
fi

IMG_FILE="$1"
OUTPUT_DIR="$2"
ISO_NAME="$3"
ALPINE_VERSION="${4:-3.20}"

# 获取绝对路径
IMG_FILE_ABS=$(readlink -f "$IMG_FILE" 2>/dev/null || echo "$(cd "$(dirname "$IMG_FILE")" && pwd)/$(basename "$IMG_FILE")")
OUTPUT_DIR_ABS=$(readlink -f "$OUTPUT_DIR" 2>/dev/null || echo "$(cd "$(dirname "$OUTPUT_DIR")" && pwd)/$(basename "$OUTPUT_DIR")")

print_step "开始构建OpenWRT安装ISO..."
print_info "Alpine版本: ${ALPINE_VERSION}"
print_info "IMG文件: ${IMG_FILE_ABS}"
print_info "输出目录: ${OUTPUT_DIR_ABS}"
print_info "ISO文件名: ${ISO_NAME}"

# 检查文件是否存在
if [[ ! -f "${IMG_FILE_ABS}" ]]; then
    print_error "IMG文件不存在: ${IMG_FILE_ABS}"
    exit 1
fi

# 检查文件类型
if ! file "${IMG_FILE_ABS}" | grep -q "DOS/MBR boot sector\|Linux.*filesystem data"; then
    print_warn "警告：输入文件可能不是有效的IMG文件"
    print_info "文件类型: $(file "${IMG_FILE_ABS}")"
fi

# 创建输出目录
mkdir -p "${OUTPUT_DIR_ABS}"

# 检查Docker是否可用
if ! command -v docker &>/dev/null; then
    print_error "Docker未安装或不可用"
    exit 1
fi

# 检查Docker是否运行
if ! docker info &>/dev/null; then
    print_error "Docker守护进程未运行"
    exit 1
fi

# 验证Dockerfile存在
if [[ ! -f "Dockerfile" ]]; then
    print_error "Dockerfile不存在"
    exit 1
fi

# 构建Docker镜像
print_step "构建Docker镜像..."
print_info "使用Alpine版本: ${ALPINE_VERSION}"

if docker build \
    --build-arg ALPINE_VERSION="${ALPINE_VERSION}" \
    -t alpine-openwrt-builder:latest \
    .; then
    print_info "✅ Docker镜像构建成功"
else
    print_error "❌ Docker镜像构建失败"
    
    # 尝试使用备用Dockerfile
    print_info "尝试使用备用Dockerfile..."
    cat > Dockerfile.backup << 'EOF'
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION}

RUN apk update && apk add --no-cache \
    bash \
    curl \
    wget \
    xorriso \
    mtools \
    dosfstools \
    parted \
    e2fsprogs \
    util-linux \
    coreutils \
    gzip \
    tar \
    file \
    fdisk \
    jq \
    gawk \
    syslinux \
    grub \
    grub-efi \
    squashfs-tools

RUN mkdir -p /work /output
WORKDIR /work
EOF
    
    if docker build -f Dockerfile.backup \
        --build-arg ALPINE_VERSION="${ALPINE_VERSION}" \
        -t alpine-openwrt-builder:latest .; then
        print_info "✅ 使用备用Dockerfile构建成功"
        rm -f Dockerfile.backup
    else
        print_error "❌ 备用Dockerfile也构建失败"
        rm -f Dockerfile.backup
        exit 1
    fi
fi

# 检查脚本是否存在
if [[ ! -f "scripts/build-iso-alpine.sh" ]]; then
    print_error "主构建脚本不存在: scripts/build-iso-alpine.sh"
    exit 1
fi

# 设置执行权限
chmod +x scripts/build-iso-alpine.sh 2>/dev/null || true

# 运行Docker容器构建ISO
print_step "启动Docker容器构建ISO..."

# 创建输出ISO的完整路径
OUTPUT_ISO="${OUTPUT_DIR_ABS}/${ISO_NAME}"

# 运行构建
docker run --rm \
    -v "${IMG_FILE_ABS}:/mnt/input.img:ro" \
    -v "${OUTPUT_DIR_ABS}:/output:rw" \
    -v "$(pwd)/scripts:/scripts:ro" \
    -v "$(pwd)/scripts/include:/usr/local/include:ro" \
    -e ALPINE_VERSION="${ALPINE_VERSION}" \
    -e INPUT_IMG="/mnt/input.img" \
    -e OUTPUT_ISO_FILENAME="${ISO_NAME}" \
    -e ISO_LABEL="OPENWRT_INSTALL" \
    -e ISO_VOLUME="OpenWRT_Installer" \
    alpine-openwrt-builder:latest \
    /bin/bash -c "
        # 确保脚本可执行
        chmod +x /scripts/build-iso-alpine.sh 2>/dev/null || true
        # 执行构建
        /scripts/build-iso-alpine.sh
    "

# 检查是否构建成功
if [[ -f "${OUTPUT_ISO}" ]]; then
    ISO_SIZE=$(du -h "${OUTPUT_ISO}" | cut -f1)
    print_info "✅ ISO构建成功!"
    print_info "文件: ${OUTPUT_ISO}"
    print_info "大小: ${ISO_SIZE}"
    
    # 显示ISO信息
    echo ""
    print_info "ISO文件详细信息:"
    ls -lh "${OUTPUT_ISO}"
    
    if command -v isoinfo >/dev/null 2>&1; then
        print_info "ISO引导信息:"
        isoinfo -d -i "${OUTPUT_ISO}" 2>/dev/null | grep -E "Volume id|Volume size|Bootable" || true
    fi
    
    # 验证文件类型
    print_info "文件类型:"
    file "${OUTPUT_ISO}" || true
else
    print_error "❌ ISO文件未生成: ${OUTPUT_ISO}"
    print_info "输出目录内容:"
    ls -la "${OUTPUT_DIR_ABS}/" 2>/dev/null || true
    exit 1
fi

print_info "🎉 构建完成！"
