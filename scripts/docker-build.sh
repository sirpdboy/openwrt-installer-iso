#!/bin/bash
# OpenWRT ISO Builder - 修复内核问题

set -e

echo "================================================"
echo "  OpenWRT ISO Builder - Fixed Kernel Issue     "
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

# 创建修复的Dockerfile（包含内核）
DOCKERFILE_PATH="Dockerfile.kernel"
cat > "$DOCKERFILE_PATH" << 'DOCKERFILE_EOF'
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION}

# 设置镜像源
RUN echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories

# 安装完整的ISO构建工具链和内核
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
    curl \
    wget \
    linux-lts \
    linux-firmware-none \
    && rm -rf /var/cache/apk/*
# 创建必要的设备节点
RUN mknod -m 0660 /dev/loop0 b 7 0 2>/dev/null || true && \
    mknod -m 0660 /dev/loop1 b 7 1 2>/dev/null || true

# 下载备用内核（如果Alpine内核安装失败）
RUN echo "下载备用内核..." && \
    mkdir -p /tmp/kernel && cd /tmp/kernel && \
    curl -L -o kernel.tar.xz https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.30.tar.xz 2>/dev/null || \
    curl -L -o kernel.tar.xz https://mirrors.edge.kernel.org/pub/linux/kernel/v6.x/linux-6.6.30.tar.xz 2>/dev/null || \
    echo "内核下载失败，继续..."

# 验证工具和内核
RUN echo "🔧 验证安装:" && \
    echo "内核位置:" && \
    ls -la /boot/ 2>/dev/null || echo "无/boot目录" && \
    echo "" && \
    echo "可用内核:" && \
    find /boot -name "vmlinuz*" 2>/dev/null | head -5 || echo "未找到内核" && \
    echo "" && \
    echo "xorriso: $(which xorriso)" && \
    echo "mkfs.fat: $(which mkfs.fat 2>/dev/null || which mkfs.vfat 2>/dev/null || echo '未找到')"
WORKDIR /work

# 复制构建脚本
COPY scripts/build-with-kernel.sh /build-with-kernel.sh
RUN chmod +x /build-with-kernel.sh

ENTRYPOINT ["/build-with-kernel.sh"]
DOCKERFILE_EOF

# 更新版本号
sed -i "s/v3.20/v$(echo $ALPINE_VERSION | cut -d. -f1-2)/g" "$DOCKERFILE_PATH"
sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/" "$DOCKERFILE_PATH"

# 创建包含内核处理的构建脚本
mkdir -p scripts
cat > scripts/build-with-kernel.sh << 'BUILD_SCRIPT_EOF'
#!/bin/bash
set -e

echo "=== 构建OpenWRT ISO (包含内核) ==="

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
    for file in isolinux.bin ldlinux.c32 libutil.c32 libcom32.c32 menu.c32; do
        if [ -f "$SYSBOOT_DIR/$file" ]; then
            cp "$SYSBOOT_DIR/$file" "$ISO_DIR/boot/isolinux/"
            echo " $SYSBOOT_DIR/$file ✅ $file"
        else
            echo "  ⚠ $file 未找到"
        fi
    done
fi
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
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200n8 rw init=/init

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
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8 rw init=/init
    echo "Loading initial ramdisk..."
    initrd /boot/initrd.img
    echo "Booting OpenWRT installer..."
}

GRUB_CFG_EOF

echo "✅ GRUB配置创建完成"

# ========== 第4步：创建EFI引导 ==========
echo ""
echo "🔧 创建EFI引导..."

mkdir -p "$ISO_DIR/EFI/boot"

# 生成GRUB EFI文件
if command -v grub-mkimage >/dev/null 2>&1; then
    echo "生成GRUB EFI可执行文件..."
    grub-mkimage \
        -O x86_64-efi \
        -o "$ISO_DIR/EFI/boot/bootx64.efi" \
        -p /boot/grub \
        fat iso9660 part_gpt part_msdos normal boot linux configfile loopback chain \
        efifwsetup efi_gop efi_uga ls search search_label search_fs_uuid search_fs_file \
        gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 \
        echo true probe terminal 2>/dev/null && \
    echo "✅ GRUB EFI生成成功" || \
    echo "⚠ GRUB EFI生成失败"
fi

# 复制GRUB配置到EFI目录
cp "$ISO_DIR/boot/grub/grub.cfg" "$ISO_DIR/EFI/boot/grub.cfg" 2>/dev/null || true
echo "✅ EFI引导配置完成"

# ========== 第5步：处理内核 ==========
echo ""
echo "🔧 处理内核文件..."

KERNEL_FOUND=false
# 方法1：检查Alpine安装的内核
echo "在系统中查找内核文件..."
POSSIBLE_KERNELS=(
    "/boot/vmlinuz-lts"
    "/boot/vmlinuz-hardened"
    "/boot/vmlinuz"
    "/boot/vmlinuz-grsec"
    "/vmlinuz"
)

for kernel_path in "${POSSIBLE_KERNELS[@]}"; do
    if [ -f "$kernel_path" ]; then
        echo "✅ 找到内核: $kernel_path"
        cp "$kernel_path" "$ISO_DIR/boot/vmlinuz"
        KERNEL_FOUND=true
        echo "✅ 复制内核: $(basename "$kernel_path") -> $ISO_DIR/boot/vmlinuz"
        
        # 验证复制是否成功
        if [ -f "$ISO_DIR/boot/vmlinuz" ]; then
            KERNEL_SIZE=$(du -h "$ISO_DIR/boot/vmlinuz" | cut -f1)
            echo "✅ 内核复制成功，大小: $KERNEL_SIZE"
            echo "内核信息:"
            file "$ISO_DIR/boot/vmlinuz" || true
        else
            echo "❌ 内核复制失败"
            KERNEL_FOUND=false
        fi
        break
    fi
done

if [ "$KERNEL_FOUND" = false ]; then
    echo "⚠ 未找到标准Linux内核，"
fi



echo "✅ 内核处理完成"

# ========== 第6步：创建initrd ==========
echo ""
echo "🔧 创建initrd..."

INITRD_DIR="/tmp/initrd"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"/{bin,dev,etc,lib,proc,sys,root,sbin,tmp,usr/bin,usr/sbin}

# 创建init脚本
cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/sh
# OpenWRT Installer Init Script

# 挂载proc和sys
mount -t proc none /proc
mount -t sysfs none /sys

# 创建设备节点
mkdir -p /dev
mount -t devtmpfs none /dev 2>/dev/null || mknod /dev/console c 5 1
mknod /dev/null c 1 3 2>/dev/null || true
mknod /dev/zero c 1 5 2>/dev/null || true
# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 挂载tmpfs
mount -t tmpfs none /tmp
# 设置PATH
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
clear
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "         OpenWRT Installation System"
echo "╚══════════════════════════════════════════════╝"


echo ""
echo "Checking OpenWRT image..."
if [ ! -f "/openwrt.img" ]; then
    echo "❌ ERROR: OpenWRT image not found!"
    echo ""
    echo "Press Enter for shell..."
    read
    exec /bin/bash
fi

echo "✅ OpenWRT image found: $(ls -lh /openwrt.img | awk '{print $5}')"
echo ""

while true; do
    echo "Available disks:"
    echo "================="
    lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^(sd|hd|nvme)' || echo "No disks detected"
    echo "================="
    echo ""
    
    read -p "Enter target disk (e.g., sda): " TARGET_DISK
    
    if [ -z "$TARGET_DISK" ]; then
        echo "Please enter a disk name"
        continue
    fi
    
    if [ ! -b "/dev/$TARGET_DISK" ]; then
        echo "❌ Disk /dev/$TARGET_DISK not found!"
        continue
    fi
    
    echo ""
    echo "⚠️  WARNING: This will erase ALL data on /dev/$TARGET_DISK!"
    echo ""
    read -p "Type 'YES' to confirm: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Cancelled."
        continue
    fi
    
    clear
    echo ""
    echo "Installing OpenWRT to /dev/$TARGET_DISK..."
    echo ""
    
    if command -v pv >/dev/null 2>&1; then
        pv /openwrt.img | dd of="/dev/$TARGET_DISK" bs=4M
    else
        dd if=/openwrt.img of="/dev/$TARGET_DISK" bs=4M status=progress
    fi
    
    sync
    echo ""
    echo "✅ Installation complete!"
    echo ""
    
    echo "System will reboot in 10 seconds..."
    
    for i in {10..1}; do
        echo -ne "Rebooting in $i seconds...\r"
        sleep 1
    done
    
    reboot -f
done

INIT_EOF
chmod +x "$INITRD_DIR/init"

# 创建符号链接：/sbin/init -> /init（很多系统会找/sbin/init）
ln -sf /init "$INITRD_DIR/sbin/init"
# 复制busybox（这是关键！）
echo "设置busybox..."
if command -v busybox >/dev/null 2>&1; then
    BUSYBOX_PATH=$(which busybox)
    if [ -f "$BUSYBOX_PATH" ]; then
        echo "复制busybox: $BUSYBOX_PATH"
        cp "$BUSYBOX_PATH" "$INITRD_DIR/bin/"
        chmod +x "$INITRD_DIR/bin/busybox"
        
        # 创建必要的符号链接
        cd "$INITRD_DIR"
        echo "创建busybox符号链接..."
        
        # 创建基本命令的符号链接
        for cmd in sh ls echo cat cp mount umount mkdir mknod dd ps grep awk sed; do
            ln -sf /bin/busybox "bin/$cmd" 2>/dev/null || true
        done
        
        # 创建sbin目录的链接
        ln -sf /bin/busybox "sbin/init" 2>/dev/null || true
        ln -sf /bin/busybox "sbin/modprobe" 2>/dev/null || true
        
        cd - >/dev/null
        echo "✅ busybox设置完成"
    else
        echo "⚠ 无法复制busybox"
    fi
fi

# 复制必要的库文件（Alpine使用musl libc）
echo "复制库文件..."
if [ -f "/lib/ld-musl-x86_64.so.1" ]; then
    cp "/lib/ld-musl-x86_64.so.1" "$INITRD_DIR/lib/" 2>/dev/null || true
    echo "✅ 复制musl loader"
fi

# 复制其他必要工具
echo "复制其他工具..."
for tool in lsblk fdisk blkid; do
    tool_path=$(which "$tool" 2>/dev/null || true)
    if [ -n "$tool_path" ] && [ -f "$tool_path" ]; then
        mkdir -p "$INITRD_DIR$(dirname "$tool_path")"
        cp "$tool_path" "$INITRD_DIR$tool_path" 2>/dev/null || true
        echo "  ✅ $tool"
    fi
done

# 创建必要的目录结构
echo "创建目录结构..."
mkdir -p "$INITRD_DIR/mnt/iso"
mkdir -p "$INITRD_DIR/run"
mkdir -p "$INITRD_DIR/var/run"

# 创建fstab文件
cat > "$INITRD_DIR/etc/fstab" << 'FSTAB_EOF'
none    /proc   proc    defaults    0 0
none    /sys    sysfs   defaults    0 0
none    /dev    devtmpfs defaults   0 0
none    /tmp    tmpfs   defaults    0 0
FSTAB_EOF

# 创建inittab文件
cat > "$INITRD_DIR/etc/inittab" << 'INITTAB_EOF'
::sysinit:/bin/busybox mount -t proc proc /proc
::sysinit:/bin/busybox mount -t sysfs sysfs /sys
::sysinit:/bin/busybox mount -t devtmpfs devtmpfs /dev
::sysinit:/bin/busybox mkdir -p /dev/pts
::sysinit:/bin/busybox mount -t devpts devpts /dev/pts
::sysinit:/bin/busybox --install -s
::respawn:/bin/sh
::ctrlaltdel:/bin/busybox reboot -f
::shutdown:/bin/busybox umount -a -r
INITTAB_EOF

# 打包initrd
echo "打包initrd..."
cd "$INITRD_DIR"
echo "initrd目录结构:"
find . | head -20

echo "创建cpio归档..."
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img"

# 验证initrd
if [ -f "$ISO_DIR/boot/initrd.img" ]; then
    INITRD_SIZE=$(du -h "$ISO_DIR/boot/initrd.img" | cut -f1)
    echo "✅ initrd创建成功 ($INITRD_SIZE)"
    
    # 检查initrd内容
    echo "检查initrd内容:"
    echo "是否有/init: $(gzip -cd "$ISO_DIR/boot/initrd.img" 2>/dev/null | cpio -it 2>/dev/null | grep -c "^init$" || echo 0)"
    echo "是否有/bin/busybox: $(gzip -cd "$ISO_DIR/boot/initrd.img" 2>/dev/null | cpio -it 2>/dev/null | grep -c "bin/busybox$" || echo 0)"
else
    echo "❌ initrd创建失败"
    exit 1
fi

# ========== 第7步：创建ISO ==========
echo ""
echo "📦 创建ISO文件..."

cd /tmp

# 创建BIOS可引导ISO
echo "创建BIOS可引导ISO..."
xorriso -as mkisofs \
    -r -V "OPENWRT_INSTALL" \
    -o "/output/openwrt.iso" \
    -b boot/isolinux/isolinux.bin \
    -c boot/isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    "$ISO_DIR" 2>&1 | grep -v "UPDATEing" || true

# 检查是否成功
if [ -f "/output/openwrt.iso" ]; then
    echo "✅ ISO创建成功"
    
    # 验证ISO
    echo ""
    echo "🔍 ISO验证:"
    echo "文件: /output/openwrt.iso"
    ISO_SIZE=$(du -h "/output/openwrt.iso" | cut -f1)
    echo "大小: $ISO_SIZE"
    
    if command -v file >/dev/null 2>&1; then
        FILE_INFO=$(file "/output/openwrt.iso")
        echo "类型: $FILE_INFO"
        
        if echo "$FILE_INFO" | grep -q "bootable"; then
            echo "✅ ISO可引导"
        else
            echo "⚠ ISO可能不可引导"
        fi
    fi
    
    # 检查内核参数
    echo ""
    echo "⚠ 重要: 内核启动参数已添加 'init=/init'"
    echo "如果仍有问题，可以尝试其他init位置:"
    echo "  init=/sbin/init"
    echo "  init=/bin/sh"
    echo "  init=/bin/busybox sh"
    
    exit 0
else
    echo "❌ ISO创建失败，尝试简单方法..."
    
    # 创建数据ISO
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

chmod +x scripts/build-with-kernel.sh

# ========== 构建Docker镜像 ==========
echo "🔨 构建Docker镜像..."
IMAGE_NAME="openwrt-kernel-builder:latest"

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

set +e
docker run --rm \
    --name openwrt-kernel-builder \
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
    echo "   3. 提取: 7z x '$FINAL_ISO' images/openwrt.img"
    
    exit 0
else
    echo ""
    echo "❌ ISO构建失败"
    
    # 显示容器日志
    echo "📋 容器日志 (最后50行):"
    docker logs --tail 50 openwrt-kernel-builder 2>/dev/null || echo "无法获取容器日志"
    
    # 检查输出目录
    echo ""
    echo "📁 输出目录内容:"
    ls -la "$OUTPUT_ABS/" 2>/dev/null || echo "输出目录不存在"
    
    exit 1
fi
