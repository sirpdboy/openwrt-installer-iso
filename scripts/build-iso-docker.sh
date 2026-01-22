#!/bin/bash
set -euo pipefail

# 容器内构建脚本

# 配置
ISO_NAME="ezopwrt-installer"
BUILD_DIR="/tmp/build"
STAGING_DIR="$BUILD_DIR/staging"
OUTPUT_DIR="/output"
ASSET_IMG="/mnt/ezopwrt.img"

# 创建目录
mkdir -p "$BUILD_DIR" "$STAGING_DIR" "$OUTPUT_DIR"
mkdir -p "$STAGING_DIR"/{isolinux,boot/grub,live}

# 复制OpenWRT镜像
if [ -f "$ASSET_IMG" ]; then
    cp "$ASSET_IMG" "$STAGING_DIR/live/ezopwrt.img"
    echo "✅ 复制镜像完成: $(ls -lh "$STAGING_DIR/live/ezopwrt.img")"
else
    echo "❌ 错误: 找不到镜像文件 $ASSET_IMG"
    exit 1
fi

# 创建最小initrd
echo "创建initrd..."
mkdir -p /tmp/initrd
cd /tmp/initrd

cat > init << 'EOF'
#!/bin/sh
# 最简init脚本
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "=== EzOpWrt Installer ==="
echo ""

# 安装逻辑
install_wrt() {
    echo "可用磁盘:"
    echo "----------------"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME"
    echo "----------------"
    echo ""
    
    echo -n "输入目标磁盘(如:sda): " && read DISK
    [ -z "$DISK" ] && echo "无效输入" && return 1
    
    echo -n "确认安装到 /dev/$DISK? (yes/no): " && read CONFIRM
    [ "$CONFIRM" != "yes" ] && echo "取消" && return 1
    
    echo "安装中..."
    if dd if=/mnt/live/ezopwrt.img of=/dev/$DISK bs=4M status=progress; then
        sync
        echo "安装完成! 重启中..."
        sleep 3
        reboot -f
    else
        echo "安装失败"
        return 1
    fi
}

# 主循环
while true; do
    echo "1) 安装EzOpWrt"
    echo "2) Shell"
    echo "3) 重启"
    echo -n "选择: " && read CHOICE
    
    case "$CHOICE" in
        1) install_wrt ;;
        2) exec /bin/sh ;;
        3) reboot -f ;;
        *) echo "无效选择" ;;
    esac
done
EOF

chmod +x init

# 打包initrd
find . | cpio -H newc -o | gzip -9 > "$STAGING_DIR/live/initrd.img"
cd -

# 获取内核（使用容器内的内核）
if [ -f "/boot/vmlinuz" ]; then
    cp /boot/vmlinuz "$STAGING_DIR/live/vmlinuz"
else
    # 尝试其他位置
    cp /vmlinuz "$STAGING_DIR/live/vmlinuz" 2>/dev/null || \
    cp "$(find /boot -name 'vmlinuz*' | head -1)" "$STAGING_DIR/live/vmlinuz" 2>/dev/null || \
    (echo "❌ 找不到内核文件" && exit 1)
fi

# 创建引导配置
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'EOF'
DEFAULT linux
TIMEOUT 100
PROMPT 0
LABEL linux
  MENU LABEL Install EzOpWrt
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 quiet
LABEL shell
  MENU LABEL Debug Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0
EOF

# 复制引导文件
cp /usr/lib/ISOLINUX/isolinux.bin "$STAGING_DIR/isolinux/"
cp /usr/lib/syslinux/modules/bios/*.c32 "$STAGING_DIR/isolinux/" 2>/dev/null || true

# 创建ISO
echo "创建ISO..."
xorriso -as mkisofs \
    -o "$OUTPUT_DIR/$ISO_NAME.iso" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    "$STAGING_DIR"

echo "✅ ISO创建完成: $OUTPUT_DIR/$ISO_NAME.iso"
echo "文件信息:"
ls -lh "$OUTPUT_DIR/$ISO_NAME.iso"
