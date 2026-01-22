FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# 安装构建工具
RUN apt-get update && apt-get install -y \
    wget curl xorriso isolinux syslinux-efi \
    grub-pc-bin grub-efi-amd64-bin grub-efi-ia32-bin \
    mtools dosfstools squashfs-tools \
    p7zip-full git build-essential \
    kernel-package fakeroot libncurses5-dev libssl-dev \
    bc kmod cpio gcc g++ make libc6-dev \
    ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 创建工作目录
WORKDIR /workspace

# 复制脚本
COPY scripts/ /workspace/scripts/
RUN chmod +x /workspace/scripts/*

# 设置入口点
ENTRYPOINT ["/workspace/scripts/build-iso.sh"]
