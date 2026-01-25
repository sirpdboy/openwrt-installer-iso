FROM debian:buster-slim

# 设置元数据
LABEL maintainer="sirpdboy"
LABEL description="OpenWRT IMG to ISO Builder"
LABEL version="1.0"

# 设置环境变量
ENV DEBIAN_FRONTEND=noninteractive
ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8

# 配置APT源
RUN echo "deb http://archive.debian.org/debian buster main contrib non-free" > /etc/apt/sources.list && \
    echo "deb http://archive.debian.org/debian-security buster/updates main" >> /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until && \
    echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/99no-check-valid-until

# 安装所有必要工具
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        debootstrap \
        squashfs-tools \
        xorriso \
        isolinux \
        syslinux \
        syslinux-common \
        grub-pc-bin \
        grub-efi-amd64-bin \
        mtools \
        dosfstools \
        parted \
        wget \
        curl \
        gnupg \
        dialog \
        live-boot \
        live-boot-initramfs-tools \
        pv \
        file \
        gddrescue \
        gdisk \
        cifs-utils \
        nfs-common \
        ntfs-3g \
        open-vm-tools \
        wimtools \
        ca-certificates \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 创建工作目录
WORKDIR /build

# 创建挂载点目录
RUN mkdir -p /mnt /output

# 复制构建脚本
COPY build.sh /build.sh
RUN chmod +x /build.sh

# 设置入口点
ENTRYPOINT ["/build.sh"]
