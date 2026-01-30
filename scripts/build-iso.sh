#!/bin/bash
set -e

# 接收参数
IMG_FILE_URL="${1}"
OUTPUT_NAME="${2}"
ALPINE_VERSION="${3:-3.20}"

echo "================================================"
echo "  OpenWRT ISO Builder - Alpine Based"
echo "================================================"
echo ""
echo "参数:"
echo "  IMG文件URL: $IMG_FILE_URL"
echo "  输出名称: $OUTPUT_NAME"
echo "  Alpine版本: $ALPINE_VERSION"
echo ""

# 设置工作目录
WORKDIR="/tmp/openwrt-builder"
OUTPUT_DIR="/output"

# 清理并创建目录
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
mkdir -p "$OUTPUT_DIR"

cd "$WORKDIR"
echo "工作目录: $WORKDIR"

# 克隆 aports 仓库
echo "克隆 aports 仓库..."
if ! git clone --depth 1 --branch "$ALPINE_VERSION-stable" \
    https://gitlab.alpinelinux.org/alpine/aports.git; then
    echo "⚠️  分支 v$ALPINE_VERSION 不存在，使用默认分支"
    git clone --depth 1 https://gitlab.alpinelinux.org/alpine/aports.git
fi

cd aports

# 验证mkimage脚本存在
if [ ! -f "scripts/mkimage.sh" ]; then
    echo "❌ 错误: scripts/mkimage.sh 不存在"
    exit 1
fi

echo "✅ 找到 mkimage.sh"

# 创建自定义的OpenWRT安装profile
echo "创建OpenWRT安装profile..."

# 创建profile目录
mkdir -p "scripts/"

# 1. 创建profile文件
cat > scripts/mkimg.openwrt.sh << 'PROFILEEOF'
#!/bin/sh

profile_openwrt() {
    # 继承标准profile
    profile_standard
    
    # 设置内核参数
    kernel_cmdline="console=tty0 console=ttyS0,115200"
    syslinux_serial="0 115200"
    
    # 添加必要的软件包
    apks="$apks openrc openssh chrony hdparm e2fsprogs sfdisk parted"
    apks="$apks wget curl gzip lsblk util-linux coreutils"
    
    # 添加内核包
    for _k in $kernel_flavors; do
        apks="$apks linux-$_k"
    done
    apks="$apks linux-firmware"
    
    # 设置overlay脚本
    apkovl="genapkovl-openwrt.sh"
}
PROFILEEOF

# 2. 创建独立的overlay生成脚本
cat > scripts/genapkovl-openwrt.sh << 'OVERLAYEOF'
#!/bin/sh

set -e

# 创建临时目录
tmp="${ROOT}/tmp/overlay"
mkdir -p "$tmp"
mkdir -p "$tmp"/etc
mkdir -p "$tmp"/usr/local/bin
mkdir -p "$tmp"/root
mkdir -p "$tmp"/etc/init.d

# 创建欢迎信息
cat > "$tmp"/etc/issue << 'EOF'
========================================
      OpenWRT Alpine Installer
========================================

系统启动后:
1. 登录: root (无需密码)
2. 运行: openwrt-installer
3. 按照提示安装OpenWRT

EOF

# 创建安装脚本
cat > "$tmp"/usr/local/bin/openwrt-installer << 'EOF'
#!/bin/sh

set -e

echo ""
echo "========================================"
echo "      OpenWRT 安装程序"
echo "========================================"
echo ""

# 默认IMG URL
DEFAULT_IMG_URL="__IMG_FILE_URL__"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 显示当前磁盘
echo "${BLUE}=== 当前磁盘信息 ===${NC}"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL

echo ""
echo "${YELLOW}警告: 此操作将覆盖所选磁盘上的所有数据！${NC}"
echo ""

# 选择磁盘
while true; do
    read -p "请输入要安装OpenWRT的磁盘(如: sda, nvme0n1): " DISK
    
    if [ -z "$DISK" ]; then
        echo "${RED}磁盘名称不能为空${NC}"
        continue
    fi
    
    if [ ! -b "/dev/$DISK" ]; then
        echo "${RED}错误: /dev/$DISK 不存在或不是块设备${NC}"
        continue
    fi
    
    # 确认选择
    echo ""
    echo "您选择了: /dev/$DISK"
    echo "磁盘信息:"
    fdisk -l "/dev/$DISK" | head -20
    echo ""
    
    read -p "确认在此磁盘安装OpenWRT？(y/N): " CONFIRM
    case "$CONFIRM" in
        [yY][eE][sS]|[yY])
            break
            ;;
        *)
            echo "重新选择..."
            continue
            ;;
    esac
done

# 下载IMG文件
echo ""
echo "${BLUE}=== 下载OpenWRT镜像 ===${NC}"

IMG_URL="$DEFAULT_IMG_URL"
read -p "输入OpenWRT镜像URL [默认: $IMG_URL]: " USER_IMG_URL
[ -n "$USER_IMG_URL" ] && IMG_URL="$USER_IMG_URL"

echo "下载: $IMG_URL"

# 创建临时目录
TEMP_DIR="/tmp/openwrt_install"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

# 下载文件
if echo "$IMG_URL" | grep -q "\.gz$"; then
    FILENAME="openwrt.img.gz"
else
    FILENAME="openwrt.img"
fi

echo "开始下载..."
wget -O "$FILENAME" "$IMG_URL" || {
    echo "${RED}下载失败${NC}"
    exit 1
}

# 解压（如果是压缩文件）
if echo "$FILENAME" | grep -q "\.gz$"; then
    echo "解压镜像..."
    gzip -d "$FILENAME"
    IMG_FILE="openwrt.img"
else
    IMG_FILE="$FILENAME"
fi

# 验证IMG文件
if [ ! -f "$IMG_FILE" ]; then
    echo "${RED}错误: IMG文件不存在${NC}"
    exit 1
fi

IMG_SIZE=$(stat -c%s "$IMG_FILE")
echo "镜像大小: $((IMG_SIZE / 1024 / 1024)) MB"

# 最后确认
echo ""
echo "${RED}⚠️  ⚠️  ⚠️  最终警告 ⚠️  ⚠️  ⚠️${NC}"
echo "即将覆盖 /dev/$DISK 上的所有数据！"
echo ""
read -p "输入 'YES' 继续安装: " FINAL_CONFIRM
if [ "$FINAL_CONFIRM" != "YES" ]; then
    echo "安装取消"
    exit 0
fi

# 开始写入
echo ""
echo "${GREEN}=== 开始写入磁盘 ===${NC}"

# 卸载所有相关分区
for part in /dev/${DISK}*; do
    if mount | grep -q "^$part"; then
        umount "$part" 2>/dev/null || true
    fi
done

# 使用dd写入镜像
echo "写入镜像到 /dev/$DISK ..."
dd if="$IMG_FILE" of="/dev/$DISK" bs=4M status=progress oflag=sync

# 同步磁盘
sync

echo ""
echo "${GREEN}✅ OpenWRT 安装完成！${NC}"
echo ""
echo "下一步:"
echo "1. 关机: poweroff"
echo "2. 移除安装介质"
echo "3. 从硬盘启动OpenWRT"
echo ""

# 清理
cd /
rm -rf "$TEMP_DIR"
EOF

# 设置执行权限
chmod +x "$tmp/usr/local/bin/openwrt-installer"

# 替换占位符
sed -i "s|__IMG_FILE_URL__|${IMG_FILE_URL}|g" "$tmp/usr/local/bin/openwrt-installer"
sed -i "s|__ALPINE_VERSION__|${ALPINE_VERSION}|g" "$tmp/etc/issue"

# 创建motd
cat > "$tmp"/etc/motd << 'EOF'

========================================
OpenWRT Alpine 安装环境
========================================

运行以下命令开始安装:
    openwrt-installer

========================================

EOF

# 设置SSH配置
mkdir -p "$tmp"/etc/ssh
cat > "$tmp"/etc/ssh/sshd_config << 'EOF'
PermitRootLogin yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
PrintMotd yes
Subsystem sftp /usr/lib/ssh/sftp-server
EOF

# 创建开机自启动脚本（可选）
cat > "$tmp"/etc/init.d/installer-prompter << 'EOF'
#!/sbin/openrc-run

name="installer_prompter"
description="Prompts user to run OpenWRT installer"

start() {
    ebegin "Starting installer prompter"
    if [ -f /usr/local/bin/openwrt-installer ] && [ ! -f /tmp/installer-run ]; then
        echo ""
        echo "========================================"
        echo "提示: 运行 'openwrt-installer' 开始安装OpenWRT"
        echo "========================================"
        echo ""
        touch /tmp/installer-run
    fi
    eend $?
}
EOF

chmod +x "$tmp"/etc/init.d/installer-prompter

# 打包overlay
( cd "$tmp" && tar -c -f "${ROOT}"/tmp/overlay.tar . )
OVERLAYEOF

# 设置执行权限
chmod +x scripts/mkimg.openwrt.sh
chmod +x scripts/genapkovl-openwrt.sh

echo "✅ Profile创建完成"

# 2. 构建ISO
echo ""
echo "开始构建ISO..."

# 构建ISO（支持BIOS和UEFI）
echo "运行mkimage.sh命令..."

# 方法1: 尝试使用系统主机密钥（如果存在）
echo "尝试使用--hostkeys参数..."
./scripts/mkimage.sh \
    --tag "$ALPINE_VERSION" \
    --outdir "$OUTPUT_DIR" \
    --arch x86_64 \
    --repository "http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/main" \
    --repository "http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/community" \
    --profile openwrt \
    --hostkeys 2>&1 || {
    
    echo "⚠️ 使用--hostkeys失败，尝试不使用--hostkeys..."
    
    # 方法2: 不使用hostkeys参数
    ./scripts/mkimage.sh \
        --tag "$ALPINE_VERSION" \
        --outdir "$OUTPUT_DIR" \
        --arch x86_64 \
        --repository "http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/main" \
        --repository "http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/community" \
        --profile openwrt 2>&1
}

# 检查结果
ISO_FILE=$(find "$OUTPUT_DIR" -name "*.iso" -type f | head -1)

if [ -n "$ISO_FILE" ] && [ -f "$ISO_FILE" ]; then
    echo ""
    echo "✅ ISO 构建成功!"
    echo "原始文件: $(basename "$ISO_FILE")"
    echo "大小: $(du -h "$ISO_FILE" | cut -f1)"
    
    # 重命名ISO文件
    FINAL_ISO="$OUTPUT_DIR/${OUTPUT_NAME}-v${ALPINE_VERSION}-$(date +%Y%m%d).iso"
    mv "$ISO_FILE" "$FINAL_ISO"
    
    echo "重命名为: $(basename "$FINAL_ISO")"
    
    # 显示ISO信息
    echo ""
    echo "ISO详细信息:"
    if command -v file >/dev/null 2>&1; then
        file "$FINAL_ISO"
    fi
    
    if command -v xorriso >/dev/null 2>&1; then
        echo ""
        echo "引导信息:"
        xorriso -indev "$FINAL_ISO" -toc 2>/dev/null | grep -E "(Bootable|Mbr|El-Torito|UEFI)" || true
    fi
    
    echo ""
    echo "🎉 构建完成!"
    echo "输出文件: $FINAL_ISO"
else
    echo "❌ ISO 构建失败 - 没有生成ISO文件"
    echo "检查输出目录: $OUTPUT_DIR"
    ls -la "$OUTPUT_DIR/"
    
    # 显示调试信息
    echo ""
    echo "调试信息:"
    echo "当前目录: $(pwd)"
    echo "目录内容:"
    ls -la
    echo ""
    echo "scripts目录内容:"
    ls -la scripts/
    
    exit 1
fi
