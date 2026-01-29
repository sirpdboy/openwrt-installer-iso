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
    squashfs-tools \
    cdrtools \
    linux-lts \
    musl-dev \
    gcc \
    make \
    binutils \
    && rm -rf /var/cache/apk/*

# 安装额外的grub模块
RUN mkdir -p /tmp/grub-modules && \
    cd /tmp/grub-modules && \
    for mod in all_video arping bfs boot chain configfile cpio echo efifwsetup efi_gop efi_uga \
        fat font gfxmenu gfxterm gzio halt http iso9660 jpeg keystatus linux loadenv loopback \
        ls lvm mdraid09 mdraid1x minicmd multiboot net normal ntfs ntfscomp part_apple part_gpt \
        part_msdos password password_pbkdf2 png reboot regexp search search_fs_file search_fs_uuid \
        search_label sleep squash4 test tftp video xzio zfs zfscrypt zfsinfo; do \
        echo "insmod $mod" >> /tmp/grub-modules/grub-modules.cfg; \
    done

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

echo "=== OpenWRT ISO Builder (Alpine完整版) ==="

# 输入文件
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"


# 检查输入文件
if [ ! -f "$INPUT_IMG" ]; then
@@ -132,432 +143,477 @@
fi

echo "✅ 输入文件: $INPUT_IMG ($(du -h "$INPUT_IMG" | cut -f1))"

echo "✅ 输出目录: /output"

# ========== 第1步：准备工作区 ==========
echo ""
echo "📁 创建工作区..."
WORK_DIR="/tmp/openwrt_iso_$(date +%s)"
ISO_DIR="$WORK_DIR/iso"
CHROOT_DIR="$WORK_DIR/chroot"
STAGING_DIR="$WORK_DIR/staging"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$ISO_DIR"
mkdir -p "$CHROOT_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub/x86_64-efi,isolinux,live}

# ========== 第2步：创建Alpine最小系统 ==========
echo ""
echo "🐧 创建Alpine最小系统..."

# 安装apk工具
apk add --no-cache alpine-base openssl ca-certificates

# 设置chroot环境
echo "设置chroot环境..."
setup-apkcache /var/cache/apk
setup-hostname -n openwrt-installer

# 安装Alpine基本系统到chroot
echo "安装基本系统到chroot..."
for pkg in alpine-base busybox e2fsprogs parted util-linux \
           syslinux grub grub-efi bash coreutils gzip tar \
           cpio findutils grep gawk file curl wget; do
    apk fetch -o "$CHROOT_DIR" $pkg || echo "跳过包: $pkg"
done

# 创建chroot目录结构
mkdir -p "$CHROOT_DIR"/{bin,dev,etc,lib,proc,sys,root,sbin,tmp,usr/{bin,sbin,lib},var/{cache,log,run},boot}
mount -t proc proc "$CHROOT_DIR/proc" || true
mount -o bind /dev "$CHROOT_DIR/dev" || true
mount -o bind /sys "$CHROOT_DIR/sys" || true

# ========== 第3步：配置chroot系统 ==========
echo ""
echo "🔧 配置chroot系统..."





# 创建基本的初始化脚本
cat > "$CHROOT_DIR/init" << 'CHROOT_INIT'
#!/bin/busybox sh
# Alpine最小初始化脚本

# 挂载必要的文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 设置控制台
exec /bin/busybox sh
CHROOT_INIT
chmod +x "$CHROOT_DIR/init"

# 创建fstab
cat > "$CHROOT_DIR/etc/fstab" << 'FSTAB'
none    /proc   proc    defaults    0 0
none    /sys    sysfs   defaults    0 0
none    /dev    devtmpfs defaults   0 0
none    /tmp    tmpfs   defaults    0 0
FSTAB

# ========== 第4步：获取内核和initrd ==========
echo ""
echo "🔧 获取内核和initrd..."

# 从Alpine安装中提取内核
KERNEL_FOUND=false
for kernel_path in /boot/vmlinuz-lts /boot/vmlinuz; do
    if [ -f "$kernel_path" ]; then
        cp "$kernel_path" "$STAGING_DIR/live/vmlinuz"
        KERNEL_FOUND=true
        echo "✅ 找到内核: $(basename "$kernel_path")"
        break
    fi
done

if [ "$KERNEL_FOUND" = false ]; then
    echo "⚠ 未找到本地内核，下载微内核..."
    # 下载Linux内核
    curl -L -o "$STAGING_DIR/live/vmlinuz" \
        https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.30.tar.xz 2>/dev/null || \
    curl -L -o "$STAGING_DIR/live/vmlinuz" \
        https://mirrors.edge.kernel.org/pub/linux/kernel/v6.x/linux-6.6.30.tar.xz 2>/dev/null || \
    echo "内核下载失败"
fi

# 创建initrd
echo "创建initrd..."
INITRD_DIR="/tmp/initrd.$$"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"

cat > "$INITRD_DIR/init" << 'INITRD_INIT'
#!/bin/sh
# OpenWRT安装系统initrd

# 早期挂载
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s





# 查找安装介质
echo "寻找OpenWRT安装介质..."
for dev in /dev/sr* /dev/cdrom*; do
    if [ -b "$dev" ]; then
        mount -t iso9660 -o ro "$dev" /mnt 2>/dev/null && break

    fi
done

# 检查OpenWRT镜像
if [ -f "/mnt/images/openwrt.img" ]; then
    echo "✅ 找到OpenWRT镜像"
    IMG_PATH="/mnt/images/openwrt.img"
elif [ -f "/openwrt.img" ]; then
    echo "✅ 使用内置OpenWRT镜像"
    IMG_PATH="/openwrt.img"
else
    echo "❌ 未找到OpenWRT镜像"
    echo "挂载点内容:"
    ls -la /mnt/ 2>/dev/null || true
    exec /bin/sh
fi











# 安装菜单
cat << 'MENU'

╔══════════════════════════════════════╗
║      OpenWRT Alpine Installer       ║
╚══════════════════════════════════════╝

1) 列出磁盘
2) 安装OpenWRT
3) Shell

4) 重启

选择: 
MENU

read choice
case $choice in
    1)
        fdisk -l 2>/dev/null || lsblk
        ;;
    2)
        echo "输入磁盘 (如: sda): "
        read disk
        if [ -b "/dev/$disk" ]; then
            echo "确认擦除 /dev/$disk? (输入YES确认): "
            read confirm
            if [ "$confirm" = "YES" ]; then
                echo "正在写入..."
                dd if="$IMG_PATH" of="/dev/$disk" bs=4M status=progress
                sync
                echo "✅ 安装完成!"
                echo "10秒后重启..."
                sleep 10
                reboot -f





            fi







        fi
        ;;
    3)
        exec /bin/sh
        ;;
    4)
        reboot -f
        ;;




esac

# 返回shell
exec /bin/sh
INITRD_INIT

chmod +x "$INITRD_DIR/init"

# 复制busybox到initrd
if which busybox >/dev/null 2>&1; then
    cp $(which busybox) "$INITRD_DIR/busybox"
    cd "$INITRD_DIR"




    for app in $(./busybox --list); do
        ln -s busybox $app
    done
    cd - >/dev/null

fi





























# 打包initrd

cd "$INITRD_DIR"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd"
cd - >/dev/null
rm -rf "$INITRD_DIR"

echo "✅ initrd创建完成"


# ========== 第5步：复制OpenWRT镜像 ==========
echo ""
echo "📦 复制OpenWRT镜像..."
cp "$INPUT_IMG" "$ISO_DIR/images/openwrt.img"
cp "$INPUT_IMG" "$STAGING_DIR/openwrt.img"























echo "✅ OpenWRT镜像已复制"








# ========== 第6步：创建引导配置 ==========
echo ""
echo "🔧 创建引导配置..."

# ISOLINUX配置 (BIOS引导)
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'

DEFAULT install
PROMPT 0
TIMEOUT 30
UI menu.c32

MENU TITLE OpenWRT Alpine Installer


LABEL install
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=tty0

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=tty0 init=/bin/sh

LABEL local
  MENU LABEL Boot from ^local disk
  LOCALBOOT 0x80
ISOLINUX_CFG

# 复制syslinux文件
if [ -d /usr/share/syslinux ]; then
    cp /usr/share/syslinux/isolinux.bin "$STAGING_DIR/isolinux/"
    cp /usr/share/syslinux/ldlinux.c32 "$STAGING_DIR/isolinux/"
    cp /usr/share/syslinux/libutil.c32 "$STAGING_DIR/isolinux/"
    cp /usr/share/syslinux/menu.c32 "$STAGING_DIR/isolinux/"
    echo "✅ 复制syslinux文件"
fi

# GRUB配置 (UEFI引导)
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'

set timeout=10
set default=0

menuentry "Install OpenWRT (UEFI)" {
    linux /live/vmlinuz console=tty0
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

# ========== 第7步：创建UEFI引导文件 ==========
echo ""
echo "🔧 创建UEFI引导文件..."

# 创建GRUB独立配置文件
cat > "$WORK_DIR/grub-standalone.cfg" << 'GRUB_STANDALONE'
search --set=root --file /openwrt.img
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
GRUB_STANDALONE

# 创建EFI目录结构
mkdir -p "$STAGING_DIR/EFI/boot"
mkdir -p "$WORK_DIR/efi_tmp"

# 生成GRUB EFI可执行文件
echo "生成GRUB EFI..."
if which grub-mkstandalone >/dev/null 2>&1; then
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/bootx64.efi" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos fat iso9660" \
        "boot/grub/grub.cfg=$WORK_DIR/grub-standalone.cfg"
    
    if [ -f "$WORK_DIR/bootx64.efi" ]; then
        echo "✅ GRUB EFI文件生成成功"
    else
        echo "⚠ GRUB EFI生成失败，尝试简单方法"
        # 简单方法：直接生成EFI文件
        if which grub-mkimage >/dev/null 2>&1; then
            grub-mkimage \
                -O x86_64-efi \
                -o "$WORK_DIR/bootx64.efi" \
                -p /boot/grub \
                fat iso9660 part_gpt part_msdos normal boot linux configfile loopback chain \
                efifwsetup efi_gop efi_uga ls search search_label search_fs_uuid search_fs_file \
                gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 \
                echo true probe terminal 2>/dev/null
        fi
    fi
fi

# 创建EFI引导镜像
if [ -f "$WORK_DIR/bootx64.efi" ]; then
    echo "创建EFI引导镜像..."
    EFI_SIZE=$(($(stat -c%s "$WORK_DIR/bootx64.efi") + 65536))
    
    # 创建空的EFI镜像
    dd if=/dev/zero of="$STAGING_DIR/EFI/boot/efiboot.img" bs=1 count=0 seek=${EFI_SIZE} 2>/dev/null
    
    # 格式化为FAT文件系统
    mkfs.fat -F 32 -n "OPENWRT_EFI" "$STAGING_DIR/EFI/boot/efiboot.img" 2>/dev/null || \
    mkfs.fat -F 12 -n "OPENWRT_EFI" "$STAGING_DIR/EFI/boot/efiboot.img" 2>/dev/null || \
    mkfs.vfat -F 32 -n "OPENWRT_EFI" "$STAGING_DIR/EFI/boot/efiboot.img" 2>/dev/null
    
    # 挂载并复制文件
    MOUNT_DIR="$WORK_DIR/efi_mount"
    mkdir -p "$MOUNT_DIR"
    
    if mount "$STAGING_DIR/EFI/boot/efiboot.img" "$MOUNT_DIR" 2>/dev/null; then
        mkdir -p "$MOUNT_DIR/EFI/boot"
        cp "$WORK_DIR/bootx64.efi" "$MOUNT_DIR/EFI/boot/bootx64.efi"
        
        # 复制GRUB配置
        mkdir -p "$MOUNT_DIR/boot/grub"
        cp "$STAGING_DIR/boot/grub/grub.cfg" "$MOUNT_DIR/boot/grub/grub.cfg"
        
        umount "$MOUNT_DIR"
        echo "✅ EFI引导镜像创建成功"
    else
        echo "⚠ 无法挂载EFI镜像，直接复制文件"
        cp "$WORK_DIR/bootx64.efi" "$STAGING_DIR/EFI/boot/bootx64.efi"
    fi
    
    rm -rf "$MOUNT_DIR"
else
    echo "⚠ 无法创建EFI引导文件，将生成仅BIOS引导的ISO"
fi

# ========== 第8步：复制其他文件 ==========
echo ""
echo "📄 复制其他文件..."

# 创建标识文件
echo "OpenWRT Alpine Installer" > "$STAGING_DIR/OPENWRT_ALPINE"
touch "$STAGING_DIR/openwrt.img"




# 复制ISO目录内容
cp -r "$ISO_DIR"/* "$STAGING_DIR/" 2>/dev/null || true





# ========== 第9步：构建ISO ==========
echo ""
echo "📦 构建ISO文件..."

cd "$WORK_DIR"

# 准备isohdpfx.bin
ISOHDPFX=""
if [ -f /usr/share/syslinux/isohdpfx.bin ]; then
    ISOHDPFX="/usr/share/syslinux/isohdpfx.bin"
elif [ -f /usr/lib/syslinux/isohdpfx.bin ]; then
    ISOHDPFX="/usr/lib/syslinux/isohdpfx.bin"
fi

# 使用xorriso构建混合ISO
echo "运行xorriso构建ISO..."
if [ -n "$ISOHDPFX" ] && [ -f "$STAGING_DIR/EFI/boot/efiboot.img" ]; then
    # 完整混合ISO (BIOS + UEFI)
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
        -e EFI/boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$STAGING_DIR" 2>&1 | grep -v "IFS" || true
else
    # 仅BIOS引导
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

# ========== 第10步：验证结果 ==========
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
    
    if which file >/dev/null 2>&1; then
        FILE_INFO=$(file "/output/openwrt.iso")
        echo "类型: $FILE_INFO"
    fi
    
    # 检查引导能力
    echo ""
    echo "🔧 引导能力检查:"
    if echo "$FILE_INFO" | grep -q "bootable"; then
        echo "✅ 可引导ISO"
    fi
    
    # 列出ISO内容
    echo ""
    echo "📁 ISO内容摘要:"
    if which xorriso >/dev/null 2>&1; then
        xorriso -indev "/output/openwrt.iso" -ls 2>/dev/null | head -15
    elif which isoinfo >/dev/null 2>&1; then
        isoinfo -f -i "/output/openwrt.iso" 2>/dev/null | head -15
    fi
    
    # 清理工作区
    rm -rf "$WORK_DIR"
    
    exit 0
else
    echo "❌ ISO创建失败"
    
    # 显示错误信息
    echo ""
    echo "📋 详细日志:"
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
@@ -566,12 +622,13 @@
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
@@ -594,46 +651,39 @@
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
