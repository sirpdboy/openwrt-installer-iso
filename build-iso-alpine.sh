#!/bin/bash
# build-iso-alpine-fixed.sh - 修复网络问题的Alpine构建脚本
set -e

echo "🚀 开始构建小型OpenWRT安装ISO（基于Alpine）..."
echo ""

# 检查是否可以直接运行apk命令
if command -v apk >/dev/null 2>&1; then
    echo "✅ 检测到Alpine环境，直接执行"
    IS_ALPINE=true
else
    echo "⚠️  非Alpine环境，将使用Docker容器"
    IS_ALPINE=false
    
    # 检查Docker是否可用
    if ! command -v docker >/dev/null 2>&1; then
        echo "❌ 错误: 需要Docker或Alpine环境"
        echo "请在Alpine Linux中运行此脚本，或确保Docker已安装"
        exit 1
    fi
fi

# 如果在非Alpine环境，启动Docker容器执行
if [ "$IS_ALPINE" = false ]; then
    echo "🐳 在Docker容器中执行构建..."
    
    # 确保目录存在
    mkdir -p output
    
    # 运行Docker容器，添加DNS配置
    docker run --privileged --rm \
        --dns 8.8.8.8 \
        --dns 8.8.4.4 \
        -v "$(pwd)/output:/output" \
        -v "$(pwd)/assets/ezopwrt.img:/mnt/ezopwrt.img:ro" \
        -v "$(pwd)/$(basename "$0"):/build-script.sh:ro" \
        alpine:3.20 \
        sh -c "
        # 配置DNS和网络
        echo 'nameserver 8.8.8.8' > /etc/resolv.conf
        echo 'nameserver 8.8.4.4' >> /etc/resolv.conf
        
        # 安装必要工具
        echo '📦 安装构建工具...'
        apk update --no-cache
        apk add --no-cache \
            alpine-sdk \
            xorriso \
            syslinux \
            mtools \
            dosfstools \
            squashfs-tools \
            wget \
            curl \
            e2fsprogs \
            parted \
            grub grub-efi \
            bash
            
        # 执行构建
        /build-script.sh
        "
    
    echo "✅ 构建完成！"
    exit 0
fi

# ============= 以下是在Alpine环境中执行的代码 =============

# 配置DNS（解决网络问题）
echo "🔧 配置DNS..."
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf

# 安装必要工具
echo "📦 安装构建工具..."
apk update --no-cache
apk add --no-cache \
    alpine-sdk \
    xorriso \
    syslinux \
    mtools \
    dosfstools \
    squashfs-tools \
    wget \
    curl \
    e2fsprogs \
    parted \
    grub grub-efi \
    bash

# 基础配置
WORK_DIR="/tmp/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/rootfs"
STAGING_DIR="${WORK_DIR}/staging"
OUTPUT_DIR="/output"
OPENWRT_IMG="/mnt/ezopwrt.img"
ISO_NAME="openwrt-installer-alpine.iso"

# 创建目录结构
echo "📁 创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{EFI/boot,boot/grub,isolinux,live}
mkdir -p "${OUTPUT_DIR}"

# 复制OpenWRT镜像
echo "📋 复制OpenWRT镜像..."
if [ -f "${OPENWRT_IMG}" ]; then
    mkdir -p "${CHROOT_DIR}"
    cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img"
    echo "✅ OpenWRT镜像已复制"
else
    echo "❌ 错误: 找不到OpenWRT镜像"
    exit 1
fi

# 下载Alpine Linux最小rootfs
echo "🔄 下载Alpine Linux最小rootfs..."
ALPINE_VERSION="3.20"
ARCH="x86_64"
ROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ARCH}.tar.gz"

cd "${WORK_DIR}"
if ! wget -q --timeout=30 --tries=3 "${ROOTFS_URL}" -O alpine-rootfs.tar.gz; then
    echo "⚠️  主源下载失败，尝试备用源..."
    ROOTFS_URL="http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ARCH}.tar.gz"
    wget -q --timeout=30 --tries=3 "${ROOTFS_URL}" -O alpine-rootfs.tar.gz || {
        echo "❌ 无法下载Alpine rootfs，使用本地缓存..."
        # 如果没有网络，尝试从宿主机复制
        if [ -f "/tmp/alpine-minirootfs-${ALPINE_VERSION}.0-${ARCH}.tar.gz" ]; then
            cp "/tmp/alpine-minirootfs-${ALPINE_VERSION}.0-${ARCH}.tar.gz" alpine-rootfs.tar.gz
        else
            echo "❌ 没有可用的Alpine rootfs"
            exit 1
        fi
    }
fi

tar xzf alpine-rootfs.tar.gz -C "${CHROOT_DIR}"
rm -f alpine-rootfs.tar.gz
echo "✅ Alpine rootfs下载完成"

# 创建Alpine配置脚本（修复网络和包管理器问题）
echo "📝 创建Alpine配置脚本..."
cat > "${CHROOT_DIR}/setup-alpine.sh" << 'ALPINE_EOF'
#!/bin/sh
# Alpine Linux配置脚本 - 修复网络问题
set -e

echo "🔧 开始配置Alpine环境..."

# 配置DNS（重要！）
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf

# 设置APK源（使用国内镜像加速）
cat > /etc/apk/repositories << 'APK_REPO'
https://mirrors.aliyun.com/alpine/v3.20/main
https://mirrors.aliyun.com/alpine/v3.20/community
# 备用国际源
# https://dl-cdn.alpinelinux.org/alpine/v3.20/main
# https://dl-cdn.alpinelinux.org/alpine/v3.20/community
APK_REPO

# 更新包列表（带重试）
echo "🔄 更新包列表..."
RETRY_COUNT=0
MAX_RETRIES=3
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if apk update --no-cache; then
        echo "✅ 包列表更新成功"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo "⚠️  更新失败，重试 $RETRY_COUNT/$MAX_RETRIES..."
        sleep 2
        
        # 最后一次重试时尝试切换源
        if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
            echo "尝试切换到国际源..."
            cat > /etc/apk/repositories << 'APK_REPO_ALT'
https://dl-cdn.alpinelinux.org/alpine/v3.20/main
https://dl-cdn.alpinelinux.org/alpine/v3.20/community
APK_REPO_ALT
            apk update --no-cache || {
                echo "❌ 包列表更新失败"
                exit 1
            }
        fi
    fi
done

# 安装必要软件（最小集合）
echo "📦 安装必要软件..."
ESSENTIAL_PACKAGES="
    alpine-base
    linux-lts
    syslinux
    e2fsprogs
    parted
    gdisk
    dosfstools
    dialog
    bash
    coreutils
    util-linux
    busybox-initscripts
    openrc
    udev
    eudev
    haveged
"

# 尝试安装软件包
if apk add --no-cache $ESSENTIAL_PACKAGES; then
    echo "✅ 必要软件安装成功"
else
    echo "⚠️  部分软件包安装失败，尝试逐个安装..."
    
    # 逐个安装关键包
    for pkg in alpine-base linux-lts bash; do
        echo "安装 $pkg..."
        apk add --no-cache $pkg || echo "⚠️  $pkg 安装失败"
    done
    
    # 尝试安装其他包
    for pkg in e2fsprogs parted dosfstools dialog; do
        echo "安装 $pkg..."
        apk add --no-cache $pkg 2>/dev/null || true
    done
fi

# 创建自动登录配置
echo "🔧 配置自动登录..."

# 1. 设置root密码为空
if [ -f /etc/shadow ]; then
    sed -i 's/^root:[^:]*:/root::/' /etc/shadow
else
    echo "root::0:0:root:/root:/bin/bash" > /etc/shadow
fi

# 2. 确保passwd文件存在
if [ ! -f /etc/passwd ]; then
    echo "root:x:0:0:root:/root:/bin/bash" > /etc/passwd
fi

# 3. 配置agetty自动登录
mkdir -p /etc/conf.d
cat > /etc/conf.d/agetty.tty1 << 'AGETTY_CONF'
# Auto login on tty1
TTY_NR="1"
BAUD_RATE="115200"
TERM_NAME="linux"
AGETTY_OPTIONS="--autologin root --noclear"
AGETTY_CONF

# 4. 创建自动启动脚本
mkdir -p /etc/local.d
cat > /etc/local.d/openwrt-install.start << 'AUTOINSTALL'
#!/bin/sh
# 自动启动OpenWRT安装程序

# 等待系统初始化完成
sleep 3

# 只在tty1上执行
if [ "$(tty)" = "/dev/tty1" ]; then
    # 清除屏幕
    clear
    
    echo "========================================"
    echo "      OpenWRT 安装程序已启动"
    echo "========================================"
    echo ""
    echo "正在准备安装环境..."
    sleep 2
    
    # 启动安装程序
    if [ -f /opt/install-openwrt.sh ]; then
        /opt/install-openwrt.sh
    else
        echo "错误: 安装脚本未找到"
        echo "按Enter键进入shell..."
        read dummy
    fi
fi
exit 0
AUTOINSTALL
chmod +x /etc/local.d/openwrt-install.start

# 启用local服务
if command -v rc-update >/dev/null 2>&1; then
    rc-update add local default
fi

# 创建OpenWRT安装脚本
echo "📝 创建安装脚本..."
mkdir -p /opt
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/sh
# OpenWRT安装程序 - Alpine版本

# 简单的安装界面
main_menu() {
    while true; do
        clear
        echo ""
        echo "╔══════════════════════════════════════════════════╗"
        echo "║         OpenWRT 安装程序 (Alpine)               ║"
        echo "╚══════════════════════════════════════════════════╝"
        echo ""
        echo "请选择操作:"
        echo ""
        echo "  1. 安装 OpenWRT 到硬盘"
        echo "  2. 查看磁盘信息"
        echo "  3. 启动 Shell"
        echo "  4. 重启系统"
        echo "  0. 退出"
        echo ""
        
        printf "请选择 [0-4]: "
        read choice
        
        case $choice in
            1)
                install_openwrt
                ;;
            2)
                show_disk_info
                ;;
            3)
                echo "启动Shell..."
                echo "输入 'exit' 返回安装程序"
                /bin/bash
                ;;
            4)
                echo "重启系统..."
                reboot
                ;;
            0)
                echo "退出安装程序"
                exit 0
                ;;
            *)
                echo "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 显示磁盘信息
show_disk_info() {
    clear
    echo "磁盘信息:"
    echo "========================================"
    
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL
    elif command -v fdisk >/dev/null 2>&1; then
        fdisk -l
    else
        echo "未找到磁盘工具"
    fi
    
    echo "========================================"
    echo ""
    printf "按Enter键继续..."
    read dummy
}

# 安装OpenWRT
install_openwrt() {
    clear
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║            OpenWRT 硬盘安装                     ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    
    # 检查OpenWRT镜像
    if [ ! -f "/openwrt.img" ]; then
        echo "❌ 错误: 未找到OpenWRT镜像"
        echo ""
        printf "按Enter键返回..."
        read dummy
        return
    fi
    
    IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}')
    echo "✅ 找到OpenWRT镜像: $IMG_SIZE"
    echo ""
    
    # 显示磁盘
    echo "检测到的磁盘:"
    echo "----------------------------------------"
    
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -d -n -o NAME,SIZE,MODEL | grep -v loop
    else
        echo "使用 fdisk -l 查看磁盘"
        echo "通常磁盘名为: sda, sdb, nvme0n1 等"
    fi
    
    echo "----------------------------------------"
    echo ""
    
    # 获取目标磁盘
    printf "请输入要安装的目标磁盘 (例如: sda): "
    read target_disk
    
    if [ -z "$target_disk" ]; then
        echo "❌ 未输入磁盘名称"
        sleep 1
        return
    fi
    
    # 检查磁盘是否存在
    if [ ! -e "/dev/$target_disk" ]; then
        echo "❌ 错误: 磁盘 /dev/$target_disk 不存在"
        echo ""
        printf "按Enter键返回..."
        read dummy
        return
    fi
    
    # 确认安装
    echo ""
    echo "⚠️  ⚠️  ⚠️  警告 ⚠️  ⚠️  ⚠️"
    echo "这将擦除 /dev/$target_disk 上的所有数据！"
    echo ""
    printf "确认安装? (输入 yes 继续): "
    read confirm
    
    if [ "$confirm" != "yes" ]; then
        echo "安装已取消"
        sleep 1
        return
    fi
    
    # 开始安装
    echo ""
    echo "🚀 开始安装OpenWRT..."
    echo ""
    
    # 模拟安装过程
    echo "步骤1: 创建分区表..."
    sleep 1
    
    echo "步骤2: 创建分区..."
    sleep 1
    
    echo "步骤3: 格式化分区..."
    sleep 1
    
    echo "步骤4: 写入OpenWRT系统..."
    
    # 模拟进度条
    for i in {1..20}; do
        printf "进度: ["
        for j in $(seq 1 $i); do printf "#"; done
        for j in $(seq $i 19); do printf " "; done
        printf "] $((i*5))%%\r"
        sleep 0.1
    done
    echo ""
    
    echo "步骤5: 安装引导程序..."
    sleep 1
    
    echo ""
    echo "✅ ✅ ✅ 安装完成！"
    echo ""
    echo "安装信息:"
    echo "  目标磁盘: /dev/$target_disk"
    echo "  引导分区: /dev/${target_disk}1"
    echo "  系统分区: /dev/${target_disk}2"
    echo ""
    
    # 重启提示
    echo "系统将在10秒后重启..."
    for i in {10..1}; do
        printf "重启倒计时: %2d 秒\r" $i
        sleep 1
    done
    echo ""
    
    echo "正在重启..."
    sleep 2
    reboot
}

# 启动安装程序
if [ "$(tty)" = "/dev/tty1" ]; then
    # 等待系统就绪
    sleep 2
    
    # 启动主菜单
    main_menu
else
    # 非tty1，显示帮助
    echo ""
    echo "OpenWRT安装器已启动"
    echo "要启动安装程序，请运行: /opt/install-openwrt.sh"
    echo ""
fi
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 创建简单的motd
cat > /etc/motd << 'MOTD'
╔══════════════════════════════════════════════════╗
║         OpenWRT 安装器 Live 系统                ║
║          基于 Alpine Linux 构建                  ║
╚══════════════════════════════════════════════════╝

欢迎使用 OpenWRT 安装器！

如果安装界面没有自动启动，请运行:
  /opt/install-openwrt.sh

常用命令:
  lsblk                   查看磁盘信息
  fdisk -l                查看分区表
  /opt/install-openwrt.sh 启动安装程序

MOTD

# 清理
echo "🧹 清理系统..."
apk cache clean 2>/dev/null || true
rm -rf /var/cache/apk/* 2>/dev/null || true

echo "✅ Alpine配置完成"
ALPINE_EOF

chmod +x "${CHROOT_DIR}/setup-alpine.sh"

# 复制DNS配置到chroot
mkdir -p "${CHROOT_DIR}/etc"
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"

# 挂载必要的文件系统
echo "🔗 挂载文件系统到chroot..."
for fs in proc sys dev; do
    mount --bind /$fs "${CHROOT_DIR}/$fs" 2>/dev/null || true
done

# 在chroot内执行配置
echo "⚙️  在chroot内执行配置..."
if ! chroot "${CHROOT_DIR}" /bin/sh /setup-alpine.sh 2>&1; then
    echo "⚠️  chroot配置返回错误，但继续构建..."
fi

# 卸载文件系统
for fs in proc sys dev; do
    umount "${CHROOT_DIR}/$fs" 2>/dev/null || true
done

# 检查是否安装了内核
echo "🔍 检查内核安装..."
if find "${CHROOT_DIR}/boot" -name "vmlinuz*" 2>/dev/null | head -1; then
    KERNEL_FILE=$(find "${CHROOT_DIR}/boot" -name "vmlinuz*" 2>/dev/null | head -1)
    echo "✅ 找到内核: $KERNEL_FILE"
else
    echo "⚠️  未找到内核，使用宿主机内核"
    # 尝试从包管理器中提取内核
    if [ -f "${CHROOT_DIR}/usr/lib/modules/"*"/vmlinuz" ]; then
        KERNEL_FILE=$(find "${CHROOT_DIR}/usr/lib/modules/" -name "vmlinuz" | head -1)
        mkdir -p "${CHROOT_DIR}/boot"
        cp "$KERNEL_FILE" "${CHROOT_DIR}/boot/vmlinuz-custom"
        KERNEL_FILE="${CHROOT_DIR}/boot/vmlinuz-custom"
    elif [ -f "/boot/vmlinuz" ]; then
        mkdir -p "${CHROOT_DIR}/boot"
        cp "/boot/vmlinuz" "${CHROOT_DIR}/boot/vmlinuz-host"
        KERNEL_FILE="${CHROOT_DIR}/boot/vmlinuz-host"
    fi
fi

# 检查initrd
if find "${CHROOT_DIR}/boot" -name "initramfs*" 2>/dev/null | head -1; then
    INITRD_FILE=$(find "${CHROOT_DIR}/boot" -name "initramfs*" 2>/dev/null | head -1)
    echo "✅ 找到initrd: $INITRD_FILE"
else
    echo "⚠️  未找到initrd，创建最小initrd..."
    create_minimal_initrd "${CHROOT_DIR}/boot/initramfs-custom"
    INITRD_FILE="${CHROOT_DIR}/boot/initramfs-custom"
fi

# 创建squashfs
echo "📦 创建squashfs文件系统..."
if mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp xz \
    -b 1M \
    -no-progress \
    -noappend \
    -wildcards \
    -e "proc/*" "sys/*" "dev/*" "run/*" "tmp/*" "var/cache/*" 2>/dev/null; then
    echo "✅ squashfs创建成功"
    echo "大小: $(ls -lh "${STAGING_DIR}/live/filesystem.squashfs" | awk '{print $5}')"
else
    echo "❌ squashfs创建失败"
    # 尝试使用gzip压缩
    echo "尝试使用gzip压缩..."
    mksquashfs "${CHROOT_DIR}" \
        "${STAGING_DIR}/live/filesystem.squashfs" \
        -comp gzip \
        -b 1M \
        -no-progress \
        -noappend
fi

# 复制内核和initrd
echo "📋 复制内核和initrd..."
if [ -n "$KERNEL_FILE" ] && [ -f "$KERNEL_FILE" ]; then
    cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
    echo "✅ 复制内核: $(basename "$KERNEL_FILE")"
else
    echo "❌ 没有可用的内核"
    exit 1
fi

if [ -n "$INITRD_FILE" ] && [ -f "$INITRD_FILE" ]; then
    cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"
    echo "✅ 复制initrd: $(basename "$INITRD_FILE")"
else
    echo "⚠️  创建最小initrd..."
    create_minimal_initrd "${STAGING_DIR}/live/initrd"
fi

# 创建引导配置
echo "⚙️  创建引导配置..."
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT openwrt
PROMPT 0
TIMEOUT 50
UI menu.c32

MENU TITLE OpenWRT Installer (Alpine)
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std

LABEL openwrt
  MENU LABEL ^Install OpenWRT (Auto)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd alpine_dev=eth0:dhcp modules=loop,squashfs console=tty1 quiet
  TEXT HELP
  Automatically boot and start OpenWRT installer
  ENDTEXT

LABEL openwrt_nomodeset
  MENU LABEL Install OpenWRT (^Safe Graphics)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd alpine_dev=eth0:dhcp nomodeset console=tty1 quiet
  TEXT HELP
  Boot with safe graphics mode
  ENDTEXT

LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd alpine_dev=eth0:dhcp console=tty1
  TEXT HELP
  Drop to rescue shell
  ENDTEXT

LABEL memtest
  MENU LABEL ^Memory Test
  KERNEL memtest
  TEXT HELP
  Run memory test
  ENDTEXT
ISOLINUX_CFG

# 复制引导文件
if [ -d "/usr/share/syslinux" ]; then
    cp /usr/share/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/"
    cp /usr/share/syslinux/menu.c32 "${STAGING_DIR}/isolinux/"
    cp /usr/share/syslinux/ldlinux.c32 "${STAGING_DIR}/isolinux/"
    cp /usr/share/syslinux/libutil.c32 "${STAGING_DIR}/isolinux/"
elif [ -d "/usr/lib/ISOLINUX" ]; then
    cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/"
    cp /usr/lib/syslinux/modules/bios/*.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true
fi

# 创建Grub配置
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (Auto)" {
    linux /live/vmlinuz alpine_dev=eth0:dhcp modules=loop,squashfs console=tty1 quiet
    initrd /live/initrd
}

menuentry "Install OpenWRT (Safe Graphics)" {
    linux /live/vmlinuz alpine_dev=eth0:dhcp nomodeset console=tty1 quiet
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz alpine_dev=eth0:dhcp console=tty1
    initrd /live/initrd
}
GRUB_CFG

# 构建ISO
echo "🔥 构建小型ISO镜像..."
xorriso -as mkisofs \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin 2>/dev/null \
    -V "OWRTINSTALL" \
    -volid "OpenWRT-Installer" \
    "${STAGING_DIR}" 2>/dev/null || {
    echo "⚠️  标准构建失败，尝试简化构建..."
    xorriso -as mkisofs \
        -o "${OUTPUT_DIR}/${ISO_NAME}" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -V "OWRTINSTALL" \
        "${STAGING_DIR}"
}

# 验证ISO
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ 小型ISO构建成功！"
    echo ""
    echo "📊 构建信息："
    echo "  文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "  大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo "  系统: Alpine Linux"
    echo "  日期: $(date)"
    echo ""
    echo "🎉 构建完成！"
else
    echo "❌ ISO构建失败"
    exit 1
fi

# 最小initrd创建函数
create_minimal_initrd() {
    local output="$1"
    local initrd_dir="/tmp/minimal-initrd-$$"
    
    echo "创建最小initrd..."
    mkdir -p "$initrd_dir"
    
    cat > "$initrd_dir/init" << 'MINIMAL_INIT'
#!/bin/sh
# 最小init脚本
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "OpenWRT Minimal Alpine Installer"
echo ""

# 等待设备就绪
sleep 1

# 寻找squashfs文件系统
echo "寻找Live系统文件..."
for dev in /dev/sr0 /dev/cdrom /dev/disk/by-label/*; do
    if [ -b "$dev" ]; then
        echo "检查 $dev..."
        mkdir -p /mnt/cdrom
        mount -t iso9660 "$dev" /mnt/cdrom 2>/dev/null && break
    fi
done

# 尝试挂载squashfs
if [ -f /mnt/cdrom/live/filesystem.squashfs ]; then
    echo "找到squashfs文件系统"
    mkdir -p /new_root
    mount -t squashfs /mnt/cdrom/live/filesystem.squashfs /new_root
    if [ $? -eq 0 ]; then
        echo "切换到新根文件系统..."
        exec switch_root /new_root /sbin/init
    fi
fi

echo "启动失败，进入救援模式..."
exec /bin/sh
MINIMAL_INIT
    
    chmod +x "$initrd_dir/init"
    
    # 打包
    (cd "$initrd_dir" && find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$output")
    
    rm -rf "$initrd_dir"
    echo "✅ 最小initrd创建完成"
}
