#!/bin/bash

# Zig Vorne M1000 Service Installation Script
# This script installs the zig-vorne-m1000 program as a systemd service

set -e

echo "Installing Zig Vorne M1000 as a system service..."

# Build the project first
echo "Building the project..."
zig build

# Check if the binary exists
if [ ! -f "./zig-out/bin/zig_vorne_m1000" ]; then
    echo "Error: Binary not found at ./zig-out/bin/zig_vorne_m1000"
    echo "Make sure the build completed successfully."
    exit 1
fi

# Copy the service file to systemd directory
echo "Installing service file..."
sudo cp zig-vorne-m1000.service /etc/systemd/system/

# Reload systemd daemon
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

# Enable the service (start on boot)
echo "Enabling service..."
sudo systemctl enable zig-vorne-m1000.service

# # Add user to dialout group for serial port access
# echo "Adding user to dialout group..."
# sudo usermod -a -G dialout $USER

# Add user to plugdev group for serial port access
echo "Adding user to plugdev group..."
sudo usermod -a -G plugdev $USER

echo ""
echo "Installation complete!"
echo ""
echo "To start the service now:"
echo "  sudo systemctl start zig-vorne-m1000"
echo ""
echo "To check service status:"
echo "  sudo systemctl status zig-vorne-m1000"
echo ""
echo "To view logs:"
echo "  sudo journalctl -u zig-vorne-m1000 -f"
echo ""
echo "To stop the service:"
echo "  sudo systemctl stop zig-vorne-m1000"
echo ""
echo "To disable auto-start on boot:"
echo "  sudo systemctl disable zig-vorne-m1000"
echo ""
echo "Note: You may need to log out and back in for group changes to take effect."
