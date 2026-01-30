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

# 创建ISO目录结构
mkdir -p "$STAGING_DIR"/{EFI/boot,boot/grub,isolinux,live,images}
echo ""

create_initrd() {
    local initrd_dir="$1"
    
    # 创建极简的 init 脚本
    cat > "$initrd_dir/init" << 'INIT_EOF'
#!/bin/busybox sh
# 终极简单 init

# 挂载必要的文件系统
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t tmpfs tmpfs /tmp

# 创建设备
/bin/busybox mkdir -p /dev
/bin/busybox mknod /dev/console c 5 1
/bin/busybox mknod /dev/null c 1 3
/bin/busybox mknod /dev/tty c 5 0

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console


# 加载必要模块
echo "加载必要模块..."
for mod in isofs cdrom sr_mod loop fat vfat; do
    modprobe $mod 2>/dev/null || true
done

# 挂载安装介质
echo "挂载安装介质..."
for dev in /dev/sr0 /dev/cdrom /dev/sd[a-z]; do
    if [ -b "$dev" ]; then
        mount -t iso9660 -o ro "$dev" /mnt 2>/dev/null && break
    fi
done

# 查找 OpenWRT 镜像
find_image() {
    for path in /mnt/images/openwrt.img /mnt/openwrt.img /images/openwrt.img; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

# 显示界面
show_header() {
    clear
    echo "========================================"
    echo "      OpenWRT 系统安装程序"
    echo "========================================"
    echo ""
}

# 主安装函数
main_install() {
    local img_path="$1"
    
    show_header
    
    # 第一步：输入目标磁盘
    echo "第一步：输入目标磁盘"
    echo "-------------------"
    echo ""
    echo "可用磁盘列表:"
    echo "-------------"
    
    # 简单列出磁盘
    for dev in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
        if [ -b "$dev" ]; then
            echo "  $dev"
        fi
    done
    
    echo "-------------"
    echo ""
    echo "请输入目标磁盘名称（例如：sda, nvme0n1）："
    read disk_name
    
    if [ -z "$disk_name" ]; then
        echo "错误：磁盘名称不能为空"
        sleep 2
        return 1
    fi
    
    # 添加 /dev/ 前缀
    if [[ "$disk_name" != /dev/* ]]; then
        disk_name="/dev/$disk_name"
    fi
    
    if [ ! -b "$disk_name" ]; then
        echo "错误：磁盘 $disk_name 不存在"
        sleep 2
        return 1
    fi
    
    # 第二步：确认安装
    show_header
    echo "第二步：确认安装"
    echo "---------------"
    echo ""
    echo "您选择了磁盘：$disk_name"
    echo ""
    echo "⚠️  警告：这将永久擦除 $disk_name 上的所有数据！"
    echo ""
    echo "请输入 YES 确认安装，输入其他内容取消："
    read confirm
    
    if [ "$confirm" != "YES" ]; then
        echo "安装已取消"
        sleep 2
        return 1
    fi
    
    # 开始安装
    show_header
    echo "正在安装 OpenWRT..."
    echo ""
    echo "源镜像：$(basename "$img_path")"
    echo "目标盘：$disk_name"
    echo ""
    echo "正在写入，请稍候..."
    echo ""
    
    # 写入镜像
    if command -v pv >/dev/null 2>&1; then
        pv "$img_path" | dd of="$disk_name" bs=4M
    else
        dd if="$img_path" of="$disk_name" bs=4M status=progress 2>/dev/null || \
        dd if="$img_path" of="$disk_name" bs=4M
    fi
    
    if [ $? -eq 0 ]; then
        sync
        echo ""
        echo "✅ 安装成功！"
        echo ""
        echo "OpenWRT 已安装到 $disk_name"
        echo ""
        echo "系统将在 10 秒后重启..."
        echo ""
        
        # 倒计时
        for i in $(seq 10 -1 1); do
            echo -ne "倒计时: ${i} 秒...\r"
            sleep 1
        done
        
        echo ""
        echo "正在重启..."
        reboot -f
    else
        echo ""
        echo "❌ 安装失败！"
        echo ""
        echo "按 Enter 键重新开始..."
        read
        return 1
    fi
}

# 主程序
main() {
    echo "初始化安装环境..."
    sleep 1
    
    # 查找镜像
    local img_path=$(find_image)
    if [ $? -ne 0 ]; then
        show_header
        echo "错误：找不到 OpenWRT 镜像"
        echo ""
        echo "请检查安装介质是否正确"
        echo "按 Enter 键进入紧急模式..."
        read
        exec /bin/sh
    fi
    
    # 循环运行安装程序（失败时重试）
    while true; do
        if main_install "$img_path"; then
            break  # 安装成功，退出循环
        fi
    done
}

# 运行主程序
main
INIT_EOF

    chmod +x "$initrd_dir/init"
}

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
    LATEST_ISO=$(curl -s "$KERNEL_URL" | grep -o "alpine-standard-.*-x86_64.iso" | head -1)
    if [ -z "$LATEST_ISO" ]; then
        LATEST_ISO="alpine-standard-${ALPINE_VERSION}.9-x86_64.iso"
    fi
    LATEST_VERSION=$(echo "$LATEST_ISO" | sed 's/alpine-standard-//' | sed 's/-x86_64.iso//')
else
    LATEST_VERSION="${ALPINE_VERSION}.9"
    LATEST_ISO="alpine-standard-${LATEST_VERSION}-x86_64.iso"
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
        
        
	# 提取 initramfs
if [ -f "$MOUNT_DIR/boot/initramfs-lts" ]; then
    log_info "使用 Alpine initramfs 并修改..."
    
    # 解压 initramfs
    INITRD_DIR="$WORK_DIR/initrd_extract"
    rm -rf "$INITRD_DIR"
    mkdir -p "$INITRD_DIR"
    
    log_info "解压 initramfs..."
    cd "$INITRD_DIR"
    
    # 尝试解压
    if gzip -dc "$MOUNT_DIR/boot/initramfs-lts" 2>/dev/null | cpio -id 2>/dev/null; then
        log_success "解压成功"
    else
        log_warning "标准解压失败，尝试其他方法..."
        # 尝试直接复制
        cp "$MOUNT_DIR/boot/initramfs-lts" "$STAGING_DIR/live/initrd"
        # 使用 create_minimal_initrd 创建
        create_minimal_initrd "$STAGING_DIR/live/initrd"
        cd - >/dev/null
        umount "$MOUNT_DIR" 2>/dev/null || true
        rm -rf "$MOUNT_DIR"
        continue
    fi
    cd - >/dev/null
    # 备份原来的 init
    if [ -f "$INITRD_DIR/init" ]; then
        mv "$INITRD_DIR/init" "$INITRD_DIR/init.alpine"
        log_info "备份原 init 脚本"
    fi
    # 写入我们简化的 init 脚本
    create_initrd "$INITRD_DIR"
      
    # 3. 复制 busybox
    if command -v busybox >/dev/null 2>&1; then
        cp $(which busybox) "$INITRD_DIR/busybox"
        cd "$INITRD_DIR"
        
        # 创建最少符号链接
        for app in sh echo cat mount umount ls mkdir mknod sleep ls dd sync reboot; do
            ln -s busybox "$app" 2>/dev/null || true
        done
        
        cd - >/dev/null
    else
        log_error "错误: 找不到 busybox"
        return 1
    fi
     mkdir -p "$INITRD_DIR"/{proc,sys,dev,tmp,run,mnt,images,bin,sbin}

    
    # 确保有设备节点
    if [ ! -c "$INITRD_DIR/dev/console" ]; then
        mkdir -p "$INITRD_DIR/dev"
        mknod "$INITRD_DIR/dev/console" c 5 1 2>/dev/null || true
        mknod "$INITRD_DIR/dev/null" c 1 3 2>/dev/null || true
    fi
    
    log_info "重新打包 initrd..."
    cd "$INITRD_DIR"
    # 使用最简单的 cpio 命令
    echo "init" > list.txt
    echo "busybox" >> list.txt
    
    
    # 方法1：使用简单的 find
    # find . -type f -o -type d | cpio -ov -H newc 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd"
    
    # find . -print0 | cpio --null -ov -H newc 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd"
    
    cpio -ov -H newc < list.txt 2>/dev/null | gzip -9 > "$STAGING_DIR/live/initrd"
    cd - >/dev/null

    # 验证
    if [ -f "$STAGING_DIR/live/initrd" ] && [ -s "$STAGING_DIR/live/initrd" ]; then
        log_success "终极 initrd 创建成功: $(du -h "$STAGING_DIR/live/initrd" | cut -f1)"
        return 0
    else
        log_error "终极 initrd 创建失败"
        return 1
    fi
    cd - >/dev/null
    rm -rf "$INITRD_DIR"
fi
	
        umount "$MOUNT_DIR"
        rm -rf "$MOUNT_DIR"
    else
        log_warning "无法挂载ISO，使用备用方法..."
    fi
fi
# 测试 initrd 是否能正常启动
test_initrd() {
    local initrd_file="$1"
    
    log_info "测试 initrd: $initrd_file"
    
    # 1. 检查文件是否存在
    if [ ! -f "$initrd_file" ]; then
        log_error "initrd 文件不存在"
        return 1
    fi
    
    # 2. 检查文件大小
    local size=$(du -h "$initrd_file" | cut -f1)
    if [ "$size" = "0" ]; then
        log_error "initrd 文件大小为 0"
        return 1
    fi
    
    log_success "文件大小: $size"
    
    # 3. 检查是否能解压
    local test_dir="$WORK_DIR/test_initrd"
    rm -rf "$test_dir"
    mkdir -p "$test_dir"
    
    if gzip -dc "$initrd_file" 2>/dev/null | cpio -id -D "$test_dir" 2>/dev/null; then
        log_success "✅ initrd 可以正常解压"
    else
        log_error "❌ initrd 无法解压"
        return 1
    fi
    
    # 4. 检查是否有 init 文件
    if [ -f "$test_dir/init" ]; then
        log_success "✅ 找到 init 文件"
        
        # 检查 init 文件权限
        if [ -x "$test_dir/init" ]; then
            log_success "✅ init 文件可执行"
        else
            log_error "❌ init 文件不可执行"
            chmod +x "$test_dir/init" 2>/dev/null || true
        fi
        
        # 检查 shebang
        local first_line=$(head -1 "$test_dir/init" 2>/dev/null)
        if echo "$first_line" | grep -q "^#!/"; then
            log_success "✅ init 有正确的 shebang: $first_line"
        else
            log_warning "⚠ init 缺少 shebang，修复中..."
            sed -i '1i#!/bin/sh' "$test_dir/init" 2>/dev/null || true
        fi
        
        # 查看 init 文件大小
        local init_size=$(wc -l < "$test_dir/init" 2>/dev/null)
        log_info "init 文件行数: $init_size"
        
    else
        log_error "❌ 未找到 init 文件"
        log_info "目录内容:"
        find "$test_dir" -type f | head -10
        return 1
    fi
    
    # 5. 检查是否有 busybox
    if [ -f "$test_dir/busybox" ] || [ -f "$test_dir/bin/busybox" ]; then
        log_success "✅ 找到 busybox"
    else
        log_error "❌ 未找到 busybox"
        log_info "可用工具:"
        find "$test_dir" -type f -executable | head -10
    fi
    
    # 6. 测试 init 脚本
    log_info "测试 init 脚本语法..."
    if /bin/sh -n "$test_dir/init" 2>/dev/null; then
        log_success "✅ init 脚本语法正确"
    else
        log_warning "⚠ init 脚本可能有语法错误"
        /bin/sh -n "$test_dir/init" 2>&1 | head -5 || true
    fi
    
    rm -rf "$test_dir"
    return 0
}

# 在构建过程中调用测试
log_info "测试 initrd..."
if test_initrd "$STAGING_DIR/live/initrd"; then
    log_success "✅ initrd 测试通过"
else
    log_error "❌ initrd 测试失败"
    exit 1
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

# ========== 步骤4: 创建initrd函数 ==========
create_minimal_initrd() {
    local initrd_path="$1"
    local initrd_dir="$WORK_DIR/initrd_root"
    
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    
    # 创建 init 脚本
    create_initrd "$initrd_dir"
    
    # 复制必要的工具
    if command -v busybox >/dev/null 2>&1; then
        cp $(which busybox) "$initrd_dir/busybox"
        cd "$initrd_dir"
        
        # 创建必要的符号链接
        for app in sh mount umount dd sync reboot poweroff modprobe \
                   mdev sleep echo cat clear ls read; do
            ln -s busybox "$app" 2>/dev/null || true
        done
        
        cd - >/dev/null
    fi
    
    # 复制其他必要工具
    if command -v pv >/dev/null 2>&1; then
        cp $(which pv) "$initrd_dir/" 2>/dev/null || true
    fi
    
    # 创建设备节点（更完整）
    mkdir -p "$initrd_dir/dev"
    mknod "$initrd_dir/dev/console" c 5 1 2>/dev/null || true
    mknod "$initrd_dir/dev/null" c 1 3 2>/dev/null || true
    mknod "$initrd_dir/dev/zero" c 1 5 2>/dev/null || true
    mknod "$initrd_dir/dev/tty" c 5 0 2>/dev/null || true
    mknod "$initrd_dir/dev/tty0" c 4 0 2>/dev/null || true
    mknod "$initrd_dir/dev/tty1" c 4 1 2>/dev/null || true
    
    # 创建设备目录
    mkdir -p "$initrd_dir/dev/shm"
    mkdir -p "$initrd_dir/dev/pts"
    
    # 创建必要的目录结构
    mkdir -p "$initrd_dir"/{proc,sys,dev,tmp,run,mnt,bin,sbin,usr/bin,usr/sbin}
    
    # 打包 initrd
    cd "$initrd_dir"
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$initrd_path"
    cd - >/dev/null
    
    # 检查 initrd 是否创建成功
    if [ -f "$initrd_path" ] && [ -s "$initrd_path" ]; then
        log_success "initrd 创建成功: $(du -h "$initrd_path" | cut -f1)"
    else
        log_error "initrd 创建失败"
        exit 1
    fi
    
    # 清理
    rm -rf "$initrd_dir"
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
