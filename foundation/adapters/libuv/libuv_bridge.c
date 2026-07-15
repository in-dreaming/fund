#include <stdlib.h>
#include <uv.h>

typedef void (*fd_uv_call)(void*);
typedef void (*fd_uv_watch_call)(void*, const char*, int, int);
typedef void (*fd_uv_accept_call)(void*, void*, int);
typedef void (*fd_uv_connect_call)(void*, void*, int);
typedef void (*fd_uv_read_call)(void*, const char*, size_t, int);
typedef void (*fd_uv_write_call)(void*, int);

struct fd_uv_loop { uv_loop_t loop; uv_async_t wake; void* context; fd_uv_call callback; };
struct fd_uv_timer { uv_timer_t timer; void* context; fd_uv_call callback; };
struct fd_uv_watch { uv_fs_event_t event; void* context; fd_uv_watch_call callback; };
struct fd_uv_stream { uv_tcp_t tcp; void* context; fd_uv_read_call read_callback; };
struct fd_uv_listener { uv_tcp_t tcp; void* context; fd_uv_accept_call callback; };
struct fd_uv_connect { uv_connect_t request; void* context; fd_uv_connect_call callback; struct fd_uv_stream* stream; };
struct fd_uv_write { uv_write_t request; void* context; fd_uv_write_call callback; char data[]; };

static void wake_callback(uv_async_t* handle) {
  struct fd_uv_loop* loop = handle->data;
  loop->callback(loop->context);
}
struct fd_uv_loop* fd_uv_loop_create(void* context, fd_uv_call callback) {
  struct fd_uv_loop* result = calloc(1, sizeof(*result));
  if (result == NULL) return NULL;
  if (uv_loop_init(&result->loop) != 0 || uv_async_init(&result->loop, &result->wake, wake_callback) != 0) { free(result); return NULL; }
  result->context = context; result->callback = callback; result->wake.data = result;
  return result;
}
void fd_uv_loop_destroy(struct fd_uv_loop* loop) {
  if (loop == NULL) return;
  uv_close((uv_handle_t*) &loop->wake, NULL);
  uv_run(&loop->loop, UV_RUN_DEFAULT);
  uv_loop_close(&loop->loop);
  free(loop);
}
int fd_uv_loop_pump(struct fd_uv_loop* loop) { return uv_run(&loop->loop, UV_RUN_NOWAIT); }
void fd_uv_loop_wakeup(struct fd_uv_loop* loop) { uv_async_send(&loop->wake); }
void fd_uv_loop_stop(struct fd_uv_loop* loop) { uv_stop(&loop->loop); }
static void timer_closed(uv_handle_t* handle) { free(handle); }
static void timer_callback(uv_timer_t* handle) {
  struct fd_uv_timer* timer = handle->data;
  timer->callback(timer->context);
  uv_close((uv_handle_t*) handle, timer_closed);
}
struct fd_uv_timer* fd_uv_timer_start(struct fd_uv_loop* loop, void* context, fd_uv_call callback, unsigned long long delay_ms) {
  struct fd_uv_timer* timer = calloc(1, sizeof(*timer));
  if (timer == NULL) return NULL;
  if (uv_timer_init(&loop->loop, &timer->timer) != 0 || uv_timer_start(&timer->timer, timer_callback, delay_ms, 0) != 0) { free(timer); return NULL; }
  timer->context = context; timer->callback = callback; timer->timer.data = timer;
  return timer;
}
void fd_uv_timer_cancel(struct fd_uv_timer* timer) { if (timer != NULL) { uv_timer_stop(&timer->timer); uv_close((uv_handle_t*) &timer->timer, timer_closed); } }
static void watch_closed(uv_handle_t* handle) { free(handle); }
static void watch_callback(uv_fs_event_t* handle, const char* filename, int events, int status) {
  struct fd_uv_watch* watch = handle->data;
  watch->callback(watch->context, filename, events, status);
}
struct fd_uv_watch* fd_uv_watch_start(struct fd_uv_loop* loop, void* context, fd_uv_watch_call callback, const char* path, unsigned int flags) {
  struct fd_uv_watch* watch = calloc(1, sizeof(*watch));
  if (watch == NULL) return NULL;
  if (uv_fs_event_init(&loop->loop, &watch->event) != 0 || uv_fs_event_start(&watch->event, watch_callback, path, flags) != 0) { free(watch); return NULL; }
  watch->context = context; watch->callback = callback; watch->event.data = watch;
  return watch;
}
void fd_uv_watch_stop(struct fd_uv_watch* watch) { if (watch != NULL) { uv_fs_event_stop(&watch->event); uv_close((uv_handle_t*) &watch->event, watch_closed); } }

static void stream_closed(uv_handle_t* handle) { free(handle); }
static void alloc_read(uv_handle_t* handle, size_t suggested, uv_buf_t* buffer) { (void) handle; buffer->base = malloc(suggested ? suggested : 1); buffer->len = suggested ? suggested : 1; }
static void on_read(uv_stream_t* handle, ssize_t size, const uv_buf_t* buffer) {
  struct fd_uv_stream* stream = handle->data;
  if (stream->read_callback != NULL) stream->read_callback(stream->context, buffer->base, size > 0 ? (size_t) size : 0, size < 0 ? (int) size : 0);
  free(buffer->base);
}
static void on_accept(uv_stream_t* server, int status) {
  struct fd_uv_listener* listener = server->data;
  struct fd_uv_stream* stream = calloc(1, sizeof(*stream));
  if (stream == NULL || uv_tcp_init(server->loop, &stream->tcp) != 0 || uv_accept(server, (uv_stream_t*) &stream->tcp) != 0) { free(stream); listener->callback(listener->context, NULL, status < 0 ? status : UV_ENOMEM); return; }
  stream->tcp.data = stream;
  listener->callback(listener->context, stream, status);
}
struct fd_uv_listener* fd_uv_tcp_listen(struct fd_uv_loop* loop, void* context, fd_uv_accept_call callback, unsigned short* port) {
  struct fd_uv_listener* listener = calloc(1, sizeof(*listener)); struct sockaddr_in address;
  if (listener == NULL || uv_tcp_init(&loop->loop, &listener->tcp) != 0 || uv_ip4_addr("127.0.0.1", 0, &address) != 0 || uv_tcp_bind(&listener->tcp, (const struct sockaddr*) &address, 0) != 0 || uv_listen((uv_stream_t*) &listener->tcp, 16, on_accept) != 0) { free(listener); return NULL; }
  listener->context = context; listener->callback = callback; listener->tcp.data = listener;
  { int len = sizeof(address); if (uv_tcp_getsockname(&listener->tcp, (struct sockaddr*) &address, &len) != 0) { uv_close((uv_handle_t*) &listener->tcp, stream_closed); return NULL; } *port = ntohs(address.sin_port); }
  return listener;
}
void fd_uv_tcp_listener_close(struct fd_uv_listener* listener) { if (listener != NULL) uv_close((uv_handle_t*) &listener->tcp, stream_closed); }
static void on_connect(uv_connect_t* request, int status) { struct fd_uv_connect* connect = request->data; connect->callback(connect->context, status == 0 ? connect->stream : NULL, status); free(connect); }
void fd_uv_tcp_connect(struct fd_uv_loop* loop, void* context, fd_uv_connect_call callback, unsigned short port) {
  struct fd_uv_connect* connect = calloc(1, sizeof(*connect)); struct sockaddr_in address;
  if (connect == NULL) { callback(context, NULL, UV_ENOMEM); return; }
  connect->stream = calloc(1, sizeof(*connect->stream)); connect->context = context; connect->callback = callback;
  if (connect->stream == NULL || uv_tcp_init(&loop->loop, &connect->stream->tcp) != 0 || uv_ip4_addr("127.0.0.1", port, &address) != 0 || uv_tcp_connect(&connect->request, &connect->stream->tcp, (const struct sockaddr*) &address, on_connect) != 0) { free(connect->stream); free(connect); callback(context, NULL, UV_ECONNREFUSED); return; }
  connect->stream->tcp.data = connect->stream; connect->request.data = connect;
}
void fd_uv_tcp_stream_set_context(struct fd_uv_stream* stream, void* context) { stream->context = context; }
int fd_uv_tcp_stream_read(struct fd_uv_stream* stream, fd_uv_read_call callback) { stream->read_callback = callback; return uv_read_start((uv_stream_t*) &stream->tcp, alloc_read, on_read); }
void fd_uv_tcp_stream_close(struct fd_uv_stream* stream) { if (stream != NULL) uv_close((uv_handle_t*) &stream->tcp, stream_closed); }
static void on_write(uv_write_t* request, int status) { struct fd_uv_write* write = request->data; write->callback(write->context, status); free(write); }
int fd_uv_tcp_stream_write(struct fd_uv_stream* stream, const char* data, size_t length, void* context, fd_uv_write_call callback) { struct fd_uv_write* write = malloc(sizeof(*write) + length); uv_buf_t buffer; if (write == NULL) return UV_ENOMEM; memcpy(write->data, data, length); write->context = context; write->callback = callback; write->request.data = write; buffer = uv_buf_init(write->data, (unsigned int) length); { int result = uv_write(&write->request, (uv_stream_t*) &stream->tcp, &buffer, 1, on_write); if (result != 0) free(write); return result; } }
