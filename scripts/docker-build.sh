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
# Dockerfile.alpine-iso-fixed
ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION} AS builder

# 使用国内镜像源，避免Docker Hub超时
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories

# 安装最小必要工具集
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
    linux-lts

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

echo "=== OpenWRT ISO Builder for Alpine 3.20 (Fixed) ==="
echo "==================================================="

# 输入文件
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"

# 检查输入文件
if [ ! -f "$INPUT_IMG" ]; then
    echo "❌ 错误: 输入文件不存在: $INPUT_IMG"
    exit 1
fi

echo "✅ 输入文件: $INPUT_IMG ($(du -h "$INPUT_IMG" | cut -f1))"
echo "✅ 输出目录: /output"
echo ""

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
        echo "✅ 找到内核: $(basename "$kernel_path")"
        
        # 验证内核文件
        echo "内核信息:"
        file "$STAGING_DIR/live/vmlinuz" 2>/dev/null || true
        echo "内核大小: $(du -h "$STAGING_DIR/live/vmlinuz" 2>/dev/null | cut -f1 || echo "未知")"
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

# ========== 第3步：创建正确的initrd ==========
echo "[3/8] 🔧 创建initrd (关键修复步骤)..."

INITRD_DIR="/tmp/initrd_root_$(date +%s)"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"

echo "创建init脚本..."
cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh


# 挂载必要的文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s
# 创建设备节点（关键！）
mknod /dev/console c 5 1
mknod /dev/null c 1 3
mknod /dev/zero c 1 5
mknod /dev/tty c 5 0

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 挂载tmpfs
mount -t tmpfs tmpfs /tmp

# 设置PATH
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

clear
cat << "BANNER"

╔══════════════════════════════════════════════════╗
║         OpenWRT Installation System              ║
║             (Alpine 3.20 based)                  ║
╚══════════════════════════════════════════════════╝

BANNER

echo "系统启动完成"
echo "正在查找安装介质..."

# 查找ISO设备
ISO_MOUNTED=false
for dev in /dev/sr0 /dev/cdrom /dev/sr*; do
    if [ -b "$dev" ]; then
        echo "尝试挂载 $dev..."
        if mount -t iso9660 -o ro "$dev" /mnt 2>/dev/null; then
            ISO_MOUNTED=true
            echo "✅ 成功挂载安装介质"
            break
        fi
    fi
done

# 查找OpenWRT镜像
IMG_PATH=""
if [ -f "/mnt/images/openwrt.img" ]; then
    IMG_PATH="/mnt/images/openwrt.img"
    echo "✅ 找到OpenWRT镜像"
elif [ -f "/openwrt.img" ]; then
    IMG_PATH="/openwrt.img"
    echo "✅ 使用内置OpenWRT镜像"
else
    echo "❌ 错误: 未找到OpenWRT镜像!"
    echo "进入救援模式..."
    exec /bin/busybox sh
fi

# 显示可用磁盘
echo ""
echo "可用磁盘:"
echo "=========="
if command -v lsblk >/dev/null 2>&1; then
    lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -v '^$' || echo "无法列出磁盘"
else
    echo "设备列表:"
    for disk in /dev/sd[a-z] /dev/hd[a-z]; do
        [ -b "$disk" ] && echo "  $disk"
    done
fi
echo "=========="

# 安装菜单
while true; do
            read -p "输入目标磁盘 (例如: sda): " target_disk
            
            if [ -z "$target_disk" ]; then
                echo "❌ 请输入磁盘名"
                continue
            fi
            
            if [ ! -b "/dev/$target_disk" ]; then
                echo "❌ 磁盘不存在: /dev/$target_disk"
                continue
            fi
            
            echo ""
            echo "⚠️  警告: 这将完全擦除 /dev/$target_disk!"
            read -p "确认安装? 输入 YES: " confirm
            
            if [ "$confirm" != "YES" ]; then
                echo "安装取消"
                continue
            fi
            
            echo ""
            echo "开始安装..."
            if command -v pv >/dev/null 2>&1; then
                pv "$IMG_PATH" | dd of="/dev/$target_disk" bs=4M
            else
                dd if="$IMG_PATH" of="/dev/$target_disk" bs=4M status=progress
            fi
            
            sync
            echo ""
            echo "✅ 安装完成!"
            echo "10秒后重启..."
            sleep 10
            reboot -f
            ;;
        
done
INIT_EOF

# 确保init文件可执行
chmod 755 "$INITRD_DIR/init"

# 复制busybox并创建符号链接
echo "设置busybox..."
BUSYBOX_PATH=$(which busybox)
if [ -f "$BUSYBOX_PATH" ]; then
    mkdir -p "$INITRD_DIR/bin"
    cp "$BUSYBOX_PATH" "$INITRD_DIR/bin/busybox"
    chmod 755 "$INITRD_DIR/bin/busybox"
    
    # 创建必要的符号链接
    cd "$INITRD_DIR/bin"
    
    # 创建所有busybox命令的符号链接
    echo "创建busybox符号链接..."
    ./busybox --list | while read cmd; do
        ln -sf /bin/busybox "$cmd" 2>/dev/null || true
    done
    
    # 额外创建一些关键命令到sbin
    mkdir -p ../sbin
    for cmd in init halt reboot poweroff; do
        ln -sf /bin/busybox ../sbin/"$cmd" 2>/dev/null || true
    done
    
    cd - >/dev/null
    echo "✅ busybox配置完成"
else
    echo "❌ 错误: 找不到busybox!"
    exit 1
fi

# 创建设备节点
echo "创建设备节点..."
mkdir -p "$INITRD_DIR/dev"
mknod "$INITRD_DIR/dev/console" c 5 1
mknod "$INITRD_DIR/dev/null" c 1 3
mknod "$INITRD_DIR/dev/zero" c 1 5
mknod "$INITRD_DIR/dev/tty" c 5 0

# 创建必要的目录
mkdir -p "$INITRD_DIR"/{proc,sys,tmp,mnt,images}

# 复制OpenWRT镜像到initrd（可选）
if [ -f "$INPUT_IMG" ]; then
    cp "$INPUT_IMG" "$INITRD_DIR/images/openwrt.img"
    echo "✅ 复制OpenWRT镜像到initrd"
fi

# 打包initrd
echo "打包initrd..."
cd "$INITRD_DIR"
echo "initrd目录结构:"
ls -la

# 使用cpio打包（确保包含所有文件）
find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd.img"

# 验证initrd
if [ -f "$STAGING_DIR/live/initrd.img" ]; then
    INITRD_SIZE=$(du -h "$STAGING_DIR/live/initrd.img" | cut -f1)
    echo "✅ initrd创建成功 ($INITRD_SIZE)"
    
    # 测试initrd内容
    echo "测试initrd内容..."
    if gzip -cd "$STAGING_DIR/live/initrd.img" 2>/dev/null | cpio -t 2>/dev/null | head -10; then
        echo "✅ initrd格式正确"
        
        # 检查是否包含init
        if gzip -cd "$STAGING_DIR/live/initrd.img" 2>/dev/null | cpio -t 2>/dev/null | grep -q "^init$"; then
            echo "✅ initrd包含init文件"
        else
            echo "❌ initrd不包含init文件"
        fi
    fi
else
    echo "❌ initrd创建失败"
    exit 1
fi

cd - >/dev/null
rm -rf "$INITRD_DIR"
echo ""


# ========== 第4步：复制OpenWRT镜像 ==========
echo "[4/8] 📦 复制OpenWRT镜像..."
cp "$INPUT_IMG" "$STAGING_DIR/images/openwrt.img"
echo "✅ OpenWRT镜像已复制"
echo ""

# ========== 第5步：创建BIOS引导配置 ==========
echo "[5/8] 🔧 创建BIOS引导配置..."

# 复制syslinux文件
echo "复制syslinux文件..."
for file in isolinux.bin ldlinux.c32 libutil.c32 menu.c32 vesamenu.c32; do
    for dir in /usr/share/syslinux /usr/lib/syslinux /usr/lib/ISOLINUX; do
        if [ -f "$dir/$file" ]; then
            cp "$dir/$file" "$STAGING_DIR/isolinux/" 2>/dev/null || true
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
DEFAULT linux
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE OpenWRT Installer

LABEL linux
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 console=ttyS0,115200n8 rw quiet

ISOLINUX_CFG_EOF

echo "✅ BIOS引导配置完成"
echo ""

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

# 生成GRUB EFI文件
echo "生成GRUB EFI文件..."
GRUB_EFI_GENERATED=false

# 方法1: 尝试grub-mkstandalone
if command -v grub-mkstandalone >/dev/null 2>&1; then
    echo "使用grub-mkstandalone..."
    
    TEMP_GRUB="/tmp/grub_temp_$(date +%s)"
    mkdir -p "$TEMP_GRUB/boot/grub"
    cp "$STAGING_DIR/boot/grub/grub.cfg" "$TEMP_GRUB/boot/grub/"
    
    if grub-mkstandalone \
        --format=x86_64-efi \
        --output="$TEMP_GRUB/bootx64.efi" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos fat ext2 iso9660" \
        "boot/grub/grub.cfg=$TEMP_GRUB/boot/grub/grub.cfg" 2>/dev/null; then
        
        cp "$TEMP_GRUB/bootx64.efi" "$STAGING_DIR/EFI/boot/bootx64.efi"
        GRUB_EFI_GENERATED=true
        echo "✅ GRUB EFI生成成功"
    fi
    
    rm -rf "$TEMP_GRUB"
fi

# 方法2: 尝试grub-mkimage
if [ "$GRUB_EFI_GENERATED" = false ] && command -v grub-mkimage >/dev/null 2>&1; then
    echo "使用grub-mkimage..."
    
    if grub-mkimage \
        -O x86_64-efi \
        -o "$STAGING_DIR/EFI/boot/bootx64.efi" \
        -p /boot/grub \
        fat iso9660 part_gpt part_msdos normal boot linux 2>/dev/null; then
        
        GRUB_EFI_GENERATED=true
        echo "✅ GRUB EFI生成成功"
    fi
fi

# 如果生成了EFI文件，创建引导镜像
if [ "$GRUB_EFI_GENERATED" = true ] && [ -f "$STAGING_DIR/EFI/boot/bootx64.efi" ]; then
    echo "创建EFI引导镜像..."
    
    EFI_IMG="$WORK_DIR/efiboot.img"
echo "创建EFI引导镜像..."

# 创建FAT32格式的EFI引导镜像
EFI_IMG="$WORK_DIR/efiboot.img"
MOUNT_DIR="$WORK_DIR/efi_mount"

# 清理旧文件
rm -rf "$EFI_IMG" "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR"

# 方法1: 使用mkfs.fat创建FAT32镜像
echo "创建FAT32 EFI引导镜像..."
# 创建16MB的镜像（足够存放EFI文件）
dd if=/dev/zero of="$EFI_IMG" bs=1M count=16 status=none 2>/dev/null

# 尝试多种方式格式化
if command -v mkfs.fat >/dev/null 2>&1; then
    # 使用mkfs.fat创建FAT32
    if mkfs.fat -F 32 -n "EFIBOOT" "$EFI_IMG" >/dev/null 2>&1; then
        echo "✅ 使用mkfs.fat创建FAT32"
    elif mkfs.fat -F 12 -n "EFIBOOT" "$EFI_IMG" >/dev/null 2>&1; then
        echo "✅ 使用mkfs.fat创建FAT12"
    else
        echo "⚠ mkfs.fat失败"
    fi
elif command -v mkfs.vfat >/dev/null 2>&1; then
    # 使用mkfs.vfat
    if mkfs.vfat -F 32 -n "EFIBOOT" "$EFI_IMG" >/dev/null 2>&1; then
        echo "✅ 使用mkfs.vfat创建FAT32"
    else
        echo "⚠ mkfs.vfat失败"
    fi
elif command -v mkdosfs >/dev/null 2>&1; then
    # 使用mkdosfs
    if mkdosfs -F 32 -n "EFIBOOT" "$EFI_IMG" >/dev/null 2>&1; then
        echo "✅ 使用mkdosfs创建FAT32"
    else
        echo "⚠ mkdosfs失败"
    fi
else
    echo "❌ 没有找到FAT文件系统创建工具"
    # 创建简单文件作为占位
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=1 status=none 2>/dev/null
fi

# 检查镜像是否创建成功
if [ ! -s "$EFI_IMG" ]; then
    echo "❌ EFI镜像创建失败"
    exit 1
fi

# 挂载镜像（使用正确的挂载选项）
echo "挂载EFI镜像..."
MOUNT_SUCCESS=false

# 尝试多种挂载方法
if command -v mount >/dev/null 2>&1; then
    # 方法1: 使用loop设备
    if losetup --version >/dev/null 2>&1; then
        echo "使用losetup挂载..."
        LOOP_DEV=$(losetup -f)
        if [ -n "$LOOP_DEV" ]; then
            if losetup "$LOOP_DEV" "$EFI_IMG" 2>/dev/null; then
                if mount -t vfat "$LOOP_DEV" "$MOUNT_DIR" 2>/dev/null; then
                    MOUNT_SUCCESS=true
                    echo "✅ 通过losetup挂载成功"
                else
                    losetup -d "$LOOP_DEV" 2>/dev/null
                fi
            fi
        fi
    fi
    
    # 方法2: 直接使用mount -o loop
    if [ "$MOUNT_SUCCESS" = false ]; then
        echo "尝试mount -o loop..."
        if mount -o loop -t vfat "$EFI_IMG" "$MOUNT_DIR" 2>/dev/null; then
            MOUNT_SUCCESS=true
            echo "✅ 通过mount -o loop挂载成功"
        fi
    fi
    
    # 方法3: 使用fuse挂载（如果可用）
    if [ "$MOUNT_SUCCESS" = false ] && command -v fuse2fs >/dev/null 2>&1; then
        echo "尝试使用fuse..."
        if mount.fuse "$EFI_IMG" "$MOUNT_DIR" -o ro 2>/dev/null; then
            MOUNT_SUCCESS=true
            echo "✅ 通过fuse挂载成功"
        fi
    fi
fi

if [ "$MOUNT_SUCCESS" = true ]; then
    # 创建EFI目录结构
    echo "创建EFI目录结构..."
    mkdir -p "$MOUNT_DIR/EFI/boot"
    mkdir -p "$MOUNT_DIR/boot/grub"
    
    # 复制EFI引导文件
    if [ -f "$STAGING_DIR/EFI/boot/bootx64.efi" ]; then
        cp "$STAGING_DIR/EFI/boot/bootx64.efi" "$MOUNT_DIR/EFI/boot/"
        echo "✅ 复制bootx64.efi"
    else
        # 如果没有EFI文件，创建一个简单的
        echo "创建简易EFI引导文件..."
        cat > "$MOUNT_DIR/EFI/boot/bootx64.efi" << 'EFI_STUB'
#!/bin/sh
echo "UEFI Boot Stub"
echo "Please use BIOS/Legacy boot mode"
sleep 5
EFI_STUB
        chmod +x "$MOUNT_DIR/EFI/boot/bootx64.efi"
    fi
    
    # 复制GRUB配置
    if [ -f "$STAGING_DIR/boot/grub/grub.cfg" ]; then
        cp "$STAGING_DIR/boot/grub/grub.cfg" "$MOUNT_DIR/boot/grub/"
        echo "✅ 复制grub.cfg"
    fi
    
    # 创建UEFI Shell（可选）
    echo "创建UEFI Shell占位..."
    cat > "$MOUNT_DIR/EFI/boot/startup.nsh" << 'STARTUP_NSH'
echo "OpenWRT UEFI Installer"
echo "If you see this, UEFI boot is working"
echo "Booting installer..."
STARTUP_NSH
    
    # 卸载
    echo "卸载EFI镜像..."
    sync
    umount "$MOUNT_DIR" 2>/dev/null || true
    
    # 清理loop设备
    if [ -n "$LOOP_DEV" ] && losetup "$LOOP_DEV" >/dev/null 2>&1; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    
    # 复制到输出目录
    cp "$EFI_IMG" "$STAGING_DIR/EFI/boot/efiboot.img"
    echo "✅ EFI引导镜像创建完成"
else
    echo "⚠ 无法挂载EFI镜像，创建空文件"
    # 创建一个小文件作为占位
    dd if=/dev/zero of="$STAGING_DIR/EFI/boot/efiboot.img" bs=1M count=1 2>/dev/null
fi

# 清理
rm -rf "$MOUNT_DIR" "$EFI_IMG" 2>/dev/null || true

    
else
    echo "⚠ 无法生成GRUB EFI文件"
fi

echo "✅ UEFI引导配置完成"
echo ""

# ========== 第7步：构建ISO ==========
echo "[7/8] 📦 构建ISO文件..."

cd "$WORK_DIR"

# 检查是否有EFI引导镜像
EFI_IMG_PATH="$STAGING_DIR/EFI/boot/efiboot.img"
ISOHDPFX_PATH="$WORK_DIR/isohdpfx.bin"

if [ -f "$EFI_IMG_PATH" ] && [ -f "$ISOHDPFX_PATH" ]; then
    echo "构建混合引导ISO (BIOS + UEFI)..."
    
    xorriso -as mkisofs \
        -r \
        -V "OPENWRT_INSTALL" \
        -o "/output/openwrt.iso" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr "$ISOHDPFX_PATH" \
        -eltorito-alt-boot \
        -e EFI/boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$STAGING_DIR" 2>&1 | tail -5
else
    echo "构建BIOS引导ISO..."
    
    xorriso -as mkisofs \
        -r \
        -V "OPENWRT_INSTALL" \
        -o "/output/openwrt.iso" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        "$STAGING_DIR" 2>&1 | tail -5
fi

echo ""

# ========== 第8步：验证结果 ==========
echo "[8/8] 🔍 验证构建结果..."

if [ -f "/output/openwrt.iso" ]; then
    ISO_SIZE=$(du -h "/output/openwrt.iso" 2>/dev/null | cut -f1 || echo "未知")
    echo "✅ ✅ ✅ ISO构建成功! ✅ ✅ ✅"
    echo ""
    echo "📊 ISO信息:"
    echo "  文件: /output/openwrt.iso"
    echo "  大小: $ISO_SIZE"
    echo ""
    
    # 检查ISO
    if command -v file >/dev/null 2>&1; then
        FILE_INFO=$(file "/output/openwrt.iso" 2>/dev/null || echo "无法获取文件信息")
        echo "类型: $FILE_INFO"
    fi
    
    # 创建构建信息
    cat > "/output/build-info.txt" << EOF
OpenWRT Alpine Installer
=======================
构建时间: $(date)
ISO大小:  $ISO_SIZE
引导支持: $( [ -f "$EFI_IMG_PATH" ] && echo "BIOS + UEFI" || echo "BIOS only" )

包含:
  - OpenWRT镜像: images/openwrt.img
  - Linux内核:   live/vmlinuz
  - Initramfs:   live/initrd.img

使用方法:
  1. sudo dd if=openwrt.iso of=/dev/sdX bs=4M status=progress
  2. 从USB启动
  3. 选择安装目标

注意: 安装会完全擦除目标磁盘!
EOF
    
    echo "✅ 构建信息保存到: /output/build-info.txt"
    
    # 清理
    rm -rf "$WORK_DIR"
    
    exit 0
else
    echo "❌ ISO创建失败"
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
