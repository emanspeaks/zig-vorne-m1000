#!/bin/bash

# Zig Vorne M1000 Service Uninstallation Script

set -e

echo "Uninstalling Zig Vorne M1000 service..."

# Stop the service if it's running
echo "Stopping service..."
sudo systemctl stop zig-vorne-m1000 || true

# Disable the service
echo "Disabling service..."
sudo systemctl disable zig-vorne-m1000 || true

# Remove the service file
echo "Removing service file..."
sudo rm -f /etc/systemd/system/zig-vorne-m1000.service

# Reload systemd daemon
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo ""
echo "Service uninstalled successfully!"
echo ""
echo "Note: User group memberships (dialout or plugdev) were not changed."
echo "The project files remain unchanged."
