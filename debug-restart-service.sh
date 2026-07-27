#!/bin/bash

# Zig Vorne M1000 Service Restart Script
# This script rebuilds the zig-vorne-m1000 program and restarts the systemd service

set -e

# Build the project first
echo "Building the project..."
zig build

# Check if the binary exists
if [ ! -f "./zig-out/bin/zig_vorne_m1000" ]; then
    echo "Error: Binary not found at ./zig-out/bin/zig_vorne_m1000"
    echo "Make sure the build completed successfully."
    exit 1
fi

echo "Restarting Zig Vorne M1000 service..."
sudo systemctl restart zig-vorne-m1000
echo "Zig Vorne M1000 service restarted successfully."
