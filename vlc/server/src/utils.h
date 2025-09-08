#ifndef UTILS_H
#define UTILS_H

#include <stddef.h>

// Function declarations
void format_time_with_ms(long long time_ms, char *buffer, size_t buffer_size);
void print_usage(const char *program_name);

#endif // UTILS_H