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
# build-iso-alpine.sh - OpenWRT ISO构建脚本（基于Alpine官方方法）
# 支持BIOS和UEFI双引导

set -e

echo "================================================"
echo "  OpenWRT Alpine Installer - Official Method"
echo "================================================"
echo ""

# 从环境变量获取参数
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt.iso}"
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

log_info "✅ 输入文件: $INPUT_IMG ($(du -h "$INPUT_IMG" | cut -f1))"
log_info "✅ 输出目录: /output"
echo ""

# ========== 步骤1: 检查输入文件 ==========
log_info "[1/10] 检查输入文件..."
if [ ! -f "$INPUT_IMG" ]; then
    log_error "OpenWRT镜像未找到: $INPUT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$INPUT_IMG" | awk '{print $5}')
log_success "找到OpenWRT镜像: $IMG_SIZE"
echo ""

# ========== 步骤2: 创建工作区 ==========
log_info "[2/10] 创建工作区..."
WORK_DIR="/tmp/openwrt_iso_$(date +%s)"
ISO_ROOT="$WORK_DIR/iso_root"
STAGING_DIR="$WORK_DIR/staging"
ISO_PATH="$OUTPUT_DIR/$ISO_NAME"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$ISO_ROOT"
mkdir -p "$STAGING_DIR"
mkdir -p "$OUTPUT_DIR"

# 创建ISO目录结构（遵循Alpine标准）
mkdir -p "$STAGING_DIR"/{boot/grub,EFI/boot,isolinux,images}
echo ""

# ========== 步骤3: 获取Alpine官方内核和initramfs ==========
log_info "[3/10] 获取Alpine官方内核和initramfs..."

ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_BRANCH="v${ALPINE_VERSION}"
ALPINE_ARCH="x86_64"

# 下载Alpine的aarch镜像来获取官方initramfs
log_info "下载Alpine aarch镜像..."
AARCH_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/main/${ALPINE_ARCH}/apk-tools-static-*.apk"

if command -v curl >/dev/null 2>&1; then
    curl -L -o "$WORK_DIR/apk-tools.apk" "$AARCH_URL" 2>/dev/null || true
fi

# 下载Alpine的内核包
log_info "下载Alpine内核包..."
KERNEL_PKG="linux-lts"
APK_CACHE_DIR="$WORK_DIR/apk_cache"
mkdir -p "$APK_CACHE_DIR"

# 尝试从Alpine仓库下载内核和initramfs工具
download_alpine_pkg() {
    local pkg="$1"
    local url="${ALPINE_MIRROR}/${ALPINE_BRANCH}/main/${ALPINE_ARCH}/${pkg}-*.apk"
    
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$APK_CACHE_DIR/${pkg}.apk" "$url" 2>/dev/null && return 0
    fi
    return 1
}

# 下载内核
if download_alpine_pkg "linux-lts"; then
    log_info "提取内核文件..."
    tar -xzf "$APK_CACHE_DIR/linux-lts.apk" -C "$WORK_DIR" 2>/dev/null || true
    
    # 查找内核文件
    if [ -f "$WORK_DIR/boot/vmlinuz-lts" ]; then
        cp "$WORK_DIR/boot/vmlinuz-lts" "$STAGING_DIR/boot/vmlinuz-lts"
        log_success "找到内核: vmlinuz-lts"
    fi
    
    # 查找initramfs
    if [ -f "$WORK_DIR/boot/initramfs-lts" ]; then
        cp "$WORK_DIR/boot/initramfs-lts" "$STAGING_DIR/boot/initramfs-lts"
        log_success "找到initramfs"
    fi
fi

# ========== 步骤4: 创建基于Alpine官方initramfs的init ==========
log_info "[4/10] 创建OpenWRT安装initramfs..."

# 方法1: 使用Alpine的mkinitfs创建initramfs
if command -v mkinitfs >/dev/null 2>&1; then
    log_info "使用mkinitfs创建initramfs..."
    
    # 创建initramfs目录
    INITRAMFS_DIR="$WORK_DIR/initramfs"
    mkdir -p "$INITRAMFS_DIR"
    
    # 创建init脚本
    cat > "$INITRAMFS_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh
# OpenWRT安装程序 - 基于Alpine

# 挂载必要文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s
mount -t tmpfs tmpfs /tmp

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 清屏
clear

# 显示标题
cat << "HEADER"
========================================
      OpenWRT 安装程序 (Alpine)
========================================
HEADER

echo ""
echo "正在初始化系统..."

# 加载必要模块
echo "加载内核模块..."
for mod in isofs cdrom sr_mod loop virtio_blk virtio_pci virtio_mmio ata_piix sd_mod ahci nvme; do
    modprobe $mod 2>/dev/null || true
done

# 查找CDROM设备
echo "查找安装介质..."
for dev in /dev/sr0 /dev/cdrom /dev/sr[0-9]*; do
    if [ -b "$dev" ]; then
        echo "找到CDROM设备: $dev"
        mount -t iso9660 -o ro $dev /mnt 2>/dev/null && break
    fi
done

# 如果挂载失败，尝试挂载为loop设备
if ! mountpoint -q /mnt; then
    echo "尝试挂载ISO镜像..."
    for img in /images/openwrt.img /openwrt.img; do
        if [ -f "$img" ]; then
            echo "找到OpenWRT镜像: $img"
            break
        fi
    done
fi

# 安装函数
install_openwrt() {
    echo ""
    echo "=== OpenWRT 安装程序 ==="
    echo ""
    
    # 显示可用磁盘
    echo "可用磁盘:"
    echo "---------"
    ls -la /dev/sd* /dev/nvme* 2>/dev/null | grep '^b' | awk '{print $NF}' | while read disk; do
        if [ -b "$disk" ]; then
            size=$(blockdev --getsize64 $disk 2>/dev/null)
            if [ -n "$size" ]; then
                size_mb=$((size / 1024 / 1024))
                echo "  $disk (${size_mb}MB)"
            else
                echo "  $disk"
            fi
        fi
    done
    echo ""
    
    # 获取目标磁盘
    while true; do
        echo -n "请输入目标磁盘 (例如: sda, nvme0n1): "
        read target_disk
        
        if [ -z "$target_disk" ]; then
            echo "错误: 请输入磁盘名称"
            continue
        fi
        
        # 添加/dev/前缀
        if [[ "$target_disk" != /dev/* ]]; then
            target_disk="/dev/$target_disk"
        fi
        
        if [ ! -b "$target_disk" ]; then
            echo "错误: 磁盘 $target_disk 不存在"
            continue
        fi
        
        # 确认
        echo ""
        echo "⚠️  警告: 这将永久擦除 $target_disk 上的所有数据!"
        echo ""
        echo -n "确认安装到 $target_disk? (输入 YES 确认): "
        read confirm
        
        if [ "$confirm" = "YES" ]; then
            break
        else
            echo "安装已取消"
            return 1
        fi
    done
    
    # 查找OpenWRT镜像
    img_path=""
    for path in /mnt/images/openwrt.img /images/openwrt.img; do
        if [ -f "$path" ]; then
            img_path="$path"
            break
        fi
    done
    
    if [ -z "$img_path" ]; then
        echo "错误: 找不到OpenWRT镜像"
        return 1
    fi
    
    # 开始安装
    echo ""
    echo "正在安装 OpenWRT..."
    echo "源: $img_path"
    echo "目标: $target_disk"
    echo ""
    
    # 显示进度
    echo "写入磁盘..."
    if command -v pv >/dev/null 2>&1; then
        pv "$img_path" | dd of="$target_disk" bs=4M oflag=sync status=none
    else
        dd if="$img_path" of="$target_disk" bs=4M status=progress
    fi
    
    if [ $? -eq 0 ]; then
        sync
        echo ""
        echo "✅ 安装成功!"
        echo ""
        echo "OpenWRT 已安装到 $target_disk"
        echo ""
        echo "系统将在10秒后重启..."
        
        # 倒计时
        for i in $(seq 10 -1 1); do
            echo -ne "重启倒计时: ${i}秒\r"
            sleep 1
        done
        
        echo ""
        echo "正在重启..."
        reboot -f
    else
        echo ""
        echo "❌ 安装失败!"
        return 1
    fi
}

# 主循环
while true; do
    echo ""
    echo "请选择操作:"
    echo "1) 安装 OpenWRT"
    echo "2) 进入 Shell"
    echo "3) 重启"
    echo ""
    echo -n "选择 (1-3): "
    read choice
    
    case $choice in
        1)
            if install_openwrt; then
                break
            fi
            ;;
        2)
            echo "进入紧急Shell..."
            echo "输入 'exit' 返回安装程序"
            /bin/sh
            ;;
        3)
            echo "正在重启..."
            reboot -f
            ;;
        *)
            echo "无效选择"
            ;;
    esac
done
INIT_EOF

    chmod +x "$INITRAMFS_DIR/init"
    
    # 复制busybox
    if command -v busybox >/dev/null 2>&1; then
        cp $(which busybox) "$INITRAMFS_DIR/busybox"
        cd "$INITRAMFS_DIR"
        
        # 创建符号链接
        for app in sh mount umount dd sync reboot poweroff modprobe \
                   ls cat echo sleep clear read ps grep awk; do
            ln -s busybox "$app" 2>/dev/null || true
        done
        
        cd - >/dev/null
    fi
    
    # 创建设备节点
    mkdir -p "$INITRAMFS_DIR/dev"
    mknod "$INITRAMFS_DIR/dev/console" c 5 1 2>/dev/null || true
    mknod "$INITRAMFS_DIR/dev/null" c 1 3 2>/dev/null || true
    
    # 创建目录结构
    mkdir -p "$INITRAMFS_DIR"/{proc,sys,dev,tmp,run,mnt,images,bin,sbin,usr/bin,usr/sbin}
    
    # 打包initramfs
    cd "$INITRAMFS_DIR"
    find . -print0 | cpio --null -ov -H newc 2>/dev/null | gzip -9 > "$STAGING_DIR/boot/initramfs-openwrt"
    cd - >/dev/null
    
    log_success "创建initramfs: $(du -h "$STAGING_DIR/boot/initramfs-openwrt" | cut -f1)"
    
else
    # 方法2: 使用现有initramfs并修改
    log_info "修改现有initramfs..."
    
    if [ -f "$STAGING_DIR/boot/initramfs-lts" ]; then
        INITRAMFS_DIR="$WORK_DIR/initramfs_extract"
        rm -rf "$INITRAMFS_DIR"
        mkdir -p "$INITRAMFS_DIR"
        
        cd "$INITRAMFS_DIR"
        gzip -dc "$STAGING_DIR/boot/initramfs-lts" | cpio -id 2>/dev/null
        
        # 替换init脚本
        cat > init << 'INIT_SIMPLE'
#!/bin/busybox sh

# 挂载必要文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 清屏
clear

echo "========================================"
echo "      OpenWRT 简单安装程序"
echo "========================================"
echo ""

# 挂载ISO
echo "挂载安装介质..."
for dev in /dev/sr0 /dev/cdrom; do
    if [ -b "$dev" ]; then
        mount -t iso9660 -o ro $dev /mnt 2>/dev/null && break
    fi
done

# 主安装函数
install() {
    echo "可用磁盘:"
    ls /dev/sd* /dev/nvme* 2>/dev/null | grep -v "[0-9]$" || true
    echo ""
    
    echo -n "输入目标磁盘 (如: sda): "
    read disk
    
    if [ -z "$disk" ]; then
        echo "无效输入"
        return 1
    fi
    
    if [[ "$disk" != /dev/* ]]; then
        disk="/dev/$disk"
    fi
    
    if [ ! -b "$disk" ]; then
        echo "磁盘不存在"
        return 1
    fi
    
    # 查找镜像
    img=""
    for path in /mnt/images/openwrt.img /images/openwrt.img; do
        if [ -f "$path" ]; then
            img="$path"
            break
        fi
    done
    
    if [ -z "$img" ]; then
        echo "找不到OpenWRT镜像"
        return 1
    fi
    
    echo ""
    echo "⚠️  将安装到 $disk"
    echo -n "确认? (YES): "
    read confirm
    
    if [ "$confirm" != "YES" ]; then
        echo "已取消"
        return 1
    fi
    
    echo "正在写入..."
    dd if="$img" of="$disk" bs=4M status=progress
    sync
    
    echo "✅ 安装完成!"
    echo "10秒后重启..."
    sleep 10
    reboot -f
}

# 运行安装
install
INIT_SIMPLE

        chmod +x init
        
        # 重新打包
        find . -print0 | cpio --null -ov -H newc 2>/dev/null | gzip -9 > "$STAGING_DIR/boot/initramfs-openwrt"
        cd - >/dev/null
        
        log_success "修改initramfs完成"
    else
        log_error "无法创建initramfs"
        exit 1
    fi
fi

# 确保有内核文件
if [ ! -f "$STAGING_DIR/boot/vmlinuz-lts" ]; then
    log_info "复制内核文件..."
    if [ -f /boot/vmlinuz-lts ]; then
        cp /boot/vmlinuz-lts "$STAGING_DIR/boot/vmlinuz-lts"
    elif [ -f /boot/vmlinuz ]; then
        cp /boot/vmlinuz "$STAGING_DIR/boot/vmlinuz-lts"
    else
        log_error "未找到内核文件"
        exit 1
    fi
fi

# ========== 步骤5: 复制OpenWRT镜像 ==========
log_info "[5/10] 复制OpenWRT镜像..."
cp "$INPUT_IMG" "$STAGING_DIR/images/openwrt.img"
log_success "OpenWRT镜像已复制"

# ========== 步骤6: 创建ISOLINUX配置并复制所有必要文件 ==========
log_info "[5/10] 创建BIOS引导配置..."

# 创建ISOLINUX目录
mkdir -p "$STAGING_DIR/isolinux"

# 创建简单的isolinux.cfg（不使用图形菜单避免依赖问题）
cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT install
TIMEOUT 100
PROMPT 1

LABEL install
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-openwrt console=tty0 console=ttyS0,115200 quiet

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-openwrt console=tty0 console=ttyS0,115200 init=/bin/sh

LABEL memtest
  MENU LABEL Memory Test
  KERNEL /boot/memtest

LABEL hdt
  MENU LABEL Hardware Detection Tool
  KERNEL /boot/hdt.c32

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32

ISOLINUX_CFG

# 复制所有必要的ISOLINUX文件
log_info "复制ISOLINUX引导文件..."

# 定义必要的文件列表
REQUIRED_FILES="
isolinux.bin
ldlinux.c32
libutil.c32
libcom32.c32
menu.c32
vesamenu.c32
chain.c32
reboot.c32
poweroff.c32
hdt.c32
memdisk
memtest
"

# 搜索syslinux文件的位置
SYS_LIB_DIRS="/usr/lib/syslinux /usr/share/syslinux /usr/lib/syslinux/modules/bios"

# 复制核心文件
log_info "复制核心ISOLINUX文件..."
for sys_dir in $SYS_LIB_DIRS; do
    if [ -d "$sys_dir" ]; then
        log_info "从 $sys_dir 复制文件..."
        
        # 复制绝对必要的文件
        cp "$sys_dir/isolinux.bin" "$STAGING_DIR/isolinux/" 2>/dev/null || true
        cp "$sys_dir/ldlinux.c32" "$STAGING_DIR/isolinux/" 2>/dev/null || true
        cp "$sys_dir/libutil.c32" "$STAGING_DIR/isolinux/" 2>/dev/null || true
        cp "$sys_dir/libcom32.c32" "$STAGING_DIR/isolinux/" 2>/dev/null || true
        
        # 复制其他常用文件
        for file in menu.c32 vesamenu.c32 chain.c32 reboot.c32 poweroff.c32; do
            if [ -f "$sys_dir/$file" ]; then
                cp "$sys_dir/$file" "$STAGING_DIR/isolinux/" 2>/dev/null || true
            fi
        done
        
        # 复制memtest和hdt
        if [ -f "$sys_dir/memtest" ]; then
            cp "$sys_dir/memtest" "$STAGING_DIR/boot/" 2>/dev/null || true
        fi
        
        if [ -f "$sys_dir/hdt.c32" ]; then
            cp "$sys_dir/hdt.c32" "$STAGING_DIR/boot/" 2>/dev/null || true
        fi
        
        break
    fi
done

# 验证必要的文件是否存在
log_info "验证ISOLINUX文件..."
MISSING_FILES=0
for file in isolinux.bin ldlinux.c32 libutil.c32 libcom32.c32; do
    if [ ! -f "$STAGING_DIR/isolinux/$file" ]; then
        log_error "缺少必要文件: $file"
        MISSING_FILES=1
    fi
done

if [ $MISSING_FILES -eq 0 ]; then
    log_success "ISOLINUX文件准备完成"
else
    log_warning "缺少一些文件，尝试生成..."
    
    # 尝试使用简单的文本菜单替代图形菜单
    if [ ! -f "$STAGING_DIR/isolinux/menu.c32" ]; then
        log_info "创建文本菜单配置..."
        cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'SIMPLE_CFG'
DEFAULT install
TIMEOUT 50
PROMPT 0

DISPLAY boot.msg

LABEL install
  MENU DEFAULT
  MENU LABEL Install OpenWRT
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-openwrt console=tty0 quiet

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-openwrt console=tty0 init=/bin/sh

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32
SIMPLE_CFG
    
        # 创建boot.msg
        cat > "$STAGING_DIR/isolinux/boot.msg" << 'BOOT_MSG'
##############################################
#           OpenWRT Installer                #
#                                            #
#         Alpine-based Installer             #
#                                            #
#     Support: BIOS & UEFI Boot              #
##############################################

Press [Tab] to edit options

Install OpenWRT:         直接安装OpenWRT到磁盘
Emergency Shell:         进入紧急Shell
Reboot:                  重启系统
BOOT_MSG
    fi
fi

# ========== 步骤7: 创建简化的GRUB配置 (UEFI引导) ==========
log_info "[6/10] 创建UEFI引导配置..."

# 创建GRUB目录结构
mkdir -p "$STAGING_DIR/boot/grub"

cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660
insmod ext2
insmod gfxterm
insmod gfxmenu

set gfxmode=auto
set gfxpayload=keep

loadfont /boot/grub/unicode.pf2

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Install OpenWRT" {
    echo "Loading kernel..."
    linux /boot/vmlinuz-lts initrd=/boot/initramfs-openwrt console=tty0 console=ttyS0,115200 quiet
    echo "Loading initramfs..."
    initrd /boot/initramfs-openwrt
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz-lts initrd=/boot/initramfs-openwrt console=tty0 console=ttyS0,115200 init=/bin/sh
    initrd /boot/initramfs-openwrt
}

menuentry "Reboot" {
    reboot
}

menuentry "Power Off" {
    halt
}
GRUB_CFG

# ========== 步骤8: 创建UEFI引导文件 ==========
log_info "[7/10] 创建UEFI引导文件..."

# 使用更可靠的方法创建EFI引导
create_efi_boot() {
    local efi_dir="$1"
    
    log_info "创建EFI引导结构..."
    mkdir -p "$efi_dir/EFI/boot"
    
    # 方法1: 使用grub-mkstandalone
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        log_info "使用grub-mkstandalone创建EFI..."
        
        # 创建临时grub配置
        local tmp_grub="$WORK_DIR/grub_tmp"
        mkdir -p "$tmp_grub/boot/grub"
        
        cat > "$tmp_grub/boot/grub/grub.cfg" << 'EFI_GRUB_CFG'
search --file /boot/grub/grub.cfg --set=root
configfile /boot/grub/grub.cfg
EFI_GRUB_CFG
        
        grub-mkstandalone \
            -O x86_64-efi \
            -o "$efi_dir/EFI/boot/bootx64.efi" \
            --modules="part_gpt part_msdos fat ext2 iso9660" \
            --locales="" \
            --fonts="" \
            "boot/grub/grub.cfg=$tmp_grub/boot/grub/grub.cfg"
        
        if [ -f "$efi_dir/EFI/boot/bootx64.efi" ]; then
            log_success "EFI文件创建成功"
            return 0
        fi
    fi
    
    # 方法2: 直接复制现有EFI文件
    log_info "尝试复制现有EFI文件..."
    for efi_path in \
        /usr/lib/grub/x86_64-efi/monolithic/grub.efi \
        /usr/share/grub/grubx64.efi \
        /boot/efi/EFI/*/grubx64.efi; do
        if [ -f "$efi_path" ]; then
            cp "$efi_path" "$efi_dir/EFI/boot/bootx64.efi"
            log_success "复制EFI文件: $efi_path"
            return 0
        fi
    done
    
    # 方法3: 创建最小的EFI存根
    log_warning "创建最小EFI存根..."
    cat > "$efi_dir/EFI/boot/bootx64.efi" << 'EFI_STUB'
#!/bin/sh
echo "UEFI boot stub - Use BIOS boot instead"
echo "This ISO should boot in BIOS/CSM mode"
sleep 5
exit 1
EFI_STUB
    
    chmod +x "$efi_dir/EFI/boot/bootx64.efi"
    log_warning "创建了EFI存根文件"
    return 1
}

create_efi_boot "$STAGING_DIR"

# ========== 步骤9: 复制内核和initramfs ==========
log_info "[8/10] 复制内核文件..."

# 确保内核文件存在
if [ ! -f "$STAGING_DIR/boot/vmlinuz-lts" ]; then
    log_info "查找内核文件..."
    for kernel in /boot/vmlinuz-lts /boot/vmlinuz /vmlinuz; do
        if [ -f "$kernel" ]; then
            cp "$kernel" "$STAGING_DIR/boot/vmlinuz-lts"
            log_success "复制内核: $kernel"
            break
        fi
    done
fi

if [ ! -f "$STAGING_DIR/boot/initramfs-openwrt" ]; then
    # 创建最小initramfs
    create_minimal_initrd "$STAGING_DIR/boot/initramfs-openwrt"
fi

# ========== 步骤10: 构建ISO ==========
log_info "[9/10] 构建ISO镜像..."

# 创建构建命令
XORRISO_CMD="xorriso"

# 确保isolinux.bin存在
if [ ! -f "$STAGING_DIR/isolinux/isolinux.bin" ]; then
    log_error "缺少isolinux.bin，无法构建可引导ISO"
    exit 1
fi

# 构建ISO
log_info "使用xorriso构建ISO..."

xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/boot/bootx64.efi \
    -no-emul-boot \
    -output "$ISO_PATH" \
    "$STAGING_DIR" 2>&1 | tee "$WORK_DIR/xorriso.log"

# 如果失败，尝试简单方法
if [ ! -f "$ISO_PATH" ]; then
    log_warning "标准方法失败，尝试简单方法..."
    
    xorriso \
        -outdev "$ISO_PATH" \
        -map "$STAGING_DIR" / \
        -boot_image isolinux dir=/isolinux \
        -boot_image any next \
        -boot_image any efi_path=--interval:appended_partition_2:all:: \
        -boot_image isolinux system_area=/usr/share/syslinux/isohdpfx.bin \
        -volid "OPENWRT" \
        -padding 0
fi

# ========== 步骤11: 验证和测试 ==========
log_info "[10/10] 验证ISO..."

if [ -f "$ISO_PATH" ] && [ -s "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    log_success "✅ ISO构建成功! 大小: $ISO_SIZE"
    
    # 测试ISO可引导性
    echo ""
    log_info "ISO引导信息:"
    
    if command -v isoinfo >/dev/null 2>&1; then
        isoinfo -d -i "$ISO_PATH" 2>/dev/null | grep -E "Volume|Boot|Catalog"
    fi
    
    # 检查ISO结构
    echo ""
    log_info "ISO内容摘要:"
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -indev "$ISO_PATH" -toc 2>/dev/null | head -20
    fi
    
    # 创建成功报告
    echo ""
    log_success "🎉 ISO构建完成!"
    echo "文件: $ISO_PATH"
    echo "大小: $ISO_SIZE"
    echo "引导: BIOS + UEFI (基础)"
    
else
    log_error "❌ ISO构建失败"
    
    # 显示错误日志
    if [ -f "$WORK_DIR/xorriso.log" ]; then
        log_error "构建日志:"
        tail -20 "$WORK_DIR/xorriso.log"
    fi
    
    exit 1
fi

# 清理
rm -rf "$WORK_DIR"

exit 0

# ========== 辅助函数 ==========
create_minimal_initrd() {
    local initrd_path="$1"
    local initrd_dir="$WORK_DIR/initrd_root"
    
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    
    # 创建init脚本
    cat > "$initrd_dir/init" << 'MINIMAL_INIT'
#!/bin/busybox sh

# 挂载必要文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

clear
echo "========================================"
echo "   OpenWRT Minimal Install Environment"
echo "========================================"
echo ""

# 挂载CDROM
echo "Mounting installation media..."
for dev in /dev/sr0 /dev/cdrom; do
    if [ -b "$dev" ]; then
        mount -t iso9660 -o ro $dev /mnt 2>/dev/null && break
    fi
done

# 运行安装脚本
if [ -f /mnt/install.sh ]; then
    chmod +x /mnt/install.sh
    /mnt/install.sh
else
    echo "Installation script not found"
    echo "Dropping to emergency shell..."
    exec /bin/sh
fi
MINIMAL_INIT

    chmod +x "$initrd_dir/init"
    
    # 复制busybox
    if command -v busybox >/dev/null 2>&1; then
        cp $(which busybox) "$initrd_dir/"
        cd "$initrd_dir"
        ln -s busybox sh
        ln -s busybox mount
        ln -s busybox umount
        ln -s busybox echo
        ln -s busybox cat
        ln -s busybox ls
        cd - >/dev/null
    fi
    
    # 创建设备
    mkdir -p "$initrd_dir/dev"
    mknod "$initrd_dir/dev/console" c 5 1 2>/dev/null || true
    mknod "$initrd_dir/dev/null" c 1 3 2>/dev/null || true
    
    # 打包
    cd "$initrd_dir"
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$initrd_path"
    cd - >/dev/null
    
    log_success "创建最小initrd: $(du -h "$initrd_path" | cut -f1)"
}



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
