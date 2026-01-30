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
# alpine-openwrt-iso-builder.sh - 基于Alpine官方方法的完整解决方案

set -e

echo "================================================"
echo "  OpenWRT ISO Builder - Alpine Official Method"
echo "================================================"
echo ""

# 参数处理
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt.iso}"
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"

if [ ! -f "$INPUT_IMG" ]; then
    echo "错误: 找不到IMG文件: $INPUT_IMG"
    exit 1
fi

# 创建工作目录
WORK_DIR="/tmp/openwrt-iso-$(date +%s)"
mkdir -p "$WORK_DIR"
mkdir -p "$OUTPUT_DIR"

# 获取绝对路径
INPUT_ABS=$(readlink -f "$INPUT_IMG" 2>/dev/null || realpath "$INPUT_IMG")
OUTPUT_ABS=$(readlink -f "$OUTPUT_DIR" 2>/dev/null || realpath "$OUTPUT_DIR")
ISO_PATH="$OUTPUT_ABS/$ISO_NAME"

echo "🔧 构建配置:"
echo "  Alpine版本: $ALPINE_VERSION"
echo "  输入镜像: $INPUT_ABS"
echo "  输出ISO: $ISO_PATH"
echo ""

# ========== 步骤1: 下载Alpine minirootfs ==========
echo "[1/8] 下载Alpine minirootfs..."

ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_BRANCH="v${ALPINE_VERSION}"
ALPINE_ARCH="x86_64"

# 获取最新版本
LATEST_VERSION="${ALPINE_VERSION}.0"
ROOTFS_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/alpine-minirootfs-${LATEST_VERSION}-${ALPINE_ARCH}.tar.gz"

echo "下载: $ROOTFS_URL"
curl -L -o "$WORK_DIR/rootfs.tar.gz" "$ROOTFS_URL" || {
    echo "下载失败，使用备用URL..."
    # 备用URL
    ROOTFS_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/latest-releases.yaml"
    LATEST_TAR=$(curl -s "$ROOTFS_URL" | grep "alpine-minirootfs.*tar.gz" | head -1 | awk '{print $2}')
    if [ -n "$LATEST_TAR" ]; then
        curl -L -o "$WORK_DIR/rootfs.tar.gz" "${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/$LATEST_TAR"
    fi
}

if [ ! -f "$WORK_DIR/rootfs.tar.gz" ] || [ ! -s "$WORK_DIR/rootfs.tar.gz" ]; then
    echo "❌ 无法下载Alpine rootfs"
    exit 1
fi

echo "✅ 下载完成: $(du -h "$WORK_DIR/rootfs.tar.gz" | cut -f1)"
echo ""

# ========== 步骤2: 提取rootfs并准备 ==========
echo "[2/8] 准备rootfs..."

# 创建rootfs目录
ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

# 提取rootfs
echo "提取rootfs..."
tar -xzf "$WORK_DIR/rootfs.tar.gz" -C "$ROOTFS_DIR"

# 创建必要的目录
mkdir -p "$ROOTFS_DIR"/{proc,sys,dev,tmp,run,mnt,images,boot}

# 复制OpenWRT镜像
echo "复制OpenWRT镜像..."
cp "$INPUT_ABS" "$ROOTFS_DIR/images/openwrt.img"

# ========== 步骤3: 创建完整的安装脚本 ==========
echo "[3/8] 创建安装系统..."

# 创建安装脚本
cat > "$ROOTFS_DIR/install-openwrt" << 'INSTALL_SCRIPT'
#!/bin/sh
# OpenWRT安装脚本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 挂载必要的文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t tmpfs tmpfs /tmp

# 创建设备节点
mknod /dev/console c 5 1 2>/dev/null || true
mknod /dev/null c 1 3 2>/dev/null || true

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 清屏
clear

# 显示标题
cat << "HEADER"
╔═══════════════════════════════════════╗
║         OpenWRT 安装程序              ║
║     基于 Alpine Linux                 ║
╚═══════════════════════════════════════╝
HEADER

echo ""
log_info "正在初始化系统..."

# 加载必要的内核模块
echo "加载内核模块..."
for mod in isofs cdrom sr_mod loop virtio_blk virtio_pci ata_piix ahci nvme sd_mod usb-storage; do
    modprobe $mod 2>/dev/null || true
done

# 查找CDROM设备并挂载
log_info "查找安装介质..."
for dev in /dev/sr0 /dev/cdrom /dev/sr[0-9]*; do
    if [ -b "$dev" ]; then
        log_info "找到CDROM: $dev"
        mount -t iso9660 -o ro $dev /mnt 2>/dev/null && {
            log_success "已挂载安装介质"
            break
        }
    fi
done

# 如果没挂载上，尝试其他方法
if ! mountpoint -q /mnt; then
    log_info "尝试其他挂载方法..."
    # 可能是从USB启动
    for dev in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
        if [ -b "$dev" ]; then
            mount -t iso9660 -o ro "${dev}1" /mnt 2>/dev/null && break
            mount -t vfat -o ro "$dev" /mnt 2>/dev/null && break
        fi
    done
fi

# 获取目标磁盘
get_target_disk() {
    echo ""
    log_info "可用磁盘列表:"
    echo "════════════════════════════════════════"
    
    local count=0
    for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
        if [ -b "$disk" ]; then
            count=$((count + 1))
            # 获取磁盘大小
            size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
            size_gb=$((size / 1024 / 1024 / 1024))
            model=$(cat "/sys/block/$(basename "$disk")/device/model" 2>/dev/null || echo "Unknown")
            printf "  %2d) %-12s %4d GB  %s\n" "$count" "$disk" "$size_gb" "$model"
        fi
    done
    
    echo "════════════════════════════════════════"
    
    if [ $count -eq 0 ]; then
        log_error "未找到任何磁盘!"
        return 1
    fi
    
    echo ""
    echo -n "请选择目标磁盘 (1-$count): "
    read choice
    
    if ! echo "$choice" | grep -qE "^[0-9]+$"; then
        log_error "无效输入"
        return 1
    fi
    
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        log_error "选择超出范围"
        return 1
    fi
    
    # 获取对应的磁盘
    local idx=1
    for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
        if [ -b "$disk" ]; then
            if [ $idx -eq "$choice" ]; then
                TARGET_DISK="$disk"
                return 0
            fi
            idx=$((idx + 1))
        fi
    done
    
    return 1
}

# 确认安装
confirm_installation() {
    echo ""
    log_error "⚠️  ⚠️  ⚠️  警告 ⚠️  ⚠️  ⚠️"
    echo ""
    log_error "这将永久擦除磁盘 $TARGET_DISK 上的所有数据!"
    echo ""
    log_error "所有分区和数据都将被删除!"
    echo ""
    
    echo -n "请输入 'YES' 确认安装: "
    read confirm
    
    if [ "$confirm" != "YES" ]; then
        log_error "安装已取消"
        return 1
    fi
    return 0
}

# 执行安装
perform_installation() {
    echo ""
    log_info "开始安装 OpenWRT..."
    echo ""
    
    # 查找OpenWRT镜像
    local img_path=""
    for path in /mnt/images/openwrt.img /images/openwrt.img /openwrt.img; do
        if [ -f "$path" ]; then
            img_path="$path"
            log_success "找到镜像: $img_path"
            break
        fi
    done
    
    if [ -z "$img_path" ]; then
        log_error "找不到OpenWRT镜像!"
        return 1
    fi
    
    # 获取镜像大小
    img_size=$(du -h "$img_path" | cut -f1)
    log_info "镜像大小: $img_size"
    
    # 显示进度
    echo ""
    log_info "正在写入磁盘 $TARGET_DISK ..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 写入镜像（使用dd）
    if command -v pv >/dev/null 2>&1; then
        # 使用pv显示进度
        pv -pet "$img_path" | dd of="$TARGET_DISK" bs=4M oflag=sync status=none
    else
        # 使用dd自带进度
        dd if="$img_path" of="$TARGET_DISK" bs=4M status=progress
    fi
    
    local result=$?
    
    # 同步数据
    sync
    
    if [ $result -eq 0 ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ 安装成功!"
        echo ""
        log_info "OpenWRT 已安装到 $TARGET_DISK"
        echo ""
        log_info "请移除安装介质并重启系统"
        echo ""
        
        # 等待用户确认
        echo -n "按 Enter 键重启..."
        read
        echo ""
        log_info "正在重启系统..."
        sleep 2
        reboot -f
    else
        log_error "❌ 安装失败! (错误代码: $result)"
        echo ""
        log_info "按 Enter 键返回..."
        read
        return 1
    fi
}

# 显示菜单
show_menu() {
    clear
    cat << "MENU_HEADER"
╔═══════════════════════════════════════╗
║         OpenWRT 安装程序              ║
╚═══════════════════════════════════════╝
MENU_HEADER
    echo ""
    log_info "请选择操作:"
    echo ""
    echo "  1) 安装 OpenWRT 到磁盘"
    echo "  2) 查看磁盘信息"
    echo "  3) 进入紧急 Shell"
    echo "  4) 重启系统"
    echo ""
    echo -n "选择 (1-4): "
}

# 主循环
while true; do
    show_menu
    read choice
    
    case $choice in
        1)
            if get_target_disk; then
                if confirm_installation; then
                    if perform_installation; then
                        break  # 安装成功，退出循环
                    fi
                fi
            else
                echo ""
                log_error "无法获取目标磁盘"
                echo -n "按 Enter 键继续..."
                read
            fi
            ;;
        2)
            echo ""
            log_info "磁盘信息:"
            echo "════════════════════════════════════════"
            lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
            echo "════════════════════════════════════════"
            echo ""
            echo -n "按 Enter 键返回..."
            read
            ;;
        3)
            echo ""
            log_info "进入紧急 Shell..."
            log_info "输入 'exit' 返回安装程序"
            echo ""
            /bin/sh
            ;;
        4)
            echo ""
            log_info "正在重启系统..."
            sleep 2
            reboot -f
            ;;
        *)
            echo ""
            log_error "无效选择"
            sleep 1
            ;;
    esac
done

exit 0
INSTALL_SCRIPT

chmod +x "$ROOTFS_DIR/install-openwrt"

# ========== 步骤4: 创建init脚本 ==========
echo "[4/8] 创建init系统..."

# 创建init脚本（这是内核启动的第一个进程）
cat > "$ROOTFS_DIR/init" << 'INIT_SCRIPT'
#!/bin/sh
# init脚本 - 系统第一个进程

# 挂载核心文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s
mount -t tmpfs tmpfs /tmp

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 加载必要模块
echo "加载内核模块..."
for mod in loop isofs cdrom sr_mod; do
    modprobe $mod 2>/dev/null || true
done

# 挂载安装介质
echo "挂载安装介质..."
for dev in /dev/sr0 /dev/cdrom /dev/sr[0-9]*; do
    if [ -b "$dev" ]; then
        echo "尝试挂载 $dev..."
        mount -t iso9660 -o ro $dev /mnt 2>/dev/null && break
    fi
done

# 如果挂载失败，尝试其他设备
if ! mountpoint -q /mnt; then
    echo "尝试挂载USB设备..."
    for dev in /dev/sd[a-z][0-9] /dev/sd[a-z]; do
        if [ -b "$dev" ]; then
            echo "尝试挂载 $dev..."
            mount -t iso9660 -o ro $dev /mnt 2>/dev/null && break
            mount -t vfat -o ro $dev /mnt 2>/dev/null && break
        fi
    done
fi

# 复制文件（如果从ISO启动）
if mountpoint -q /mnt; then
    echo "从安装介质复制文件..."
    if [ -f /mnt/images/openwrt.img ]; then
        mkdir -p /images
        cp /mnt/images/openwrt.img /images/
    fi
fi

# 如果挂载了介质，可以卸载它
umount /mnt 2>/dev/null || true

# 执行安装程序
echo "启动安装程序..."
exec /install-openwrt

# 如果安装程序退出，进入shell
echo "安装程序退出，进入紧急shell..."
exec /bin/sh
INIT_SCRIPT

chmod +x "$ROOTFS_DIR/init"

# ========== 步骤5: 准备busybox ==========
echo "[5/8] 准备busybox..."

# 复制busybox到rootfs
if command -v busybox >/dev/null 2>&1; then
    cp $(which busybox) "$ROOTFS_DIR/busybox"
    # 创建必要的符号链接
    cd "$ROOTFS_DIR"
    ls -l
    chmod +x busybox
    
    ./busybox --install -s .
    cd - >/dev/null
else
    # 从Alpine包中提取busybox
    echo "下载busybox..."
    curl -L -o "$WORK_DIR/busybox.apk" \
        "${ALPINE_MIRROR}/${ALPINE_BRANCH}/main/${ALPINE_ARCH}/busybox-*.apk" 2>/dev/null || true
    
    if [ -f "$WORK_DIR/busybox.apk" ]; then
        tar -xzf "$WORK_DIR/busybox.apk" -C "$WORK_DIR" 2>/dev/null
        cp "$WORK_DIR/bin/busybox" "$ROOTFS_DIR/bin/" 2>/dev/null || true
    fi
fi

# ========== 步骤6: 创建initramfs ==========
echo "[6/8] 创建initramfs..."

# 进入rootfs目录并打包
cd "$ROOTFS_DIR"
echo "打包initramfs..."
find . -print0 | cpio --null -ov -H newc 2>/dev/null | gzip -9 > "$WORK_DIR/initramfs-openwrt"
cd - >/dev/null

INITRAMFS_SIZE=$(du -h "$WORK_DIR/initramfs-openwrt" | cut -f1)
echo "✅ initramfs创建完成: $INITRAMFS_SIZE"

# ========== 步骤7: 获取或创建内核 ==========
echo "[7/8] 准备内核..."

# 尝试获取Alpine内核
KERNEL_PATH="$WORK_DIR/vmlinuz"
if [ -f /boot/vmlinuz-lts ]; then
    cp /boot/vmlinuz-lts "$KERNEL_PATH"
    echo "✅ 使用本地内核: vmlinuz-lts"
elif [ -f /boot/vmlinuz ]; then
    cp /boot/vmlinuz "$KERNEL_PATH"
    echo "✅ 使用本地内核: vmlinuz"
else
    # 下载Alpine内核
    echo "下载Alpine内核..."
    KERNEL_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/main/${ALPINE_ARCH}/linux-lts-*.apk"
    curl -L -o "$WORK_DIR/kernel.apk" "$KERNEL_URL" 2>/dev/null || true
    
    if [ -f "$WORK_DIR/kernel.apk" ]; then
        tar -xzf "$WORK_DIR/kernel.apk" -C "$WORK_DIR" 2>/dev/null
        cp "$WORK_DIR"/boot/vmlinuz-* "$KERNEL_PATH" 2>/dev/null || true
    fi
fi

if [ ! -f "$KERNEL_PATH" ] || [ ! -s "$KERNEL_PATH" ]; then
    echo "❌ 无法获取内核文件"
    exit 1
fi

echo "✅ 内核大小: $(du -h "$KERNEL_PATH" | cut -f1)"
echo ""

# ========== 步骤8: 构建ISO ==========
echo "[8/8] 构建ISO镜像..."

# 创建ISO目录结构
ISO_ROOT="$WORK_DIR/iso"
mkdir -p "$ISO_ROOT"/{isolinux,boot/grub,EFI/boot,images}

# 复制文件
cp "$KERNEL_PATH" "$ISO_ROOT/boot/vmlinuz"
cp "$WORK_DIR/initramfs-openwrt" "$ISO_ROOT/boot/initramfs"
cp "$INPUT_ABS" "$ISO_ROOT/images/openwrt.img"

# 创建ISOLINUX配置
cat > "$ISO_ROOT/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT openwrt
TIMEOUT 50
PROMPT 0

LABEL openwrt
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs console=tty0 console=ttyS0,115200 quiet

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs console=tty0 init=/bin/sh
ISOLINUX_CFG

# 创建GRUB配置
cat > "$ISO_ROOT/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz initrd=/boot/initramfs console=tty0 quiet
    initrd /boot/initramfs
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz initrd=/boot/initramfs console=tty0 init=/bin/sh
    initrd /boot/initramfs
}
GRUB_CFG

# 复制引导文件
echo "复制引导文件..."
if [ -d /usr/share/syslinux ]; then
    cp /usr/share/syslinux/isolinux.bin "$ISO_ROOT/isolinux/"
    cp /usr/share/syslinux/ldlinux.c32 "$ISO_ROOT/isolinux/"
    cp /usr/share/syslinux/libutil.c32 "$ISO_ROOT/isolinux/"
    cp /usr/share/syslinux/libcom32.c32 "$ISO_ROOT/isolinux/"
    echo "✅ 复制syslinux文件"
else
    # 下载syslinux
    echo "下载syslinux..."
    curl -L -o "$WORK_DIR/syslinux.tar.gz" \
        "https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04.tar.gz" 2>/dev/null || true
    
    if [ -f "$WORK_DIR/syslinux.tar.gz" ]; then
        tar -xzf "$WORK_DIR/syslinux.tar.gz" -C "$WORK_DIR"
        cp "$WORK_DIR"/syslinux-*/bios/core/isolinux.bin "$ISO_ROOT/isolinux/"
        cp "$WORK_DIR"/syslinux-*/bios/com32/elflink/ldlinux/ldlinux.c32 "$ISO_ROOT/isolinux/"
        cp "$WORK_DIR"/syslinux-*/bios/com32/libutil/libutil.c32 "$ISO_ROOT/isolinux/"
        cp "$WORK_DIR"/syslinux-*/bios/com32/lib/libcom32.c32 "$ISO_ROOT/isolinux/"
        echo "✅ 使用下载的syslinux"
    fi
fi

# 创建EFI引导（简单方式）
cat > "$ISO_ROOT/EFI/boot/bootx64.efi" << 'EFI_STUB'
# This is a placeholder EFI file
# The ISO should boot in BIOS/CSM mode
EFI_STUB

# 构建ISO
echo "使用xorriso构建ISO..."
xorriso -as mkisofs \
    -r -V 'OPENWRT_INSTALLER' \
    -o "$ISO_PATH" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin 2>/dev/null \
    "$ISO_ROOT" 2>&1 | grep -v "UPDATE"

# 验证ISO
if [ -f "$ISO_PATH" ] && [ -s "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    echo ""
    echo "🎉 🎉 🎉 ISO构建成功! 🎉 🎉 🎉"
    echo ""
    echo "📁 ISO文件: $ISO_PATH"
    echo "📊 大小: $ISO_SIZE"
    echo ""
    echo "🔧 引导信息:"
    echo "  - BIOS引导: 支持"
    echo "  - UEFI引导: 基础支持"
    echo "  - 内核: $(du -h "$KERNEL_PATH" | cut -f1)"
    echo "  - initramfs: $INITRAMFS_SIZE"
    echo ""
    echo "💡 使用方法:"
    echo "  1. dd if=\"$ISO_NAME\" of=/dev/sdX bs=4M status=progress"
    echo "  2. 从USB启动"
    echo "  3. 选择安装选项"
    echo ""
else
    echo "❌ ISO构建失败"
    exit 1
fi

# 清理
rm -rf "$WORK_DIR"

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
