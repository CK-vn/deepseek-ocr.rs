#!/bin/bash
set -e

# Log all output to a file
exec > >(tee -a /var/log/user-data.log)
exec 2>&1

echo "Starting Open WebUI installation at $(date)"

# Update system packages
apt-get update
apt-get upgrade -y

# Install Docker
echo "Installing Docker..."
apt-get install -y ca-certificates curl gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start and enable Docker
systemctl start docker
systemctl enable docker

# Add ubuntu user to docker group
usermod -aG docker ubuntu

# Pull and run Open WebUI
echo "Starting Open WebUI container..."
docker run -d \
  --name open-webui \
  -p 3000:8080 \
  -v open-webui:/app/backend/data \
  --restart always \
  ghcr.io/open-webui/open-webui:main

# Wait for container to be healthy and responding
echo "Waiting for Open WebUI to start..."
MAX_WAIT=300  # 5 minutes
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    if curl -s http://localhost:3000/ > /dev/null 2>&1; then
        echo "✓ Open WebUI is ready and responding!"
        break
    fi
    echo "Waiting for Open WebUI... ($ELAPSED seconds elapsed)"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "WARNING: Open WebUI did not become ready within $MAX_WAIT seconds"
    echo "Container status:"
    docker ps -a | grep open-webui
    echo "Container logs:"
    docker logs open-webui --tail 50
else
    echo "Open WebUI started successfully in $ELAPSED seconds"
fi

# Check if container is running
if docker ps | grep -q open-webui; then
    echo "Open WebUI is running successfully!"
    echo "Access it at: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):3000"
else
    echo "ERROR: Open WebUI failed to start"
    docker logs open-webui
    exit 1
fi

echo "Installation completed at $(date)"
echo ""
echo "=== SETUP INSTRUCTIONS ==="
echo "1. Access Open WebUI at: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):3000"
echo "2. Create an admin account on first visit"
echo "3. Go to Settings > Connections"
echo "4. Add OpenAI API connection with:"
echo "   - Base URL: ${deepseek_ocr_endpoint}"
echo "   - API Key: (any value, e.g., 'dummy-key')"
echo "5. Start testing DeepSeek OCR!"
