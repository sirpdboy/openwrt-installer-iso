#!/bin/bash
# build-iso.sh OpenWRT ISO构建脚本 - 基于Alpine mkimage

set -e

# 参数处理
usage() {
    cat << EOF
用法: $0 <openwrt.img> <output.iso> [alpine_version]

参数:
  openwrt.img      OpenWRT镜像文件路径
  output.iso       输出的ISO文件路径
  alpine_version   Alpine版本 (默认: 3.20)

示例:
  $0 ./openwrt.img ./openwrt-installer.iso
  $0 ./openwrt.img ./output/openwrt.iso 3.20
EOF
    exit 1
}

# 检查参数
if [ $# -lt 2 ]; then
    usage
fi

IMG_FILE="$1"
OUTPUT_DIR="$2"
ALPINE_VERSION="${3:-3.20}"

OPENWRT_IMG=$(realpath "$IMG_FILE" 2>/dev/null || echo "$(cd "$(dirname "$IMG_FILE")" && pwd)/$(basename "$IMG_FILE")")
OUTPUT_ISO=$(realpath "$OUTPUT_DIR" 2>/dev/null || echo "$(cd "$(dirname "$OUTPUT_DIR")" && pwd)/$(basename "$OUTPUT_DIR")")
# 验证输入文件
if [ ! -f "$OPENWRT_IMG" ]; then
    echo "❌ 错误: OpenWRT镜像文件不存在: $OPENWRT_IMG"
    exit 1
fi

# 创建输出目录
OUTPUT_DIR=$(dirname "$OUTPUT_ISO")
mkdir -p "$OUTPUT_DIR"

echo "================================================"
echo "  OpenWRT Alpine Installer Builder"
echo "================================================"
echo ""
echo "配置信息:"
echo "  OpenWRT镜像: $OPENWRT_IMG ($(du -h "$OPENWRT_IMG" | cut -f1))"
echo "  输出ISO: $OUTPUT_ISO"
echo "  Alpine版本: $ALPINE_VERSION"
echo ""

# 创建临时工作目录
WORKDIR=$(mktemp -d)
echo "工作目录: $WORKDIR"
cd "$WORKDIR"

# 函数：清理临时文件
cleanup() {
    echo "清理临时文件..."
    if [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

# 1. 复制OpenWRT镜像到工作目录
echo "准备OpenWRT镜像..."
mkdir -p overlay/images
cp "$OPENWRT_IMG" overlay/images/openwrt.img
echo "✅ 镜像复制完成"

# 2. 创建安装脚本
echo "创建安装系统..."
mkdir -p overlay/usr/local/bin

cat > overlay/usr/local/bin/openwrt-installer << 'INSTALL_EOF'
#!/bin/sh
# OpenWRT安装程序

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 挂载必要文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2</dev/console

clear

# 显示标题
cat << "HEADER"
╔═══════════════════════════════════════╗
║         OpenWRT 安装程序              ║
║     基于 Alpine Linux                 ║
╚═══════════════════════════════════════╝
HEADER

echo ""
log_info "正在初始化安装环境..."

# 加载内核模块
echo "加载内核模块..."
for mod in loop isofs cdrom sr_mod virtio_blk nvme ahci sd_mod usb-storage; do
    modprobe $mod 2>/dev/null || true
done

# 挂载安装介质（如果从CD启动）
echo "查找安装介质..."
for dev in /dev/sr0 /dev/cdrom /dev/sr[0-9]*; do
    if [ -b "$dev" ]; then
        log_info "找到安装介质: $dev"
        mount -t iso9660 -o ro $dev /mnt 2>/dev/null && {
            # 复制OpenWRT镜像
            if [ -f /mnt/images/openwrt.img ]; then
                cp /mnt/images/openwrt.img /images/ 2>/dev/null
                log_success "复制OpenWRT镜像"
            fi
            umount /mnt 2>/dev/null
            break
        }
    fi
done

# 安装函数
install_openwrt() {
    echo ""
    log_info "=== OpenWRT 磁盘安装 ==="
    echo ""
    
    # 显示可用磁盘
    echo "可用磁盘列表:"
    echo "════════════════════════════════════════"
    
    DISK_LIST=()
    local count=0
    
    for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
        if [ -b "$disk" ]; then
            count=$((count + 1))
            DISK_LIST[$count]="$disk"
            
            # 获取磁盘信息
            size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
            size_gb=$((size / 1024 / 1024 / 1024))
            
            # 检查是否系统盘
            if mount | grep -q "^$disk"; then
                printf "  %2d) %-12s %4d GB  %s\n" "$count" "$disk" "$size_gb" "⚠️ 系统盘"
            else
                printf "  %2d) %-12s %4d GB\n" "$count" "$disk" "$size_gb"
            fi
        fi
    done
    
    echo "════════════════════════════════════════"
    
    if [ $count -eq 0 ]; then
        log_error "未找到任何可用磁盘!"
        return 1
    fi
    
    # 选择磁盘
    echo ""
    echo -n "请选择目标磁盘 (1-$count): "
    read choice
    
    # 验证输入
    if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        log_error "无效的选择!"
        return 1
    fi
    
    TARGET_DISK="${DISK_LIST[$choice]}"
    
    # 最终确认
    echo ""
    log_error "⚠️  ⚠️  ⚠️  警告 ⚠️  ⚠️  ⚠️"
    log_error "这将永久擦除磁盘 $TARGET_DISK 上的所有数据!"
    log_error "所有分区和数据都将被删除!"
    echo ""
    
    echo -n "请输入 'YES' 确认安装: "
    read confirm
    
    if [ "$confirm" != "YES" ]; then
        log_error "安装已取消"
        return 1
    fi
    
    # 查找OpenWRT镜像
    local img_path=""
    for path in /images/openwrt.img /mnt/images/openwrt.img; do
        if [ -f "$path" ]; then
            img_path="$path"
            break
        fi
    done
    
    if [ -z "$img_path" ]; then
        log_error "找不到OpenWRT镜像!"
        return 1
    fi
    
    # 开始安装
    echo ""
    log_info "正在安装 OpenWRT..."
    log_info "源镜像: $img_path"
    log_info "目标磁盘: $TARGET_DISK"
    echo ""
    
    # 显示进度
    echo "写入进度:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 使用dd写入
    if command -v pv >/dev/null 2>&1; then
        # 使用pv显示进度
        img_size=$(stat -c%s "$img_path" 2>/dev/null || echo 0)
        pv -s "$img_size" "$img_path" | dd of="$TARGET_DISK" bs=4M oflag=sync status=none
    else
        # 使用dd自带进度
        dd if="$img_path" of="$TARGET_DISK" bs=4M status=progress
    fi
    
    local result=$?
    
    # 同步数据
    sync
    
    if [ $result -eq 0 ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ OpenWRT 安装成功!"
        echo ""
        log_info "安装完成，请移除安装介质并重启系统"
        echo ""
        
        # 等待用户确认
        echo -n "按 Enter 键重启..."
        read
        echo ""
        log_info "正在重启系统..."
        sleep 2
        reboot -f
    else
        log_error "❌ 安装失败! (错误代码: $result)"
        return 1
    fi
}

# 主菜单
main_menu() {
    while true; do
        clear
        cat << "MENU"
╔═══════════════════════════════════════╗
║         OpenWRT 安装程序              ║
╚═══════════════════════════════════════╝
MENU
        echo ""
        log_info "请选择操作:"
        echo ""
        echo "  1) 安装 OpenWRT 到磁盘"
        echo "  2) 查看磁盘信息"
        echo "  3) 进入紧急 Shell"
        echo "  4) 重启系统"
        echo ""
        echo -n "选择 (1-4): "
        read choice
        
        case "$choice" in
            1)
                if install_openwrt; then
                    break
                else
                    echo ""
                    echo -n "按 Enter 键返回..."
                    read
                fi
                ;;
            2)
                echo ""
                log_info "磁盘信息:"
                echo "════════════════════════════════════════"
                if command -v lsblk >/dev/null 2>&1; then
                    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
                else
                    # 简单显示
                    for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
                        if [ -b "$disk" ]; then
                            size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
                            size_gb=$((size / 1024 / 1024 / 1024))
                            echo "$disk - ${size_gb}GB"
                        fi
                    done
                fi
                echo "════════════════════════════════════════"
                echo ""
                echo -n "按 Enter 键返回..."
                read
                ;;
            3)
                echo ""
                log_info "进入紧急 Shell..."
                log_info "输入 'exit' 返回安装程序"
                echo ""
                /bin/sh
                ;;
            4)
                echo ""
                log_info "正在重启系统..."
                sleep 2
                reboot -f
                ;;
            *)
                echo ""
                log_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 启动主菜单
main_menu

exit 0
INSTALL_EOF

chmod +x overlay/usr/local/bin/openwrt-installer

# 3. 创建overlay生成脚本
echo "创建overlay生成脚本..."

cat > genapkovl-openwrt.sh << 'OVERLAYEOF'
#!/bin/sh
# OpenWRT安装overlay生成脚本

set -e

# 创建临时目录
tmp="${ROOT}/tmp/overlay"
mkdir -p "$tmp"/etc/init.d
mkdir -p "$tmp"/usr/local/bin
mkdir -p "$tmp"/images

# 1. 复制OpenWRT镜像
if [ -f "/source/images/openwrt.img" ]; then
    echo "复制OpenWRT镜像..."
    cp "/source/images/openwrt.img" "$tmp/images/"
fi

# 2. 复制安装脚本
if [ -f "/source/usr/local/bin/openwrt-installer" ]; then
    echo "复制安装脚本..."
    cp "/source/usr/local/bin/openwrt-installer" "$tmp/usr/local/bin/"
    chmod 755 "$tmp/usr/local/bin/openwrt-installer"
fi

# 3. 创建init.d服务
cat > "$tmp/etc/init.d/openwrt-installer" << 'SERVICEEOF'
#!/sbin/openrc-run
# OpenWRT安装服务

name="openwrt-installer"
description="OpenWRT Installation Service"

depend() {
    need localmount
    after bootmisc
}

start() {
    ebegin "Starting OpenWRT installer"
    /usr/local/bin/openwrt-installer
    eend $?
}
SERVICEEOF

chmod 755 "$tmp/etc/init.d/openwrt-installer"

# 4. 添加到默认运行级别
mkdir -p "$tmp/etc/runlevels/default"
ln -sf /etc/init.d/openwrt-installer "$tmp/etc/runlevels/default/openwrt-installer"

# 5. 创建欢迎信息
cat > "$tmp/etc/issue" << 'ISSUEEOF'
========================================
      OpenWRT Alpine Installer
========================================

从启动菜单中选择 "Install OpenWRT"

ISSUEEOF

# 6. 创建/etc/apk/world
mkdir -p "$tmp/etc/apk"
cat > "$tmp/etc/apk/world" << 'WORLDEOF'
alpine-base
WORLDEOF

# 打包overlay
( cd "$tmp" && tar -c -f "${ROOT}/tmp/overlay.tar" . )

echo "Overlay创建完成"
OVERLAYEOF

chmod +x genapkovl-openwrt.sh

# 4. 使用Docker运行Alpine容器进行构建
echo "启动Alpine构建容器..."

# 创建构建命令
cat > build-command.sh << 'BUILDEOF'
#!/bin/sh
set -e

echo "=== 在Alpine容器中构建ISO ==="
echo "Alpine版本: $ALPINE_VERSION"

# 安装必要工具
apk update
apk add alpine-sdk alpine-conf syslinux xorriso squashfs-tools git

# 克隆aports
git clone --depth 1 https://gitlab.alpinelinux.org/alpine/aports.git
cd aports

# 创建profile
cat > scripts/mkimg.openwrt.sh << 'PROFILEEOF'
profile_openwrt() {
    profile_standard
    kernel_cmdline="console=tty0 console=ttyS0,115200"
    syslinux_serial="0 115200"
    apks="$apks dosfstools e2fsprogs parted lsblk"
    apkovl="genapkovl-openwrt.sh"
}
PROFILEEOF

# 复制overlay脚本到正确位置
cp /work/genapkovl-openwrt.sh scripts/

# 构建ISO
./scripts/mkimage.sh \
    --tag "$ALPINE_VERSION" \
    --outdir /output \
    --arch x86_64 \
    --hostkeys \
    --repository "http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/main" \
    --repository "http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/community" \
    --profile openwrt

# 重命名ISO
if ls /output/*.iso >/dev/null 2>&1; then
    ORIG_ISO=$(ls /output/*.iso)
    mv "$ORIG_ISO" "/output/openwrt-alpine-$ALPINE_VERSION.iso"
    echo "✅ ISO构建完成: openwrt-alpine-$ALPINE_VERSION.iso"
else
    echo "❌ ISO构建失败"
    exit 1
fi
BUILDEOF

chmod +x build-command.sh

# 运行Docker容器
echo "运行Docker构建容器..."
docker run --rm \
    -v "$WORKDIR/overlay:/source:ro" \
    -v "$WORKDIR:/work:ro" \
    -v "$OUTPUT_DIR:/output:rw" \
    -e ALPINE_VERSION="$ALPINE_VERSION" \
    alpine:$ALPINE_VERSION \
    sh -c "cd /work && ./build-command.sh"

# 检查结果
if [ -f "$OUTPUT_ISO" ]; then
    echo ""
    echo "🎉 🎉 🎉 构建成功! 🎉 🎉 🎉"
    echo ""
    echo "📁 ISO文件: $OUTPUT_ISO"
    echo "📊 文件大小: $(du -h "$OUTPUT_ISO" | cut -f1)"
    echo ""
    
    # 验证ISO
    echo "🔍 ISO验证信息:"
    if command -v file >/dev/null 2>&1; then
        file "$OUTPUT_ISO"
    fi
    
    exit 0
else
    echo "❌ 构建失败 - ISO文件未生成"
    exit 1
fi
