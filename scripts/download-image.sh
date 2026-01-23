#!/bin/bash
# download-image.sh- 下载OpenWRT镜像

set -euo pipefail

REPO="sirpdboy/openwrt"
ASSETS_DIR="assets"
FINAL_IMG="${ASSETS_DIR}/ezopwrt.img"
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

# 下载并解压
download_and_extract() {
    local url="$1"
    local output_img="$2"
    
    # 创建临时文件
    local temp_gz=$(mktemp /tmp/ezopwrt-XXXXXX.img.gz)
    local temp_img=$(mktemp /tmp/ezopwrt-XXXXXX.img)
    
    # 清理函数
     rm -f "$temp_gz" "$temp_img"
    
    log_info "下载镜像..."
    if ! curl -L -o "$temp_gz" --progress-bar "$url"; then
        log_error "下载失败"
        return 1
    fi
    
    log_info "解压镜像..."
    if ! gzip -dc "$temp_gz" > "$temp_img"; then
        log_error "解压失败"
        return 1
    fi
    
    # 验证镜像大小（至少10MB）
    local size=$(stat -c%s "$temp_img" 2>/dev/null || echo 0)
    if [ "$size" -lt 10485760 ]; then  # 10MB
        log_error "镜像文件过小: $((size/1024/1024))MB"
        return 1
    fi
    
    # 移动到最终位置
    mkdir -p "$(dirname "$output_img")"
    mv "$temp_img" "$output_img"
    
    # 清理临时文件（trap会处理）
    return 0
}

# 主函数
main() {
    echo "========================================"
    echo "    EzOpWrt 镜像下载工具"
    echo "========================================"
    
    check_deps
    
    # 清理旧文件
    rm -f "$FINAL_IMG"
    
    # 获取tag
    local tag
    tag=$(get_latest_tag)
    log_success "版本: $tag"
    
    # 获取URL
    local url
    url=$(get_download_url "$tag")
    log_info "下载链接: $url"
    
    # 下载并解压
    if download_and_extract "$url" "$FINAL_IMG"; then
        log_success "✅ 镜像下载完成"
        echo ""
        echo "文件信息:"
        echo "  路径: $FINAL_IMG"
        echo "  大小: $(du -h "$FINAL_IMG" | cut -f1)"
        echo "  版本: $tag"
        echo ""
        ls -lh "$FINAL_IMG"
    else
        log_error "❌ 镜像下载失败"
        exit 1
    fi
}

# 运行
main "$@"
