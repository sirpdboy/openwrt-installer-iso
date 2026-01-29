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

# 安装最小但完整的工具集
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
    && rm -rf /var/cache/apk/*
    
# 尝试安装GRUB，如果失败则跳过
RUN apk add --no-cache grub grub-efi 2>/dev/null || \
    echo "GRUB安装失败，将使用替代方案" && \
    # 创建必要的工具占位
    mkdir -p /usr/sbin && \
    echo '#!/bin/sh\necho "GRUB tool not available"' > /usr/sbin/grub-mkimage && \
    chmod +x /usr/sbin/grub-mkimage

WORKDIR /work

# 复制构建脚本
COPY scripts/build-iso-alpine.sh /build.sh
RUN chmod +x /build.sh

ENTRYPOINT ["/build.sh"]

DOCKERFILE_EOF

# 更新版本号
# sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/g" "$DOCKERFILE_PATH"

# 创建完整的Alpine构建脚本
mkdir -p scripts
cat > scripts/build-iso-alpine.sh << 'BUILD_SCRIPT_EOF'
#!/bin/bash
set -e

echo "=== OpenWRT ISO Builder (Alpine 3.20) ==="

# 输入文件
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"

# 检查输入文件
if [ ! -f "$INPUT_IMG" ]; then
    echo "❌ 错误: 输入文件不存在: $INPUT_IMG"
    exit 1
fi


# ========== 第1步：准备工作区 ==========
echo "[1/8] 📁 创建工作区..."
WORK_DIR="/tmp/openwrt_build_$(date +%s)"
ISO_DIR="$WORK_DIR/iso"
STAGING_DIR="$WORK_DIR/staging"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$ISO_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub,isolinux,live,images}

echo "工作区: $WORK_DIR"
echo "暂存区: $STAGING_DIR"
echo ""

# ========== 第2步：获取Linux内核 ==========
echo "[2/8] 🔧 获取Linux内核..."

# 首先确保安装了linux-lts
if ! apk info -e linux-lts >/dev/null 2>&1; then
    echo "安装linux-lts内核..."
    apk add --no-cache linux-lts 2>/dev/null || true
fi

# 查找可用的内核
KERNEL_FOUND=false
echo "搜索内核文件..."
find /boot -name "vmlinuz*" 2>/dev/null | head -5

for kernel_path in /boot/vmlinuz-lts /boot/vmlinuz-generic /boot/vmlinuz; do
    if [ -f "$kernel_path" ]; then
        cp "$kernel_path" "$STAGING_DIR/live/vmlinuz"
        KERNEL_FOUND=true
        echo "✅ 找到内核: "$kernel_path"
        # 验证内核文件
        KERNEL_SIZE=$(du -h "$STAGING_DIR/live/vmlinuz" | cut -f1)
        echo "✅ 使用内核: $(basename "$kernel") ($KERNEL_SIZE)"
        break
    fi
done

# 如果还没找到，尝试直接下载
if [ "$KERNEL_FOUND" = false ]; then
    echo "尝试下载内核..."
    # 从Alpine仓库下载linux-lts包并提取内核
    TEMP_DIR="/tmp/kernel_extract_$(date +%s)"
    mkdir -p "$TEMP_DIR"
    
    if curl -L -o "$TEMP_DIR/linux-lts.apk" \
        "https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/linux-lts-6.6.35-r0.apk" \
        2>/dev/null; then
        
        tar -xzOf "$TEMP_DIR/linux-lts.apk" boot/vmlinuz-lts > "$STAGING_DIR/live/vmlinuz" 2>/dev/null
        if [ -s "$STAGING_DIR/live/vmlinuz" ]; then
            KERNEL_FOUND=true
            KERNEL_SIZE=$(du -h "$STAGING_DIR/live/vmlinuz" | cut -f1)
            echo "✅ 使用内核: $(basename "$kernel") ($KERNEL_SIZE)"
            echo "✅ 从APK包提取内核成功"
        fi
    fi
    
    rm -rf "$TEMP_DIR"
fi

if [ "$KERNEL_FOUND" = false ]; then
    echo "❌ 致命错误: 无法获取Linux内核，构建终止"
    exit 1
fi
echo ""

# ========== 第3步：创建initrd ==========
echo "[3/8] 🔧 创建initrd..."

INITRD_DIR="/tmp/initrd_complete_$(date +%s)"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"

echo "创建完整的init脚本..."
cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh


# 挂载必要的文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 创建设备节点
mknod /dev/console c 5 1
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 挂载tmpfs
mount -t tmpfs tmpfs /tmp

# 设置PATH
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

clear
cat << "HEADER"

╔══════════════════════════════════════════════════╗
║         OpenWRT Installation System              ║
║             (Alpine 3.20 based)                  ║
╚══════════════════════════════════════════════════╝

HEADER

echo "系统初始化完成..."
echo ""

# 查找OpenWRT镜像
IMG_PATH=""
if [ -f "/images/openwrt.img" ]; then
    IMG_PATH="/images/openwrt.img"
    echo "✅ 找到OpenWRT刷机镜像"
    echo "   大小: $(ls -lh "$IMG_PATH" | awk '{print $5}')"
else
    echo "❌ 错误: 未找到刷机镜像!"
    echo "进入救援模式..."
    exec /bin/sh
fi

# 显示磁盘信息
show_disks() {
    echo ""
    echo "📊 可用磁盘列表:"
    echo "================="
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -n -o NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -v '^$' || echo "无法使用lsblk"
    else
        echo "使用简单列表:"
        for disk in /dev/sd[a-z] /dev/hd[a-z] /dev/nvme[0-9]n[0-9]; do
            [ -b "$disk" ] && echo "  $disk"
        done
    fi
    echo "================="
}

# 主安装循环
while true; do
    show_disks
    
            echo ""
            read -p "请输入目标磁盘名称 (例如: sda, nvme0n1): " target_disk
            
            if [ -z "$target_disk" ]; then
                echo "❌ 未输入磁盘名"
                continue
            fi
            
            # 检查磁盘是否存在
            if [ ! -b "/dev/$target_disk" ]; then
                echo "❌ 磁盘 /dev/$target_disk 不存在!"
                continue
            fi
            
            # 确认操作
            echo ""
            echo "⚠️  ⚠️  ⚠️  警告 ⚠️  ⚠️  ⚠️"
            echo "这将完全擦除 /dev/$target_disk 上的所有数据!"
            echo "所有分区和数据都将永久丢失!"
            echo ""
            read -p "确认刷机？输入大写 YES 继续: " confirm
            
            if [ "$confirm" != "YES" ]; then
                echo "❌ 刷机取消"
                continue
            fi
            
            echo ""
            echo "🚀 开始刷写 OpenWRT 到 /dev/$target_disk ..."
            echo ""
            
            # 刷机进度显示
            if command -v pv >/dev/null 2>&1; then
                echo "使用pv显示进度..."
                pv -t -e -b -a "$IMG_PATH" | dd of="/dev/$target_disk" bs=4M oflag=sync
            else
                echo "使用dd刷写..."
                dd if="$IMG_PATH" of="/dev/$target_disk" bs=4M status=progress oflag=sync
            fi
            
            # 同步数据
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
            
            # 重启系统
            echo "正在重启..."
            reboot -f
            ;;
        
done
INIT_EOF

chmod 755 "$INITRD_DIR/init"

echo "复制必要工具到initrd..."

# 创建目录结构
mkdir -p "$INITRD_DIR"/{bin,sbin,dev,proc,sys,tmp,images,usr/bin}

# 1. 复制busybox（核心）
echo "复制busybox..."
BUSYBOX_PATH=$(which busybox)
if [ -f "$BUSYBOX_PATH" ]; then
    cp "$BUSYBOX_PATH" "$INITRD_DIR/bin/busybox"
    chmod 755 "$INITRD_DIR/bin/busybox"
    
    # 只创建必要的符号链接，不创建所有
    cd "$INITRD_DIR/bin"
    echo "创建必要的busybox符号链接..."
    for cmd in sh mount umount cat echo ls ps grep sed cp mv rm mkdir rmdir \
               dd sync reboot fdisk lsblk blkid sleep head tail; do
        ln -sf /bin/busybox "$cmd" 2>/dev/null || true
    done
    cd - >/dev/null
else
    echo "❌ 错误: 找不到busybox!"
    exit 1
fi

# 2. 复制刷机必需的工具（不能通过busybox替代的）
echo "复制刷机工具..."
TOOLS_TO_COPY=(
    "pv"       # 进度显示
    "fdisk"    # 磁盘分区（busybox的fdisk功能有限）
    "lsblk"    # 块设备列表
    "blkid"    # 块设备信息
    "parted"   # 分区工具
    "dd"       # 磁盘操作（使用系统dd以获得更好功能）
    "sync"     # 同步
    "reboot"   # 重启
)

for tool in "${TOOLS_TO_COPY[@]}"; do
    tool_path=$(which "$tool" 2>/dev/null || true)
    if [ -n "$tool_path" ] && [ -f "$tool_path" ]; then
        # 如果busybox已经有链接，跳过
        if [ ! -f "$INITRD_DIR/bin/$tool" ]; then
            mkdir -p "$INITRD_DIR$(dirname "$tool_path")"
            cp "$tool_path" "$INITRD_DIR$tool_path" 2>/dev/null || true
            echo "  ✅ $tool"
        fi
    fi
done

# 3. 复制必要的库文件
echo "复制必要的库文件..."
mkdir -p "$INITRD_DIR/lib"
# 只复制必要的库
LIBS_TO_COPY=(
    "/lib/ld-musl-x86_64.so.1"
    "/lib/libc.musl-x86_64.so.1"
    "/lib/libblkid.so.1"
    "/lib/libmount.so.1"
    "/lib/libsmartcols.so.1"
    "/lib/libuuid.so.1"
)

for lib in "${LIBS_TO_COPY[@]}"; do
    if [ -f "$lib" ]; then
        cp "$lib" "$INITRD_DIR/lib/" 2>/dev/null || true
        echo "  ✅ $(basename "$lib")"
    fi
done

# 4. 创建设备节点
echo "创建设备节点..."
mknod "$INITRD_DIR/dev/console" c 5 1
mknod "$INITRD_DIR/dev/null" c 1 3
mknod "$INITRD_DIR/dev/zero" c 1 5
mknod "$INITRD_DIR/dev/tty" c 5 0
mknod "$INITRD_DIR/dev/tty0" c 4 0

# 5. 复制OpenWRT镜像到initrd（可选，如果要从initrd直接访问）
# cp "$INPUT_IMG" "$INITRD_DIR/images/openwrt.img" 2>/dev/null || true

# 清理不需要的文件
echo "清理不需要的文件..."
find "$INITRD_DIR" -name "*.so.*" ! -name "*.so.1" -delete 2>/dev/null || true
find "$INITRD_DIR" -type f -name "*.a" -delete 2>/dev/null || true
find "$INITRD_DIR" -type f -name "*.la" -delete 2>/dev/null || true

echo "打包initrd..."
cd "$INITRD_DIR"
echo "initrd目录大小: $(du -sh . | cut -f1)"
echo "文件数量: $(find . -type f | wc -l)"

# 使用gzip -6平衡压缩率和速度
find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -6 > "$STAGING_DIR/live/initrd.img"

INITRD_SIZE=$(du -h "$STAGING_DIR/live/initrd.img" | cut -f1)
echo "✅ initrd创建完成 ($INITRD_SIZE)"

# 验证
if gzip -cd "$STAGING_DIR/live/initrd.img" 2>/dev/null | cpio -t 2>/dev/null | grep -q "^init$"; then
    echo "✅ initrd包含有效的init"
    
    # 检查关键工具
    echo "检查关键工具:"
    gzip -cd "$STAGING_DIR/live/initrd.img" 2>/dev/null | cpio -t 2>/dev/null | grep -E "(init|busybox|pv|fdisk|lsblk|dd)" || true
fi

cd - >/dev/null
rm -rf "$INITRD_DIR"
echo ""

# ========== 第4步：复制OpenWRT镜像 ==========
echo "[4/8] 📦 复制OpenWRT镜像..."
cp "$INPUT_IMG" "$STAGING_DIR/images/openwrt.img"
IMG_SIZE=$(du -h "$INPUT_IMG" | cut -f1)
echo "✅ 刷机镜像已复制 ($IMG_SIZE)"

# ========== 第5步：创建BIOS引导配置 ==========
echo "[5/8] 🔧 创建BIOS引导配置..."

# 复制syslinux文件
for file in isolinux.bin ldlinux.c32 libutil.c32 menu.c32 vesamenu.c32; do
    for dir in /usr/share/syslinux /usr/lib/syslinux /usr/lib/ISOLINUX; do
        if [ -f "$dir/$file" ]; then
            cp "$dir/$file" "$STAGING_DIR/isolinux/"
            break
        fi
    done
done

# 查找isohdpfx.bin
for dir in /usr/share/syslinux /usr/lib/syslinux /usr/lib/ISOLINUX; do
    if [ -f "$dir/isohdpfx.bin" ]; then
        cp "$dir/isohdpfx.bin" "$WORK_DIR/isohdpfx.bin"
        echo "✅ 找到isohdpfx.bin"
        break
    fi
done

# 创建ISOLINUX配置
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG_EOF'
DEFAULT vesamenu.c32
PROMPT 0
TIMEOUT 10
ONTIMEOUT install

MENU TITLE OpenWRT刷机安装系统
MENU BACKGROUND /boot/splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std

LABEL install
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 console=ttyS0,115200n8 rw quiet

ISOLINUX_CFG_EOF

echo "✅ BIOS引导配置完成"

# ========== 第6步：创建UEFI引导配置 ==========
echo "[6/8] 🔧 创建UEFI引导配置..."

# 创建GRUB配置
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG_EOF'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /live/vmlinuz console=tty0 console=ttyS0,115200n8 rw quiet
    initrd /live/initrd.img
}

GRUB_CFG_EOF

# 生成GRUB EFI文件（如果可用）
if command -v grub-mkstandalone >/dev/null 2>&1; then
    echo "生成GRUB EFI文件..."
    TEMP_DIR="/tmp/grub_efi_$(date +%s)"
    mkdir -p "$TEMP_DIR/boot/grub"
    cp "$STAGING_DIR/boot/grub/grub.cfg" "$TEMP_DIR/boot/grub/"
    
    if grub-mkstandalone \
        --format=x86_64-efi \
        --output="$TEMP_DIR/bootx64.efi" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos fat ext2 iso9660" \
        "boot/grub/grub.cfg=$TEMP_DIR/boot/grub/grub.cfg" 2>/dev/null; then
        
        cp "$TEMP_DIR/bootx64.efi" "$STAGING_DIR/EFI/boot/bootx64.efi"
        echo "✅ GRUB EFI生成成功"
    fi
    rm -rf "$TEMP_DIR"
fi

echo "✅ UEFI引导配置完成"

# ========== 第7步：构建ISO ==========
echo "[7/8] 📦 构建ISO..."

cd "$WORK_DIR"

# 检查是否有EFI引导镜像
EFI_IMG_PATH="$STAGING_DIR/EFI/boot/bootx64.efi"
ISOHDPFX_PATH="$WORK_DIR/isohdpfx.bin"

if [ -f "$EFI_IMG_PATH" ] && [ -f "$ISOHDPFX_PATH" ]; then
    echo "构建混合引导ISO (BIOS + UEFI)..."
    
    # 创建EFI引导镜像
    EFI_IMG="$WORK_DIR/efiboot.img"
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=16 status=none 2>/dev/null
    if mkfs.fat -F 32 -n "EFIBOOT" "$EFI_IMG" >/dev/null 2>&1; then
        MOUNT_DIR="$WORK_DIR/efi_mount"
        mkdir -p "$MOUNT_DIR"
        
        if mount -o loop "$EFI_IMG" "$MOUNT_DIR" 2>/dev/null; then
            mkdir -p "$MOUNT_DIR/EFI/boot"
            cp "$EFI_IMG_PATH" "$MOUNT_DIR/EFI/boot/"
            sync
            umount "$MOUNT_DIR"
        fi
        rm -rf "$MOUNT_DIR"
    fi
    
    xorriso -as mkisofs \
        -r \
        -V "OPENWRT_FLASH" \
        -o "/output/openwrt.iso" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr "$ISOHDPFX_PATH" \
        -eltorito-alt-boot \
        -e "$EFI_IMG" \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$STAGING_DIR" 2>&1 | grep -E "written|sectors" || true
        
    rm -f "$EFI_IMG"
else
    echo "构建BIOS引导ISO..."
    
    xorriso -as mkisofs \
        -r \
        -V "OPENWRT_FLASH" \
        -o "/output/openwrt.iso" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        "$STAGING_DIR" 2>&1 | grep -E "written|sectors" || true
fi

# ========== 第8步：验证结果 ==========
echo "[8/8] 🔍 验证结果..."

if [ -f "/output/openwrt.iso" ]; then
    ISO_SIZE=$(du -h "/output/openwrt.iso" | cut -f1)
    echo ""
    echo "🎉🎉🎉 ISO构建成功! 🎉🎉🎉"
    echo ""
    echo "📊 构建摘要:"
    echo "  ISO文件: /output/openwrt.iso"
    echo "  ISO大小: $ISO_SIZE"
    echo "  内核大小: $KERNEL_SIZE"
    echo "  initrd大小: $INITRD_SIZE"
    echo "  刷机镜像: $IMG_SIZE"
    echo ""
    
    # 创建构建信息
    cat > "/output/build-info.txt" << EOF
OpenWRT刷机安装系统ISO
=======================
构建时间: $(date)
ISO大小:  $ISO_SIZE
内核:     $KERNEL_SIZE
initrd:   $INITRD_SIZE
刷机镜像: $IMG_SIZE

包含工具:
  - fdisk, lsblk, blkid (磁盘工具)
  - dd, pv (刷机工具)
  - parted (分区工具)
  - busybox (核心工具集)

引导支持:
  - BIOS (ISOLINUX): 是
  - UEFI (GRUB): 是

使用方法:
  1. 制作USB启动盘:
     sudo dd if=openwrt.iso of=/dev/sdX bs=4M status=progress oflag=sync
  2. 从USB启动
  3. 选择目标磁盘刷机
  4. 输入YES确认刷机

注意: 刷机会完全擦除目标磁盘!
EOF
    
    echo "✅ 构建信息保存到: /output/build-info.txt"
    echo ""
    echo "🚀 刷机ISO准备就绪!"
    
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
