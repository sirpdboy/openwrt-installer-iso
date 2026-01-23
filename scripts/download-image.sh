#!/bin/bash
# download-image-simple.sh - 极简版

set -e

REPO="sirpdboy/openwrt"
ASSETS_DIR="assets"
FINAL_IMG="${ASSETS_DIR}/ezopwrt.img"

echo "开始下载 EzOpWrt 镜像..."
echo ""

# 创建目录
mkdir -p "$ASSETS_DIR"

# 清理旧文件
rm -f "$FINAL_IMG" 2>/dev/null || true

# 1. 获取最新tag
echo "步骤1: 获取最新版本..."
TAG=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | \
      grep -o '"tag_name": *"[^"]*"' | \
      head -1 | \
      cut -d'"' -f4)

if [ -z "$TAG" ]; then
    TAG=$(curl -sL "https://api.github.com/repos/$REPO/tags" | \
          grep -o '"name": *"[^"]*"' | \
          head -1 | \
          cut -d'"' -f4)
fi

if [ -z "$TAG" ]; then
    echo "错误: 无法获取版本"
    exit 1
fi

echo "✅ 版本: $TAG"

# 2. 获取下载URL
echo ""
echo "步骤2: 获取下载链接..."
URL=$(curl -sL "https://api.github.com/repos/$REPO/releases/tags/$TAG" | \
      grep -o '"browser_download_url": *"[^"]*\.img\.gz[^"]*"' | \
      head -1 | \
      cut -d'"' -f4)

if [ -z "$URL" ]; then
    echo "错误: 未找到下载链接"
    exit 1
fi

echo "✅ 下载链接获取成功"

# 3. 下载
echo ""
echo "步骤3: 下载镜像..."
TEMP_GZ="/tmp/ezopwrt-${TAG}.img.gz"

if curl -L -o "$TEMP_GZ" --progress-bar "$URL"; then
    echo "✅ 下载完成"
else
    echo "错误: 下载失败"
    exit 1
fi

# 4. 解压
echo ""
echo "步骤4: 解压镜像..."
if gzip -dc "$TEMP_GZ" > "$FINAL_IMG"; then
    echo "✅ 解压完成"
    rm -f "$TEMP_GZ"
else
    echo "错误: 解压失败"
    rm -f "$TEMP_GZ" "$FINAL_IMG"
    exit 1
fi

# 5. 验证
echo ""
echo "步骤5: 验证文件..."
if [ -f "$FINAL_IMG" ]; then
    SIZE=$(stat -c%s "$FINAL_IMG" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt 10485760 ]; then  # 10MB
        echo "✅ 镜像验证通过"
        echo ""
        echo "========================================"
        echo "下载完成！"
        echo "========================================"
        echo "文件: $FINAL_IMG"
        echo "大小: $((SIZE/1024/1024))MB"
        echo "版本: $TAG"
        echo ""
        ls -lh "$FINAL_IMG"
    else
        echo "错误: 镜像文件过小"
        exit 1
    fi
else
    echo "错误: 文件不存在"
    exit 1
fi
