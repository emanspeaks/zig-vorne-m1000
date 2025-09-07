#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <signal.h>
#include <errno.h>
#include <time.h>

#ifdef _WIN32
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #include <windows.h>
    #pragma comment(lib, "ws2_32.lib")
    #define PIPE_NAME "\\\\.\\pipe\\vlc_status"
    #define sleep(x) Sleep((x) * 1000)
#else
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <unistd.h>
    #include <sys/stat.h>
    #include <fcntl.h>
    #define PIPE_NAME "/tmp/vlc_status_pipe"
    #define SOCKET int
    #define INVALID_SOCKET -1
    #define SOCKET_ERROR -1
    #define closesocket close
#endif

#define MULTICAST_GROUP "239.255.0.100"
#define MULTICAST_PORT 8888
#define BUFFER_SIZE 4096
#define MAX_MESSAGE_SIZE 2048

typedef struct {
    SOCKET multicast_socket;
    struct sockaddr_in multicast_addr;
    bool running;
    char message_buffer[MAX_MESSAGE_SIZE];
} server_context_t;

static server_context_t g_server = {0};

// Signal handler for graceful shutdown
void signal_handler(int sig) {
    printf("\nReceived signal %d, shutting down gracefully...\n", sig);
    g_server.running = false;
}

// Initialize networking (Windows specific)
bool init_networking() {
#ifdef _WIN32
    WSADATA wsaData;
    int result = WSAStartup(MAKEWORD(2, 2), &wsaData);
    if (result != 0) {
        fprintf(stderr, "WSAStartup failed: %d\n", result);
        return false;
    }
#endif
    return true;
}

// Cleanup networking (Windows specific)
void cleanup_networking() {
#ifdef _WIN32
    WSACleanup();
#endif
}

// Create and configure multicast socket
bool setup_multicast_socket(server_context_t* ctx) {
    // Create UDP socket
    ctx->multicast_socket = socket(AF_INET, SOCK_DGRAM, 0);
    if (ctx->multicast_socket == INVALID_SOCKET) {
        fprintf(stderr, "Failed to create socket: %s\n", strerror(errno));
        return false;
    }

    // Enable SO_REUSEADDR
    int reuse = 1;
    if (setsockopt(ctx->multicast_socket, SOL_SOCKET, SO_REUSEADDR, 
                   (const char*)&reuse, sizeof(reuse)) == SOCKET_ERROR) {
        fprintf(stderr, "Failed to set SO_REUSEADDR: %s\n", strerror(errno));
        closesocket(ctx->multicast_socket);
        return false;
    }

    // Set TTL for multicast
    int ttl = 1;  // Local network only
    if (setsockopt(ctx->multicast_socket, IPPROTO_IP, IP_MULTICAST_TTL,
                   (const char*)&ttl, sizeof(ttl)) == SOCKET_ERROR) {
        fprintf(stderr, "Failed to set TTL: %s\n", strerror(errno));
        closesocket(ctx->multicast_socket);
        return false;
    }

    // Setup multicast address
    memset(&ctx->multicast_addr, 0, sizeof(ctx->multicast_addr));
    ctx->multicast_addr.sin_family = AF_INET;
    ctx->multicast_addr.sin_port = htons(MULTICAST_PORT);
    if (inet_pton(AF_INET, MULTICAST_GROUP, &ctx->multicast_addr.sin_addr) <= 0) {
        fprintf(stderr, "Invalid multicast address: %s\n", MULTICAST_GROUP);
        closesocket(ctx->multicast_socket);
        return false;
    }

    printf("Multicast socket configured for %s:%d\n", MULTICAST_GROUP, MULTICAST_PORT);
    return true;
}

// Send data via multicast
bool send_multicast_data(server_context_t* ctx, const char* data, size_t len) {
    if (!data || len == 0) {
        return false;
    }

    ssize_t sent = sendto(ctx->multicast_socket, data, (int)len, 0,
                         (struct sockaddr*)&ctx->multicast_addr,
                         sizeof(ctx->multicast_addr));
    
    if (sent == SOCKET_ERROR) {
        fprintf(stderr, "Failed to send multicast data: %s\n", strerror(errno));
        return false;
    }

    if ((size_t)sent != len) {
        fprintf(stderr, "Warning: Only sent %zd of %zu bytes\n", sent, len);
        return false;
    }

    printf("Sent %zu bytes via multicast\n", len);
    return true;
}

// Process received VLC status message
void process_vlc_status(server_context_t* ctx, const char* message) {
    if (!message || strlen(message) == 0) {
        return;
    }

    // Add timestamp and server info to the message
    time_t now = time(NULL);
    struct tm* tm_info = localtime(&now);
    char timestamp[32];
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", tm_info);

    // Create enhanced message with server metadata
    int written = snprintf(ctx->message_buffer, sizeof(ctx->message_buffer),
                          "{\"server_timestamp\": \"%s\", \"server_id\": \"vlc-status-server\", \"vlc_data\": %s}",
                          timestamp, message);

    if (written < 0 || written >= (int)sizeof(ctx->message_buffer)) {
        fprintf(stderr, "Error formatting message or message too large\n");
        return;
    }

    // Send via multicast
    if (send_multicast_data(ctx, ctx->message_buffer, strlen(ctx->message_buffer))) {
        printf("Processed VLC status: %s\n", message);
    }
}

#ifdef _WIN32
// Windows named pipe handling
bool read_from_pipe_windows(server_context_t* ctx) {
    HANDLE pipe_handle = INVALID_HANDLE_VALUE;
    char buffer[BUFFER_SIZE];
    DWORD bytes_read;
    char line_buffer[MAX_MESSAGE_SIZE];
    size_t line_pos = 0;
    
    printf("Waiting for VLC extension to connect to pipe...\n");
    
    while (ctx->running) {
        // Create named pipe
        pipe_handle = CreateNamedPipeA(
            PIPE_NAME,
            PIPE_ACCESS_INBOUND,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            1,  // max instances
            BUFFER_SIZE,  // out buffer size
            BUFFER_SIZE,  // in buffer size
            0,  // timeout
            NULL  // security attributes
        );
        
        if (pipe_handle == INVALID_HANDLE_VALUE) {
            fprintf(stderr, "Failed to create named pipe: %lu\n", GetLastError());
            sleep(5);
            continue;
        }
        
        printf("Named pipe created, waiting for connection...\n");
        
        // Wait for client connection
        BOOL connected = ConnectNamedPipe(pipe_handle, NULL);
        if (!connected && GetLastError() != ERROR_PIPE_CONNECTED) {
            fprintf(stderr, "Failed to connect to pipe: %lu\n", GetLastError());
            CloseHandle(pipe_handle);
            sleep(1);
            continue;
        }
        
        printf("VLC extension connected to pipe\n");
        line_pos = 0;
        
        // Read data from pipe
        while (ctx->running) {
            if (!ReadFile(pipe_handle, buffer, sizeof(buffer) - 1, &bytes_read, NULL)) {
                DWORD error = GetLastError();
                if (error == ERROR_BROKEN_PIPE) {
                    printf("VLC extension disconnected\n");
                } else {
                    fprintf(stderr, "Failed to read from pipe: %lu\n", error);
                }
                break;
            }
            
            if (bytes_read == 0) {
                continue;
            }
            
            buffer[bytes_read] = '\0';
            
            // Process buffer character by character to handle line breaks
            for (DWORD i = 0; i < bytes_read; i++) {
                if (buffer[i] == '\n' || buffer[i] == '\r') {
                    if (line_pos > 0) {
                        line_buffer[line_pos] = '\0';
                        process_vlc_status(ctx, line_buffer);
                        line_pos = 0;
                    }
                } else if (line_pos < sizeof(line_buffer) - 1) {
                    line_buffer[line_pos++] = buffer[i];
                }
            }
        }
        
        CloseHandle(pipe_handle);
        pipe_handle = INVALID_HANDLE_VALUE;
        
        if (ctx->running) {
            printf("Connection lost, attempting to reconnect...\n");
            sleep(2);
        }
    }
    
    if (pipe_handle != INVALID_HANDLE_VALUE) {
        CloseHandle(pipe_handle);
    }
    
    return true;
}
#else
// Unix named pipe (FIFO) handling
bool read_from_pipe_unix(server_context_t* ctx) {
    int pipe_fd = -1;
    char buffer[BUFFER_SIZE];
    char line_buffer[MAX_MESSAGE_SIZE];
    size_t line_pos = 0;
    
    // Create FIFO if it doesn't exist
    if (mkfifo(PIPE_NAME, 0666) == -1 && errno != EEXIST) {
        fprintf(stderr, "Failed to create FIFO: %s\n", strerror(errno));
        return false;
    }
    
    printf("FIFO created at %s\n", PIPE_NAME);
    printf("Waiting for VLC extension to connect...\n");
    
    while (ctx->running) {
        // Open FIFO for reading
        pipe_fd = open(PIPE_NAME, O_RDONLY);
        if (pipe_fd == -1) {
            fprintf(stderr, "Failed to open FIFO: %s\n", strerror(errno));
            sleep(1);
            continue;
        }
        
        printf("VLC extension connected to FIFO\n");
        line_pos = 0;
        
        // Read data from FIFO
        while (ctx->running) {
            ssize_t bytes_read = read(pipe_fd, buffer, sizeof(buffer) - 1);
            if (bytes_read <= 0) {
                if (bytes_read == 0) {
                    printf("VLC extension disconnected\n");
                } else {
                    fprintf(stderr, "Failed to read from FIFO: %s\n", strerror(errno));
                }
                break;
            }
            
            buffer[bytes_read] = '\0';
            
            // Process buffer character by character to handle line breaks
            for (ssize_t i = 0; i < bytes_read; i++) {
                if (buffer[i] == '\n' || buffer[i] == '\r') {
                    if (line_pos > 0) {
                        line_buffer[line_pos] = '\0';
                        process_vlc_status(ctx, line_buffer);
                        line_pos = 0;
                    }
                } else if (line_pos < sizeof(line_buffer) - 1) {
                    line_buffer[line_pos++] = buffer[i];
                }
            }
        }
        
        close(pipe_fd);
        pipe_fd = -1;
        
        if (ctx->running) {
            printf("Connection lost, attempting to reconnect...\n");
            sleep(2);
        }
    }
    
    if (pipe_fd != -1) {
        close(pipe_fd);
    }
    
    // Cleanup FIFO
    unlink(PIPE_NAME);
    
    return true;
}
#endif

int main(int argc, char* argv[]) {
    (void)argc;  // Suppress unused parameter warning
    (void)argv;  // Suppress unused parameter warning
    
    printf("VLC Status Multicast Server v1.0\n");
    printf("Broadcasting to %s:%d\n\n", MULTICAST_GROUP, MULTICAST_PORT);
    
    // Initialize server context
    g_server.running = true;
    
    // Setup signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Initialize networking
    if (!init_networking()) {
        fprintf(stderr, "Failed to initialize networking\n");
        return EXIT_FAILURE;
    }
    
    // Setup multicast socket
    if (!setup_multicast_socket(&g_server)) {
        fprintf(stderr, "Failed to setup multicast socket\n");
        cleanup_networking();
        return EXIT_FAILURE;
    }
    
    printf("Server initialized successfully\n");
    printf("Install the VLC extension and activate it to start broadcasting\n");
    printf("Press Ctrl+C to stop the server\n\n");
    
    // Main loop - read from pipe and broadcast
    bool success;
#ifdef _WIN32
    success = read_from_pipe_windows(&g_server);
#else
    success = read_from_pipe_unix(&g_server);
#endif
    
    // Cleanup
    printf("\nShutting down server...\n");
    
    if (g_server.multicast_socket != INVALID_SOCKET) {
        closesocket(g_server.multicast_socket);
    }
    
    cleanup_networking();
    
    printf("Server shutdown complete\n");
    return success ? EXIT_SUCCESS : EXIT_FAILURE;
}
