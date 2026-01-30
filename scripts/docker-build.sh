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

[ $# -lt 1 ] && { echo "用法: $0 <openwrt.img> [输出目录] [iso名称] [alpine版本]"; exit 1; }


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
# openwrt-iso-final.sh - 最终修复版本

set -e

echo "================================================"
echo "  OpenWRT ISO Builder - Final Fix"
echo "================================================"
echo ""

# 参数
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt.iso}"
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"

[ ! -f "$INPUT_IMG" ] && { echo "错误: 找不到IMG文件"; exit 1; }

# 工作目录
WORK_DIR="/tmp/openwrt-final-$(date +%s)"
mkdir -p "$WORK_DIR"
mkdir -p "$OUTPUT_DIR"

INPUT_ABS=$(realpath "$INPUT_IMG")
OUTPUT_ABS=$(realpath "$OUTPUT_DIR")
ISO_PATH="$OUTPUT_ABS/$ISO_NAME"

echo "🔧 配置:"
echo "  输入: $INPUT_ABS"
echo "  输出: $ISO_PATH"
echo ""

# ========== 步骤1: 创建极简initramfs目录 ==========
echo "[1/7] 创建极简initramfs..."

INITRAMFS_DIR="$WORK_DIR/initramfs"
rm -rf "$INITRAMFS_DIR"
mkdir -p "$INITRAMFS_DIR"

# 只创建必要的目录
for dir in bin dev proc sys tmp mnt images; do
    mkdir -p "$INITRAMFS_DIR/$dir"
done

# ========== 步骤2: 创建正确的init脚本 ==========
echo "[2/7] 创建init脚本..."

cat > "$INITRAMFS_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh
# OpenWRT安装程序init脚本

# 1. 挂载核心文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp

# 2. 创建设备
mdev -s 2>/dev/null || true
[ ! -c /dev/console ] && mknod /dev/console c 5 1
[ ! -c /dev/null ] && mknod /dev/null c 1 3

# 3. 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

# 4. 显示信息
clear
echo "========================================"
echo "      OpenWRT Installer Started"
echo "========================================"
echo ""

# 5. 加载内核模块
echo "Loading modules..."
for mod in loop isofs cdrom; do
    modprobe $mod 2>/dev/null || true
done

# 6. 挂载安装介质
echo "Mounting installation media..."
for dev in /dev/sr0 /dev/cdrom /dev/sr[0-9]*; do
    if [ -b "$dev" ]; then
        mount -t iso9660 -o ro $dev /mnt 2>/dev/null && break
    fi
done

# 7. 复制OpenWRT镜像（如果从CD启动）
if mountpoint -q /mnt && [ -f /mnt/images/openwrt.img ]; then
    echo "Copying OpenWRT image..."
    cp /mnt/images/openwrt.img /images/ 2>/dev/null
    umount /mnt 2>/dev/null
fi

# 8. 主安装程序
install_menu() {
    while true; do
        clear
        echo "========================================"
        echo "         OpenWRT Installation"
        echo "========================================"
        echo ""
        echo "1) Install OpenWRT"
        echo "2) List disks"
        echo "3) Emergency shell"
        echo "4) Reboot"
        echo ""
        echo -n "Select (1-4): "
        read choice
        
        case "$choice" in
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
                
                if [ -z "$target" ]; then
                    echo "No disk specified!"
                    sleep 2
                    continue
                fi
                
                # 添加/dev/前缀
                if [ "$target" != "/dev/"* ]; then
                    target="/dev/$target"
                fi
                
                if [ ! -b "$target" ]; then
                    echo "Disk $target not found!"
                    sleep 2
                    continue
                fi
                
                # 确认
                echo ""
                echo "WARNING: This will ERASE $target!"
                echo ""
                echo -n "Type 'YES' to confirm: "
                read confirm
                
                if [ "$confirm" != "YES" ]; then
                    echo "Cancelled"
                    sleep 2
                    continue
                fi
                
                # 查找OpenWRT镜像
                img=""
                [ -f /images/openwrt.img ] && img="/images/openwrt.img"
                
                if [ -z "$img" ]; then
                    echo "OpenWRT image not found!"
                    sleep 2
                    continue
                fi
                
                # 开始安装
                echo ""
                echo "Installing OpenWRT to $target..."
                echo ""
                
                if dd if="$img" of="$target" bs=4M status=progress 2>/dev/null; then
                    sync
                    echo ""
                    echo "✅ Installation successful!"
                    echo ""
                    echo "Rebooting in 10 seconds..."
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
                for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
                    if [ -b "$disk" ]; then
                        size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
                        size_gb=$((size / 1024 / 1024 / 1024))
                        printf "  %-12s %4d GB\n" "$disk" "$size_gb"
                    fi
                done
                echo ""
                echo -n "Press Enter to continue..."
                read
                ;;
            3)
                echo ""
                echo "Starting emergency shell..."
                echo "Type 'exit' to return"
                echo ""
                exec /bin/sh
                ;;
            4)
                echo "Rebooting..."
                reboot -f
                ;;
            *)
                echo "Invalid choice"
                sleep 1
                ;;
        esac
    done
}

# 启动菜单
install_menu

# 如果失败，进入shell
echo "Installation failed, dropping to shell..."
exec /bin/sh
INIT_EOF

chmod 755 "$INITRAMFS_DIR/init"

# ========== 步骤3: 准备busybox ==========
echo "[3/7] 准备busybox..."

# 检查busybox是否可用
if ! command -v busybox >/dev/null 2>&1; then
    echo "❌ 错误: 系统没有busybox"
    exit 1
fi

# 获取busybox路径
BUSYBOX_PATH=$(which busybox)

# 复制busybox到initramfs
echo "复制busybox..."
cp "$BUSYBOX_PATH" "$INITRAMFS_DIR/bin/busybox"
chmod 755 "$INITRAMFS_DIR/bin/busybox"

# 测试busybox
if "$INITRAMFS_DIR/bin/busybox" --help 2>&1 | head -1 | grep -q "BusyBox"; then
    echo "✅ busybox可用"
else
    echo "❌ busybox可能损坏"
    exit 1
fi

# 创建必要的符号链接
echo "创建符号链接..."
cd "$INITRAMFS_DIR/bin"

# 手动创建最必要的链接
ln -sf busybox sh 2>/dev/null || true
ln -sf busybox mount 2>/dev/null || true
ln -sf busybox umount 2>/dev/null || true
ln -sf busybox modprobe 2>/dev/null || true
ln -sf busybox dd 2>/dev/null || true
ln -sf busybox sync 2>/dev/null || true
ln -sf busybox reboot 2>/dev/null || true
ln -sf busybox mknod 2>/dev/null || true
ln -sf busybox mdev 2>/dev/null || true
ln -sf busybox cat 2>/dev/null || true
ln -sf busybox echo 2>/dev/null || true
ln -sf busybox ls 2>/dev/null || true
ln -sf busybox clear 2>/dev/null || true
ln -sf busybox sleep 2>/dev/null || true

cd - >/dev/null

# ========== 步骤4: 复制OpenWRT镜像 ==========
echo "[4/7] 复制OpenWRT镜像..."
cp "$INPUT_ABS" "$INITRAMFS_DIR/images/openwrt.img"
echo "✅ OpenWRT镜像大小: $(du -h "$INPUT_ABS" | cut -f1)"

# ========== 步骤5: 打包initramfs（修复路径问题） ==========
echo "[5/7] 打包initramfs..."

# 保存当前目录
CURRENT_DIR=$(pwd)

# 进入initramfs目录
cd "$INITRAMFS_DIR"

echo "正在打包..."
# 使用简单可靠的方法
{
    # 先列出所有文件
    find . -type f -o -type l | sort
    
    # 确保目录存在
    find . -type d | sed 's|/$||' | sort
} | cpio -o -H newc 2>/dev/null | gzip -9 > "$WORK_DIR/initramfs.gz"

# 返回原目录
cd "$CURRENT_DIR"

# 检查initramfs
if [ ! -f "$WORK_DIR/initramfs.gz" ] || [ ! -s "$WORK_DIR/initramfs.gz" ]; then
    echo "❌ initramfs打包失败"
    exit 1
fi

INITRAMFS_SIZE=$(du -h "$WORK_DIR/initramfs.gz" | cut -f1)
echo "✅ initramfs大小: $INITRAMFS_SIZE"

# 测试initramfs
echo "测试initramfs..."
TEST_DIR="$WORK_DIR/test-initramfs"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

# 这里修复了cd命令的问题
if cd "$TEST_DIR" && gzip -dc "$WORK_DIR/initramfs.gz" | cpio -id 2>/dev/null; then
    echo "✅ initramfs可正常解压"
    
    # 检查关键文件
    if [ -f init ] && [ -x init ] && [ -f bin/busybox ] && [ -f bin/sh ]; then
        echo "✅ 所有关键文件正常"
        
        # 检查shebang
        SHEBANG=$(head -1 init 2>/dev/null)
        echo "  init shebang: $SHEBANG"
    else
        echo "❌ 缺少关键文件"
        [ -f init ] || echo "  - 缺少init"
        [ -x init ] || echo "  - init不可执行"
        [ -f bin/busybox ] || echo "  - 缺少busybox"
        [ -f bin/sh ] || echo "  - 缺少sh"
    fi
else
    echo "❌ initramfs解压失败"
fi

# 返回原目录
cd "$CURRENT_DIR"

# 清理测试目录
rm -rf "$TEST_DIR"

echo ""

# ========== 步骤6: 准备内核 ==========
echo "[6/7] 准备内核..."

KERNEL_PATH="$WORK_DIR/vmlinuz"
if [ -f /boot/vmlinuz-lts ]; then
    cp /boot/vmlinuz-lts "$KERNEL_PATH"
    echo "✅ 使用内核: vmlinuz-lts"
elif [ -f /boot/vmlinuz ]; then
    cp /boot/vmlinuz "$KERNEL_PATH"
    echo "✅ 使用内核: vmlinuz"
else
    echo "❌ 找不到内核文件"
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
TIMEOUT 100
PROMPT 1

LABEL install
  MENU LABEL Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs console=tty0 console=ttyS0,115200 rw quiet

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs console=tty0 init=/bin/sh rw

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32
ISOLINUX_EOF

# 复制引导文件
echo "复制引导文件..."
SYS_FOUND=0
for sys_dir in /usr/share/syslinux /usr/lib/syslinux; do
    if [ -d "$sys_dir" ]; then
        echo "从 $sys_dir 复制文件"
        
        # 复制核心文件
        for file in isolinux.bin ldlinux.c32; do
            if [ -f "$sys_dir/$file" ]; then
                cp "$sys_dir/$file" "$ISO_ROOT/isolinux/"
                echo "  ✅ $file"
            fi
        done
        
        # 可选文件
        for file in libutil.c32 libcom32.c32 reboot.c32; do
            if [ -f "$sys_dir/$file" ]; then
                cp "$sys_dir/$file" "$ISO_ROOT/isolinux/" 2>/dev/null || true
            fi
        done
        
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
if command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs \
        -r -V 'OPENWRT_INSTALL' \
        -o "$ISO_PATH" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin 2>/dev/null \
        "$ISO_ROOT" 2>&1 | grep -v "UPDATE" | tail -10
else
    echo "❌ 错误: 没有xorriso"
    exit 1
fi

# 验证ISO
if [ -f "$ISO_PATH" ] && [ -s "$ISO_PATH" ]; then
    ISO_SIZE=$(ls -lh "$ISO_PATH" | awk '{print $5}')
    
    echo ""
    echo "🎉 🎉 🎉 ISO构建成功! 🎉 🎉 🎉"
    echo ""
    echo "📁 ISO文件: $ISO_PATH"
    echo "📊 总大小: $ISO_SIZE"
    echo ""
    echo "📦 组件大小:"
    echo "  - 内核: $KERNEL_SIZE"
    echo "  - initramfs: $INITRAMFS_SIZE"
    echo "  - OpenWRT镜像: $(du -h "$INPUT_ABS" | cut -f1)"
    echo ""
    echo "✅ 构建完成!"
    
    # 创建测试脚本
    cat > "$OUTPUT_ABS/verify-iso.sh" << 'VERIFY_EOF'
#!/bin/bash
# 验证ISO脚本

ISO="$1"
[ ! -f "$ISO" ] && { echo "用法: $0 <iso文件>"; exit 1; }

echo "验证ISO: $ISO"
echo ""

# 1. 基本检查
echo "1. 基本检查:"
echo "  大小: $(ls -lh "$ISO" | awk '{print $5}')"
echo "  类型: $(file "$ISO" 2>/dev/null | cut -d: -f2-)"
echo ""

# 2. 检查引导
echo "2. 引导检查:"
if command -v xorriso >/dev/null 2>&1; then
    xorriso -indev "$ISO" -check_media 2>&1 | grep -E "El.Torito|bootable|No.boot" || true
fi
echo ""

# 3. 提取并检查initramfs
echo "3. 检查initramfs:"
TEMP_DIR="/tmp/iso-check-$$"
mkdir -p "$TEMP_DIR"

# 尝试提取initramfs
if xorriso -osirrox on -indev "$ISO" -extract /boot/initramfs "$TEMP_DIR/initramfs.gz" 2>/dev/null; then
    echo "  ✅ 成功提取initramfs"
    
    # 解压
    mkdir -p "$TEMP_DIR/extract"
    if cd "$TEMP_DIR/extract" && gzip -dc "../initramfs.gz" 2>/dev/null | cpio -id 2>/dev/null; then
        echo "  ✅ initramfs可解压"
        
        # 检查文件
        echo "  - init: $(test -f init && echo '存在' || echo '缺失')"
        echo "  - init权限: $(test -x init && echo '可执行' || echo '不可执行')"
        echo "  - busybox: $(test -f bin/busybox && echo '存在' || echo '缺失')"
        echo "  - sh: $(test -f bin/sh && echo '存在' || echo '缺失')"
        
        if [ -f init ]; then
            echo "  - init shebang: $(head -1 init 2>/dev/null)"
        fi
    else
        echo "  ❌ initramfs解压失败"
    fi
else
    echo "  ❌ 无法提取initramfs"
fi

# 清理
rm -rf "$TEMP_DIR"
echo ""
echo "✅ 验证完成"
VERIFY_EOF
    
    chmod +x "$OUTPUT_ABS/verify-iso.sh"
    
    echo "💡 提示: 使用以下命令验证ISO:"
    echo "  $OUTPUT_ABS/verify-iso.sh \"$ISO_PATH\""
    
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
