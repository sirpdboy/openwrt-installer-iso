#!/bin/bash
# dockerrun.sh - 简化版
set -e

INPUT_IMG="${1:-/mnt/openwrt.img}"
OUTPUT_DIR="${2:-/output}"
ISO_NAME="${3:-openwrt-autoinstall.iso}"

echo "Building OpenWRT ISO..."
echo "Input: $INPUT_IMG"
echo "Output: $OUTPUT_DIR/$ISO_NAME"

# 检查Docker
if ! command -v docker &> /dev/null; then
    echo "Error: Docker not found"
    exit 1
fi

# 创建目录
mkdir -p "$OUTPUT_DIR"

# 使用已安装所有依赖的Debian镜像直接运行
docker run --rm --privileged \
    -v "$INPUT_IMG:/mnt/ezopwrt.img:ro" \
    -v "$OUTPUT_DIR:/output" \
    debian:buster-slim \
    bash -c "
    # 配置非交互模式
    export DEBIAN_FRONTEND=noninteractive
    
    # 配置源（非交互式）
    echo 'deb http://archive.debian.org/debian buster main' > /etc/apt/sources.list
    echo 'deb http://archive.debian.org/debian-security buster/updates main' >> /etc/apt/sources.list
    echo 'Acquire::Check-Valid-Until \"false\";' > /etc/apt/apt.conf.d/99no-check
    
    # 更新和安装（非交互式）
    apt-get update -yq
    apt-get install -yq --no-install-recommends \
        debootstrap \
        squashfs-tools \
        xorriso \
        isolinux \
        syslinux \
        grub-pc-bin \
        mtools \
        dosfstools \
        parted \
        wget
    
    # 复制构建脚本并执行
    cat > /tmp/build.sh << 'BUILD_EOF'
$(cat build.sh)
BUILD_EOF
    
    chmod +x /tmp/build.sh
    INPUT_IMG='/mnt/ezopwrt.img' OUTPUT_DIR='/output' ISO_NAME='$ISO_NAME' /tmp/build.sh
    "

# 检查结果
if [ -f "$OUTPUT_DIR/$ISO_NAME" ]; then
    echo "✅ Success! ISO created: $OUTPUT_DIR/$ISO_NAME"
    ls -lh "$OUTPUT_DIR/$ISO_NAME"
else
    echo "❌ Failed to create ISO"
    exit 1
fi
