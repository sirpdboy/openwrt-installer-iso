FROM debian:bullseye-slim

# 设置环境变量
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

# 安装构建工具
RUN apt-get update && apt-get install -y \
    # 基础工具
    wget curl ca-certificates \
    # ISO构建工具
    xorriso isolinux syslinux-efi \
    grub-pc-bin grub-efi-amd64-bin grub-efi-ia32-bin \
    mtools dosfstools \
    # 文件系统工具
    squashfs-tools gzip bzip2 xz-utils \
    # 编译工具
    build-essential \
    # 内核工具
    kmod cpio file \
    # 脚本工具
    jq bc p7zip-full \
    # 网络工具
    iproute2 net-tools \
    # 清理
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 创建目录结构
WORKDIR /workspace
RUN mkdir -p /output /scripts /config /assets

# 复制构建脚本
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# 设置容器用户（非root运行）
RUN useradd -m -u 1000 builder && \
    chown -R builder:builder /workspace /output /scripts
USER builder

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD test -f /tmp/.build-ready || exit 1

# 默认命令
CMD ["/scripts/build-iso-docker.sh"]
