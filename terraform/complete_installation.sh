#!/bin/bash
# Script to complete the DeepSeek OCR installation via SSM

set -e

INSTANCE_ID="i-0c62beba89ff9c9c4"
REGION="us-west-2"

echo "=== Completing DeepSeek OCR Installation ==="
echo "Instance ID: $INSTANCE_ID"
echo ""

# Function to run SSM command and wait for completion
run_ssm_command() {
    local description=$1
    local command=$2
    local timeout=${3:-300}  # Default 5 minutes
    
    echo "[$description]"
    
    local cmd_id=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name 'AWS-RunShellScript' \
        --parameters "commands=[\"$command\"]" \
        --timeout-seconds "$timeout" \
        --region "$REGION" \
        --output json | jq -r '.Command.CommandId')
    
    echo "Command ID: $cmd_id"
    echo "Waiting for completion..."
    
    # Wait for command to complete
    sleep 5
    
    local status="InProgress"
    local count=0
    while [ "$status" = "InProgress" ] && [ $count -lt 60 ]; do
        status=$(aws ssm get-command-invocation \
            --command-id "$cmd_id" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --output json 2>/dev/null | jq -r '.Status' || echo "InProgress")
        
        if [ "$status" = "InProgress" ]; then
            sleep 5
            count=$((count + 1))
            echo -n "."
        fi
    done
    echo ""
    
    # Get output
    local output=$(aws ssm get-command-invocation \
        --command-id "$cmd_id" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" \
        --output json | jq -r '.StandardOutputContent')
    
    echo "$output"
    echo "---"
    echo ""
}

# Step 1: Check CUDA installation
run_ssm_command "Checking CUDA installation" \
    "if command -v nvidia-smi &> /dev/null; then nvidia-smi; else echo CUDA not installed; fi"

# Step 2: Complete CUDA installation if needed
run_ssm_command "Completing CUDA installation" \
    "if ! command -v nvidia-smi &> /dev/null; then \
        export DEBIAN_FRONTEND=noninteractive; \
        apt-get install -y cuda-toolkit-12-2 cuda-drivers 2>&1 | tail -20; \
        echo CUDA installation completed; \
    else \
        echo CUDA already installed; \
    fi" 600

# Step 3: Install Rust
run_ssm_command "Installing Rust" \
    "if ! su - ubuntu -c 'command -v rustc' &> /dev/null; then \
        su - ubuntu -c 'curl --proto \"=https\" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'; \
        echo Rust installed; \
    else \
        echo Rust already installed; \
        su - ubuntu -c 'source \$HOME/.cargo/env && rustc --version'; \
    fi" 300

# Step 4: Clone repository
run_ssm_command "Cloning repository" \
    "if [ ! -d /home/ubuntu/deepseek-ocr.rs ]; then \
        su - ubuntu -c 'git clone https://github.com/TimmyOVO/deepseek-ocr.rs.git /home/ubuntu/deepseek-ocr.rs'; \
        chown -R ubuntu:ubuntu /home/ubuntu/deepseek-ocr.rs; \
        echo Repository cloned; \
    else \
        echo Repository already exists; \
    fi" 180

# Step 5: Build server
run_ssm_command "Building server (this will take 10-15 minutes)" \
    "su - ubuntu -c 'cd /home/ubuntu/deepseek-ocr.rs && source \$HOME/.cargo/env && cargo build --release -p deepseek-ocr-server --features cuda 2>&1 | tail -50'" 1800

# Step 6: Create systemd service
run_ssm_command "Creating systemd service" \
    "cat > /etc/systemd/system/deepseek-ocr-server.service << 'EOF'
[Unit]
Description=DeepSeek OCR Server
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/deepseek-ocr.rs
Environment=\"HF_HOME=/home/ubuntu/.cache/huggingface\"
Environment=\"PATH=/usr/local/cuda-12.2/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"
Environment=\"LD_LIBRARY_PATH=/usr/local/cuda-12.2/lib64\"
ExecStart=/home/ubuntu/deepseek-ocr.rs/target/release/deepseek-ocr-server --host 0.0.0.0 --port 8000 --device cuda --dtype f16 --max-new-tokens 512
Restart=always
RestartSec=10
StandardOutput=append:/var/log/deepseek-ocr-server.log
StandardError=append:/var/log/deepseek-ocr-server.log

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable deepseek-ocr-server.service
echo Service created"

# Step 7: Start service
run_ssm_command "Starting service" \
    "systemctl start deepseek-ocr-server.service && sleep 5 && systemctl status deepseek-ocr-server.service --no-pager"

echo "=== Installation Complete ==="
echo "Check service logs with:"
echo "aws ssm send-command --instance-ids $INSTANCE_ID --document-name 'AWS-RunShellScript' --parameters 'commands=[\"tail -n 50 /var/log/deepseek-ocr-server.log\"]' --region $REGION"
