FROM debian:buster-slim

# 设置元数据
LABEL maintainer="sirpdboy"
LABEL description="OpenWRT IMG to ISO Builder"
LABEL version="1.0"

# 设置环境
ENV DEBIAN_FRONTEND=noninteractive
ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8

# 设置工作目录
WORKDIR /build

# 安装必要工具
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        curl \
        gnupg \
        && \
    echo "deb http://archive.debian.org/debian buster main" > /etc/apt/sources.list && \
    echo "deb http://archive.debian.org/debian-security buster/updates main" >> /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until && \
    apt-get update && \
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
        live-boot \
        live-boot-initramfs-tools \
        pv \
        file \
        dialog \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 创建挂载点
RUN mkdir -p /mnt /output

# 设置入口点
ENTRYPOINT ["/build.sh"]
