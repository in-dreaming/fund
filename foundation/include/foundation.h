#ifndef FOUNDATION_H
#define FOUNDATION_H

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#  if defined(FD_STATIC)
#    define FD_API
#  elif defined(FD_BUILDING_FOUNDATION)
#    define FD_API __declspec(dllexport)
#  else
#    define FD_API __declspec(dllimport)
#  endif
#  define FD_CALL __cdecl
#else
#  define FD_API __attribute__((visibility("default")))
#  define FD_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define FD_ABI_VERSION 1u
#define FD_STRUCT_VERSION_1 1u

typedef uint64_t fd_handle;
typedef uint64_t fd_operation;
typedef struct fd_context fd_context;

typedef struct fd_string_view {
    const char *data; /* Borrowed; may be NULL only when length is zero. */
    size_t length;
} fd_string_view;

typedef void (FD_CALL *fd_buffer_release_fn)(void *userdata, uint8_t *data, size_t length);
typedef struct fd_buffer {
    uint8_t *data;
    size_t length;
    fd_buffer_release_fn release;
    void *release_userdata;
} fd_buffer;

typedef enum fd_error_code {
    FD_OK = 0,
    FD_INVALID_ARGUMENT = 1,
    FD_INVALID_STATE = 2,
    FD_NOT_FOUND = 3,
    FD_PERMISSION_DENIED = 4,
    FD_CANCELLED = 5,
    FD_TIMEOUT = 6,
    FD_UNAVAILABLE = 7,
    FD_RESOURCE_EXHAUSTED = 8,
    FD_IO = 9,
    FD_NETWORK = 10,
    FD_PROTOCOL = 11,
    FD_CORRUPTED_DATA = 12,
    FD_UNSUPPORTED = 13,
    FD_INTERNAL = 14
} fd_error_code;

typedef enum fd_cancel_reason {
    FD_CANCEL_REQUESTED = 1,
    FD_CANCEL_TIMEOUT = 2,
    FD_CANCEL_SHUTDOWN = 3,
    FD_CANCEL_OWNER_DESTROYED = 4
} fd_cancel_reason;
typedef enum fd_operation_state {
    FD_OPERATION_PENDING = 0,
    FD_OPERATION_COMPLETED = 1,
    FD_OPERATION_FAILED = 2,
    FD_OPERATION_CANCELLED = 3
} fd_operation_state;

typedef struct fd_error {
    uint32_t struct_size;
    uint32_t struct_version;
    uint32_t code;
    int64_t native_code;
    fd_string_view message; /* Borrowed for the duration documented by the producer. */
} fd_error;

typedef void (FD_CALL *fd_callback_fn)(void *userdata);
typedef struct fd_executor {
    uint32_t struct_size;
    uint32_t struct_version;
    void *userdata;
    fd_error_code (FD_CALL *schedule)(void *userdata, fd_callback_fn callback, void *callback_userdata);
} fd_executor;

typedef struct fd_plugin_descriptor {
    uint32_t struct_size;
    uint32_t struct_version;
    uint32_t abi_version;
    uint64_t feature_bits;
    fd_string_view build_id;
    fd_error_code (FD_CALL *start)(const fd_context *host);
    void (FD_CALL *stop)(void);
} fd_plugin_descriptor;
typedef const fd_plugin_descriptor *(FD_CALL *fd_plugin_get_descriptor_fn)(void);

FD_API uint32_t FD_CALL fd_abi_version(void);
FD_API fd_error_code FD_CALL fd_string_view_validate(fd_string_view value);
FD_API fd_error_code FD_CALL fd_handle_validate(fd_handle handle);
FD_API fd_error_code FD_CALL fd_cancel_reason_validate(fd_cancel_reason reason);
FD_API fd_error_code FD_CALL fd_operation_state_validate(fd_operation_state state);
/* Invokes and clears release exactly once on the calling thread. */
FD_API fd_error_code FD_CALL fd_buffer_release(fd_buffer *buffer);
/* Uses the supplied executor. A successful return transfers callback ownership to it. */
FD_API fd_error_code FD_CALL fd_executor_schedule(const fd_executor *executor, fd_callback_fn callback, void *userdata);
FD_API fd_error_code FD_CALL fd_plugin_descriptor_validate(const fd_plugin_descriptor *descriptor, uint64_t required_features);

#ifdef __cplusplus
} /* extern "C" */
#endif
#endif /* FOUNDATION_H */
