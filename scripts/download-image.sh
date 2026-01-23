#!/bin/bash
# download-image-pro.sh - 专业修复版

set -euo pipefail

REPO="sirpdboy/openwrt"
ASSETS_DIR="assets"
FINAL_IMG="${ASSETS_DIR}/ezopwrt.img"

# 颜色输出
echo_info() { echo -e "\033[36m[INFO]\033[0m $*"; }
echo_success() { echo -e "\033[32m[SUCCESS]\033[0m $*"; }
echo_error() { echo -e "\033[31m[ERROR]\033[0m $*"; }

# 检查依赖
check_deps() {
    for cmd in curl gzip; do
        if ! command -v "$cmd" &> /dev/null; then
            echo_error "缺少命令: $cmd"
            exit 1
        fi
    done
}

# 获取最新tag
get_latest_tag() {
    echo_info "获取最新版本..."
    
    local api_url="https://api.github.com/repos/$REPO/releases/latest"
    local tag=$(curl -sL "$api_url" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -z "$tag" ]; then
        api_url="https://api.github.com/repos/$REPO/tags"
        tag=$(curl -sL "$api_url" | grep -o '"name": *"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
    
    [ -z "$tag" ] && { echo_error "无法获取版本"; exit 1; }
    
    echo "$tag"
}

# 获取下载URL
get_download_url() {
    local tag="$1"
    echo_info "获取版本 $tag 的下载链接..."
    
    local api_url="https://api.github.com/repos/$REPO/releases/tags/$tag"
    local download_url=$(curl -sL "$api_url" | \
        grep -o '"browser_download_url": *"[^"]*\.img\.gz[^"]*"' | \
        head -1 | cut -d'"' -f4)
    
    [ -z "$download_url" ] && { echo_error "未找到镜像文件"; exit 1; }
    
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
    cleanup() {
        rm -f "$temp_gz" "$temp_img"
    }
    trap cleanup EXIT
    
    echo_info "下载镜像..."
    if ! curl -L -o "$temp_gz" --progress-bar "$url"; then
        echo_error "下载失败"
        return 1
    fi
    
    echo_info "解压镜像..."
    if ! gzip -dc "$temp_gz" > "$temp_img"; then
        echo_error "解压失败"
        return 1
    fi
    
    # 验证镜像大小（至少10MB）
    local size=$(stat -c%s "$temp_img" 2>/dev/null || echo 0)
    if [ "$size" -lt 10485760 ]; then  # 10MB
        echo_error "镜像文件过小: $((size/1024/1024))MB"
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
    echo_success "版本: $tag"
    
    # 获取URL
    local url
    url=$(get_download_url "$tag")
    echo_info "下载链接: $url"
    
    # 下载并解压
    if download_and_extract "$url" "$FINAL_IMG"; then
        echo_success "✅ 镜像下载完成"
        echo ""
        echo "文件信息:"
        echo "  路径: $FINAL_IMG"
        echo "  大小: $(du -h "$FINAL_IMG" | cut -f1)"
        echo "  版本: $tag"
        echo ""
        ls -lh "$FINAL_IMG"
    else
        echo_error "❌ 镜像下载失败"
        exit 1
    fi
}

# 运行
main "$@"
