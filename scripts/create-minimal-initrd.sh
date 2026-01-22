#!/bin/bash
# 创建最简化的initrd，专注于OpenWRT安装

set -e
INITRD_DIR="/tmp/initrd-minimal"
OUTPUT_FILE="initrd.img"

# 清理并创建目录
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"/{bin,dev,etc,proc,sys,tmp,mnt,root}

# 下载静态编译的busybox
BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
wget -q "$BUSYBOX_URL" -O "$INITRD_DIR/bin/busybox"
chmod +x "$INITRD_DIR/bin/busybox"

# 创建符号链接
cd "$INITRD_DIR/bin"
ln -s busybox sh
ln -s busybox mount
ln -s busybox umount
ln -s busybox ls
ln -s busybox cat
ln -s busybox echo
ln -s busybox dd
ln -s busybox sync
ln -s busybox reboot
ln -s busybox blkid
ln -s busybox mknod
ln -s busybox sleep
cd -

# 创建init脚本
cat > "$INITRD_DIR/init" << 'EOF'
#!/bin/busybox sh

# 挂载虚拟文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# 设置路径
export PATH=/bin:/sbin

# 创建控制台
mknod /dev/console c 5 1
exec >/dev/console 2>&1

echo ""
echo "========================================"
echo "    OpenWRT Installer"
echo "========================================"

# 查找ISO中的OpenWRT镜像
for dev in /dev/sr0 /dev/sda /dev/sdb; do
    if [ -b "$dev" ]; then
        mount -t iso9660 -o ro "$dev" /mnt 2>/dev/null && break
        mount -t vfat -o ro "$dev" /mnt 2>/dev/null && break
    fi
done

# 检查是否找到镜像
if [ -f "/mnt/live/openwrt.img" ]; then
    echo "找到OpenWRT镜像"
    cp /mnt/live/openwrt.img /tmp/openwrt.img
else
    echo "错误: 未找到OpenWRT镜像"
    echo "正在使用shell..."
    exec /bin/busybox sh
fi

# 安装程序主循环
while true; do
    clear
    echo ""
    echo "可用磁盘:"
    echo "--------"
    /bin/busybox blkid | grep -v iso9660 || echo "(未找到磁盘)"
    echo "--------"
    echo ""
    
    echo -n "输入目标磁盘 (例如: sda): "
    read DISK
    
    if [ -b "/dev/$DISK" ]; then
        echo ""
        echo "警告: 这将完全擦除 /dev/$DISK 上的所有数据!"
        echo -n "确认安装? 输入 'yes': "
        read CONFIRM
        
        if [ "$CONFIRM" = "yes" ]; then
            echo "正在安装到 /dev/$DISK ..."
            if dd if=/tmp/openwrt.img of=/dev/$DISK bs=4M status=progress; then
                sync
                echo ""
                echo "安装完成! 3秒后重启..."
                sleep 3
                reboot -f
            else
                echo "安装失败!"
                sleep 2
            fi
        else
            echo "安装取消"
            sleep 1
        fi
    else
        echo "无效的磁盘: /dev/$DISK"
        sleep 2
    fi
done
EOF

chmod +x "$INITRD_DIR/init"

# 打包initrd
cd "$INITRD_DIR"
find . | cpio -H newc -o | gzip -9 > "../$OUTPUT_FILE"
cd -

echo "initrd创建完成: $(ls -lh /tmp/$OUTPUT_FILE)"
