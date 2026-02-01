#!/bin/bash
# scripts/lib/utils.sh
# 通用工具函数

# 颜色定义
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_MAGENTA='\033[0;35m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

# 日志函数
log_info() {
    echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET} $1"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1" >&2
}

log_debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        echo -e "${COLOR_BLUE}[DEBUG]${COLOR_RESET} $1"
    fi
}

# 标题函数
print_header() {
    echo ""
    echo -e "${COLOR_CYAN}========================================${COLOR_RESET}"
    echo -e "${COLOR_CYAN}  $1${COLOR_RESET}"
    echo -e "${COLOR_CYAN}========================================${COLOR_RESET}"
    echo ""
}

print_success() {
    echo ""
    echo -e "${COLOR_GREEN}✓ $1${COLOR_RESET}"
    echo ""
}

print_step() {
    echo -e "${COLOR_MAGENTA}▶ $1${COLOR_RESET}"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查是否为root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "此操作需要root权限"
        exit 1
    fi
}

# 创建目录（如果不存在）
ensure_dir() {
    if [ ! -d "$1" ]; then
        log_debug "创建目录: $1"
        mkdir -p "$1"
    fi
}

# 清理目录
clean_dir() {
    if [ -d "$1" ]; then
        log_debug "清理目录: $1"
        rm -rf "$1"
    fi
}

# 下载文件（带重试）
download_file() {
    local url="$1"
    local output="$2"
    local max_retries="${3:-3}"
    
    log_debug "下载: $url -> $output"
    
    for i in $(seq 1 $max_retries); do
        if wget -q -O "$output" "$url"; then
            return 0
        fi
        log_warn "下载失败，重试 $i/$max_retries: $url"
        sleep 2
    done
    
    log_error "下载失败: $url"
    return 1
}
