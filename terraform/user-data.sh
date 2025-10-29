#!/bin/bash
set -e
set -x

# Redirect all output to log file
exec > >(tee -a /var/log/user-data.log)
exec 2>&1

echo "=== Starting user data script at $(date) ==="

# Update apt package index and install system packages
echo "=== Installing system packages ==="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    pkg-config \
    libssl-dev \
    git \
    curl \
    wget

# Install SSM Agent if not already installed
echo "=== Installing SSM Agent ==="
if ! systemctl is-active --quiet amazon-ssm-agent; then
    snap install amazon-ssm-agent --classic
    systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
    systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service
    echo "SSM Agent installed and started"
else
    echo "SSM Agent already running"
fi

# Check if CUDA is already installed
echo "=== Checking CUDA installation ==="
if ! command -v nvidia-smi &> /dev/null; then
    echo "CUDA not found, installing CUDA 12.2..."
    
    # Install GCC-12 to match kernel build requirements
    apt-get install -y gcc-12 g++-12
    update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100
    update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 100
    
    # Install kernel headers
    apt-get install -y linux-headers-$(uname -r) linux-modules-extra-$(uname -r)
    
    # Install CUDA 12.2 from NVIDIA repository
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i cuda-keyring_1.1-1_all.deb
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y cuda-toolkit-12-2 cuda-drivers \
        cuda-cudart-dev-12-2 cuda-nvrtc-dev-12-2 libcublas-dev-12-2 libcurand-dev-12-2
    
    # Add CUDA to PATH
    echo 'export PATH=/usr/local/cuda-12.2/bin:$PATH' >> /etc/profile.d/cuda.sh
    echo 'export LD_LIBRARY_PATH=/usr/local/cuda-12.2/lib64:$LD_LIBRARY_PATH' >> /etc/profile.d/cuda.sh
    source /etc/profile.d/cuda.sh
    
    echo "CUDA installation completed"
else
    echo "CUDA already installed"
fi

# Verify CUDA installation
echo "=== Verifying CUDA installation ==="
nvidia-smi

# Install Rust toolchain as ubuntu user
echo "=== Installing Rust toolchain ==="
su - ubuntu -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
su - ubuntu -c 'source $HOME/.cargo/env && rustc --version'

# Verify Rust version
RUST_VERSION=$(su - ubuntu -c 'source $HOME/.cargo/env && rustc --version' | grep -oP '\d+\.\d+' | head -1)
echo "Installed Rust version: $RUST_VERSION"

# Clone repository
echo "=== Cloning deepseek-ocr.rs repository ==="
if [ -d /home/ubuntu/deepseek-ocr.rs ]; then
    echo "Repository already exists, pulling latest changes"
    su - ubuntu -c 'cd /home/ubuntu/deepseek-ocr.rs && git pull'
else
    su - ubuntu -c 'git clone https://github.com/TimmyOVO/deepseek-ocr.rs.git /home/ubuntu/deepseek-ocr.rs'
fi

# Ensure correct ownership
chown -R ubuntu:ubuntu /home/ubuntu/deepseek-ocr.rs

# Build server with CUDA features
echo "=== Building deepseek-ocr-server ==="
su - ubuntu -c 'cd /home/ubuntu/deepseek-ocr.rs && source $HOME/.cargo/env && cargo build --release -p deepseek-ocr-server --features cuda'

# Verify binary exists
if [ -f /home/ubuntu/deepseek-ocr.rs/target/release/deepseek-ocr-server ]; then
    echo "Binary built successfully at /home/ubuntu/deepseek-ocr.rs/target/release/deepseek-ocr-server"
else
    echo "ERROR: Binary not found at expected path"
    exit 1
fi

# Create systemd service file
echo "=== Creating systemd service ==="
cat > /etc/systemd/system/deepseek-ocr-server.service << 'EOF'
[Unit]
Description=DeepSeek OCR Server
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/deepseek-ocr.rs
Environment="HF_HOME=/home/ubuntu/.cache/huggingface"
ExecStart=/home/ubuntu/deepseek-ocr.rs/target/release/deepseek-ocr-server --host 0.0.0.0 --port 8000 --device cuda --dtype f16 --max-new-tokens 512
Restart=always
RestartSec=10
StandardOutput=append:/var/log/deepseek-ocr-server.log
StandardError=append:/var/log/deepseek-ocr-server.log

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd daemon
echo "=== Reloading systemd daemon ==="
systemctl daemon-reload

# Enable service to start on boot
echo "=== Enabling service ==="
systemctl enable deepseek-ocr-server.service

# Start service
echo "=== Starting service ==="
systemctl start deepseek-ocr-server.service

# Wait for service to be ready
echo "=== Waiting for service to be ready ==="
MAX_WAIT=600  # 10 minutes
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    if curl -s http://localhost:8000/v1/health > /dev/null 2>&1; then
        echo "✓ Service is ready and responding!"
        break
    fi
    echo "Waiting for service... ($ELAPSED seconds elapsed)"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "WARNING: Service did not become ready within $MAX_WAIT seconds"
    echo "Checking service status and logs..."
    systemctl status deepseek-ocr-server.service --no-pager
    echo "Last 50 lines of service log:"
    tail -50 /var/log/deepseek-ocr-server.log
else
    echo "Service started successfully in $ELAPSED seconds"
fi

# Check service status
echo "=== Final service status ==="
systemctl status deepseek-ocr-server.service --no-pager

echo "=== User data script completed at $(date) ==="
