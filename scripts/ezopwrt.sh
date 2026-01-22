#!/bin/bash
set -euo pipefail

# 配置
REPO="sirpdboy/openwrt"
ASSETS_DIR="assets"
LOG_FILE="/tmp/ezopwrt-download.log"

# 颜色输出
red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
blue() { echo -e "\033[34m$*\033[0m"; }

log_info() { blue "[INFO] $*"; }
log_success() { green "[SUCCESS] $*"; }
log_warning() { yellow "[WARNING] $*"; }
log_error() { red "[ERROR] $*"; }

# 检查依赖
check_deps() {
    local deps=("curl" "jq" "gzip" "file")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "缺少依赖: $dep"
            return 1
        fi
    done
}

# 获取最新tag
get_latest_tag() {
    local tag=""
    
    # 尝试从releases获取
    log_info "获取最新Release..."
    tag=$(curl -sL \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$REPO/releases/latest" \
        | jq -r '.tag_name // empty')
    
    # 如果失败，从tags获取
    if [ -z "$tag" ] || [ "$tag" = "null" ]; then
        log_warning "无法获取Release，尝试获取Tags..."
        tag=$(curl -sL \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/$REPO/tags" \
            | jq -r '.[0].name // empty')
    fi
    
    if [ -z "$tag" ] || [ "$tag" = "null" ]; then
        log_error "无法获取版本信息"
        return 1
    fi
    
    echo "$tag"
}

# 下载镜像
download_image() {
    local tag="$1"
    local url_list="" download_url="" output_file=""
    
    log_info "获取TAG: $tag 的下载列表..."
    
    # 获取下载URL列表
    url_list=$(curl -sL \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$REPO/releases/tags/$tag" \
        | jq -r '.assets[] | select(.name | endswith("img.gz")) | .browser_download_url')
    
    if [ -z "$url_list" ]; then
        log_error "未找到.img.gz文件"
        return 1
    fi
    
    # 选择第一个符合条件的URL
    download_url=$(echo "$url_list" | head -n1)
    output_file="${ASSETS_DIR}/ezopwrt.img.gz"
    
    # 创建目录
    mkdir -p "$ASSETS_DIR"
    
    log_info "下载镜像: $download_url"
    log_info "保存到: $output_file"
    
    # 下载文件
    if curl -L -o "$output_file" \
        --progress-bar \
        --retry 3 \
        --retry-delay 5 \
        --connect-timeout 30 \
        --max-time 300 \
        "$download_url"; then
        
        # 验证文件
        if [ ! -s "$output_file" ]; then
            log_error "下载的文件为空"
            return 1
        fi
        
        log_success "下载完成"
        echo "$output_file"
        return 0
    else
        log_error "下载失败"
        return 1
    fi
}

# 解压镜像
extract_image() {
    local gz_file="$1"
    local img_file="${gz_file%.gz}"
    
    log_info "解压镜像..."
    
    if [ ! -f "$gz_file" ]; then
        log_error "找不到压缩文件: $gz_file"
        return 1
    fi
    
    # 检查文件类型
    if ! file "$gz_file" | grep -q "gzip compressed data"; then
        log_error "不是有效的gzip文件"
        return 1
    fi
    
    # 解压
    if gzip -d -f "$gz_file"; then
        log_success "解压完成: $img_file"
        
        # 验证解压后的文件
        if [ ! -f "$img_file" ]; then
            log_error "解压后文件不存在"
            return 1
        fi
        
        echo "$img_file"
        return 0
    else
        log_error "解压失败"
        return 1
    fi
}

# 验证镜像
validate_image() {
    local img_file="$1"
    local size_mb=""
    
    log_info "验证镜像..."
    
    if [ ! -f "$img_file" ]; then
        log_error "镜像文件不存在: $img_file"
        return 1
    fi
    
    # 检查文件大小
    size_mb=$(( $(stat -c%s "$img_file") / 1024 / 1024 ))
    
    if [ "$size_mb" -lt 10 ]; then
        log_error "镜像文件过小: ${size_mb}MB"
        return 1
    fi
    
    # 检查文件类型
    if ! file "$img_file" | grep -q "DOS/MBR boot sector"; then
        log_warning "镜像可能不是有效的启动镜像"
        # 不返回错误，继续尝试
    fi
    
    log_success "镜像验证通过: ${size_mb}MB"
    return 0
}

# 主函数
main() {
    local tag="" gz_file="" img_file=""
    
    log_info "开始下载EzOpWrt镜像..."
    
    # 检查依赖
    check_deps || exit 1
    
    # 获取tag
    tag=$(get_latest_tag) || exit 1
    log_info "最新版本: $tag"
    
    # 下载镜像
    gz_file=$(download_image "$tag") || exit 1
    
    # 解压镜像
    img_file=$(extract_image "$gz_file") || exit 1
    
    # 验证镜像
    validate_image "$img_file" || exit 1
    
    # 显示结果
    log_success "������ EzOpWrt镜像准备完成!"
    echo ""
    echo "镜像信息:"
    echo "  - 文件: $(basename "$img_file")"
    echo "  - 大小: $(du -h "$img_file" | cut -f1)"
    echo "  - 位置: $(readlink -f "$img_file")"
    echo ""
    
    # 输出GitHub Actions变量
    if [ -n "$GITHUB_OUTPUT" ]; then
        echo "img_path=$img_file" >> "$GITHUB_OUTPUT"
        echo "img_size=$(stat -c%s "$img_file")" >> "$GITHUB_OUTPUT"
    fi
}

# 异常处理
trap 'log_error "脚本执行出错"; exit 1' ERR

# 运行主函数
main "$@"
