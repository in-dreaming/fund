#define FD_STATIC 1
#include "foundation.h"

int main() {
    fd_string_view empty{nullptr, 0};
    return fd_string_view_validate(empty) == FD_OK ? 0 : 1;
}
