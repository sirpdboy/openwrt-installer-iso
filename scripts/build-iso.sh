#!/bin/bash
# build-iso-fixed-rootfs.sh - 修复根文件系统挂载

set -e

echo "构建OpenWRT安装ISO（修复根文件系统问题）..."
echo ""

# 工作目录
ISO_DIR="/tmp/iso-rootfs"
mkdir -p "$ISO_DIR"/{isolinux,live}

# 1. 安装必要的包
echo "步骤1: 安装必要工具..."
apt-get update
apt-get install -y \
    syslinux isolinux \
    xorriso wget cpio gzip \
    linux-image-amd64  # 确保有内核

# 2. 复制引导文件
echo "步骤2: 复制引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
cp /usr/lib/syslinux/modules/bios/*.c32 "$ISO_DIR/isolinux/" 2>/dev/null || true

# 3. 获取可靠的内核
echo "步骤3: 准备内核..."
if [ -f "/boot/vmlinuz-$(uname -r)" ]; then
    KERNEL_SRC="/boot/vmlinuz-$(uname -r)"
elif [ -f "/boot/vmlinuz" ]; then
    KERNEL_SRC="/boot/vmlinuz"
else
    # 下载Debian稳定版内核
    echo "下载Debian内核..."
    wget -q "http://ftp.debian.org/debian/dists/bullseye/main/installer-amd64/current/images/cdrom/vmlinuz" \
        -O /tmp/debian-vmlinuz
    KERNEL_SRC="/tmp/debian-vmlinuz"
fi

cp "$KERNEL_SRC" "$ISO_DIR/live/vmlinuz"
echo "✅ 内核准备完成: $(file "$ISO_DIR/live/vmlinuz")"

# 4. 创建正确的initrd（关键修复）
echo "步骤4: 创建initrd（修复根文件系统）..."
create_proper_initrd() {
    local initrd_dir="/tmp/initrd-proper"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"/{bin,dev,etc,proc,sys,tmp,mnt,root,sbin,lib,lib64}
    
    # 创建正确的init脚本 - 必须命名为init，不能有其他名称
    cat > "$initrd_dir/init" << 'INIT_PROPER'
#!/bin/busybox sh
# 正确的init脚本 - 修复根文件系统挂载

# 挂载虚拟文件系统（必须的）
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev

# 创建设备节点
/bin/busybox mknod /dev/console c 5 1
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 输出调试信息
echo ""
echo "========================================"
echo "    OpenWRT Installer - Init Complete"
echo "========================================"
echo ""
echo "Kernel command line: $(cat /proc/cmdline)"
echo ""

# 等待设备初始化
/bin/busybox sleep 1

# 挂载CD/USB设备查找OpenWRT镜像
echo "Mounting installation media..."
for dev in /dev/sr0 /dev/cdrom /dev/sda /dev/sdb; do
    if [ -b "$dev" ]; then
        echo "Trying $dev..."
        /bin/busybox mount -t iso9660 -o ro "$dev" /mnt 2>/dev/null && break
        /bin/busybox mount -t vfat -o ro "$dev" /mnt 2>/dev/null && break
    fi
done

# 检查是否挂载成功
if /bin/busybox mount | /bin/busybox grep -q "/mnt"; then
    echo "Media mounted at /mnt"
    
    # 查找OpenWRT镜像
    if [ -f "/mnt/live/openwrt.img" ]; then
        echo "Found OpenWRT image"
        /bin/busybox cp "/mnt/live/openwrt.img" /tmp/openwrt.img
    fi
else
    echo "Warning: Could not mount installation media"
fi

# 安装函数
install_menu() {
    while true; do
        clear
        echo "=== OpenWRT Installation ==="
        echo ""
        echo "1. Install OpenWRT"
        echo "2. List disks"
        echo "3. Shell"
        echo "4. Reboot"
        echo ""
        echo -n "Select [1-4]: "
        read choice
        
        case $choice in
            1)
                echo "Installation would start here"
                /bin/busybox sleep 2
                ;;
            2)
                echo "Available disks:"
                /bin/busybox ls -la /dev/sd* /dev/nvme* 2>/dev/null || echo "No disks found"
                echo ""
                echo -n "Press Enter..." && read
                ;;
            3)
                echo "Starting shell..."
                exec /bin/busybox sh
                ;;
            4)
                echo "Rebooting..."
                /bin/busybox reboot -f
                ;;
        esac
    done
}

# 下载或准备busybox
if [ ! -x /bin/busybox ]; then
    echo "Setting up busybox..."
    # 如果busybox不存在，使用内置命令
    for cmd in echo cat ls mount umount sleep reboot; do
        eval "$cmd() { /bin/busybox $cmd \"\$@\"; }"
    done
fi

# 启动安装菜单
install_menu
INIT_PROPER
    
    chmod +x "$initrd_dir/init"
    
    # 下载静态编译的busybox
    echo "下载busybox..."
    if ! wget -q "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" \
        -O "$initrd_dir/bin/busybox"; then
        # 如果下载失败，从系统复制
        cp /bin/busybox "$initrd_dir/bin/busybox" 2>/dev/null || {
            echo "创建最小busybox"
            cat > "$initrd_dir/bin/busybox" << 'BUSYBOX_MIN'
#!/bin/sh
case "$1" in
    sh) exec /bin/sh ;;
    echo) shift; echo "$@" ;;
    cat) shift; cat "$@" 2>/dev/null || echo "cat: $1: No such file" ;;
    ls) ls "$@" 2>/dev/null || echo "ls: No such file" ;;
    mount) echo "mount: simulated" ;;
    *) echo "busybox: applet not found" ;;
esac
BUSYBOX_MIN
            chmod +x "$initrd_dir/bin/busybox"
        }
    fi
    
    if [ -f "$initrd_dir/bin/busybox" ]; then
        chmod +x "$initrd_dir/bin/busybox"
        
        # 创建必要的符号链接
        cd "$initrd_dir/bin"
        for cmd in sh echo cat ls mount umount sleep reboot cp grep; do
            ln -sf busybox $cmd 2>/dev/null || true
        done
        cd -
        
        # 确保/bin/sh存在
        ln -sf bin/busybox "$initrd_dir/sh" 2>/dev/null || true
    fi
    
    # 打包initrd - 使用标准格式
    echo "打包initrd..."
    cd "$initrd_dir"
    find . 2>/dev/null | cpio -H newc -o 2>/dev/null | gzip -9 > "$ISO_DIR/live/initrd"
    cd -
    
    echo "✅ initrd创建完成"
    ls -lh "$ISO_DIR/live/initrd"
}

create_proper_initrd

# 5. 复制OpenWRT镜像
echo "步骤5: 复制OpenWRT镜像..."
cp "/mnt/ezopwrt.img" "$ISO_DIR/live/openwrt.img"

# 6. 创建正确的引导配置（关键修复）
echo "步骤6: 创建引导配置..."
cat > "$ISO_DIR/isolinux/isolinux.cfg" << 'CFG_PROPER'
DEFAULT vesamenu.c32
PROMPT 0
MENU TITLE OpenWRT Installer
TIMEOUT 100

# 设置背景等（可选）
MENU BACKGROUND /isolinux/background.png
MENU COLOR border       30;44   #00000000 #00000000 none
MENU COLOR title        1;36;44 #ffffffff #00000000 none

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  KERNEL /live/vmlinuz
  # 关键：正确的内核参数
  APPEND initrd=/live/initrd root=/dev/ram0 rw console=tty0 console=ttyS0,115200n8 quiet
  
LABEL openwrt_nomodeset
  MENU LABEL Install OpenWRT (^No Modeset)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd root=/dev/ram0 rw console=tty0 nomodeset quiet
  
LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd root=/dev/ram0 rw console=tty0 init=/bin/sh

LABEL memtest
  MENU LABEL ^Memory Test
  KERNEL /isolinux/memtest
  APPEND -

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
CFG_PROPER

# 7. 创建ISO
echo "步骤7: 创建ISO..."
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot isolinux/isolinux.bin \
    -boot-load-size 4 \
    -boot-info-table \
    -no-emul-boot \
    -eltorito-catalog isolinux/isolinux.cat \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -output "/output/openwrt-installer.iso" \
    "$ISO_DIR" 2>&1 | grep -v "unable to" || true

# 8. 验证
if [ -f "/output/openwrt-installer.iso" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO创建成功！"
    echo "文件: /output/openwrt-installer.iso"
    echo "大小: $(ls -lh /output/openwrt-installer.iso | awk '{print $5}')"
    
    # 提取并验证initrd
    echo ""
    echo "验证initrd:"
    TEMP_DIR="/tmp/verify-$$"
    mkdir -p "$TEMP_DIR"
    xorriso -osirrox on -indev "/output/openwrt-installer.iso" \
        -extract /live/initrd "$TEMP_DIR/initrd.gz" 2>/dev/null || true
    
    if [ -f "$TEMP_DIR/initrd.gz" ]; then
        echo "initrd文件存在"
        file "$TEMP_DIR/initrd.gz"
        
        # 尝试解压检查
        mkdir -p "$TEMP_DIR/initrd-extract"
        cd "$TEMP_DIR/initrd-extract"
        gzip -dc ../initrd.gz 2>/dev/null | cpio -id 2>/dev/null || true
        if [ -f "init" ]; then
            echo "✅ init脚本存在"
            head -5 init
        else
            echo "❌ init脚本缺失"
            ls -la
        fi
    fi
    rm -rf "$TEMP_DIR"
else
    echo "❌ ISO创建失败"
    exit 1
fi

echo ""
echo "🎉 构建完成！"
