#define FD_STATIC 1
#include "foundation.h"

static int releases = 0;
static int callbacks = 0;

static void FD_CALL release_buffer(void *userdata, uint8_t *data, size_t length) {
    (void)userdata;
    (void)data;
    (void)length;
    ++releases;
}

static void FD_CALL callback(void *userdata) {
    ++*(int *)userdata;
}

static fd_error_code FD_CALL schedule(void *userdata, fd_callback_fn work, void *work_userdata) {
    (void)userdata;
    work(work_userdata);
    return FD_OK;
}

int main(void) {
    fd_buffer buffer = { 0, 0, release_buffer, 0 };
    fd_executor executor = { sizeof(executor), FD_STRUCT_VERSION_1, 0, schedule };
    if (fd_abi_version() != FD_ABI_VERSION) return 1;
    if (fd_string_view_validate((fd_string_view){ 0, 1 }) != FD_INVALID_ARGUMENT) return 2;
    if (fd_handle_validate(42) != FD_INVALID_ARGUMENT) return 3;
    if (fd_buffer_release(&buffer) != FD_OK || releases != 1) return 4;
    if (fd_buffer_release(&buffer) != FD_INVALID_STATE) return 5;
    if (fd_executor_schedule(&executor, callback, &callbacks) != FD_OK || callbacks != 1) return 6;
    return 0;
}
