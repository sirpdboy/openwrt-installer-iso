#!/bin/bash
# build-tinycore-chroot-iso.sh - 使用chroot技术构建更小的ISO
set -e

echo "=== 使用chroot技术构建OpenWRT安装ISO ==="
echo "=========================================="

# 参数
if [ $# -ne 2 ]; then
    echo "用法: $0 <output_dir> <iso_name>"
    exit 1
fi

OUTPUT_DIR="$2"
ISO_NAME="$3"

# 配置
TINYCORE_VERSION="16.x"
ARCH="x86_64"
TC_MIRROR="https://mirrors.dotsrc.org/tinycorelinux/${TINYCORE_VERSION}/${ARCH}/release/distribution_files"

# 工作目录
WORK_DIR="/tmp/tc-chroot-$(date +%s)"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

echo "工作目录: ${WORK_DIR}"
echo "输出文件: ${OUTPUT_DIR}/${ISO_NAME}"

# ================= 第一步：安装必要工具 =================
echo "1. 安装必要工具..."
install_tools() {
    apt-get update 2>/dev/null || true
    for pkg in wget cpio bsdcpio xorriso syslinux isolinux squashfs-tools; do
        if ! command -v $pkg >/dev/null 2>&1; then
            echo "  安装 $pkg..."
            apt-get install -y $pkg 2>/dev/null || true
        fi
    done
}
install_tools

# ================= 第二步：下载核心文件 =================
echo "2. 下载核心文件..."

# 创建目录结构
mkdir -p "${WORK_DIR}/iso"
mkdir -p "${WORK_DIR}/chroot"
mkdir -p "${WORK_DIR}/tcz"
mkdir -p "${OUTPUT_DIR}"

# 下载最小rootfs（借鉴参考脚本）
echo "  下载rootfs64.gz..."
if ! wget -q "${TC_MIRROR}/rootfs64.gz" \
    -O "${WORK_DIR}/rootfs64.gz"; then
    # 备选源
    wget -q "https://mirrors.edge.kernel.org/tinycorelinux/${TINYCORE_VERSION}/x86_64/release/distribution_files/rootfs64.gz" \
        -O "${WORK_DIR}/rootfs64.gz" || {
        echo "❌ rootfs64.gz下载失败"
        exit 1
    }
fi

# 下载内核
echo "  下载内核..."
wget -q "${TC_MIRROR}/vmlinuz64" \
    -O "${WORK_DIR}/iso/vmlinuz64" || {
    echo "❌ 内核下载失败"
    exit 1
}

# ================= 第三步：创建chroot环境 =================
echo "3. 创建chroot环境..."

# 创建内存文件系统（借鉴参考脚本）
echo "  创建tmpfs..."
sudo mount -t tmpfs none "${WORK_DIR}/chroot" || {
    echo "❌ 无法创建tmpfs，使用普通目录"
    mkdir -p "${WORK_DIR}/chroot"
}

# 解压rootfs到chroot
echo "  解压rootfs64.gz..."
cd "${WORK_DIR}/chroot"
bsdcpio -i -d -H newc < ../rootfs64.gz 2>/dev/null || \
cpio -i -d -H newc < ../rootfs64.gz 2>/dev/null || {
    echo "⚠️  cpio解压失败，尝试其他方法"
    gzip -dc ../rootfs64.gz | cpio -i -d -H newc 2>/dev/null || true
}

# ================= 第四步：配置chroot环境 =================
echo "4. 配置chroot环境..."

# 创建必要的目录
mkdir -p dev proc sys tmp etc/sysconfig home/tc

# 创建tce目录链接（借鉴参考脚本）
mkdir -p "${WORK_DIR}/tcz"
ln -sf /mnt/tcz etc/sysconfig/tcedir

# 复制profile
if [ -f etc/profile ]; then
    cp etc/profile home/tc/.profile
fi

# 挂载特殊文件系统（在chroot外部准备，ISO内部不挂载）
echo "  准备特殊文件系统..."
cat > "${WORK_DIR}/chroot/init" << 'INIT_SCRIPT'
#!/bin/sh
# Tiny Core初始化脚本

# 挂载proc
mount -t proc proc /proc

# 挂载sysfs
mount -t sysfs sysfs /sys

# 挂载devtmpfs
mount -t devtmpfs devtmpfs /dev

# 创建必要的设备节点
mknod -m 666 /dev/null c 1 3 2>/dev/null || true
mknod -m 666 /dev/zero c 1 5 2>/dev/null || true
mknod -m 644 /dev/urandom c 1 9 2>/dev/null || true

# 设置主机名
hostname openwrt-installer

# 配置网络
echo "127.0.0.1 localhost" > /etc/hosts
echo "openwrt-installer" > /etc/hostname

# 启动安装程序
echo ""
echo "========================================"
echo "   OpenWRT Installer Started"
echo "========================================"
echo ""

# 寻找OpenWRT镜像
find_openwrt_image() {
    # 检查CDROM
    if [ -b /dev/sr0 ]; then
        mkdir -p /mnt/cdrom
        mount /dev/sr0 /mnt/cdrom 2>/dev/null && {
            if [ -f /mnt/cdrom/openwrt.img ]; then
                echo "Found OpenWRT image on CDROM"
                cp /mnt/cdrom/openwrt.img /tmp/openwrt.img
                umount /mnt/cdrom
                return 0
            fi
            umount /mnt/cdrom
        }
    fi
    
    # 检查USB设备
    for dev in /dev/sd* /dev/hd*; do
        if [ -b "$dev" ] && [ "$dev" != "/dev/sda" ]; then
            mkdir -p /mnt/usb
            mount "$dev" /mnt/usb 2>/dev/null && {
                if [ -f /mnt/usb/openwrt.img ]; then
                    echo "Found OpenWRT image on $dev"
                    cp /mnt/usb/openwrt.img /tmp/openwrt.img
                    umount /mnt/usb
                    return 0
                fi
                umount /mnt/usb
            }
        fi
    done
    
    return 1
}

# 安装函数
install_openwrt() {
    local image="$1"
    local target="$2"
    
    echo "Installing OpenWRT to $target..."
    
    # 检查目标设备
    if [ ! -b "$target" ]; then
        echo "Error: $target is not a block device"
        return 1
    fi
    
    # 使用dd写入
    if command -v pv >/dev/null 2>&1; then
        pv "$image" | dd of="$target" bs=4M status=none
    else
        dd if="$image" of="$target" bs=4M status=progress
    fi
    
    sync
    return $?
}

# 主循环
main_menu() {
    while true; do
        clear
        echo "========================================"
        echo "      OpenWRT Installation Menu"
        echo "========================================"
        echo ""
        
        # 显示可用磁盘
        echo "Available disks:"
        echo "----------------"
        lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null || \
            fdisk -l 2>/dev/null | grep "^Disk /dev/" || \
            echo "No disks found"
        echo "----------------"
        echo ""
        
        echo "Options:"
        echo "  1. Search for OpenWRT image"
        echo "  2. Show disk details"
        echo "  3. Start installation"
        echo "  4. Open shell"
        echo "  5. Reboot"
        echo ""
        
        read -p "Select option (1-5): " choice
        
        case $choice in
            1)
                echo ""
                echo "Searching for OpenWRT image..."
                if find_openwrt_image; then
                    echo "✅ OpenWRT image found: /tmp/openwrt.img"
                    echo "   Size: $(ls -lh /tmp/openwrt.img 2>/dev/null | awk '{print $5}' || echo 'unknown')"
                else
                    echo "❌ OpenWRT image not found"
                    echo "   Please make sure:"
                    echo "   1. File is named 'openwrt.img'"
                    echo "   2. File is on USB/CDROM root"
                fi
                read -p "Press Enter to continue..."
                ;;
            2)
                echo ""
                echo "Disk details:"
                fdisk -l 2>/dev/null || lsblk 2>/dev/null || echo "Cannot show disk details"
                read -p "Press Enter to continue..."
                ;;
            3)
                if [ ! -f /tmp/openwrt.img ]; then
                    echo ""
                    echo "❌ No OpenWRT image found"
                    echo "   Please search for image first (option 1)"
                    sleep 2
                    continue
                fi
                
                echo ""
                read -p "Enter target disk (e.g., sda): " disk
                
                if [ -z "$disk" ]; then
                    echo "Please enter disk name"
                    sleep 1
                    continue
                fi
                
                if [ ! -b "/dev/$disk" ]; then
                    echo "❌ Disk /dev/$disk not found"
                    sleep 2
                    continue
                fi
                
                # 确认
                echo ""
                echo "⚠️  WARNING: This will erase ALL data on /dev/$disk!"
                read -p "Type 'YES' to confirm: " confirm
                
                if [ "$confirm" != "YES" ]; then
                    echo "Installation cancelled"
                    sleep 2
                    continue
                fi
                
                # 安装
                if install_openwrt "/tmp/openwrt.img" "/dev/$disk"; then
                    echo ""
                    echo "✅ Installation successful!"
                    echo ""
                    echo "System will reboot in 10 seconds..."
                    
                    for i in {10..1}; do
                        echo -ne "Rebooting in $i seconds...\r"
                        sleep 1
                    done
                    
                    echo ""
                    echo "Rebooting..."
                    reboot -f
                else
                    echo ""
                    echo "❌ Installation failed!"
                    read -p "Press Enter to continue..."
                fi
                ;;
            4)
                echo "Starting shell..."
                echo "Install command: dd if=/tmp/openwrt.img of=/dev/sdX bs=4M"
                exec /bin/sh
                ;;
            5)
                echo "Rebooting..."
                reboot
                ;;
            *)
                echo "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# 启动主菜单
main_menu
INIT_SCRIPT

chmod +x "${WORK_DIR}/chroot/init"

# ================= 第五步：创建initrd =================
echo "5. 创建initrd..."

# 进入chroot目录
cd "${WORK_DIR}/chroot"

# 创建initrd（包含所有文件）
echo "  打包initrd.img..."
find . | cpio -o -H newc | gzip -9 > "${WORK_DIR}/iso/initrd.img" 2>/dev/null || {
    # 备选方法
    find . -print0 | cpio -0 -o -H newc | gzip -9 > "${WORK_DIR}/iso/initrd.img"
}

echo "  initrd大小: $(ls -lh "${WORK_DIR}/iso/initrd.img" | awk '{print $5}')"

# ================= 第六步：创建引导配置 =================
echo "6. 创建引导配置..."

# 创建ISO目录结构
mkdir -p "${WORK_DIR}/iso/boot/isolinux"

# 获取引导文件
if [ -f /usr/lib/ISOLINUX/isolinux.bin ]; then
    cp /usr/lib/ISOLINUX/isolinux.bin "${WORK_DIR}/iso/boot/isolinux/"
else
    # 尝试下载
    wget -q "${TC_MIRROR}/isolinux.bin" \
        -O "${WORK_DIR}/iso/boot/isolinux/isolinux.bin" 2>/dev/null || {
        echo "❌ 找不到isolinux.bin"
        exit 1
    }
fi

# 复制syslinux模块
for module in ldlinux.c32 libutil.c32 menu.c32; do
    if [ -f "/usr/lib/syslinux/modules/bios/${module}" ]; then
        cp "/usr/lib/syslinux/modules/bios/${module}" "${WORK_DIR}/iso/boot/isolinux/"
    fi
done

# 创建ISOLINUX配置
cat > "${WORK_DIR}/iso/boot/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT openwrt
PROMPT 0
TIMEOUT 300
UI menu.c32

MENU TITLE OpenWRT Installer (Chroot)

LABEL openwrt
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /vmlinuz64
  APPEND initrd=/initrd.img quiet console=ttyS0 console=tty0

LABEL shell
  MENU LABEL ^Direct Shell
  KERNEL /vmlinuz64
  APPEND initrd=/initrd.img quiet console=ttyS0 console=tty0 init=/bin/sh

LABEL local
  MENU LABEL Boot from ^local drive
  LOCALBOOT 0x80
  TIMEOUT 60
ISOLINUX_CFG

touch "${WORK_DIR}/iso/boot/isolinux/boot.cat"

# ================= 第七步：添加额外工具 =================
echo "7. 添加额外工具..."

# 在chroot中安装额外工具（可选）
# 这里可以下载busybox等工具到chroot环境
cd "${WORK_DIR}/chroot"

# 下载busybox（如果需要在initrd中）
if [ ! -f bin/busybox ] && command -v wget >/dev/null 2>&1; then
    echo "  下载busybox..."
    wget -q "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" \
        -O bin/busybox 2>/dev/null && chmod +x bin/busybox || true
fi

# ================= 第八步：构建ISO =================
echo "8. 构建ISO..."

cd "${WORK_DIR}"

# 检查构建工具
if command -v xorriso >/dev/null 2>&1; then
    echo "  使用xorriso构建..."
    
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "OPENWRT-CHROOT" \
        -eltorito-boot iso/boot/isolinux/isolinux.bin \
        -eltorito-catalog iso/boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin 2>/dev/null \
        -output "${OUTPUT_DIR}/${ISO_NAME}" \
        "${WORK_DIR}/iso"
        
elif command -v genisoimage >/dev/null 2>&1; then
    echo "  使用genisoimage构建..."
    
    genisoimage \
        -o "${OUTPUT_DIR}/${ISO_NAME}" \
        -b iso/boot/isolinux/isolinux.bin \
        -c iso/boot/isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -V "OPENWRT-CHROOT" \
        "${WORK_DIR}/iso"
else
    echo "❌ 没有找到ISO构建工具"
    exit 1
fi

# ================= 第九步：验证结果 =================
echo "9. 验证结果..."

if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    ISO_SIZE=$(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')
    ISO_SIZE_BYTES=$(stat -c%s "${OUTPUT_DIR}/${ISO_NAME}")
    ISO_SIZE_MB=$((ISO_SIZE_BYTES / 1024 / 1024))
    
    echo ""
    echo "✅ ISO构建成功!"
    echo ""
    echo "📊 构建信息:"
    echo "  文件: ${ISO_NAME}"
    echo "  大小: ${ISO_SIZE} (${ISO_SIZE_MB}MB)"
    echo "  内核: vmlinuz64"
    echo "  initrd: 包含完整rootfs"
    echo "  引导: BIOS (ISOLINUX)"
    echo ""
    
    # 显示initrd内容摘要
    echo "📦 initrd内容摘要:"
    echo "  Total files in initrd: $(cd "${WORK_DIR}/chroot" && find . -type f | wc -l)"
    echo "  initrd size: $(ls -lh "${WORK_DIR}/iso/initrd.img" | awk '{print $5}')"
    echo ""
    
    # 创建使用说明
    cat > "${OUTPUT_DIR}/README-CHROOT.txt" << 'README'
OpenWRT Chroot Installer
========================

基于Tiny Core Linux的chroot技术构建的OpenWRT安装器。

特点:
1. 使用rootfs64.gz作为最小基础系统
2. 在内存中运行(tmpfs)，速度快
3. 包含完整的安装界面
4. 自动搜索OpenWRT镜像文件

使用方法:
1. 准备OpenWRT镜像文件，命名为: openwrt.img
2. 写入ISO到USB: sudo dd if=openwrt-installer.iso of=/dev/sdX bs=4M
3. 复制openwrt.img到USB根目录
4. 从USB启动计算机
5. 选择"Install OpenWRT"
6. 按照菜单操作

技术细节:
- 基于Tiny Core Linux 16.x
- 使用chroot技术创建完整rootfs
- initrd包含所有必要文件
- 支持自动设备检测

构建时间: $(date)
README
    
    echo "📖 详细说明: ${OUTPUT_DIR}/README-CHROOT.txt"
    
    # 测试命令
    cat > "${OUTPUT_DIR}/test-chroot.sh" << 'TEST_SCRIPT'
#!/bin/bash
echo "测试Chroot ISO引导"
echo "=================="
echo "ISO: $1"
echo ""
echo "QEMU测试命令:"
echo "qemu-system-x86_64 -cdrom \"$1\" -m 512 -boot d -serial stdio"
echo ""
echo "检查ISO内容:"
if command -v isoinfo >/dev/null 2>&1; then
    isoinfo -d -i "$1" 2>/dev/null | grep -E "Volume|Boot"
fi
TEST_SCRIPT
    chmod +x "${OUTPUT_DIR}/test-chroot.sh"
    
    echo ""
    echo "🔧 测试命令: ${OUTPUT_DIR}/test-chroot.sh \"${OUTPUT_DIR}/${ISO_NAME}\""
    
else
    echo "❌ ISO构建失败"
    exit 1
fi

# 清理（保留iso和output）
rm -rf "${WORK_DIR}/chroot" "${WORK_DIR}/tcz" "${WORK_DIR}/rootfs64.gz"
echo ""
echo "✅ 构建完成! 临时文件已清理。"
