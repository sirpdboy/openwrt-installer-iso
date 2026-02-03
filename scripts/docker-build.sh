#!/bin/bash
# build-using-debian-cd.sh - 使用Debian CD工具
set -e

echo "使用Debian CD工具构建可引导ISO..."

OUTDIR="$2"
ISOFILE="$3"

# 安装必要工具
apt-get update
apt-get install -y debian-cd xorriso syslinux isolinux

# 创建最小内容
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/iso/boot/isolinux"

# 复制引导文件
cp /usr/lib/ISOLINUX/isolinux.bin "$TMPDIR/iso/boot/isolinux/"
cp /usr/lib/syslinux/modules/bios/*.c32 "$TMPDIR/iso/boot/isolinux/" 2>/dev/null || true

# 创建配置
cat > "$TMPDIR/iso/boot/isolinux/isolinux.cfg" << 'EOF'
DEFAULT linux
PROMPT 0
TIMEOUT 50
UI menu.c32

LABEL linux
  MENU LABEL Boot Test
  SAY Booting...
EOF

touch "$TMPDIR/iso/boot/isolinux/boot.cat"

# 使用debian-cd工具构建
cd "$TMPDIR"
build-simple-cdd --force --dist stable --locale en_US.UTF-8 \
    --profiles "iso" --debug --dvd "$ISOFILE"

# 如果失败，使用fallback
if [ ! -f "$ISOFILE" ]; then
    genisoimage -o "$OUTDIR/$ISOFILE" \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -V "BOOTABLE" \
        "$TMPDIR/iso"
fi

echo "ISO创建: $OUTDIR/$ISOFILE"
