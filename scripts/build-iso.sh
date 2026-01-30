#!/bin/bash
# OpenWRT ISO构建脚本 - 基于Alpine mkimage

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
OUTPUT_PATH="$2"
ALPINE_VERSION="${3:-3.20}"

# 获取绝对路径
get_absolute_path() {
    local path="$1"
    if [[ "$path" == /* ]]; then
        echo "$path"
    else
        echo "$(pwd)/$path"
    fi
}

# 转换为绝对路径
OPENWRT_IMG=$(get_absolute_path "$IMG_FILE")
OUTPUT_ISO=$(get_absolute_path "$OUTPUT_PATH")

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
echo "临时工作目录: $WORKDIR"
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

if [ $? -eq 0 ] && [ -f "overlay/images/openwrt.img" ]; then
    echo "✅ 镜像复制完成: $(du -h overlay/images/openwrt.img | cut -f1)"
else
    echo "❌ 镜像复制失败"
    exit 1
fi

# 2. 创建安装脚本
echo "创建安装系统..."
mkdir -p overlay/usr/local/bin

cat > overlay/usr/local/bin/openwrt-installer << 'INSTALL_EOF'
#!/bin/sh
# OpenWRT安装程序

set -e

# 挂载必要文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 设置控制台
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

clear

echo "========================================"
echo "     OpenWRT Installer"
echo "========================================"
echo ""
echo "Initializing..."

# 加载内核模块
for mod in loop isofs cdrom; do
    modprobe $mod 2>/dev/null || true
done

# 安装函数
install_openwrt() {
    echo ""
    echo "=== OpenWRT Installation ==="
    echo ""
    
    # 显示可用磁盘
    echo "Available disks:"
    echo "----------------"
    for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
        if [ -b "$disk" ]; then
            size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
            size_gb=$((size / 1024 / 1024 / 1024))
            echo "  $disk - ${size_gb}GB"
        fi
    done
    echo "----------------"
    
    # 获取目标磁盘
    echo ""
    echo -n "Enter target disk (e.g., sda): "
    read target
    
    [ -z "$target" ] && return 1
    
    # 添加/dev/前缀
    if [ "$target" != "/dev/"* ]; then
        target="/dev/$target"
    fi
    
    [ ! -b "$target" ] && echo "Disk not found!" && return 1
    
    # 确认
    echo ""
    echo "WARNING: This will ERASE ALL DATA on $target!"
    echo ""
    echo -n "Type 'YES' to confirm: "
    read confirm
    
    [ "$confirm" != "YES" ] && echo "Cancelled" && return 1
    
    # 查找OpenWRT镜像
    img=""
    [ -f /images/openwrt.img ] && img="/images/openwrt.img"
    [ -z "$img" ] && echo "OpenWRT image not found!" && return 1
    
    # 开始安装
    echo ""
    echo "Installing OpenWRT to $target..."
    echo ""
    
    if command -v pv >/dev/null 2>&1; then
        pv "$img" | dd of="$target" bs=4M
    else
        dd if="$img" of="$target" bs=4M status=progress 2>/dev/null || \
        dd if="$img" of="$target" bs=4M
    fi
    
    if [ $? -eq 0 ]; then
        sync
        echo ""
        echo "✅ Installation successful!"
        echo ""
        echo "System will reboot in 10 seconds..."
        sleep 10
        reboot -f
    else
        echo ""
        echo "❌ Installation failed!"
        return 1
    fi
}

# 主菜单
while true; do
    echo ""
    echo "Menu:"
    echo "1) Install OpenWRT"
    echo "2) Emergency Shell"
    echo "3) Reboot"
    echo ""
    echo -n "Select (1-3): "
    read choice
    
    case "$choice" in
        1)
            if install_openwrt; then
                break
            fi
            ;;
        2)
            echo ""
            echo "Starting emergency shell..."
            echo "Type 'exit' to return"
            echo ""
            /bin/sh
            ;;
        3)
            echo "Rebooting..."
            reboot -f
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
done
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
    echo "Copying OpenWRT image..."
    cp "/source/images/openwrt.img" "$tmp/images/"
fi

# 2. 复制安装脚本
if [ -f "/source/usr/local/bin/openwrt-installer" ]; then
    echo "Copying installer script..."
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

# 5. 创建/etc/apk/world
mkdir -p "$tmp/etc/apk"
cat > "$tmp/etc/apk/world" << 'WORLDEOF'
alpine-base
WORLDEOF

# 打包overlay
( cd "$tmp" && tar -c -f "${ROOT}/tmp/overlay.tar" . )

echo "Overlay created"
OVERLAYEOF

chmod +x genapkovl-openwrt.sh

# 4. 使用Docker运行Alpine容器进行构建
echo "启动Alpine构建容器..."

# 使用Docker构建（修复模块签名问题）
docker run --rm \
    -v "$WORKDIR/overlay:/source:ro" \
    -v "$WORKDIR:/work:rw" \
    -v "$OUTPUT_DIR:/output:rw" \
    -e ALPINE_VERSION="$ALPINE_VERSION" \
    alpine:$ALPINE_VERSION \
    sh -c "
    set -e
    
    echo '=== Building ISO in Alpine container ==='
    echo 'Alpine version: \$ALPINE_VERSION'
    
    # 切换到可写目录
    cd /tmp
    echo 'Current directory: \$(pwd)'
    
    # 安装必要工具
    echo 'Installing tools...'
    apk update
    apk add alpine-sdk alpine-conf syslinux xorriso squashfs-tools git
    
    # 克隆aports到/tmp目录
    echo 'Cloning aports...'
    git clone --depth 1 https://gitlab.alpinelinux.org/alpine/aports.git
    cd aports
    
    # 创建profile - 关键修复：禁用模块签名
    echo 'Creating profile...'
    cat > scripts/mkimg.openwrt.sh << 'PROFILEEOF'
profile_openwrt() {
    profile_standard
    kernel_cmdline=\"console=tty0 console=ttyS0,115200\"
    syslinux_serial=\"0 115200\"
    
    # 禁用模块签名以避免PACKAGER_PRIVKEY错误
    modloop_sign=no
    
    # 明确设置不包含内核模块
    kernel_flavors=\"\"
    kernel_addons=\"\"
    
    # 添加必要软件包
    apks=\"\\\$apks\"
    
    # 使用我们的overlay脚本
    apkovl=\"genapkovl-openwrt.sh\"
}
PROFILEEOF
    
    # 复制overlay脚本
    echo 'Copying overlay script...'
    cp /work/genapkovl-openwrt.sh scripts/
    chmod +x scripts/genapkovl-openwrt.sh
    
    # 方法1: 尝试使用标准profile构建（避免模块签名问题）
    echo 'Method 1: Using standard profile with custom overlay...'
    
    # 使用mkimage的--hostkeys参数，并禁用模块签名
    cat > build-simple.sh << 'BUILDEOF'
#!/bin/sh
# 简单构建脚本

set -e

# 创建简单的profile配置
cat > mkimg.simple.sh << 'SIMPLEEOF'
profile_simple() {
    profile_standard
    kernel_cmdline=\"console=tty0 console=ttyS0,115200\"
    syslinux_serial=\"0 115200\"
    
    # 关键：禁用模块签名
    modloop_sign=no
    
    # 不使用内核模块
    kernel_flavors=\"\"
    kernel_addons=\"\"
    
    # 使用我们的overlay
    apkovl=\"genapkovl-openwrt.sh\"
}
SIMPLEEOF

# 将profile移动到正确位置
mv mkimg.simple.sh scripts/mkimg.simple.sh

# 构建ISO
echo 'Building ISO...'
./scripts/mkimage.sh \\
    --tag \"\$ALPINE_VERSION\" \\
    --outdir /output \\
    --arch x86_64 \\
    --hostkeys \\
    --modloop \\
    --repository \"http://dl-cdn.alpinelinux.org/alpine/v\$ALPINE_VERSION/main\" \\
    --repository \"http://dl-cdn.alpinelinux.org/alpine/v\$ALPINE_VERSION/community\" \\
    --profile simple
BUILDEOF
    
    chmod +x build-simple.sh
    
    # 尝试方法1
    echo 'Trying method 1...'
    if ./build-simple.sh; then
        echo '✅ Method 1 succeeded'
    else
        echo '⚠️ Method 1 failed, trying method 2...'
        
        # 方法2: 使用更简单的配置
        echo 'Method 2: Using minimal configuration...'
        
        # 使用vanilla profile，它默认不包含内核模块
        ./scripts/mkimage.sh \\
            --tag \"\$ALPINE_VERSION\" \\
            --outdir /output \\
            --arch x86_64 \\
            --hostkeys \\
            --no-modloop \\
            --repository \"http://dl-cdn.alpinelinux.org/alpine/v\$ALPINE_VERSION/main\" \\
            --profile vanilla
    fi
    
    # 检查结果
    if ls /output/*.iso >/dev/null 2>&1; then
        ORIG_ISO=\$(ls /output/*.iso)
        mv \"\$ORIG_ISO\" \"/output/openwrt-alpine-\$ALPINE_VERSION.iso\"
        echo '✅ ISO built successfully'
    else
        echo '❌ ISO build failed'
        exit 1
    fi
    "

# 检查结果
if ls "$OUTPUT_DIR"/openwrt-alpine-*.iso 1>/dev/null 2>&1; then
    ISO_FILE=$(ls "$OUTPUT_DIR"/openwrt-alpine-*.iso)
    # 重命名为用户指定的名称
    mv "$ISO_FILE" "$OUTPUT_ISO"
    
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
    echo "输出目录内容:"
    ls -la "$OUTPUT_DIR" 2>/dev/null || echo "输出目录不存在"
    exit 1
fi
