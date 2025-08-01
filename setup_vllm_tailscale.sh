#!/bin/bash

# VLLM and Tailscale Setup Script
# This script installs VLLM, downloads the Gamma3n model, installs Tailscale,
# and publishes the VLLM endpoint on the intranet

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root (use sudo)"
   exit 1
fi

# System update - only if hasn't been updated in last 24h
if [[ $(find /var/cache/apt/pkgcache.bin -mtime +1) ]]; then
    print_status "Updating system packages..."
    apt-get update && apt-get upgrade -y
else
    print_status "System packages were recently updated, skipping..."
fi

# Check Python installation
if ! command -v python3 &> /dev/null; then
    print_status "Installing Python and essential packages..."
    apt-get install -y python3 python3-pip python3-venv git curl wget
else
    print_status "Python already installed, skipping..."
fi

# Install NVIDIA stack
print_status "Installing NVIDIA stack..."
# Add NVIDIA repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update

# Install drivers and toolkit
apt-get install -y nvidia-driver-535 nvidia-dkms-535
apt-get install -y nvidia-container-toolkit nvidia-cuda-toolkit build-essential

# Verify NVIDIA installation and exit if not working
if ! nvidia-smi &> /dev/null; then
    print_error "NVIDIA drivers not loaded. You need to reboot first!"
    print_warning "Please run: sudo reboot"
    print_warning "Then run this script again after reboot"
    exit 1
fi

# Create virtual environment for VLLM
print_status "Creating Python virtual environment..."
python3 -m venv /opt/vllm-env
source /opt/vllm-env/bin/activate

# Install VLLM with specific CUDA version
print_status "Installing VLLM..."
pip install --upgrade pip
pip install torch --index-url https://download.pytorch.org/whl/cu118
pip install "vllm[all]"

# Download Gamma3n model
print_status "Downloading Gamma3n model..."
# Note: Replace this with the actual model path/name
# This is a placeholder as the exact model name might vary
MODEL_PATH="google/gemma-3n-E4B"
mkdir -p /opt/models

# Improve Hugging Face authentication
print_status "Setting up Hugging Face authentication..."
pip install --upgrade huggingface_hub

# Create config directory if it doesn't exist
mkdir -p /root/.huggingface

# Store token in proper location
if [ ! -f /root/.huggingface/token ]; then
    print_warning "Please enter your Hugging Face token:"
    read -r HF_TOKEN
    echo "${HF_TOKEN}" > /root/.huggingface/token
    chmod 600 /root/.huggingface/token
else
    HF_TOKEN=$(cat /root/.huggingface/token)
    print_status "Using existing Hugging Face token..."
fi

# Test token
print_status "Testing Hugging Face authentication..."
if ! huggingface-cli whoami; then
    print_error "Hugging Face authentication failed. Please check your token."
    exit 1
fi

# Create VLLM service
print_status "Creating VLLM systemd service..."
cat > /etc/systemd/system/vllm.service << EOF
[Unit]
Description=VLLM API Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt
Environment="PATH=/opt/vllm-env/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64"
Environment="VLLM_LOGGING_LEVEL=DEBUG"
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="NCCL_DEBUG=INFO"
Environment="TORCH_DEVICE=cuda"
Environment="HUGGINGFACE_TOKEN=${HF_TOKEN}"
Environment="TRANSFORMERS_CACHE=/opt/models/cache"
Environment="HF_HOME=/root/.huggingface"
Environment="HF_TOKEN=${HF_TOKEN}"
ExecStartPre=/bin/bash -c 'nvidia-smi || exit 1'
ExecStart=/opt/vllm-env/bin/python -m vllm.entrypoints.openai.api_server \\
    --model ${MODEL_PATH} \\
    --host 0.0.0.0 \\
    --port 8000 \\
    --max-model-len 4096 \\
    --trust-remote-code \\
    --dtype auto \\
    --tensor-parallel-size 1 \\
    --gpu-memory-utilization 0.9 \\
    --swap-space 16
StandardOutput=append:/var/log/vllm.log
StandardError=append:/var/log/vllm.log
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create log file
touch /var/log/vllm.log
chmod 644 /var/log/vllm.log

# Add service check and debug info
print_status "Checking NVIDIA and CUDA..."
nvidia-smi
print_status "CUDA version:"
nvcc --version

print_status "Starting VLLM service..."
systemctl daemon-reload
systemctl restart vllm
sleep 5

# More detailed service check
if ! systemctl is-active --quiet vllm; then
    print_error "VLLM failed to start. Debugging information:"
    systemctl status vllm
    echo "Last 20 lines of logs:"
    tail -n 20 /var/log/vllm.log
    echo "GPU Status:"
    nvidia-smi
    exit 1
fi

# Wait for VLLM to start
print_status "Waiting for VLLM to start..."
sleep 10

# Check VLLM status
if systemctl is-active --quiet vllm; then
    print_status "VLLM is running successfully"
else
    print_error "VLLM failed to start. Check logs with: journalctl -u vllm -f"
    exit 1
fi

# Configure Tailscale to serve VLLM
print_status "Configuring Tailscale to serve VLLM endpoint..."
tailscale serve https:443 / http://localhost:8000

# Get Tailscale status
TAILSCALE_IP=$(tailscale ip -4)
TAILSCALE_HOSTNAME=$(tailscale status --json | python3 -c "import sys, json; data = json.load(sys.stdin); print(data['Self']['DNSName'].rstrip('.'))")

# Display connection information
print_status "Setup complete!"
echo ""
echo "========================================="
echo "VLLM is now accessible via Tailscale at:"
echo "  - https://${TAILSCALE_HOSTNAME}"
echo "  - http://${TAILSCALE_IP}:8000"
echo ""
echo "To test the endpoint:"
echo "  curl https://${TAILSCALE_HOSTNAME}/v1/models"
echo ""
echo "To view VLLM logs:"
echo "  journalctl -u vllm -f"
echo ""
echo "To view Tailscale status:"
echo "  tailscale status"
echo "========================================="

# Update test script with correct model name
cat > /opt/test_vllm.py << 'EOF'
#!/usr/bin/env python3
import requests
import json

def test_model():
    url = "http://localhost:8000/v1/chat/completions"
    headers = {"Content-Type": "application/json"}
    data = {
        "model": "google/gemma-3n-E4B",
        "messages": [
            {
                "role": "user",
                "content": "Say hello!"
            }
        ]
    }
    
    try:
        response = requests.post(url, headers=headers, json=data)
        if response.status_code == 200:
            print("✓ VLLM is responding correctly")
            print("Response:", json.dumps(response.json(), indent=2))
        else:
            print("✗ VLLM returned status code:", response.status_code)
    except Exception as e:
        print("✗ Failed to connect to VLLM:", str(e))

if __name__ == "__main__":
    test_model()
EOF

chmod +x /opt/test_vllm.py

print_status "You can test VLLM locally with: /opt/test_vllm.py"