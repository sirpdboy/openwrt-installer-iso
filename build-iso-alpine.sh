name: build-iso-alpine

on:
  push:
    branches: [ main, master ]
    paths:
      - 'build-iso-alpine.sh'
      - '.github/workflows/build-iso-alpine.yml'
  workflow_dispatch:
    inputs:
      alpine_version:
        description: 'ubuntu版本'
        required: false
        default: '3.20'

jobs:
  build-alpine-iso:
    runs-on: ubuntu-latest
    
    steps:
    - name: Checkout code
      uses: actions/checkout@v4
    
    - name: Setup environment
      run: |
        sudo apt-get update
        sudo apt-get install -y \
            wget \
            curl \
            xorriso \
            syslinux \
            mtools \
            dosfstools \
            squashfs-tools \
            e2fsprogs \
            parted \
            gdisk \
            jq
    
    
    - name: Download OpenWRT image
      run: |
        mkdir -p assets
        
        # 使用你的下载脚本或直接下载
        if [ -f scripts/download-image.sh ]; then
          chmod +x scripts/download-image.sh
          ./scripts/download-image.sh
        else
          echo "下载OpenWRT镜像..."
          REPO="sirpdboy/openwrt"
          TAG=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | jq -r '.tag_name // empty')
          DOWNLOAD_URLS=$(curl -sL "https://api.github.com/repos/$REPO/releases/tags/$TAG" | \
                jq -r '.assets[] | select(.name | endswith("img.gz")) | .browser_download_url')
          FIRST_URL=$(echo "$DOWNLOAD_URLS" | head -n1)
          echo "下载: $FIRST_URL"
          wget -q $FIRST_URL  -O assets/ezopwrt.img.gz
           if [ ! -f "assets/ezopwrt.img.gz" ]; then
             curl -L -o "$OUTPUT_FILE"  --progress-bar --retry 3 "$FIRST_URL" 
           fi
        
           if [ $? -eq 0 ]; then
               echo "✅ 下载完成"
               gzip -d assets/ezopwrt.img.gz
            fi
        fi
        echo "✅ 镜像大小: $(stat -c%s assets/ezopwrt.img | numfmt --to=iec)"
    
    - name: Create output directory
      run: |
        mkdir -p output
        chmod 777 output
      
    - name: Build ISO with Alpine in Docker
      run: |
        # 给脚本执行权限
        chmod +x build-iso-alpine.sh
        
        echo "� 在Alpine Docker容器中构建ISO..."
        
        # 使用带有网络修复的Docker运行命令
        docker run --privileged --rm \
          --network host \
          -e http_proxy="${HTTP_PROXY:-}" \
          -e https_proxy="${HTTPS_PROXY:-}" \
          -e no_proxy="${NO_PROXY:-}" \
          -v "$(pwd)/output:/output" \
          -v "$(pwd)/assets/ezopwrt.img:/mnt/ezopwrt.img:ro" \
          -v "$(pwd)/build-iso-alpine.sh:/build-iso-alpine.sh:ro" \
          alpine:3.20 \
          sh -c "
          # 设置环境
          export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
          
          # 配置DNS和网络
          echo '配置网络...'
          echo 'nameserver 8.8.8.8' > /etc/resolv.conf
          echo 'nameserver 1.1.1.1' >> /etc/resolv.conf
          echo 'nameserver 8.8.4.4' >> /etc/resolv.conf
          
          # 安装必要工具（带重试）
          echo '安装构建工具...'
          apk update --no-cache
          
          # 尝试安装核心包
          for i in 1 2 3; do
              if apk add --no-cache \
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
                  bash; then
                  echo '✅ 工具安装成功'
                  break
              else
                  echo \"⚠️  安装失败，重试 \$i/3...\"
                  sleep 2
              fi
          done
          
          # 执行构建脚本
          echo '开始构建ISO...'
          /build-iso-alpine.sh
          "
      
        echo "✅ Docker容器执行完成"
    
    - name: Check ISO file
      run: |
        echo "� 检查输出文件:"
        ls -lh output/
        
        if [ -f "output/openwrt-installer-alpine.iso" ]; then
            echo "✅ ISO文件存在"
            echo "大小: $(ls -lh output/openwrt-installer-alpine.iso | awk '{print $5}')"
        else
            echo "❌ ISO文件未生成"
            echo "当前目录内容:"
            find output/ -type f
            exit 1
        fi
    
    - name: Upload ISO artifact
      uses: actions/upload-artifact@v4
      with:
        name: openwrt-alpine-installer
        path: output/*.iso
        retention-days: 30
        if-no-files-found: error
    
    - name: Create release
      if: startsWith(github.ref, 'refs/tags/')
      uses: softprops/action-gh-release@v1
      with:
        files: output/*.iso
        body: |
          # OpenWRT Alpine 安装器
          
          ## � 特点
          - � 基于 Alpine Linux，极简轻量
          - � ISO大小仅 50-80MB
          - � 自动启动，无需密码
          - � 自动登录 root 用户
          - � 支持 UEFI 和传统 BIOS
          - ⚡ 快速启动，低内存占用
          
          ## � 构建信息
          - 版本: ${{ github.ref_name }}
          - 时间: $(date -u +"%Y-%m-%d %H:%M:%S")
          - 系统: Alpine Linux 3.20
          - 架构: x86_64
          - 提交: ${{ github.sha }}
          
          ## � 使用说明
          1. 下载 ISO 文件
          2. 使用 Rufus、Etcher 或 dd 写入 U 盘
          3. 从 U 盘启动计算机
          4. 系统会自动启动 OpenWRT 安装程序
          5. 按照提示完成安装
          
          ## � 手动操作
          如果自动安装未启动，可以手动运行:
          ```
          /opt/install-openwrt.sh
          ```
