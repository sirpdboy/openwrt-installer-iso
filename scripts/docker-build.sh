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
FROM alpine:${ALPINE_VERSION} as builder

# 设置Alpine 3.20的官方源
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories

# 更新并安装必要的包（Alpine 3.20可用的包）
RUN apk update && \
    apk add --no-cache \
    bash \
    xorriso \
    syslinux \
    mtools \
    dosfstools \
    grub \
    grub-efi \
    e2fsprogs \
    e2fsprogs-extra \
    parted \
    util-linux \
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
    squashfs-tools \
    cdrtools \
    linux-lts \
    musl-dev \
    gcc \
    make \
    binutils \
    && rm -rf /var/cache/apk/*

# 验证关键工具
RUN echo "验证安装:" && \
    which xorriso && \
    which grub-mkimage && \
    which mkfs.fat && \
    which mkisofs || which xorriso

# 创建必要的设备节点（用于构建过程）
RUN mknod -m 0644 /dev/loop0 b 7 0 2>/dev/null || true && \
    mknod -m 0644 /dev/loop1 b 7 1 2>/dev/null || true

WORKDIR /work

# 复制构建脚本
COPY scripts/build-alpine-iso.sh /build-alpine-iso.sh
RUN chmod +x /build-alpine-iso.sh

ENTRYPOINT ["/build-alpine-iso.sh"]


DOCKERFILE_EOF

# 更新版本号
sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/g" "$DOCKERFILE_PATH"

# 创建完整的Alpine构建脚本
mkdir -p scripts
cat > scripts/build-iso-alpine.sh << 'BUILD_SCRIPT_EOF'
#!/bin/bash
set -e

echo "=== OpenWRT ISO Builder for Alpine 3.20 ==="
echo "==========================================="

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

# 查找可用的内核
KERNEL_FOUND=false
echo "搜索内核文件..."
find /boot -name "vmlinuz*" 2>/dev/null | head -5

for kernel_path in /boot/vmlinuz-lts /boot/vmlinuz; do
    if [ -f "$kernel_path" ]; then
        cp "$kernel_path" "$STAGING_DIR/live/vmlinuz"
        KERNEL_FOUND=true
        echo "✅ 找到内核: $(basename "$kernel_path")"
        
        # 验证内核文件
        echo "内核信息:"
        file "$STAGING_DIR/live/vmlinuz" || true
        echo "内核大小: $(du -h "$STAGING_DIR/live/vmlinuz" | cut -f1)"
        break
    fi
done

# 如果没找到，尝试安装linux-lts
if [ "$KERNEL_FOUND" = false ]; then
    echo "安装linux-lts内核..."
    if apk add --no-cache linux-lts 2>/dev/null; then
        for kernel_path in /boot/vmlinuz-lts /boot/vmlinuz; do
            if [ -f "$kernel_path" ]; then
                cp "$kernel_path" "$STAGING_DIR/live/vmlinuz"
                KERNEL_FOUND=true
                echo "✅ 安装并使用内核: $(basename "$kernel_path")"
                break
            fi
        done
    fi
fi

if [ "$KERNEL_FOUND" = false ]; then
    echo "❌ 错误: 无法找到Linux内核!"
    echo "尝试从Alpine包获取..."
    
    # 从Alpine包直接下载内核
    ARCHIVE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/linux-lts-6.6.35-r0.apk"
    if curl -L -o /tmp/linux.apk "$ARCHIVE_URL" 2>/dev/null; then
        tar -Oxzf /tmp/linux.apk boot/vmlinuz-lts > "$STAGING_DIR/live/vmlinuz" 2>/dev/null
        if [ -s "$STAGING_DIR/live/vmlinuz" ]; then
            KERNEL_FOUND=true
            echo "✅ 从APK包提取内核成功"
        fi
        rm -f /tmp/linux.apk
    fi
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
# OpenWRT安装系统init脚本
# 重要：必须使用busybox sh，不能是/bin/sh

# 挂载必要的文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 设置控制台
echo "初始化控制台..."
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

echo "系统初始化完成"
echo ""

# 查找ISO设备
echo "寻找安装介质..."
ISO_MOUNTED=false
for dev in /dev/sr0 /dev/cdrom /dev/sr*; do
    if [ -b "$dev" ]; then
        echo "尝试挂载 $dev..."
        if mount -t iso9660 -o ro "$dev" /mnt 2>/dev/null; then
            ISO_MOUNTED=true
            echo "✅ 成功挂载 $dev 到 /mnt"
            break
        fi
    fi
done

# 查找OpenWRT镜像
IMG_PATH=""
if [ -f "/mnt/images/openwrt.img" ]; then
    IMG_PATH="/mnt/images/openwrt.img"
    echo "✅ 找到OpenWRT镜像: $IMG_PATH"
elif [ -f "/openwrt.img" ]; then
    IMG_PATH="/openwrt.img"
    echo "✅ 使用内置OpenWRT镜像"
else
    echo "❌ 错误: 未找到OpenWRT镜像!"
    echo ""
    echo "挂载点内容 (/mnt):"
    ls -la /mnt/ 2>/dev/null || echo "/mnt目录为空或不可访问"
    echo ""
    echo "等待用户操作，按Enter进入shell..."
    read dummy
    exec /bin/sh
fi

# 显示镜像信息
if [ -f "$IMG_PATH" ]; then
    echo "镜像大小: $(busybox du -h "$IMG_PATH" 2>/dev/null | cut -f1 || echo "未知")"
    echo ""
fi

# 显示可用磁盘
echo "可用磁盘列表:"
echo "=============="
if command -v lsblk >/dev/null 2>&1; then
    lsblk -d -n -o NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -v '^$' || echo "无法使用lsblk"
else
    echo "使用简单列表:"
    for disk in /dev/sd[a-z] /dev/hd[a-z] /dev/nvme[0-9]n[0-9]; do
        [ -b "$disk" ] && echo "  $disk"
    done
fi
echo "=============="

# 主安装循环
while true; do
    echo ""
    echo "安装菜单:"
    echo "  1) 显示详细磁盘信息"
    echo "  2) 安装OpenWRT到磁盘"
    echo "  3) 进入Shell (调试)"
    echo "  4) 重启系统"
    echo ""
    read -p "请选择 [1-4]: " choice
    
    case "$choice" in
        1)
            echo ""
            echo "详细磁盘信息:"
            if command -v fdisk >/dev/null 2>&1; then
                fdisk -l 2>/dev/null || echo "fdisk不可用"
            else
                echo "使用busybox fdisk:"
                busybox fdisk -l 2>/dev/null || echo "无法显示磁盘信息"
            fi
            ;;
        2)
            echo ""
            read -p "请输入目标磁盘名称 (例如: sda, nvme0n1): " target_disk
            
            if [ -z "$target_disk" ]; then
                echo "❌ 未输入磁盘名"
                continue
            fi
            
            # 检查磁盘是否存在
            if [ ! -b "/dev/$target_disk" ]; then
                echo "❌ 磁盘 /dev/$target_disk 不存在!"
                echo "可用磁盘:"
                ls /dev/sd* /dev/hd* /dev/nvme* 2>/dev/null | grep -v '[0-9]$' || true
                continue
            fi
            
            # 确认操作
            echo ""
            echo "⚠️  ⚠️  ⚠️  警告: ⚠️  ⚠️  ⚠️"
            echo "这将完全擦除 /dev/$target_disk 上的所有数据!"
            echo "所有分区和数据都将丢失!"
            echo ""
            read -p "确认安装？输入大写 YES 继续: " confirm
            
            if [ "$confirm" != "YES" ]; then
                echo "❌ 安装取消"
                continue
            fi
            
            echo ""
            echo "开始安装 OpenWRT 到 /dev/$target_disk ..."
            echo ""
            
            # 安装进度显示
            if command -v pv >/dev/null 2>&1; then
                echo "使用pv显示进度:"
                pv -t -e -b -a "$IMG_PATH" | dd of="/dev/$target_disk" bs=4M oflag=sync
            else
                echo "使用dd写入镜像..."
                dd if="$IMG_PATH" of="/dev/$target_disk" bs=4M status=progress oflag=sync
            fi
            
            # 同步数据
            sync
            
            echo ""
            echo "✅ ✅ ✅ 安装完成! ✅ ✅ ✅"
            echo ""
            echo "OpenWRT已成功安装到 /dev/$target_disk"
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
        3)
            echo ""
            echo "进入shell..."
            echo "输入 'exit' 返回安装菜单"
            echo ""
            exec /bin/sh
            ;;
        4)
            echo ""
            echo "重启系统..."
            reboot -f
            ;;
        *)
            echo ""
            echo "❌ 无效选择，请重试"
            ;;
    esac
done
INIT_EOF

# 确保init文件可执行
chmod 755 "$INITRD_DIR/init"

echo "复制busybox到initrd..."
# 获取busybox
BUSYBOX_PATH=$(which busybox 2>/dev/null || echo "/bin/busybox")
if [ -f "$BUSYBOX_PATH" ]; then
    cp "$BUSYBOX_PATH" "$INITRD_DIR/bin/busybox"
    chmod 755 "$INITRD_DIR/bin/busybox"
    
    # 创建必要的符号链接
    cd "$INITRD_DIR"
    echo "创建busybox符号链接..."
    ./bin/busybox --list | while read app; do
        # 跳过已存在的
        if [ ! -e "bin/$app" ]; then
            ln -s /bin/busybox "bin/$app" 2>/dev/null || true
        fi
        
        # 为关键命令创建sbin链接
        case "$app" in
            init|halt|reboot|poweroff|ifconfig|route|arp|ip|modprobe|insmod|rmmod|lsmod|depmod)
                mkdir -p sbin
                ln -sf /bin/busybox "sbin/$app" 2>/dev/null || true
                ;;
        esac
    done
    cd - >/dev/null
    
    echo "✅ busybox配置完成"
else
    echo "❌ 错误: 找不到busybox!"
    exit 1
fi

echo "复制其他必要工具..."
# 复制必要的工具
TOOLS="fdisk lsblk blkid dd sync reboot mount umount cat echo grep sed cp mv rm mkdir rmdir ls ps kill sleep"
for tool in $TOOLS; do
    tool_path=$(which "$tool" 2>/dev/null || true)
    if [ -n "$tool_path" ] && [ -f "$tool_path" ]; then
        # 如果工具已经通过busybox链接存在，跳过
        if [ ! -f "$INITRD_DIR/bin/$tool" ]; then
            mkdir -p "$INITRD_DIR$(dirname "$tool_path")"
            cp "$tool_path" "$INITRD_DIR$tool_path" 2>/dev/null || true
        fi
    fi
done

echo "创建设备节点..."
# 创建设备节点（关键！）
mkdir -p "$INITRD_DIR/dev"
mknod "$INITRD_DIR/dev/console" c 5 1
mknod "$INITRD_DIR/dev/null" c 1 3
mknod "$INITRD_DIR/dev/zero" c 1 5
mknod "$INITRD_DIR/dev/tty" c 5 0
mknod "$INITRD_DIR/dev/tty0" c 4 0

# 创建必要的目录
mkdir -p "$INITRD_DIR"/{proc,sys,tmp,mnt,run}

echo "打包initrd..."
cd "$INITRD_DIR"
echo "initrd目录结构:"
find . -type f | head -20

# 使用cpio打包
find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd.img"

# 验证initrd
if [ -f "$STAGING_DIR/live/initrd.img" ]; then
    INITRD_SIZE=$(du -h "$STAGING_DIR/live/initrd.img" | cut -f1)
    echo "✅ initrd创建成功 ($INITRD_SIZE)"
    
    # 测试initrd是否可以读取
    echo "测试initrd内容..."
    if gzip -cd "$STAGING_DIR/live/initrd.img" 2>/dev/null | cpio -t 2>/dev/null | grep -q "^init$"; then
        echo "✅ initrd包含有效的init文件"
    else
        echo "⚠ initrd可能有问题"
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
cp "$INPUT_IMG" "$STAGING_DIR/openwrt.img"  # 兼容性

IMG_SIZE=$(du -h "$INPUT_IMG" | cut -f1)
echo "✅ OpenWRT镜像已复制 ($IMG_SIZE)"
echo ""

# ========== 第5步：创建BIOS引导配置 ==========
echo "[5/8] 🔧 创建BIOS引导配置..."

# 复制syslinux文件
echo "复制syslinux引导文件..."
SYSBOOT_DIR=""
for dir in /usr/share/syslinux /usr/lib/syslinux /usr/lib/ISOLINUX; do
    if [ -d "$dir" ]; then
        SYSBOOT_DIR="$dir"
        echo "使用syslinux目录: $SYSBOOT_DIR"
        break
    fi
done

if [ -n "$SYSBOOT_DIR" ]; then
    cp "$SYSBOOT_DIR/isolinux.bin" "$STAGING_DIR/isolinux/" 2>/dev/null || true
    cp "$SYSBOOT_DIR/ldlinux.c32" "$STAGING_DIR/isolinux/" 2>/dev/null || true
    cp "$SYSBOOT_DIR/libutil.c32" "$STAGING_DIR/isolinux/" 2>/dev/null || true
    cp "$SYSBOOT_DIR/menu.c32" "$STAGING_DIR/isolinux/" 2>/dev/null || true
    cp "$SYSBOOT_DIR/vesamenu.c32" "$STAGING_DIR/isolinux/" 2>/dev/null || true
    
    # 查找isohdpfx.bin
    if [ -f "$SYSBOOT_DIR/isohdpfx.bin" ]; then
        cp "$SYSBOOT_DIR/isohdpfx.bin" "$WORK_DIR/isohdpfx.bin"
        echo "✅ 找到isohdpfx.bin"
    fi
fi

# 创建ISOLINUX配置
echo "创建ISOLINUX配置..."
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG_EOF'
DEFAULT vesamenu.c32
PROMPT 0
TIMEOUT 100
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
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

LABEL install
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 console=ttyS0,115200n8 rw quiet

LABEL debug
  MENU LABEL ^Debug Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 console=ttyS0,115200n8 rw init=/bin/sh

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img console=tty0 init=/bin/sh

LABEL local
  MENU LABEL Boot from ^local disk
  LOCALBOOT 0x80
ISOLINUX_CFG_EOF

echo "✅ BIOS引导配置完成"
echo ""

# ========== 第6步：创建UEFI引导配置 ==========
echo "[6/8] 🔧 创建UEFI引导配置..."

# 创建GRUB配置
echo "创建GRUB配置..."
cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG_EOF'
set timeout=10
set default=0

menuentry "Install OpenWRT (UEFI Mode)" {
    echo "Loading kernel..."
    linux /live/vmlinuz console=tty0 console=ttyS0,115200n8 rw quiet
    echo "Loading initial ramdisk..."
    initrd /live/initrd.img
    echo "Booting OpenWRT installer..."
}

menuentry "Debug Mode" {
    linux /live/vmlinuz console=tty0 console=ttyS0,115200n8 rw init=/bin/sh
    initrd /live/initrd.img
}

menuentry "Boot from local disk" {
    echo "Attempting to boot from local disk..."
    exit
}
GRUB_CFG_EOF

# 生成GRUB EFI可执行文件
echo "生成GRUB EFI文件..."
if command -v grub-mkstandalone >/dev/null 2>&1; then
    echo "使用grub-mkstandalone..."
    
    # 创建临时配置文件
    mkdir -p "$WORK_DIR/grub-temp/boot/grub"
    cp "$STAGING_DIR/boot/grub/grub.cfg" "$WORK_DIR/grub-temp/boot/grub/"
    
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$WORK_DIR/bootx64.efi" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos fat ext2 iso9660" \
        "boot/grub/grub.cfg=$WORK_DIR/grub-temp/boot/grub/grub.cfg"
    
    if [ -f "$WORK_DIR/bootx64.efi" ]; then
        cp "$WORK_DIR/bootx64.efi" "$STAGING_DIR/EFI/boot/bootx64.efi"
        echo "✅ GRUB EFI文件生成成功"
    fi
    
    rm -rf "$WORK_DIR/grub-temp"
elif command -v grub-mkimage >/dev/null 2>&1; then
    echo "使用grub-mkimage..."
    
    grub-mkimage \
        -O x86_64-efi \
        -o "$STAGING_DIR/EFI/boot/bootx64.efi" \
        -p /boot/grub \
        fat iso9660 part_gpt part_msdos normal boot linux configfile loopback chain \
        efifwsetup efi_gop efi_uga ls search search_label search_fs_uuid search_fs_file \
        gfxterm gfxterm_background gfxterm_menu test all_video loadenv exfat ext2 \
        echo true probe terminal
    
    if [ -f "$STAGING_DIR/EFI/boot/bootx64.efi" ]; then
        echo "✅ GRUB EFI文件生成成功"
    fi
fi

# 如果EFI文件生成成功，创建EFI引导镜像
if [ -f "$STAGING_DIR/EFI/boot/bootx64.efi" ]; then
    echo "创建EFI引导镜像..."
    
    # 创建FAT格式的EFI镜像
    EFI_IMG="$WORK_DIR/efiboot.img"
    dd if=/dev/zero of="$EFI_IMG" bs=1K count=1440 2>/dev/null
    mkfs.fat -F 12 -n "OPENWRT_EFI" "$EFI_IMG" 2>/dev/null || \
    mkfs.fat -F 32 -n "OPENWRT_EFI" "$EFI_IMG" 2>/dev/null
    
    # 挂载并复制文件
    EFI_MOUNT="$WORK_DIR/efi_mount"
    mkdir -p "$EFI_MOUNT"
    
    if mount -o loop "$EFI_IMG" "$EFI_MOUNT" 2>/dev/null; then
        mkdir -p "$EFI_MOUNT/EFI/boot"
        cp "$STAGING_DIR/EFI/boot/bootx64.efi" "$EFI_MOUNT/EFI/boot/"
        
        # 复制GRUB配置
        mkdir -p "$EFI_MOUNT/boot/grub"
        cp "$STAGING_DIR/boot/grub/grub.cfg" "$EFI_MOUNT/boot/grub/"
        
        umount "$EFI_MOUNT"
        cp "$EFI_IMG" "$STAGING_DIR/EFI/boot/efiboot.img"
        echo "✅ EFI引导镜像创建成功"
    else
        echo "⚠ 无法创建EFI引导镜像，将生成仅BIOS引导的ISO"
    fi
    
    rm -rf "$EFI_MOUNT" "$EFI_IMG"
else
    echo "⚠ 无法生成GRUB EFI文件，UEFI引导可能不可用"
fi

echo "✅ UEFI引导配置完成"
echo ""

# ========== 第7步：构建ISO ==========
echo "[7/8] 📦 构建ISO文件..."

cd "$WORK_DIR"

# 检查是否创建了EFI引导镜像
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
        "$STAGING_DIR" 2>&1 | grep -v "^xorriso" | grep -v "IFS" || true
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
        "$STAGING_DIR" 2>&1 | grep -v "^xorriso" | grep -v "IFS" || true
fi

echo ""

# ========== 第8步：验证结果 ==========
echo "[8/8] 🔍 验证构建结果..."

if [ -f "/output/openwrt.iso" ]; then
    ISO_SIZE=$(du -h "/output/openwrt.iso" | cut -f1)
    echo "✅ ✅ ✅ ISO构建成功! ✅ ✅ ✅"
    echo ""
    echo "📊 ISO详细信息:"
    echo "  文件路径: /output/openwrt.iso"
    echo "  文件大小: $ISO_SIZE"
    echo "  创建时间: $(date)"
    echo ""
    
    # 显示ISO信息
    if command -v file >/dev/null 2>&1; then
        FILE_INFO=$(file "/output/openwrt.iso")
        echo "文件类型: $FILE_INFO"
        
        if echo "$FILE_INFO" | grep -qi "bootable"; then
            echo "✅ ISO包含引导信息"
        fi
        
        if echo "$FILE_INFO" | grep -qi "UEFI\|EFI"; then
            echo "✅ ISO支持UEFI引导"
        fi
    fi
    
    # 检查ISO内容
    echo ""
    echo "📁 ISO内容结构:"
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -indev "/output/openwrt.iso" -ls 2>/dev/null | head -20
    fi
    
    # 创建构建信息文件
    cat > "/output/build-info.txt" << EOF
OpenWRT Alpine Installer ISO
============================
构建日期:      $(date)
Alpine版本:    3.20
内核版本:      $(file "$STAGING_DIR/live/vmlinuz" 2>/dev/null | cut -d, -f1 | cut -d: -f2-)
ISO大小:       $ISO_SIZE

引导支持:
  - BIOS (ISOLINUX): 是
  - UEFI (GRUB):     $( [ -f "$EFI_IMG_PATH" ] && echo "是" || echo "否" )

包含文件:
  - OpenWRT镜像:     images/openwrt.img
  - Linux内核:      live/vmlinuz
  - Initramfs:      live/initrd.img

使用方法:
  1. 刻录到USB: sudo dd if=openwrt.iso of=/dev/sdX bs=4M status=progress
  2. 从USB启动
  3. 选择目标磁盘安装

注意事项:
  - 安装将完全擦除目标磁盘
  - 确保已备份重要数据

构建来源: https://github.com/sirpdboy/openwrt-installer-iso.git
EOF
    
    echo "✅ 构建信息保存到: /output/build-info.txt"
    echo ""
    echo "🚀 构建完成！可以测试ISO文件了。"
    
    # 清理工作区
    rm -rf "$WORK_DIR"
    
    exit 0
else
    echo "❌ ISO创建失败"
    echo ""
    echo "调试信息:"
    echo "工作区内容:"
    ls -la "$WORK_DIR" 2>/dev/null || true
    echo ""
    echo "暂存区内容:"
    ls -la "$STAGING_DIR" 2>/dev/null || true
    
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
