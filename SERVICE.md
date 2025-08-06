# Zig Vorne M1000 Service Management

This directory contains scripts and configuration to run the Zig Vorne M1000 display program automatically on boot.

## Installation

1. **Install the service:**

   ```bash
   ./install-service.sh
   ```

2. **Log out and log back in** (or reboot) for group permissions to take effect.

3. **Start the service:**

   ```bash
   sudo systemctl start zig-vorne-m1000
   ```

## Service Management Commands

- **Check service status:**

  ```bash
  sudo systemctl status zig-vorne-m1000
  ```

- **View live logs:**

  ```bash
  sudo journalctl -u zig-vorne-m1000 -f
  ```

- **View recent logs:**

  ```bash
  sudo journalctl -u zig-vorne-m1000 -n 50
  ```

- **Restart the service:**

  ```bash
  sudo systemctl restart zig-vorne-m1000
  ```

- **Stop the service:**

  ```bash
  sudo systemctl stop zig-vorne-m1000
  ```

- **Disable auto-start (but keep installed):**

  ```bash
  sudo systemctl disable zig-vorne-m1000
  ```

- **Re-enable auto-start:**

  ```bash
  sudo systemctl enable zig-vorne-m1000
  ```

## Updating the Program

1. **Stop the service:**

   ```bash
   sudo systemctl stop zig-vorne-m1000
   ```

2. **Build the updated program:**

   ```bash
   zig build
   ```

3. **Start the service:**

   ```bash
   sudo systemctl start zig-vorne-m1000
   ```

## Uninstallation

To completely remove the service:

```bash
./uninstall-service.sh
```

## Troubleshooting

### Serial Port Permission Issues

If you get permission denied errors for `/dev/ttyUSB0`:

```bash
# sudo usermod -a -G dialout $USER
sudo usermod -a -G plugdev $USER
# Then log out and back in
```

### Check if USB device is detected

```bash
ls -la /dev/ttyUSB*
dmesg | grep tty
```

### Service won't start

```bash
# Check service status for error details
sudo systemctl status zig-vorne-m1000

# Check logs for specific errors
sudo journalctl -u zig-vorne-m1000 -n 50
```

### Manual testing

Run the program manually to test:

```bash
./zig-out/bin/zig_vorne_m1000
```

## Service Configuration

The service configuration is in `zig-vorne-m1000.service` and includes:

- Automatic restart on failure
- Proper user permissions for serial port access
- Logging to systemd journal
- Dependency on network being available

## Files

- `zig-vorne-m1000.service` - Systemd service configuration
- `install-service.sh` - Installation script
- `uninstall-service.sh` - Uninstallation script
- `SERVICE.md` - This documentation file
