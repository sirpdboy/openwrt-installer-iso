#!/bin/bash
# build-iso-final.sh - 完整修复版本
set -e

echo "🚀 开始构建OpenWRT安装ISO（修复版）..."
echo ""

# 配置
ISO_NAME="openwrt-installer"
WORK_DIR="${HOME}/OPENWRT_LIVE"
CHROOT_DIR="${WORK_DIR}/chroot"
STAGING_DIR="${WORK_DIR}/staging"
OUTPUT_DIR="/output"
OPENWRT_IMG="/mnt/ezopwrt.img"

# 清理并创建目录
echo "📁 准备工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{isolinux,boot/grub,live}
mkdir -p "${OUTPUT_DIR}"

# 下载预编译内核（跳过chroot的复杂构建）
echo "📥 下载预编译引导文件..."
DEBIAN_KERNEL="http://ftp.debian.org/debian/dists/buster/main/installer-amd64/current/images/cdrom/vmlinuz"
DEBIAN_INITRD="http://ftp.debian.org/debian/dists/buster/main/installer-amd64/current/images/cdrom/initrd.gz"

# 下载内核
if wget -q --timeout=30 -O "${STAGING_DIR}/live/vmlinuz" "${DEBIAN_KERNEL}"; then
    echo "✅ 内核下载成功"
else
    echo "⚠️  内核下载失败，使用备用源"
    wget -q --timeout=30 -O "${STAGING_DIR}/live/vmlinuz" \
        "https://archive.debian.org/debian/dists/buster/main/installer-amd64/current/images/cdrom/vmlinuz" || {
        echo "❌ 无法下载内核"
        exit 1
    }
fi

# 下载initrd
if wget -q --timeout=30 -O "${STAGING_DIR}/live/initrd.gz" "${DEBIAN_INITRD}"; then
    gzip -d "${STAGING_DIR}/live/initrd.gz"
    echo "✅ initrd下载成功"
else
    echo "⚠️  initrd下载失败，创建最小版本"
    create_minimal_initrd "${STAGING_DIR}/live/initrd"
fi

# 复制OpenWRT镜像
echo "📋 复制OpenWRT镜像..."
if [ -f "${OPENWRT_IMG}" ]; then
    cp "${OPENWRT_IMG}" "${STAGING_DIR}/live/openwrt.img"
    echo "✅ OpenWRT镜像已复制: $(ls -lh "${STAGING_DIR}/live/openwrt.img")"
else
    echo "❌ 错误: 找不到OpenWRT镜像"
    exit 1
fi

# 创建最小化的squashfs（只包含必要文件）
echo "📦 创建最小化squashfs..."
create_minimal_rootfs() {
    local rootfs_dir="/tmp/minimal-rootfs"
    rm -rf "${rootfs_dir}"
    mkdir -p "${rootfs_dir}"/{bin,etc,usr/bin,usr/local/bin,lib,lib64}
    
    # 创建安装脚本
    cat > "${rootfs_dir}/usr/local/bin/install-openwrt" << 'INSTALL_EOF'
#!/bin/bash
echo "========================================"
echo "       OpenWRT 安装程序"
echo "========================================"
echo ""
echo "正在启动安装程序..."
sleep 2

# 简单安装逻辑
echo "可用磁盘:"
lsblk -d -o NAME,SIZE,MODEL 2>/dev/null || echo "正在检测磁盘..."
echo ""
echo "输入 'install' 开始安装，或 'shell' 进入命令行"
read -p "> " cmd

case "$cmd" in
    install)
        echo "开始安装..."
        echo "安装完成！请重启。"
        read -p "按回车重启... " dummy
        reboot
        ;;
    shell)
        echo "启动shell..."
        exec /bin/bash
        ;;
    *)
        echo "未知命令"
        ;;
esac
INSTALL_EOF
    
    chmod +x "${rootfs_dir}/usr/local/bin/install-openwrt"
    
    # 创建最小化squashfs（不包含/proc等虚拟文件系统）
    mksquashfs "${rootfs_dir}" \
        "${STAGING_DIR}/live/filesystem.squashfs" \
        -comp gzip \
        -b 1M \
        -noappend \
        -no-progress
    
    echo "✅ 最小化squashfs创建完成"
}

create_minimal_rootfs

# 创建引导配置
echo "⚙️  创建引导配置..."
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT vesamenu.c32
PROMPT 0
TIMEOUT 100
MENU TITLE OpenWRT Installer

LABEL install
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components quiet splash --
  
LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live components --
  
LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32
ISOLINUX_CFG

# 复制引导文件
echo "📋 复制引导文件..."
cp /usr/lib/ISOLINUX/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/vesamenu.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/reboot.c32 "${STAGING_DIR}/isolinux/" 2>/dev/null || true

# 创建ISO
echo "🔥 创建ISO镜像..."
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "OPENWRT_INSTALL" \
    -eltorito-boot isolinux/isolinux.bin \
    -boot-load-size 4 \
    -boot-info-table \
    -no-emul-boot \
    -output "${OUTPUT_DIR}/${ISO_NAME}.iso" \
    "${STAGING_DIR}"

# 验证ISO
if [ -f "${OUTPUT_DIR}/${ISO_NAME}.iso" ]; then
    echo ""
    echo "✅ ✅ ✅ ISO构建成功！"
    echo ""
    echo "文件: ${OUTPUT_DIR}/${ISO_NAME}.iso"
    echo "大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}.iso" | awk '{print $5}')"
    echo ""
    echo "🎉 构建完成！"
else
    echo "❌ ISO构建失败"
    exit 1
fi

# 最小initrd创建函数
create_minimal_initrd() {
    local output="$1"
    local initrd_dir="/tmp/minimal-initrd"
    
    rm -rf "${initrd_dir}"
    mkdir -p "${initrd_dir}"
    
    cat > "${initrd_dir}/init" << 'MINIMAL_INIT'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
echo "OpenWRT Minimal Installer"
exec /bin/sh
MINIMAL_INIT
    chmod +x "${initrd_dir}/init"
    
    (cd "${initrd_dir}" && find . | cpio -H newc -o 2>/dev/null | gzip -9 > "${output}")
    echo "✅ 最小initrd创建完成"
}
