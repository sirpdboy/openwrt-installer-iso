#!/bin/bash
# Docker构建脚本

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 打印带颜色的消息
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查参数
if [ $# -lt 2 ]; then
    print_error "使用方法: $0 <alpine_version> <iso_name>"
    print_error "示例: $0 latest alpine-dualboot"
    exit 1
fi

ALPINE_VERSION="$1"
ISO_NAME="$2"

print_info "开始构建Alpine双引导ISO..."
print_info "Alpine版本: ${ALPINE_VERSION}"
print_info "ISO名称: ${ISO_NAME}"

# 创建输出目录
mkdir -p output

# 检查是否在GitHub Actions环境中
if [ -n "$GITHUB_ACTIONS" ]; then
    print_info "检测到GitHub Actions环境"
fi

# 清理旧的Docker镜像（可选）
print_info "清理旧Docker镜像..."
docker rmi alpine-iso-builder:latest 2>/dev/null || true

# 构建Docker镜像
print_info "构建Docker镜像..."
docker build \
    --build-arg ALPINE_VERSION=${ALPINE_VERSION} \
    --build-arg ISO_NAME=${ISO_NAME} \
    -t alpine-iso-builder:latest \
    -f - . << 'EOF'
FROM alpine:latest AS builder

# 构建参数
ARG ALPINE_VERSION=latest
ARG ISO_NAME=alpine-dualboot

# 环境变量
ENV ALPINE_VERSION=${ALPINE_VERSION}
ENV ISO_NAME=${ISO_NAME}
ENV OUTPUT_DIR=/output
ENV WORK_DIR=/work

# 安装必要的软件包
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
    mkinitfs \
    alpine-conf \
    alpine-make-rootfs \
    squashfs-tools

# 创建工作目录
RUN mkdir -p ${WORK_DIR} ${OUTPUT_DIR}

# 复制构建脚本
COPY scripts/build-iso-alpine.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/build-iso-alpine.sh

# 设置工作目录
WORKDIR ${WORK_DIR}

# 设置入口点
ENTRYPOINT ["/usr/local/bin/build-iso-alpine.sh"]
EOF

# 检查Docker镜像是否构建成功
if [ $? -ne 0 ]; then
    print_error "Docker镜像构建失败"
    exit 1
fi

print_info "Docker镜像构建成功"

# 运行Docker容器构建ISO
print_info "启动Docker容器构建ISO..."
docker run --rm \
    -v $(pwd)/output:/output \
    -e ALPINE_VERSION=${ALPINE_VERSION} \
    -e ISO_NAME=${ISO_NAME} \
    alpine-iso-builder:latest

# 检查ISO是否生成
if [ -f "output/${ISO_NAME}.iso" ]; then
    print_info "✓ ISO构建成功: output/${ISO_NAME}.iso"
    ls -lh "output/${ISO_NAME}.iso"
else
    print_error "ISO文件未生成"
    exit 1
fi

print_info "构建完成！"
