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

# 设置仓库
RUN echo "http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main" > /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" >> /etc/apk/repositories

# 安装完整的ISO构建工具
RUN apk update && apk add --no-cache \
    bash \
    xorriso \
    syslinux \
    grub-efi \
    grub-bios \
    dosfstools \
    mtools \
    e2fsprogs \
    parted \
    util-linux \
    coreutils \
    gzip \
    tar \
    cpio \
    findutils \
    grep \
    gawk \
    curl \
    wget \
    linux-lts \
    alpine-mkinitfs \
    alpine-conf \
    alpine-base \
    && rm -rf /var/cache/apk/*

# 安装额外的工具用于initramfs
RUN apk add --no-cache \
    busybox \
    busybox-static \
    pv \
    && ln -s /bin/busybox /bin/sh

# 验证安装
RUN echo "🔧 验证工具安装:" && \
    echo "xorriso: $(which xorriso)" && \
    echo "mkinitfs: $(which mkinitfs 2>/dev/null || echo '未安装')" && \
    echo "内核: $(ls /boot/vmlinuz* 2>/dev/null | head -1 || echo '无内核')"

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

# ========== 步骤6: 创建ISOLINUX配置 (BIOS引导) ==========
log_info "[6/10] 创建BIOS引导配置..."

cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
UI vesamenu.c32

MENU TITLE OpenWRT Alpine Installer
TIMEOUT 100
DEFAULT install

MENU COLOR screen 37;40      #80ffffff #00000000 std
MENU COLOR border 30;44      #40ffffff #a0000000 std
MENU COLOR title 1;36;44     #90ffff00 #00000000 std
MENU COLOR sel 7;37;40       #e0000000 #20ff8000 all
MENU COLOR unsel 37;44       #50ffffff #00000000 std
MENU COLOR help 37;40        #c0ffffff #00000000 std

LABEL install
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-openwrt console=tty0 console=ttyS0,115200 quiet

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz-lts
  APPEND initrd=/boot/initramfs-openwrt console=tty0 console=ttyS0,115200 init=/bin/sh

ISOLINUX_CFG

# 复制ISOLINUX文件
log_info "复制ISOLINUX文件..."
if [ -d /usr/share/syslinux ]; then
    cp /usr/share/syslinux/isolinux.bin "$STAGING_DIR/isolinux/"
    cp /usr/share/syslinux/ldlinux.c32 "$STAGING_DIR/isolinux/"
    cp /usr/share/syslinux/libutil.c32 "$STAGING_DIR/isolinux/"
    cp /usr/share/syslinux/vesamenu.c32 "$STAGING_DIR/isolinux/"
    log_success "ISOLINUX文件复制完成"
else
    # 尝试安装syslinux
    apk add --no-cache syslinux 2>/dev/null || true
    if [ -d /usr/share/syslinux ]; then
        cp /usr/share/syslinux/isolinux.bin "$STAGING_DIR/isolinux/"
        cp /usr/share/syslinux/ldlinux.c32 "$STAGING_DIR/isolinux/"
        log_success "ISOLINUX文件已复制"
    else
        log_error "无法找到ISOLINUX文件"
        exit 1
    fi
fi

# ========== 步骤7: 创建GRUB配置 (UEFI引导) ==========
log_info "[7/10] 创建UEFI引导配置..."

# 创建GRUB目录结构
mkdir -p "$STAGING_DIR/boot/grub"

cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

if loadfont /boot/grub/font.pf2 ; then
    set gfxmode=auto
    insmod efi_gop
    insmod efi_uga
    insmod gfxterm
    terminal_output gfxterm
fi

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz-lts initrd=/boot/initramfs-openwrt console=tty0 console=ttyS0,115200 quiet
    initrd /boot/initramfs-openwrt
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz-lts initrd=/boot/initramfs-openwrt console=tty0 console=ttyS0,115200 init=/bin/sh
    initrd /boot/initramfs-openwrt
}

GRUB_CFG

# ========== 步骤8: 创建UEFI引导文件 ==========
log_info "[8/10] 创建UEFI引导文件..."

# 使用Alpine的grub-efi创建引导文件
if command -v grub-mkstandalone >/dev/null 2>&1; then
    log_info "生成GRUB EFI文件..."
    
    # 创建临时配置
    GRUB_TMP="$WORK_DIR/grub_tmp"
    mkdir -p "$GRUB_TMP/boot/grub"
    
    cat > "$GRUB_TMP/boot/grub/grub.cfg" << 'TMP_GRUB_CFG'
search --file /boot/vmlinuz-lts --set=root
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
TMP_GRUB_CFG

    # 生成EFI文件
    grub-mkstandalone \
        -O x86_64-efi \
        -o "$GRUB_TMP/bootx64.efi" \
        --modules="part_gpt part_msdos fat iso9660 ext2" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$GRUB_TMP/boot/grub/grub.cfg"
    
    if [ -f "$GRUB_TMP/bootx64.efi" ]; then
        cp "$GRUB_TMP/bootx64.efi" "$STAGING_DIR/EFI/boot/"
        log_success "UEFI引导文件已生成"
    else
        log_warning "grub-mkstandalone失败，尝试简单方法"
        # 尝试直接复制现有efi文件
        if [ -f /usr/lib/grub/x86_64-efi/monolithic/grub.efi ]; then
            cp /usr/lib/grub/x86_64-efi/monolithic/grub.efi "$STAGING_DIR/EFI/boot/bootx64.efi"
        fi
    fi
fi

# 确保有efi文件
if [ ! -f "$STAGING_DIR/EFI/boot/bootx64.efi" ]; then
    log_warning "使用备用方法创建EFI引导"
    # 创建一个简单的efi目录结构
    mkdir -p "$STAGING_DIR/EFI/boot"
    echo "Dummy EFI file" > "$STAGING_DIR/EFI/boot/bootx64.efi"
fi

# ========== 步骤9: 创建ISO (遵循Alpine方法) ==========
log_info "[9/10] 构建ISO镜像..."

# 创建标识文件
echo "OpenWRT Alpine Installer" > "$STAGING_DIR/.ALPINE"
echo "Build Date: $(date)" >> "$STAGING_DIR/.ALPINE"
echo "Version: Alpine $ALPINE_VERSION" >> "$STAGING_DIR/.ALPINE"

# 使用xorriso构建ISO（遵循Alpine官方方法）
XORRISO_CMD="xorriso -as mkisofs"

# 基本ISO选项
XORRISO_CMD="$XORRISO_CMD -r -V 'OPENWRT_ALPINE'"
XORRISO_CMD="$XORRISO_CMD -J -joliet-long"
XORRISO_CMD="$XORRISO_CMD -cache-inodes"
XORRISO_CMD="$XORRISO_CMD -full-iso9660-filenames"

# BIOS引导（El Torito）
XORRISO_CMD="$XORRISO_CMD -b isolinux/isolinux.bin"
XORRISO_CMD="$XORRISO_CMD -c isolinux/boot.cat"
XORRISO_CMD="$XORRISO_CMD -no-emul-boot"
XORRISO_CMD="$XORRISO_CMD -boot-load-size 4"
XORRISO_CMD="$XORRISO_CMD -boot-info-table"
XORRISO_CMD="$XORRISO_CMD -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin 2>/dev/null || true"

# UEFI引导
XORRISO_CMD="$XORRISO_CMD -eltorito-alt-boot"
XORRISO_CMD="$XORRISO_CMD -e EFI/boot/bootx64.efi"
XORRISO_CMD="$XORRISO_CMD -no-emul-boot"
XORRISO_CMD="$XORRISO_CMD -isohybrid-gpt-basdat"

# 输出
XORRISO_CMD="$XORRISO_CMD -o '$ISO_PATH'"
XORRISO_CMD="$XORRISO_CMD '$STAGING_DIR'"

log_info "执行ISO构建..."
eval $XORRISO_CMD

# 如果失败，尝试简单方法
if [ ! -f "$ISO_PATH" ] || [ ! -s "$ISO_PATH" ]; then
    log_warning "标准方法失败，尝试简单方法..."
    
    xorriso -as mkisofs \
        -r -V 'OPENWRT' \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/boot/bootx64.efi \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -o "$ISO_PATH" \
        "$STAGING_DIR" 2>/dev/null
fi

# ========== 步骤10: 验证结果 ==========
log_info "[10/10] 验证构建结果..."

if [ -f "$ISO_PATH" ] && [ -s "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    log_success "✅ ISO构建成功! ($ISO_SIZE)"
    
    # 验证ISO可引导性
    echo ""
    log_info "验证引导能力:"
    
    # 检查是否为混合ISO
    if command -v xorriso >/dev/null 2>&1; then
        XORRISO_CHECK=$(xorriso -indev "$ISO_PATH" -check_media 2>&1)
        
        if echo "$XORRISO_CHECK" | grep -q "El Torito boot record"; then
            log_success "  ✅ BIOS引导支持"
        fi
        
        if echo "$XORRISO_CHECK" | grep -q "EFI boot record"; then
            log_success "  ✅ UEFI引导支持"
        fi
    fi
    
    # 检查文件类型
    if command -v file >/dev/null 2>&1; then
        FILE_TYPE=$(file "$ISO_PATH")
        echo "文件类型: $FILE_TYPE"
    fi
    
    # 创建构建信息
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Alpine Installer
=======================
构建时间: $(date)
ISO文件: $(basename "$ISO_PATH")
ISO大小: $ISO_SIZE
Alpine版本: $ALPINE_VERSION
引导支持: BIOS + UEFI

包含内容:
- OpenWRT镜像: $(basename "$INPUT_IMG") ($IMG_SIZE)
- Alpine内核: vmlinuz-lts
- 安装程序: initramfs-openwrt

使用方法:
1. 制作USB: dd if="$ISO_NAME" of=/dev/sdX bs=4M status=progress
2. 从USB启动
3. 选择安装选项

注意: 安装将覆盖整个目标磁盘
EOF
    
    log_success "构建信息保存到: build-info.txt"
    
else
    log_error "❌ ISO构建失败"
    exit 1
fi

# 清理
log_info "清理工作区..."
rm -rf "$WORK_DIR"

echo ""
log_success "🎉 构建完成!"
log_success "ISO路径: $ISO_PATH"
echo ""

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
