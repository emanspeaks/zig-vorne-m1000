# VLC Status Broadcaster

A system that broadcasts VLC Media Player playback status over multicast UDP using a VLC Lua extension and a C17 server communicating via named pipes.

## Architecture

- **VLC Lua Extension** (`status_broadcaster.lua`): Monitors VLC playback status and sends data via named pipe
- **C17 Multicast Server** (`vlc_status_server`): Reads from named pipe and broadcasts status via UDP multicast

## Features

- Real-time VLC playback status monitoring
- JSON-formatted status messages
- Cross-platform support (Windows/Linux)
- Named pipe communication (no temp files)
- UDP multicast broadcasting
- Automatic reconnection handling
- Graceful shutdown support

## Status Data Format

The broadcaster sends JSON data containing:

```json
{
  "server_timestamp": "2025-09-06 14:30:25",
  "server_id": "vlc-status-server",
  "vlc_data": {
    "timestamp": 1725627025,
    "is_playing": true,
    "position": 0.425,
    "time": 125000000,
    "duration": 294000000,
    "rate": 1.0,
    "title": "Song Title",
    "artist": "Artist Name",
    "album": "Album Name",
    "filename": "song.mp3",
    "uri": "file:///path/to/song.mp3"
  }
}
```

## Building the Server

### Prerequisites

- CMake 3.10 or later
- C17-compatible compiler:
  - GCC 7+ (Linux/Windows with MinGW)
  - Clang 6+ (Linux/macOS)
  - Visual Studio 2017+ (Windows)

### Build Instructions

```bash
# Navigate to server directory
cd server

# Create build directory
mkdir build && cd build

# Configure the project
cmake ..

# Build (use appropriate command for your generator)
cmake --build .

# Or use generator-specific commands:
# make          # Unix Makefiles
# ninja         # Ninja
# msbuild       # Visual Studio (Windows)
```

### Build Configuration Options

```bash
# Debug build
cmake -DCMAKE_BUILD_TYPE=Debug ..

# Release build (default)
cmake -DCMAKE_BUILD_TYPE=Release ..

# Specify generator (optional)
cmake -G "Unix Makefiles" ..           # Linux/macOS
cmake -G "Visual Studio 16 2019" ..    # Windows (VS 2019)
cmake -G "MinGW Makefiles" ..          # Windows (MinGW)
cmake -G "Ninja" ..                     # Any platform with Ninja
```

### Using CMake Presets (CMake 3.19+)

```bash
# List available presets
cmake --list-presets

# Configure using preset
cmake --preset default    # Release build
cmake --preset debug      # Debug build
cmake --preset windows-mingw  # Windows MinGW

# Build using preset
cmake --build --preset default
```

### Cross-compilation Example

```bash
# Windows from Linux (using MinGW)
cmake -DCMAKE_TOOLCHAIN_FILE=/path/to/mingw-toolchain.cmake ..
```

## Installation

### VLC Extension Installation

#### Windows

Copy `vlc-extension/status_broadcaster.lua` to one of these directories:

- All users: `%ProgramFiles%\VideoLAN\VLC\lua\extensions\`
- Current user: `%APPDATA%\VLC\lua\extensions\`

#### Linux

Copy `vlc-extension/status_broadcaster.lua` to one of these directories:

- All users: `/usr/lib/vlc/lua/extensions/`
- Current user: `~/.local/share/vlc/lua/extensions/`

#### macOS

Copy `vlc-extension/status_broadcaster.lua` to one of these directories:

- All users: `/Applications/VLC.app/Contents/MacOS/share/lua/extensions/`
- Current user: `~/Library/Application Support/org.videolan.vlc/lua/extensions/`

### Server Installation

1. Build the server:

   ```bash
   cd server
   mkdir build && cd build
   cmake ..
   cmake --build .
   ```

2. The executable will be in `build/bin/vlc_status_server` (or `.exe` on Windows)
3. Optionally install system-wide:

   ```bash
   sudo cmake --install .  # Linux/macOS
   cmake --install . --config Release  # Windows
   ```

## Usage

### 1. Start the Multicast Server

```bash
# Linux/macOS
./vlc_status_server

# Windows
vlc_status_server.exe
```

The server will:

- Create a named pipe (`\\.\pipe\vlc_status` on Windows, `/tmp/vlc_status_pipe` on Linux)
- Set up UDP multicast on `239.255.0.100:8888`
- Wait for VLC extension to connect

### 2. Activate VLC Extension

1. Open VLC Media Player
2. Go to **View** → **VLC Status Broadcaster**
3. The extension will automatically start broadcasting status

### 3. Receive Multicast Data

To receive the broadcast data, listen for UDP multicast on `239.255.0.100:8888`.

Example Python receiver:

```python
import socket
import json

# Create UDP socket
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

# Bind to multicast group
sock.bind(('', 8888))

# Join multicast group
mreq = socket.inet_aton('239.255.0.100') + socket.inet_aton('0.0.0.0')
sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)

print("Listening for VLC status broadcasts...")

while True:
    data, addr = sock.recvfrom(4096)
    try:
        status = json.loads(data.decode())
        vlc_data = status['vlc_data']
        print(f"VLC Status: {vlc_data['is_playing']} - {vlc_data['title']}")
    except Exception as e:
        print(f"Error parsing data: {e}")
```

## Configuration

### Multicast Settings

To change the multicast group or port, edit these constants in `vlc_status_server.c`:

```c
#define MULTICAST_GROUP "239.255.0.100"
#define MULTICAST_PORT 8888
```

### Named Pipe Settings

To change the pipe name, edit these constants:

```c
// Windows
#define PIPE_NAME "\\\\.\\pipe\\vlc_status"

// Linux
#define PIPE_NAME "/tmp/vlc_status_pipe"
```

And update the corresponding variable in `status_broadcaster.lua`:

```lua
local pipe_name = "\\\\.\\pipe\\vlc_status"  -- Windows
-- local pipe_name = "/tmp/vlc_status_pipe"     -- Linux
```

### Update Frequency

The extension sends updates every second and immediately when status changes. To modify the update interval, change this line in `status_broadcaster.lua`:

```lua
update_timer = vlc.misc.timer(1000000, update_status)  -- 1 second in microseconds
```

## Troubleshooting

### Extension Not Visible in VLC Menu

1. Verify the extension file is in the correct VLC lua/extensions directory
2. Restart VLC Media Player
3. Check VLC logs (Tools → Messages) for extension loading errors

### Server Cannot Create Named Pipe

**Windows:**

- Ensure the server has sufficient privileges
- Check if another instance is already running
- Verify Windows named pipe support

**Linux:**

- Ensure `/tmp` directory is writable
- Check if FIFO already exists: `ls -la /tmp/vlc_status_pipe`
- Remove existing FIFO if needed: `rm /tmp/vlc_status_pipe`

### No Multicast Data Received

1. Verify the server is running and shows "VLC extension connected"
2. Check firewall settings allow UDP traffic on port 8888
3. Ensure multicast routing is enabled on your network
4. Test with the Python receiver example above

### Extension Connection Issues

1. Check VLC Messages (Tools → Messages) for error messages
2. Verify the pipe name matches between extension and server
3. Restart both VLC and the server
4. On Linux, check file permissions for the FIFO

## Technical Details

### Named Pipe Communication

- **Windows**: Uses Windows Named Pipes API (`CreateNamedPipe`, `ConnectNamedPipe`)
- **Linux**: Uses POSIX FIFOs (`mkfifo`, `open`, `read`)
- Data format: JSON strings separated by newlines
- Automatic reconnection on disconnect

### Multicast Protocol

- **Group**: 239.255.0.100 (site-local multicast)
- **Port**: 8888/UDP
- **TTL**: 1 (local network only)
- **Format**: JSON messages with server metadata and VLC data

### VLC Extension Events

The extension responds to these VLC events:

- `input_changed()`: When media changes
- `meta_changed()`: When metadata updates
- `status_changed()`: When playback state changes
- Timer-based updates every second during playback
