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

        sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        sudo apt-get autoremove -y
        
        # 安装必要依赖
        sudo apt-get update
        sudo apt-get install -y \
            ca-certificates \
            curl \
            gnupg \
            lsb-release
        
        # 添加Docker官方GPG密钥
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        
        # 设置仓库
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # 安装Docker
        sudo apt-get update
        sudo apt-get install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-compose-plugin
        
        # 启动服务
        sudo systemctl start docker
        sudo systemctl enable docker
        
        # 验证
        docker --version
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


# 检查输入文件（如果在宿主机上）
if [[ "$INPUT_IMG" == /* ]] && [ ! -f "$INPUT_IMG" ]; then
    log_error "Input file not found: $INPUT_IMG"
    exit 1
fi

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 构建Docker镜像
log_info "Building Docker image..."
if ! docker build -t openwrt-iso-builder:latest .; then
    log_error "Docker image build failed"
    exit 1
fi
log_success "Docker image built successfully"

log_info "Starting Docker container for ISO build..."
chmod +x build-iso.sh
docker run --privileged --rm \
    -v "$INPUT_IMG:/mnt/ezopwrt.img:ro" \
    -v "$OUTPUT_DIR:/output" \
    -e "INPUT_IMG=$INPUT_IMG" \
    -e "OUTPUT_DIR=$OUTPUT_DIR" \
    -e "ISO_NAME=$ISO_NAME" \
    debian:buster \
    bash -c "
    # 安装必要工具
    apt-get update
    apt-get install -y \
    debootstrap squashfs-tools xorriso isolinux syslinux-efi \
    grub-pc-bin grub-efi-amd64-bin mtools dosfstools parted wget curl
       
    /build-iso.sh
              "

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
    
    # 显示ISO基本信息
    log_info "ISO Information:"
    if command -v file &> /dev/null; then
        file "$ISO_PATH"
    fi
    
    # 创建构建报告
    cat > "$OUTPUT_DIR/build-report.md" << EOF
# OpenWRT Installer ISO Build Report

## Build Information
- **Build Date:** $(date)
- **Build Script:** dockerrun.sh
- **Docker Image:** openwrt-iso-builder:latest

## Input/Output
- **Input Image:** $INPUT_IMG
- **Output ISO:** $ISO_PATH
- **ISO Size:** $ISO_SIZE

## Usage Instructions
1. Flash to USB: \`dd if="$ISO_NAME" of=/dev/sdX bs=4M status=progress\`
2. Boot from USB
3. Follow on-screen instructions to install OpenWRT

## Notes
- This ISO supports both BIOS and UEFI boot
- Installation will erase all data on target disk
- Default boot timeout: 5 seconds

## Build Command
\`\`\`bash
./dockerrun.sh "$INPUT_IMG" "$OUTPUT_DIR" "$ISO_NAME"
\`\`\`
EOF
    
    log_success "Build report saved to: $OUTPUT_DIR/build-report.md"
    
    # 显示ISO内容摘要
    echo ""
    log_info "ISO Contents (top level):"
    if command -v xorriso &> /dev/null; then
        xorriso -indev "$ISO_PATH" -find / -maxdepth 1 2>/dev/null | head -20 || true
    fi
else
    log_error "❌ ISO build failed or file not found"
    log_error "Expected ISO at: $ISO_PATH"
    exit 1
fi

log_success "🎉 All tasks completed successfully!"
