#!/bin/bash
# OpenWRT ISO Builder - 修复EFI引导问题

set -e

echo "================================================"
echo "  OpenWRT ISO Builder - Fixed EFI Boot Issue   "
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

# 创建修复的Dockerfile（解决loop设备问题）
DOCKERFILE_PATH="Dockerfile.fixed"
cat > "$DOCKERFILE_PATH" << 'DOCKERFILE_EOF'
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION}

# 设置镜像源
RUN echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories

# 安装完整的ISO构建工具链（包含loop支持）
RUN apk update && apk add --no-cache \
    bash \
    xorriso \
    syslinux \
    mtools \
    dosfstools \
    grub \
    grub-efi \
    grub-bios \
    e2fsprogs \
    parted \
    util-linux \
    util-linux-misc \
    coreutils \
    gzip \
    tar \
    cpio \
    findutils \
    grep \
    gawk \
    file \
    && rm -rf /var/cache/apk/*

# 创建必要的设备节点（解决loop设备问题）
RUN mknod -m 0660 /dev/loop0 b 7 0 2>/dev/null || true && \
    mknod -m 0660 /dev/loop1 b 7 1 2>/dev/null || true && \
    mknod -m 0660 /dev/loop2 b 7 2 2>/dev/null || true && \
    mknod -m 0660 /dev/loop3 b 7 3 2>/dev/null || true

# 验证工具安装
RUN echo "🔧 验证工具安装:" && \
    echo "xorriso: $(which xorriso)" && \
    echo "mkfs.fat: $(which mkfs.fat 2>/dev/null || which mkfs.vfat 2>/dev/null || echo '未找到')" && \
    echo "syslinux: $(ls -la /usr/share/syslinux/isolinux.bin 2>/dev/null || echo '未找到')" && \
    echo "loop设备: $(ls -la /dev/loop* 2>/dev/null || echo '未找到')"

WORKDIR /work

# 复制构建脚本
COPY scripts/build-fixed-iso.sh /build-fixed-iso.sh
RUN chmod +x /build-fixed-iso.sh

ENTRYPOINT ["/build-fixed-iso.sh"]
DOCKERFILE_EOF

# 更新版本号
sed -i "s/v3.20/v$(echo $ALPINE_VERSION | cut -d. -f1-2)/g" "$DOCKERFILE_PATH"
sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/" "$DOCKERFILE_PATH"

# 创建修复的构建脚本（解决loop挂载问题）
mkdir -p scripts
cat > scripts/build-fixed-iso.sh << 'BUILD_SCRIPT_EOF'
#!/bin/bash
set -e

echo "=== 构建OpenWRT ISO (修复EFI问题) ==="

# 输入文件
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"

# 检查输入文件
if [ ! -f "$INPUT_IMG" ]; then
    echo "❌ 错误: 输入文件不存在: $INPUT_IMG"
    exit 1
fi

echo "✅ 输入文件: $INPUT_IMG ($(du -h "$INPUT_IMG" | cut -f1))"
echo "✅ 输出目录: /output"

# ========== 第1步：创建ISO目录结构 ==========
echo ""
echo "📁 创建ISO目录结构..."
ISO_DIR="/tmp/iso"
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR"/{boot/grub,boot/isolinux,EFI/boot,images}

# 复制OpenWRT镜像
cp "$INPUT_IMG" "$ISO_DIR/images/openwrt.img"
echo "✅ 复制OpenWRT镜像"

# ========== 第2步：设置BIOS引导 ==========
echo ""
echo "🔧 设置BIOS引导 (ISOLINUX)..."

# 复制syslinux文件
SYSBOOT_DIR="/usr/share/syslinux"
if [ -d "$SYSBOOT_DIR" ]; then
    echo "复制syslinux文件..."
    for file in isolinux.bin ldlinux.c32 libutil.c32 libcom32.c32 menu.c32 vesamenu.c32; do
        if [ -f "$SYSBOOT_DIR/$file" ]; then
            cp "$SYSBOOT_DIR/$file" "$ISO_DIR/boot/isolinux/"
            echo " $SYSBOOT_DIR/$file ✅ $file"
        else
            echo "  ⚠ $file 未找到"
        fi
    done
fi
ls -l  $ISO_DIR/boot/isolinux/
# 创建ISOLINUX配置
echo "创建ISOLINUX配置..."
cat > "$ISO_DIR/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG_EOF'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 300
MENU TITLE OpenWRT Installation System

LABEL install
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200n8

ISOLINUX_CFG_EOF

echo "✅ BIOS引导配置完成"

# ========== 第3步：创建GRUB配置 ==========
echo ""
echo "🔧 创建GRUB配置..."

cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_CFG_EOF'
set timeout=5
set default=0

menuentry "Install OpenWRT" {
    echo "Loading kernel..."
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8
    echo "Loading initial ramdisk..."
    initrd /boot/initrd.img
    echo "Booting OpenWRT installer..."
}

GRUB_CFG_EOF

echo "✅ GRUB配置创建完成"

# ========== 第4步：修复的EFI引导创建 ==========
echo ""
echo "🔧 创建EFI引导 (修复loop设备问题)..."

# 方法1：直接创建EFI目录结构，不依赖loop挂载
mkdir -p "$ISO_DIR/EFI/boot"

# 生成GRUB EFI文件（直接输出到目标位置）
if command -v grub-mkimage >/dev/null 2>&1; then
    echo "生成GRUB EFI可执行文件..."
    grub-mkimage \
        -O x86_64-efi \
        -o "$ISO_DIR/EFI/boot/bootx64.efi" \
        -p /EFI/boot \
        fat iso9660 part_gpt part_msdos normal boot linux configfile loopback chain \
        efifwsetup efi_gop efi_uga ls search search_label search_fs_uuid search_fs_file \
        gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 \
        echo true probe terminal 2>/dev/null && \
    echo "✅ GRUB EFI生成成功" || \
    echo "⚠ GRUB EFI生成失败，尝试备用方法"
fi

# 如果生成失败，尝试复制预编译文件
if [ ! -f "$ISO_DIR/EFI/boot/bootx64.efi" ]; then
    echo "尝试复制预编译GRUB EFI..."
    for path in \
        "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" \
        "/usr/share/grub/grubx64.efi" \
        "/usr/lib/grub/x86_64-efi/grubx64.efi"; do
        if [ -f "$path" ]; then
            cp "$path" "$ISO_DIR/EFI/boot/bootx64.efi"
            echo "✅ 从 $path 复制成功"
            break
        fi
    done
fi
ls -l  $ISO_DIR/EFI/boot
# 如果还是没有EFI文件，创建最小的EFI存根
if [ ! -f "$ISO_DIR/EFI/boot/bootx64.efi" ]; then
    echo "创建最小的EFI存根..."
    cat > "$ISO_DIR/EFI/boot/bootx64.efi.stub" << 'EFI_STUB_EOF'
这是一个EFI存根文件。实际的ISO应该包含从Alpine ISO提取的bootx64.efi。
请从官方Alpine ISO复制EFI/boot/bootx64.efi到此位置。
EFI_STUB_EOF
    # 创建一个可执行的脚本作为占位
    echo 'echo "EFI boot stub - Please use a real bootx64.efi from Alpine ISO"' > "$ISO_DIR/EFI/boot/bootx64.efi"
    chmod +x "$ISO_DIR/EFI/boot/bootx64.efi"
    echo "⚠ 创建了EFI存根文件，建议从Alpine ISO提取真正的bootx64.efi"
fi

# 复制GRUB配置到EFI目录
cp "$ISO_DIR/boot/grub/grub.cfg" "$ISO_DIR/EFI/boot/grub.cfg" 2>/dev/null || true

echo "✅ EFI引导配置完成"

# ========== 第5步：创建内核和initrd ==========
echo ""
echo "🔧 创建可引导内核..."

# 使用Alpine的内核
KERNEL_FOUND=false
for kernel in /boot/vmlinuz-lts /boot/vmlinuz-hardened /boot/vmlinuz; do
    if [ -f "$kernel" ]; then
        cp "$kernel" "$ISO_DIR/boot/vmlinuz"
        echo "✅ 使用内核: $(basename "$kernel")"
        KERNEL_FOUND=true
        break
    fi
done

if [ "$KERNEL_FOUND" = false ]; then
    echo "❌ 错误: 未找到Linux内核"
    exit 1
fi

echo ""
echo "🔧 创建initrd..."
INITRD_DIR="/tmp/initrd"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"

# 创建简单的init脚本
cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/sh
# Simple OpenWRT installer init script

# Mount proc and sys
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true

# Create console
mknod /dev/console c 5 1 2>/dev/null || true
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

clear
echo ""
echo "========================================"
echo "   OpenWRT Installation Environment     "
echo "========================================"
echo ""
echo "Welcome! This is a minimal installation environment."
echo ""
echo "The OpenWRT image is available at:"
echo "  /mnt/images/openwrt.img  (if ISO is mounted)"
echo "  or in the ISO at /images/openwrt.img"
echo ""
echo "To install OpenWRT:"
echo "  1. Find your target disk: lsblk or fdisk -l"
echo "  2. Write the image: dd if=openwrt.img of=/dev/sdX bs=4M"
echo ""
echo "Type 'exit' to reboot or Ctrl+D"
echo ""

# Start shell
export PS1="(openwrt) # "
exec /bin/sh
INIT_EOF
chmod +x "$INITRD_DIR/init"

# 复制busybox
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) "$INITRD_DIR/" 2>/dev/null || true
fi

# 打包initrd
(cd "$INITRD_DIR" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img")
echo "✅ initrd创建完成 ($(du -h "$ISO_DIR/boot/initrd.img" | cut -f1))"

# ========== 第6步：创建ISO ==========
echo ""
echo "📦 创建ISO文件..."

cd /tmp

# 首先尝试创建简单的可引导ISO（仅BIOS）
echo "尝试创建BIOS可引导ISO..."
xorriso -as mkisofs \
    -r -V "OPENWRT_INSTALL" \
    -o "/output/openwrt.iso" \
    -b boot/isolinux/isolinux.bin \
    -c boot/isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    "$ISO_DIR" 2>&1 | grep -v "UPDATEing" | grep -v "File not found" || true

# 检查是否成功
if [ -f "/output/openwrt.iso" ]; then
    echo "✅ BIOS ISO创建成功"
    
    # 尝试添加UEFI支持（如果EFI文件存在）
    if [ -f "$ISO_DIR/EFI/boot/bootx64.efi" ] && [ $(stat -c%s "$ISO_DIR/EFI/boot/bootx64.efi") -gt 1000 ]; then
        echo "尝试添加UEFI支持..."
        
        # 创建EFI引导镜像（不使用loop挂载）
        EFI_IMG="/tmp/efiboot.img"
        dd if=/dev/zero of="$EFI_IMG" bs=1M count=10 2>/dev/null
        
        # 使用mformat和mcopy直接操作FAT镜像
        if command -v mformat >/dev/null 2>&1; then
            mformat -i "$EFI_IMG" -F -v "EFI_BOOT" 2>/dev/null || true
            mmd -i "$EFI_IMG" ::/EFI 2>/dev/null || true
            mmd -i "$EFI_IMG" ::/EFI/BOOT 2>/dev/null || true
            mcopy -i "$EFI_IMG" "$ISO_DIR/EFI/boot/bootx64.efi" ::/EFI/BOOT/ 2>/dev/null || true
            mcopy -i "$EFI_IMG" "$ISO_DIR/boot/grub/grub.cfg" ::/EFI/BOOT/ 2>/dev/null || true
            
            # 重新创建带UEFI支持的ISO
            xorriso -as mkisofs \
                -r -V "OPENWRT_INSTALL" \
                -o "/output/openwrt-uefi.iso" \
                -b boot/isolinux/isolinux.bin \
                -c boot/isolinux/boot.cat \
                -no-emul-boot -boot-load-size 4 -boot-info-table \
                -eltorito-alt-boot \
                -e "$EFI_IMG" \
                -no-emul-boot \
                -isohybrid-gpt-basdat \
                "$ISO_DIR" 2>&1 | grep -v "UPDATEing" || true
            
            if [ -f "/output/openwrt-uefi.iso" ]; then
                mv "/output/openwrt-uefi.iso" "/output/openwrt.iso"
                echo "✅ 双引导ISO创建成功"
            fi
        fi
    fi
    
    # 验证ISO
    echo ""
    echo "🔍 验证ISO:"
    echo "文件: /output/openwrt.iso"
    echo "大小: $(du -h "/output/openwrt.iso" | cut -f1)"
    
    if command -v file >/dev/null 2>&1; then
        file "/output/openwrt.iso"
    fi
    
    exit 0
else
    echo "❌ ISO创建失败，尝试创建数据ISO..."
    
    # 创建最简单的数据ISO
    xorriso -as mkisofs \
        -r -V "OPENWRT_DATA" \
        -o "/output/openwrt.iso" \
        "$ISO_DIR"
    
    if [ -f "/output/openwrt.iso" ]; then
        echo "✅ 数据ISO创建成功"
        echo "文件: /output/openwrt.iso"
        echo "大小: $(du -h "/output/openwrt.iso" | cut -f1)"
        exit 0
    else
        echo "❌ 所有ISO创建尝试都失败"
        exit 1
    fi
fi
BUILD_SCRIPT_EOF

chmod +x scripts/build-fixed-iso.sh

# ========== 构建Docker镜像 ==========
echo "🔨 构建Docker镜像..."
IMAGE_NAME="openwrt-fixed-builder:latest"

if docker build \
    -f "$DOCKERFILE_PATH" \
    --build-arg ALPINE_VERSION="$ALPINE_VERSION" \
    -t "$IMAGE_NAME" \
    . 2>&1 | tee /tmp/docker-build.log; then
    
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        echo "✅ Docker镜像构建成功: $IMAGE_NAME"
    else
        echo "❌ Docker镜像构建失败"
        cat /tmp/docker-build.log | tail -20
        exit 1
    fi
else
    echo "❌ Docker构建过程失败"
    cat /tmp/docker-build.log | tail -20
    exit 1
fi

# ========== 运行Docker容器 ==========
echo "🚀 运行Docker容器构建ISO..."

# 运行容器时启用特权模式（解决loop设备问题）
set +e
docker run --rm \
    --name openwrt-fixed-builder \
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
    
    # 验证
    echo "🔍 验证信息:"
    if command -v file >/dev/null 2>&1; then
        FILE_INFO=$(file "$FINAL_ISO")
        echo "文件类型: $FILE_INFO"
        
        if echo "$FILE_INFO" | grep -q "bootable"; then
            echo "✅ ISO可引导"
        else
            echo "⚠ ISO可能不可引导（数据ISO）"
        fi
    fi
    
    # 检查ISO内容
    echo ""
    echo "📂 ISO内容摘要:"
    if command -v isoinfo >/dev/null 2>&1 && [ -f "$FINAL_ISO" ]; then
        echo "卷标: $(isoinfo -d -i "$FINAL_ISO" 2>/dev/null | grep "Volume id" | cut -d: -f2- | sed 's/^ *//' || echo "未知")"
        echo "包含OpenWRT镜像: $(isoinfo -f -i "$FINAL_ISO" 2>/dev/null | grep -c "openwrt.img" || echo 0) 个"
    fi
    
    echo ""
    echo "🚀 使用方法:"
    echo "   1. 测试: qemu-system-x86_64 -cdrom '$FINAL_ISO' -m 512"
    echo "   2. 刻录USB: sudo dd if='$FINAL_ISO' of=/dev/sdX bs=4M status=progress"
    echo "   3. 提取镜像: 7z x '$FINAL_ISO' images/openwrt.img"
    
    exit 0
else
    echo ""
    echo "❌ ISO构建失败"
    
    # 显示容器日志
    echo "📋 容器日志:"
    docker logs openwrt-fixed-builder 2>/dev/null || echo "无法获取容器日志"
    
    # 检查输出目录
    echo ""
    echo "📁 输出目录内容:"
    ls -la "$OUTPUT_ABS/" 2>/dev/null || echo "输出目录不存在"
    
    exit 1
fi
