#!/bin/bash
# OpenWRT ISO构建脚本 - 最终修复版

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
mkdir -p iso/images
cp "$IMG_FILE" iso/images/openwrt.img
echo "✅ 镜像复制完成"

# 2. 创建initramfs目录结构
echo "创建initramfs..."
mkdir -p initramfs/{bin,dev,proc,sys,tmp,images,mnt}

# 创建init脚本
cat > initramfs/init << 'INIT_EOF'
#!/bin/busybox sh
# OpenWRT安装程序init脚本

# 挂载核心文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 创建设备
[ -c /dev/console ] || mknod /dev/console c 5 1
[ -c /dev/null ] || mknod /dev/null c 1 3
[ -c /dev/tty ] || mknod /dev/tty c 5 0

# 设置控制台
exec 0</dev/console
exec 1</dev/console
exec 2</dev/console

# 清屏
clear
echo "========================================"
echo "     OpenWRT Alpine Installer"
echo "========================================"
echo ""
echo "Initializing..."

# 加载内核模块
echo "Loading kernel modules..."
for mod in loop isofs cdrom; do
    modprobe $mod 2>/dev/null || true
done

# 挂载CDROM查找OpenWRT镜像
echo "Looking for OpenWRT image..."
for dev in /dev/sr0 /dev/cdrom; do
    if [ -b "$dev" ]; then
        echo "Found CDROM: $dev"
        mount -t iso9660 -o ro $dev /mnt 2>/dev/null && break
    fi
done

# 如果从CD启动，复制镜像
if mountpoint -q /mnt && [ -f /mnt/images/openwrt.img ]; then
    echo "Copying OpenWRT image from installation media..."
    mkdir -p /images
    cp /mnt/images/openwrt.img /images/
    umount /mnt 2>/dev/null
fi

# 安装函数
install_openwrt() {
    echo ""
    echo "=== OpenWRT Installation ==="
    echo ""
    
    # 显示可用磁盘
    echo "Available disks:"
    echo "----------------"
    DISK_COUNT=0
    for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
        if [ -b "$disk" ]; then
            DISK_COUNT=$((DISK_COUNT + 1))
            size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
            size_gb=$((size / 1024 / 1024 / 1024))
            printf "  %2d) %-12s %4d GB\n" "$DISK_COUNT" "$disk" "$size_gb"
        fi
    done
    
    if [ $DISK_COUNT -eq 0 ]; then
        echo "No disks found!"
        return 1
    fi
    
    echo "----------------"
    
    # 选择磁盘
    echo ""
    echo -n "Select disk number (1-$DISK_COUNT): "
    read choice
    
    # 验证选择
    if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "$DISK_COUNT" ]; then
        echo "Invalid selection!"
        return 1
    fi
    
    # 找到对应的磁盘
    local idx=1
    for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
        if [ -b "$disk" ]; then
            if [ $idx -eq "$choice" ]; then
                TARGET_DISK="$disk"
                break
            fi
            idx=$((idx + 1))
        fi
    done
    
    # 确认
    echo ""
    echo "WARNING: This will ERASE ALL DATA on $TARGET_DISK!"
    echo ""
    echo -n "Type 'YES' to confirm: "
    read confirm
    
    if [ "$confirm" != "YES" ]; then
        echo "Installation cancelled."
        return 1
    fi
    
    # 查找OpenWRT镜像
    local img_path=""
    [ -f /images/openwrt.img ] && img_path="/images/openwrt.img"
    
    if [ -z "$img_path" ]; then
        echo "OpenWRT image not found!"
        return 1
    fi
    
    # 开始安装
    echo ""
    echo "Installing OpenWRT to $TARGET_DISK..."
    echo ""
    
    # 显示进度
    echo "Writing disk..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if command -v pv >/dev/null 2>&1; then
        pv "$img_path" | dd of="$TARGET_DISK" bs=4M
    else
        dd if="$img_path" of="$TARGET_DISK" bs=4M status=progress 2>/dev/null || \
        dd if="$img_path" of="$TARGET_DISK" bs=4M
    fi
    
    if [ $? -eq 0 ]; then
        sync
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✅ Installation successful!"
        echo ""
        echo "OpenWRT has been installed to $TARGET_DISK"
        echo ""
        echo "System will reboot in 10 seconds..."
        
        for i in $(seq 10 -1 1); do
            echo -ne "Rebooting in ${i} seconds...\r"
            sleep 1
        done
        
        echo ""
        echo "Rebooting..."
        reboot -f
    else
        echo "❌ Installation failed!"
        return 1
    fi
}

# 主菜单
while true; do
    echo ""
    echo "Menu:"
    echo "1) Install OpenWRT"
    echo "2) List disks"
    echo "3) Emergency shell"
    echo "4) Reboot"
    echo ""
    echo -n "Select option (1-4): "
    read choice
    
    case "$choice" in
        1)
            if install_openwrt; then
                break
            else
                echo ""
                echo "Press Enter to continue..."
                read
            fi
            ;;
        2)
            echo ""
            echo "Available disks:"
            echo "----------------"
            for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
                if [ -b "$disk" ]; then
                    size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
                    size_gb=$((size / 1024 / 1024 / 1024))
                    echo "  $disk - ${size_gb}GB"
                fi
            done
            echo "----------------"
            echo ""
            echo "Press Enter to continue..."
            read
            ;;
        3)
            echo ""
            echo "Starting emergency shell..."
            echo "Type 'exit' to return to menu"
            echo ""
            /bin/sh
            ;;
        4)
            echo "Rebooting system..."
            reboot -f
            ;;
        *)
            echo "Invalid option"
            ;;
    esac
done
INIT_EOF

chmod +x initramfs/init

# 创建busybox（从Alpine容器获取）
echo "准备busybox..."
docker run --rm alpine:$ALPINE_VERSION cat /bin/busybox > initramfs/bin/busybox
chmod +x initramfs/bin/busybox

# 创建符号链接
cd initramfs/bin
ln -s busybox sh
ln -s busybox mount
ln -s busybox umount
ln -s busybox mknod
ln -s busybox modprobe
ln -s busybox dd
ln -s busybox sync
ln -s busybox reboot
ln -s busybox echo
ln -s busybox cat
ln -s busybox ls
ln -s busybox clear
ln -s busybox sleep
cd ../..

# 复制OpenWRT镜像到initramfs
cp iso/images/openwrt.img initramfs/images/

# 打包initramfs
echo "打包initramfs..."
(cd initramfs && find . | cpio -o -H newc 2>/dev/null | gzip -9) > iso/boot/initrd.img
INITRD_SIZE=$(du -h iso/boot/initrd.img | cut -f1)
echo "✅ initramfs大小: $INITRD_SIZE"

# 3. 获取Alpine内核
echo "获取Alpine内核..."
docker run --rm \
    -v "$WORKDIR:/work:rw" \
    alpine:$ALPINE_VERSION \
    sh -c "
    echo 'Installing Alpine kernel...'
    apk update
    apk add linux-lts
    echo 'Kernel installed'
    
    # 复制内核
    if [ -f /boot/vmlinuz-lts ]; then
        cp /boot/vmlinuz-lts /work/iso/boot/vmlinuz
        echo '✅ Kernel copied: vmlinuz-lts'
    elif [ -f /boot/vmlinuz ]; then
        cp /boot/vmlinuz /work/iso/boot/vmlinuz
        echo '✅ Kernel copied: vmlinuz'
    else
        echo '❌ No kernel found in /boot'
        ls -la /boot/
        exit 1
    fi
    "

if [ ! -f "iso/boot/vmlinuz" ]; then
    echo "❌ 错误: 无法获取内核文件"
    exit 1
fi

KERNEL_SIZE=$(du -h iso/boot/vmlinuz | cut -f1)
echo "✅ 内核大小: $KERNEL_SIZE"

# 4. 创建ISOLINUX引导配置
echo "创建引导配置..."
mkdir -p iso/isolinux

cat > iso/isolinux/isolinux.cfg << 'ISOLINUX_EOF'
DEFAULT install
TIMEOUT 100
PROMPT 1

LABEL install
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 console=ttyS0,115200 quiet

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=tty0 init=/bin/sh

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32
ISOLINUX_EOF

# 5. 使用Alpine容器构建ISO
echo "构建ISO..."

docker run --rm \
    -v "$WORKDIR/iso:/iso:ro" \
    -v "$OUTPUT_DIR:/output:rw" \
    alpine:$ALPINE_VERSION \
    sh -c "
    set -e
    
    echo 'Building ISO with xorriso...'
    
    # 安装必要工具
    apk update
    apk add xorriso syslinux
    
    # 复制引导文件
    echo 'Copying boot files...'
    if [ -d /usr/share/syslinux ]; then
        mkdir -p /iso/isolinux
        cp /usr/share/syslinux/isolinux.bin /iso/isolinux/
        cp /usr/share/syslinux/ldlinux.c32 /iso/isolinux/
        cp /usr/share/syslinux/libutil.c32 /iso/isolinux/ 2>/dev/null || true
        cp /usr/share/syslinux/libcom32.c32 /iso/isolinux/ 2>/dev/null || true
        cp /usr/share/syslinux/reboot.c32 /iso/isolinux/ 2>/dev/null || true
        echo '✅ Syslinux files copied'
    fi
    
    # 构建ISO
    echo 'Creating ISO...'
    xorriso -as mkisofs \
        -r -V 'OPENWRT_INSTALL' \
        -o /output/openwrt.iso \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin 2>/dev/null \
        /iso
    
    echo '✅ ISO created successfully'
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
    echo "📦 组件详情:"
    echo "  - 内核: $KERNEL_SIZE"
    echo "  - initramfs: $INITRD_SIZE"
    echo "  - OpenWRT镜像: $(du -h "$IMG_FILE" | cut -f1)"
    echo ""
    
    # 验证ISO
    echo "🔍 ISO验证信息:"
    if command -v file >/dev/null 2>&1; then
        file "$OUTPUT_PATH"
    fi
    
    exit 0
else
    echo "❌ 构建失败 - ISO文件未生成"
    echo "输出目录内容:"
    ls -la "$OUTPUT_DIR" 2>/dev/null || echo "输出目录不存在"
    exit 1
fi
