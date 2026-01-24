#!/bin/bash
# build-openwrt-autoinstaller-interactive.sh
# 交互式硬盘选择版本
set -e

echo "🚀 开始构建 OpenWRT 交互式安装器 ISO..."
echo "基于 Debian buster (存档源) 和 live-boot 构建"
echo "=============================================="

# 基础配置
WORK_DIR="${HOME}/OPENWRT_AUTOINSTALL"
CHROOT_DIR="${WORK_DIR}/chroot"
STAGING_DIR="${WORK_DIR}/staging"
OUTPUT_DIR="/output"
OPENWRT_IMG="/mnt/ezopwrt.img"
ISO_NAME="openwrt-autoinstaller.iso"

# 🔧 1. 安装构建依赖
echo "📦 1. 安装构建工具..."
apt-get update
apt-get install -y \
    debootstrap \
    squashfs-tools \
    xorriso \
    isolinux \
    syslinux \
    grub-pc-bin \
    mtools \
    dosfstools \
    parted \
    wget \
    live-boot \
    live-boot-initramfs-tools \
    dialog

# 📁 2. 创建目录结构
echo "📁 2. 创建工作目录..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${STAGING_DIR}"/{boot/grub,isolinux,live}
mkdir -p "${OUTPUT_DIR}"

# 📋 3. 复制 OpenWRT 镜像
echo "📋 3. 准备 OpenWRT 镜像..."
if [ -f "${OPENWRT_IMG}" ]; then
    mkdir -p "${CHROOT_DIR}"
    cp "${OPENWRT_IMG}" "${CHROOT_DIR}/openwrt.img"
    echo "✅ OpenWRT 镜像已复制到 chroot"
else
    echo "❌ 错误: 找不到 OpenWRT 镜像 ${OPENWRT_IMG}"
    exit 1
fi

# 🌱 4. 引导最小 Debian 系统
echo "🌱 4. 引导最小 Debian buster 系统..."
echo "   使用存档源: http://archive.debian.org/debian"
debootstrap --arch=amd64 --variant=minbase \
    buster "${CHROOT_DIR}" \
    http://archive.debian.org/debian

# ⚙️ 5. 配置 chroot 环境
echo "⚙️ 5. 配置 chroot 环境 (自动登录 + 交互式安装脚本)..."
cat > "${CHROOT_DIR}/configure.sh" << 'CHROOT_EOF'
#!/bin/bash
set -e

echo "🔧 开始在 chroot 内配置..."

# 5.1 配置 APT 源
cat > /etc/apt/sources.list << 'APT_SOURCES'
# Debian buster 存档源
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main
APT_SOURCES

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check

# 5.2 配置 DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# 5.3 安装必要软件包
apt-get update
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    live-boot \
    live-boot-initramfs-tools \
    systemd-sysv \
    bash \
    coreutils \
    util-linux \
    parted \
    dosfstools \
    dialog \
    whiptail \
    pv \
    lsb-release

# 5.4 配置自动登录
echo "🔧 配置自动登录 root..."
# 清空 root 密码
echo "root::0:0:root:/root:/bin/bash" > /etc/shadow
# 创建 systemd 覆盖文件实现 tty1 自动登录
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY_OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
Type=idle
GETTY_OVERRIDE

# 5.5 创建交互式安装脚本 (核心功能)
echo "📝 创建 OpenWRT 交互式安装脚本..."
cat > /opt/install-openwrt.sh << 'INSTALL_SCRIPT'
#!/bin/bash
# OpenWRT 交互式安装脚本 - 支持选择硬盘

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 打印带颜色的消息
print_header() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║           OpenWRT 交互式安装程序                 ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# 显示磁盘信息
show_disk_info() {
    echo -e "${BLUE}💾 系统检测到的磁盘列表:${NC}"
    echo "========================================"
    
    if command -v lsblk >/dev/null 2>&1; then
        # 使用 lsblk 显示详细信息
        lsblk -d -n -o NAME,SIZE,MODEL,TYPE,TRAN 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || {
            echo "使用简单列表..."
            lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || true
        }
    else
        # 使用 fdisk 作为备选
        fdisk -l 2>/dev/null | grep '^Disk /dev/' | head -15 || true
    fi
    
    echo "========================================"
}

# 验证 OpenWRT 镜像
verify_openwrt_image() {
    if [ ! -f "/openwrt.img" ]; then
        echo -e "${RED}❌ 错误: 未找到 OpenWRT 镜像文件！${NC}"
        echo "镜像应位于: /openwrt.img"
        return 1
    fi
    
    IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}')
    IMG_SIZE_BYTES=$(stat -c%s /openwrt.img 2>/dev/null || echo 0)
    
    if [ "$IMG_SIZE_BYTES" -lt 1000000 ]; then
        echo -e "${RED}❌ 错误: OpenWRT 镜像文件可能已损坏或为空！${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ 找到 OpenWRT 镜像: $IMG_SIZE${NC}"
    return 0
}

# 交互式选择磁盘
select_disk_interactive() {
    while true; do
        print_header
        echo -e "${YELLOW}步骤 1/3: 选择安装目标硬盘${NC}"
        echo ""
        
        # 显示磁盘信息
        show_disk_info
        echo ""
        
        # 获取可用磁盘列表
        if command -v lsblk >/dev/null 2>&1; then
            DISK_LIST=$(lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^(sd|hd|nvme|vd)' || echo "")
        else
            DISK_LIST=$(fdisk -l 2>/dev/null | grep '^Disk /dev/' | awk -F'[/:]' '{print $3 " " $5}' | head -15 || echo "")
        fi
        
        if [ -z "$DISK_LIST" ]; then
            echo -e "${RED}⚠️  未检测到任何可用磁盘！${NC}"
            echo ""
            echo "请检查:"
            echo "  1. 硬盘是否已正确连接"
            echo "  2. 硬盘电源是否正常"
            echo "  3. 数据线是否插好"
            echo ""
            read -p "按 Enter 键重新扫描..." dummy
            continue
        fi
        
        # 显示编号列表
        echo -e "${BLUE}请从以下列表中选择目标硬盘:${NC}"
        echo ""
        
        local i=1
        local disk_options=()
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                disk_name=$(echo "$line" | awk '{print $1}')
                disk_size=$(echo "$line" | awk '{print $2}')
                disk_model=$(echo "$line" | cut -d' ' -f3-)
                
                echo -e "  ${GREEN}$i${NC}. ${YELLOW}/dev/$disk_name${NC} - $disk_size ${CYAN}${disk_model:-未知型号}${NC}"
                disk_options+=("$disk_name")
                i=$((i+1))
            fi
        done <<< "$DISK_LIST"
        
        echo ""
        echo -e "  ${GREEN}0${NC}. 重新扫描磁盘"
        echo ""
        
        # 获取用户选择
        read -p "请输入硬盘编号 (1-$((i-1))): " disk_choice
        
        # 处理重新扫描
        if [ "$disk_choice" = "0" ]; then
            continue
        fi
        
        # 验证输入
        if ! [[ "$disk_choice" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}❌ 请输入有效的数字编号！${NC}"
            sleep 2
            continue
        fi
        
        if [ "$disk_choice" -lt 1 ] || [ "$disk_choice" -gt $((i-1)) ]; then
            echo -e "${RED}❌ 编号超出范围，请重新选择！${NC}"
            sleep 2
            continue
        fi
        
        # 获取选择的磁盘
        TARGET_DISK=${disk_options[$((disk_choice-1))]}
        
        # 确认选择
        echo ""
        echo -e "您选择了: ${YELLOW}/dev/$TARGET_DISK${NC}"
        
        # 显示磁盘详细信息
        if command -v lsblk >/dev/null 2>&1; then
            echo ""
            echo -e "${BLUE}磁盘详细信息:${NC}"
            echo "----------------------------------------"
            lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL "/dev/$TARGET_DISK" 2>/dev/null || true
            echo "----------------------------------------"
        fi
        
        echo ""
        read -p "确认选择这个磁盘? (y/N): " confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "$TARGET_DISK"
            return 0
        else
            echo "重新选择..."
            sleep 1
        fi
    done
}

# 确认安装
confirm_installation() {
    local target_disk=$1
    
    print_header
    echo -e "${RED}⚠️  ⚠️  ⚠️  重要警告 ⚠️  ⚠️  ⚠️${NC}"
    echo ""
    echo -e "您将要安装 OpenWRT 到:"
    echo -e "  ${YELLOW}/dev/$target_disk${NC}"
    echo ""
    echo -e "${RED}⚠️  这将执行以下操作:${NC}"
    echo -e "  1. ${RED}完全擦除${NC} /dev/$target_disk 上的所有数据"
    echo -e "  2. ${RED}删除${NC}所有现有分区"
    echo -e "  3. 写入全新的 OpenWRT 系统"
    echo -e "  4. 完成后自动重启"
    echo ""
    echo -e "${BLUE}请确保:${NC}"
    echo -e "  • 已备份重要数据"
    echo -e "  • 选择了正确的磁盘"
    echo -e "  • 电源稳定不会中断"
    echo ""
    
    read -p "确认开始安装? (输入 YES 确认): " confirm
    
    if [ "$confirm" = "YES" ]; then
        return 0
    else
        echo -e "${YELLOW}安装已取消${NC}"
        return 1
    fi
}

# 执行安装
perform_installation() {
    local target_disk=$1
    
    print_header
    echo -e "${GREEN}🚀 开始安装 OpenWRT${NC}"
    echo -e "目标磁盘: ${YELLOW}/dev/$target_disk${NC}"
    echo ""
    
    # 获取镜像信息
    IMG_SIZE=$(ls -lh /openwrt.img | awk '{print $5}')
    IMG_SIZE_BYTES=$(stat -c%s /openwrt.img)
    IMG_SIZE_MB=$((IMG_SIZE_BYTES / 1024 / 1024))
    
    echo -e "${BLUE}镜像信息:${NC}"
    echo "  文件: /openwrt.img"
    echo "  大小: $IMG_SIZE (${IMG_SIZE_MB} MB)"
    echo "  目标: /dev/$target_disk"
    echo ""
    
    # 检查磁盘大小
    if command -v blockdev >/dev/null 2>&1; then
        DISK_SIZE_BYTES=$(blockdev --getsize64 "/dev/$target_disk" 2>/dev/null || echo 0)
        DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))
        
        if [ "$IMG_SIZE_MB" -gt "$DISK_SIZE_MB" ]; then
            echo -e "${RED}❌ 错误: 镜像(${IMG_SIZE_MB}MB)大于磁盘(${DISK_SIZE_MB}MB)${NC}"
            return 1
        fi
        
        echo -e "${BLUE}磁盘信息:${NC}"
        echo "  设备: /dev/$target_disk"
        echo "  大小: ${DISK_SIZE_MB} MB"
        echo ""
    fi
    
    # 安装确认
    echo -e "${YELLOW}⚠️  即将开始写入，请勿中断电源！${NC}"
    echo ""
    read -p "按 Enter 键开始安装..." dummy
    
    # 开始安装
    echo ""
    echo -e "${GREEN}正在写入 OpenWRT 镜像...${NC}"
    echo ""
    
    # 使用 dd 写入，带进度显示
    if command -v pv >/dev/null 2>&1; then
        # 使用 pv 显示进度
        echo "使用 dd + pv 写入..."
        pv -pet /openwrt.img | dd of="/dev/$target_disk" bs=4M status=none
        DD_EXIT=$?
    else
        # 使用 dd 显示简单进度
        echo "使用 dd 写入..."
        dd if=/openwrt.img of="/dev/$target_disk" bs=4M status=progress 2>&1
        DD_EXIT=$?
    fi
    
    # 同步磁盘
    sync
    
    echo ""
    if [ $DD_EXIT -eq 0 ]; then
        echo -e "${GREEN}✅ OpenWRT 写入完成！${NC}"
        return 0
    else
        echo -e "${RED}❌ 写入失败！错误代码: $DD_EXIT${NC}"
        return 1
    fi
}

# 主安装流程
main_installation() {
    # 验证 OpenWRT 镜像
    if ! verify_openwrt_image; then
        echo ""
        read -p "按 Enter 键进入救援模式..." dummy
        exec /bin/bash
    fi
    
    # 交互式选择磁盘
    TARGET_DISK=$(select_disk_interactive)
    if [ $? -ne 0 ] || [ -z "$TARGET_DISK" ]; then
        echo -e "${RED}磁盘选择失败${NC}"
        return 1
    fi
    
    # 确认安装
    if ! confirm_installation "$TARGET_DISK"; then
        return 1
    fi
    
    # 执行安装
    if perform_installation "$TARGET_DISK"; then
        # 安装成功，准备重启
        print_header
        echo -e "${GREEN}🎉 OpenWRT 安装成功！${NC}"
        echo ""
        echo -e "安装完成:"
        echo -e "  • 目标磁盘: /dev/$TARGET_DISK"
        echo -e "  • 镜像大小: $(ls -lh /openwrt.img | awk '{print $5}')"
        echo -e "  • 安装时间: $(date)"
        echo ""
        
        # 重启倒计时
        echo -e "${YELLOW}系统将在10秒后自动重启...${NC}"
        echo -e "按 ${GREEN}Ctrl+C${NC} 取消重启"
        echo ""
        
        for i in {10..1}; do
            echo -ne "重启倒计时: ${RED}$i${NC} 秒\r"
            if read -t 1 -n 1; then
                echo ""
                echo -e "${YELLOW}重启已取消${NC}"
                echo ""
                echo -e "手动重启命令: ${GREEN}reboot${NC}"
                echo -e "重新安装: ${GREEN}/opt/install-openwrt.sh${NC}"
                echo ""
                exec /bin/bash
            fi
        done
        
        echo ""
        echo -e "${GREEN}正在重启系统...${NC}"
        sleep 2
        reboot
    else
        echo ""
        echo -e "${RED}安装失败！${NC}"
        echo ""
        read -p "按 Enter 键返回重新安装..." dummy
        return 1
    fi
}

# 启动安装程序
if [ "$(tty)" = "/dev/tty1" ]; then
    # 等待系统就绪
    sleep 3
    
    # 启动主安装流程
    main_installation
else
    # 非 tty1，显示提示
    echo ""
    echo -e "${CYAN}OpenWRT 交互式安装系统${NC}"
    echo ""
    echo "要启动安装程序，请运行:"
    echo "  /opt/install-openwrt.sh"
    echo ""
fi
INSTALL_SCRIPT
chmod +x /opt/install-openwrt.sh

# 5.6 配置启动时自动执行安装脚本
cat > /root/.bash_profile << 'BASHPROFILE'
#!/bin/bash
# 只在首次登录 tty1 时运行安装程序
if [ "$(tty)" = "/dev/tty1" ] && [ ! -f /tmp/install-started ]; then
    touch /tmp/install-started
    /opt/install-openwrt.sh
fi
BASHPROFILE

# 5.7 清理和生成 initramfs
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
update-initramfs -c

echo "✅ chroot 环境配置完成！"
CHROOT_EOF

# 6. 在 chroot 内执行配置
chmod +x "${CHROOT_DIR}/configure.sh"
for fs in proc dev sys; do mount --bind /$fs "${CHROOT_DIR}/$fs"; done
chroot "${CHROOT_DIR}" /bin/bash /configure.sh
for fs in proc dev sys; do umount "${CHROOT_DIR}/$fs"; done

# 📦 7. 创建 SquashFS 根文件系统
echo "📦 7. 创建 SquashFS 文件系统..."
mksquashfs "${CHROOT_DIR}" \
    "${STAGING_DIR}/live/filesystem.squashfs" \
    -comp gzip -b 1M -noappend \
    -e "proc/*" "sys/*" "dev/*" "run/*" "tmp/*"

echo "✅ squashfs 创建成功"

# 📋 8. 复制内核和 initrd
echo "📋 8. 复制内核和引导文件..."
KERNEL_FILE=$(find "${CHROOT_DIR}/boot" -name "vmlinuz*" 2>/dev/null | head -1)
INITRD_FILE=$(find "${CHROOT_DIR}/boot" -name "initrd*" 2>/dev/null | head -1)

if [ -f "$KERNEL_FILE" ]; then
    cp "$KERNEL_FILE" "${STAGING_DIR}/live/vmlinuz"
    echo "✅ 复制内核: $(basename "$KERNEL_FILE")"
else
    echo "❌ 未找到内核文件"
    exit 1
fi

if [ -f "$INITRD_FILE" ]; then
    cp "$INITRD_FILE" "${STAGING_DIR}/live/initrd"
    echo "✅ 复制 initrd: $(basename "$INITRD_FILE")"
else
    echo "❌ 未找到 initrd 文件"
    exit 1
fi

# ⚙️ 9. 配置引导菜单
echo "⚙️ 9. 配置引导菜单..."
cat > "${STAGING_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT autoinstall
PROMPT 0
TIMEOUT 30
UI menu.c32

MENU TITLE OpenWRT Auto Installer
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std

LABEL autoinstall
  MENU LABEL ^Install OpenWRT (Interactive)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live quiet
  TEXT HELP
  自动登录并启动 OpenWRT 交互式安装程序
  ENDTEXT

LABEL shell
  MENU LABEL ^Rescue Shell
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live single
  TEXT HELP
  进入救援命令行
  ENDTEXT

LABEL debug
  MENU LABEL ^Debug Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live debug
  TEXT HELP
  调试模式，显示详细启动信息
  ENDTEXT
ISOLINUX_CFG

# 复制引导文件
echo "📋 复制引导文件..."
# 查找 isolinux.bin
if [ -f "/usr/lib/ISOLINUX/isolinux.bin" ]; then
    cp "/usr/lib/ISOLINUX/isolinux.bin" "${STAGING_DIR}/isolinux/"
elif [ -f "/usr/lib/syslinux/isolinux.bin" ]; then
    cp "/usr/lib/syslinux/isolinux.bin" "${STAGING_DIR}/isolinux/"
elif [ -f "/usr/share/syslinux/isolinux.bin" ]; then
    cp "/usr/share/syslinux/isolinux.bin" "${STAGING_DIR}/isolinux/"
else
    echo "⚠️  未找到 isolinux.bin，尝试安装 syslinux"
    apt-get install -y syslinux
    cp /usr/lib/syslinux/isolinux.bin "${STAGING_DIR}/isolinux/" 2>/dev/null || true
fi

# 查找 menu.c32
if [ -f "/usr/lib/syslinux/modules/bios/menu.c32" ]; then
    cp "/usr/lib/syslinux/modules/bios/menu.c32" "${STAGING_DIR}/isolinux/"
elif [ -f "/usr/share/syslinux/menu.c32" ]; then
    cp "/usr/share/syslinux/menu.c32" "${STAGING_DIR}/isolinux/"
fi

# 创建 Grub 配置 (备用)
cat > "${STAGING_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

menuentry "Install OpenWRT (Interactive)" {
    linux /live/vmlinuz boot=live quiet
    initrd /live/initrd
}

menuentry "Rescue Shell" {
    linux /live/vmlinuz boot=live single
    initrd /live/initrd
}
GRUB_CFG

# 🔥 10. 构建 ISO 镜像
echo "🔥 10. 构建 ISO 镜像..."
xorriso -as mkisofs \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -V "OPENWRT_AUTO" \
    -quiet \
    "${STAGING_DIR}"

# ✅ 11. 完成验证
if [ -f "${OUTPUT_DIR}/${ISO_NAME}" ]; then
    echo ""
    echo "✅ ✅ ✅ 构建成功！"
    echo "=============================================="
    echo "📦 输出文件: ${OUTPUT_DIR}/${ISO_NAME}"
    echo "📊 文件大小: $(ls -lh "${OUTPUT_DIR}/${ISO_NAME}" | awk '{print $5}')"
    echo "🎯 引导方式: 传统 BIOS (ISOLINUX)"
    echo ""
    echo "🚀 使用说明："
    echo "1. 将 ISO 写入 U 盘: dd if=xxx.iso of=/dev/sdX bs=4M status=progress"
    echo "2. 从 U 盘启动计算机"
    echo "3. 选择 'Install OpenWRT (Interactive)'"
    echo "4. 系统将自动登录并显示交互式安装界面"
    echo "5. 按照提示:"
    echo "   - 查看磁盘列表"
    echo "   - 选择目标硬盘"
    echo "   - 确认安装（输入 YES）"
    echo "   - 等待安装完成"
    echo "   - 自动重启"
    echo ""
    echo "💡 提示：如果遇到显示问题，可选择 'Debug Mode' 查看启动信息"
    echo "=============================================="
else
    echo "❌ ISO 构建失败！"
    exit 1
fi

echo "🎉 所有步骤已完成！"
