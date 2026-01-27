#!/bin/bash
# OpenWRT自动安装脚本
# 启动后自动运行，引导用户选择硬盘并安装IMG

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_title() { echo -e "${CYAN}\n$1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}! $1${NC}"; }
print_info() { echo -e "${BLUE}➤ $1${NC}"; }

# 显示欢迎界面
clear
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}          OpenWRT 系统安装程序${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

# 检查IMG文件
print_title "检查安装文件"
if [ ! -f /img/openwrt.img ]; then
    print_error "未找到OpenWRT镜像文件"
    echo "正在尝试从CD/DVD挂载..."
    
    mkdir -p /mnt/iso
    if mount -t iso9660 /dev/sr0 /mnt/iso 2>/dev/null || \
       mount -t iso9660 /dev/cdrom /mnt/iso 2>/dev/null; then
        if [ -f /mnt/iso/img/openwrt.img ]; then
            mkdir -p /img
            cp /mnt/iso/img/openwrt.img /img/
            cp /mnt/iso/img/image.info /img/ 2>/dev/null || true
            umount /mnt/iso
        else
            print_error "在光盘中也未找到镜像文件"
            echo "请按 Enter 键进入Shell手动操作..."
            read
            exec /bin/bash
        fi
    else
        print_error "无法挂载光盘"
        echo "请按 Enter 键进入Shell手动操作..."
        read
        exec /bin/bash
    fi
fi

IMG_SIZE=$(du -h /img/openwrt.img | cut -f1)
print_success "找到OpenWRT镜像文件: ${IMG_SIZE}"

if [ -f /img/image.info ]; then
    echo "镜像信息:"
    cat /img/image.info | grep -v "^#" | sed 's/^/  /'
fi

echo ""
read -p "按 Enter 键继续安装..." dummy

# 显示硬盘选择
print_title "选择目标硬盘"
echo "检测到的硬盘列表:"
echo ""

# 获取硬盘列表
DISKS=$(lsblk -d -n -o NAME,SIZE,MODEL | grep -E '^(sd|hd|vd|nvme)' || true)

if [ -z "$DISKS" ]; then
    print_error "未检测到硬盘"
    echo "正在尝试其他检测方式..."
    DISKS=$(fdisk -l 2>/dev/null | grep -E '^Disk /dev/(sd|hd|vd|nvme)' | cut -d' ' -f2- | sed 's/,$//')
    
    if [ -z "$DISKS" ]; then
        print_error "仍然无法检测到硬盘"
        echo "请按 Enter 键进入Shell手动操作..."
        read
        exec /bin/bash
    fi
fi

echo -e "${YELLOW}编号 | 设备 | 大小 | 型号${NC}"
echo "----------------------------------------"
i=1
declare -A DISK_MAP

while IFS= read -r line; do
    if echo "$line" | grep -q "^/dev/"; then
        # fdisk输出格式
        DEVICE=$(echo "$line" | cut -d' ' -f2 | tr -d :)
        SIZE=$(echo "$line" | cut -d' ' -f3-)
        MODEL="未知"
    else
        # lsblk输出格式
        DEVICE="/dev/$(echo "$line" | awk '{print $1}')"
        SIZE=$(echo "$line" | awk '{print $2}')
        MODEL=$(echo "$line" | cut -d' ' -f3-)
    fi
    
    # 检查是否为系统盘（有分区）
    IS_SYSTEM=0
    if [ -b "${DEVICE}" ]; then
        PART_COUNT=$(lsblk -n -o NAME "${DEVICE}" | wc -l)
        if [ "$PART_COUNT" -gt 1 ]; then
            IS_SYSTEM=1
        fi
    fi
    
    if [ "$IS_SYSTEM" -eq 1 ]; then
        echo -e "${RED}$i. ${DEVICE} | ${SIZE} | ${MODEL} (警告: 系统盘)${NC}"
    else
        echo -e "${GREEN}$i. ${DEVICE} | ${SIZE} | ${MODEL}${NC}"
    fi
    
    DISK_MAP[$i]=$DEVICE
    i=$((i+1))
done <<< "$DISKS"

echo ""
echo -e "${YELLOW}c. 取消安装并进入Shell${NC}"
echo -e "${YELLOW}r. 重新扫描硬盘${NC}"

# 选择硬盘
while true; do
    echo ""
    read -p "请选择要安装的硬盘编号 (1-$((i-1))): " choice
    
    case $choice in
        [cC])
            print_warning "安装取消"
            echo "进入Shell..."
            sleep 2
            exec /bin/bash
            ;;
        [rR])
            print_info "重新扫描硬盘..."
            exec $0
            ;;
        *)
            if [[ $choice =~ ^[0-9]+$ ]] && [ $choice -ge 1 ] && [ $choice -lt $i ]; then
                TARGET_DISK=${DISK_MAP[$choice]}
                
                # 确认选择
                echo ""
                print_warning "您选择了: ${TARGET_DISK}"
                print_warning "警告: 此操作将完全清空 ${TARGET_DISK} 上的所有数据！"
                echo ""
                read -p "确认安装? (输入 'yes' 继续): " confirm
                
                if [ "$confirm" = "yes" ]; then
                    break
                else
                    print_info "重新选择..."
                fi
            else
                print_error "无效选择"
            fi
            ;;
    esac
done

# 开始安装
print_title "开始安装 OpenWRT"
print_info "目标硬盘: ${TARGET_DISK}"
print_info "镜像文件: /img/openwrt.img (${IMG_SIZE})"

echo ""
echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
echo -e "${RED}       警告: 即将开始写入，此操作不可逆！${NC}"
echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
echo ""
read -p "最后确认，按 Enter 键开始安装 (Ctrl+C 取消)..." dummy

# 检查设备是否存在
if [ ! -b "${TARGET_DISK}" ]; then
    print_error "设备不存在: ${TARGET_DISK}"
    echo "按 Enter 键重启..."
    read
    reboot
fi

# 写入镜像
print_info "正在写入镜像到 ${TARGET_DISK} ..."

# 显示进度
if command -v pv >/dev/null 2>&1; then
    pv /img/openwrt.img | dd of=${TARGET_DISK} bs=4M conv=fsync 2>&1
else
    print_info "正在使用dd写入，这可能需要一些时间..."
    dd if=/img/openwrt.img of=${TARGET_DISK} bs=4M conv=fsync status=progress 2>&1
fi

DD_EXIT=$?

if [ $DD_EXIT -eq 0 ]; then
    print_success "镜像写入成功！"
    
    # 同步磁盘
    print_info "同步磁盘缓存..."
    sync
    
    # 验证写入
    print_info "验证安装..."
    if [ -b "${TARGET_DISK}" ]; then
        print_success "硬盘 ${TARGET_DISK} 已准备好"
    fi
else
    print_error "写入失败 (错误码: $DD_EXIT)"
    echo "按 Enter 键进入Shell查看错误..."
    read
    exec /bin/bash
fi

# 安装完成
print_title "安装完成"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}        OpenWRT 已成功安装到 ${TARGET_DISK}${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "下一步操作:"
echo "1. 移除安装介质 (USB/CD)"
echo "2. 系统将自动重启"
echo "3. 从硬盘启动 OpenWRT"
echo ""
echo -e "${YELLOW}系统将在10秒后自动重启...${NC}"

# 倒计时重启
for i in {10..1}; do
    echo -ne "倒计时: ${i}秒后重启...\r"
    sleep 1
done

print_info "正在重启系统..."
reboot
