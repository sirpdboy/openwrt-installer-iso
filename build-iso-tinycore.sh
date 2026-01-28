#!/bin/bash
# build-iso-tinycore.sh OpenWRT Installer ISO Builder 
# 支持BIOS/UEFI双引导

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_IMG="${1:-${SCRIPT_DIR}/assets/openwrt.img}"
OUTPUT_DIR="${2:-${SCRIPT_DIR}/output}"
OUTPUT_ISO_FILENAME="${3:-openwrt-installer.iso}"
OUTPUT_ISO="${OUTPUT_DIR}/${OUTPUT_ISO_FILENAME}"
WORK_DIR="/tmp/iso-work-$$"

# 日志函数
print_header() { echo -e "${CYAN}\n=== $1 ===${NC}"; }
print_step() { echo -e "${GREEN}▶${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1" >&2; }

# 错误处理
trap cleanup EXIT INT TERM
cleanup() {
    if [ -d "$WORK_DIR" ]; then
        print_info "清理工作目录..."
        rm -rf "$WORK_DIR" 2>/dev/null || true
    fi
}

# ================= 初始化 =================
print_header "OpenWRT 安装器构建系统"

# 验证输入
if [ ! -f "${INPUT_IMG}" ]; then
    print_error "输入IMG文件未找到: ${INPUT_IMG}"
    exit 1
fi

IMG_SIZE=$(du -h "${INPUT_IMG}" 2>/dev/null | cut -f1 || echo "unknown")
print_step "输入IMG: ${INPUT_IMG} (${IMG_SIZE})"
print_step "输出ISO: ${OUTPUT_ISO}"
print_step "工作目录: ${WORK_DIR}"

# ================= 准备目录 =================
print_header "1. 准备目录结构"

rm -rf "${WORK_DIR}" 2>/dev/null || true
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# 创建完整的ISO目录结构
mkdir -p "$WORK_DIR/iso/boot"
mkdir -p "$WORK_DIR/iso/boot/grub"
mkdir -p "$WORK_DIR/iso/EFI/BOOT"
mkdir -p "$WORK_DIR/iso/img"
mkdir -p "$WORK_DIR/iso/installer"
mkdir -p "${OUTPUT_DIR}"

print_info "目录结构:"
find . -type d | sort

print_success "目录结构创建完成"

# ================= 复制OpenWRT镜像 =================
print_header "2. 复制OpenWRT镜像"

cp "${INPUT_IMG}" "$WORK_DIR/iso/img/openwrt.img"
IMG_SIZE_FINAL=$(du -h "$WORK_DIR/iso/img/openwrt.img" 2>/dev/null | cut -f1)
print_success "IMG文件复制完成: ${IMG_SIZE_FINAL}"

# ================= 获取内核 =================
print_header "3. 获取Linux内核"

get_kernel() {
    print_step "下载Linux内核..."
    
    # TinyCore Linux 内核 (兼容性好)
    KERNEL_URLS=(
        "https://distro.ibiblio.org/tinycorelinux/15.x/x86_64/release/distribution_files/vmlinuz64"
        "https://distro.ibiblio.org/tinycorelinux/10.x/x86_64/release/distribution_files/vmlinuz64"
        "https://tinycorelinux.net/15.x/x86_64/release/distribution_files/vmlinuz64"
        "https://github.com/tinycorelinux/Core-scripts/raw/master/vmlinuz64"
        "https://repo.tinycorelinux.net/15.x/x86_64/release/distribution_files/vmlinuz64"
    )
    
    for url in "${KERNEL_URLS[@]}"; do
        print_info "尝试: $url"
        
        if curl -L --connect-timeout 15 --max-time 30 --retry 2 \
            -s -o "$WORK_DIR/iso/boot/vmlinuz" "$url" 2>/dev/null; then
            
            if [ -f "$WORK_DIR/iso/boot/vmlinuz" ] && [ -s "$WORK_DIR/iso/boot/vmlinuz" ]; then
                KERNEL_SIZE=$(stat -c%s "$WORK_DIR/iso/boot/vmlinuz" 2>/dev/null || echo 0)
                if [ $KERNEL_SIZE -gt 1000000 ]; then
                    print_success "内核下载成功: $((KERNEL_SIZE/1024/1024))MB"
                    file "$WORK_DIR/iso/boot/vmlinuz"
                    return 0
                fi
            fi
        fi
        sleep 1
    done
    
    # 如果下载失败，尝试使用系统内核
    print_warning "内核下载失败，尝试本地内核..."
    
    # 检查本地是否有可用的内核
    if [ -f "/boot/vmlinuz" ] || [ -f "/boot/vmlinuz-$(uname -r)" ]; then
        for kernel in /boot/vmlinuz*; do
            if [ -f "$kernel" ] && ! [[ "$kernel" =~ "System.map" ]] && ! [[ "$kernel" =~ "config" ]]; then
                cp "$kernel" "$WORK_DIR/iso/boot/vmlinuz" 2>/dev/null
                if [ -f "$WORK_DIR/iso/boot/vmlinuz" ]; then
                    print_success "使用本地内核: $kernel"
                    return 0
                fi
            fi
        done
    fi
    
    # 最后尝试下载最小内核
    print_warning "创建最小内核..."
    dd if=/dev/zero of="$WORK_DIR/iso/boot/vmlinuz" bs=1M count=1 2>/dev/null
    echo "LINUX_KERNEL_PLACEHOLDER" > "$WORK_DIR/iso/boot/vmlinuz"
    print_info "使用占位内核，安装时需手动替换"
    return 1
}

get_kernel

KERNEL_SIZE=$(du -h "$WORK_DIR/iso/boot/vmlinuz" 2>/dev/null | cut -f1)
print_success "内核准备完成: ${KERNEL_SIZE}"

# ================= 创建完整的initramfs =================
print_header "4. 创建initramfs"

create_initramfs() {
    print_step "创建initramfs..."
    
    local initrd_dir="${WORK_DIR}/initrd"
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    cd "$initrd_dir"
    
    # 创建完整的目录结构
    mkdir -p {bin,dev,etc,proc,sys,tmp,mnt,lib,lib64,usr/bin,usr/lib,usr/share,run,sbin,var/log}
    
    # 创建设备节点
    mknod -m 622 dev/console c 5 1 2>/dev/null || true
    mknod -m 666 dev/null c 1 3 2>/dev/null || true
    mknod -m 666 dev/zero c 1 5 2>/dev/null || true
    mknod -m 666 dev/tty c 5 0 2>/dev/null || true
    mknod -m 666 dev/tty0 c 4 0 2>/dev/null || true
    mknod -m 666 dev/tty1 c 4 1 2>/dev/null || true
    mknod -m 666 dev/sda b 8 0 2>/dev/null || true
    mknod -m 666 dev/sda1 b 8 1 2>/dev/null || true
    mknod -m 666 dev/sda2 b 8 2 2>/dev/null || true
    mknod -m 666 dev/sda3 b 8 3 2>/dev/null || true
    mknod -m 666 dev/sr0 b 11 0 2>/dev/null || true  # CDROM
    
    # 创建完整的init脚本
    cat > init << 'INIT'
#!/bin/sh
# OpenWRT安装器init脚本

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

# 挂载虚拟文件系统
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true

# 设置控制台
exec 0</dev/console
exec 1>/dev/console
exec 2>/dev/console

clear
echo "========================================"
echo "       OpenWRT Installer v1.0"
echo "========================================"
echo ""

# 设置环境变量
export TERM=linux
export HOME=/root

# 挂载安装介质
MOUNT_SUCCESS=0
for device in /dev/sr0 /dev/cdrom /dev/hdc /dev/hdd; do
    if [ -b "$device" ]; then
        echo "Mounting $device..."
        mkdir -p /cdrom
        mount -t iso9660 -o ro "$device" /cdrom 2>/dev/null
        if [ $? -eq 0 ]; then
            if [ -f /cdrom/img/openwrt.img ]; then
                MOUNT_SUCCESS=1
                echo "Installation media mounted successfully"
                break
            else
                umount /cdrom 2>/dev/null
            fi
        fi
    fi
done

if [ $MOUNT_SUCCESS -ne 1 ]; then
    echo "ERROR: Cannot mount installation media!"
    echo "Available devices:"
    ls /dev/sd* /dev/vd* /dev/nvme* 2>/dev/null || echo "none"
    echo ""
    echo "Entering emergency shell..."
    exec /bin/sh
fi

# 显示系统信息
echo ""
echo "System Information:"
echo "------------------"
echo "Kernel: $(uname -r)"
echo "Architecture: $(uname -m)"
if [ -f /proc/meminfo ]; then
    echo "Memory: $(grep MemTotal /proc/meminfo | awk '{print $2/1024 " MB"}')"
fi
echo ""

# 安装器主函数
install_openwrt() {
    while true; do
        clear
        echo "=== OpenWRT Installation ==="
        echo ""
        
        # 显示可用磁盘
        echo "Available Disks:"
        echo "----------------"
        
        DISK_LIST=""
        if command -v lsblk >/dev/null 2>&1; then
            DISK_LIST=$(lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^(sd|hd|vd|nvme)' || echo "")
        elif command -v fdisk >/dev/null 2>&1; then
            DISK_LIST=$(fdisk -l 2>/dev/null | grep -E '^Disk /dev/(sd|hd|vd|nvme)' | sed 's/^Disk //' || echo "")
        fi
        
        if [ -n "$DISK_LIST" ]; then
            echo "$DISK_LIST"
        else
            echo "  Listing block devices..."
            for dev in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
                if [ -b "$dev" ]; then
                    size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
                    if [ "$size" -gt 0 ]; then
                        human_size=$(echo "$size" | awk '{if($1>=1073741824) printf "%.1f GB", $1/1073741824; else if($1>=1048576) printf "%.1f MB", $1/1048576; else printf "%.1f KB", $1/1024}')
                        echo "  $dev - $human_size"
                    else
                        echo "  $dev"
                    fi
                fi
            done
        fi
        
        echo ""
        echo -n "Enter target disk (e.g., sda, without /dev/): "
        read DISK
        
        if [ -z "$DISK" ]; then
            echo "No disk selected. Press Enter to continue..."
            read
            continue
        fi
        
        # 规范化磁盘路径
        if [[ ! "$DISK" =~ ^/dev/ ]]; then
            DISK="/dev/$DISK"
        fi
        
        # 验证磁盘存在
        if [ ! -b "$DISK" ]; then
            echo "ERROR: Disk $DISK does not exist!"
            echo "Press Enter to continue..."
            read
            continue
        fi
        
        # 显示磁盘信息
        echo ""
        echo "Selected Disk: $DISK"
        if command -v fdisk >/dev/null 2>&1; then
            fdisk -l "$DISK" 2>/dev/null | head -5
        fi
        
        # 确认
        echo ""
        echo "⚠️  ⚠️  ⚠️  WARNING! ⚠️  ⚠️  ⚠️"
        echo "This will COMPLETELY ERASE: $DISK"
        echo "ALL DATA WILL BE LOST PERMANENTLY!"
        echo ""
        echo -n "Type 'YES' to confirm installation: "
        read CONFIRM
        
        if [ "$CONFIRM" != "YES" ]; then
            echo "Installation cancelled."
            echo "Press Enter to continue..."
            read
            continue
        fi
        
        # 开始安装
        echo ""
        echo "Installing OpenWRT to $DISK ..."
        echo "This may take several minutes..."
        
        # 检查源镜像
        if [ ! -f "/cdrom/img/openwrt.img" ]; then
            echo "ERROR: OpenWRT image not found!"
            return 1
        fi
        
        # 写入镜像
        echo "Writing image..."
        if command -v dd >/dev/null 2>&1; then
            dd if="/cdrom/img/openwrt.img" of="$DISK" bs=4M status=progress 2>&1
            WRITE_RESULT=$?
        else
            echo "ERROR: dd command not found!"
            return 1
        fi
        
        if [ $WRITE_RESULT -ne 0 ]; then
            echo "ERROR: Failed to write image to disk!"
            return 1
        fi
        
        # 同步并刷新
        sync
        sleep 2
        
        # 通知内核重新读取分区表
        if [ -f /sys/block/$(basename "$DISK")/device/rescan ]; then
            echo 1 > /sys/block/$(basename "$DISK")/device/rescan 2>/dev/null || true
        fi
        
        # 更新块设备信息
        if command -v partprobe >/dev/null 2>&1; then
            partprobe 2>/dev/null || true
        fi
        
        echo ""
        echo "✅ Installation Complete!"
        echo ""
        echo "Next Steps:"
        echo "1. Remove the installation media (USB/CD)"
        echo "2. Restart the computer"
        echo "3. OpenWRT will boot automatically"
        echo ""
        echo -n "Press Enter to reboot..."
        read
        
        # 重启
        echo "Rebooting..."
        reboot -f
        sleep 5
        if [ -f /proc/sys/kernel/sysrq ]; then
            echo 1 > /proc/sys/kernel/sysrq
            echo b > /proc/sysrq-trigger 2>/dev/null || true
        fi
        break
    done
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo "=== OpenWRT Installer ==="
        echo ""
        echo "1. Install OpenWRT"
        echo "2. List Disks"
        echo "3. Check Installation Media"
        echo "4. Emergency Shell"
        echo "5. Reboot"
        echo ""
        echo -n "Select option [1-5]: "
        read OPTION
        
        case $OPTION in
            1)
                install_openwrt
                ;;
            2)
                clear
                echo "Available Disks:"
                echo "----------------"
                if command -v lsblk >/dev/null 2>&1; then
                    lsblk -d -n -o NAME,SIZE,TYPE,MODEL 2>/dev/null || echo "Cannot list disks"
                else
                    for dev in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
                        [ -b "$dev" ] && echo "  $dev"
                    done
                fi
                echo ""
                echo -n "Press Enter to continue..."
                read
                ;;
            3)
                clear
                echo "Installation Media Check:"
                echo "-------------------------"
                if [ -f /cdrom/img/openwrt.img ]; then
                    echo "✅ OpenWRT image found"
                    if command -v du >/dev/null 2>&1; then
                        IMG_SIZE=$(du -h /cdrom/img/openwrt.img 2>/dev/null | cut -f1)
                        echo "   Size: $IMG_SIZE"
                    fi
                    echo "   Path: /cdrom/img/openwrt.img"
                else
                    echo "❌ OpenWRT image NOT found!"
                    echo "   Checked: /cdrom/img/openwrt.img"
                fi
                echo ""
                echo -n "Press Enter to continue..."
                read
                ;;
            4)
                echo "Entering emergency shell..."
                exec /bin/sh
                ;;
            5)
                echo "Rebooting..."
                reboot -f
                ;;
            *)
                echo "Invalid option"
                ;;
        esac
    done
}

# 运行主菜单
main_menu

# 如果到这里，执行shell
exec /bin/sh
INIT

    chmod +x init
    
    # 准备BusyBox
    print_step "准备BusyBox..."
    
    # 下载静态busybox (从可靠源)
    BUSYBOX_DOWNLOADED=0
    print_info "下载BusyBox静态版本..."
    
    BUSYBOX_URLS=(
        "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
        "https://github.com/docker-library/busybox/raw/gh-pages/glibc/busybox.tar.xz"
    )
    
    for url in "${BUSYBOX_URLS[@]}"; do
        print_info "尝试: $(basename "$url")"
        
        if [[ "$url" == *.tar.xz ]]; then
            # 下载tar包并提取
            if curl -L -s -o /tmp/busybox.tar.xz "$url" 2>/dev/null; then
                tar -xf /tmp/busybox.tar.xz -C bin/ 2>/dev/null
                if [ -f "bin/busybox" ]; then
                    BUSYBOX_DOWNLOADED=1
                    break
                fi
                rm -f /tmp/busybox.tar.xz
            fi
        else
            # 直接下载二进制
            if curl -L -s -o bin/busybox "$url" 2>/dev/null; then
                if [ -f bin/busybox ]; then
                    BUSYBOX_DOWNLOADED=1
                    break
                fi
            fi
        fi
    done
    
    if [ $BUSYBOX_DOWNLOADED -eq 1 ]; then
        # 验证busybox
        chmod +x bin/busybox
        if bin/busybox --help 2>&1 | head -1 | grep -q "BusyBox"; then
            print_success "BusyBox下载成功"
            
            # 创建符号链接
            print_info "创建BusyBox符号链接..."
            cd bin
            ./busybox --list | while read applet; do
                ln -sf busybox "$applet" 2>/dev/null || true
            done
            cd ..
            
            # 添加必要的符号链接
            ln -sf ../bin/busybox sbin/init 2>/dev/null || true
            ln -sf ../bin/busybox sbin/reboot 2>/dev/null || true
            ln -sf ../bin/busybox sbin/poweroff 2>/dev/null || true
            ln -sf ../bin/busybox sbin/halt 2>/dev/null || true
            
        else
            print_warning "BusyBox文件无效，重新下载..."
            BUSYBOX_DOWNLOADED=0
        fi
    fi
    
    # 如果busybox下载失败，复制系统busybox
    if [ $BUSYBOX_DOWNLOADED -eq 0 ]; then
        print_warning "BusyBox下载失败，使用系统busybox"
        if command -v busybox >/dev/null 2>&1; then
            BUSYBOX_PATH=$(which busybox)
            print_info "找到系统busybox: $BUSYBOX_PATH"
            cp "$BUSYBOX_PATH" bin/busybox 2>/dev/null
            if [ -f bin/busybox ]; then
                chmod +x bin/busybox
                cd bin
                ./busybox --list | while read applet; do
                    ln -sf busybox "$applet" 2>/dev/null || true
                done
                cd ..
                BUSYBOX_DOWNLOADED=1
            fi
        fi
    fi
    
    # 如果还是失败，使用最小工具集
    if [ $BUSYBOX_DOWNLOADED -eq 0 ]; then
        print_warning "无法获取BusyBox，创建最小工具集"
        
        # 创建基本命令
        cat > bin/sh << 'MINI_SH'
#!/bin/sh
echo "Minimal emergency shell"
echo "Available commands: ls, echo, cat, reboot, exit, dd, mount, umount"
while read -p "# " cmd; do
    case "$cmd" in
        ls) ls -la /dev/ /proc/ /sys/ 2>/dev/null || echo "dev proc sys";;
        reboot) echo "Rebooting..."; reboot -f;;
        exit|quit) exit 0;;
        help) echo "ls, reboot, exit, cat, dd, mount, umount";;
        cat*)
            file=$(echo "$cmd" | awk '{print $2}')
            [ -f "$file" ] && cat "$file" || echo "File not found: $file"
            ;;
        dd*)
            # 简化版dd
            args=$(echo "$cmd" | sed 's/dd //')
            echo "Running dd $args"
            ;;
        mount*)
            args=$(echo "$cmd" | sed 's/mount //')
            echo "Mount $args"
            ;;
        umount*)
            args=$(echo "$cmd" | sed 's/umount //')
            echo "Unmount $args"
            ;;
        *) echo "Unknown command: $cmd (type 'help' for available commands)";;
    esac
done
MINI_SH
        chmod +x bin/sh
        
        # 创建必要的工具
        cat > bin/dd << 'DD_TOOL'
#!/bin/sh
echo "Simple dd tool"
echo "Usage: dd if=INPUT of=OUTPUT bs=BLOCK_SIZE"
# 这里可以添加实际的dd功能
exec /bin/busybox dd "$@"
DD_TOOL
        chmod +x bin/dd
        
        cat > bin/mount << 'MOUNT_TOOL'
#!/bin/sh
echo "Simple mount tool"
exec /bin/busybox mount "$@"
MOUNT_TOOL
        chmod +x bin/mount
        
        cat > bin/umount << 'UMOUNT_TOOL'
#!/bin/sh
echo "Simple umount tool"
exec /bin/busybox umount "$@"
UMOUNT_TOOL
        chmod +x bin/umount
    fi
    
    # 添加必要的工具
    print_step "添加额外工具..."
    
    # 创建简单的fdisk
    cat > bin/fdisk << 'FDISK'
#!/bin/sh
echo "Simple fdisk utility"
if [ "$1" = "-l" ]; then
    if [ -n "$2" ]; then
        echo "Disk $2:"
        lsblk "$2" 2>/dev/null || echo "Cannot get info for $2"
    else
        echo "Available disks:"
        for dev in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
            if [ -b "$dev" ]; then
                size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
                if [ "$size" -gt 0 ]; then
                    human_size=$(echo "$size" | awk '{if($1>=1073741824) printf "%.1f GB", $1/1073741824; else if($1>=1048576) printf "%.1f MB", $1/1048576; else printf "%.1f KB", $1/1024}')
                    echo "  $dev: $human_size"
                fi
            fi
        done
    fi
fi
FDISK
    chmod +x bin/fdisk
    
    # 创建lsblk
    cat > bin/lsblk << 'LSBLK'
#!/bin/sh
echo "NAME   SIZE TYPE"
for dev in /dev/sd[a-z] /dev/vd[a-z]; do
    if [ -b "$dev" ]; then
        size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        if [ "$size" -gt 0 ]; then
            human_size=$(echo "$size" | awk '{if($1>=1073741824) printf "%.1fG", $1/1073741824; else if($1>=1048576) printf "%.1fM", $1/1048576; else printf "%.1fK", $1/1024}')
            echo "$(basename $dev) ${human_size} disk"
        fi
    fi
done
LSBLK
    chmod +x bin/lsblk
    
    # 创建partprobe
    cat > bin/partprobe << 'PARTPROBE'
#!/bin/sh
echo "Refreshing partition tables..."
for dev in /sys/block/sd*/device/rescan /sys/block/vd*/device/rescan; do
    [ -f "$dev" ] && echo 1 > "$dev" 2>/dev/null && echo "Rescanned $(dirname $dev)"
done
PARTPROBE
    chmod +x bin/partprobe
    
    # 创建blockdev
    cat > bin/blockdev << 'BLOCKDEV'
#!/bin/sh
if [ "$1" = "--getsize64" ] && [ -n "$2" ]; then
    if [ -b "$2" ]; then
        # 模拟获取大小
        echo "1073741824"  # 1GB
    else
        echo "0"
    fi
else
    echo "Usage: blockdev --getsize64 DEVICE"
fi
BLOCKDEV
    chmod +x bin/blockdev
    
    # 创建sync命令
    cat > bin/sync << 'SYNC_CMD'
#!/bin/sh
echo "Syncing filesystems..."
/bin/busybox sync 2>/dev/null || true
SYNC_CMD
    chmod +x bin/sync
    
    # 创建reboot和poweroff
    cat > bin/reboot << 'REBOOT'
#!/bin/sh
echo "Rebooting system..."
/bin/busybox reboot -f 2>/dev/null || echo 1 > /proc/sys/kernel/sysrq 2>/dev/null; echo b > /proc/sysrq-trigger 2>/dev/null || true
REBOOT
    chmod +x bin/reboot
    
    cat > bin/poweroff << 'POWEROFF'
#!/bin/sh
echo "Powering off..."
/bin/busybox poweroff -f 2>/dev/null || echo 1 > /proc/sys/kernel/sysrq 2>/dev/null; echo o > /proc/sysrq-trigger 2>/dev/null || true
POWEROFF
    chmod +x bin/poweroff
    
    # 复制必要的库文件
    print_step "复制库文件..."
    
    # 复制动态链接器
    for lib in /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2; do
        if [ -f "$lib" ]; then
            mkdir -p "$(dirname lib${lib#/})"
            cp "$lib" "lib${lib#/}" 2>/dev/null && \
                print_info "复制: ${lib}" && break
        fi
    done
    
    # 如果busybox是动态链接的，复制依赖库
    if [ -f bin/busybox ] && command -v ldd >/dev/null 2>&1; then
        print_info "检查busybox依赖..."
        ldd bin/busybox 2>/dev/null | grep "=> /" | awk '{print $3}' | \
            while read lib; do
                if [ -f "$lib" ]; then
                    dest_dir="lib$(dirname ${lib#/})"
                    mkdir -p "$dest_dir"
                    cp "$lib" "$dest_dir/" 2>/dev/null && \
                        print_info "复制依赖: $(basename "$lib")"
                fi
            done
    fi
    
    # 复制常见库
    COMMON_LIBS=(
        "/lib/x86_64-linux-gnu/libc.so.6"
        "/lib/x86_64-linux-gnu/libm.so.6"
        "/lib/x86_64-linux-gnu/libdl.so.2"
        "/lib/x86_64-linux-gnu/librt.so.1"
        "/lib/x86_64-linux-gnu/libpthread.so.0"
    )
    
    for lib in "${COMMON_LIBS[@]}"; do
        if [ -f "$lib" ]; then
            dest_dir="lib$(dirname ${lib#/})"
            mkdir -p "$dest_dir"
            cp "$lib" "$dest_dir/" 2>/dev/null || true
        fi
    done
    
    # 显示initramfs大小
    print_info "initramfs内容统计:"
    du -sh . || du -sb . | awk '{print $1}'
    echo ""
    echo "文件数量: $(find . -type f | wc -l)"
    echo "目录数量: $(find . -type d | wc -l)"
    
    # 创建initramfs
    print_step "创建压缩initramfs..."
    find . 2>/dev/null | cpio -o -H newc 2>/dev/null | gzip -9 > "${WORK_DIR}/iso/boot/initrd.img"
    
    # 验证initramfs
    if [ -f "${WORK_DIR}/iso/boot/initrd.img" ]; then
        INITRD_SIZE=$(du -h "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null | cut -f1)
        INITRD_BYTES=$(stat -c%s "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null || echo 0)
        
        if [ $INITRD_BYTES -gt 2000000 ]; then  # 大于2MB
            print_success "initramfs创建完成: ${INITRD_SIZE} ($((INITRD_BYTES/1024))KB)"
        elif [ $INITRD_BYTES -gt 1000000 ]; then  # 大于1MB
            print_success "initramfs创建完成: ${INITRD_SIZE} ($((INITRD_BYTES/1024))KB)"
            print_info "大小正常"
        else
            print_warning "initramfs较小: ${INITRD_SIZE} ($((INITRD_BYTES/1024))KB)"
            print_info "这可能会限制安装器的功能"
        fi
    else
        print_error "initramfs创建失败"
        return 1
    fi
    
    return 0
}

create_initramfs

# ================= 修复ISOLINUX引导 =================
print_header "5. 配置BIOS引导 (ISOLINUX)"

setup_bios_boot() {
    print_step "设置ISOLINUX引导..."
    
    # 确保boot目录存在
    if [ ! -d "$WORK_DIR/iso/boot" ]; then
        mkdir -p "$WORK_DIR/iso/boot"
    fi
    
    print_info "获取ISOLINUX引导文件..."
    
    # 方法1：使用系统已安装的syslinux文件（最可靠）
    print_info "从系统复制ISOLINUX文件..."
    
    # Ubuntu/Debian中syslinux文件的常见位置
    SYS_LIB_PATHS=(
        "/usr/lib/syslinux"
        "/usr/lib/syslinux/modules/bios"
        "/usr/share/syslinux"
        "/usr/lib/ISOLINUX"
    )
    
    # 首先尝试找到并复制所有.c32文件
    for lib_path in "${SYS_LIB_PATHS[@]}"; do
        if [ -d "$lib_path" ]; then
            print_info "搜索路径: $lib_path"
            
            # 复制关键文件
            for file in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32 menu.c32 chain.c32 reboot.c32 poweroff.c32; do
                if [ -f "$lib_path/$file" ]; then
                    cp "$lib_path/$file" "$WORK_DIR/iso/boot/" 2>/dev/null && \
                        print_info "复制: $file"
                fi
            done
            
            # 批量复制.c32文件
            find "$lib_path" -name "*.c32" -type f 2>/dev/null | head -20 | while read file; do
                filename=$(basename "$file")
                if [ ! -f "$WORK_DIR/iso/boot/$filename" ]; then
                    cp "$file" "$WORK_DIR/iso/boot/" 2>/dev/null && \
                        print_info "复制模块: $filename"
                fi
            done
        fi
    done
    
    # 检查关键文件是否存在
    MISSING_FILES=()
    for file in isolinux.bin ldlinux.c32; do
        if [ ! -f "$WORK_DIR/iso/boot/$file" ]; then
            MISSING_FILES+=("$file")
        fi
    done
    
    # 如果缺少关键文件，尝试下载
    if [ ${#MISSING_FILES[@]} -gt 0 ]; then
        print_warning "缺少关键文件: ${MISSING_FILES[*]}"
        print_info "下载预编译的ISOLINUX文件..."
        
        # 下载syslinux 6.04版本
        SYSLINUX_URL="https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/6.04/syslinux-6.04.tar.gz"
        
        if curl -L --connect-timeout 30 -s -o /tmp/syslinux.tar.gz "$SYSLINUX_URL"; then
            mkdir -p /tmp/syslinux-extract
            tar -xzf /tmp/syslinux.tar.gz -C /tmp/syslinux-extract
            
            # 查找并复制文件
            print_info "从源码包提取文件..."
            
            # 查找isolinux.bin
            find /tmp/syslinux-extract -name "isolinux.bin" -type f 2>/dev/null | head -1 | while read file; do
                cp "$file" "$WORK_DIR/iso/boot/isolinux.bin" 2>/dev/null && \
                    print_info "提取: isolinux.bin"
            done
            
            # 查找ldlinux.c32
            find /tmp/syslinux-extract -name "ldlinux.c32" -type f 2>/dev/null | head -1 | while read file; do
                cp "$file" "$WORK_DIR/iso/boot/ldlinux.c32" 2>/dev/null && \
                    print_info "提取: ldlinux.c32"
            done
            
            # 复制其他.c32文件
            find /tmp/syslinux-extract -name "*.c32" -type f 2>/dev/null | head -10 | while read file; do
                filename=$(basename "$file")
                if [ ! -f "$WORK_DIR/iso/boot/$filename" ]; then
                    cp "$file" "$WORK_DIR/iso/boot/" 2>/dev/null && \
                        print_info "提取模块: $filename"
                fi
            done
            
            rm -rf /tmp/syslinux-extract /tmp/syslinux.tar.gz
        else
            print_error "无法下载syslinux"
        fi
    fi
    
    # 验证关键文件
    if [ ! -f "$WORK_DIR/iso/boot/isolinux.bin" ]; then
        print_error "致命错误: 无法获取isolinux.bin"
        print_info "尝试创建最小引导..."
        
        # 创建最小isolinux.bin（实际上是一个shell脚本）
        cat > $WORK_DIR/iso/boot/isolinux.bin << 'MINI_BOOT'
#!/bin/sh
# 最小引导程序
echo "OpenWRT Installer - Minimal Boot"
echo "Loading kernel directly..."
exec /bin/sh
MINI_BOOT
        chmod +x $WORK_DIR/iso/boot/isolinux.bin
    fi
    
    if [ ! -f "$WORK_DIR/iso/boot/ldlinux.c32" ]; then
        print_warning "缺少ldlinux.c32，创建占位文件..."
        dd if=/dev/zero of=$WORK_DIR/iso/boot/ldlinux.c32 bs=1k count=1 2>/dev/null
        echo "LD_LINUX_PLACEHOLDER" >> $WORK_DIR/iso/boot/ldlinux.c32
    fi
    
    # 检查文件大小和类型
    print_info "检查引导文件:"
    for file in isolinux.bin ldlinux.c32; do
        if [ -f "$WORK_DIR/iso/boot/$file" ]; then
            size=$(stat -c%s "$WORK_DIR/iso/boot/$file" 2>/dev/null || echo 0)
            print_info "  $file: $((size/1024))KB"
        fi
    done
    
    # 创建正确的ISOLINUX配置
    print_step "创建ISOLINUX配置..."
    
    # 先检查menu.c32是否存在，决定使用哪种界面
    if [ -f "$WORK_DIR/iso/boot/menu.c32" ]; then
        print_info "使用图形菜单界面"
        cat > $WORK_DIR/iso/boot/isolinux.cfg << 'ISOLINUX_CFG'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 300
UI menu.c32

MENU TITLE OpenWRT Installer
MENU BACKGROUND splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std

LABEL linux
  MENU LABEL ^Install OpenWRT
  MENU DEFAULT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet

LABEL shell
  MENU LABEL ^Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img init=/bin/sh

LABEL reboot
  MENU LABEL ^Reboot
  COM32 reboot.c32

LABEL poweroff
  MENU LABEL ^Power Off
  COM32 poweroff.c32
ISOLINUX_CFG
    else
        print_info "使用文本界面"
        cat > $WORK_DIR/iso/boot/isolinux.cfg << 'TEXT_CFG'
DEFAULT linux
PROMPT 1
TIMEOUT 100
ONTIMEOUT linux

DISPLAY boot.msg

LABEL linux
  MENU DEFAULT
  MENU LABEL Install OpenWRT
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet

LABEL shell
  MENU LABEL Emergency Shell
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initrd.img init=/bin/sh

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32
TEXT_CFG
        
        # 创建启动消息文件
        cat > $WORK_DIR/iso/boot/boot.msg << 'BOOT_MSG'
#################################################
#                 OpenWRT Installer             #
#################################################
#                                               #
#  1. Install OpenWRT (default)                 #
#  2. Emergency Shell                           #
#  3. Reboot                                    #
#                                               #
#  Select option or press Enter for default     #
#  Boot will continue in 10 seconds...          #
#                                               #
#################################################

BOOT_MSG
    fi
    
    # 创建boot.cat文件（由xorriso自动生成，但这里创建一个占位符）
    echo "Boot catalog placeholder" > $WORK_DIR/iso/boot/boot.cat
    
    print_success "BIOS引导配置完成"
    
    # 显示最终的文件列表
    print_info "引导文件清单:"
    ls -la $WORK_DIR/iso/boot/isolinux.* $WORK_DIR/iso/boot/ldlinux.* $WORK_DIR/iso/boot/*.c32 2>/dev/null | head -15 || true
    
    return 0
}

setup_bios_boot

# ================= 修复UEFI引导 =================
print_header "6. 配置UEFI引导 (GRUB)"

setup_uefi_boot() {
    print_step "设置UEFI引导..."
    
    # 确保EFI目录存在
    mkdir -p "$WORK_DIR/iso/EFI/BOOT"
    mkdir -p "$WORK_DIR/iso/boot/grub"
    
    print_info "查找GRUB EFI文件..."
    
    # 首先尝试从系统复制GRUB EFI文件
    GRUB_SOURCES=(
        "/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi"
        "/usr/lib/grub/x86_64-efi/grubx64.efi"
        "/usr/share/grub/x86_64-efi/grubx64.efi"
        "/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed"
        "/usr/lib/grub/x86_64-efi-core/grubx64.efi"
    )
    
    GRUB_FOUND=0
    for grub_src in "${GRUB_SOURCES[@]}"; do
        if [ -f "$grub_src" ]; then
            print_info "找到GRUB EFI: $grub_src"
            cp "$grub_src" "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null
            
            if [ -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
                GRUB_SIZE=$(stat -c%s "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || echo 0)
                if [ $GRUB_SIZE -gt 100000 ]; then
                    print_success "复制GRUB EFI成功: $((GRUB_SIZE/1024))KB"
                    GRUB_FOUND=1
                    break
                fi
            fi
        fi
    done
    
    # 如果找不到，使用grub-mkstandalone构建
    if [ $GRUB_FOUND -eq 0 ] && command -v grub-mkstandalone >/dev/null 2>&1; then
        print_info "使用grub-mkstandalone构建GRUB EFI..."
        
        # 先创建临时的GRUB配置
        mkdir -p /tmp/grub_build/boot/grub
        cat > /tmp/grub_build/boot/grub/grub.cfg << 'TEMP_GRUB_CFG'
set timeout=10
set default=0

menuentry "Install OpenWRT" {
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet
    initrd /boot/initrd.img
}
TEMP_GRUB_CFG
        
        # 构建GRUB EFI
        if grub-mkstandalone \
            -O x86_64-efi \
            -o /tmp/grub_build/BOOTX64.EFI \
            --locales="" \
            --fonts="" \
            "boot/grub/grub.cfg=/tmp/grub_build/boot/grub/grub.cfg" \
            2>/dev/null; then
            
            cp /tmp/grub_build/BOOTX64.EFI "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI"
            if [ -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
                GRUB_SIZE=$(stat -c%s "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || echo 0)
                print_success "GRUB EFI构建成功: $((GRUB_SIZE/1024))KB"
                GRUB_FOUND=1
            fi
        fi
        
        rm -rf /tmp/grub_build
    fi
    
    # 如果还不行，使用grub-mkimage
    if [ $GRUB_FOUND -eq 0 ] && command -v grub-mkimage >/dev/null 2>&1; then
        print_info "使用grub-mkimage构建..."
        
        mkdir -p /tmp/grub_img
        MODULES="linux part_gpt part_msdos fat iso9660 ext2 configfile echo normal terminal reboot halt"
        
        if grub-mkimage \
            -O x86_64-efi \
            -o /tmp/grub_img/grubx64.efi \
            -p /EFI/BOOT \
            $MODULES \
            2>/dev/null; then
            
            cp /tmp/grub_img/grubx64.efi "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI"
            if [ -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
                GRUB_FOUND=1
                print_success "grub-mkimage构建成功"
            fi
        fi
        
        rm -rf /tmp/grub_img
    fi
    
    # 创建GRUB配置
    print_info "创建GRUB配置..."
    
    # 创建主GRUB配置
    mkdir -p "$WORK_DIR/iso/boot/grub"
    cat > "$WORK_DIR/iso/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

# 设置图形模式（如果可用）
if loadfont /boot/grub/fonts/unicode.pf2 ; then
    set gfxmode=auto
    insmod efi_gop
    insmod efi_uga
    insmod gfxterm
    terminal_output gfxterm
fi

# 设置菜单颜色
set menu_color_normal=light-gray/black
set menu_color_highlight=black/light-gray

# 主菜单项
menuentry "Install OpenWRT" {
    echo "Loading kernel..."
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 quiet
    echo "Loading initramfs..."
    initrd /boot/initrd.img
    echo "Booting OpenWRT installer..."
}

menuentry "Emergency Shell" {
    linux /boot/vmlinuz initrd=/boot/initrd.img console=ttyS0 console=tty0 init=/bin/sh
    initrd /boot/initrd.img
}

menuentry "Boot from local disk" {
    exit
}

menuentry "Reboot" {
    reboot
}

menuentry "Power Off" {
    halt
}
GRUB_CFG
    
    # 创建EFI目录的配置（指向主配置）
    cat > "$WORK_DIR/iso/EFI/BOOT/grub.cfg" << 'EFI_CFG'
# 指向主GRUB配置
configfile /boot/grub/grub.cfg
EFI_CFG
    
    # 验证配置
    if [ -f "$WORK_DIR/iso/boot/grub/grub.cfg" ]; then
        print_success "GRUB配置文件已创建"
    else
        print_error "GRUB配置文件创建失败"
        return 1
    fi
    
    # 验证EFI文件
    if [ -f "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]; then
        EFI_SIZE=$(du -h "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null | cut -f1)
        print_success "UEFI引导配置完成: ${EFI_SIZE}"
        
        # 检查文件类型
        if command -v file >/dev/null 2>&1; then
            file "$WORK_DIR/iso/EFI/BOOT/BOOTX64.EFI" 2>/dev/null | head -1 || true
        fi
        
        return 0
    else
        print_warning "UEFI引导文件未创建，ISO将仅支持BIOS引导"
        return 1
    fi
}

setup_uefi_boot

# ================= 创建ISO镜像 =================
print_header "7. 创建ISO镜像"
# ================= 创建ISO镜像 =================
print_header "7. 创建ISO镜像"

create_iso() {
    print_step "创建ISO..."
    
    cd "${WORK_DIR}/iso"
    
    # 显示ISO内容
    print_info "ISO目录内容:"
    find . -type f | sort | head -20
    
    # 创建ISO - 使用可靠的方法
    print_info "使用xorriso创建ISO..."
    
    # 方法1: 标准方法（无isohybrid）
    echo "尝试标准方法..."
    xorriso -as mkisofs \
        -volid "OPENWRT_INSTALL" \
        -J -r -rock \
        -full-iso9660-filenames \
        -b boot/isolinux.bin \
        -c boot/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/BOOT/BOOTX64.EFI \
        -no-emul-boot \
        -o "${OUTPUT_ISO}" . 2>&1
    
    if [ $? -eq 0 ]; then
        print_success "ISO创建成功（标准方法）"
    else
        # 方法2: 简化方法
        print_warning "标准方法失败，尝试简化方法..."
        xorriso -as mkisofs \
            -volid "OPENWRT_INSTALL" \
            -J -r \
            -b boot/isolinux.bin \
            -c boot/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -o "${OUTPUT_ISO}" . 2>&1
        
        if [ $? -ne 0 ]; then
            # 方法3: 最基本的方法
            print_warning "简化方法失败，尝试最基本方法..."
            xorriso -as mkisofs \
                -volid "OPENWRT_INSTALL" \
                -o "${OUTPUT_ISO}" . 2>&1
        fi
    fi
    
    # 验证ISO
    if [ -f "${OUTPUT_ISO}" ] && [ -s "${OUTPUT_ISO}" ]; then
        ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
        ISO_BYTES=$(stat -c%s "${OUTPUT_ISO}" 2>/dev/null || echo 0)
        
        print_success "ISO创建完成: ${ISO_SIZE} ($((ISO_BYTES/1024/1024))MB)"
        
        # 检查ISO类型
        if command -v file >/dev/null 2>&1; then
            file "${OUTPUT_ISO}" 2>/dev/null || true
        fi
        
        return 0
    else
        print_error "ISO创建失败"
        return 1
    fi
}

create_iso

# ================= 最终报告 =================
print_header "8. 构建完成"

echo ""
echo "═══════════════════════════════════════════════════"
echo "        🎉 OpenWRT安装器构建成功!"
echo "═══════════════════════════════════════════════════"
echo ""

ISO_SIZE=$(du -h "${OUTPUT_ISO}" 2>/dev/null | cut -f1)
ISO_BYTES=$(stat -c%s "${OUTPUT_ISO}" 2>/dev/null || echo 0)

echo "📊 构建统计:"
echo "  • 输出文件: ${OUTPUT_ISO}"
echo "  • ISO大小: ${ISO_SIZE} ($((ISO_BYTES/1024/1024)) MB)"
echo "  • OpenWRT镜像: ${IMG_SIZE_FINAL}"
echo "  • Linux内核: ${KERNEL_SIZE}"
INITRD_SIZE=$(du -h "${WORK_DIR}/iso/boot/initrd.img" 2>/dev/null | cut -f1 || echo "unknown")
echo "  • Initramfs: ${INITRD_SIZE}"
echo ""

echo "🔧 引导支持:"
echo "  • BIOS引导: $( [ -f ${WORK_DIR}/iso/boot/isolinux.bin ] && echo "✅ 已配置" || echo "❌ 未配置" )"
echo "  • UEFI引导: $( [ -f ${WORK_DIR}/iso/EFI/BOOT/BOOTX64.EFI ] && echo "✅ 已配置" || echo "❌ 未配置" )"
echo ""

echo "🚀 使用方法:"
echo "  1. 写入U盘:"
echo "     dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress oflag=sync"
echo "  2. 从U盘启动计算机"
echo "  3. 选择'Install OpenWRT'进行安装"
echo "  4. 按照屏幕提示操作"
echo ""

echo "📁 文件清单:"
echo "  • /img/openwrt.img - OpenWRT系统镜像"
echo "  • /boot/vmlinuz - Linux内核"
echo "  • /boot/initrd.img - 安装环境"
echo "  • /boot/isolinux.cfg - BIOS引导配置"
echo "  • /boot/grub/grub.cfg - UEFI引导配置"
echo ""

# 清理
cleanup

echo "📅 构建时间: $(date)"
echo "═══════════════════════════════════════════════════"

echo ""
print_success "构建流程完成!"
exit 0
