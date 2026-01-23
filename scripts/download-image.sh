#!/bin/bash
# download-image.sh - 下载OpenWRT镜像

set -euo pipefail

REPO="sirpdboy/openwrt"
ASSETS_DIR="assets"
OUTPUT_FILE="${ASSETS_DIR}/ezopwrt.img.gz"

# 获取最新tag
echo "获取最新版本..."
TAG=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | \
      jq -r '.tag_name // empty')

if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
    TAG=$(curl -sL "https://api.github.com/repos/$REPO/tags" | \
          jq -r '.[0].name // empty')
fi

if [ -z "$TAG" ]; then
    echo "错误: 无法获取版本信息"
    exit 1
fi

echo "最新版本: $TAG"

# 获取下载URL
echo "获取下载链接..."
DOWNLOAD_URLS=$(curl -sL "https://api.github.com/repos/$REPO/releases/tags/$TAG" | \
                jq -r '.assets[] | select(.name | endswith("img.gz")) | .browser_download_url')

if [ -z "$DOWNLOAD_URLS" ]; then
    echo "错误: 未找到镜像文件"
    exit 1
fi

FIRST_URL=$(echo "$DOWNLOAD_URLS" | head -n1)
echo "下载: $FIRST_URL"

# 创建目录
mkdir -p "$ASSETS_DIR"

# 下载
curl -L -o "$OUTPUT_FILE" \
     --progress-bar \
     --retry 3 \
     "$FIRST_URL"

if [ $? -eq 0 ]; then
    echo "✅ 下载完成"
    
    # 解压
    echo "解压镜像..."
    gzip -d "$OUTPUT_FILE"

    ls -lh "${ASSETS_DIR}
    # 重命名
    # mv "${OUTPUT_FILE%.*}" "${ASSETS_DIR}/ezopwrt.img" || true
    
    echo "✅ 镜像准备完成: ${ASSETS_DIR}/ezopwrt.img"
    ls -lh "${ASSETS_DIR}/ezopwrt.img"
else
    echo "❌ 下载失败"
    exit 1
fi
