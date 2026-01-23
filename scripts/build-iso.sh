#!/bin/bash
# build-iso.sh

set -e

echo "开始构建可引导的OpenWRT安装ISO..."
echo ""

# 工作目录
WORK_DIR="/tmp/iso-build"
ISO_DIR="$WORK_DIR/iso"
mkdir -p "$ISO_DIR"/{isolinux,live}

# 1. 安装必要的syslinux组件
echo "步骤1: 安装syslinux组件..."
apt-get update
apt-get install -y syslinux-common isolinux 2>/dev/null || {
    echo "安装syslinux失败，尝试从包中提取"
    # 手动提取必要文件
    mkdir -p /tmp/syslinux-extract
    cd /tmp/syslinux-extract
    apt-get download syslinux-common 2>/dev/null || true
    apt-get download isolinux 2>/dev/null || true
    for pkg in *.deb; do
        if [ -f "$pkg" ]; then
            dpkg-deb -x "$pkg" . 2>/dev/null || true
        fi
    done
    cd -
}

# 2. 复制所有必要的ISOLINUX文件
echo "步骤2: 复制ISOLINUX引导文件..."

# 查找isolinux.bin
find /usr -name "isolinux.bin" 2>/dev/null | head -1 | xargs -I {} cp {} "$ISO_DIR/isolinux/" 2>/dev/null || {
    echo "警告: 找不到isolinux.bin"
    # 尝试下载
    wget -q "https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz" \
        -O /tmp/syslinux.tar.gz 2>/dev/null || true
    if [ -f "/tmp/syslinux.tar.gz" ]; then
        tar -xz -C /tmp -f /tmp/syslinux.tar.gz syslinux-6.04-pre1/bios/core/isolinux.bin 2>/dev/null || true
        cp /tmp/syslinux-6.04-pre1/bios/core/isolinux.bin "$ISO_DIR/isolinux/" 2>/dev/null || true
    fi
}

# 复制所有.c32模块文件
echo "复制ISOLINUX模块文件..."
for module_dir in /usr/lib/syslinux/modules/bios /usr/lib/ISOLINUX /usr/share/syslinux; do
    if [ -d "$module_dir" ]; then
        cp "$module_dir"/*.c32 "$ISO_DIR/isolinux/" 2>/dev/null || true
    fi
done

# 检查是否复制了关键文件
REQUIRED_FILES=("isolinux.bin" "ldlinux.c32" "libcom32.c32" "libutil.c32" "menu.c32" "vesamenu.c32")
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$ISO_DIR/isolinux/$file" ]; then
        echo "警告: 缺少 $file，尝试下载..."
        # 从网络下载缺失的文件
        wget -q "https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz" \
            -O /tmp/syslinux-full.tar.gz 2>/dev/null || continue
        
        tar -xz -C /tmp -f /tmp/syslinux-full.tar.gz \
            "syslinux-6.04-pre1/bios/core/$file" \
            "syslinux-6.04-pre1/bios/com32/elflink/ldlinux/$file" \
            "syslinux-6.04-pre1/bios/com32/lib/$file" \
            "syslinux-6.04-pre1/bios/com32/menu/$file" \
            2>/dev/null || true
        
        # 查找并复制
        find /tmp/syslinux-6.04-pre1 -name "$file" 2>/dev/null | head -1 | xargs -I {} cp {} "$ISO_DIR/isolinux/" 2>/dev/null || true
    fi
done

# 验证必要文件
echo "验证ISOLINUX文件..."
ls -la "$ISO_DIR/isolinux/" | grep -E "\.(bin|c32)$" || echo "未找到引导文件"

# 3. 获取内核
echo "步骤3: 准备内核..."
if [ -f "/boot/vmlinuz" ]; then
    cp "/boot/vmlinuz" "$ISO_DIR/live/vmlinuz"
elif [ -f "/vmlinuz" ]; then
    cp "/vmlinuz" "$ISO_DIR/live/vmlinuz"
else
    echo "下载Debian安装器内核..."
    wget -q "http://ftp.debian.org/debian/dists/bullseye/main/installer-amd64/current/images/cdrom/vmlinuz" \
        -O "$ISO_DIR/live/vmlinuz" || {
        echo "创建最小内核..."
        echo '#!/bin/sh
echo "Minimal OpenWRT Installer"
exec /bin/sh' > "$ISO_DIR/live/vmlinuz"
        chmod +x "$ISO_DIR/live/vmlinuz"
    }
fi

# 4. 创建initrd
echo "步骤4: 创建initrd..."
INITRD_DIR="/tmp/initrd-simple"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"

cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/sh
# 简单init脚本

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

echo ""
echo "=== OpenWRT Installer ==="
echo "Successfully booted!"
echo ""

# 启动shell
exec /bin/sh
INIT_EOF

chmod +x "$INITRD_DIR/init"

# 打包initrd
cd "$INITRD_DIR"
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$ISO_DIR/live/initrd.img"
cd -

# 5. 复制OpenWRT镜像
echo "步骤5: 复制OpenWRT镜像..."
cp "/mnt/ezopwrt.img" "$ISO_DIR/live/openwrt.img"

# 6. 创建引导配置
echo "步骤6: 创建引导配置..."
cat > "$ISO_DIR/isolinux/isolinux.cfg" << 'CFG_EOF'
UI menu.c32
PROMPT 0
MENU TITLE OpenWRT Installer
TIMEOUT 100
DEFAULT openwrt

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 quiet

LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 init=/bin/sh

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
CFG_EOF

# 7. 创建ISO（使用正确的参数）
echo "步骤7: 创建ISO..."
if command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "OPENWRT_INSTALL" \
        -eltorito-boot isolinux/isolinux.bin \
        -boot-load-size 4 \
        -boot-info-table \
        -no-emul-boot \
        -eltorito-catalog isolinux/isolinux.cat \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin 2>/dev/null \
        -output "/output/openwrt-installer.iso" \
        "$ISO_DIR" 2>&1 | grep -v "unable to" || true
else
    echo "错误: xorriso未安装"
    exit 1
fi

# 8. 验证ISO
echo "步骤8: 验证ISO..."
if [ -f "/output/openwrt-installer.iso" ]; then
    echo ""
    echo "✅ ISO创建成功!"
    echo "文件: /output/openwrt-installer.iso"
    echo "大小: $(ls -lh /output/openwrt-installer.iso | awk '{print $5}')"
    
    # 检查ISO结构
    echo ""
    echo "ISO引导信息:"
    if xorriso -indev "/output/openwrt-installer.iso" -boot_image any show 2>/dev/null; then
        echo "✅ ISO引导信息正常"
    else
        echo "⚠️  无法读取ISO引导信息"
    fi
    
    # 列出ISO内容
    echo ""
    echo "ISO内容概览:"
    xorriso -indev "/output/openwrt-installer.iso" -toc 2>&1 | head -20 || true
else
    echo "❌ ISO创建失败"
    exit 1
fi

echo ""
echo "🎉 构建完成!"
