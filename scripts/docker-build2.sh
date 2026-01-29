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
FROM alpine:${ALPINE_VERSION}

# 使用国内镜像源加速
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories

# 安装完整工具集
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
    coreutils \
    gzip \
    tar \
    cpio \
    findutils \
    grep \
    curl \
    wget \
    pv \
    linux-lts \
    grub \
    grub-efi \
    grub-bios \
    jq \
    file \
    && rm -rf /var/cache/apk/*

# 确保syslinux文件存在
RUN mkdir -p /usr/share/syslinux && \
    if [ ! -f /usr/share/syslinux/isolinux.bin ]; then \
        apk add --no-cache syslinux --repository http://dl-cdn.alpinelinux.org/alpine/edge/main; \
    fi

WORKDIR /work

# 复制构建脚本
COPY scripts/build-iso-alpine.sh /build.sh
RUN chmod +x /build.sh

# 设置环境变量
ENV INPUT_IMG=/mnt/input.img \
    OUTPUT_DIR=/output \
    ISO_NAME=openwrt-installer.iso

ENTRYPOINT ["/build.sh"]


DOCKERFILE_EOF

# 更新版本号
# sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/g" "$DOCKERFILE_PATH"

# 创建完整的Alpine构建脚本
mkdir -p scripts
cat > scripts/build-iso-alpine.sh << 'BUILD_SCRIPT_EOF'
#!/bin/bash
set -e

echo "=== Alpine Live OpenWRT Installer Builder ==="
echo "============================================="

INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"
[ ! -f "$INPUT_IMG" ] && { echo "❌ 输入文件不存在"; exit 1; }

echo "✅ 输入文件: $INPUT_IMG ($(du -h "$INPUT_IMG" | cut -f1))"
echo "✅ 输出目录: /output"
echo ""

# ========== 第1步：创建工作区 ==========
echo "[1/10] 📁 创建工作区..."
WORK_DIR="/tmp/alpine_live_$(date +%s)"
CHROOT_DIR="$WORK_DIR/chroot"
STAGING_DIR="$WORK_DIR/staging"
ISO_PATH="/output/openwrt.iso"

cleanup() {
    echo "清理工作区..."
    # 卸载chroot挂载点
    for mount_point in "$CHROOT_DIR"/proc "$CHROOT_DIR"/sys "$CHROOT_DIR"/dev; do
        umount -l "$mount_point" 2>/dev/null || true
    done
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR"
mkdir -p "$CHROOT_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub,isolinux,live}

# ========== 第2步：创建Alpine最小系统 ==========
echo "[2/10] 🐧 创建Alpine最小系统..."

# 设置apk缓存
setup-apkcache /var/cache/apk

# 安装Alpine基础系统到chroot
echo "安装Alpine基础系统..."
apk -X https://dl-cdn.alpinelinux.org/alpine/v3.20/main \
    -U --allow-untrusted --root "$CHROOT_DIR" --initdb \
    add alpine-base linux-lts openrc busybox

# ========== 第3步：配置chroot系统 ==========
echo "[3/10] 🔧 配置chroot系统..."

# 挂载必要的文件系统
mount -t proc proc "$CHROOT_DIR/proc"
mount -t sysfs sysfs "$CHROOT_DIR/sys"
mount -o bind /dev "$CHROOT_DIR/dev"

# 创建chroot配置脚本
cat > "$CHROOT_DIR/setup-chroot.sh" << 'CHROOT_SETUP'
#!/bin/sh
set -e

echo "🔧 配置Alpine Live系统..."

# 设置主机名
echo "openwrt-installer" > /etc/hostname

# 设置时区
setup-timezone -z UTC

# 设置root密码（空密码）
echo "设置root密码..."
passwd -d root 2>/dev/null || true

# 配置OpenRC服务
rc-update add devfs boot
rc-update add dmesg boot
rc-update add mdev sysinit
rc-update add hwclock boot
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add syslog boot

# 创建自动登录到tty1
cat > /etc/inittab << 'INITTAB'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
# 设置tty1自动登录root
tty1::respawn:/bin/login -f root
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3
tty4::respawn:/sbin/getty 38400 tty4
tty5::respawn:/sbin/getty 38400 tty5
tty6::respawn:/sbin/getty 38400 tty6
::restart:/sbin/init
::shutdown:/sbin/openrc shutdown
INITTAB

# 创建自动启动脚本
mkdir -p /etc/local.d
cat > /etc/local.d/start-installer.start << 'STARTUP'
#!/bin/sh
# OpenWRT安装系统启动脚本

# 等待tty1就绪
sleep 2

# 清屏并显示欢迎信息
clear
cat << "BANNER"

╔══════════════════════════════════════════════════╗
║       OpenWRT Alpine Live Installer              ║
╚══════════════════════════════════════════════════╝

BANNER

echo "系统启动完成，正在启动安装程序..."
sleep 2

# 启动安装程序
exec /opt/openwrt-installer.sh
STARTUP
chmod +x /etc/local.d/start-installer.start

# 启用local服务
rc-update add local default

# 创建OpenWRT安装脚本
mkdir -p /opt
cat > /opt/openwrt-installer.sh << 'INSTALLER'
#!/bin/sh
# OpenWRT刷机安装程序

while true; do
    clear
    cat << "HEADER"

╔══════════════════════════════════════════════════╗
║           OpenWRT 刷机安装系统                   ║
╚══════════════════════════════════════════════════╝

HEADER

    # 检查OpenWRT镜像
    if [ ! -f "/mnt/openwrt.img" ]; then
        echo "❌ 错误: 未找到OpenWRT刷机镜像!"
        echo ""
        echo "镜像应该位于: /mnt/openwrt.img"
        echo ""
        echo "请检查ISO是否包含镜像文件。"
        echo ""
        read -p "按Enter键重试..." dummy
        continue
    fi

    echo "✅ 找到OpenWRT刷机镜像"
    IMG_SIZE=$(du -h /mnt/openwrt.img 2>/dev/null | cut -f1 || echo "未知")
    echo "   镜像大小: $IMG_SIZE"
    echo ""

    # 显示磁盘信息
    echo "📊 可用磁盘列表:"
    echo "================="
    /sbin/fdisk -l 2>/dev/null | grep "^Disk /dev/" | head -10 || \
    lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -v '^$' || \
    echo "   无法列出磁盘"
    echo "================="
    echo ""

    echo "🔧 安装菜单:"
    echo "  1) 查看磁盘详细信息 (fdisk -l)"
    echo "  2) 刷写OpenWRT到磁盘"
    echo "  3) 重启系统"
    echo "  4) 进入Shell"
    echo ""
    read -p "请选择 [1-4]: " choice

    case "$choice" in
        1)
            echo ""
            echo "磁盘详细信息:"
            echo "----------------"
            /sbin/fdisk -l 2>/dev/null | head -30 || echo "无法显示详细信息"
            echo ""
            read -p "按Enter键继续..." dummy
            ;;
        2)
            echo ""
            read -p "请输入目标磁盘名称 (例如: sda): " target_disk
            
            if [ -z "$target_disk" ]; then
                echo "❌ 未输入磁盘名"
                sleep 2
                continue
            fi
            
            if [ ! -b "/dev/$target_disk" ]; then
                echo "❌ 磁盘 /dev/$target_disk 不存在!"
                sleep 2
                continue
            fi
            
            echo ""
            echo "⚠️  ⚠️  ⚠️  严重警告 ⚠️  ⚠️  ⚠️"
            echo "这将完全擦除 /dev/$target_disk 上的所有数据!"
            echo "所有分区和数据都将永久丢失!"
            echo ""
            read -p "确认刷机？输入大写 YES 继续: " confirm
            
            if [ "$confirm" != "YES" ]; then
                echo "❌ 刷机取消"
                sleep 2
                continue
            fi
            
            echo ""
            echo "🚀 开始刷写 OpenWRT 到 /dev/$target_disk ..."
            echo ""
            
            # 刷机
            if command -v pv >/dev/null 2>&1; then
                echo "使用pv显示进度..."
                pv /mnt/openwrt.img | dd of="/dev/$target_disk" bs=4M
            else
                echo "使用dd刷写..."
                dd if=/mnt/openwrt.img of="/dev/$target_disk" bs=4M status=progress
            fi
            
            sync
            echo ""
            echo "✅ ✅ ✅ 刷机完成! ✅ ✅ ✅"
            echo ""
            echo "OpenWRT已成功刷写到 /dev/$target_disk"
            echo ""
            
            echo "系统将在10秒后自动重启..."
            for i in $(seq 10 -1 1); do
                echo -ne "重启倒计时: ${i}秒\r"
                sleep 1
            done
            echo ""
            
            reboot -f
            ;;
        3)
            echo "重启系统..."
            reboot -f
            ;;
        4)
            echo ""
            echo "进入shell..."
            echo "输入 'exit' 返回安装菜单"
            echo ""
            exec /bin/sh
            ;;
        *)
            echo "❌ 无效选择"
            sleep 2
            ;;
    esac
done
INSTALLER
chmod +x /opt/openwrt-installer.sh

# 安装必要的工具
echo "安装刷机工具..."
apk add --no-cache \
    fdisk \
    lsblk \
    pv \
    e2fsprogs \
    parted \
    util-linux

# 配置网络（如果需要）
echo "配置网络..."
cat > /etc/network/interfaces << 'NETWORK'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NETWORK

# 清理
echo "清理缓存..."
rm -rf /var/cache/apk/*

echo "✅ Alpine Live系统配置完成"
CHROOT_SETUP

# 在chroot中运行配置
chroot "$CHROOT_DIR" /bin/sh /setup-chroot.sh
rm -f "$CHROOT_DIR/setup-chroot.sh"

# 卸载chroot挂载点
umount "$CHROOT_DIR/proc"
umount "$CHROOT_DIR/sys"
umount "$CHROOT_DIR/dev"

# ========== 第4步：复制OpenWRT镜像 ==========
echo "[4/10] 📦 复制OpenWRT镜像..."
cp "$INPUT_IMG" "$CHROOT_DIR/mnt/openwrt.img"
cp "$INPUT_IMG" "$STAGING_DIR/live/openwrt.img"
IMG_SIZE=$(du -h "$INPUT_IMG" | cut -f1)
echo "✅ 刷机镜像已复制 ($IMG_SIZE)"

# ========== 第5步：创建squashfs文件系统 ==========
echo "[5/10] 📦 创建squashfs文件系统..."

# 创建排除列表
cat > "$WORK_DIR/squashfs-exclude.txt" << 'EXCLUDE'
proc/*
sys/*
dev/*
tmp/*
run/*
var/tmp/*
var/run/*
var/cache/*
var/log/*
boot/*.old
root/.ash_history
root/.cache
EXCLUDE

# 创建squashfs
echo "创建squashfs（这可能需要几分钟）..."
if mksquashfs "$CHROOT_DIR" "$STAGING_DIR/live/filesystem.squashfs" \
    -comp xz \
    -b 1M \
    -noappend \
    -no-progress \
    -wildcards \
    -ef "$WORK_DIR/squashfs-exclude.txt"; then
    
    SQUASHFS_SIZE=$(du -h "$STAGING_DIR/live/filesystem.squashfs" | cut -f1)
    echo "✅ squashfs创建成功 ($SQUASHFS_SIZE)"
else
    echo "❌ squashfs创建失败"
    exit 1
fi

# 创建live标识文件
echo "live" > "$STAGING_DIR/live/filesystem.squashfs.type"
touch "$STAGING_DIR/live/filesystem.packages"

# ========== 第6步：获取内核和initramfs ==========
echo "[6/10] 🔧 获取内核和initramfs..."

# 从chroot中提取内核
KERNEL=$(find "$CHROOT_DIR/boot" -name "vmlinuz*" 2>/dev/null | head -1)
INITRAMFS=$(find "$CHROOT_DIR/boot" -name "initramfs*" 2>/dev/null | head -1)

if [ -f "$KERNEL" ] && [ -f "$INITRAMFS" ]; then
    cp "$KERNEL" "$STAGING_DIR/live/vmlinuz"
    cp "$INITRAMFS" "$STAGING_DIR/live/initrd.img"
    echo "✅ 内核: $(basename "$KERNEL")"
    echo "✅ initramfs: $(basename "$INITRAMFS")"
else
    # 如果没找到，使用当前系统的
    echo "⚠ 未在chroot中找到内核，使用当前系统内核..."
    for kernel in /boot/vmlinuz-lts /boot/vmlinuz; do
        if [ -f "$kernel" ]; then
            cp "$kernel" "$STAGING_DIR/live/vmlinuz"
            echo "✅ 使用内核: $(basename "$kernel")"
            break
        fi
    done
    
    # 创建简单的initrd
    echo "创建简单的initrd..."
    TEMP_INITRD="/tmp/simple_initrd"
    mkdir -p "$TEMP_INITRD"
    
    cat > "$TEMP_INITRD/init" << 'INITRD_INIT'
#!/bin/sh
# 简单initrd
mount -t proc proc /proc
mount -t sysfs sysfs /sys
exec /bin/sh
INITRD_INIT
    chmod +x "$TEMP_INITRD/init"
    
    cd "$TEMP_INITRD"
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd.img"
    cd - >/dev/null
    rm -rf "$TEMP_INITRD"
fi

# ========== 第7步：创建BIOS引导配置 ==========
echo "[7/10] 🔧 创建BIOS引导配置..."

# 复制syslinux文件
for file in isolinux.bin ldlinux.c32 libutil.c32 menu.c32 vesamenu.c32; do
    for dir in /usr/share/syslinux /usr/lib/syslinux; do
        if [ -f "$dir/$file" ]; then
            cp "$dir/$file" "$STAGING_DIR/isolinux/"
            break
        fi
    done
done

# 查找isohdpfx.bin
for dir in /usr/share/syslinux /usr/lib/syslinux; do
    if [ -f "$dir/isohdpfx.bin" ]; then
        cp "$dir/isohdpfx.bin" "$WORK_DIR/isohdpfx.bin"
        echo "✅ 找到isohdpfx.bin"
        break
    fi
done

# 创建ISOLINUX配置
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT vesamenu.c32
PROMPT 0
TIMEOUT 100
ONTIMEOUT live

MENU TITLE OpenWRT Alpine Live Installer
MENU BACKGROUND /boot/splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std

LABEL live
  MENU LABEL ^启动OpenWRT安装系统
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 console=ttyS0,115200n8 root=/dev/root rootfstype=squashfs rootflags=loop=/live/filesystem.squashfs

LABEL debug
  MENU LABEL ^调试模式
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 console=ttyS0,115200n8 root=/dev/root rootfstype=squashfs rootflags=loop=/live/filesystem.squashfs init=/bin/sh

LABEL shell
  MENU LABEL ^应急Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 init=/bin/sh

LABEL local
  MENU LABEL 从本地磁盘启动
  LOCALBOOT 0x80
ISOLINUX_CFG

echo "✅ BIOS引导配置完成"

# ========== 第8步：创建UEFI引导配置 ==========
echo "[8/10] 🔧 创建UEFI引导配置..."

# 创建GRUB配置
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

menuentry "启动OpenWRT安装系统 (UEFI)" {
    linux /live/vmlinuz console=tty0 console=ttyS0,115200n8 root=/dev/root rootfstype=squashfs rootflags=loop=/live/filesystem.squashfs
    initrd /live/initrd.img
}

menuentry "调试模式" {
    linux /live/vmlinuz console=tty0 console=ttyS0,115200n8 root=/dev/root rootfstype=squashfs rootflags=loop=/live/filesystem.squashfs init=/bin/sh
    initrd /live/initrd.img
}

menuentry "应急Shell" {
    linux /live/vmlinuz console=tty0 init=/bin/sh
    initrd /live/initrd.img
}

menuentry "从本地磁盘启动" {
    exit
}
GRUB_CFG

# 生成GRUB EFI文件
if command -v grub-mkstandalone >/dev/null 2>&1; then
    echo "生成GRUB EFI文件..."
    TEMP_DIR="/tmp/grub_uefi_$(date +%s)"
    mkdir -p "$TEMP_DIR/boot/grub"
    cp "$STAGING_DIR/boot/grub/grub.cfg" "$TEMP_DIR/boot/grub/"
    
    if grub-mkstandalone \
        --format=x86_64-efi \
        --output="$TEMP_DIR/bootx64.efi" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos fat ext2 iso9660 squash4" \
        "boot/grub/grub.cfg=$TEMP_DIR/boot/grub/grub.cfg" 2>/dev/null; then
        
        cp "$TEMP_DIR/bootx64.efi" "$STAGING_DIR/EFI/boot/bootx64.efi"
        echo "✅ GRUB EFI生成成功"
    fi
    rm -rf "$TEMP_DIR"
fi

echo "✅ UEFI引导配置完成"

# ========== 第9步：构建ISO ==========
echo "[9/10] 📦 构建ISO..."

cd "$WORK_DIR"

# 检查是否有EFI引导文件和isohdpfx.bin
EFI_FILE="$STAGING_DIR/EFI/boot/bootx64.efi"
ISOHDPFX="$WORK_DIR/isohdpfx.bin"

if [ -f "$EFI_FILE" ] && [ -f "$ISOHDPFX" ]; then
    echo "构建混合引导ISO (BIOS + UEFI)..."
    
    # 创建EFI引导镜像
    EFI_IMG="$WORK_DIR/efiboot.img"
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=16 status=none 2>/dev/null
    if mkfs.fat -F 32 -n "EFIBOOT" "$EFI_IMG" >/dev/null 2>&1; then
        MOUNT_DIR="$WORK_DIR/efi_mount"
        mkdir -p "$MOUNT_DIR"
        
        if mount -o loop "$EFI_IMG" "$MOUNT_DIR" 2>/dev/null; then
            mkdir -p "$MOUNT_DIR/EFI/boot"
            cp "$EFI_FILE" "$MOUNT_DIR/EFI/boot/"
            sync
            umount "$MOUNT_DIR"
        fi
        rm -rf "$MOUNT_DIR"
    fi
    
    xorriso -as mkisofs \
        -r \
        -V "OPENWRT_ALPINE_LIVE" \
        -o "$ISO_PATH" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr "$ISOHDPFX" \
        -eltorito-alt-boot \
        -e "$EFI_IMG" \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$STAGING_DIR" 2>&1 | tail -5
        
    rm -f "$EFI_IMG"
else
    echo "构建BIOS引导ISO..."
    
    xorriso -as mkisofs \
        -r \
        -V "OPENWRT_ALPINE_LIVE" \
        -o "$ISO_PATH" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        "$STAGING_DIR" 2>&1 | tail -5
fi

# ========== 第10步：验证结果 ==========
echo "[10/10] 🔍 验证结果..."

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(du -h "$ISO_PATH" | cut -f1)
    echo ""
    echo "🎉🎉🎉 Alpine Live ISO构建成功! 🎉🎉🎉"
    echo ""
    echo "📊 构建摘要:"
    echo "  ISO文件: $ISO_PATH"
    echo "  ISO大小: $ISO_SIZE"
    echo "  squashfs大小: $SQUASHFS_SIZE"
    echo "  刷机镜像: $IMG_SIZE"
    echo "  内核: $(basename "$STAGING_DIR/live/vmlinuz")"
    echo ""
    
    # 显示ISO信息
    if command -v file >/dev/null 2>&1; then
        FILE_INFO=$(file "$ISO_PATH")
        echo "ISO类型: $FILE_INFO"
    fi
    
    # 创建构建信息
    cat > "/output/build-info.txt" << EOF
OpenWRT Alpine Live Installer ISO
==================================
构建时间: $(date)
ISO大小:  $ISO_SIZE
squashfs: $SQUASHFS_SIZE
刷机镜像: $IMG_SIZE
内核版本: $(basename "$STAGING_DIR/live/vmlinuz")

系统特性:
  - 基于Alpine Linux 3.20
  - 完整的Live系统环境
  - 自动启动安装程序
  - 包含fdisk, lsblk, dd, pv等刷机工具
  - root自动登录

引导支持:
  - BIOS (ISOLINUX): 是
  - UEFI (GRUB): $( [ -f "$EFI_FILE" ] && echo "是" || echo "否" )

使用方法:
  1. 制作USB启动盘:
     sudo dd if=openwrt.iso of=/dev/sdX bs=4M status=progress oflag=sync
  2. 从USB启动
  3. 系统自动启动安装程序
  4. 选择目标磁盘刷机
  5. 输入YES确认刷机

注意: 刷机会完全擦除目标磁盘!
EOF
    
    echo "✅ 构建信息保存到: /output/build-info.txt"
    echo ""
    echo "🚀 Alpine Live刷机ISO准备就绪!"
    
    exit 0
else
    echo "❌ ISO构建失败"
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
