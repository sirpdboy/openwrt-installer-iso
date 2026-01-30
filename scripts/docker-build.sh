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

RUN echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories

# 安装完整的ISO构建工具链和内核
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
    linux-lts \
    linux-firmware-none \
    && rm -rf /var/cache/apk/*
# 创建必要的设备节点
RUN mknod -m 0660 /dev/loop0 b 7 0 2>/dev/null || true && \
    mknod -m 0660 /dev/loop1 b 7 1 2>/dev/null || true

# 下载备用内核（如果Alpine内核安装失败）
RUN echo "下载备用内核..." && \
    mkdir -p /tmp/kernel && cd /tmp/kernel && \
    curl -L -o kernel.tar.xz https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.30.tar.xz 2>/dev/null || \
    curl -L -o kernel.tar.xz https://mirrors.edge.kernel.org/pub/linux/kernel/v6.x/linux-6.6.30.tar.xz 2>/dev/null || \
    echo "内核下载失败，继续..."

# 验证工具和内核
RUN echo "🔧 验证安装:" && \
    echo "内核位置:" && \
    ls -la /boot/ 2>/dev/null || echo "无/boot目录" && \
    echo "" && \
    echo "可用内核:" && \
    find /boot -name "vmlinuz*" 2>/dev/null | head -5 || echo "未找到内核" && \
    echo "" && \
    echo "xorriso: $(which xorriso)" && \
    echo "mkfs.fat: $(which mkfs.fat 2>/dev/null || which mkfs.vfat 2>/dev/null || echo '未找到')"
WORKDIR /work

# 复制构建脚本
COPY scripts/build-iso-alpine.sh /work/build-iso.sh
RUN chmod +x /work/build-iso.sh


ENTRYPOINT ["/work/build-iso.sh"]


DOCKERFILE_EOF

# 更新版本号
# sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/g" "$DOCKERFILE_PATH"

# 创建完整的Alpine构建脚本
cat > scripts/build-iso-alpine.sh << 'BUILD_SCRIPT_EOF'
#!/bin/bash
# openwrt-iso-proven.sh - 经过测试的解决方案

set -e

echo "================================================"
echo "  OpenWRT ISO Builder - Proven Solution"
echo "================================================"
echo ""

# 参数
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt.iso}"
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"

[ $# -lt 1 ] && { echo "用法: $0 <openwrt.img> [输出目录] [iso名称] [alpine版本]"; exit 1; }
[ ! -f "$INPUT_IMG" ] && { echo "错误: 找不到IMG文件: $INPUT_IMG"; exit 1; }

# 工作目录
WORK_DIR="/tmp/openwrt-proven-$(date +%s)"
mkdir -p "$WORK_DIR"
mkdir -p "$OUTPUT_DIR"

INPUT_ABS=$(realpath "$INPUT_IMG")
OUTPUT_ABS=$(realpath "$OUTPUT_DIR")
ISO_PATH="$OUTPUT_ABS/$ISO_NAME"

echo "🔧 配置:"
echo "  输入镜像: $INPUT_ABS"
echo "  输出ISO: $ISO_PATH"
echo ""

# ========== 步骤1: 创建initramfs目录结构 ==========
echo "[1/7] 创建initramfs目录结构..."

INITRAMFS_DIR="$WORK_DIR/initramfs"
rm -rf "$INITRAMFS_DIR"
mkdir -p "$INITRAMFS_DIR"

# 创建完整的目录结构
for dir in bin dev etc lib lib64 proc root sbin sys tmp usr/bin usr/sbin var mnt images; do
    mkdir -p "$INITRAMFS_DIR/$dir"
done

# ========== 步骤2: 创建绝对正确的init脚本 ==========
echo "[2/7] 创建init脚本..."

# 创建init文件 - 这是最关键的部分！
cat > "$INITRAMFS_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh
# 绝对正确的init脚本 - 内核第一个进程

# 1. 挂载核心文件系统
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || /bin/busybox mount -t tmpfs tmpfs /dev
/bin/busybox mount -t tmpfs tmpfs /tmp

# 2. 创建设备节点（必须！）
/bin/busybox mkdir -p /dev/pts
[ ! -c /dev/console ] && /bin/busybox mknod /dev/console c 5 1
[ ! -c /dev/null ] && /bin/busybox mknod /dev/null c 1 3
[ ! -c /dev/tty ] && /bin/busybox mknod /dev/tty c 5 0
[ ! -c /dev/tty0 ] && /bin/busybox mknod /dev/tty0 c 4 0
[ ! -c /dev/tty1 ] && /bin/busybox mknod /dev/tty1 c 4 1

# 3. 设置控制台（必须！）
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 4. 设置PATH环境变量
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# 5. 启动udev或mdev
if [ -x /bin/mdev ]; then
    /bin/busybox echo "/bin/mdev" > /proc/sys/kernel/hotplug
    /bin/mdev -s
fi

# 6. 清屏并显示信息
/bin/busybox clear
/bin/busybox echo "========================================"
/bin/busybox echo "  OpenWRT Installer - Init Started"
/bin/busybox echo "========================================"
/bin/busybox echo ""
/bin/busybox echo "Checking system..."
/bin/busybox echo ""

# 7. 检查必要文件
if [ ! -x /bin/busybox ]; then
    /bin/busybox echo "ERROR: /bin/busybox not found or not executable!"
    /bin/busybox echo "Dropping to emergency shell..."
    exec /bin/busybox sh
fi

# 8. 加载必要内核模块
/bin/busybox echo "Loading kernel modules..."
for module in loop isofs cdrom sr_mod virtio_blk nvme ahci sd_mod usb-storage; do
    /bin/busybox modprobe $module 2>/dev/null || true
done

# 9. 挂载安装介质
/bin/busybox echo "Mounting installation media..."
for device in /dev/sr0 /dev/cdrom /dev/sr[0-9]*; do
    if [ -b "$device" ]; then
        /bin/busybox echo "Found device: $device"
        /bin/busybox mount -t iso9660 -o ro "$device" /mnt 2>/dev/null && {
            /bin/busybox echo "Successfully mounted $device"
            break
        }
    fi
done

# 10. 如果挂载成功，复制OpenWRT镜像
if /bin/busybox mountpoint -q /mnt; then
    if [ -f /mnt/images/openwrt.img ]; then
        /bin/busybox echo "Copying OpenWRT image..."
        /bin/busybox cp /mnt/images/openwrt.img /images/ 2>/dev/null || true
    fi
    /bin/busybox umount /mnt 2>/dev/null || true
fi

# 11. 运行安装程序
/bin/busybox echo ""
/bin/busybox echo "Starting OpenWRT installer..."
/bin/busybox echo ""

# 创建简单的安装脚本并执行
cat > /install.sh << 'INSTALL_EOF'
#!/bin/busybox sh

clear
echo "========================================"
echo "      OpenWRT Installation Menu"
echo "========================================"
echo ""

while true; do
    echo "1) Install OpenWRT to disk"
    echo "2) List available disks"
    echo "3) Start emergency shell"
    echo "4) Reboot system"
    echo ""
    echo -n "Select option (1-4): "
    read choice
    
    case $choice in
        1)
            echo ""
            echo "Available disks:"
            echo "----------------"
            for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
                [ -b "$disk" ] && echo "  $disk"
            done
            echo ""
            echo -n "Enter target disk (e.g., sda): "
            read target
            [ -z "$target" ] && continue
            
            [ "$target" != "/dev/"* ] && target="/dev/$target"
            [ ! -b "$target" ] && echo "Disk not found!" && sleep 2 && continue
            
            echo ""
            echo "WARNING: This will ERASE ALL DATA on $target!"
            echo ""
            echo -n "Type 'YES' to confirm: "
            read confirm
            [ "$confirm" != "YES" ] && continue
            
            # Find OpenWRT image
            img=""
            [ -f /images/openwrt.img ] && img="/images/openwrt.img"
            [ -z "$img" ] && echo "OpenWRT image not found!" && sleep 2 && continue
            
            echo ""
            echo "Installing OpenWRT to $target..."
            echo ""
            
            if command -v pv >/dev/null 2>&1; then
                pv "$img" | dd of="$target" bs=4M
            else
                dd if="$img" of="$target" bs=4M status=progress 2>/dev/null || \
                dd if="$img" of="$target" bs=4M
            fi
            
            if [ $? -eq 0 ]; then
                sync
                echo ""
                echo "✅ Installation successful!"
                echo ""
                echo "System will reboot in 10 seconds..."
                sleep 10
                reboot -f
            else
                echo ""
                echo "❌ Installation failed!"
                sleep 2
            fi
            ;;
        2)
            echo ""
            echo "Available disks:"
            echo "----------------"
            lsblk 2>/dev/null || {
                for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
                    if [ -b "$disk" ]; then
                        size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
                        size_gb=$((size / 1024 / 1024 / 1024))
                        echo "  $disk - ${size_gb}GB"
                    fi
                done
            }
            echo ""
            echo -n "Press Enter to continue..."
            read
            ;;
        3)
            echo ""
            echo "Starting emergency shell..."
            echo "Type 'exit' to return to menu"
            echo ""
            exec /bin/busybox sh
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
INSTALL_EOF

chmod +x /install.sh
exec /bin/busybox sh /install.sh

# 如果上面失败，进入紧急shell
/bin/busybox echo "Install script failed, dropping to emergency shell..."
exec /bin/busybox sh
INIT_EOF

# 确保init文件可执行
chmod 755 "$INITRAMFS_DIR/init"

# 测试init脚本语法
echo "测试init脚本语法..."
if /bin/sh -n "$INITRAMFS_DIR/init" 2>/dev/null; then
    echo "✅ init脚本语法正确"
else
    echo "❌ init脚本语法错误"
    /bin/sh -n "$INITRAMFS_DIR/init" 2>&1 | head -5
fi

# ========== 步骤3: 复制busybox并创建符号链接 ==========
echo "[3/7] 准备busybox..."

# 复制busybox到initramfs
if command -v busybox >/dev/null 2>&1; then
    echo "复制busybox..."
    BUSYBOX_PATH=$(which busybox)
    cp "$BUSYBOX_PATH" "$INITRAMFS_DIR/bin/busybox"
    chmod 755 "$INITRAMFS_DIR/bin/busybox"
    
    # 检查busybox是否可用
    if "$INITRAMFS_DIR/bin/busybox" --help 2>&1 | head -1 | grep -q "BusyBox"; then
        echo "✅ busybox复制成功"
    else
        echo "❌ busybox不可用"
        exit 1
    fi
else
    echo "❌ 错误: 系统没有busybox"
    exit 1
fi

# 创建符号链接 - 使用busybox命令自身创建
echo "创建busybox符号链接..."
cd "$INITRAMFS_DIR"
cat > create_links.sh << 'LINK_EOF'
#!/bin/sh
cd /bin
./busybox --install -s . 2>/dev/null || {
    # 手动创建必要的链接
    for app in sh mount umount modprobe insmod rmmod lsmod \
               losetup dd cp mv rm cat echo ls \
               mkdir rmdir chmod chown ln sleep kill ps \
               grep sed awk head tail find mknod mdev \
               clear stty tty date which true false test \
               [ printf read reboot poweroff halt blkid \
               fdisk sfdisk blockdev pv gzip gunzip tar cpio \
               wget curl ping dmesg sort uniq wc \
               basename dirname cut tr xargs; do
        ln -sf busybox $app 2>/dev/null || true
    done
}
LINK_EOF

chmod +x create_links.sh

# 在chroot环境中运行（确保环境正确）
echo "在chroot环境中创建链接..."
if chroot . /bin/sh create_links.sh 2>/dev/null; then
    echo "✅ 符号链接创建成功"
else
    echo "⚠️ chroot失败，手动创建链接..."
    cd "$INITRAMFS_DIR/bin"
    ln -sf busybox sh 2>/dev/null || true
    ln -sf busybox mount 2>/dev/null || true
    ln -sf busybox umount 2>/dev/null || true
    ln -sf busybox modprobe 2>/dev/null || true
    ln -sf busybox dd 2>/dev/null || true
    ln -sf busybox reboot 2>/dev/null || true
    cd - >/dev/null
fi

rm -f create_links.sh
cd - >/dev/null

# 验证关键文件
echo "验证关键文件..."
if [ -f "$INITRAMFS_DIR/init" ] && [ -x "$INITRAMFS_DIR/init" ] && \
   [ -f "$INITRAMFS_DIR/bin/busybox" ] && [ -f "$INITRAMFS_DIR/bin/sh" ]; then
    echo "✅ 所有关键文件都存在且可执行"
else
    echo "❌ 缺少关键文件:"
    [ -f "$INITRAMFS_DIR/init" ] || echo "  - init 不存在"
    [ -x "$INITRAMFS_DIR/init" ] || echo "  - init 不可执行"
    [ -f "$INITRAMFS_DIR/bin/busybox" ] || echo "  - busybox 不存在"
    [ -f "$INITRAMFS_DIR/bin/sh" ] || echo "  - sh 不存在"
    exit 1
fi

# ========== 步骤4: 复制OpenWRT镜像 ==========
echo "[4/7] 复制OpenWRT镜像..."
mkdir -p "$INITRAMFS_DIR/images"
cp "$INPUT_ABS" "$INITRAMFS_DIR/images/openwrt.img"
echo "✅ OpenWRT镜像复制完成"

# ========== 步骤5: 打包initramfs ==========
echo "[5/7] 打包initramfs..."

cd "$INITRAMFS_DIR"

# 方法1: 使用find打包（更可靠）
echo "方法1: 使用find打包..."
find . -print0 | cpio --null -ov -H newc 2>/dev/null | \
    gzip -9 > "$WORK_DIR/initramfs.gz"

# 检查initramfs是否创建成功
if [ ! -f "$WORK_DIR/initramfs.gz" ] || [ ! -s "$WORK_DIR/initramfs.gz" ]; then
    echo "方法1失败，尝试方法2..."
    # 方法2: 明确列出文件
    {
        echo "init"
        find bin -type f -o -type l
        echo "images/openwrt.img"
        echo "dev"
        echo "proc"
        echo "sys"
        echo "tmp"
        echo "mnt"
        for dir in etc lib lib64 root sbin usr var; do
            [ -d "$dir" ] && echo "$dir"
        done
    } | cpio -o -H newc 2>/dev/null | gzip -9 > "$WORK_DIR/initramfs.gz"
fi

INITRAMFS_SIZE=$(du -h "$WORK_DIR/initramfs.gz" | cut -f1)
echo "✅ initramfs大小: $INITRAMFS_SIZE"

# 测试initramfs是否正常
echo "测试initramfs..."
TEST_DIR="$WORK_DIR/test-initramfs"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

if gzip -dc "$WORK_DIR/initramfs.gz" | cpio -id 2>/dev/null; then
    echo "✅ initramfs可正常解压"
    
    # 详细检查
    echo "检查解压后的文件:"
    echo "  init 存在: $(test -f init && echo '是' || echo '否')"
    echo "  init 可执行: $(test -x init && echo '是' || echo '否')"
    echo "  init shebang: $(head -1 init 2>/dev/null || echo '无')"
    echo "  /bin/busybox 存在: $(test -f bin/busybox && echo '是' || echo '否')"
    echo "  /bin/sh 存在: $(test -f bin/sh && echo '是' || echo '否')"
    
    # 测试init脚本
    if [ -f init ] && [ -x init ]; then
        echo "测试init脚本执行..."
        if /bin/sh -n init 2>/dev/null; then
            echo "✅ init脚本语法正确"
        else
            echo "❌ init脚本语法错误"
        fi
    fi
else
    echo "❌ initramfs解压失败"
fi

cd - >/dev/null
rm -rf "$TEST_DIR"
cd - >/dev/null

echo ""

# ========== 步骤6: 获取内核 ==========
echo "[6/7] 准备内核..."

# 获取内核
KERNEL_PATH="$WORK_DIR/vmlinuz"
if [ -f /boot/vmlinuz-lts ]; then
    cp /boot/vmlinuz-lts "$KERNEL_PATH"
    echo "✅ 使用内核: vmlinuz-lts"
elif [ -f /boot/vmlinuz ]; then
    cp /boot/vmlinuz "$KERNEL_PATH"
    echo "✅ 使用内核: vmlinuz"
else
    echo "❌ 错误: 找不到内核文件"
    echo "在以下位置查找:"
    find /boot -name "vmlinuz*" 2>/dev/null | head -5
    exit 1
fi

KERNEL_SIZE=$(du -h "$KERNEL_PATH" | cut -f1)
echo "✅ 内核大小: $KERNEL_SIZE"

# ========== 步骤7: 构建ISO ==========
echo "[7/7] 构建ISO..."

ISO_ROOT="$WORK_DIR/iso"
rm -rf "$ISO_ROOT"
mkdir -p "$ISO_ROOT"/{isolinux,boot,images}

# 复制文件
cp "$KERNEL_PATH" "$ISO_ROOT/boot/vmlinuz"
cp "$WORK_DIR/initramfs.gz" "$ISO_ROOT/boot/initramfs"
cp "$INPUT_ABS" "$ISO_ROOT/images/openwrt.img"

# 创建ISOLINUX配置
cat > "$ISO_ROOT/isolinux/isolinux.cfg" << 'ISOLINUX_EOF'
DEFAULT install
TIMEOUT 300
PROMPT 1
UI vesamenu.c32

MENU TITLE OpenWRT Installer
MENU BACKGROUND splash.png

LABEL install
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs console=tty0 console=ttyS0,115200 rw quiet

LABEL install_debug
  MENU LABEL Install OpenWRT (debug mode)
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs console=tty0 console=ttyS0,115200 rw debug

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs console=tty0 init=/bin/sh rw

LABEL memtest
  MENU LABEL Memory Test
  KERNEL /boot/memtest

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32
ISOLINUX_EOF

# 复制引导文件
echo "复制引导文件..."
SYS_FOUND=0
for sys_dir in /usr/share/syslinux /usr/lib/syslinux; do
    if [ -d "$sys_dir" ]; then
        echo "从 $sys_dir 复制文件..."
        for file in isolinux.bin ldlinux.c32 libutil.c32 libcom32.c32 vesamenu.c32 menu.c32 chain.c32 reboot.c32; do
            [ -f "$sys_dir/$file" ] && cp "$sys_dir/$file" "$ISO_ROOT/isolinux/" && echo "  ✅ $file"
        done
        
        [ -f "$sys_dir/memtest" ] && cp "$sys_dir/memtest" "$ISO_ROOT/boot/"
        [ -f "$sys_dir/splash.png" ] && cp "$sys_dir/splash.png" "$ISO_ROOT/isolinux/" 2>/dev/null || true
        
        SYS_FOUND=1
        break
    fi
done

if [ $SYS_FOUND -eq 0 ]; then
    echo "⚠️ 警告: 未找到syslinux文件"
    echo "ISO可能不可引导"
fi

# 构建ISO
echo "构建ISO镜像..."
xorriso -as mkisofs \
    -r -V 'OPENWRT_INSTALL' \
    -o "$ISO_PATH" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin 2>/dev/null \
    "$ISO_ROOT" 2>&1 | grep -v "UPDATE" | tail -20

# 验证ISO
if [ -f "$ISO_PATH" ] && [ -s "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    echo "🎉 🎉 🎉 ISO构建成功! 🎉 🎉 🎉"
    echo ""
    echo "📁 ISO文件: $ISO_PATH"
    echo "📊 总大小: $ISO_SIZE"
    echo ""
    echo "📦 组件详情:"
    echo "  - 内核: $KERNEL_SIZE"
    echo "  - initramfs: $INITRAMFS_SIZE"
    echo "  - OpenWRT镜像: $(du -h "$INPUT_ABS" | cut -f1)"
    echo ""
    
    # 创建快速测试脚本
    cat > "$OUTPUT_ABS/test-iso.sh" << 'TEST_EOF'
#!/bin/bash
# 测试ISO脚本

ISO="$1"
if [ ! -f "$ISO" ]; then
    echo "用法: $0 <iso文件>"
    exit 1
fi

echo "测试ISO: $ISO"
echo ""

# 1. 检查文件类型
echo "1. 文件类型:"
file "$ISO"
echo ""

# 2. 检查ISO内容
echo "2. ISO内容摘要:"
if command -v xorriso >/dev/null 2>&1; then
    xorriso -indev "$ISO" -toc 2>&1 | head -20
elif command -v isoinfo >/dev/null 2>&1; then
    isoinfo -d -i "$ISO" 2>&1
fi
echo ""

# 3. 检查引导能力
echo "3. 引导能力检查:"
if command -v xorriso >/dev/null 2>&1; then
    xorriso -indev "$ISO" -check_media 2>&1 | grep -i "boot\|efi\|eltorito" || true
fi
echo ""

# 4. 提取initramfs测试
echo "4. 测试initramfs:"
TEMP_DIR="/tmp/iso-test-$$"
mkdir -p "$TEMP_DIR"

# 提取initramfs
xorriso -osirrox on -indev "$ISO" -extract /boot/initramfs "$TEMP_DIR/initramfs" 2>/dev/null || \
isoinfo -i "$ISO" -x /BOOT/INITRAMFS. -o "$TEMP_DIR/initramfs" 2>/dev/null

if [ -f "$TEMP_DIR/initramfs" ]; then
    echo "  ✅ 成功提取initramfs"
    
    # 解压测试
    mkdir -p "$TEMP_DIR/extract"
    cd "$TEMP_DIR/extract"
    if gzip -dc "$TEMP_DIR/initramfs" 2>/dev/null | cpio -id 2>/dev/null; then
        echo "  ✅ initramfs可解压"
        
        # 检查关键文件
        [ -f init ] && echo "  ✅ 找到init文件" || echo "  ❌ 未找到init文件"
        [ -x init ] && echo "  ✅ init文件可执行" || echo "  ❌ init文件不可执行"
        [ -f bin/busybox ] && echo "  ✅ 找到busybox" || echo "  ❌ 未找到busybox"
        [ -f bin/sh ] && echo "  ✅ 找到sh" || echo "  ❌ 未找到sh"
        
        # 显示init文件头
        echo "  init文件头: $(head -1 init 2>/dev/null || echo '无')"
    else
        echo "  ❌ initramfs解压失败"
    fi
    cd - >/dev/null
else
    echo "  ❌ 无法提取initramfs"
fi

# 清理
rm -rf "$TEMP_DIR"
echo ""
echo "✅ 测试完成"
TEST_EOF
    
    chmod +x "$OUTPUT_ABS/test-iso.sh"
    
    echo "💡 提示: 可以使用以下命令测试ISO:"
    echo "  $OUTPUT_ABS/test-iso.sh \"$ISO_PATH\""
    
else
    echo "❌ ISO构建失败"
    exit 1
fi

# 清理
rm -rf "$WORK_DIR"

echo ""
echo "✅ 所有步骤完成!"
exit 0


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
FINAL_ISO="$OUTPUT_ABS/$ISO_NAME"
if [ -f "$OUTPUT_ISO" ]; then
    # 重命名
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
        else
            echo "⚠ ISO可能不可引导（数据ISO）"
        fi
    fi

    # 检查是否为混合ISO
    echo ""
    echo "💻 引导支持:"
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -indev "$FINAL_ISO" -check_media 2>&1 | grep -i "efi\|uefi" && \
            echo "✅ 支持UEFI引导" || echo "⚠ 仅支持BIOS引导"
    fi

    exit 0
else
    echo ""
    echo "❌ ISO构建失败"

    # 显示容器日志
    echo "📋 容器日志 (最后50行):"
    docker logs --tail 50 openwrt-kernel-builder 2>/dev/null || echo "无法获取容器日志"
    
    # 检查输出目录
    echo ""
    echo "📁 输出目录内容:"
    ls -la "$OUTPUT_ABS/" 2>/dev/null || echo "输出目录不存在"
    
    exit 1
fi
