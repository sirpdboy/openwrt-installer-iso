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
FROM alpine:3.20

RUN echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories

RUN apk update

# 安装构建工具（分组安装，避免单个包失败）
# 第1组：基础工具
RUN apk add --no-cache bash curl wget ca-certificates

# 第2组：ISO构建工具
RUN apk add --no-cache xorriso syslinux

# 第3组：引导工具
RUN apk add --no-cache grub grub-efi

# 第4组：文件系统工具
RUN apk add --no-cache e2fsprogs dosfstools mtools

# 5. 分区工具（注意：fdisk 包含在 util-linux 中）
RUN apk add --no-cache parted util-linux

# 6. 压缩和打包工具
RUN apk add --no-cache gzip tar cpio squashfs-tools cdrtools

# 7. 其他必要工具
RUN apk add --no-cache coreutils findutils grep gawk file pv

# 清理缓存
RUN rm -rf /var/cache/apk/*

# 验证工具安装
RUN echo "=== 验证安装的工具 ===" && \
    echo "xorriso: $(xorriso --version 2>/dev/null | head -1 || echo '未安装')" && \
    echo "syslinux: $(which syslinux 2>/dev/null || echo '未安装')" && \
    echo "grub: $(which grub-mkstandalone 2>/dev/null || echo '未安装')" && \
    echo "parted: $(which parted 2>/dev/null || echo '未安装')" && \
    echo "mkisofs: $(which mkisofs 2>/dev/null || which genisoimage 2>/dev/null || echo '使用xorriso')" && \
    echo "=== 验证完成 ==="


# 创建工作目录
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
# build-iso-alpine.sh - OpenWRT ISO构建脚本（基于Alpine）
# 支持BIOS和UEFI双引导

set -e

echo "================================================"
echo "  OpenWRT Alpine Installer - Full Build"
echo "================================================"
echo ""

# 从环境变量获取参数
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt-installer.iso}"
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

# 显示配置信息
log_info "构建配置:"
log_info "  输入镜像: $INPUT_IMG"
log_info "  输出目录: $OUTPUT_DIR"
log_info "  ISO名称: $ISO_NAME"
log_info "  Alpine版本: $ALPINE_VERSION"
echo ""

# ========== 步骤1: 检查输入文件 ==========
log_info "[1/10] 检查输入文件..."
if [ ! -f "$INPUT_IMG" ]; then
    log_error "OpenWRT镜像未找到: $INPUT_IMG"
    exit 1
fi

IMG_SIZE=$(ls -lh "$INPUT_IMG" | awk '{print $5}')
log_success "找到OpenWRT镜像: $IMG_SIZE"

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

# 创建ISO目录结构
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub,isolinux,live,images}

# ========== 步骤3: 获取Alpine内核和initramfs ==========
log_info "[3/10] 获取Alpine内核和initramfs..."

# 下载Alpine内核和initramfs
log_info "下载Alpine内核和initramfs..."
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_BRANCH="v${ALPINE_VERSION}"
ALPINE_ARCH="x86_64"

# 下载内核
KERNEL_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/latest-releases.yaml"
log_info "获取最新版本信息..."

# 尝试多种方式获取最新版本
if command -v curl >/dev/null 2>&1; then
    LATEST_ISO=$(curl -s "$KERNEL_URL" | grep -o "alpine-mini-.*-x86_64.iso" | head -1)
    if [ -z "$LATEST_ISO" ]; then
        LATEST_ISO="alpine-mini-${ALPINE_VERSION}.0-x86_64.iso"
    fi
    LATEST_VERSION=$(echo "$LATEST_ISO" | sed 's/alpine-mini-//' | sed 's/-x86_64.iso//')
else
    LATEST_VERSION="${ALPINE_VERSION}.0"
    LATEST_ISO="alpine-mini-${LATEST_VERSION}-x86_64.iso"
fi

log_info "使用Alpine版本: $LATEST_VERSION"

# 下载mini ISO来提取内核
MINI_ISO_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/${LATEST_ISO}"
log_info "下载Alpine mini ISO: $MINI_ISO_URL"

ISO_TMP="$WORK_DIR/alpine-mini.iso"
if command -v curl >/dev/null 2>&1; then
    curl -L -o "$ISO_TMP" "$MINI_ISO_URL" || {
        log_warning "下载mini ISO失败，使用本地内核..."
        ISO_TMP=""
    }
elif command -v wget >/dev/null 2>&1; then
    wget -O "$ISO_TMP" "$MINI_ISO_URL" || {
        log_warning "下载mini ISO失败，使用本地内核..."
        ISO_TMP=""
    }
else
    log_warning "没有找到curl或wget，使用本地内核..."
    ISO_TMP=""
fi

# 提取内核和initramfs
if [ -f "$ISO_TMP" ] && [ -s "$ISO_TMP" ]; then
    log_info "从mini ISO提取内核..."
    
    # 挂载ISO
    MOUNT_DIR="$WORK_DIR/iso_mount"
    mkdir -p "$MOUNT_DIR"
    
    if mount -o loop "$ISO_TMP" "$MOUNT_DIR" 2>/dev/null; then
        # 复制内核
        if [ -f "$MOUNT_DIR/boot/vmlinuz-lts" ]; then
            cp "$MOUNT_DIR/boot/vmlinuz-lts" "$STAGING_DIR/live/vmlinuz"
            log_success "提取内核: vmlinuz-lts"
        elif [ -f "$MOUNT_DIR/boot/vmlinuz" ]; then
            cp "$MOUNT_DIR/boot/vmlinuz" "$STAGING_DIR/live/vmlinuz"
            log_success "提取内核: vmlinuz"
        fi
        
        # 复制initramfs
        if [ -f "$MOUNT_DIR/boot/initramfs-lts" ]; then
            cp "$MOUNT_DIR/boot/initramfs-lts" "$STAGING_DIR/live/initrd"
            log_success "提取initramfs: initramfs-lts"
        elif [ -f "$MOUNT_DIR/boot/initramfs" ]; then
            cp "$MOUNT_DIR/boot/initramfs" "$STAGING_DIR/live/initrd"
            log_success "提取initramfs: initramfs"
        fi
        
        umount "$MOUNT_DIR"
        rm -rf "$MOUNT_DIR"
    else
        log_warning "无法挂载ISO，使用备用方法..."
    fi
fi

# 如果提取失败，使用本地内核或创建简单initrd
if [ ! -f "$STAGING_DIR/live/vmlinuz" ]; then
    log_info "使用本地内核..."
    # 查找本地内核
    if [ -f /boot/vmlinuz-lts ]; then
        cp /boot/vmlinuz-lts "$STAGING_DIR/live/vmlinuz"
    elif [ -f /boot/vmlinuz ]; then
        cp /boot/vmlinuz "$STAGING_DIR/live/vmlinuz"
    else
        log_error "未找到内核文件"
        exit 1
    fi
fi

if [ ! -f "$STAGING_DIR/live/initrd" ]; then
    log_info "创建最小initrd..."
    create_minimal_initrd "$STAGING_DIR/live/initrd"
fi

# ========== 步骤4: 创建最小initrd函数 ==========
create_minimal_initrd() {
    local initrd_path="$1"
    local initrd_dir="$WORK_DIR/initrd_root"
    
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    
    # 创建init脚本
    cat > "$initrd_dir/init" << 'INIT_EOF'
#!/bin/sh
# OpenWRT Alpine Installer initrd

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# 早期挂载
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# 创建必要的目录
mkdir -p /tmp /mnt /root /proc /sys /dev /run

# 加载必要的模块
modprobe -q isofs 2>/dev/null || true
modprobe -q cdrom 2>/dev/null || true
modprobe -q sr_mod 2>/dev/null || true
modprobe -q loop 2>/dev/null || true
modprobe -q fat 2>/dev/null || true
modprobe -q vfat 2>/dev/null || true

# 寻找安装介质
echo "寻找OpenWRT安装介质..."

# 先尝试挂载光盘
for dev in /dev/sr* /dev/cdrom* /dev/disk/by-label/*; do
    if [ -b "$dev" ]; then
        echo "尝试挂载 $dev..."
        mount -t iso9660 -o ro "$dev" /mnt 2>/dev/null && break
        mount -t udf -o ro "$dev" /mnt 2>/dev/null && break
    fi
done

# 如果失败，尝试挂载USB
if ! mountpoint -q /mnt; then
    for dev in /dev/sd* /dev/mmcblk*; do
        if [ -b "$dev" ] && [ "${dev##*/}" != "sda" ]; then
            echo "尝试挂载 $dev..."
            mount -t iso9660 -o ro "$dev" /mnt 2>/dev/null && break
            mount -t vfat -o ro "$dev" /mnt 2>/dev/null && break
        fi
    done
fi

# 检查OpenWRT镜像
if [ -f "/mnt/images/openwrt.img" ]; then
    echo "✅ 找到OpenWRT镜像: /mnt/images/openwrt.img"
    IMG_PATH="/mnt/images/openwrt.img"
elif [ -f "/mnt/openwrt.img" ]; then
    echo "✅ 找到OpenWRT镜像: /mnt/openwrt.img"
    IMG_PATH="/mnt/openwrt.img"
else
    echo "❌ 未找到OpenWRT镜像"
    echo "挂载点内容:"
    ls -la /mnt/ 2>/dev/null || true
    echo "等待10秒后进入shell..."
    sleep 10
    exec /bin/sh
fi

# 安装菜单
while true; do
    clear
    cat << 'MENU_EOF'

╔══════════════════════════════════════╗
║      OpenWRT Alpine Installer       ║
╚══════════════════════════════════════╝

1) 列出磁盘
2) 安装OpenWRT
3) 进入Shell
4) 重启

选择 [1-4]: 
MENU_EOF
    
    read -n 1 choice
    echo ""
    
    case $choice in
        1)
            echo "可用磁盘:"
            echo "=========="
            lsblk -d -n -o NAME,SIZE,MODEL,TYPE 2>/dev/null || \
            fdisk -l 2>/dev/null || \
            echo "无法列出磁盘"
            echo "=========="
            echo ""
            echo "按Enter键继续..."
            read
            ;;
        2)
            echo "输入目标磁盘 (例如: sda, nvme0n1): "
            read disk
            
            if [ -z "$disk" ]; then
                echo "磁盘名称不能为空"
                sleep 2
                continue
            fi
            
            # 添加/dev/前缀（如果未提供）
            if [[ "$disk" != /dev/* ]]; then
                disk="/dev/$disk"
            fi
            
            if [ ! -b "$disk" ]; then
                echo "❌ 磁盘不存在: $disk"
                sleep 2
                continue
            fi
            
            # 显示磁盘信息
            echo ""
            echo "磁盘信息:"
            if command -v fdisk >/dev/null 2>&1; then
                fdisk -l "$disk" 2>/dev/null | head -20
            fi
            echo ""
            
            # 确认
            echo "⚠️ 警告: 这将擦除 $disk 上的所有数据!"
            echo "输入 'YES' 确认: "
            read confirm
            
            if [ "$confirm" != "YES" ]; then
                echo "操作取消"
                sleep 2
                continue
            fi
            
            # 写入镜像
            echo ""
            echo "正在写入OpenWRT镜像到 $disk ..."
            echo "这可能需要几分钟，请耐心等待..."
            
            # 使用dd写入
            if command -v pv >/dev/null 2>&1; then
                pv "$IMG_PATH" | dd of="$disk" bs=4M
            else
                dd if="$IMG_PATH" of="$disk" bs=4M status=progress
            fi
            
            # 同步并等待
            sync
            echo ""
            echo "✅ 安装完成!"
            echo ""
            echo "10秒后重启..."
            sleep 10
            reboot -f
            ;;
        3)
            echo "进入shell..."
            echo "输入 'exit' 返回菜单"
            exec /bin/sh
            ;;
        4)
            echo "重启系统..."
            sleep 2
            reboot -f
            ;;
        *)
            echo "无效选择"
            sleep 1
            ;;
    esac
done
INIT_EOF

    chmod +x "$initrd_dir/init"
    
    # 复制busybox
    if which busybox >/dev/null 2>&1; then
        cp $(which busybox) "$initrd_dir/busybox"
        cd "$initrd_dir"
        ./busybox --list | while read app; do
            ln -s busybox "$app" 2>/dev/null || true
        done
        cd - >/dev/null
    fi
    
    # 打包initrd
    cd "$initrd_dir"
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$initrd_path"
    cd - >/dev/null
    
    log_success "initrd创建完成: $(du -h "$initrd_path" | cut -f1)"
}

# ========== 步骤5: 复制OpenWRT镜像 ==========
log_info "[4/10] 复制OpenWRT镜像..."
cp "$INPUT_IMG" "$STAGING_DIR/images/openwrt.img"
log_success "OpenWRT镜像已复制: $(du -h "$STAGING_DIR/images/openwrt.img" | cut -f1)"

# ========== 步骤6: 创建ISOLINUX配置 (BIOS引导) ==========
log_info "[5/10] 创建BIOS引导配置..."

cat > "$STAGING_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
UI vesamenu.c32

MENU TITLE OpenWRT Alpine Installer
DEFAULT install
TIMEOUT 30
TIMEOUTTOT 300
MENU RESOLUTION 640 480
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
  MENU LABEL ^Install OpenWRT (BIOS)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=tty0 console=ttyS0,115200

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd console=tty0 init=/bin/sh

LABEL memtest
  MENU LABEL ^Memory Test
  KERNEL /boot/memtest

LABEL local
  MENU LABEL Boot from ^local disk
  LOCALBOOT 0x80
  TIMEOUT 30
ISOLINUX_CFG

# 复制ISOLINUX文件
log_info "复制ISOLINUX文件..."
if [ -d /usr/share/syslinux ]; then
    cp /usr/share/syslinux/isolinux.bin "$STAGING_DIR/isolinux/"
    cp /usr/share/syslinux/ldlinux.c32 "$STAGING_DIR/isolinux/"
    cp /usr/share/syslinux/libutil.c32 "$STAGING_DIR/isolinux/"
    cp /usr/share/syslinux/libcom32.c32 "$STAGING_DIR/isolinux/"
    cp /usr/share/syslinux/menu.c32 "$STAGING_DIR/isolinux/"
    cp /usr/share/syslinux/vesamenu.c32 "$STAGING_DIR/isolinux/"
    cp /usr/share/syslinux/chain.c32 "$STAGING_DIR/isolinux/"
    log_success "ISOLINUX文件复制完成"
else
    log_warning "未找到syslinux文件，尝试从包管理器安装..."
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
log_info "[6/10] 创建UEFI引导配置..."

cat > "$STAGING_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

if loadfont /boot/grub/fonts/unicode.pf2 ; then
    set gfxmode=auto
    insmod efi_gop
    insmod efi_uga
    insmod gfxterm
    terminal_output gfxterm
fi

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Install OpenWRT (UEFI)" {
    linux /live/vmlinuz console=tty0 console=ttyS0,115200
    initrd /live/initrd
}

menuentry "Emergency Shell" {
    linux /live/vmlinuz console=tty0 init=/bin/sh
    initrd /live/initrd
}

menuentry "Boot from local disk" {
    exit
}

menuentry "Reboot" {
    reboot
}

menuentry "Shutdown" {
    halt
}
GRUB_CFG

# ========== 步骤8: 创建UEFI引导文件 ==========
log_info "[7/10] 创建UEFI引导文件..."

# 创建GRUB EFI可执行文件
GRUB_EFI_TMP="$WORK_DIR/grub-efi"
mkdir -p "$GRUB_EFI_TMP"

# 创建grub模块配置文件
cat > "$GRUB_EFI_TMP/grub.cfg" << 'GRUB_MODULES_CFG'
search --file /images/openwrt.img --set=root
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
GRUB_MODULES_CFG

# 生成EFI文件
log_info "生成GRUB EFI可执行文件..."
if command -v grub-mkstandalone >/dev/null 2>&1; then
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$GRUB_EFI_TMP/bootx64.efi" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos fat iso9660 ext2" \
        "boot/grub/grub.cfg=$GRUB_EFI_TMP/grub.cfg"
    
    if [ -f "$GRUB_EFI_TMP/bootx64.efi" ]; then
        log_success "GRUB EFI文件生成成功"
    else
        log_warning "grub-mkstandalone失败，尝试grub-mkimage"
        if command -v grub-mkimage >/dev/null 2>&1; then
            grub-mkimage \
                -O x86_64-efi \
                -o "$GRUB_EFI_TMP/bootx64.efi" \
                -p /boot/grub \
                fat iso9660 part_gpt part_msdos normal boot linux linux16 chain \
                efifwsetup efi_gop efi_uga ls search search_label search_fs_uuid \
                search_fs_file gfxterm gfxterm_background gfxterm_menu test all_video \
                loadenv exfat ext2 btrfs ntfs configfile echo true probe terminal
        fi
    fi
elif command -v grub2-mkstandalone >/dev/null 2>&1; then
    grub2-mkstandalone \
        --format=x86_64-efi \
        --output="$GRUB_EFI_TMP/bootx64.efi" \
        --locales="" \
        --fonts="" \
        --modules="part_gpt part_msdos fat iso9660 ext2" \
        "boot/grub/grub.cfg=$GRUB_EFI_TMP/grub.cfg"
fi

# 复制EFI文件
if [ -f "$GRUB_EFI_TMP/bootx64.efi" ]; then
    cp "$GRUB_EFI_TMP/bootx64.efi" "$STAGING_DIR/EFI/boot/"
    log_success "UEFI引导文件已复制"
else
    log_error "无法生成UEFI引导文件"
    exit 1
fi

# ========== 步骤9: 创建ISO ==========
log_info "[8/10] 构建ISO镜像..."

# 创建标识文件
echo "OpenWRT Alpine Installer" > "$STAGING_DIR/OPENWRT_ALPINE"
echo "Build Date: $(date)" >> "$STAGING_DIR/OPENWRT_ALPINE"
echo "Alpine Version: $ALPINE_VERSION" >> "$STAGING_DIR/OPENWRT_ALPINE"

# 查找isohdpfx.bin
ISOHDPFX=""
for path in /usr/share/syslinux/isohdpfx.bin /usr/lib/syslinux/isohdpfx.bin; do
    if [ -f "$path" ]; then
        ISOHDPFX="$path"
        break
    fi
done

if [ -z "$ISOHDPFX" ]; then
    log_warning "未找到isohdpfx.bin，安装syslinux..."
    apk add --no-cache syslinux 2>/dev/null || true
    for path in /usr/share/syslinux/isohdpfx.bin /usr/lib/syslinux/isohdpfx.bin; do
        if [ -f "$path" ]; then
            ISOHDPFX="$path"
            break
        fi
    done
fi

log_info "使用xorriso构建ISO..."

# 构建命令
XORRISO_CMD="xorriso -as mkisofs"

# 基本选项
XORRISO_CMD="$XORRISO_CMD -r -V 'OPENWRT_ALPINE'"
XORRISO_CMD="$XORRISO_CMD -J -joliet-long"
XORRISO_CMD="$XORRISO_CMD -cache-inodes"
XORRISO_CMD="$XORRISO_CMD -full-iso9660-filenames"

# BIOS引导选项
XORRISO_CMD="$XORRISO_CMD -b isolinux/isolinux.bin"
XORRISO_CMD="$XORRISO_CMD -c isolinux/boot.cat"
XORRISO_CMD="$XORRISO_CMD -no-emul-boot"
XORRISO_CMD="$XORRISO_CMD -boot-load-size 4"
XORRISO_CMD="$XORRISO_CMD -boot-info-table"

# UEFI引导选项
XORRISO_CMD="$XORRISO_CMD -eltorito-alt-boot"
XORRISO_CMD="$XORRISO_CMD -e EFI/boot/bootx64.efi"
XORRISO_CMD="$XORRISO_CMD -no-emul-boot"
XORRISO_CMD="$XORRISO_CMD -isohybrid-gpt-basdat"

# 如果找到isohdpfx.bin，添加混合MBR支持
if [ -n "$ISOHDPFX" ]; then
    XORRISO_CMD="$XORRISO_CMD -isohybrid-mbr $ISOHDPFX"
    log_info "启用混合MBR支持"
fi

# 输出文件和源目录
XORRISO_CMD="$XORRISO_CMD -o '$ISO_PATH'"
XORRISO_CMD="$XORRISO_CMD '$STAGING_DIR'"

# 执行构建
log_info "执行: $XORRISO_CMD"
eval $XORRISO_CMD

# ========== 步骤10: 验证结果 ==========
log_info "[9/10] 验证构建结果..."

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    log_success "✅ ISO构建成功! ($ISO_SIZE)"
    
    # 显示ISO信息
    echo ""
    log_info "ISO详细信息:"
    log_info "  文件: $ISO_PATH"
    log_info "  大小: $ISO_SIZE"
    
    # 检查引导能力
    echo ""
    log_info "引导能力检查:"
    
    if command -v file >/dev/null 2>&1; then
        FILE_INFO=$(file "$ISO_PATH")
        log_info "  文件类型: $FILE_INFO"
        
        if echo "$FILE_INFO" | grep -q "bootable\|DOS/MBR"; then
            log_success "  ✅ BIOS引导支持"
        fi
        
        if echo "$FILE_INFO" | grep -q "UEFI\|EFI"; then
            log_success "  ✅ UEFI引导支持"
        fi
    fi
    
    # 检查ISO内容
    echo ""
    log_info "ISO内容摘要:"
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -indev "$ISO_PATH" -toc 2>/dev/null | head -20
    elif command -v isoinfo >/dev/null 2>&1; then
        isoinfo -d -i "$ISO_PATH" 2>/dev/null
    fi
    
    # 创建构建信息文件
    cat > "$OUTPUT_DIR/build-info.txt" << EOF
OpenWRT Alpine Installer ISO
============================
构建时间:     $(date)

ISO信息:
  文件:      $(basename "$ISO_PATH")
  大小:      $ISO_SIZE
  版本:      Alpine $ALPINE_VERSION
  引导支持:  BIOS + UEFI

镜像信息:
  原始镜像:  $(basename "$INPUT_IMG")
  镜像大小:  $IMG_SIZE

使用方法:
  1. 制作USB: dd if="$ISO_NAME" of=/dev/sdX bs=4M status=progress
  2. 虚拟机:  qemu-system-x86_64 -cdrom "$ISO_NAME" -m 512M
  3. 从USB或光盘启动
  4. 选择安装选项

项目地址: https://github.com/sirpdboy/openwrt-installer-iso.git
EOF
    
    log_success "构建信息保存到: $OUTPUT_DIR/build-info.txt"
    
else
    log_error "❌ ISO文件未创建: $ISO_PATH"
    exit 1
fi

# ========== 清理工作区 ==========
log_info "[10/10] 清理工作区..."
rm -rf "$WORK_DIR"
log_success "工作区已清理"

echo ""
log_success "🎉 所有步骤完成!"
log_success "ISO已创建: $ISO_PATH"
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
@@ -566,12 +622,13 @@
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
@@ -594,46 +651,39 @@
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

    exit 0
else
    echo ""
    echo "❌ ISO构建失败"

    # 显示容器日志
    echo "📋 容器日志:"
    docker logs --tail 100 openwrt-alpine-builder 2>/dev/null || echo "无法获取容器日志"






    exit 1
fi
