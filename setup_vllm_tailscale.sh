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

# System update
print_status "Updating system packages..."
apt-get update && apt-get upgrade -y

# Install Python and dependencies
print_status "Installing Python and essential packages..."
apt-get install -y python3 python3-pip python3-venv git curl wget

# Create virtual environment for VLLM
print_status "Creating Python virtual environment..."
python3 -m venv /opt/vllm-env
source /opt/vllm-env/bin/activate

# Install VLLM
print_status "Installing VLLM..."
pip install --upgrade pip
pip install vllm

# Download Gamma3n model
print_status "Downloading Gamma3n model..."
# Note: Replace this with the actual model path/name
# This is a placeholder as the exact model name might vary
MODEL_PATH="/opt/models/gamma3n"
mkdir -p /opt/models

# You'll need to replace this with the actual download command for Gamma3n
# For example, if it's a Hugging Face model:
# git clone https://huggingface.co/path/to/gamma3n $MODEL_PATH
print_warning "Please update the model download command with the actual Gamma3n model path"

# Install Tailscale
print_status "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh

# Start Tailscale
print_status "Starting Tailscale..."
systemctl enable tailscaled
systemctl start tailscaled

# Authenticate Tailscale (interactive)
print_status "Authenticating Tailscale..."
print_warning "Please follow the authentication URL that will be displayed"
tailscale up

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
Environment="PATH=/opt/vllm-env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/opt/vllm-env/bin/python -m vllm.entrypoints.openai.api_server \\
    --model ${MODEL_PATH} \\
    --host 0.0.0.0 \\
    --port 8000 \\
    --max-model-len 4096
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and start VLLM
print_status "Starting VLLM service..."
systemctl daemon-reload
systemctl enable vllm
systemctl start vllm

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

# Create a simple test script
cat > /opt/test_vllm.py << 'EOF'
#!/usr/bin/env python3
import requests
import json

# Test the local endpoint
try:
    response = requests.get("http://localhost:8000/v1/models")
    if response.status_code == 200:
        print("✓ VLLM is responding correctly")
        print("Available models:", json.dumps(response.json(), indent=2))
    else:
        print("✗ VLLM returned status code:", response.status_code)
except Exception as e:
    print("✗ Failed to connect to VLLM:", str(e))
EOF

chmod +x /opt/test_vllm.py

print_status "You can test VLLM locally with: /opt/test_vllm.py"