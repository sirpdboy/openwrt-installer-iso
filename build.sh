#!/bin/bash
# build.sh - 本地构建入口

set -euo pipefail

# 配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
ASSETS_DIR="${SCRIPT_DIR}/assets"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
DOCKER_IMAGE="debian:bullseye-slim"

# 颜色输出
red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

log_info() { echo "[INFO] $*"; }
log_success() { green "[SUCCESS] $*"; }
log_error() { red "[ERROR] $*"; }

# 检查Docker
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker未安装"
        echo "请安装Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker服务未运行"
        echo "请启动Docker服务"
        exit 1
    fi
    
    log_success "Docker检查通过"
}

# 下载OpenWRT镜像
download_image() {
    log_info "下载OpenWRT镜像..."
    
    mkdir -p "$ASSETS_DIR"
    
    if [ ! -f "${ASSETS_DIR}/ezopwrt.img" ]; then
        if [ -f "${SCRIPTS_DIR}/download-image.sh" ]; then
            "${SCRIPTS_DIR}/download-image.sh"
        else
            log_error "找不到下载脚本"
            echo "请手动将OpenWRT镜像放入: $ASSETS_DIR/ezopwrt.img"
            exit 1
        fi
    fi
    
    if [ ! -f "${ASSETS_DIR}/ezopwrt.img" ]; then
        log_error "找不到OpenWRT镜像"
        exit 1
    fi
    
    log_success "镜像准备完成: $(ls -lh "${ASSETS_DIR}/ezopwrt.img")"
}

# 准备输出目录
prepare_output() {
    log_info "准备输出目录..."
    
    mkdir -p "$OUTPUT_DIR"
    chmod 777 "$OUTPUT_DIR" 2>/dev/null || true
    
    log_success "输出目录: $OUTPUT_DIR"
}

# 运行Docker构建
run_docker_build() {
    log_info "启动Docker构建..."
    
    # 安装必要软件包并运行构建脚本
    docker run --privileged --rm \
        -v "${OUTPUT_DIR}:/output" \
        -v "${SCRIPTS_DIR}:/scripts:ro" \
        -v "${ASSETS_DIR}/ezopwrt.img:/mnt/ezopwrt.img:ro" \
        "$DOCKER_IMAGE" \
        /bin/bash -c "
        # 安装构建工具
        apt-get update && apt-get install -y \
            xorriso isolinux syslinux-efi \
            grub-pc-bin grub-efi-amd64-bin \
            mtools dosfstools squashfs-tools \
            wget curl cpio gzip \
            build-essential kmod file \
            && apt-get clean
        
        # 运行构建脚本
        /scripts/build-iso.sh
        "
}

# 显示结果
show_result() {
    echo ""
    echo "========================================"
    echo "    构建完成"
    echo "========================================"
    echo ""
    
    if ls "${OUTPUT_DIR}"/*.iso 1> /dev/null 2>&1; then
        local iso_file=$(ls -t "${OUTPUT_DIR}"/*.iso | head -1)
        log_success "ISO文件: $iso_file"
        echo ""
        echo "文件信息:"
        echo "  - 大小: $(ls -lh "$iso_file" | awk '{print $5}')"
        echo "  - 修改时间: $(stat -c '%y' "$iso_file" | cut -d'.' -f1)"
        echo ""
        echo "使用命令写入USB:"
        echo "  sudo dd if=\"$iso_file\" of=/dev/sdX bs=4M status=progress"
        echo "  sync"
        echo ""
        echo "注意: 将 /dev/sdX 替换为你的USB设备"
    else
        log_error "未找到生成的ISO文件"
        exit 1
    fi
}

# 主函数
main() {
    echo "========================================"
    echo "    EzOpWrt ISO 本地构建工具"
    echo "========================================"
    echo ""
    
    check_docker
    download_image
    prepare_output
    run_docker_build
    show_result
}

# 异常处理
trap 'log_error "构建过程出错"; exit 1' ERR

# 运行主函数
main "$@"
