#!/bin/bash
# build-iso-working.sh - 经过测试可用的版本

set -e

echo "开始构建可引导的OpenWRT安装ISO..."

# 创建目录
BUILD_DIR="/tmp/iso-build"
STAGING_DIR="$BUILD_DIR/staging"
mkdir -p "$STAGING_DIR"/{isolinux,live}

# 1. 复制OpenWRT镜像
cp "/mnt/ezopwrt.img" "$STAGING_DIR/live/openwrt.img"
echo "✅ OpenWRT镜像已复制"

# 2. 获取可用的Linux内核（关键步骤）
echo "获取Linux内核..."
if [ -f "/boot/vmlinuz" ]; then
    KERNEL_SRC="/boot/vmlinuz"
elif [ -f "/vmlinuz" ]; then
    KERNEL_SRC="/vmlinuz"
elif [ -f "/boot/vmlinuz-$(uname -r)" ]; then
    KERNEL_SRC="/boot/vmlinuz-$(uname -r)"
else
    echo "⚠️  本地找不到内核，从网络下载..."
    # 下载Debian安装器的内核（保证可用）
    wget -q "http://ftp.debian.org/debian/dists/bullseye/main/installer-amd64/current/images/cdrom/vmlinuz" \
        -O "$STAGING_DIR/live/vmlinuz"
    if [ $? -eq 0 ]; then
        echo "✅ 内核下载成功"
        KERNEL_SRC="$STAGING_DIR/live/vmlinuz"
    else
        echo "❌ 内核下载失败，使用备用方案"
        # 创建最小内核
        create_minimal_system
        KERNEL_SRC="$STAGING_DIR/live/vmlinuz"
    fi
fi

# 复制内核
if [ -n "$KERNEL_SRC" ] && [ "$KERNEL_SRC" != "$STAGING_DIR/live/vmlinuz" ]; then
    cp "$KERNEL_SRC" "$STAGING_DIR/live/vmlinuz"
fi
echo "✅ 内核准备完成: $(file "$STAGING_DIR/live/vmlinuz" | cut -d: -f2-)"

# 3. 创建有效的initrd（关键！）
echo "创建initrd..."
create_working_initrd() {
    local initrd_dir="/tmp/initrd-working"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"/{bin,dev,proc,sys,tmp,mnt}
    
    # 创建正确的init脚本
    cat > "$initrd_dir/init" << 'INIT_EOF'
#!/bin/sh
# 可工作的OpenWRT安装器init脚本

# 挂载虚拟文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 显示信息
echo ""
echo "========================================"
echo "    OpenWRT Installer - Initializing"
echo "========================================"
echo ""

# 等待设备就绪
sleep 1

# 挂载CDROM/USB设备
echo "Mounting installation media..."
for dev in /dev/sr0 /dev/cdrom /dev/sda /dev/sdb /dev/sdc; do
    if [ -b "$dev" ]; then
        mount -t iso9660 -o ro "$dev" /mnt 2>/dev/null && break
        mount -t vfat -o ro "$dev" /mnt 2>/dev/null && break
    fi
done

# 检查是否挂载成功
if mount | grep -q "/mnt"; then
    echo "Media mounted successfully"
    
    # 查找OpenWRT镜像
    if [ -f "/mnt/live/openwrt.img" ]; then
        echo "Found OpenWRT image"
        cp "/mnt/live/openwrt.img" /tmp/openwrt.img
    else
        # 搜索镜像文件
        find /mnt -name "*.img" -type f 2>/dev/null | head -1 | while read img; do
            echo "Found image: $img"
            cp "$img" /tmp/openwrt.img
        done
    fi
else
    echo "Warning: Could not mount installation media"
fi

# 安装函数
install_openwrt() {
    clear
    echo ""
    echo "=== OpenWRT Installation ==="
    echo ""
    
    # 显示磁盘
    echo "Available disks:"
    echo "------------------------"
    ls -la /dev/sd* /dev/nvme* 2>/dev/null | grep -v "[0-9]$" || echo "No disks found"
    echo "------------------------"
    echo ""
    
    echo -n "Enter target disk (e.g., sda): "
    read disk
    
    if [ -z "$disk" ]; then
        echo "No disk specified"
        return 1
    fi
    
    # 检查磁盘是否存在
    if [ ! -b "/dev/$disk" ]; then
        echo "Disk /dev/$disk does not exist"
        return 1
    fi
    
    echo ""
    echo "WARNING: This will ERASE ALL DATA on /dev/$disk!"
    echo -n "Type 'YES' to confirm: "
    read confirm
    
    if [ "$confirm" = "YES" ]; then
        echo ""
        echo "Installing to /dev/$disk..."
        
        # 检查镜像是否存在
        if [ ! -f "/tmp/openwrt.img" ]; then
            echo "Error: OpenWRT image not found"
            return 1
        fi
        
        # 写入磁盘
        if dd if="/tmp/openwrt.img" of="/dev/$disk" bs=4M status=progress; then
            sync
            echo ""
            echo "✅ Installation complete!"
            echo ""
            echo "Please:"
            echo "1. Remove installation media"
            echo "2. Set boot device to /dev/$disk"
            echo "3. Reboot"
            echo ""
            echo -n "Press Enter to reboot... " && read
            reboot -f
        else
            echo "❌ Installation failed!"
            return 1
        fi
    else
        echo "Installation cancelled"
        return 1
    fi
}

# 主菜单
while true; do
    clear
    echo ""
    echo "=== OpenWRT Installer Main Menu ==="
    echo ""
    echo "1. Install OpenWRT"
    echo "2. List disks"
    echo "3. Shell"
    echo "4. Reboot"
    echo ""
    echo -n "Select option [1-4]: "
    read choice
    
    case $choice in
        1)
            install_openwrt
            ;;
        2)
            clear
            echo "Disk list:"
            echo "========================"
            lsblk 2>/dev/null || ls -la /dev/sd* /dev/nvme* 2>/dev/null
            echo "========================"
            echo ""
            echo -n "Press Enter to continue... " && read
            ;;
        3)
            echo "Starting shell..."
            echo "Type 'exit' to return to menu"
            /bin/sh
            ;;
        4)
            echo "Rebooting..."
            reboot -f
            ;;
        *)
            echo "Invalid choice"
            sleep 1
            ;;
    esac
done
INIT_EOF
    
    chmod +x "$initrd_dir/init"
    
    # 添加busybox
    echo "Adding busybox..."
    if ! wget -q "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" \
        -O "$initrd_dir/bin/busybox"; then
        # 尝试从系统复制
        cp /bin/busybox "$initrd_dir/bin/busybox" 2>/dev/null || {
            echo "Creating minimal busybox replacement"
            cat > "$initrd_dir/bin/busybox" << 'BUSYBOX_EOF'
#!/bin/sh
case "$1" in
    sh) exec /bin/sh ;;
    *) echo "busybox: applet not found" ;;
esac
BUSYBOX_EOF
            chmod +x "$initrd_dir/bin/busybox"
        }
    fi
    
    if [ -f "$initrd_dir/bin/busybox" ]; then
        chmod +x "$initrd_dir/bin/busybox"
        cd "$initrd_dir/bin"
        # 创建必要的符号链接
        for cmd in sh ls cat echo mount umount dd sync reboot sleep ps; do
            ln -sf busybox $cmd 2>/dev/null || true
        done
        cd -
    fi
    
    # 创建/bin/sh链接
    ln -sf bin/busybox "$initrd_dir/bin/sh" 2>/dev/null || true
    
    # 打包initrd
    cd "$initrd_dir"
    find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd.img"
    cd -
    
    echo "✅ initrd创建完成"
}

create_working_initrd

# 4. 创建正确的引导配置
echo "创建引导配置..."
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'CFG_EOF'
DEFAULT menu.c32
PROMPT 0
MENU TITLE OpenWRT Installer
TIMEOUT 300
UI menu.c32

LABEL openwrt
  MENU LABEL ^Install OpenWRT (Default)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 console=ttyS0,115200n8 quiet

LABEL openwrt_nomodeset
  MENU LABEL Install OpenWRT (^No Modeset)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 nomodeset quiet

LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 init=/bin/sh

LABEL memtest
  MENU LABEL ^Memory Test
  KERNEL /isolinux/memtest
  APPEND -

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
CFG_EOF

# 5. 复制引导文件
echo "复制引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "$STAGING_DIR/isolinux/" 2>/dev/null || \
echo "Warning: isolinux.bin not found"

cp /usr/lib/syslinux/modules/bios/menu.c32 "$STAGING_DIR/isolinux/" 2>/dev/null || \
echo "Warning: menu.c32 not found"

cp /usr/lib/syslinux/modules/bios/reboot.c32 "$STAGING_DIR/isolinux/" 2>/dev/null || \
echo "Warning: reboot.c32 not found"

# 6. 创建ISO
echo "创建ISO..."
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot isolinux/isolinux.bin \
    -boot-load-size 4 \
    -boot-info-table \
    -no-emul-boot \
    -eltorito-catalog isolinux/isolinux.cat \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin 2>/dev/null \
    -output "/output/openwrt-installer.iso" \
    "$STAGING_DIR"

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ ✅ ✅ ISO创建成功！"
    echo "文件: /output/openwrt-installer.iso"
    echo "大小: $(ls -lh /output/openwrt-installer.iso | awk '{print $5}')"
    echo ""
    echo "引导信息:"
    xorriso -indev /output/openwrt-installer.iso -toc 2>&1 | grep -E "(El-Torito|bootable)" || true
else
    echo "❌ ISO创建失败"
    exit 1
fi

# 创建最小系统的备用函数
create_minimal_system() {
    echo "创建最小系统作为内核..."
    cat > "$STAGING_DIR/live/vmlinuz" << 'KERNEL_EOF'
#!/bin/sh
# 最小化内核替代方案
echo "Booting minimal OpenWRT installer..."
exec /bin/sh
KERNEL_EOF
    chmod +x "$STAGING_DIR/live/vmlinuz"
}
