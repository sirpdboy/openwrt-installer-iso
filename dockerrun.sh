#!/bin/bash
# dockerrun.sh -

# 参数
INPUT_IMG="$1"
OUTPUT_DIR="$2"
OUTPUT_ISO_NAME="$3"

sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        sudo apt-get autoremove -y
        
        # 安装必要依赖
        sudo apt-get update
        sudo apt-get install -y \
            ca-certificates \
            curl \
            gnupg \
            lsb-release
        
        # 添加Docker官方GPG密钥
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        
        # 设置仓库
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # 安装Docker
        sudo apt-get update
        sudo apt-get install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-compose-plugin
        
        # 启动服务
        sudo systemctl start docker
        sudo systemctl enable docker
                    # 1. 确保脚本有权限
            chmod +x build.sh
    
            # 2. 复制脚本到容器内执行
            docker run --privileged --rm \
              -v $(pwd)/$OUTPUT_DIR:/output \
              -v $(pwd)/${INPUT_IMG}:/mnt/ezopwrt.img:ro \
              -v $(pwd)/build.sh:/build.sh:ro \
              debian:buster \
              bash -c "
              # 安装必要工具
              apt-get update
              apt-get install -y \
                debootstrap squashfs-tools xorriso isolinux syslinux-efi \
                grub-pc-bin grub-efi-amd64-bin mtools dosfstools parted wget curl
       
              /build.sh
              "
