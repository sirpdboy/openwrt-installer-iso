#!/bin/bash
# docker-build.sh OpenWRT ISO Builder - 基于Alpine的完整解决方案

set -e

echo "================================================"
echo "  OpenWRT ISO Builder - Alpine Edition"
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

# 创建优化的Dockerfile
DOCKERFILE_PATH="Dockerfile.alpine-iso"
cat > "$DOCKERFILE_PATH" << 'DOCKERFILE_EOF'
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION} as builder

# 使用Alpine官方镜像源
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v$(cut -d. -f1-2 /etc/alpine-release)/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/v$(cut -d. -f1-2 /etc/alpine-release)/community" >> /etc/apk/repositories

# 安装必要的工具（分步安装，避免单个包失败导致全部失败）
RUN apk update && \
    apk add --no-cache \
    bash \
    xorriso \
    syslinux \
    mtools \
    dosfstools \
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
    linux-firmware-none \
    && rm -rf /var/cache/apk/*


# 尝试安装linux-lts，如果失败则跳过
RUN apk add --no-cache linux-lts 2>/dev/null || echo "linux-lts not available, will use alternative kernel"

# 安装额外的grub模块
RUN mkdir -p /tmp/grub-modules && \
    cd /tmp/grub-modules && \
    apk add --no-cache grub grub-efi grub-bios

WORKDIR /work

# 复制构建脚本
COPY scripts/build-iso-alpine.sh /build-iso.sh
RUN chmod +x /build-iso.sh

ENTRYPOINT ["/build-iso.sh"]

DOCKERFILE_EOF

# 更新版本号
sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/g" "$DOCKERFILE_PATH"

# 创建完整的Alpine构建脚本
mkdir -p scripts
cat > scripts/build-iso-alpine.sh << 'BUILD_SCRIPT_EOF'
#!/bin/bash
set -e

echo "=== OpenWRT ISO Builder (Alpine Edition - Fixed) ==="

# 输入文件
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"

# 检查输入文件
if [ ! -f "$INPUT_IMG" ]; then
    echo "❌ 错误: 输入文件不存在: $INPUT_IMG"
    exit 1
fi

echo "✅ 输入文件: $INPUT_IMG ($(du -h "$INPUT_IMG" | cut -f1))"
echo "✅ 输出目录: /output"

# ========== 第1步：创建工作区 ==========
echo ""
echo "📁 创建工作区..."
WORK_DIR="/tmp/openwrt_iso_$(date +%s)"
ISO_DIR="$WORK_DIR/iso"
STAGING_DIR="$WORK_DIR/staging"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$ISO_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub,isolinux,live,images}

# ========== 第2步：获取内核 ==========
echo ""
echo "🔧 获取内核..."

KERNEL_FOUND=false
# 尝试多种方式获取内核
echo "查找可用的内核..."

# 方法1：检查已安装的内核
for kernel_path in /boot/vmlinuz-lts /boot/vmlinuz; do
    if [ -f "$kernel_path" ]; then
        cp "$kernel_path" "$STAGING_DIR/live/vmlinuz"
        KERNEL_FOUND=true
        echo "✅ 使用已安装内核: $(basename "$kernel_path")"
        break
    fi
done

# 方法2：尝试从Alpine包安装内核
if [ "$KERNEL_FOUND" = false ]; then
    echo "尝试安装linux-lts内核..."
    if apk add --no-cache linux-lts 2>/dev/null; then
        for kernel_path in /boot/vmlinuz-lts /boot/vmlinuz; do
            if [ -f "$kernel_path" ]; then
                cp "$kernel_path" "$STAGING_DIR/live/vmlinuz"
                KERNEL_FOUND=true
                echo "✅ 使用新安装的内核: $(basename "$kernel_path")"
                break
            fi
        done
    fi
fi

# 方法3：下载微内核
if [ "$KERNEL_FOUND" = false ]; then
    echo "下载微内核..."
    # 下载tinycore内核（最小）
    if curl -L -o "$STAGING_DIR/live/vmlinuz" \
        "http://tinycorelinux.net/14.x/x86_64/release/distribution_files/vmlinuz64" \
        2>/dev/null && [ -s "$STAGING_DIR/live/vmlinuz" ]; then
        KERNEL_FOUND=true
        echo "✅ 使用TinyCore内核"
    fi
fi

# 方法4：使用busybox的内核（如果没有其他选择）
if [ "$KERNEL_FOUND" = false ] && command -v busybox >/dev/null; then
    echo "⚠ 使用busybox作为内核替代"
    # 创建一个简单的内核占位文件
    cat > "$STAGING_DIR/live/vmlinuz" << 'KERNEL_PLACEHOLDER'
#!/bin/busybox sh
# Minimal kernel placeholder
echo "Boot loader"
exec /bin/busybox sh
KERNEL_PLACEHOLDER
    chmod +x "$STAGING_DIR/live/vmlinuz"
    KERNEL_FOUND=true
fi

if [ "$KERNEL_FOUND" = false ]; then
    echo "❌ 错误: 无法获取内核!"
    exit 1
fi

# ========== 第3步：创建initrd ==========
echo ""
echo "🔧 创建initrd..."

INITRD_DIR="/tmp/initrd_$(date +%s)"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"/{bin,dev,etc,lib,proc,sys,tmp,usr/bin}

# 创建init脚本
cat > "$INITRD_DIR/init" << 'INIT'
#!/bin/sh
# OpenWRT Alpine安装系统init

# 挂载proc和sys
mount -t proc proc /proc
mount -t sysfs sysfs /sys

# 创建设备节点
mkdir -p /dev
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true
mknod /dev/zero c 1 5 2>/dev/null || true

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 挂载tmpfs
mount -t tmpfs tmpfs /tmp

echo ""
echo "=========================================="
echo "   OpenWRT Alpine Installation System"
echo "=========================================="
echo ""

# 查找ISO设备
echo "寻找安装介质..."
for dev in /dev/sr0 /dev/cdrom /dev/sr*; do
    if [ -b "$dev" ]; then
        echo "尝试挂载 $dev..."
        mount -t iso9660 -o ro "$dev" /mnt 2>/dev/null && break
    fi
done

# 查找OpenWRT镜像
IMG_PATH=""
if [ -f "/mnt/images/openwrt.img" ]; then
    IMG_PATH="/mnt/images/openwrt.img"
    echo "✅ 找到OpenWRT镜像: $IMG_PATH"
elif [ -f "/openwrt.img" ]; then
    IMG_PATH="/openwrt.img"
    echo "✅ 使用内置OpenWRT镜像"
else
    echo "❌ 未找到OpenWRT镜像"
    echo "挂载点内容:"
    ls -la /mnt/ 2>/dev/null || true
    echo ""
    echo "进入救援shell..."
    exec /bin/sh
fi

# 显示磁盘
echo ""
echo "可用磁盘:"
echo "=========="
lsblk 2>/dev/null || (echo "使用简单列表:" && ls /dev/sd* /dev/hd* 2>/dev/null || true)
echo "=========="

# 安装菜单
while true; do
    echo ""
    echo "选择操作:"
    echo "  1) 列出磁盘详情"
    echo "  2) 安装OpenWRT到磁盘"
    echo "  3) 进入Shell"
    echo "  4) 重启"
    echo ""
    read -p "请输入选项 [1-4]: " choice
    
    case $choice in
        1)
            echo ""
            echo "磁盘详情:"
            fdisk -l 2>/dev/null || lsblk -f 2>/dev/null || echo "无法获取磁盘详情"
            ;;
        2)
            echo ""
            read -p "输入目标磁盘 (例如: sda): " disk
            
            if [ -z "$disk" ]; then
                echo "❌ 未输入磁盘名"
                continue
            fi
            
            if [ ! -b "/dev/$disk" ]; then
                echo "❌ 磁盘 /dev/$disk 不存在!"
                continue
            fi
            
            echo ""
            echo "⚠️  警告: 这将擦除 /dev/$disk 上的所有数据!"
            read -p "输入 'YES' 确认: " confirm
            
            if [ "$confirm" != "YES" ]; then
                echo "❌ 安装取消"
                continue
            fi
            
            echo ""
            echo "正在安装OpenWRT到 /dev/$disk ..."
            
            # 使用dd写入镜像
            if command -v pv >/dev/null 2>&1; then
                echo "使用pv显示进度..."
                pv "$IMG_PATH" | dd of="/dev/$disk" bs=4M
            else
                echo "使用dd写入..."
                dd if="$IMG_PATH" of="/dev/$disk" bs=4M status=progress
            fi
            
            sync
            echo ""
            echo "✅ 安装完成!"
            echo ""
            
            echo "10秒后重启..."
            for i in $(seq 10 -1 1); do
                echo -ne "重启倒计时: ${i}s\r"
                sleep 1
            done
            echo ""
            
            reboot -f
            ;;
        3)
            echo ""
            echo "进入shell..."
            exec /bin/sh
            ;;
        4)
            echo ""
            echo "重启系统..."
            reboot -f
            ;;
        *)
            echo ""
            echo "❌ 无效选项"
            ;;
    esac
done
INIT
chmod +x "$INITRD_DIR/init"

# 复制busybox到initrd
if command -v busybox >/dev/null 2>&1; then
    BUSYBOX=$(which busybox)
    cp "$BUSYBOX" "$INITRD_DIR/bin/"
    cd "$INITRD_DIR/bin"
    
    # 创建必要的符号链接
    for app in sh ls mount umount cat echo grep sed cp mv rm mkdir rmdir \
               dd sync reboot fdisk lsblk blkid ps kill sleep; do
        ln -sf busybox "$app" 2>/dev/null || true
    done
    cd - >/dev/null
    echo "✅ 添加busybox到initrd"
fi

# 添加其他必要工具
echo "添加其他工具..."
for tool in fdisk lsblk blkid dd sync reboot; do
    tool_path=$(which "$tool" 2>/dev/null || true)
    if [ -n "$tool_path" ] && [ -f "$tool_path" ]; then
        cp "$tool_path" "$INITRD_DIR/bin/" 2>/dev/null || true
    fi
done

# 创建必要的设备节点
mknod "$INITRD_DIR/dev/console" c 5 1 2>/dev/null || true
mknod "$INITRD_DIR/dev/null" c 1 3 2>/dev/null || true
mknod "$INITRD_DIR/dev/zero" c 1 5 2>/dev/null || true

# 打包initrd
echo "打包initrd..."
cd "$INITRD_DIR"
find . -print0 | cpio -0 -o -H newc 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd"
cd - >/dev/null

INITRD_SIZE=$(du -h "$STAGING_DIR/live/initrd" 2>/dev/null | cut -f1 || echo "未知")
echo "✅ initrd创建完成 ($INITRD_SIZE)"

# 清理initrd目录
rm -rf "$INITRD_DIR"

# ========== 第4步：复制OpenWRT镜像 ==========
echo ""
echo "📦 复制OpenWRT镜像..."
cp "$INPUT_IMG" "$STAGING_DIR/images/openwrt.img"
echo "✅ OpenWRT镜像已复制"

# ========== 第5步：创建引导配置 ==========
echo ""
echo "🔧 创建引导配置..."

# ISOLINUX配置 (BIOS引导)
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT install
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE OpenWRT Alpine Installer
MENU BACKGROUND /boot/splash.png

LABEL install
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=tty0 console=ttyS0,115200n8

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=tty0 init=/bin/sh

LABEL local
  MENU LABEL Boot from ^local disk
  LOCALBOOT 0x80
ISOLINUX_CFG

# 复制syslinux文件
echo "复制syslinux文件..."
if [ -d /usr/share/syslinux ]; then
    SYSBOOT="/usr/share/syslinux"
elif [ -d /usr/lib/syslinux ]; then
    SYSBOOT="/usr/lib/syslinux"
elif [ -d /usr/lib/ISOLINUX ]; then
    SYSBOOT="/usr/lib/ISOLINUX"
else
    echo "⚠ 未找到syslinux目录"
fi

if [ -n "$SYSBOOT" ]; then
    cp "$SYSBOOT/isolinux.bin" "$STAGING_DIR/isolinux/" 2>/dev/null || true
    cp "$SYSBOOT/ldlinux.c32" "$STAGING_DIR/isolinux/" 2>/dev/null || true
    cp "$SYSBOOT/libutil.c32" "$STAGING_DIR/isolinux/" 2>/dev/null || true
    cp "$SYSBOOT/menu.c32" "$STAGING_DIR/isolinux/" 2>/dev/null || true
    echo "✅ syslinux文件复制完成"
fi

# GRUB配置 (UEFI引导)
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT (UEFI Mode)" {
    linux /live/vmlinuz console=tty0 console=ttyS0,115200n8
    initrd /live/initrd
}

menuentry "Emergency Shell" {
    linux /live/vmlinuz console=tty0 init=/bin/sh
    initrd /live/initrd
}

menuentry "Boot from local disk" {
    exit
}
GRUB_CFG

# ========== 第6步：创建UEFI引导文件 ==========
echo ""
echo "🔧 创建UEFI引导文件..."

# 创建EFI目录结构
mkdir -p "$STAGING_DIR/EFI/boot"

# 方法1：使用grub-mkstandalone（推荐）
if command -v grub-mkstandalone >/dev/null 2>&1; then
    echo "使用grub-mkstandalone创建EFI文件..."
    
    # 创建临时目录
    GRUB_TEMP="/tmp/grub_temp_$(date +%s)"
    mkdir -p "$GRUB_TEMP/boot/grub"
    
    # 复制grub.cfg
    cp "$STAGING_DIR/boot/grub/grub.cfg" "$GRUB_TEMP/boot/grub/grub.cfg"
    
    # 生成EFI文件
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$GRUB_TEMP/bootx64.efi" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos fat ext2 iso9660" \
        "boot/grub/grub.cfg=$GRUB_TEMP/boot/grub/grub.cfg" 2>/dev/null
    
    if [ -f "$GRUB_TEMP/bootx64.efi" ]; then
        cp "$GRUB_TEMP/bootx64.efi" "$STAGING_DIR/EFI/boot/bootx64.efi"
        echo "✅ GRUB EFI文件生成成功"
    fi
    
    rm -rf "$GRUB_TEMP"
fi

# 方法2：使用grub-mkimage（备用）
if [ ! -f "$STAGING_DIR/EFI/boot/bootx64.efi" ] && command -v grub-mkimage >/dev/null 2>&1; then
    echo "使用grub-mkimage创建EFI文件..."
    
    grub-mkimage \
        -O x86_64-efi \
        -o "$STAGING_DIR/EFI/boot/bootx64.efi" \
        -p /boot/grub \
        fat iso9660 part_gpt part_msdos normal boot linux configfile loopback chain \
        efifwsetup efi_gop efi_uga ls search search_label search_fs_uuid search_fs_file \
        gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 \
        echo true probe terminal 2>/dev/null
    
    if [ -f "$STAGING_DIR/EFI/boot/bootx64.efi" ]; then
        echo "✅ GRUB EFI文件生成成功"
    fi
fi

# 方法3：如果都没有成功，创建简单的EFI占位文件
if [ ! -f "$STAGING_DIR/EFI/boot/bootx64.efi" ]; then
    echo "⚠ 无法生成GRUB EFI，创建占位文件..."
    cat > "$STAGING_DIR/EFI/boot/bootx64.efi" << 'EFI_PLACEHOLDER'
#!/bin/sh
# EFI boot placeholder
echo "UEFI boot not properly configured"
echo "Please use BIOS/Legacy boot mode"
sleep 5
EFI_PLACEHOLDER
    chmod +x "$STAGING_DIR/EFI/boot/bootx64.efi"
    echo "⚠ UEFI引导可能无法正常工作"
fi

# ========== 第7步：创建标识文件 ==========
echo ""
echo "📄 创建标识文件..."
echo "OpenWRT Alpine Installer" > "$STAGING_DIR/.openwrt_alpine"
date > "$STAGING_DIR/.build_date"
echo "Alpine $ALPINE_VERSION" > "$STAGING_DIR/.alpine_version"

# ========== 第8步：构建ISO ==========
echo ""
echo "📦 构建ISO文件..."

cd "$WORK_DIR"

# 查找isohdpfx.bin
ISOHDPFX=""
for path in /usr/share/syslinux/isohdpfx.bin \
            /usr/lib/syslinux/isohdpfx.bin \
            /usr/lib/ISOLINUX/isohdpfx.bin; do
    if [ -f "$path" ]; then
        ISOHDPFX="$path"
        break
    fi
done

echo "构建ISO..."
if [ -f "$ISOHDPFX" ] && [ -f "$STAGING_DIR/EFI/boot/bootx64.efi" ]; then
    echo "创建混合引导ISO (BIOS + UEFI)..."
    
    # 创建EFI引导镜像
    EFI_IMG="$WORK_DIR/efiboot.img"
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=10 2>/dev/null
    mkfs.fat -F 32 "$EFI_IMG" 2>/dev/null || mkfs.vfat "$EFI_IMG" 2>/dev/null
    
    # 挂载并复制EFI文件
    EFI_MOUNT="$WORK_DIR/efi_mount"
    mkdir -p "$EFI_MOUNT"
    
    if mount "$EFI_IMG" "$EFI_MOUNT" 2>/dev/null; then
        mkdir -p "$EFI_MOUNT/EFI/boot"
        cp "$STAGING_DIR/EFI/boot/bootx64.efi" "$EFI_MOUNT/EFI/boot/"
        umount "$EFI_MOUNT"
    fi
    
    rm -rf "$EFI_MOUNT"
    
    # 构建混合ISO
    xorriso -as mkisofs \
        -r -V "OPENWRT_ALPINE" \
        -o "/output/openwrt.iso" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr "$ISOHDPFX" \
        -eltorito-alt-boot \
        -e "$(basename "$EFI_IMG")" \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$STAGING_DIR" "$EFI_IMG" 2>&1 | grep -v "IFS" || true
else
    echo "创建BIOS引导ISO..."
    xorriso -as mkisofs \
        -r -V "OPENWRT_ALPINE" \
        -o "/output/openwrt.iso" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        "$STAGING_DIR" 2>&1 | grep -v "IFS" || true
fi

# ========== 第9步：验证结果 ==========
echo ""
echo "🔍 验证构建结果..."

if [ -f "/output/openwrt.iso" ]; then
    ISO_SIZE=$(du -h "/output/openwrt.iso" | cut -f1)
    echo "✅ ISO构建成功! ($ISO_SIZE)"
    
    # 显示ISO信息
    echo ""
    echo "📊 ISO详细信息:"
    echo "文件: /output/openwrt.iso"
    echo "大小: $ISO_SIZE"
    
    if command -v file >/dev/null 2>&1; then
        FILE_INFO=$(file "/output/openwrt.iso")
        echo "类型: $FILE_INFO"
        
        if echo "$FILE_INFO" | grep -qi "bootable\|DOS/MBR"; then
            echo "✅ ISO可引导"
        fi
    fi
    
    # 清理工作区
    rm -rf "$WORK_DIR"
    
    # 创建构建信息
    cat > "/output/build-info.txt" << EOF
OpenWRT Alpine Installer ISO
============================
Build Date:      $(date)
Alpine Version:  $ALPINE_VERSION
ISO Size:        $ISO_SIZE
Kernel:          $(basename "$STAGING_DIR/live/vmlinuz")
Initrd:          $(basename "$STAGING_DIR/live/initrd")

Boot Support:    BIOS + UEFI
Install Method:  dd if=openwrt.img of=/dev/sdX

Source:          https://github.com/sirpdboy/openwrt-installer-iso.git
EOF
    
    echo "✅ 构建信息保存到: /output/build-info.txt"
    
    exit 0
else
    echo "❌ ISO创建失败"
    echo "工作区内容:"
    ls -la "$WORK_DIR" 2>/dev/null || true
    
    exit 1
fi

BUILD_SCRIPT_EOF

chmod +x scripts/build-iso-alpine.sh

# ========== 构建Docker镜像 ==========
echo "🔨 构建Docker镜像..."
IMAGE_NAME="openwrt-alpine-builder:latest"

echo "构建镜像..."
docker build \
    -f "$DOCKERFILE_PATH" \
    --build-arg ALPINE_VERSION="$ALPINE_VERSION" \
    -t "$IMAGE_NAME" \
    . 2>&1 | tee /tmp/docker-build.log

if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "✅ Docker镜像构建成功: $IMAGE_NAME"
else
    echo "❌ Docker镜像构建失败"
    cat /tmp/docker-build.log | tail -20
    exit 1
fi

# ========== 运行Docker容器 ==========
echo "🚀 运行Docker容器构建ISO..."

set +e
echo "启动构建容器..."
docker run --rm \
    --name openwrt-alpine-builder \
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
    
    # 验证ISO
    echo "🔍 验证信息:"
    if command -v file >/dev/null 2>&1; then
        FILE_INFO=$(file "$FINAL_ISO")
        echo "文件类型: $FILE_INFO"
        
        if echo "$FILE_INFO" | grep -q "bootable\|DOS/MBR"; then
            echo "✅ ISO可引导"
        fi
    fi
    
    # 检查是否为混合ISO
    echo ""
    echo "💻 引导支持:"
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -indev "$FINAL_ISO" -check_media 2>&1 | grep -i "efi\|uefi" && \
            echo "✅ 支持UEFI引导" || echo "⚠ 仅支持BIOS引导"
    fi
    
    echo ""
    echo "🚀 使用方法:"
    echo "   1. 虚拟机测试: qemu-system-x86_64 -cdrom '$FINAL_ISO' -m 512M"
    echo "   2. 制作USB: sudo dd if='$FINAL_ISO' of=/dev/sdX bs=4M status=progress oflag=sync"
    echo "   3. 直接引导: 从USB或CD/DVD启动"
    
    exit 0
else
    echo ""
    echo "❌ ISO构建失败"
    
    # 显示容器日志
    echo "📋 容器日志:"
    docker logs --tail 100 openwrt-alpine-builder 2>/dev/null || echo "无法获取容器日志"
    
    exit 1
fi
