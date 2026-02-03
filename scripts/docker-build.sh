#!/bin/bash
# build-minimal-bootable.sh - 最小可引导ISO
set -e

echo "=== 构建最小可引导ISO ==="

OUTPUT_DIR="$2"
ISO_NAME="$3"

# 创建最简单但可引导的ISO
WORK_DIR=$(mktemp -d)
ISO_DIR="${WORK_DIR}/iso"
mkdir -p "${ISO_DIR}/boot/isolinux"

echo "1. 创建最基本的内容..."
echo "test file" > "${ISO_DIR}/README.txt"

echo "2. 获取引导文件..."
# 使用绝对可靠的引导文件
if [ -f "/usr/lib/ISOLINUX/isolinux.bin" ]; then
    cp /usr/lib/ISOLINUX/isolinux.bin "${ISO_DIR}/boot/isolinux/"
    cp /usr/lib/ISOLINUX/isohdpfx.bin "${WORK_DIR}/"
elif [ -f "/usr/lib/syslinux/isolinux.bin" ]; then
    cp /usr/lib/syslinux/isolinux.bin "${ISO_DIR}/boot/isolinux/"
    # 获取isohdpfx.bin
    if [ -f "/usr/lib/syslinux/isohdpfx.bin" ]; then
        cp /usr/lib/syslinux/isohdpfx.bin "${WORK_DIR}/"
    fi
else
    echo "❌ 找不到isolinux.bin，尝试安装syslinux"
    apt-get update && apt-get install -y syslinux isolinux 2>/dev/null || true
fi

# 确保有引导文件
if [ ! -f "${ISO_DIR}/boot/isolinux/isolinux.bin" ]; then
    echo "❌ 无法获取isolinux.bin"
    exit 1
fi

echo "3. 创建引导配置..."
cat > "${ISO_DIR}/boot/isolinux/isolinux.cfg" << 'CFG'
DEFAULT linux
PROMPT 0
TIMEOUT 1
SERIAL 0 115200

LABEL linux
  SAY Booting OpenWRT Installer...
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=ttyS0 console=tty0
CFG

touch "${ISO_DIR}/boot/isolinux/boot.cat"

echo "4. 添加一个简单的内核和initrd（如果可用）..."
# 尝试从当前系统复制
if [ -f "/boot/vmlinuz" ]; then
    cp /boot/vmlinuz "${ISO_DIR}/boot/vmlinuz" 2>/dev/null || true
fi
if [ -f "/boot/initrd.img" ]; then
    cp /boot/initrd.img "${ISO_DIR}/boot/initrd.img" 2>/dev/null || true
fi

echo "5. 构建ISO..."
cd "${WORK_DIR}"

# 方法1: 使用xorriso（推荐）
if command -v xorriso >/dev/null 2>&1; then
    echo "  使用xorriso构建..."
    
    xorriso -as mkisofs \
        -iso-level 3 \
        -volid "BOOT_TEST" \
        -eltorito-boot boot/isolinux/isolinux.bin \
        -eltorito-catalog boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        "${ISO_DIR}"
fi

# 方法2: 如果xorriso失败，使用mkisofs
if [ ! -f "${OUTPUT_DIR}/${ISO_NAME}" ] && command -v mkisofs >/dev/null 2>&1; then
    echo "  使用mkisofs构建..."
    
    mkisofs \
        -o "${OUTPUT_DIR}/${ISO_NAME}" \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -V "BOOT_TEST" \
        "${ISO_DIR}"
fi

echo "6. 验证..."
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo "✅ ISO创建成功: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "   大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    
    # 检查引导
    echo "   引导信息:"
    if command -v isoinfo >/dev/null 2>&1; then
        isoinfo -d -i "${OUTPUT_DIR}/${ISO_NAME}" 2>/dev/null | grep -E "(Volume|El Torito)" || true
    fi
    
    # 检查前440字节（MBR引导代码）
    echo "   MBR引导代码:"
    dd if="${OUTPUT_DIR}/${ISO_NAME}" bs=1 count=440 2>/dev/null | hexdump -C | head -5
    
else
    echo "❌ ISO创建失败"
fi

rm -rf "${WORK_DIR}"
