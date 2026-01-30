#!/bin/bash
# OpenWRT ISO构建脚本 - 终极修复版

set -e

# 参数处理
usage() {
    cat << EOF
用法: $0 <openwrt.img> <output.iso> [alpine_version]

参数:
  openwrt.img      OpenWRT镜像文件路径
  output.iso       输出的ISO文件路径
  alpine_version   Alpine版本 (默认: 3.20)

示例:
  $0 ./openwrt.img ./openwrt-installer.iso
  $0 ./openwrt.img ./output/openwrt.iso 3.20
EOF
    exit 1
}

# 检查参数
if [ $# -lt 2 ]; then
    usage
fi

IMG_FILE="$1"
OUTPUT_PATH="$2"
ALPINE_VERSION="${3:-3.20}"

# 获取绝对路径
if [[ "$IMG_FILE" != /* ]]; then
    IMG_FILE="$(pwd)/$IMG_FILE"
fi
if [[ "$OUTPUT_PATH" != /* ]]; then
    OUTPUT_PATH="$(pwd)/$OUTPUT_PATH"
fi

# 验证输入文件
if [ ! -f "$IMG_FILE" ]; then
    echo "❌ 错误: OpenWRT镜像文件不存在: $IMG_FILE"
    exit 1
fi

# 创建输出目录
OUTPUT_DIR=$(dirname "$OUTPUT_PATH")
mkdir -p "$OUTPUT_DIR"

echo "================================================"
echo "  OpenWRT Alpine Installer Builder"
echo "================================================"
echo ""
echo "配置信息:"
echo "  OpenWRT镜像: $IMG_FILE ($(du -h "$IMG_FILE" | cut -f1))"
echo "  输出ISO: $OUTPUT_PATH"
echo "  Alpine版本: $ALPINE_VERSION"
echo ""

# 创建临时工作目录
WORKDIR=$(mktemp -d)
echo "临时工作目录: $WORKDIR"
cd "$WORKDIR"

# 函数：清理临时文件
cleanup() {
    echo "清理临时文件..."
    if [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

# 1. 复制OpenWRT镜像
echo "准备OpenWRT镜像..."
mkdir -p overlay/images
cp "$IMG_FILE" overlay/images/openwrt.img
echo "✅ 镜像复制完成"

# 2. 创建简单的initramfs
echo "创建initramfs..."
mkdir -p initramfs
cat > initramfs/init << 'INIT_EOF'
#!/bin/sh
# 最简单的init脚本

# 挂载核心文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 创建设备
[ -c /dev/console ] || mknod /dev/console c 5 1
[ -c /dev/null ] || mknod /dev/null c 1 3

# 设置控制台
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

clear
echo "========================================"
echo "     OpenWRT Simple Installer"
echo "========================================"
echo ""

# 挂载CDROM查找镜像
echo "Looking for OpenWRT image..."
for dev in /dev/sr0 /dev/cdrom; do
    if [ -b "$dev" ]; then
        echo "Found device: $dev"
        mount -t iso9660 -o ro $dev /mnt 2>/dev/null && break
    fi
done

# 如果挂载成功，复制镜像
if mountpoint -q /mnt && [ -f /mnt/images/openwrt.img ]; then
    echo "Copying OpenWRT image..."
    mkdir -p /images
    cp /mnt/images/openwrt.img /images/
    umount /mnt 2>/dev/null
fi

# 简单安装函数
install() {
    echo ""
    echo "=== OpenWRT Installation ==="
    echo ""
    
    echo "Available disks:"
    for d in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
        [ -b "$d" ] && echo "  $d"
    done
    
    echo ""
    echo -n "Target disk (e.g., sda): "
    read disk
    [ -z "$disk" ] && return 1
    
    [ "$disk" != "/dev/"* ] && disk="/dev/$disk"
    [ ! -b "$disk" ] && echo "Disk not found!" && return 1
    
    echo ""
    echo "WARNING: Will erase $disk!"
    echo -n "Type YES to confirm: "
    read confirm
    [ "$confirm" != "YES" ] && return 1
    
    img=""
    [ -f /images/openwrt.img ] && img="/images/openwrt.img"
    [ -z "$img" ] && echo "No image found!" && return 1
    
    echo "Installing..."
    dd if="$img" of="$disk" bs=4M status=progress 2>/dev/null || \
    dd if="$img" of="$disk" bs=4M
    
    if [ $? -eq 0 ]; then
        sync
        echo ""
        echo "✅ Success!"
        echo "Rebooting in 5s..."
        sleep 5
        reboot -f
    fi
}

# 主循环
while true; do
    echo ""
    echo "1) Install OpenWRT"
    echo "2) Shell"
    echo "3) Reboot"
    echo ""
    echo -n "Choice: "
    read choice
    
    case "$choice" in
        1) install ;;
        2) /bin/sh ;;
        3) reboot -f ;;
        *) echo "Invalid" ;;
    esac
done
INIT_EOF

# 创建busybox链接
mkdir -p initramfs/bin
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) initramfs/bin/
    cd initramfs/bin
    ln -s busybox sh
    ln -s busybox mount
    ln -s busybox umount
    ln -s busybox mknod
    ln -s busybox dd
    ln -s busybox reboot
    cd ../..
fi

# 打包initramfs
(cd initramfs && find . | cpio -o -H newc 2>/dev/null | gzip -9) > initrd.img
echo "✅ initramfs创建完成: $(du -h initrd.img | cut -f1)"

# 3. 直接使用Alpine容器构建ISO（绕过mkimage签名问题）
echo "构建ISO..."

# 方法1: 使用docker直接构建
docker run --rm \
    -v "$WORKDIR/overlay/images:/images:ro" \
    -v "$WORKDIR/initrd.img:/initrd.img:ro" \
    -v "$OUTPUT_DIR:/output:rw" \
    alpine:$ALPINE_VERSION \
    sh -c "
    set -e
    
    echo 'Building ISO with Alpine $ALPINE_VERSION'
    
    # 安装必要工具
    apk update
    apk add xorriso syslinux dosfstools
    
    # 创建ISO目录结构
    mkdir -p /tmp/iso/{isolinux,boot,images}
    
    # 复制内核
    if [ -f /boot/vmlinuz-lts ]; then
        cp /boot/vmlinuz-lts /tmp/iso/boot/vmlinuz
    elif [ -f /boot/vmlinuz ]; then
        cp /boot/vmlinuz /tmp/iso/boot/vmlinuz
    else
        echo '❌ No kernel found'
        exit 1
    fi
    
    # 复制initramfs
    cp /initrd.img /tmp/iso/boot/initrd.img
    
    # 复制OpenWRT镜像
    cp /images/openwrt.img /tmp/iso/images/
    
    # 创建ISOLINUX配置
    cat > /tmp/iso/isolinux/isolinux.cfg << 'CFGEOF'
DEFAULT install
TIMEOUT 50
PROMPT 0

LABEL install
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200 quiet

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 init=/bin/sh
CFGEOF
    
    # 复制引导文件
    if [ -d /usr/share/syslinux ]; then
        cp /usr/share/syslinux/isolinux.bin /tmp/iso/isolinux/
        cp /usr/share/syslinux/ldlinux.c32 /tmp/iso/isolinux/
    fi
    
    # 构建ISO
    xorriso -as mkisofs \
        -r -V 'OPENWRT_INSTALL' \
        -o /output/openwrt.iso \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        /tmp/iso
    
    echo '✅ ISO built successfully'
    "

# 检查结果
if [ -f "$OUTPUT_DIR/openwrt.iso" ]; then
    # 重命名为用户指定的名称
    mv "$OUTPUT_DIR/openwrt.iso" "$OUTPUT_PATH"
    
    echo ""
    echo "🎉 🎉 🎉 构建成功! 🎉 🎉 🎉"
    echo ""
    echo "📁 ISO文件: $OUTPUT_PATH"
    echo "📊 文件大小: $(du -h "$OUTPUT_PATH" | cut -f1)"
    echo ""
    
    # 验证ISO
    echo "🔍 ISO验证信息:"
    if command -v file >/dev/null 2>&1; then
        file "$OUTPUT_PATH"
    fi
    
    exit 0
else
    echo "❌ 方法1失败，尝试方法2..."
    
    # 方法2: 使用更简单的方法
    echo "尝试方法2: 使用直接构建..."
    
    docker run --rm \
        -v "$WORKDIR/overlay/images:/images:ro" \
        -v "$OUTPUT_DIR:/output:rw" \
        alpine:$ALPINE_VERSION \
        sh -c "
        # 创建最小化ISO
        mkdir -p /tmp/mini-iso/{boot,images}
        
        # 获取内核
        if [ -f /boot/vmlinuz-lts ]; then
            cp /boot/vmlinuz-lts /tmp/mini-iso/boot/
        elif [ -f /boot/vmlinuz ]; then
            cp /boot/vmlinuz /tmp/mini-iso/boot/
        fi
        
        # 复制镜像
        cp /images/openwrt.img /tmp/mini-iso/images/
        
        # 创建最简单的引导配置
        cat > /tmp/mini-iso/boot/grub.cfg << 'GRUBCFG'
set timeout=3
menuentry 'OpenWRT Installer' {
    linux /boot/vmlinuz console=tty0
}
GRUBCFG
        
        # 使用xorriso创建ISO
        xorriso -as mkisofs \
            -r -V 'OPENWRT' \
            -o /output/openwrt-simple.iso \
            /tmp/mini-iso
        "
    
    if [ -f "$OUTPUT_DIR/openwrt-simple.iso" ]; then
        mv "$OUTPUT_DIR/openwrt-simple.iso" "$OUTPUT_PATH"
        echo "✅ 方法2成功: $OUTPUT_PATH"
    else
        echo "❌ 所有方法都失败"
        exit 1
    fi
fi
