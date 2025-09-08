#include <stdio.h>
#include <windows.h>

int main() {
    // Print PATH
    char *path = getenv("PATH");
    printf("PATH: %s\n", path ? path : "(not set)");

    // Try to load libvlc.dll
    HMODULE hLib = LoadLibraryA("libvlc.dll");
    if (hLib) {
        printf("libvlc.dll loaded successfully!\n");
        FreeLibrary(hLib);
    } else {
        printf("Failed to load libvlc.dll. Error code: %lu\n", GetLastError());
    }

    // getchar(); // Pause for console
    return 0;
}
