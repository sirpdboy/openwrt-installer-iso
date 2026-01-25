#!/bin/bash
# dockerrun.sh - Docker构建运行器
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 显示帮助
show_help() {
    cat << EOF
OpenWRT IMG to ISO Converter

Usage: $0 [INPUT_IMG] [OUTPUT_DIR] [ISO_NAME]

Arguments:
  INPUT_IMG      Path to OpenWRT IMG file (default: /mnt/openwrt.img)
  OUTPUT_DIR     Output directory for ISO (default: /output)
  ISO_NAME       Name of output ISO file (default: openwrt-autoinstall.iso)

Examples:
  $0 ./openwrt.img ./output my-openwrt.iso
  $0                           # 使用默认值
EOF
}

# 参数处理
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

INPUT_IMG="${1:-/mnt/openwrt.img}"
OUTPUT_DIR="${2:-/output}"
ISO_NAME="${3:-openwrt-autoinstall.iso}"

# 显示构建信息
log_info "========================================"
log_info "OpenWRT ISO Builder - Docker Runner"
log_info "========================================"
log_info "Input IMG:    $INPUT_IMG"
log_info "Output Dir:   $OUTPUT_DIR"
log_info "ISO Name:     $ISO_NAME"
log_info "========================================"
echo ""

# 检查Docker是否可用
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed or not in PATH"
        log_info "Trying to install Docker..."
        
        # 简化安装 - 不使用交互式GPG
        sudo apt-get update
        sudo apt-get install -y \
            apt-transport-https \
            ca-certificates \
            curl \
            software-properties-common
        
        # 添加Docker仓库（不使用交互式GPG）
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            sudo gpg --batch --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
            https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
            sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # 安装Docker
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
        
        # 启动服务
        sudo systemctl start docker
        sudo systemctl enable docker
        
        # 验证安装
        if docker --version; then
            log_success "Docker installed successfully"
        else
            log_error "Docker installation failed"
            exit 1
        fi
    fi
    
    # 检查Docker服务状态
    if ! sudo docker info > /dev/null 2>&1; then
        log_error "Docker daemon is not running"
        log_info "Starting Docker daemon..."
        sudo systemctl start docker
        sleep 3
        
        if ! sudo docker info > /dev/null 2>&1; then
            log_error "Failed to start Docker daemon"
            exit 1
        fi
    fi
    
    log_success "Docker is ready"
}

# 检查Docker
check_docker

# 检查输入文件（如果在宿主机上）
if [[ "$INPUT_IMG" == /* ]] && [ ! -f "$INPUT_IMG" ]; then
    log_error "Input file not found: $INPUT_IMG"
    exit 1
fi

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 构建ISO
log_info "Starting ISO build..."
chmod +x build.sh
# 方法1：使用预安装所有依赖的Docker镜像（推荐）
if docker images | grep -q "openwrt-iso-builder"; then
    log_info "Using existing Docker image: openwrt-iso-builder"
    docker run --privileged --rm \
        -v "$INPUT_IMG:/mnt/ezopwrt.img:ro" \
        -v "$OUTPUT_DIR:/output" \
        -v "$(pwd)/build.sh:/build.sh:ro" \
        openwrt-iso-builder

elif docker images | grep -q "debian:buster"; then
    log_info "Using existing Docker image: debian:buster"
    docker run --privileged --rm \
        -v "$INPUT_IMG:/mnt/ezopwrt.img:ro" \
        -v "$OUTPUT_DIR:/output" \
        -v "$(pwd)/build.sh:/build.sh:ro" \
        -e "INPUT_IMG=/mnt/ezopwrt.img" \
        -e "OUTPUT_DIR=/output" \
        -e "ISO_NAME=$ISO_NAME" \
        debian:buster \
              bash -c "
              apt-get update
              apt-get install -y \
                debootstrap squashfs-tools xorriso isolinux syslinux-efi \
                grub-pc-bin grub-efi-amd64-bin mtools dosfstools parted wget curl
       
              /build.sh
              "
else
    # 方法2：动态构建镜像
    log_info "Creating Docker image with all dependencies..."
    
    # 创建临时Dockerfile
    cat > /tmp/Dockerfile.openwrt << 'DOCKERFILE'
FROM debian:buster-slim

# 设置环境变量
ENV DEBIAN_FRONTEND=noninteractive

# 配置源
RUN echo "deb http://archive.debian.org/debian buster main" > /etc/apt/sources.list && \
    echo "deb http://archive.debian.org/debian-security buster/updates main" >> /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# 安装所有必要工具
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        debootstrap \
        squashfs-tools \
        xorriso \
        isolinux \
        syslinux \
        syslinux-common \
        grub-pc-bin \
        grub-efi-amd64-bin \
        mtools \
        dosfstools \
        parted \
        wget \
        curl \
        pv \
        file \
        live-boot \
        live-boot-initramfs-tools \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 创建工作目录
RUN mkdir -p /mnt /output
WORKDIR /build

# 设置默认命令
CMD ["/bin/bash"]
DOCKERFILE

    # 构建镜像
    docker build -t openwrt-iso-builder -f /tmp/Dockerfile.openwrt .
    
    # 运行构建
    log_info "Running build in Docker container..."
    docker run --privileged --rm \
        -v "$INPUT_IMG:/mnt/ezopwrt.img:ro" \
        -v "$OUTPUT_DIR:/output" \
        -v "$(pwd)/build.sh:/build.sh:ro" \
        -e "INPUT_IMG=/mnt/ezopwrt.img" \
        -e "OUTPUT_DIR=/output" \
        -e "ISO_NAME=$ISO_NAME" \
        openwrt-iso-builder \
        bash -c "/build.sh"
fi

# 检查构建结果
BUILD_RESULT=$?
ISO_PATH="$OUTPUT_DIR/$ISO_NAME"

if [ $BUILD_RESULT -eq 0 ] && [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    log_success "✅ ISO build completed successfully!"
    echo ""
    log_info "Build Summary:"
    log_info "  Input File:   $(basename "$INPUT_IMG")"
    log_info "  Output ISO:   $ISO_NAME"
    log_info "  File Size:    $ISO_SIZE"
    log_info "  Location:     $ISO_PATH"
    echo ""
else
    log_error "✅ ISO build completed error!"
fi
