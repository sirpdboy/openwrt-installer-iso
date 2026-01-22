#!/bin/bash
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[*]${NC} $1"; }
log_success() { echo -e "${GREEN}[+]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[-]${NC} $1"; }

# 显示标题
clear
echo "================================================"
echo "       OpenWRT 安装程序"
echo "================================================"
echo ""

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "需要root权限运行此脚本"
    exit 1
fi

# 查找OpenWRT镜像
OPENWRT_IMG="/live/openwrt.img"
if [ ! -f "$OPENWRT_IMG" ]; then
    log_error "找不到OpenWRT镜像: $OPENWRT_IMG"
    exit 1
fi

log_info "找到OpenWRT镜像: $(ls -lh "$OPENWRT_IMG")"

# 显示磁盘列表
log_info "检测可用磁盘..."
echo ""
echo "可用磁盘列表:"
echo "--------------------------------"

DISKS=()
while IFS= read -r line; do
    if [[ "$line" =~ ^/dev/[sv]d[a-z] ]]; then
        disk=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $4}')
        model=$(echo "$line" | awk '{print $3}')
        DISKS+=("$disk")
        printf "  %-10s %-10s %s\n" "$disk" "$size" "$model"
    fi
done < <(lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "NAME")

echo "--------------------------------"
echo ""

if [ ${#DISKS[@]} -eq 0 ]; then
    log_error "未找到可用磁盘"
    exit 1
fi

# 选择磁盘
while true; do
    read -p "请输入要安装OpenWRT的磁盘 (例如: /dev/sda): " TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        log_warning "请输入磁盘设备路径"
        continue
    fi
    
    if [[ ! "$TARGET_DISK" =~ ^/dev/[sv]d[a-z]$ ]]; then
        log_warning "无效的磁盘设备路径。请使用类似 /dev/sda 的格式"
        continue
    fi
    
    if [ ! -b "$TARGET_DISK" ]; then
        log_warning "磁盘 $TARGET_DISK 不存在"
        continue
    fi
    
    # 确认选择
    DISK_INFO=$(lsblk -d -o SIZE,MODEL "$TARGET_DISK" 2>/dev/null | tail -1)
    if [ -z "$DISK_INFO" ]; then
        log_warning "无法获取磁盘信息"
        continue
    fi
    
    echo ""
    log_warning "警告：这将完全擦除磁盘 $TARGET_DISK 上的所有数据！"
    echo "磁盘信息: $DISK_INFO"
    echo ""
    
    read -p "确认安装到 $TARGET_DISK ？输入 'y' 确认: " CONFIRM
    
    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
        break
    else
        echo "取消选择，请重新选择磁盘"
        echo ""
    fi
done

# 确认安装
echo ""
echo "================================================"
log_warning "最终确认"
echo "================================================"
echo "目标磁盘: $TARGET_DISK"
echo "源镜像: $OPENWRT_IMG"
echo ""
echo "此操作将："
echo "1. 擦除 $TARGET_DISK 上的所有分区和数据"
echo "2. 写入OpenWRT系统镜像"
echo "3. 磁盘将无法恢复原有数据"
echo ""

read -p "输入 'yes' 确认开始安装: " FINAL_CONFIRM

if [ "$FINAL_CONFIRM" != "yes" ]; then
    log_error "安装已取消"
    exit 0
fi

# 开始安装
echo ""
log_info "开始安装OpenWRT到 $TARGET_DISK ..."
echo ""

# 卸载所有相关分区
for partition in $(lsblk -lno NAME "$TARGET_DISK" | grep -v "^$(basename "$TARGET_DISK")$"); do
    umount "/dev/$partition" 2>/dev/null || true
done

# 使用dd写入镜像
log_info "正在写入镜像，这可能需要几分钟..."
if ! dd if="$OPENWRT_IMG" of="$TARGET_DISK" bs=4M status=progress; then
    log_error "镜像写入失败"
    exit 1
fi

# 同步磁盘
sync

echo ""
log_success "OpenWRT安装完成！"
echo ""
log_info "请执行以下操作："
echo "1. 移除安装介质"
echo "2. 设置从 $TARGET_DISK 启动"
echo "3. 重启系统"
echo ""
read -p "按Enter键重启系统，或按Ctrl+C取消..." </dev/tty

# 重启
reboot
