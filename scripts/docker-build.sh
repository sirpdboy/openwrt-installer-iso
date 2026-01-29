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

# 设置Alpine 3.20的官方源
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories

# 更新并安装必要的包（Alpine 3.20可用的包）
RUN apk update && \
    apk add --no-cache \
    bash \
    xorriso \
    syslinux \
    mtools \
    dosfstools \
    grub \
    grub-efi \
    grub-bios \
    e2fsprogs \
    e2fsprogs-extra \
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
    curl \
    wget \
    squashfs-tools \
    cdrtools \
    linux-lts \
    musl-dev \
    gcc \
    make \
    binutils \
    && rm -rf /var/cache/apk/*

# 修复GRUB安装问题 - 忽略overlay文件系统错误
RUN set -e; \
    apk add --no-cache grub grub-efi grub-bios || true; \
    # 检查grub工具是否可用，如果触发脚本失败，手动修复
    if [ ! -f /usr/sbin/grub-mkimage ] && [ -f /usr/bin/grub-mkimage ]; then \
        ln -sf /usr/bin/grub-mkimage /usr/sbin/grub-mkimage; \
    fi; \
    if [ ! -f /usr/sbin/grub-mkstandalone ] && [ -f /usr/bin/grub-mkstandalone ]; then \
        ln -sf /usr/bin/grub-mkstandalone /usr/sbin/grub-mkstandalone; \
    fi; \
    echo "GRUB tools checked and fixed if needed"

# 验证关键工具
RUN echo "验证安装:" && \
    ls -la /usr/sbin/grub-* /usr/bin/grub-* 2>/dev/null | head -10 && \
    which xorriso && \
    which mkfs.fat && \
    echo "GRUB tools: $(which grub-mkimage 2>/dev/null || which grub-mkstandalone 2>/dev/null || echo 'grub tools not found')"

# 创建必要的设备节点（用于构建过程）
RUN mknod -m 0644 /dev/loop0 b 7 0 2>/dev/null || true && \
    mknod -m 0644 /dev/loop1 b 7 1 2>/dev/null || true

WORKDIR /work

# 复制构建脚本
COPY scripts/build-iso-alpine.sh /build.sh
RUN chmod +x /build.sh

ENTRYPOINT ["/build.sh"]

DOCKERFILE_EOF

# 更新版本号
sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/g" "$DOCKERFILE_PATH"

# 创建完整的Alpine构建脚本
mkdir -p scripts
cat > scripts/build-iso-alpine.sh << 'BUILD_SCRIPT_EOF'
#!/bin/bash
set -e

echo "=== OpenWRT ISO Builder for Alpine 3.20 (Fixed) ==="
echo "==================================================="

# 输入文件
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"

# 检查输入文件
if [ ! -f "$INPUT_IMG" ]; then
    echo "❌ 错误: 输入文件不存在: $INPUT_IMG"
    exit 1
fi

echo "✅ 输入文件: $INPUT_IMG ($(du -h "$INPUT_IMG" | cut -f1))"
echo "✅ 输出目录: /output"
echo ""

# ========== 第1步：准备工作区 ==========
echo "[1/8] 📁 创建工作区..."
WORK_DIR="/tmp/openwrt_build_$(date +%s)"
ISO_DIR="$WORK_DIR/iso"
STAGING_DIR="$WORK_DIR/staging"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$ISO_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub,isolinux,live,images}

echo "工作区: $WORK_DIR"
echo "暂存区: $STAGING_DIR"
echo ""

# ========== 第2步：获取Linux内核 ==========
echo "[2/8] 🔧 获取Linux内核..."

# 首先确保安装了linux-lts
if ! apk info -e linux-lts >/dev/null 2>&1; then
    echo "安装linux-lts内核..."
    apk add --no-cache linux-lts 2>/dev/null || true
fi

# 查找可用的内核
KERNEL_FOUND=false
echo "搜索内核文件..."
find /boot -name "vmlinuz*" 2>/dev/null | head -5

for kernel_path in /boot/vmlinuz-lts /boot/vmlinuz-generic /boot/vmlinuz; do
    if [ -f "$kernel_path" ]; then
        cp "$kernel_path" "$STAGING_DIR/live/vmlinuz"
        KERNEL_FOUND=true
        echo "✅ 找到内核: $(basename "$kernel_path")"
        
        # 验证内核文件
        echo "内核信息:"
        file "$STAGING_DIR/live/vmlinuz" 2>/dev/null || true
        echo "内核大小: $(du -h "$STAGING_DIR/live/vmlinuz" 2>/dev/null | cut -f1 || echo "未知")"
        break
    fi
done

# 如果还没找到，尝试直接下载
if [ "$KERNEL_FOUND" = false ]; then
    echo "尝试下载内核..."
    # 从Alpine仓库下载linux-lts包并提取内核
    TEMP_DIR="/tmp/kernel_extract_$(date +%s)"
    mkdir -p "$TEMP_DIR"
    
    if curl -L -o "$TEMP_DIR/linux-lts.apk" \
        "https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/linux-lts-6.6.35-r0.apk" \
        2>/dev/null; then
        
        tar -xzOf "$TEMP_DIR/linux-lts.apk" boot/vmlinuz-lts > "$STAGING_DIR/live/vmlinuz" 2>/dev/null
        if [ -s "$STAGING_DIR/live/vmlinuz" ]; then
            KERNEL_FOUND=true
            echo "✅ 从APK包提取内核成功"
        fi
    fi
    
    rm -rf "$TEMP_DIR"
fi

if [ "$KERNEL_FOUND" = false ]; then
    echo "❌ 致命错误: 无法获取Linux内核，构建终止"
    exit 1
fi
echo ""

# ========== 第3步：创建正确的initrd ==========
echo "[3/8] 🔧 创建initrd (关键修复步骤)..."

INITRD_DIR="/tmp/initrd_root_$(date +%s)"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"

echo "创建init脚本..."
cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh
# OpenWRT安装系统init脚本
# 注意：第一行必须是#!/bin/busybox sh

# 挂载必要的文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 挂载tmpfs
mount -t tmpfs tmpfs /tmp

# 设置PATH
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

clear
cat << "BANNER"

╔══════════════════════════════════════════════════╗
║         OpenWRT Installation System              ║
║             (Alpine 3.20 based)                  ║
╚══════════════════════════════════════════════════╝

BANNER

echo "系统启动完成"
echo "正在查找安装介质..."

# 查找ISO设备
ISO_MOUNTED=false
for dev in /dev/sr0 /dev/cdrom /dev/sr*; do
    if [ -b "$dev" ]; then
        echo "尝试挂载 $dev..."
        if mount -t iso9660 -o ro "$dev" /mnt 2>/dev/null; then
            ISO_MOUNTED=true
            echo "✅ 成功挂载安装介质"
            break
        fi
    fi
done

# 查找OpenWRT镜像
IMG_PATH=""
if [ -f "/mnt/images/openwrt.img" ]; then
    IMG_PATH="/mnt/images/openwrt.img"
    echo "✅ 找到OpenWRT镜像"
elif [ -f "/openwrt.img" ]; then
    IMG_PATH="/openwrt.img"
    echo "✅ 使用内置OpenWRT镜像"
else
    echo "❌ 错误: 未找到OpenWRT镜像!"
    echo "进入救援模式..."
    exec /bin/sh
fi

# 显示可用磁盘
echo ""
echo "可用磁盘:"
echo "=========="
if command -v lsblk >/dev/null 2>&1; then
    lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -v '^$' || echo "无法列出磁盘"
else
    echo "设备列表:"
    for disk in /dev/sd[a-z] /dev/hd[a-z]; do
        [ -b "$disk" ] && echo "  $disk"
    done
fi
echo "=========="

# 安装菜单
while true; do
    echo ""
    echo "请选择:"
    echo "  1) 安装OpenWRT到磁盘"
    echo "  2) 查看磁盘详情"
    echo "  3) 进入Shell"
    echo "  4) 重启"
    echo ""
    read -p "选择 [1-4]: " choice
    
    case "$choice" in
        1)
            echo ""
            read -p "输入目标磁盘 (例如: sda): " target_disk
            
            if [ -z "$target_disk" ]; then
                echo "❌ 请输入磁盘名"
                continue
            fi
            
            if [ ! -b "/dev/$target_disk" ]; then
                echo "❌ 磁盘不存在: /dev/$target_disk"
                continue
            fi
            
            echo ""
            echo "⚠️  警告: 这将完全擦除 /dev/$target_disk!"
            read -p "确认安装? 输入 YES: " confirm
            
            if [ "$confirm" != "YES" ]; then
                echo "安装取消"
                continue
            fi
            
            echo ""
            echo "开始安装..."
            if command -v pv >/dev/null 2>&1; then
                pv "$IMG_PATH" | dd of="/dev/$target_disk" bs=4M
            else
                dd if="$IMG_PATH" of="/dev/$target_disk" bs=4M status=progress
            fi
            
            sync
            echo ""
            echo "✅ 安装完成!"
            echo "10秒后重启..."
            sleep 10
            reboot -f
            ;;
        2)
            echo ""
            echo "磁盘详情:"
            fdisk -l 2>/dev/null || echo "无法显示详情"
            ;;
        3)
            echo ""
            echo "进入shell..."
            exec /bin/sh
            ;;
        4)
            echo "重启..."
            reboot -f
            ;;
        *)
            echo "无效选择"
            ;;
    esac
done
INIT_EOF

# 确保init文件可执行
chmod 755 "$INITRD_DIR/init"

echo "设置busybox..."
# 获取busybox
if ! command -v busybox >/dev/null 2>&1; then
    echo "安装busybox..."
    apk add --no-cache busybox 2>/dev/null || true
fi

BUSYBOX_PATH=$(which busybox 2>/dev/null)
if [ -f "$BUSYBOX_PATH" ]; then
    mkdir -p "$INITRD_DIR/bin"
    cp "$BUSYBOX_PATH" "$INITRD_DIR/bin/busybox"
    chmod 755 "$INITRD_DIR/bin/busybox"
    
    # 创建符号链接
    cd "$INITRD_DIR/bin"
    ./busybox --list | while read app; do
        ln -s busybox "$app" 2>/dev/null || true
    done
    cd - >/dev/null
    echo "✅ busybox配置完成"
else
    echo "❌ 错误: 找不到busybox!"
    exit 1
fi

echo "创建设备节点..."
mkdir -p "$INITRD_DIR/dev"
mknod "$INITRD_DIR/dev/console" c 5 1 2>/dev/null || true
mknod "$INITRD_DIR/dev/null" c 1 3 2>/dev/null || true
mknod "$INITRD_DIR/dev/zero" c 1 5 2>/dev/null || true

# 创建必要目录
mkdir -p "$INITRD_DIR"/{proc,sys,tmp,mnt}

echo "打包initrd..."
cd "$INITRD_DIR"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd.img"

if [ -f "$STAGING_DIR/live/initrd.img" ]; then
    INITRD_SIZE=$(du -h "$STAGING_DIR/live/initrd.img" 2>/dev/null | cut -f1 || echo "未知")
    echo "✅ initrd创建成功 ($INITRD_SIZE)"
else
    echo "❌ initrd创建失败"
    exit 1
fi

cd - >/dev/null
rm -rf "$INITRD_DIR"
echo ""

# ========== 第4步：复制OpenWRT镜像 ==========
echo "[4/8] 📦 复制OpenWRT镜像..."
cp "$INPUT_IMG" "$STAGING_DIR/images/openwrt.img"
echo "✅ OpenWRT镜像已复制"
echo ""

# ========== 第5步：创建BIOS引导配置 ==========
echo "[5/8] 🔧 创建BIOS引导配置..."

# 复制syslinux文件
echo "复制syslinux文件..."
for file in isolinux.bin ldlinux.c32 libutil.c32 menu.c32 vesamenu.c32; do
    for dir in /usr/share/syslinux /usr/lib/syslinux /usr/lib/ISOLINUX; do
        if [ -f "$dir/$file" ]; then
            cp "$dir/$file" "$STAGING_DIR/isolinux/" 2>/dev/null || true
            break
        fi
    done
done

# 查找isohdpfx.bin
for dir in /usr/share/syslinux /usr/lib/syslinux /usr/lib/ISOLINUX; do
    if [ -f "$dir/isohdpfx.bin" ]; then
        cp "$dir/isohdpfx.bin" "$WORK_DIR/isohdpfx.bin"
        echo "✅ 找到isohdpfx.bin"
        break
    fi
done

# 创建ISOLINUX配置
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG_EOF'
DEFAULT vesamenu.c32
PROMPT 0
TIMEOUT 50
ONTIMEOUT install

MENU TITLE OpenWRT Installer

LABEL install
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 init=/bin/sh

LABEL local
  MENU LABEL Boot from local disk
  LOCALBOOT 0x80
ISOLINUX_CFG_EOF

echo "✅ BIOS引导配置完成"
echo ""

# ========== 第6步：创建UEFI引导配置 ==========
echo "[6/8] 🔧 创建UEFI引导配置..."

# 创建GRUB配置
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG_EOF'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz console=tty0
    initrd /live/initrd.img
}

menuentry "Emergency Shell" {
    linux /live/vmlinuz console=tty0 init=/bin/sh
    initrd /live/initrd.img
}

menuentry "Boot from local disk" {
    exit
}
GRUB_CFG_EOF

# 生成GRUB EFI文件
echo "生成GRUB EFI文件..."
GRUB_EFI_GENERATED=false

# 方法1: 尝试grub-mkstandalone
if command -v grub-mkstandalone >/dev/null 2>&1; then
    echo "使用grub-mkstandalone..."
    
    TEMP_GRUB="/tmp/grub_temp_$(date +%s)"
    mkdir -p "$TEMP_GRUB/boot/grub"
    cp "$STAGING_DIR/boot/grub/grub.cfg" "$TEMP_GRUB/boot/grub/"
    
    if grub-mkstandalone \
        --format=x86_64-efi \
        --output="$TEMP_GRUB/bootx64.efi" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos fat ext2 iso9660" \
        "boot/grub/grub.cfg=$TEMP_GRUB/boot/grub/grub.cfg" 2>/dev/null; then
        
        cp "$TEMP_GRUB/bootx64.efi" "$STAGING_DIR/EFI/boot/bootx64.efi"
        GRUB_EFI_GENERATED=true
        echo "✅ GRUB EFI生成成功"
    fi
    
    rm -rf "$TEMP_GRUB"
fi

# 方法2: 尝试grub-mkimage
if [ "$GRUB_EFI_GENERATED" = false ] && command -v grub-mkimage >/dev/null 2>&1; then
    echo "使用grub-mkimage..."
    
    if grub-mkimage \
        -O x86_64-efi \
        -o "$STAGING_DIR/EFI/boot/bootx64.efi" \
        -p /boot/grub \
        fat iso9660 part_gpt part_msdos normal boot linux 2>/dev/null; then
        
        GRUB_EFI_GENERATED=true
        echo "✅ GRUB EFI生成成功"
    fi
fi

# 如果生成了EFI文件，创建引导镜像
if [ "$GRUB_EFI_GENERATED" = true ] && [ -f "$STAGING_DIR/EFI/boot/bootx64.efi" ]; then
    echo "创建EFI引导镜像..."
    
    EFI_IMG="$WORK_DIR/efiboot.img"
    dd if=/dev/zero of="$EFI_IMG" bs=1024 count=2880 2>/dev/null
    mkfs.fat -F 12 "$EFI_IMG" 2>/dev/null || mkfs.vfat "$EFI_IMG" 2>/dev/null
    
    # 挂载并复制
    MOUNT_DIR="$WORK_DIR/efi_mount"
    mkdir -p "$MOUNT_DIR"
    
    if mount -o loop "$EFI_IMG" "$MOUNT_DIR" 2>/dev/null; then
        mkdir -p "$MOUNT_DIR/EFI/boot"
        cp "$STAGING_DIR/EFI/boot/bootx64.efi" "$MOUNT_DIR/EFI/boot/"
        umount "$MOUNT_DIR"
        cp "$EFI_IMG" "$STAGING_DIR/EFI/boot/efiboot.img"
        echo "✅ EFI引导镜像创建成功"
    else
        echo "⚠ 无法挂载EFI镜像"
    fi
    
    rm -rf "$MOUNT_DIR" "$EFI_IMG"
else
    echo "⚠ 无法生成GRUB EFI文件"
fi

echo "✅ UEFI引导配置完成"
echo ""

# ========== 第7步：构建ISO ==========
echo "[7/8] 📦 构建ISO文件..."

cd "$WORK_DIR"

# 检查是否有EFI引导镜像
EFI_IMG_PATH="$STAGING_DIR/EFI/boot/efiboot.img"
ISOHDPFX_PATH="$WORK_DIR/isohdpfx.bin"

if [ -f "$EFI_IMG_PATH" ] && [ -f "$ISOHDPFX_PATH" ]; then
    echo "构建混合引导ISO (BIOS + UEFI)..."
    
    xorriso -as mkisofs \
        -r \
        -V "OPENWRT_INSTALL" \
        -o "/output/openwrt.iso" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr "$ISOHDPFX_PATH" \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$STAGING_DIR" 2>&1 | tail -5
else
    echo "构建BIOS引导ISO..."
    
    xorriso -as mkisofs \
        -r \
        -V "OPENWRT_INSTALL" \
        -o "/output/openwrt.iso" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        "$STAGING_DIR" 2>&1 | tail -5
fi

echo ""

# ========== 第8步：验证结果 ==========
echo "[8/8] 🔍 验证构建结果..."

if [ -f "/output/openwrt.iso" ]; then
    ISO_SIZE=$(du -h "/output/openwrt.iso" 2>/dev/null | cut -f1 || echo "未知")
    echo "✅ ✅ ✅ ISO构建成功! ✅ ✅ ✅"
    echo ""
    echo "📊 ISO信息:"
    echo "  文件: /output/openwrt.iso"
    echo "  大小: $ISO_SIZE"
    echo ""
    
    # 检查ISO
    if command -v file >/dev/null 2>&1; then
        FILE_INFO=$(file "/output/openwrt.iso" 2>/dev/null || echo "无法获取文件信息")
        echo "类型: $FILE_INFO"
    fi
    
    # 创建构建信息
    cat > "/output/build-info.txt" << EOF
OpenWRT Alpine Installer
=======================
构建时间: $(date)
ISO大小:  $ISO_SIZE
引导支持: $( [ -f "$EFI_IMG_PATH" ] && echo "BIOS + UEFI" || echo "BIOS only" )

包含:
  - OpenWRT镜像: images/openwrt.img
  - Linux内核:   live/vmlinuz
  - Initramfs:   live/initrd.img

使用方法:
  1. sudo dd if=openwrt.iso of=/dev/sdX bs=4M status=progress
  2. 从USB启动
  3. 选择安装目标

注意: 安装会完全擦除目标磁盘!
EOF
    
    echo "✅ 构建信息保存到: /output/build-info.txt"
    
    # 清理
    rm -rf "$WORK_DIR"
    
    exit 0
else
    echo "❌ ISO创建失败"
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
