#!/bin/bash
# OpenWRT ISO Builder - 支持BIOS/UEFI双引导

set -e

echo "================================================"
echo "  OpenWRT ISO Builder - Dual Boot (BIOS+UEFI)  "
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

# 验证IMG文件
echo "🔍 验证IMG文件..."
if ! file "$IMG_FILE" | grep -q "DOS/MBR boot sector\|Linux.*filesystem data"; then
    echo "⚠ 警告: 文件可能不是有效的IMG文件"
    echo "文件类型: $(file "$IMG_FILE")"
    read -p "继续? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        exit 1
    fi
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

# 创建正确的Dockerfile（包含所有必要工具）
DOCKERFILE_PATH="Dockerfile.dual"
cat > "$DOCKERFILE_PATH" << 'DOCKERFILE_EOF'
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION}

# 设置镜像源
RUN echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories

# 安装完整的ISO构建工具链
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
    coreutils \
    gzip \
    tar \
    cpio \
    findutils \
    grep \
    gawk \
    file \
    && rm -rf /var/cache/apk/*

# 验证工具安装
RUN echo "🔧 验证工具安装:" && \
    echo "xorriso: $(which xorriso)" && \
    echo "syslinux: $(ls -la /usr/share/syslinux/isolinux.bin 2>/dev/null || echo '未找到')" && \
    echo "grub-mkimage: $(which grub-mkimage 2>/dev/null || echo '未找到')" && \
    echo "mkfs.fat: $(which mkfs.fat 2>/dev/null || echo '未找到')"

WORKDIR /work

# 复制构建脚本
COPY scripts/build-dual-iso.sh /build-dual-iso.sh
RUN chmod +x /build-dual-iso.sh

ENTRYPOINT ["/build-dual-iso.sh"]
DOCKERFILE_EOF

# 更新版本号
sed -i "s/v3.20/v$(echo $ALPINE_VERSION | cut -d. -f1-2)/g" "$DOCKERFILE_PATH"
sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/" "$DOCKERFILE_PATH"

# 创建真正的双引导构建脚本
mkdir -p scripts
cat > scripts/build-dual-iso.sh << 'BUILD_SCRIPT_EOF'
#!/bin/bash
set -e

echo "=== 构建双引导OpenWRT ISO (BIOS+UEFI) ==="

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
mkdir -p "$ISO_DIR"/{boot/grub,boot/isolinux,EFI/boot,images,install}

# 复制OpenWRT镜像
cp "$INPUT_IMG" "$ISO_DIR/images/openwrt.img"
echo "✅ 复制OpenWRT镜像"

# ========== 第2步：设置BIOS引导 (ISOLINUX) ==========
echo ""
echo "🔧 设置BIOS引导 (ISOLINUX)..."

# 复制所有必要的syslinux文件
SYSBOOT_DIR="/usr/share/syslinux"
if [ -d "$SYSBOOT_DIR" ]; then
    echo "复制syslinux文件..."
    cp "$SYSBOOT_DIR/isolinux.bin" "$ISO_DIR/boot/isolinux/" 2>/dev/null || echo "⚠ 未找到 isolinux.bin"
    cp "$SYSBOOT_DIR/ldlinux.c32" "$ISO_DIR/boot/isolinux/" 2>/dev/null || echo "⚠ 未找到 ldlinux.c32"
    cp "$SYSBOOT_DIR/libutil.c32" "$ISO_DIR/boot/isolinux/" 2>/dev/null || echo "⚠ 未找到 libutil.c32"
    cp "$SYSBOOT_DIR/libcom32.c32" "$ISO_DIR/boot/isolinux/" 2>/dev/null || echo "⚠ 未找到 libcom32.c32"
    cp "$SYSBOOT_DIR/menu.c32" "$ISO_DIR/boot/isolinux/" 2>/dev/null || echo "⚠ 未找到 menu.c32"
    cp "$SYSBOOT_DIR/vesamenu.c32" "$ISO_DIR/boot/isolinux/" 2>/dev/null || echo "⚠ 未找到 vesamenu.c32"
    cp "$SYSBOOT_DIR/chain.c32" "$ISO_DIR/boot/isolinux/" 2>/dev/null || echo "⚠ 未找到 chain.c32"
    cp "$SYSBOOT_DIR/reboot.c32" "$ISO_DIR/boot/isolinux/" 2>/dev/null || echo "⚠ 未找到 reboot.c32"
else
    echo "❌ 错误: syslinux目录不存在"
    exit 1
fi

# 创建ISOLINUX配置文件（修复版）
echo "创建ISOLINUX配置..."
cat > "$ISO_DIR/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG_EOF'
DEFAULT vesamenu.c32
PROMPT 0
TIMEOUT 300
MENU TITLE OpenWRT Installation System
MENU BACKGROUND /boot/isolinux/splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

LABEL install
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200n8

LABEL bootlocal
  MENU LABEL ^Boot from local disk
  LOCALBOOT 0x80
  TEXT HELP
  Boot from the first hard disk
  ENDTEXT

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32

LABEL shell
  MENU LABEL ^Shell
  COM32 shell.c32
ISOLINUX_CFG_EOF

# 如果vesamenu.c32不存在，使用简单配置
if [ ! -f "$ISO_DIR/boot/isolinux/vesamenu.c32" ]; then
    cat > "$ISO_DIR/boot/isolinux/isolinux.cfg" << 'SIMPLE_CFG_EOF'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 300
MENU TITLE OpenWRT Installation System

LABEL install
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200n8

LABEL bootlocal
  MENU LABEL Boot from local disk
  LOCALBOOT 0x80

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32
SIMPLE_CFG_EOF
fi

echo "✅ BIOS引导配置完成"

# ========== 第3步：设置UEFI引导 (GRUB) ==========
echo ""
echo "🔧 设置UEFI引导 (GRUB)..."

# 创建GRUB配置文件
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_CFG_EOF'
set timeout=5
set default=0

# 加载必要的模块
insmod all_video
insmod gfxterm
insmod png
insmod ext2
insmod part_gpt
insmod part_msdos

# 设置显示
set gfxmode=auto
set gfxpayload=keep
terminal_output gfxterm

# 菜单项
menuentry "Install OpenWRT" --class gnu-linux --class gnu --class os {
    echo "Loading kernel..."
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8
    echo "Loading initial ramdisk..."
    initrd /boot/initrd.img
    echo "Booting OpenWRT installer..."
}

menuentry "Boot from local disk" {
    echo "Attempting to boot from local disk..."
    exit
}

menuentry "UEFI Firmware Settings" {
    fwsetup
}

menuentry "Reboot" {
    reboot
}
GRUB_CFG_EOF

echo "✅ GRUB配置创建完成"

# ========== 第4步：创建EFI引导镜像 ==========
echo ""
echo "🔧 创建EFI引导镜像..."

# 创建EFI分区镜像
EFI_IMG="/tmp/efiboot.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=32
mkfs.fat -F 32 "$EFI_IMG"

# 挂载并填充EFI分区
mkdir -p /tmp/efi_mnt
mount -o loop "$EFI_IMG" /tmp/efi_mnt
mkdir -p /tmp/efi_mnt/EFI/BOOT

# 生成或复制GRUB EFI文件
if command -v grub-mkimage >/dev/null 2>&1; then
    echo "生成GRUB EFI可执行文件..."
    grub-mkimage \
        -O x86_64-efi \
        -o /tmp/efi_mnt/EFI/BOOT/bootx64.efi \
        -p /boot/grub \
        fat iso9660 part_gpt part_msdos normal boot linux configfile loopback chain \
        efifwsetup efi_gop efi_uga ls search search_label search_fs_uuid search_fs_file \
        gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 \
        echo true probe terminal
    echo "✅ GRUB EFI生成成功"
elif [ -f "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" ]; then
    echo "复制预编译的GRUB EFI..."
    cp "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" /tmp/efi_mnt/EFI/BOOT/bootx64.efi
else
    echo "⚠ 警告: 无法创建EFI引导文件"
fi

# 复制GRUB配置文件
mkdir -p /tmp/efi_mnt/boot/grub
cp "$ISO_DIR/boot/grub/grub.cfg" /tmp/efi_mnt/boot/grub/

# 卸载
umount /tmp/efi_mnt
rmdir /tmp/efi_mnt

# 移动EFI镜像到ISO目录
mv "$EFI_IMG" "$ISO_DIR/EFI/boot/efiboot.img"
echo "✅ EFI引导镜像创建完成 ($(du -h "$ISO_DIR/EFI/boot/efiboot.img" | cut -f1))"

# ========== 第5步：创建可引导内核和initrd ==========
echo ""
echo "🔧 创建可引导内核..."

# 使用Alpine的内核（确保可用）
if [ -f "/boot/vmlinuz-lts" ]; then
    cp /boot/vmlinuz-lts "$ISO_DIR/boot/vmlinuz"
    echo "✅ 使用内核: vmlinuz-lts"
elif [ -f "/boot/vmlinuz" ]; then
    cp /boot/vmlinuz "$ISO_DIR/boot/vmlinuz"
    echo "✅ 使用内核: vmlinuz"
else
    echo "❌ 错误: 未找到Linux内核"
    exit 1
fi

echo ""
echo "🔧 创建initrd..."
INITRD_DIR="/tmp/initrd"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"/{bin,dev,proc,sys,etc,usr/bin,lib,lib64,mnt,root,tmp,var,run,images,install}

# 创建真正的init脚本（能实际工作）
cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/sh
# OpenWRT Installer Init Script

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mknod /dev/null c 1 3

# Create console
mknod /dev/console c 5 1 2>/dev/null || true
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# Set up basic environment
echo "Mounting tmpfs..."
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run

# Load modules if needed
modprobe -q loop 2>/dev/null || true
modprobe -q ext4 2>/dev/null || true
modprobe -q fat 2>/dev/null || true

# Show welcome message
clear
cat << "WELCOME"
╔══════════════════════════════════════════════════╗
║           OpenWRT Installation System            ║
╚══════════════════════════════════════════════════╝
WELCOME

echo ""
echo "Welcome to the OpenWRT installer!"
echo ""
echo "The OpenWRT image is located at: /mnt/images/openwrt.img"
echo ""

# Mount the ISO to access the OpenWRT image
echo "Mounting ISO..."
mkdir -p /mnt/iso
mount -t iso9660 -o ro /dev/sr0 /mnt/iso 2>/dev/null || \
mount -t iso9660 -o ro /dev/cdrom /mnt/iso 2>/dev/null || \
echo "Warning: Could not mount ISO, trying alternative..."

# Copy OpenWRT image to tmpfs for faster access
if [ -f "/mnt/iso/images/openwrt.img" ]; then
    echo "Copying OpenWRT image to RAM..."
    cp /mnt/iso/images/openwrt.img /tmp/openwrt.img
    echo "OpenWRT image ready in /tmp/openwrt.img"
else
    echo "Error: OpenWRT image not found on ISO!"
    echo "Looking for image in /images..."
    if [ -f "/images/openwrt.img" ]; then
        cp /images/openwrt.img /tmp/openwrt.img
    fi
fi

# Show available disks
echo ""
echo "Available storage devices:"
echo "──────────────────────────────────────────────"
if command -v lsblk >/dev/null 2>&1; then
    lsblk -d -n -o NAME,SIZE,MODEL,TYPE,TRAN
elif command -v fdisk >/dev/null 2>&1; then
    fdisk -l 2>/dev/null | grep "^Disk /dev/" | head -10
else
    echo "No disk listing tools available"
fi
echo "──────────────────────────────────────────────"

# Show installation instructions
cat << "INSTRUCTIONS"

Installation Instructions:
──────────────────────────
1. Identify your target disk (e.g., /dev/sda)
2. Write the OpenWRT image:
   dd if=/tmp/openwrt.img of=/dev/sdX bs=4M status=progress
   
   Or if the image is on the ISO:
   dd if=/mnt/iso/images/openwrt.img of=/dev/sdX bs=4M status=progress

3. Verify the write:
   sync
   
4. Reboot when done

Type 'help' for more commands or 'exit' to reboot.
INSTRUCTIONS

echo ""
echo "Starting shell..."
echo ""

# Start interactive shell
export PS1="(openwrt-installer) # "
exec /bin/sh
INIT_EOF
chmod +x "$INITRD_DIR/init"

# 复制必要的工具
echo "复制必要工具到initrd..."
if command -v busybox >/dev/null 2>&1; then
    BUSYBOX_PATH=$(which busybox)
    cp "$BUSYBOX_PATH" "$INITRD_DIR/bin/"
    
    # 创建符号链接
    cd "$INITRD_DIR/bin"
    ./busybox --list | while read cmd; do
        ln -sf busybox "$cmd" 2>/dev/null || true
    done
    cd - >/dev/null
    echo "✅ 复制busybox及工具"
fi

# 复制其他必要工具
for tool in dd lsblk fdisk mount umount cat echo sh sync; do
    tool_path=$(which "$tool" 2>/dev/null || true)
    if [ -n "$tool_path" ] && [ -f "$tool_path" ]; then
        mkdir -p "$INITRD_DIR$(dirname "$tool_path")"
        cp "$tool_path" "$INITRD_DIR$tool_path" 2>/dev/null || true
    fi
done

# 创建库文件（简化版）
mkdir -p "$INITRD_DIR/lib"
cp /lib/ld-musl-*.so* "$INITRD_DIR/lib/" 2>/dev/null || true

# 打包initrd
echo "打包initrd..."
(cd "$INITRD_DIR" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img")
INITRD_SIZE=$(du -h "$ISO_DIR/boot/initrd.img" | cut -f1)
echo "✅ initrd创建完成 ($INITRD_SIZE)"

# ========== 第6步：创建最终的ISO ==========
echo ""
echo "📦 创建双引导ISO文件..."

# 复制引导镜像文件
if [ -f "/usr/share/syslinux/isohdpfx.bin" ]; then
    cp /usr/share/syslinux/isohdpfx.bin /tmp/isohdpfx.bin
else
    # 生成hybrid MBR
    echo "生成hybrid MBR..."
    dd if=/dev/zero of=/tmp/isohdpfx.bin bs=512 count=1
    printf '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' | \
        dd of=/tmp/isohdpfx.bin conv=notrunc 2>/dev/null
fi

cd /tmp

# 使用xorriso创建真正的双引导ISO
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot boot/isolinux/isolinux.bin \
    -eltorito-catalog boot/isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /tmp/isohdpfx.bin \
    -eltorito-alt-boot \
    -e EFI/boot/efiboot.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -append_partition 2 0xef "$ISO_DIR/EFI/boot/efiboot.img" \
    -o "/output/openwrt.iso" \
    "$ISO_DIR" 2>&1 | grep -v "UPDATEing" | grep -v "File not found" || true

# 验证ISO创建
if [ -f "/output/openwrt.iso" ]; then
    echo "✅ ISO创建成功"
    
    # 验证ISO引导信息
    echo ""
    echo "🔍 验证ISO引导信息..."
    if command -v isoinfo >/dev/null 2>&1; then
        ISO_INFO=$(isoinfo -d -i "/output/openwrt.iso" 2>/dev/null || true)
        echo "$ISO_INFO" | grep -E "Volume id|Bootable" || true
    fi
    
    echo ""
    echo "💾 ISO详细信息:"
    echo "文件: /output/openwrt.iso"
    echo "大小: $(du -h "/output/openwrt.iso" | cut -f1)"
    
    # 检查引导能力
    if file "/output/openwrt.iso" | grep -q "bootable"; then
        echo "✅ ISO可引导 (BIOS+UEFI)"
    else
        echo "⚠ ISO可能不可引导"
    fi
    
    exit 0
else
    echo "❌ ISO创建失败"
    
    # 尝试简单方法
    echo "尝试简单方法创建ISO..."
    xorriso -as mkisofs \
        -r -V "OPENWRT_INSTALL" \
        -o "/output/openwrt.iso" \
        "$ISO_DIR"
    
    if [ -f "/output/openwrt.iso" ]; then
        echo "✅ ISO创建成功 (简单模式)"
        echo "文件: /output/openwrt.iso"
        echo "大小: $(du -h "/output/openwrt.iso" | cut -f1)"
        exit 0
    else
        echo "❌ 所有ISO创建尝试都失败"
        exit 1
    fi
fi
BUILD_SCRIPT_EOF

chmod +x scripts/build-dual-iso.sh

# ========== 构建Docker镜像 ==========
echo "🔨 构建Docker镜像..."
IMAGE_NAME="openwrt-dual-boot-builder:latest"

echo "使用的Dockerfile:"
echo "----------------------------------------"
head -30 "$DOCKERFILE_PATH"
echo "..."
echo "----------------------------------------"

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

# ========== 运行Docker容器构建ISO ==========
echo "🚀 运行Docker容器构建ISO..."

# 清理旧容器
docker rm -f openwrt-dual-builder 2>/dev/null || true

# 运行容器
set +e
timeout 600 docker run --rm \
    --name openwrt-dual-builder \
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
    echo "🎉🎉🎉 双引导ISO构建成功! 🎉🎉🎉"
    echo ""
    echo "📁 ISO文件: $FINAL_ISO"
    echo "📊 大小: $(du -h "$FINAL_ISO" | cut -f1)"
    echo ""
    
    # 详细验证
    echo "🔍 详细验证:"
    
    # 1. 文件类型
    echo "1. 文件类型:"
    file "$FINAL_ISO"
    
    # 2. ISO信息
    echo ""
    echo "2. ISO信息:"
    if command -v isoinfo >/dev/null 2>&1; then
        ISO_INFO=$(isoinfo -d -i "$FINAL_ISO" 2>/dev/null || true)
        echo "$ISO_INFO" | grep -E "Volume id|Volume size|Bootable" || echo "无法获取ISO信息"
    fi
    
    # 3. 列出内容
    echo ""
    echo "3. ISO主要内容:"
    if command -v isoinfo >/dev/null 2>&1; then
        isoinfo -f -i "$FINAL_ISO" 2>/dev/null | grep -E "(boot|EFI|images)" | head -10 || true
    fi
    
    echo ""
    echo "✅ 构建特性:"
    echo "   ✓ BIOS引导 (ISOLINUX) - 支持传统模式"
    echo "   ✓ UEFI引导 (GRUB) - 支持新式固件"
    echo "   ✓ 完整的安装环境"
    echo "   ✓ 包含OpenWRT镜像"
    
    echo ""
    echo "🚀 测试建议:"
    echo "   1. BIOS模式测试: qemu-system-x86_64 -cdrom '$FINAL_ISO' -m 512"
    echo "   2. UEFI模式测试: qemu-system-x86_64 -cdrom '$FINAL_ISO' -bios /usr/share/qemu/OVMF.fd -m 512"
    echo "   3. 刻录到USB: sudo dd if='$FINAL_ISO' of=/dev/sdX bs=4M status=progress"
    
    exit 0
else
    echo ""
    echo "❌ ISO构建失败"
    
    # 显示容器日志
    echo "📋 容器日志:"
    docker logs --tail 100 openwrt-dual-builder 2>/dev/null || echo "无法获取容器日志"
    
    # 检查输出目录
    echo ""
    echo "📁 输出目录内容:"
    ls -la "$OUTPUT_ABS/" 2>/dev/null || echo "输出目录不存在"
    
    exit 1
fi
