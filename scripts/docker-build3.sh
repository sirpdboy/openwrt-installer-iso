name: Build-Alpine-ISO3

on:
  workflow_dispatch:
  push:
    branches: [ main ]
    paths:
      - 'scripts/docker-build3.sh'
      - '.github/workflows/Build-Alpine-ISO3.yml'

jobs:
  build:
    runs-on: ubuntu-22.04
    
    steps:
    - name: Checkout repository
      uses: actions/checkout@v4
      with:
        persist-credentials: false
        
    - name: Install dependencies
      run: |
        sudo apt-get update
        sudo apt-get install -y \
          grub2-common \
          grub-pc-bin \
          grub-efi-amd64-bin \
          xorriso \
          mtools \
          dosfstools \
          wget \
          qemu-system-x86
        
    - name: Make script executable
      run: |
        chmod +x scripts/docker-build3.sh
        
    - name: Build ISO
      run: |
        # 在根目录运行脚本，这样ISO会生成在根目录
        ./scripts/docker-build3.sh
        
        # 检查生成的文件
        echo "=== 生成的文件 ==="
        find . -name "*.iso" -type f | xargs ls -lh
        echo ""
        
        # 确认ISO位置
        echo "=== 当前目录 ==="
        pwd
        ls -la
        echo ""
        
        # 移动所有ISO文件到当前目录
        find . -name "*.iso" -type f -exec mv {} . \; 2>/dev/null || true
        
        echo "=== 移动后 ==="
        ls -lh *.iso 2>/dev/null || echo "没有找到ISO文件"
        
    - name: Upload ISO artifact
      uses: actions/upload-artifact@v4
      with:
        name: minimal-live-iso
        path: "minimal-live-*.iso"
        if-no-files-found: error
        retention-days: 7
        
    - name: Quick test
      run: |
        if ls minimal-live-*.iso 1> /dev/null 2>&1; then
            echo "=== 快速测试 ==="
            ISO_FILE=$(ls -t minimal-live-*.iso | head -1)
            
            # 测试ISO是否可引导
            timeout 3 qemu-system-x86_64 \
                -cdrom "$ISO_FILE" \
                -m 256 \
                -boot d \
                -serial stdio \
                -display none \
                2>&1 | grep -i -E "(booting|loading|kernel|error)" | head -10 || true
        else
            echo "错误: 找不到ISO文件"
            find . -name "*.iso" -type f
        fi
