#!/bin/bash
# download-image.sh - 下载OpenWRT镜像（修复版）

set -euo pipefail

# 配置变量
REPO="sirpdboy/openwrt"
ASSETS_DIR="assets"
TEMP_DIR="/tmp/ezopwrt-download"
LOG_FILE="$TEMP_DIR/download.log"

# 颜色输出函数
red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
blue() { echo -e "\033[34m$*\033[0m"; }

log_info() { blue "[INFO] $*"; }
log_success() { green "[SUCCESS] $*"; }
log_warning() { yellow "[WARNING] $*"; }
log_error() { red "[ERROR] $*"; }

# 创建目录
mkdir -p "$ASSETS_DIR" "$TEMP_DIR"

# 清理函数
cleanup() {
    if [ $? -ne 0 ]; then
        log_error "脚本执行失败"
        echo "查看日志: $LOG_FILE"
        cat "$LOG_FILE" 2>/dev/null || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# 获取最新标签
get_latest_tag() {
    log_info "获取最新版本..."
    
    # 方法1：从releases获取
    local tag
    tag=$(curl -sL \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4) 2>/dev/null || true
    
    # 方法2：如果失败，从tags获取
    if [ -z "$tag" ] || [ "$tag" = "null" ]; then
        log_warning "无法获取release，尝试获取tags..."
        tag=$(curl -sL \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/$REPO/tags" \
            | grep -o '"name": *"[^"]*"' | head -1 | cut -d'"' -f4) 2>/dev/null || true
    fi
    
    if [ -z "$tag" ]; then
        log_error "无法获取版本信息"
        exit 1
    fi
    
    echo "$tag"
}

# 获取下载URL
get_download_url() {
    local tag="$1"
    log_info "获取版本 $tag 的下载链接..."
    
    # 获取release信息
    local release_json
    release_json=$(curl -sL \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$REPO/releases/tags/$tag") 2>/dev/null || true
    
    if [ -z "$release_json" ]; then
        log_error "无法获取release信息"
        exit 1
    fi
    
    # 提取.img.gz文件的下载URL（使用grep替代jq）
    local download_url
    download_url=$(echo "$release_json" | \
        grep -o '"browser_download_url": *"[^"]*\.img\.gz[^"]*"' | \
        head -1 | \
        cut -d'"' -f4)
    
    if [ -z "$download_url" ]; then
        log_error "未找到.img.gz文件"
        exit 1
    fi
    
    echo "$download_url"
}

# 下载文件
download_file() {
    local url="$1"
    local output_file="$2"
    
    log_info "下载: $(basename "$output_file")"
    log_info "来源: $url"
    
    # 使用wget下载（更稳定）
    if ! wget -q --show-progress \
        --timeout=30 \
        --tries=3 \
        --retry-connrefused \
        -O "$output_file" \
        "$url"; then
        
        log_error "下载失败"
        return 1
    fi
    
    # 验证文件
    if [ ! -s "$output_file" ]; then
        log_error "下载的文件为空"
        return 1
    fi
    
    log_success "下载完成: $(ls -lh "$output_file" | awk '{print $5}')"
    return 0
}

# 解压文件
extract_file() {
    local gz_file="$1"
    local img_file="${gz_file%.gz}"
    
    log_info "解压文件..."
    
    # 检查是否为gzip文件
    if ! file "$gz_file" | grep -q "gzip compressed data"; then
        log_error "不是有效的gzip文件"
        return 1
    fi
    
    # 解压
    if ! gzip -d -f "$gz_file"; then
        log_error "解压失败"
        return 1
    fi
    
    # 重命名
    if [ -f "$img_file" ]; then
        log_success "解压完成: $img_file"
        echo "$img_file"
        return 0
    else
        log_error "解压后文件不存在"
        return 1
    fi
}

# 主函数
main() {
    echo "========================================"
    echo "    EzOpWrt 镜像下载工具"
    echo "========================================"
    echo ""
    
    # 获取最新tag
    local tag
    tag=$(get_latest_tag)
    log_success "最新版本: $tag"
    
    # 获取下载URL
    local download_url
    download_url=$(get_download_url "$tag")
    log_info "下载链接: $download_url"
    
    # 设置输出文件路径
    local gz_file="${ASSETS_DIR}/ezopwrt-${tag}.img.gz"
    local final_img="${ASSETS_DIR}/ezopwrt.img"
    
    # 下载
    if ! download_file "$download_url" "$gz_file"; then
        exit 1
    fi
    
    # 解压
    local extracted_file
    if extracted_file=$(extract_file "$gz_file"); then
        # 重命名为标准名称
        mv "$extracted_file" "$final_img"
        log_success "镜像准备完成: $final_img"
        
        # 显示信息
        echo ""
        echo "镜像信息:"
        echo "  - 文件: $(basename "$final_img")"
        echo "  - 大小: $(du -h "$final_img" | cut -f1)"
        echo "  - 版本: $tag"
        echo "  - 路径: $(readlink -f "$final_img")"
        echo ""
        
        # 如果是GitHub Actions，输出变量
        if [ -n "${GITHUB_OUTPUT:-}" ]; then
            echo "image_path=$final_img" >> "$GITHUB_OUTPUT"
            echo "image_size=$(stat -c%s "$final_img")" >> "$GITHUB_OUTPUT"
            echo "image_version=$tag" >> "$GITHUB_OUTPUT"
        fi
    else
        exit 1
    fi
    
    log_success "🎉 所有操作完成！"
}

# 运行主函数
main "$@" 2>&1 | tee "$LOG_FILE"
