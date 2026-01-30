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
       # 安装构建工具
        RUN apk update && apk add --no-cache \
            alpine-sdk \
            alpine-conf \
            syslinux \
            xorriso \
            squashfs-tools \
            grub \
            grub-efi \
            mtools \
            dosfstools \
            e2fsprogs \
            parted \
            lsblk \
            curl \
            wget \
            git \
            bash \
            && rm -rf /var/cache/apk/*
        
        # 创建构建用户
        RUN adduser -D -g "Alpine Builder" builder && \
            echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
        
        USER builder
        WORKDIR /home/builder
        
        # 创建签名密钥（非交互式）
        RUN abuild-keygen -a -n
        
        # 复制构建脚本
        COPY --chown=builder:builder build-scripts/ /home/builder/build-scripts/
        
        RUN chmod +x /home/builder/build-scripts//build-iso.sh
        ENTRYPOINT ["/home/builder/build-scripts/build-iso.sh"]


DOCKERFILE_EOF
mkdir -p build-scripts
# 更新版本号
# sed -i "s/ARG ALPINE_VERSION=3.20/ARG ALPINE_VERSION=$ALPINE_VERSION/g" "$DOCKERFILE_PATH"

# 创建完整的Alpine构建脚本
cat > build-scripts/build-iso.sh << 'SCRIPTEOF'
        #!/bin/bash
        set -e
        
        echo "================================================"
        echo "  OpenWRT ISO Builder - Alpine mkimage"
        echo "================================================"
        echo ""
# 从环境变量获取参数
INPUT_IMG="${INPUT_IMG:-/mnt/input.img}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_NAME="${ISO_NAME:-openwrt.iso}"
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"

        # 克隆 aports 仓库（如果不存在）
        if [ ! -d aports ]; then
          echo "克隆 aports 仓库..."
          git clone --depth 1 https://gitlab.alpinelinux.org/alpine/aports.git
        fi
        
        cd aports
        
        # 创建临时目录
        export TMPDIR=$(pwd)/tmp
        mkdir -p $TMPDIR
        
        echo "当前目录: $(pwd)"
        echo "TMPDIR: $TMPDIR"
        
        # 1. 创建自定义 profile
        echo "创建自定义 profile..."
        cat > scripts/mkimg.openwrt-installer.sh << 'PROFILEEOF'
        profile_openwrt_installer() {
            profile_standard
            kernel_cmdline="console=tty0 console=ttyS0,115200 quiet"
            syslinux_serial="0 115200"
            apks="\$apks dosfstools e2fsprogs parted lsblk pv"
            
            # 添加我们的 overlay 脚本
            apkovl="genapkovl-openwrt-installer.sh"
        }
        PROFILEEOF
        
        # 2. 创建 overlay 生成脚本
        echo "创建 overlay 生成脚本..."
        cat > scripts/genapkovl-openwrt-installer.sh << 'OVERLAYEOF'
        #!/bin/sh
        # OpenWRT 安装 overlay
        
        set -e
        
        # 创建临时目录
        tmp="\${ROOT}/tmp/overlay"
        mkdir -p "\$tmp"/etc/init.d
        mkdir -p "\$tmp"/usr/local/bin
        mkdir -p "\$tmp"/etc/apk
        mkdir -p "\$tmp"/images
        
        # 复制 OpenWRT 镜像
        if [ -f "$INPUT_IMG" ]; then
          echo "复制 OpenWRT 镜像到 overlay..."
          # cp /source/images/openwrt.img "\$tmp"/images/
          cp "$INPUT_IMG" "\$tmp"/images/
        fi
        
        # 创建 /etc/apk/world
        cat > "\$tmp"/etc/apk/world << 'WORLDEOF'
        alpine-base
        WORLDEOF
        
        # 创建安装脚本
        cat > "\$tmp"/usr/local/bin/setup-openwrt << 'INSTALLEOF'
        #!/bin/sh
        # OpenWRT 安装程序
        
        set -e
        
        echo "========================================"
        echo "     OpenWRT Installation Program"
        echo "========================================"
        echo ""
        
        # 查找镜像
        find_image() {
            # 1. 检查 overlay 中的镜像
            if [ -f /images/openwrt.img ]; then
                echo "/images/openwrt.img"
                return 0
            fi
            
            # 2. 检查安装介质
            for dev in /dev/sr0 /dev/cdrom /media/cdrom /mnt/cdrom; do
                if [ -b "\$dev" ] || [ -d "\$dev" ]; then
                    if [ -f "\$dev/images/openwrt.img" ]; then
                        echo "\$dev/images/openwrt.img"
                        return 0
                    fi
                fi
            done
            
            # 3. 检查挂载点
            for mount in /media/* /mnt/*; do
                if [ -f "\$mount/images/openwrt.img" ]; then
                    echo "\$mount/images/openwrt.img"
                    return 0
                fi
            done
            
            return 1
        }
        
        # 显示磁盘信息
        show_disks() {
            echo "可用磁盘列表:"
            echo "--------------"
            if command -v lsblk >/dev/null 2>&1; then
                lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME"
            else
                # 简单列出磁盘
                for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
                    if [ -b "\$disk" ]; then
                        size=\$(blockdev --getsize64 "\$disk" 2>/dev/null || echo 0)
                        size_gb=\$((size / 1024 / 1024 / 1024))
                        echo "\$disk - \${size_gb}GB"
                    fi
                done
            fi
            echo "--------------"
        }
        
        # 主安装函数
        main_install() {
            # 查找镜像
            IMG_PATH=\$(find_image)
            if [ -z "\$IMG_PATH" ] || [ ! -f "\$IMG_PATH" ]; then
                echo "错误：找不到 OpenWRT 镜像文件"
                echo "请确保 openwrt.img 位于以下位置之一:"
                echo "  - 安装介质的 /images/ 目录"
                echo "  - 系统 /images/ 目录"
                return 1
            fi
            
            echo "找到镜像: \$IMG_PATH (\$(du -h "\$IMG_PATH" | cut -f1))"
            echo ""
            
            # 显示磁盘
            show_disks
            echo ""
            
            # 获取目标磁盘
            while true; do
                echo -n "请输入目标磁盘名称 (例如: sda, nvme0n1): "
                read TARGET_DISK
                
                if [ -z "\$TARGET_DISK" ]; then
                    echo "输入不能为空，请重新输入"
                    continue
                fi
                
                # 添加 /dev/ 前缀
                if [[ "\$TARGET_DISK" != "/dev/"* ]]; then
                    TARGET_DISK="/dev/\$TARGET_DISK"
                fi
                
                # 验证磁盘存在
                if [ ! -b "\$TARGET_DISK" ]; then
                    echo "错误：磁盘 \$TARGET_DISK 不存在"
                    echo "请重新输入"
                    continue
                fi
                
                # 防止误操作到系统盘
                if mount | grep -q "\$TARGET_DISK"; then
                    echo "警告：磁盘 \$TARGET_DISK 已挂载！"
                    echo -n "确认要继续吗？(输入 YES 确认): "
                    read CONFIRM
                    if [ "\$CONFIRM" != "YES" ]; then
                        echo "操作取消"
                        return 1
                    fi
                fi
                
                break
            done
            
            # 最终确认
            echo ""
            echo "⚠️  ⚠️  ⚠️  警告 ⚠️  ⚠️  ⚠️"
            echo ""
            echo "这将永久擦除磁盘 \$TARGET_DISK 上的所有数据！"
            echo ""
            echo -n "请输入 'YES' 确认安装: "
            read FINAL_CONFIRM
            
            if [ "\$FINAL_CONFIRM" != "YES" ]; then
                echo "安装已取消"
                return 1
            fi
            
            # 开始安装
            echo ""
            echo "正在安装 OpenWRT 到 \$TARGET_DISK ..."
            echo ""
            
            if command -v pv >/dev/null 2>&1; then
                echo "使用 pv 显示进度..."
                pv "\$IMG_PATH" | dd of="\$TARGET_DISK" bs=4M
            else
                echo "使用 dd 写入..."
                dd if="\$IMG_PATH" of="\$TARGET_DISK" bs=4M status=progress 2>/dev/null || \
                dd if="\$IMG_PATH" of="\$TARGET_DISK" bs=4M
            fi
            
            WRITE_RESULT=\$?
            
            # 同步数据
            sync
            
            if [ \$WRITE_RESULT -eq 0 ]; then
                echo ""
                echo "✅ OpenWRT 安装成功！"
                echo ""
                echo "镜像已写入: \$TARGET_DISK"
                echo ""
                echo "系统将在 10 秒后重启..."
                
                for i in \$(seq 10 -1 1); do
                    echo -ne "倒计时: \${i} 秒...\r"
                    sleep 1
                done
                
                echo ""
                echo "正在重启..."
                reboot -f
            else
                echo ""
                echo "❌ 安装失败！错误代码: \$WRITE_RESULT"
                return 1
            fi
        }
        
        # 简单菜单
        show_menu() {
            clear
            echo "========================================"
            echo "        OpenWRT 安装程序"
            echo "========================================"
            echo ""
            echo "1) 安装 OpenWRT"
            echo "2) 查看磁盘信息"
            echo "3) 进入紧急 Shell"
            echo "4) 重启系统"
            echo ""
        }
        
        # 主循环
        while true; do
            show_menu
            echo -n "请选择操作 (1-4): "
            read CHOICE
            
            case "\$CHOICE" in
                1)
                    if main_install; then
                        break
                    else
                        echo ""
                        echo "按 Enter 键继续..."
                        read
                    fi
                    ;;
                2)
                    clear
                    show_disks
                    echo ""
                    echo "按 Enter 键继续..."
                    read
                    ;;
                3)
                    echo ""
                    echo "进入紧急 Shell..."
                    echo "输入 'exit' 返回安装程序"
                    echo ""
                    /bin/sh
                    ;;
                4)
                    echo "正在重启系统..."
                    reboot -f
                    ;;
                *)
                    echo "无效选择"
                    sleep 1
                    ;;
            esac
        done
        INSTALLEOF
        
        chmod 755 "\$tmp"/usr/local/bin/setup-openwrt
        
        # 创建 init.d 服务
        cat > "\$tmp"/etc/init.d/setup-openwrt << 'SERVICEEOF'
        #!/sbin/openrc-run
        # OpenWRT 安装服务
        
        name="setup-openwrt"
        description="OpenWRT Installation Service"
        
        depend() {
            need localmount
            after bootmisc
        }
        
        start() {
            ebegin "Starting OpenWRT installation"
            /usr/local/bin/setup-openwrt
            eend \$?
        }
        SERVICEEOF
        
        chmod 755 "\$tmp"/etc/init.d/setup-openwrt
        
        # 添加到默认运行级别
        mkdir -p "\$tmp"/etc/runlevels/default
        ln -sf /etc/init.d/setup-openwrt "\$tmp"/etc/runlevels/default/setup-openwrt
        
        # 打包 overlay
        ( cd "\$tmp" && tar -c -f "\${ROOT}"/tmp/overlay.tar . )
        
        echo "Overlay 创建完成"
        OVERLAYEOF
        
        chmod +x scripts/genapkovl-openwrt-installer.sh
        
        # 3. 运行 mkimage.sh 构建 ISO
        echo "开始构建 ISO..."
        echo "参数:"
        echo "  Alpine 版本: $ALPINE_VERSION"
        echo "  架构: x86_64"
        echo "  Profile: openwrt_installer"
        
        # 构建 ISO
        ./scripts/mkimage.sh \
          --tag "$ALPINE_VERSION" \
          --outdir /output \
          --arch x86_64 \
          --repository "http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/main" \
          --repository "http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/community" \
          --profile openwrt_installer
        
        # 检查构建结果
        if ls /output/*.iso 1>/dev/null 2>&1; then
          ISO_FILE=$(ls /output/*.iso)
          echo "✅ ISO 构建成功: $ISO_FILE"
          echo "文件大小: $(du -h "$ISO_FILE" | cut -f1)"
        else
          echo "❌ ISO 构建失败"
          exit 1
        fi
        
        echo ""
        echo "🎉 构建完成！"



BUILD_SCRIPT_EOF

chmod +x build-scripts/build-iso.sh
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
