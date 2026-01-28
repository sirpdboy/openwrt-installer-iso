#!/bin/bash
# docker-build.sh OpenWRT ISO Builder 

set -e

echo "================================================"
echo "  OpenWRT ISO Builder - Minimal Edition"
echo "================================================"
echo ""

# 参数处理
IMG_FILE="$1"
OUTPUT_DIR="${2:-./output}"
ISO_NAME="${3:-openwrt-installer-$(date +%Y%m%d).iso}"
ALPINE_VERSION="${4:-3.20}"
MINIMAL="${5:-true}"

# 基本检查
if [ $# -lt 1 ]; then
    cat << EOF
用法: $0 <img文件> [输出目录] [iso名称] [alpine版本] [最小化模式]

示例:
  $0 ./openwrt.img
  $0 ./openwrt.img ./iso my-openwrt.iso
  $0 ./openwrt.img ./output openwrt.iso 3.19 true
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
echo "  最小化模式: $MINIMAL"
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
DOCKERFILE_PATH="Dockerfile.isobuilder"
cat > "$DOCKERFILE_PATH" << 'DOCKERFILE_EOF'
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION} as builder

# 设置镜像源
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories || true

# 安装必要的包（最小集合）
RUN apk update && apk add --no-cache \
    bash \
    xorriso \
    syslinux \
    grub \
    grub-efi \
    e2fsprogs \
    parted \
    util-linux \
    dosfstools \
    mtools \
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
    jq \
    && rm -rf /var/cache/apk/*

# 验证工具
RUN echo "验证工具安装:" && \
    xorriso --version 2>&1 | head -1 && \
    which grub-mkimage && \
    which mkisofs || which xorriso

WORKDIR /work

# 创建构建脚本
COPY scripts/build-iso.sh /build-iso.sh
RUN chmod +x /build-iso.sh

ENTRYPOINT ["/build-iso.sh"]
DOCKERFILE_EOF

# 更新版本号
sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/" "$DOCKERFILE_PATH"

# 创建优化的构建脚本
mkdir -p scripts
cat > scripts/build-iso.sh << 'BUILD_SCRIPT_EOF'
#!/bin/bash
set -e

echo "=== OpenWRT ISO Builder (优化版) ==="

# 输入文件
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"
MINIMAL="${MINIMAL:-true}"

# 检查输入文件
if [ ! -f "$INPUT_IMG" ]; then
    echo "❌ 错误: 输入文件不存在: $INPUT_IMG"
    exit 1
fi

echo "✅ 输入文件: $INPUT_IMG ($(du -h "$INPUT_IMG" | cut -f1))"
echo "✅ 最小化模式: $MINIMAL"
echo "✅ 输出目录: /output"

# ========== 第1步：创建ISO目录结构 ==========
echo ""
echo "📁 创建ISO目录结构..."
ISO_DIR="/tmp/iso"
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR"/{boot/grub,boot/isolinux,EFI/boot,images,loader/entries}

# 复制OpenWRT镜像
cp "$INPUT_IMG" "$ISO_DIR/images/openwrt.img"
echo "✅ 复制OpenWRT镜像: $(du -h "$ISO_DIR/images/openwrt.img" | cut -f1)"

# ========== 第2步：创建极简initrd ==========
echo ""
echo "🔧 创建极简initrd..."

INITRD_DIR="/tmp/initrd.root"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"

# 创建最简化的init脚本
cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh
# 极简init脚本

# 挂载必要的文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 设置控制台
setsid cttyhack sh

# 如果没有devtmpfs，创建设备
[ -c /dev/console ] || mknod /dev/console c 5 1
[ -c /dev/null ] || mknod /dev/null c 1 3

# 挂载tmpfs
mount -t tmpfs tmpfs /tmp

# 设置环境
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# 查找ISO设备
echo "寻找安装介质..."
for x in $(cd /dev && ls sr* cdrom* hd* sd* 2>/dev/null); do
    if mount -t iso9660 -o ro /dev/$x /tmp/iso 2>/dev/null; then
        echo "找到安装介质: /dev/$x"
        break
    fi
done

# 查找OpenWRT镜像
IMG_PATH=""
for path in /tmp/iso/images/openwrt.img /images/openwrt.img /openwrt.img; do
    if [ -f "$path" ]; then
        IMG_PATH="$path"
        break
    fi
done

if [ -z "$IMG_PATH" ]; then
    echo "错误: 未找到OpenWRT镜像!"
    echo "ISO内容:"
    find /tmp/iso -type f 2>/dev/null | head -20
    exec sh
fi

echo "找到OpenWRT镜像: $IMG_PATH"
echo "大小: $(busybox du -h "$IMG_PATH" 2>/dev/null | cut -f1)"

# 显示磁盘
echo ""
echo "可用磁盘:"
echo "=========="
busybox blkid 2>/dev/null || echo "无法列出磁盘"
echo "=========="

# 安装菜单
cat << MENU

╔══════════════════════════════════════╗
║      OpenWRT 安装程序               ║
╚══════════════════════════════════════╝

选择操作:
1) 显示磁盘信息 (fdisk -l)
2) 安装OpenWRT到磁盘
3) 进入Shell
4) 重启

请输入选项 [1-4]:
MENU

read choice
case $choice in
    1)
        fdisk -l 2>/dev/null || echo "fdisk不可用"
        ;;
    2)
        echo "输入目标磁盘 (例如: sda):"
        read disk
        
        if [ ! -b "/dev/$disk" ]; then
            echo "错误: 磁盘 /dev/$disk 不存在!"
            exec sh
        fi
        
        echo "警告: 这将擦除 /dev/$disk 上的所有数据!"
        echo "输入 'YES' 确认:"
        read confirm
        
        if [ "$confirm" = "YES" ]; then
            echo "正在写入OpenWRT镜像到 /dev/$disk ..."
            if command -v pv >/dev/null 2>&1; then
                pv "$IMG_PATH" | dd of="/dev/$disk" bs=4M oflag=sync
            else
                dd if="$IMG_PATH" of="/dev/$disk" bs=4M status=progress oflag=sync
            fi
            sync
            echo "安装完成!"
            echo "10秒后重启..."
            sleep 10
            reboot -f
        else
            echo "取消安装"
        fi
        ;;
    3)
        exec sh
        ;;
    4)
        reboot -f
        ;;
    *)
        echo "无效选项"
        exec sh
        ;;
esac

# 如果执行到这里，返回shell
exec sh
INIT_EOF

chmod +x "$INITRD_DIR/init"

# 复制busybox到initrd
if which busybox >/dev/null 2>&1; then
    BUSYBOX=$(which busybox)
    mkdir -p "$INITRD_DIR/bin"
    cp "$BUSYBOX" "$INITRD_DIR/bin/"
    cd "$INITRD_DIR/bin"
    
    # 创建必要的符号链接
    for app in $(./busybox --list); do
        ln -s busybox "$app"
    done
    cd - >/dev/null
    echo "✅ 添加busybox到initrd"
fi

# 复制必要的工具
echo "添加必要的工具..."
TOOLS=("lsblk" "fdisk" "blkid" "dd" "mount" "umount" "sync" "mknod" "mdev" "reboot" "pv" "bash" )
for tool in "${TOOLS[@]}"; do
    tool_path=$(which "$tool" 2>/dev/null || true)
    if [ -n "$tool_path" ] && [ -f "$tool_path" ]; then
        mkdir -p "$INITRD_DIR$(dirname "$tool_path")"
        cp "$tool_path" "$INITRD_DIR$tool_path" 2>/dev/null || true
        
        # 复制依赖库
        if ldd "$tool_path" 2>/dev/null | grep -q "=>"; then
            ldd "$tool_path" 2>/dev/null | grep "=>" | awk '{print $3}' | while read lib; do
                if [ -f "$lib" ]; then
                    lib_dir="$INITRD_DIR$(dirname "$lib")"
                    mkdir -p "$lib_dir"
                    cp "$lib" "$INITRD_DIR$lib" 2>/dev/null || true
                fi
            done
        fi
    fi
done

# 添加必要的库文件
echo "添加库文件..."
mkdir -p "$INITRD_DIR/lib"
cp /lib/ld-musl-x86_64.so.1 "$INITRD_DIR/lib/" 2>/dev/null || true
cp /lib/libc.musl-x86_64.so.1 "$INITRD_DIR/lib/" 2>/dev/null || true

# 打包initrd
echo "打包initrd..."
cd "$INITRD_DIR"
find . -print0 | cpio -0 -o -H newc 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initrd.img"

INITRD_SIZE=$(du -h "$ISO_DIR/boot/initrd.img" 2>/dev/null | cut -f1 || echo "未知")
echo "✅ initrd创建完成 ($INITRD_SIZE)"

# ========== 第3步：获取内核 ==========
echo ""
echo "🔧 获取内核..."

# 从Alpine安装内核
if apk add --no-cache linux-lts 2>/dev/null; then
    # 查找内核
    for kernel in /boot/vmlinuz-lts /boot/vmlinuz; do
        if [ -f "$kernel" ]; then
            cp "$kernel" "$ISO_DIR/boot/vmlinuz"
            echo "✅ 使用Alpine内核: $(basename "$kernel")"
            break
        fi
    done
fi

# 如果没找到，尝试下载微内核
if [ ! -f "$ISO_DIR/boot/vmlinuz" ]; then
    echo "下载微内核..."
    # 尝试下载tinycore内核
    if curl -L -o /tmp/vmlinuz64 \
        "http://tinycorelinux.net/14.x/x86_64/release/distribution_files/vmlinuz64" \
        2>/dev/null && [ -f /tmp/vmlinuz64 ]; then
        cp /tmp/vmlinuz64 "$ISO_DIR/boot/vmlinuz"
        echo "✅ 使用TinyCore内核"
    fi
fi

# 验证内核
if [ -f "$ISO_DIR/boot/vmlinuz" ]; then
    KERNEL_SIZE=$(du -h "$ISO_DIR/boot/vmlinuz" | cut -f1)
    echo "✅ 内核文件: $ISO_DIR/boot/vmlinuz ($KERNEL_SIZE)"
else
    echo "❌ 错误: 无法获取内核!"
    exit 1
fi

# ========== 第4步：创建引导配置 ==========
echo ""
echo "🔧 创建引导配置..."

# BIOS引导 (ISOLINUX)
echo "创建BIOS引导配置..."
cat > "$ISO_DIR/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG_EOF'
DEFAULT install
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE OpenWRT Installer
MENU BACKGROUND /boot/splash.png

LABEL install
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200n8

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0

LABEL local
  MENU LABEL Boot from local disk
  LOCALBOOT 0x80
ISOLINUX_CFG_EOF

# 复制syslinux文件
if [ -d /usr/share/syslinux ]; then
    cp /usr/share/syslinux/isolinux.bin "$ISO_DIR/boot/isolinux/"
    cp /usr/share/syslinux/ldlinux.c32 "$ISO_DIR/boot/isolinux/"
    cp /usr/share/syslinux/libutil.c32 "$ISO_DIR/boot/isolinux/"
    cp /usr/share/syslinux/menu.c32 "$ISO_DIR/boot/isolinux/"
    echo "✅ 复制syslinux文件"
fi

# GRUB引导配置
echo "创建GRUB引导配置..."
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_CFG_EOF'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8
    initrd /boot/initrd.img
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz console=tty0
    initrd /boot/initrd.img
}

menuentry "Boot from local disk" {
    exit
}
GRUB_CFG_EOF

# ========== 第5步：创建EFI引导 ==========
echo ""
echo "🔧 创建EFI引导..."

# 创建EFI目录结构
mkdir -p "$ISO_DIR/EFI/BOOT"

# 生成GRUB EFI
if which grub-mkimage >/dev/null 2>&1; then
    echo "生成UEFI引导文件..."
    grub-mkimage \
        -O x86_64-efi \
        -o "$ISO_DIR/EFI/BOOT/BOOTX64.EFI" \
        -p /boot/grub \
        fat part_gpt part_msdos iso9660 \
        normal boot configfile loopback chain \
        efifwsetup efi_gop efi_uga ls search search_label \
        gfxterm gfxterm_background gfxterm_menu test all_video \
        echo true probe terminal 2>/dev/null
    
    if [ -f "$ISO_DIR/EFI/BOOT/BOOTX64.EFI" ]; then
        echo "✅ UEFI引导文件生成成功"
    fi
fi

# 复制grub.cfg到EFI目录
cp "$ISO_DIR/boot/grub/grub.cfg" "$ISO_DIR/EFI/BOOT/grub.cfg" 2>/dev/null || true

# 创建UEFI启动项（systemd-boot风格）
cat > "$ISO_DIR/loader/loader.conf" << 'LOADER_CONF_EOF'
default openwrt
timeout 5
console-mode keep
LOADER_CONF_EOF

cat > "$ISO_DIR/loader/entries/openwrt.conf" << 'ENTRY_CONF_EOF'
title OpenWRT Installer
linux /boot/vmlinuz
initrd /boot/initrd.img
options console=tty0 console=ttyS0,115200n8
ENTRY_CONF_EOF

# ========== 第6步：创建ISO ==========
echo ""
echo "📦 创建ISO文件..."

cd /tmp

# 使用xorriso创建混合ISO（BIOS+UEFI）
echo "创建混合引导ISO..."
xorriso -as mkisofs \
    -r -V "OPENWRT_INSTALLER" \
    -o "/output/openwrt.iso" \
    -b boot/isolinux/isolinux.bin \
    -c boot/isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/BOOT/BOOTX64.EFI \
    -no-emul-boot \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin 2>/dev/null \
    -isohybrid-gpt-basdat \
    "$ISO_DIR" 2>/dev/null

# 如果xorriso失败，尝试mkisofs
if [ ! -f "/output/openwrt.iso" ]; then
    echo "尝试mkisofs..."
    mkisofs \
        -r -V "OPENWRT_INSTALLER" \
        -o "/output/openwrt.iso" \
        -b boot/isolinux/isolinux.bin \
        -c boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        "$ISO_DIR" 2>/dev/null
fi

# 验证ISO
if [ -f "/output/openwrt.iso" ]; then
    ISO_SIZE=$(du -h "/output/openwrt.iso" | cut -f1)
    echo "✅ ISO创建成功! ($ISO_SIZE)"
    
    # 显示ISO信息
    echo ""
    echo "📊 ISO信息:"
    echo "文件: /output/openwrt.iso"
    echo "大小: $ISO_SIZE"
    
    if which file >/dev/null 2>&1; then
        file "/output/openwrt.iso"
    fi
    
    # 测试ISO结构
    echo ""
    echo "📁 ISO内容:"
    isoinfo -f -i "/output/openwrt.iso" 2>/dev/null | head -20 || \
    xorriso -indev "/output/openwrt.iso" -ls 2>/dev/null | head -20 || \
    echo "无法列出ISO内容"
    
    exit 0
else
    echo "❌ ISO创建失败"
    exit 1
fi
BUILD_SCRIPT_EOF

chmod +x scripts/build-iso.sh

# ========== 构建Docker镜像 ==========
echo "🔨 构建Docker镜像..."
IMAGE_NAME="openwrt-iso-builder:latest"

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
    --name openwrt-iso-builder \
    -v "$IMG_ABS:/mnt/input.img:ro" \
    -v "$OUTPUT_ABS:/output:rw" \
    -e INPUT_IMG="/mnt/input.img" \
    -e MINIMAL="$MINIMAL" \
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
    
    # 验证引导能力
    echo "🔍 引导验证:"
    if which file >/dev/null 2>&1; then
        FILE_INFO=$(file "$FINAL_ISO")
        echo "文件类型: $FILE_INFO"
        
        # 检查引导标记
        if echo "$FILE_INFO" | grep -q "bootable" || echo "$FILE_INFO" | grep -q "ISO 9660"; then
            echo "✅ 看起来是可引导ISO"
        fi
    fi
    
    # 检查是否为混合ISO
    if which dd >/dev/null 2>&1; then
        echo ""
        echo "检查引导扇区:"
        dd if="$FINAL_ISO" bs=1 count=64 2>/dev/null | xxd | grep -q "55 AA" && \
            echo "✅ 检测到BIOS引导扇区"
    fi
    
    echo ""
    echo "🚀 使用方法:"
    echo "   1. 虚拟机测试: qemu-system-x86_64 -cdrom '$FINAL_ISO' -m 512M"
    echo "   2. 制作USB: sudo dd if='$FINAL_ISO' of=/dev/sdX bs=4M status=progress oflag=sync"
    echo "   3. 刻录光盘: burn '$FINAL_ISO'"
    echo "   4. 直接使用: 将openwrt.img放在/images/目录下"
    
    exit 0
else
    echo ""
    echo "❌ ISO构建失败"
    
    # 显示容器日志
    echo "📋 容器日志 (最后50行):"
    docker logs --tail 50 openwrt-iso-builder 2>/dev/null || echo "无法获取容器日志"
    
    # 检查输出目录
    echo ""
    echo "📁 输出目录内容:"
    ls -la "$OUTPUT_ABS/" 2>/dev/null || echo "输出目录不存在"
    
    exit 1
fi
