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
    echo "使用方法: $0 <img_file> <output_dir> <iso_name> [alpine_version]"
    echo ""
    echo "参数说明:"
    echo "  img_file       : OpenWRT IMG文件路径"
    echo "  output_dir     : 输出目录"
    echo "  iso_name       : 输出的ISO文件名（如：openwrt-installer.iso）"
    echo "  alpine_version : Alpine版本（默认：3.20）"
    echo ""
    echo "示例:"
    echo "  $0 ./openwrt.img ./output openwrt-installer.iso 3.20"
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
IMG_FILE_ABS=$(readlink -f "$IMG_FILE")
OUTPUT_DIR_ABS=$(readlink -f "$OUTPUT_DIR")

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

# 创建输出目录
mkdir -p "${OUTPUT_DIR_ABS}"

# 检查Docker是否可用
if ! command -v docker &>/dev/null; then
    print_error "Docker未安装或不可用"
    exit 1
fi

# 构建Docker镜像
print_step "构建Docker镜像..."
docker build \
    --build-arg ALPINE_VERSION="${ALPINE_VERSION}" \
    -t alpine-openwrt-builder:latest \
    .

if [[ $? -ne 0 ]]; then
    print_error "Docker镜像构建失败"
    exit 1
fi

print_info "Docker镜像构建成功"

# 运行Docker容器构建ISO
print_step "启动Docker容器构建ISO..."
docker run --rm \
    -v "${IMG_FILE_ABS}:/mnt/input.img:ro" \
    -v "${OUTPUT_DIR_ABS}:/output:rw" \
    -e ALPINE_VERSION="${ALPINE_VERSION}" \
    -e INPUT_IMG="/mnt/input.img" \
    -e OUTPUT_ISO_FILENAME="${ISO_NAME}" \
    -e ISO_LABEL="OPENWRT_INSTALL" \
    -e ISO_VOLUME="OpenWRT_Installer_v${ALPINE_VERSION}" \
    alpine-openwrt-builder:latest

# 检查是否构建成功
OUTPUT_ISO="${OUTPUT_DIR_ABS}/${ISO_NAME}"
if [[ -f "${OUTPUT_ISO}" ]]; then
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
    
    # 验证文件类型
    print_info "文件类型:"
    file "${OUTPUT_ISO}" || true
else
    print_error "ISO文件未生成: ${OUTPUT_ISO}"
    ls -la "${OUTPUT_DIR_ABS}/" || true
    exit 1
fi

print_info "构建完成！"
