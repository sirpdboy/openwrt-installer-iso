#!/bin/bash
# build-bootable-iso.sh - 构建可引导的BIOS+UEFI ISO
set -e

echo "=== 构建可引导的OpenWRT安装ISO ==="
echo "======================================"

OUTPUT_DIR="$2"
ISO_NAME="$3"

# 使用固定版本确保稳定性
TINYCORE_VERSION="11.x"
ARCH="x86_64"
TC_MIRROR="http://tinycorelinux.net/${TINYCORE_VERSION}/${ARCH}"

# 工作目录
WORK_DIR="/tmp/iso-build-$(date +%s)"
ISO_DIR="${WORK_DIR}/iso"
mkdir -p "${ISO_DIR}"
mkdir -p "${OUTPUT_DIR}"

echo "工作目录: ${WORK_DIR}"
echo "输出文件: ${OUTPUT_DIR}/${ISO_NAME}"

# ================= 第一步：创建目录结构 =================
echo "1. 创建目录结构..."
mkdir -p "${ISO_DIR}/boot/grub"
mkdir -p "${ISO_DIR}/boot/isolinux"
mkdir -p "${ISO_DIR}/efi/boot"
mkdir -p "${ISO_DIR}/live"

# ================= 第二步：下载Tiny Core核心文件 =================
echo "2. 下载Tiny Core Linux核心文件..."

download_with_fallback() {
    local url="$1"
    local output="$2"
    
    # 尝试下载
    if wget -q --tries=2 --timeout=30 -O "$output" "$url"; then
        return 0
    fi
    
    # 备选URL
    local alt_url="${url/11.x/10.x}"
    if wget -q --tries=1 --timeout=20 -O "$output" "$alt_url"; then
        echo "  使用备选URL下载成功"
        return 0
    fi
    
    return 1
}

echo "  下载内核..."
if ! download_with_fallback "${TC_MIRROR}/release/distribution_files/vmlinuz64" \
    "${ISO_DIR}/boot/vmlinuz64"; then
    echo "❌ 内核下载失败"
    exit 1
fi

echo "  下载initrd..."
if ! download_with_fallback "${TC_MIRROR}/release/distribution_files/corepure64.gz" \
    "${ISO_DIR}/boot/core.gz"; then
    echo "❌ initrd下载失败"
    exit 1
fi

# ================= 第三步：创建引导文件 =================
echo "3. 创建引导文件..."

# 3.1 BIOS引导 (ISOLINUX/SYSLINUX)
echo "  创建BIOS引导..."

# 确保有isolinux.bin
if [ -f "/usr/lib/ISOLINUX/isolinux.bin" ]; then
    cp /usr/lib/ISOLINUX/isolinux.bin "${ISO_DIR}/boot/isolinux/"
elif [ -f "/usr/lib/syslinux/isolinux.bin" ]; then
    cp /usr/lib/syslinux/isolinux.bin "${ISO_DIR}/boot/isolinux/"
else
    # 下载isolinux.bin
    wget -q "${TC_MIRROR}/release/distribution_files/isolinux.bin" \
        -O "${ISO_DIR}/boot/isolinux/isolinux.bin" || {
        echo "❌ 找不到isolinux.bin"
        exit 1
    }
fi

# 复制必要的模块
for module in ldlinux.c32 libutil.c32 menu.c32; do
    if [ -f "/usr/lib/syslinux/modules/bios/${module}" ]; then
        cp "/usr/lib/syslinux/modules/bios/${module}" "${ISO_DIR}/boot/isolinux/"
    fi
done

# 3.2 创建ISOLINUX配置
cat > "${ISO_DIR}/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT openwrt
PROMPT 0
TIMEOUT 300
UI menu.c32

MENU TITLE OpenWRT Installer

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz64
  APPEND initrd=/boot/core.gz quiet console=ttyS0 console=tty0

LABEL local
  MENU LABEL Boot from ^local drive
  LOCALBOOT 0x80
ISOLINUX_CFG

# 3.3 UEFI引导 (GRUB2)
echo "  创建UEFI引导..."

# 创建GRUB配置文件
cat > "${ISO_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz64 quiet
    initrd /boot/core.gz
}

GRUB_CFG

# 复制或生成GRUB EFI文件
if [ -f "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" ]; then
    cp "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" \
        "${ISO_DIR}/efi/boot/bootx64.efi"
elif [ -f "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" ]; then
    cp "/usr/lib/grub/x86_64-efi/monolithic/grub.efi" \
        "${ISO_DIR}/efi/boot/bootx64.efi"
elif command -v grub-mkstandalone >/dev/null 2>&1; then
    echo "  生成GRUB EFI文件..."
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="${WORK_DIR}/bootx64.efi" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos" \
        "boot/grub/grub.cfg=${ISO_DIR}/boot/grub/grub.cfg"
    cp "${WORK_DIR}/bootx64.efi" "${ISO_DIR}/efi/boot/bootx64.efi"
else
    echo "⚠️  无法创建UEFI引导文件，ISO将只支持BIOS引导"
fi

# ================= 第四步：创建简单的启动脚本 =================
echo "4. 创建启动脚本..."

cat > "${ISO_DIR}/start.sh" << 'START_SCRIPT'
#!/bin/sh
# 启动脚本

clear
echo ""
echo "========================================"
echo "    OpenWRT Installer - Tiny Core"
echo "========================================"
echo ""
echo "System is booting..."
echo ""
echo "To install OpenWRT:"
echo "1. The OpenWRT image should be on a USB drive"
echo "2. It should be named 'openwrt.img'"
echo "3. The installer will search for it automatically"
echo ""
echo "If the installer doesn't start, type:"
echo "  /bin/sh"
echo ""
echo "Booting in 3 seconds..."
sleep 3
exec /bin/sh
START_SCRIPT

chmod +x "${ISO_DIR}/start.sh"

# ================= 第五步：验证文件结构 =================
echo "5. 验证文件结构..."
echo "ISO目录内容:"
find "${ISO_DIR}" -type f | sed "s|${ISO_DIR}/||" | sort

# ================= 第六步：构建ISO（关键步骤） =================
echo "6. 构建ISO..."

cd "${WORK_DIR}"

# 使用xorriso构建完整引导的ISO
echo "  使用xorriso构建BIOS+UEFI引导ISO..."

if [ -f "${ISO_DIR}/efi/boot/bootx64.efi" ]; then
    # 构建双引导ISO（BIOS + UEFI）
    echo "  构建双引导ISO..."
    
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "OPENWRT_INSTALL" \
        # BIOS引导
        -eltorito-boot boot/isolinux/isolinux.bin \
        -eltorito-catalog boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        # UEFI引导
        -eltorito-alt-boot \
        -e efi/boot/bootx64.efi \
        -no-emul-boot \
        # 混合模式支持
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -isohybrid-gpt-basdat \
        # 输出
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        "${ISO_DIR}"
else
    # 只构建BIOS引导ISO
    echo "  构建BIOS引导ISO..."
    
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "OPENWRT_INSTALL" \
        -eltorito-boot boot/isolinux/isolinux.bin \
        -eltorito-catalog boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        "${ISO_DIR}"
fi

# 如果xorriso失败，尝试使用genisoimage
if [ $? -ne 0 ] || [ ! -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo "  xorriso失败，尝试genisoimage..."
    
    genisoimage \
        -rational-rock \
        -volid "OPENWRT_INSTALL" \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        "${ISO_DIR}"
fi

# ================= 第七步：验证ISO =================
echo "7. 验证ISO..."

if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    ISO_SIZE=$(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')
    
    echo ""
    echo "✅ ISO构建成功!"
    echo "   文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "   大小: ${ISO_SIZE}"
    
    # 检查引导信息
    echo ""
    echo "🔍 检查引导信息:"
    
    # 检查文件类型
    echo "   文件类型:"
    file "${OUTPUT_DIR}/${ISO_NAME}"
    
    # 检查引导记录
    if command -v isoinfo >/dev/null 2>&1; then
        echo ""
        echo "   ISO引导记录:"
        isoinfo -d -i "${OUTPUT_DIR}/${ISO_NAME}" 2>/dev/null | \
            grep -E "(Volume|El Torito|Boot|Catalog)" || true
    fi
    
    # 检查前512字节（MBR）
    echo ""
    echo "   MBR引导签名:"
    hexdump -C -n 64 "${OUTPUT_DIR}/${ISO_NAME}" | \
        grep -E "(000001b0|000001c0|000001d0|000001e0)" || true
    
    # 创建测试脚本
    cat > "${OUTPUT_DIR}/test-iso.sh" << 'TEST_SCRIPT'
#!/bin/bash
echo "测试ISO引导: $1"
echo ""
echo "1. 使用QEMU测试:"
echo "   qemu-system-x86_64 -cdrom \"$1\" -m 512 -boot d"
echo ""
echo "2. 检查引导信息:"
if command -v isoinfo >/dev/null 2>&1; then
    isoinfo -d -i "$1" 2>/dev/null | grep -A5 "El Torito"
fi
TEST_SCRIPT
    chmod +x "${OUTPUT_DIR}/test-iso.sh"
    
    echo ""
    echo "🚀 使用说明:"
    echo "   1. 写入USB: sudo dd if=\"${OUTPUT_DIR}/${ISO_NAME}\" of=/dev/sdX bs=4M status=progress"
    echo "   2. 测试引导: ${OUTPUT_DIR}/test-iso.sh \"${OUTPUT_DIR}/${ISO_NAME}\""
    
else
    echo "❌ ISO构建失败"
    exit 1
fi

# 清理
rm -rf "${WORK_DIR}"
echo ""
echo "✅ 构建完成!"
