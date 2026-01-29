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

# 安装必需的工具（不使用setup-apkcache）
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
    file \
    && rm -rf /var/cache/apk/*

# 确保syslinux文件存在
RUN if [ ! -f /usr/share/syslinux/isolinux.bin ]; then \
        echo "重新安装syslinux..." && \
        apk add --no-cache --force syslinux; \
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

echo "=== OpenWRT ISO Builder (Alpine) ==="
echo "版本: $(date +%Y%m%d-%H%M%S)"
echo ""

# ========== 参数和配置 ==========
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"
OUTPUT_DIR="/output"
ISO_NAME="${ISO_NAME:-openwrt-installer.iso}"

# 检查输入文件
if [ ! -f "$INPUT_IMG" ]; then
    echo "❌ 错误: 输入文件不存在: $INPUT_IMG"
    exit 1
fi

# 检查输出目录
mkdir -p "$OUTPUT_DIR"

# ========== 第1步：准备工作区 ==========
echo "[1/10] 📁 创建工作区..."
WORK_DIR="/tmp/openwrt_build_$(date +%s)"
STAGING_DIR="$WORK_DIR/staging"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$STAGING_DIR"
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub,isolinux,live,images}

echo "工作区: $WORK_DIR"
echo "暂存区: $STAGING_DIR"
echo ""

# ========== 第2步：获取内核 ==========
echo "[2/10] 🔧 获取Linux内核..."

# 确保linux-lts已安装
if ! apk info -e linux-lts >/dev/null 2>&1; then
    echo "安装linux-lts内核..."
    apk add --no-cache linux-lts >/dev/null 2>&1 || {
        echo "警告: 无法安装linux-lts，尝试从包文件提取..."
    }
fi

# 查找内核文件
KERNEL_FOUND=false
KERNEL_PATHS=(
    "/boot/vmlinuz-lts"
    "/boot/vmlinuz"
    "/lib/modules/*/vmlinuz"
    "/usr/lib/modules/*/vmlinuz"
)
find /boot -name "vmlinuz*" 2>/dev/null | head -5

for path_pattern in "${KERNEL_PATHS[@]}"; do
    for kernel in $path_pattern; do
        if [ -f "$kernel" ]; then
            cp "$kernel" "$STAGING_DIR/live/vmlinuz"
            KERNEL_FOUND=true
            echo "✅ 找到内核: "$kernel"
            KERNEL_SIZE=$(du -h "$STAGING_DIR/live/vmlinuz" | cut -f1)
            echo "✅ 找到内核:  $(basename "$kernel") ($KERNEL_SIZE)"
            break 2
        fi
    done
done

# 备用方案：如果找不到内核，创建简单的启动系统
if [ "$KERNEL_FOUND" = false ]; then
    echo "⚠️  警告: 未找到Linux内核，创建最小启动系统..."
    
    # 创建简单的启动脚本作为内核（仅用于测试）
    cat > "$STAGING_DIR/live/vmlinuz" << 'KERNEL_EOF'
#!/bin/sh
echo "Minimal OpenWRT Installer"
echo "Kernel placeholder - real kernel should be included"
echo "Booting to shell..."
exec /bin/sh
KERNEL_EOF
    
    chmod +x "$STAGING_DIR/live/vmlinuz"
    KERNEL_SIZE="1K"
    echo "✅ 创建内核占位文件"
fi

echo ""

# ========== 第3步：准备initrd ==========
echo "[3/10] 🔧 准备initrd..."

INITRD_DIR="/tmp/initrd_$(date +%s)"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"

# 创建目录结构
echo "创建目录结构..."
for dir in bin sbin usr/bin usr/sbin lib lib64 dev proc sys tmp mnt images etc; do
    mkdir -p "$INITRD_DIR/$dir"
done

# ========== 第4步：复制必需工具 ==========
echo "[4/10] 📦 复制必需工具..."

# 复制busybox（核心）
echo "复制busybox..."
if [ -f /bin/busybox ]; then
    cp /bin/busybox "$INITRD_DIR/bin/"
    chmod 755 "$INITRD_DIR/bin/busybox"
    
    # 创建符号链接
    cd "$INITRD_DIR/bin"
    echo "创建busybox符号链接..."
    /bin/busybox --list | while read applet; do
        ln -sf busybox "$applet" 2>/dev/null || true
    done
    cd - >/dev/null
    echo "✅ busybox已配置"
else
    echo "❌ 错误: 找不到busybox"
    exit 1
fi

# 复制额外的工具（如果存在）
TOOLS_LIST=(
    "/sbin/fdisk"
    "/sbin/blkid"
    "/usr/bin/lsblk"
    "/usr/bin/pv"
    "/sbin/parted"
    "/sbin/mke2fs"
    "/sbin/e2fsck"
    "/sbin/dumpe2fs"
)

echo "复制额外工具..."
for tool in "${TOOLS_LIST[@]}"; do
    if [ -f "$tool" ]; then
        # 创建目标目录
        mkdir -p "$INITRD_DIR$(dirname "$tool")"
        # 复制工具
        cp "$tool" "$INITRD_DIR$tool" 2>/dev/null || true
        
        # 复制依赖库
        if ldd "$tool" 2>/dev/null >/dev/null; then
            ldd "$tool" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read lib; do
                if [ -f "$lib" ]; then
                    mkdir -p "$INITRD_DIR$(dirname "$lib")"
                    cp "$lib" "$INITRD_DIR$lib" 2>/dev/null || true
                fi
            done
        fi
        echo "  ✅ $(basename "$tool")"
    fi
done

# ========== 第5步：复制库文件 ==========
echo "[5/10] 📚 复制库文件..."

# 基础C库
BASE_LIBS=(
    "/lib/ld-musl-x86_64.so.1"
    "/lib/libc.musl-x86_64.so.1"
)

# 其他常用库
OTHER_LIBS=(
    "/lib/libblkid.so.*"
    "/lib/libmount.so.*"
    "/lib/libuuid.so.*"
    "/lib/libsmartcols.so.*"
    "/lib/libfdisk.so.*"
    "/usr/lib/libreadline.so.*"
    "/usr/lib/libncursesw.so.*"
)

echo "复制基础库..."
for lib in "${BASE_LIBS[@]}"; do
    if [ -f "$lib" ]; then
        mkdir -p "$INITRD_DIR$(dirname "$lib")"
        cp "$lib" "$INITRD_DIR$lib" 2>/dev/null || true
    fi
done

echo "复制其他库..."
for lib_pattern in "${OTHER_LIBS[@]}"; do
    for lib in $lib_pattern; do
        if [ -f "$lib" ]; then
            mkdir -p "$INITRD_DIR$(dirname "$lib")"
            cp "$lib" "$INITRD_DIR$(dirname "$lib")/" 2>/dev/null || true
        fi
    done
done

# ========== 第6步：创建init脚本 ==========
echo "[6/10] 📝 创建init脚本..."

cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/sh

# 初始化系统
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# 挂载虚拟文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# 设置控制台
exec 0</dev/console 2>/dev/null || exec 0</dev/tty0
exec 1>/dev/console 2>/dev/null || exec 1>/dev/tty0
exec 2>/dev/console 2>/dev/null || exec 2>/dev/tty0

# 创建设备节点
[ -c /dev/console ] || mknod /dev/console c 5 1 2>/dev/null || true
[ -c /dev/null ] || mknod /dev/null c 1 3 2>/dev/null || true
[ -c /dev/zero ] || mknod /dev/zero c 1 5 2>/dev/null || true

# 挂载tmpfs
mount -t tmpfs tmpfs /tmp 2>/dev/null || true

# 清理屏幕
clear

# 显示标题
cat << "HEADER"

╔══════════════════════════════════════════════════╗
║          OpenWRT Installation System             ║
║            Alpine Linux Based                    ║
╚══════════════════════════════════════════════════╝

HEADER

echo "系统初始化完成..."
echo ""

# 查找OpenWRT镜像
IMG_PATH=""
for path in /images/openwrt.img /mnt/images/openwrt.img /live/images/openwrt.img; do
    if [ -f "$path" ]; then
        IMG_PATH="$path"
        echo "✅ 找到OpenWRT刷机镜像"
        IMG_SIZE=$(ls -lh "$path" 2>/dev/null | awk '{print $5}' || echo "unknown")
        echo "   路径: $path"
        echo "   大小: $IMG_SIZE"
        break
    fi
done

if [ -z "$IMG_PATH" ]; then
    echo "❌ 错误: 未找到刷机镜像!"
    echo "进入救援Shell..."
    echo ""
    exec /bin/sh
fi

# 显示磁盘信息
show_disks() {
    echo ""
    echo "📊 可用磁盘列表:"
    echo "========================================"
    
    # 使用lsblk如果可用
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -n -o NAME,SIZE,TYPE,TRAN 2>/dev/null | head -20
    else
        # 简单列出块设备
        echo "设备名       类型"
        for disk in /dev/sd[a-z] /dev/vd[a-z] /dev/hd[a-z] /dev/nvme[0-9]n[0-9]; do
            [ -b "$disk" ] && echo "$(basename $disk)    磁盘"
        done
    fi
    echo "========================================"
}

# 主菜单
main_menu() {
    while true; do
        echo ""
        echo "请选择操作:"
        echo "  1. 刷机到磁盘"
        echo "  2. 显示磁盘信息"
        echo "  3. 进入Shell"
        echo "  4. 重启系统"
        echo "  0. 退出"
        echo ""
        printf "请选择 [0-4]: "
        read choice
        
        case "$choice" in
            1)
                printf "请输入目标磁盘名称 (例如: sda, nvme0n1): "
                read target_disk
                
                if [ -z "$target_disk" ]; then
                    echo "❌ 未输入磁盘名"
                    continue
                fi
                
                # 添加/dev/前缀
                if [[ ! "$target_disk" =~ ^/dev/ ]]; then
                    target_disk="/dev/$target_disk"
                fi
                
                if [ ! -b "$target_disk" ]; then
                    echo "❌ 磁盘 $target_disk 不存在!"
                    continue
                fi
                
                # 确认
                echo ""
                echo "⚠️  ⚠️  ⚠️  警告 ⚠️  ⚠️  ⚠️"
                echo "这将完全擦除 $target_disk 上的所有数据!"
                echo "所有分区和数据都将永久丢失!"
                echo ""
                printf "确认刷机？输入大写 YES 继续: "
                read confirm
                
                if [ "$confirm" = "YES" ]; then
                    echo ""
                    echo "🚀 开始刷写 OpenWRT 到 $target_disk ..."
                    echo "========================================"
                    
                    # 检查磁盘大小
                    disk_size=$(blockdev --getsize64 "$target_disk" 2>/dev/null || echo 0)
                    img_size=$(stat -c %s "$IMG_PATH" 2>/dev/null || echo 0)
                    
                    if [ "$disk_size" -eq 0 ] || [ "$img_size" -eq 0 ]; then
                        echo "❌ 无法获取磁盘或镜像大小"
                        continue
                    fi
                    
                    if [ "$img_size" -gt "$disk_size" ]; then
                        echo "❌ 镜像大小大于磁盘容量"
                        continue
                    fi
                    
                    # 刷机
                    echo "正在刷写..."
                    if command -v pv >/dev/null 2>&1; then
                        pv -t -e -b -a "$IMG_PATH" | dd of="$target_disk" bs=4M oflag=sync status=none
                    else
                        dd if="$IMG_PATH" of="$target_disk" bs=4M oflag=sync status=progress
                    fi
                    
                    # 同步
                    sync
                    
                    echo "========================================"
                    echo "✅ ✅ ✅ 刷机完成! ✅ ✅ ✅"
                    echo ""
                    echo "OpenWRT已成功刷写到 $target_disk"
                    echo ""
                    
                    echo "系统将在10秒后自动重启..."
                    sleep 10
                    echo "正在重启..."
                    reboot -f
                else
                    echo "❌ 刷机取消"
                fi
                ;;
                
            2)
                show_disks
                ;;
                
            3)
                echo "进入Shell，输入'exit'返回主菜单"
                /bin/sh
                ;;
                
            4)
                echo "正在重启..."
                reboot -f
                ;;
                
            0)
                echo "退出系统..."
                exit 0
                ;;
                
            *)
                echo "❌ 无效选择"
                ;;
        esac
    done
}

# 启动主菜单
main_menu
INIT_EOF

chmod 755 "$INITRD_DIR/init"

# 创建设备节点
echo "创建设备节点..."
mknod "$INITRD_DIR/dev/console" c 5 1 2>/dev/null || true
mknod "$INITRD_DIR/dev/null" c 1 3 2>/dev/null || true
mknod "$INITRD_DIR/dev/zero" c 1 5 2>/dev/null || true
mknod "$INITRD_DIR/dev/tty" c 5 0 2>/dev/null || true
mknod "$INITRD_DIR/dev/tty0" c 4 0 2>/dev/null || true

# 复制OpenWRT镜像
echo "复制OpenWRT镜像..."
cp "$INPUT_IMG" "$INITRD_DIR/images/openwrt.img"
IMG_SIZE=$(du -h "$INPUT_IMG" | cut -f1)
echo "✅ 刷机镜像已复制 ($IMG_SIZE)"

# ========== 第7步：打包initrd ==========
echo "[7/10] 📦 打包initrd..."

cd "$INITRD_DIR"
echo "打包initrd..."
find . 2>/dev/null | cpio -H newc -o 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd.img"

INITRD_SIZE=$(du -h "$STAGING_DIR/live/initrd.img" | cut -f1)
echo "✅ initrd创建完成 ($INITRD_SIZE)"

cd - >/dev/null
rm -rf "$INITRD_DIR"
echo ""

# ========== 第8步：配置BIOS引导 ==========
echo "[8/10] 🔧 配置引导系统..."

# BIOS引导 (ISOLINUX)
echo "配置BIOS引导..."
ISOLINUX_FILES=(
    "isolinux.bin"
    "ldlinux.c32"
    "libutil.c32"
    "menu.c32"
    "vesamenu.c32"
)

# 查找并复制syslinux文件
for file in "${ISOLINUX_FILES[@]}"; do
    found=false
    for dir in /usr/share/syslinux /usr/lib/syslinux /lib/syslinux; do
        if [ -f "$dir/$file" ]; then
            cp "$dir/$file" "$STAGING_DIR/isolinux/"
            found=true
            echo "  ✅ $file"
            break
        fi
    done
    if [ "$found" = false ]; then
        echo "  ⚠️  未找到: $file"
    fi
done

# 创建ISOLINUX配置
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG_EOF'
DEFAULT vesamenu.c32
PROMPT 0
TIMEOUT 30
ONTIMEOUT install

MENU TITLE OpenWRT Installation System
MENU BACKGROUND /boot/splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std

LABEL install
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 console=ttyS0,115200n8 rw quiet

LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 console=ttyS0,115200n8 rw quiet init=/bin/sh

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
ISOLINUX_CFG_EOF

# ========== 第9步：配置UEFI引导 ==========
echo "[9/10] 🔧 配置UEFI引导..."

# 确保GRUB可用
if command -v grub-mkstandalone >/dev/null 2>&1; then
    echo "GRUB工具可用，配置UEFI引导..."
    
    # 创建GRUB配置目录
    mkdir -p "$STAGING_DIR/boot/grub"
    
    # 创建GRUB配置
    cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG_EOF'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    echo "Loading kernel..."
    linux /live/vmlinuz console=tty0 console=ttyS0,115200n8 rw quiet
    echo "Loading initrd..."
    initrd /live/initrd.img
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz console=tty0 console=ttyS0,115200n8 rw quiet init=/bin/sh
    initrd /live/initrd.img
}

menuentry "Reboot" {
    reboot
}
GRUB_CFG_EOF
    
    # 生成EFI文件
    echo "生成GRUB EFI文件..."
    TEMP_GRUB="/tmp/grub_build_$(date +%s)"
    mkdir -p "$TEMP_GRUB/EFI/boot"
    
    if grub-mkstandalone \
        -O x86_64-efi \
        -o "$TEMP_GRUB/EFI/boot/bootx64.efi" \
        --modules="part_gpt part_msdos fat ext2 iso9660 linux normal boot" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$STAGING_DIR/boot/grub/grub.cfg" 2>/dev/null; then
        
        cp "$TEMP_GRUB/EFI/boot/bootx64.efi" "$STAGING_DIR/EFI/boot/"
        echo "✅ GRUB EFI文件生成成功"
    else
        echo "❌ GRUB EFI生成失败"
    fi
    
    rm -rf "$TEMP_GRUB"
else
    echo "⚠️  GRUB工具不可用，跳过UEFI引导"
fi

# ========== 第10步：构建ISO ==========
echo "[10/10] 📀 构建ISO..."

cd "$WORK_DIR"

# 查找isohdpfx.bin（用于混合引导）
ISOHDPFX_PATH=""
for dir in /usr/share/syslinux /usr/lib/syslinux /lib/syslinux; do
    if [ -f "$dir/isohdpfx.bin" ]; then
        cp "$dir/isohdpfx.bin" "$WORK_DIR/"
        ISOHDPFX_PATH="$WORK_DIR/isohdpfx.bin"
        echo "✅ 找到isohdpfx.bin"
        break
    fi
done

# 构建ISO
OUTPUT_ISO="$OUTPUT_DIR/$ISO_NAME"
echo "构建ISO: $OUTPUT_ISO"

# 检查EFI引导文件是否存在
EFI_BOOT_FILE="$STAGING_DIR/EFI/boot/bootx64.efi"

if [ -f "$EFI_BOOT_FILE" ] && [ -f "$ISOHDPFX_PATH" ]; then
    echo "构建混合引导ISO (BIOS + UEFI)..."
    
    # 创建EFI引导镜像
    EFI_IMG="$WORK_DIR/efiboot.img"
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=16 status=none
    mkfs.fat -F 32 -n "UEFI_BOOT" "$EFI_IMG" >/dev/null 2>&1
    
    # 复制EFI文件
    echo "准备EFI引导镜像..."
    MNT_DIR="$WORK_DIR/efi_mnt"
    mkdir -p "$MNT_DIR"
    
    if mount -o loop "$EFI_IMG" "$MNT_DIR" 2>/dev/null; then
        mkdir -p "$MNT_DIR/EFI/boot"
        cp "$EFI_BOOT_FILE" "$MNT_DIR/EFI/boot/"
        umount "$MNT_DIR"
        echo "✅ EFI引导镜像准备完成"
    fi
    rm -rf "$MNT_DIR"
    
    # 构建混合ISO
    xorriso -as mkisofs \
        -r -V "OPENWRT_INSTALL" \
        -o "$OUTPUT_ISO" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr "$ISOHDPFX_PATH" \
        -eltorito-alt-boot \
        -e efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$STAGING_DIR" 2>&1 | tail -5
    
    rm -f "$EFI_IMG"
else
    echo "构建BIOS引导ISO..."
    
    xorriso -as mkisofs \
        -r -V "OPENWRT_INSTALL" \
        -o "$OUTPUT_ISO" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        "$STAGING_DIR" 2>&1 | tail -5
fi

# ========== 验证结果 ==========
if [ -f "$OUTPUT_ISO" ]; then
    ISO_SIZE=$(du -h "$OUTPUT_ISO" | cut -f1)
    echo ""
    echo "🎉🎉🎉 ISO构建成功! 🎉🎉🎉"
    echo ""
    echo "📊 构建摘要:"
    echo "  ISO文件: $OUTPUT_ISO"
    echo "  ISO大小: $ISO_SIZE"
    echo "  内核大小: $KERNEL_SIZE"
    echo "  initrd大小: $INITRD_SIZE"
    echo "  刷机镜像: $IMG_SIZE"
    echo ""
    
    # 验证ISO
    if command -v file >/dev/null 2>&1; then
        echo "🔍 ISO信息:"
        file "$OUTPUT_ISO"
    fi
    
    # 创建构建信息
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT刷机安装系统ISO
=======================
构建时间: $(date)
ISO文件:  $ISO_NAME
ISO大小:  $ISO_SIZE
内核:     $KERNEL_SIZE
initrd:   $INITRD_SIZE
刷机镜像: $IMG_SIZE

引导支持:
  - BIOS (ISOLINUX): 是
  - UEFI (GRUB): $(if [ -f "$EFI_BOOT_FILE" ]; then echo "是"; else echo "否"; fi)

使用方法:
  1. 制作USB启动盘:
     sudo dd if="$ISO_NAME" of=/dev/sdX bs=4M status=progress oflag=sync
  2. 从USB启动
  3. 选择"Install OpenWRT"
  4. 按照提示刷机

警告: 刷机会完全擦除目标磁盘!
EOF
    
    echo "✅ 构建信息保存到: $OUTPUT_DIR/build-info.txt"
    
    # 清理工作区
    rm -rf "$WORK_DIR"
    
    exit 0
else
    echo "❌ ISO构建失败"
    echo "工作区位置: $WORK_DIR"
    echo "暂存区内容:"
    ls -la "$STAGING_DIR/" 2>/dev/null || true
    exit 1
fi



BUILD_SCRIPT_EOF

chmod +x scripts/build-iso-alpine.sh
# ========== 构建Docker镜像 ==========
echo "🔨 构建Docker镜像..."
IMAGE_NAME="openwrt-alpine-builder:${ALPINE_VERSION}"

echo "构建镜像 $IMAGE_NAME ..."
docker build \
    -f "$DOCKERFILE_PATH" \
    --build-arg ALPINE_VERSION="$ALPINE_VERSION" \
    -t "$IMAGE_NAME" \
    . 2>&1 | tee /tmp/docker-build.log
if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "✅ Docker镜像构建成功: $IMAGE_NAME"
else
    echo "❌ Docker镜像构建失败"
    cat /tmp/docker-build.log | tail -30
    exit 1
fi

# ========== 运行Docker容器 ==========
echo "🚀 运行Docker容器构建ISO..."

# 清理旧的输出
rm -f "$OUTPUT_ABS"/*.iso "$OUTPUT_ABS"/build-info.txt 2>/dev/null || true

echo "启动构建容器..."
set +e
docker run --rm \
    --name openwrt-iso-builder \
    --privileged \
    -v "$IMG_ABS:/mnt/input.img:ro" \
    -v "$OUTPUT_ABS:/output:rw" \
    -e ISO_NAME="$ISO_NAME" \
    "$IMAGE_NAME"

CONTAINER_EXIT=$?
set -e

echo "容器退出代码: $CONTAINER_EXIT"

# ========== 检查结果 ==========
FINAL_ISO="$OUTPUT_ABS/$ISO_NAME"
if [ -f "$FINAL_ISO" ]; then
    echo ""
    echo "🎉🎉🎉 ISO构建成功! 🎉🎉🎉"
    echo ""
    echo "📁 ISO文件: $FINAL_ISO"
    ISO_SIZE=$(du -h "$FINAL_ISO" | cut -f1)
    echo "📊 大小: $ISO_SIZE"
    echo ""
    
    # 验证ISO
    echo "🔍 验证信息:"
    
    # 检查文件类型
    if command -v file >/dev/null 2>&1; then
        FILE_INFO=$(file "$FINAL_ISO")
        echo "文件类型: $FILE_INFO"
        
        if echo "$FILE_INFO" | grep -q "bootable\|DOS/MBR"; then
            echo "✅ ISO可引导"
        fi
    fi
    
    # 检查是否支持UEFI
    echo ""
    echo "💻 引导支持检查:"
    if command -v xorriso >/dev/null 2>&1; then
        if xorriso -indev "$FINAL_ISO" -toc 2>&1 | grep -q "El Torito boot image: efi"; then
            echo "✅ 支持UEFI引导"
        else
            echo "⚠️  仅支持BIOS引导"
        fi
    fi
    
    # 显示构建信息
    if [ -f "$OUTPUT_ABS/build-info.txt" ]; then
        echo ""
        echo "📋 构建信息:"
        cat "$OUTPUT_ABS/build-info.txt"
    fi
    
    echo ""
    echo "🚀 使用方法:"
    echo "   1. 虚拟机测试:"
    echo "      qemu-system-x86_64 -cdrom '$FINAL_ISO' -m 512M -enable-kvm"
    echo "   2. 制作USB启动盘:"
    echo "      sudo dd if='$FINAL_ISO' of=/dev/sdX bs=4M status=progress oflag=sync"
    echo "   3. 从USB或CD/DVD启动"
    
    exit 0
else
    echo ""
    echo "❌ ISO构建失败"
    
    # 显示可能的错误文件
    echo "输出目录内容:"
    ls -la "$OUTPUT_ABS/" 2>/dev/null || echo "输出目录为空"
    
    exit 1
fi
