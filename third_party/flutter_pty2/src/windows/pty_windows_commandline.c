#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include "pty_windows_commandline.h"

#include <windows.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static wchar_t *utf8_to_wide(const char *value)
{
    if (value == NULL) return NULL;
    const int length = MultiByteToWideChar(CP_UTF8,
                                           MB_ERR_INVALID_CHARS,
                                           value,
                                           -1,
                                           NULL,
                                           0);
    if (length <= 0) return NULL;
    wchar_t *converted = malloc((size_t)length * sizeof(*converted));
    if (converted == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8,
                            MB_ERR_INVALID_CHARS,
                            value,
                            -1,
                            converted,
                            length) <= 0) {
        free(converted);
        return NULL;
    }
    return converted;
}

static int ascii_lower(int value)
{
    return value >= 'A' && value <= 'Z' ? value - 'A' + 'a' : value;
}

static int ascii_case_equal(const char *left, const char *right)
{
    while (*left != '\0' && *right != '\0') {
        if (ascii_lower((unsigned char)*left) !=
            ascii_lower((unsigned char)*right)) {
            return 0;
        }
        left++;
        right++;
    }
    return *left == '\0' && *right == '\0';
}

static const char *executable_basename(const char *executable)
{
    const char *base = executable;
    for (const char *cursor = executable; *cursor != '\0'; cursor++) {
        if (*cursor == '\\' || *cursor == '/') base = cursor + 1;
    }
    return base;
}

static int is_cmd_executable(const char *executable)
{
    const char *base = executable_basename(executable);
    return ascii_case_equal(base, "cmd") ||
           ascii_case_equal(base, "cmd.exe");
}

static int is_cmd_switch(const char *argument, char letter)
{
    return argument[0] == '/' &&
           (argument[1] == letter ||
            argument[1] == (char)(letter - 'a' + 'A')) &&
           argument[2] == '\0';
}

static size_t append_raw_argument(wchar_t *command,
                                  size_t offset,
                                  const wchar_t *argument)
{
    while (*argument != L'\0') command[offset++] = *argument++;
    return offset;
}

static size_t append_quoted_argument(wchar_t *command,
                                     size_t offset,
                                     const wchar_t *argument)
{
    command[offset++] = L'"';
    size_t backslashes = 0;
    for (size_t index = 0; argument[index] != L'\0'; index++) {
        if (argument[index] == L'\\') {
            backslashes++;
            continue;
        }
        if (argument[index] == L'"') {
            for (size_t count = 0; count < backslashes * 2 + 1; count++) {
                command[offset++] = L'\\';
            }
            command[offset++] = L'"';
            backslashes = 0;
            continue;
        }
        for (size_t count = 0; count < backslashes; count++) {
            command[offset++] = L'\\';
        }
        backslashes = 0;
        command[offset++] = argument[index];
    }
    for (size_t count = 0; count < backslashes * 2; count++) {
        command[offset++] = L'\\';
    }
    command[offset++] = L'"';
    return offset;
}

wchar_t *pty_windows_build_command_line(const char *executable,
                                         const char *const *arguments,
                                         int argument_count)
{
    if (executable == NULL || argument_count < 0 ||
        (argument_count != 0 && arguments == NULL)) {
        return NULL;
    }
    size_t command_capacity = 1;
    const size_t executable_length = strlen(executable);
    if (executable_length > (SIZE_MAX - command_capacity - 3) / 2) {
        return NULL;
    }
    command_capacity += executable_length * 2 + 3;
    for (int index = 0; index < argument_count; index++) {
        if (arguments[index] == NULL) return NULL;
        const size_t length = strlen(arguments[index]);
        if (length > (SIZE_MAX - command_capacity - 4) / 2) {
            return NULL;
        }
        command_capacity += length * 2 + 4;
    }
    wchar_t *command = malloc(command_capacity * sizeof(*command));
    if (command == NULL) return NULL;

    // cmd.exe does not parse its command line like a normal C program. With
    // /S /C it strips one outer pair of quotes and keeps every inner quote
    // as-is, so the command must not be escaped with backslashes. We only
    // take this path for the explicit /S /C form used by the PTY launcher.
    if (is_cmd_executable(executable)) {
        int s_index = -1;
        int command_index = -1;
        for (int index = 0; index < argument_count; index++) {
            if (is_cmd_switch(arguments[index], 's')) s_index = index;
            if (is_cmd_switch(arguments[index], 'c') ||
                is_cmd_switch(arguments[index], 'k')) {
                command_index = index;
            }
        }
        if (s_index >= 0 && command_index > s_index &&
            command_index + 1 < argument_count) {
            size_t raw_offset = 0;
            wchar_t *converted = utf8_to_wide(executable);
            if (converted == NULL) {
                free(command);
                return NULL;
            }
            raw_offset = append_quoted_argument(command,
                                                raw_offset,
                                                converted);
            free(converted);
            for (int index = 0; index <= command_index; index++) {
                converted = utf8_to_wide(arguments[index]);
                if (converted == NULL) {
                    free(command);
                    return NULL;
                }
                command[raw_offset++] = L' ';
                raw_offset = append_raw_argument(command,
                                                 raw_offset,
                                                 converted);
                free(converted);
            }
            command[raw_offset++] = L' ';
            command[raw_offset++] = L'"';
            for (int index = command_index + 1;
                 index < argument_count;
                 index++) {
                if (index > command_index + 1) command[raw_offset++] = L' ';
                converted = utf8_to_wide(arguments[index]);
                if (converted == NULL) {
                    free(command);
                    return NULL;
                }
                raw_offset = append_raw_argument(command,
                                                 raw_offset,
                                                 converted);
                free(converted);
            }
            command[raw_offset++] = L'"';
            command[raw_offset] = L'\0';
            return command;
        }
    }

    size_t offset = 0;
    wchar_t *converted_executable = utf8_to_wide(executable);
    if (converted_executable == NULL) {
        free(command);
        return NULL;
    }
    offset = append_quoted_argument(command, offset, converted_executable);
    free(converted_executable);

    for (int index = 0; index < argument_count; index++) {
        wchar_t *converted = utf8_to_wide(arguments[index]);
        if (converted == NULL) {
            free(command);
            return NULL;
        }
        command[offset++] = L' ';
        offset = append_quoted_argument(command, offset, converted);
        free(converted);
    }
    command[offset] = L'\0';
    return command;
}
