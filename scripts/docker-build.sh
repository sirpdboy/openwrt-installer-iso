#!/bin/bash
# docker-build.sh OpenWRT ISO Builder - 基于Alpine的完整解决方案

set -e

echo "================================================"
echo "  OpenWRT ISO Builder - Alpine Edition"
echo "================================================"
echo ""

# 参数处理
IMG_FILE="$1"
OUTPUT_DIR="${2:-./output}"
ISO_NAME="${3:-openwrt-installer-$(date +%Y%m%d).iso}"
ALPINE_VERSION="${4:-3.20}"

# 基本检查
if [ $# -lt 1 ]; then
    cat << EOF
用法: $0 <img文件> [输出目录] [iso名称] [alpine版本]

示例:
  $0 ./openwrt.img
  $0 ./openwrt.img ./iso my-openwrt.iso
  $0 ./openwrt.img ./output openwrt.iso 3.19
EOF
    exit 1
fi

if [ ! -f "$IMG_FILE" ]; then
    echo "❌ 错误: IMG文件不存在: $IMG_FILE"
    exit 1
fi

# 创建目录
mkdir -p "$OUTPUT_DIR"

# 获取绝对路径
IMG_ABS=$(realpath "$IMG_FILE" 2>/dev/null || echo "$(cd "$(dirname "$IMG_FILE")" && pwd)/$(basename "$IMG_FILE")")
OUTPUT_ABS=$(realpath "$OUTPUT_DIR" 2>/dev/null || echo "$(cd "$(dirname "$OUTPUT_DIR")" && pwd)/$(basename "$OUTPUT_DIR")")

echo "📋 构建配置:"
echo "  Alpine版本: $ALPINE_VERSION"
echo "  输入IMG: $IMG_ABS"
echo "  输出目录: $OUTPUT_ABS"
echo "  ISO名称: $ISO_NAME"
echo ""

# 检查Docker
echo "🔧 检查Docker环境..."
if ! command -v docker &>/dev/null; then
    echo "❌ Docker未安装"
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "❌ Docker服务未运行"
    exit 1
fi
echo "✅ Docker可用"

# 创建优化的Dockerfile
DOCKERFILE_PATH="Dockerfile.alpine-iso"
cat > "$DOCKERFILE_PATH" << 'DOCKERFILE_EOF'
# Dockerfile.alpine-iso-fixed
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION} AS builder

# 使用国内镜像源，避免Docker Hub超时
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories

# 安装最小必要工具集
RUN apk update && \
    apk add --no-cache \
    bash \
    xorriso \
    syslinux \
    mtools \
    dosfstools \
    e2fsprogs \
    parted \
    util-linux \
    coreutils \
    gzip \
    tar \
    cpio \
    findutils \
    grep \
    curl \
    wget \
    linux-lts

# 尝试安装GRUB，如果失败则跳过
RUN apk add --no-cache grub grub-efi 2>/dev/null || \
    echo "GRUB安装失败，将使用替代方案" && \
    # 创建必要的工具占位
    mkdir -p /usr/sbin && \
    echo '#!/bin/sh\necho "GRUB tool not available"' > /usr/sbin/grub-mkimage && \
    chmod +x /usr/sbin/grub-mkimage

WORKDIR /work

# 复制构建脚本
COPY scripts/build-iso-alpine.sh /build.sh
RUN chmod +x /build.sh

ENTRYPOINT ["/build.sh"]


DOCKERFILE_EOF

# 更新版本号
# sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/g" "$DOCKERFILE_PATH"

# 创建完整的Alpine构建脚本
mkdir -p scripts

cat > scripts/build-iso-alpine.sh << 'BUILD_SCRIPT_EOF'
#!/bin/bash
# build-iso-complete.sh -

set -e

echo "================================================"
echo "  OpenWRT ISO Builder - Complete Edition"
echo "================================================"
echo ""

IMG_FILE="$1"
OUTPUT_DIR="${2:-./output}"
ISO_NAME="${3:-openwrt-complete-$(date +%Y%m%d).iso}"

if [ $# -lt 1 ]; then
    echo "用法: $0 <img文件> [输出目录] [iso名称]"
    exit 1
fi

if [ ! -f "$IMG_FILE" ]; then
    echo "❌ 错误: IMG文件不存在: $IMG_FILE"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "📋 配置:"
echo "  输入: $IMG_FILE"
echo "  输出: $OUTPUT_DIR/$ISO_NAME"
echo ""

# 检查必要工具
echo "🔧 检查工具..."
for tool in xorriso mkisofs cpio gzip dd mkfs.fat mount; do
    if ! command -v $tool >/dev/null 2>&1; then
        echo "❌ 缺少工具: $tool"
        exit 1
    fi
done
echo "✅ 所有必要工具已安装"

# 创建工作区
WORK_DIR="/tmp/openwrt_build_$(date +%s)"
STAGING_DIR="$WORK_DIR/staging"

cleanup() {
    echo "清理工作区..."
    # 确保卸载所有挂载点
    for mount_point in "$WORK_DIR"/*/; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            umount -l "$mount_point" 2>/dev/null || true
        fi
    done
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/{grub,isolinux},live,images}

echo "[1/8] 获取内核..."
# 使用当前系统内核
if [ -f "/boot/vmlinuz" ]; then
    cp "/boot/vmlinuz" "$STAGING_DIR/live/vmlinuz"
    echo "✅ 使用系统内核"
elif [ -f "/boot/vmlinuz-$(uname -r)" ]; then
    cp "/boot/vmlinuz-$(uname -r)" "$STAGING_DIR/live/vmlinuz"
    echo "✅ 使用内核: vmlinuz-$(uname -r)"
else
    echo "❌ 未找到内核"
    exit 1
fi

echo "[2/8] 创建initrd..."
INITRD_DIR="$WORK_DIR/initrd_root"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"

cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh
# OpenWRT安装系统init

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 创建设备节点
mknod /dev/console c 5 1
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 挂载tmpfs
mount -t tmpfs tmpfs /tmp

echo ""
echo "========================================"
echo "      OpenWRT Installation System"
echo "========================================"
echo ""

# 检查OpenWRT镜像
if [ -f "/images/openwrt.img" ]; then
    echo "✅ 找到OpenWRT镜像"
else
    echo "❌ 未找到OpenWRT镜像"
    echo "进入shell..."
    exec /bin/sh
fi

echo "输入 'install' 开始安装:"
read cmd
[ "$cmd" = "install" ] && echo "开始安装..." || exec /bin/sh
INIT_EOF
chmod +x "$INITRD_DIR/init"

# 复制busybox
if which busybox >/dev/null; then
    cp $(which busybox) "$INITRD_DIR/busybox"
    cd "$INITRD_DIR"
    for app in sh mount umount cat echo ls dd sync; do
        ln -s busybox $app 2>/dev/null || true
    done
    cd - >/dev/null
fi

# 创建设备
mkdir -p "$INITRD_DIR/dev"
mknod "$INITRD_DIR/dev/console" c 5 1 2>/dev/null || true
mknod "$INITRD_DIR/dev/null" c 1 3 2>/dev/null || true

# 打包
cd "$INITRD_DIR"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd.img"
cd - >/dev/null
rm -rf "$INITRD_DIR"

echo "✅ initrd创建完成"

echo "[3/8] 复制OpenWRT镜像..."
cp "$IMG_FILE" "$STAGING_DIR/images/openwrt.img"
echo "✅ 镜像已复制"

echo "[4/8] 创建BIOS引导配置..."
# ISOLINUX配置
cat > "$STAGING_DIR/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT linux
PROMPT 0
TIMEOUT 50
UI menu.c32

LABEL linux
  MENU LABEL Install OpenWRT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 init=/bin/sh
ISOLINUX_CFG

# 复制syslinux文件
echo "复制syslinux引导文件..."
SYSBOOT_FILES=("isolinux.bin" "ldlinux.c32" "libutil.c32" "menu.c32" "isohdpfx.bin")
for file in "${SYSBOOT_FILES[@]}"; do
    for dir in /usr/share/syslinux /usr/lib/syslinux /usr/lib/ISOLINUX; do
        if [ -f "$dir/$file" ]; then
            if [ "$file" = "isohdpfx.bin" ]; then
                cp "$dir/$file" "$WORK_DIR/isohdpfx.bin"
            else
                cp "$dir/$file" "$STAGING_DIR/boot/isolinux/"
            fi
            echo "  ✅ $file"
            break
        fi
    done
done

echo "[5/8] 创建UEFI引导配置..."
# GRUB配置
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT (UEFI)" {
    linux /live/vmlinuz console=tty0
    initrd /live/initrd.img
}

menuentry "Emergency Shell" {
    linux /live/vmlinuz console=tty0 init=/bin/sh
    initrd /live/initrd.img
}
GRUB_CFG

# 创建GRUB EFI文件
echo "创建GRUB EFI文件..."
if command -v grub-mkimage >/dev/null 2>&1; then
    grub-mkimage \
        -O x86_64-efi \
        -o "$STAGING_DIR/EFI/boot/bootx64.efi" \
        -p /boot/grub \
        fat iso9660 part_gpt part_msdos normal boot linux 2>/dev/null || \
    echo "⚠ GRUB EFI生成失败"
fi

# 如果生成了EFI文件，创建引导镜像
if [ -f "$STAGING_DIR/EFI/boot/bootx64.efi" ]; then
    echo "创建EFI引导镜像..."
    
    EFI_IMG="$WORK_DIR/efiboot.img"
    MOUNT_DIR="$WORK_DIR/efi_mount"
    
    rm -rf "$EFI_IMG" "$MOUNT_DIR"
    mkdir -p "$MOUNT_DIR"
    
    # 创建16MB的FAT32镜像
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=16 status=none 2>/dev/null
    
    # 格式化
    if mkfs.fat -F 32 -n "EFIBOOT" "$EFI_IMG" >/dev/null 2>&1; then
        echo "✅ FAT32镜像创建成功"
        
        # 挂载
        if mount -o loop "$EFI_IMG" "$MOUNT_DIR" 2>/dev/null; then
            echo "✅ 挂载成功"
            
            # 创建目录结构
            mkdir -p "$MOUNT_DIR/EFI/boot"
            
            # 复制EFI文件
            cp "$STAGING_DIR/EFI/boot/bootx64.efi" "$MOUNT_DIR/EFI/boot/"
            
            # 复制GRUB配置
            mkdir -p "$MOUNT_DIR/boot/grub"
            cp "$STAGING_DIR/boot/grub/grub.cfg" "$MOUNT_DIR/boot/grub/"
            
            # 同步并卸载
            sync
            umount "$MOUNT_DIR" 2>/dev/null
            
            # 复制到输出目录
            cp "$EFI_IMG" "$STAGING_DIR/EFI/boot/efiboot.img"
            echo "✅ EFI引导镜像创建完成"
        else
            echo "⚠ 无法挂载EFI镜像"
        fi
    else
        echo "⚠ 无法格式化EFI镜像"
    fi
    
    # 清理
    rm -rf "$MOUNT_DIR" "$EFI_IMG" 2>/dev/null || true
else
    echo "⚠ 未生成GRUB EFI文件，跳过UEFI引导"
fi

echo "[6/8] 创建标识文件..."
echo "OpenWRT Installer" > "$STAGING_DIR/.openwrt_installer"
date > "$STAGING_DIR/.build_date"

echo "[7/8] 构建ISO..."
cd "$WORK_DIR"

# 检查是否有EFI引导镜像和isohdpfx.bin
EFI_IMG_PATH="$STAGING_DIR/EFI/boot/efiboot.img"
ISOHDPFX_PATH="$WORK_DIR/isohdpfx.bin"

if [ -f "$EFI_IMG_PATH" ] && [ -f "$ISOHDPFX_PATH" ] && [ -s "$EFI_IMG_PATH" ]; then
    echo "构建混合引导ISO (BIOS + UEFI)..."
    
    xorriso -as mkisofs \
        -r \
        -V "OPENWRT_INSTALL" \
        -o "$OUTPUT_DIR/$ISO_NAME" \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr "$ISOHDPFX_PATH" \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$STAGING_DIR" 2>&1 | grep -E "written|error" || true
else
    echo "构建BIOS引导ISO..."
    
    xorriso -as mkisofs \
        -r \
        -V "OPENWRT_INSTALL" \
        -o "$OUTPUT_DIR/$ISO_NAME" \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        "$STAGING_DIR" 2>&1 | grep -E "written|error" || true
fi

echo "[8/8] 验证结果..."
if [ -f "$OUTPUT_DIR/$ISO_NAME" ]; then
    ISO_SIZE=$(du -h "$OUTPUT_DIR/$ISO_NAME" | cut -f1)
    echo ""
    echo "🎉🎉🎉 ISO构建成功! 🎉🎉🎉"
    echo ""
    echo "📊 详细信息:"
    echo "  文件: $OUTPUT_DIR/$ISO_NAME"
    echo "  大小: $ISO_SIZE"
    echo ""
    
    # 检查ISO类型
    if command -v file >/dev/null; then
        FILE_INFO=$(file "$OUTPUT_DIR/$ISO_NAME")
        echo "类型: $FILE_INFO"
        
        # 检查引导能力
        if echo "$FILE_INFO" | grep -q "bootable"; then
            echo "✅ 可引导ISO"
        fi
        
        # 检查UEFI支持
        if [ -f "$EFI_IMG_PATH" ] && [ -s "$EFI_IMG_PATH" ]; then
            echo "✅ 包含UEFI引导"
        fi
    fi
    
    # 检查ISO内容
    echo ""
    echo "📁 ISO内容摘要:"
    if command -v isoinfo >/dev/null; then
        isoinfo -f -i "$OUTPUT_DIR/$ISO_NAME" 2>/dev/null | grep -E "(vmlinuz|initrd|openwrt.img)" || true
    fi
    
    echo ""
    echo "🚀 使用方法:"
    echo "  1. 制作USB启动盘:"
    echo "     sudo dd if='$OUTPUT_DIR/$ISO_NAME' of=/dev/sdX bs=4M status=progress oflag=sync"
    echo ""
    echo "  2. 虚拟机测试:"
    echo "     qemu-system-x86_64 -cdrom '$OUTPUT_DIR/$ISO_NAME' -m 512M -boot d"
    
    exit 0
else
    echo "❌ ISO构建失败"
    echo ""
    echo "调试信息:"
    echo "STAGING_DIR内容:"
    ls -la "$STAGING_DIR" 2>/dev/null | head -20 || true
    exit 1
fi



BUILD_SCRIPT_EOF

chmod +x scripts/build-iso-alpine.sh

# ========== 构建Docker镜像 ==========
echo "🔨 构建Docker镜像..."
IMAGE_NAME="openwrt-alpine-builder:latest"

echo "构建镜像..."
docker build \
    -f "$DOCKERFILE_PATH" \
    --build-arg ALPINE_VERSION="$ALPINE_VERSION" \
    -t "$IMAGE_NAME" \
    . 2>&1 | tee /tmp/docker-build.log

if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "✅ Docker镜像构建成功: $IMAGE_NAME"
else
    echo "❌ Docker镜像构建失败"
    cat /tmp/docker-build.log | tail -20
    exit 1
fi

# ========== 运行Docker容器 ==========
echo "🚀 运行Docker容器构建ISO..."

set +e
echo "启动构建容器..."
docker run --rm \
    --name openwrt-alpine-builder \
    --privileged \
    -v "$IMG_ABS:/mnt/input.img:ro" \
    -v "$OUTPUT_ABS:/output:rw" \
    -e INPUT_IMG="/mnt/input.img" \
    "$IMAGE_NAME"

CONTAINER_EXIT=$?
set -e

echo "容器退出代码: $CONTAINER_EXIT"

# ========== 检查结果 ==========
OUTPUT_ISO="$OUTPUT_ABS/openwrt.iso"
if [ -f "$OUTPUT_ISO" ]; then
    # 重命名
    FINAL_ISO="$OUTPUT_ABS/$ISO_NAME"
    mv "$OUTPUT_ISO" "$FINAL_ISO"
    
    echo ""
    echo "🎉🎉🎉 ISO构建成功! 🎉🎉🎉"
    echo ""
    echo "📁 ISO文件: $FINAL_ISO"
    ISO_SIZE=$(du -h "$FINAL_ISO" | cut -f1)
    echo "📊 大小: $ISO_SIZE"
    echo ""
    
    # 验证ISO
    echo "🔍 验证信息:"
    if command -v file >/dev/null 2>&1; then
        FILE_INFO=$(file "$FINAL_ISO")
        echo "文件类型: $FILE_INFO"
        
        if echo "$FILE_INFO" | grep -q "bootable\|DOS/MBR"; then
            echo "✅ ISO可引导"
        fi
    fi
    
    # 检查是否为混合ISO
    echo ""
    echo "💻 引导支持:"
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -indev "$FINAL_ISO" -check_media 2>&1 | grep -i "efi\|uefi" && \
            echo "✅ 支持UEFI引导" || echo "⚠ 仅支持BIOS引导"
    fi
    
    echo ""
    echo "🚀 使用方法:"
    echo "   1. 虚拟机测试: qemu-system-x86_64 -cdrom '$FINAL_ISO' -m 512M"
    echo "   2. 制作USB: sudo dd if='$FINAL_ISO' of=/dev/sdX bs=4M status=progress oflag=sync"
    echo "   3. 直接引导: 从USB或CD/DVD启动"
    
    exit 0
else
    echo ""
    echo "❌ ISO构建失败"
    
    # 显示容器日志
    echo "📋 容器日志:"
    docker logs --tail 100 openwrt-alpine-builder 2>/dev/null || echo "无法获取容器日志"
    
    exit 1
fi
