#include "yyjson.h"

yyjson_doc *fd_yyjson_read(const char *data, size_t len) {
    return yyjson_read(data, len, 0);
}

void fd_yyjson_doc_free(yyjson_doc *document) {
    yyjson_doc_free(document);
}

yyjson_val *fd_yyjson_doc_get_root(yyjson_doc *document) {
    return yyjson_doc_get_root(document);
}
