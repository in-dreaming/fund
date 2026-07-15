# Foundation Layer 公共基础设施设计文档

## 面向 Zig/C 游戏引擎、Agent Runtime、工具链与服务器的基础公共库

**文档状态：** 架构设计稿
**目标语言：** Zig
**公共接口：** Zig API + 稳定 C ABI
**核心原则：** 统一接口、复用成熟实现、少量关键自研、可替换 Backend、严格依赖治理

---

# 1. 文档目的

本文定义一套可供以下系统共同复用的 Foundation Layer：

* 游戏 Runtime；
* Native Agent Runtime；
* Editor；
* Job System；
* Resource Task Graph；
* 资源构建与打包工具；
* Profiler 与性能分析工具；
* 机器农场终端；
* SVN 等开发工具；
* CLI；
* 独立服务器；
* 自动化测试程序。

Foundation Layer 不应成为某个具体系统的内部工具集合，也不应试图替代 Zig 标准库或重新实现所有成熟基础库。

它的核心职责是：

1. 统一全项目的基础类型和工程语义；
2. 隔离 Zig 标准库和第三方库的变化；
3. 为第三方实现提供稳定 Facade 和 Adapter；
4. 统一生命周期、取消、异步、错误和内存所有权；
5. 为不同平台和构建目标提供可替换 Backend；
6. 避免各项目重复实现相同底层机制；
7. 控制第三方依赖数量、许可证和升级风险。

Foundation Layer 的本质是：

> 一套基础能力治理层，而不是一套全部从零开发的基础设施实现。

---

# 2. 背景

当前规划中的多个系统存在大量重复需求。

## 2.1 Agent Runtime

需要：

* HTTP/HTTPS；
* SSE；
* JSON；
* Cancellation；
* Future；
* Executor；
* Buffer；
* Timer；
* Session 持久化；
* Trace；
* C ABI。

## 2.2 Job System 与 Task Graph

需要：

* Thread；
* Atomic；
* Queue；
* Stable Handle；
* Cancellation；
* Future；
* Executor；
* Clock；
* Profiler；
* Resource ID。

## 2.3 游戏 Runtime

需要：

* 内存分配；
* Stable Object Handle；
* 文件系统；
  -异步 I/O；
  -日志；
  -压缩；
  -Hash；
  -插件加载；
  -C ABI。

## 2.4 工具链与机器农场

需要：

* HTTP；
  -进程管理；
  -文件操作；
  -下载；
  -压缩；
  -SQLite；
  -日志；
  -配置；
  -异步任务；
  -故障恢复。

如果每个项目自行选择和封装这些能力，将出现：

* 相同第三方库被多次集成；
* 错误码和生命周期不一致；
* 各自实现 Cancellation 和 Future；
* 多套线程池同时存在；
* 不同模块使用不同 JSON 库；
* Buffer 在 C ABI 间无法安全传递；
* 日志、Metrics 和 Trace 无法关联；
* 依赖版本和许可证不可控；
* 平台差异散落在业务代码中；
* 第三方库升级影响整个项目。

因此需要一个独立的 Foundation Layer 统一治理。

---

# 3. 项目定位

## 3.1 一句话定义

Foundation Layer 是：

> 以 Zig 为主、提供稳定 Zig API 与 C ABI、通过 Facade 和 Adapter 复用标准库及成熟第三方实现的公共基础设施层。

---

## 3.2 Foundation Layer 负责什么

Foundation 负责：

* 基础类型；
* Stable Handle；
* 内存所有权规范；
* SharedBuffer；
* Error Mapping；
* Cancellation；
* Future 和 Operation 语义；
* Executor 抽象；
* Channel 与 Mailbox；
* Time 和 Clock；
* Logging Facade；
* Metrics Facade；
* Trace Facade；
* 文件系统抽象；
* HTTP 抽象；
* JSON 抽象；
* 压缩抽象；
* Hash 抽象；
  -数据库 Adapter；
  -插件 ABI；
  -C ABI；
  -第三方依赖管理；
  -测试和故障注入。

---

## 3.3 Foundation Layer 不负责什么

Foundation 不负责：

* Agent Loop；
* Workflow；
* Job System 具体调度；
* Resource Task Graph；
* ECS；
  -对象系统；
  -渲染；
  -Gameplay；
  -资产格式；
  -资源打包策略；
  -数据库 ORM；
  -网络业务协议；
  -完整 RPC 框架；
  -完整 VFS；
  -模型 Provider；
  -复杂反射；
  -脚本语言；
  -自研 TLS；
  -自研压缩算法；
  -自研通用数据库。

---

# 4. 核心设计原则

## 4.1 优先复用

每项能力按以下顺序评估：

```text
Zig 标准库
    ↓
成熟、长期维护的 C/C++ 库
    ↓
已有引擎基础设施
    ↓
小型 Adapter 或补充实现
    ↓
必要时自研
```

不能因为目标语言是 Zig，就拒绝成熟 C 库。

---

## 4.2 Facade 不等于重写

例如 HTTP 层：

```text
上层模块
    ↓
foundation.http.HttpClient
    ↓
CurlBackend
```

Foundation 统一：

* Request；
* Response；
* Cancellation；
* Timeout；
* Buffer；
* Error；
* Metrics；
* Mock。

libcurl 负责：

* HTTP；
* HTTPS；
  -连接池；
  -证书；
  -重定向；
  -代理；
  -协议细节。

Foundation 不复制 libcurl 功能。

---

## 4.3 第三方实现不可直接泄漏到业务层

业务模块不应直接依赖：

```text
curl_easy_*
sqlite3_*
yyjson_*
ZSTD_*
uv_*
```

所有第三方能力通过对应 Adapter 进入。

这样可以：

* 替换实现；
* 控制升级范围；
  -统一错误；
  -统一内存；
  -统一监控；
  -在测试中替换 Mock。

---

## 4.4 只自研关键语义层

Foundation 真正需要自行掌控的是：

* Stable Handle；
* Cancellation 统一语义；
* Executor 抽象；
* Future/Operation 规范；
* SharedBuffer；
* Error Mapping；
* Shutdown；
* C ABI；
  -依赖治理；
  -Adapter；
  -测试设施。

这些能力跨越所有模块，且现有库无法直接提供统一语义。

---

## 4.5 可替换 Backend

所有可能受平台、性能或依赖影响的能力，都应允许替换：

```text
HTTP
JSON
Compression
Hash
Allocator
File System
Executor
Profiler
Database
TLS
Async I/O
```

但“允许替换”不等于同时维护多个完整实现。

每个能力应有：

* 一个默认生产 Backend；
* 一个测试 Backend；
* 必要时一个平台 Backend。

---

## 4.6 避免过度抽象

以下情况不应先抽象：

* 只有一个明确实现；
* 上层无需感知差异；
* 替换成本低；
* 接口尚未稳定；
* 抽象会损失核心性能或能力。

应避免创建大量只转发一个函数的无意义包装。

---

## 4.7 不隐式创建 Runtime 设施

Foundation 不应因为被链接就自动创建：

* 全局线程池；
  -网络线程；
  -日志线程；
  -数据库；
  -监控服务；
  -后台清理任务。

所有设施必须显式初始化。

---

# 5. 总体架构

```text
┌───────────────────────────────────────────────────────────────┐
│ Game Runtime / Agent Runtime / Editor / Tools / Server        │
├───────────────────────────────────────────────────────────────┤
│ Foundation Public API                                         │
│                                                               │
│ Handle / Buffer / Error / Cancellation / Future / Executor    │
│ FileSystem / HTTP / JSON / Hash / Compression / Logging       │
├───────────────────────────────────────────────────────────────┤
│ Foundation Adapters                                           │
│                                                               │
│ curl / libuv / yyjson / SQLite / zstd / LZ4 / BLAKE3 / Tracy  │
│ Zig std / Engine Job System / Platform APIs                    │
├───────────────────────────────────────────────────────────────┤
│ Zig std / OS / Mature Third-party Libraries                   │
└───────────────────────────────────────────────────────────────┘
```

---

# 6. 模块划分

```text
foundation/
├── core
├── memory
├── containers
├── text
├── ids
├── error
├── time
├── sync
├── async
├── executor
├── channel
├── io
├── filesystem
├── network
├── serialization
├── compression
├── hash
├── database
├── logging
├── metrics
├── trace
├── process
├── plugin
├── platform
├── cabi
├── testing
└── adapters
```

其中：

* `core` 为小型稳定核心；
* `adapters` 集成第三方；
* 大部分第三方能力不进入最小核心。

---

# 7. 依赖层级

## 7.1 Foundation Core

Foundation Core 应保持小而稳定：

```text
foundation-core
├── base
├── memory conventions
├── strong ids
├── stable handles
├── error model
├── time
├── cancellation
├── future/operation
├── executor interface
├── shared buffer
├── shutdown
└── C ABI base
```

Core 原则上只依赖 Zig 标准库和 OS 最基础能力。

---

## 7.2 Foundation Standard Adapters

```text
foundation-std
├── std containers
├── std filesystem
├── std json
├── std threads
├── std crypto
└── std testing
```

这层不是重新包装所有 Zig API，而是：

* 固定项目入口；
  -统一版本适配；
  -补充缺失能力；
  -避免业务依赖 Zig 内部模块路径。

---

## 7.3 Third-party Adapters

```text
foundation-curl
foundation-libuv
foundation-yyjson
foundation-sqlite
foundation-zstd
foundation-lz4
foundation-blake3
foundation-mimalloc
foundation-tracy
foundation-mbedtls
```

上层按需链接。

---

# 8. 技术选型总表

| 能力                 | 默认方案                        | Foundation 自研内容                   |
| ------------------ | --------------------------- | --------------------------------- |
| Allocator          | Zig `std.mem.Allocator`     | Tag、Tracking、Budget、测试 Decorator  |
| Arena              | `std.heap.ArenaAllocator`   | 生命周期规范                            |
| 容器                 | Zig std                     | HandleTable、特殊有界并发容器              |
| Thread/Atomic      | Zig std、OS                  | 轻量规范与 Debug 检查                    |
| Stable Handle      | 自研                          | Index + Generation                |
| SharedBuffer       | 自研                          | 引用计数与跨 ABI Ownership              |
| Cancellation       | 自研语义                        | Backend 适配                        |
| Future/Operation   | 自研语义                        | 与 Executor、C ABI 集成               |
| Executor           | 自研接口                        | Job System、libuv 等 Adapter        |
| 文件系统               | Zig std + OS                | FileSystem Facade、Memory FS       |
| HTTP/HTTPS         | libcurl                     | HttpClient Facade、Cancellation 适配 |
| 通用 Event Loop      | 引擎 Job System；工具端 libuv     | IoBackend 抽象                      |
| JSON               | `std.json` + yyjson         | Codec Facade、Value View           |
| JSON Schema        | 轻量自研子集                      | Tool 参数校验                         |
| 压缩                 | zstd、LZ4                    | Compressor 接口和 Adapter            |
| Hash               | Zig std、BLAKE3              | Strong Hash 类型与接口                 |
| SQLite             | SQLite Amalgamation         | RAII、错误和 Executor 适配              |
| Profiler           | Tracy                       | Trace Facade 与 Adapter            |
| TLS                | libcurl Backend；可选 Mbed TLS | 配置与错误映射                           |
| Logging            | 轻量自研 Facade                 | Sink 与第三方 Adapter                 |
| Metrics            | 轻量自研 Facade                 | Sink 与 Exporter                   |
| Agent Trace/Replay | 自研                          | 行为级记录与重放                          |
| Process            | Zig std/OS 或 libuv          | Process Facade                    |
| Dynamic Library    | Zig std/OS                  | Plugin ABI 与生命周期                  |
| 测试                 | `std.testing`               | Mock、TestClock、Fault Injection    |

---

# 9. Zig 标准库使用策略

## 9.1 直接复用

优先直接使用：

* `std.mem.Allocator`；
* `std.heap.ArenaAllocator`；
* `std.ArrayList`；
* `std.HashMap`；
* `std.Thread`；
* `std.atomic`；
* `std.fs`；
* `std.json`；
* `std.testing`；
  -标准加密和编码工具。

Foundation 不应重新实现这些通用能力。

---

## 9.2 只做薄隔离

Zig 标准库接口仍可能随版本变化。

Foundation 可以通过统一入口隔离：

```zig
pub const collections = @import("collections/root.zig");
pub const filesystem = @import("filesystem/root.zig");
pub const json = @import("serialization/json.zig");
```

但不要把每个类型重新包装成一套相同 API。

---

## 9.3 Zig 版本策略

整个工程应统一 Zig 版本，不允许各子项目自行升级。

建议：

* 固定 Zig 版本；
  -在 CI 中锁定；
  -Foundation 负责版本适配；
  -业务层禁止依赖不稳定内部 API；
  -升级 Zig 时先通过 Foundation 测试集。

---

# 10. 内存管理

## 10.1 直接采用 Zig Allocator

Foundation 不自研通用堆。

默认使用：

* Zig 标准分配器；
  -引擎 Allocator Adapter；
  -可选 mimalloc Adapter。

---

## 10.2 需要统一的内容

Foundation 统一：

* 所有权规则；
* Allocator 参数传递；
* SharedBuffer；
  -内存 Tag；
  -内存预算；
  -测试分配器；
  -跨 ABI 内存释放；
  -短生命周期 Arena 规范。

---

## 10.3 Ownership 分类

所有 API 返回数据时必须属于以下一种：

### Borrowed

```zig
fn name(self: *const Object) []const u8;
```

### Caller Allocated

```zig
fn serialize(self: *const Object, output: []u8) !usize;
```

### Allocator Owned

```zig
fn clone(self: *const Object, allocator: Allocator) !OwnedObject;
```

### Shared Ownership

```zig
fn readAsync(...) Future(SharedBuffer);
```

### Handle Ownership

```zig
fn createOperation(...) OperationHandle;
```

---

## 10.4 SharedBuffer

需要自行实现统一的 SharedBuffer，因为不同 Backend 可能返回：

* Heap；
* mmap；
* libcurl Buffer；
  -外部 C Buffer；
  -文件缓存；
  -网络 Buffer；
  -共享内存。

```zig
pub const SharedBuffer = struct {
    storage: *Storage,
    offset: usize,
    len: usize,
};
```

能力：

* 引用计数；
  -子 Slice；
  -自定义释放函数；
  -只读/可写；
  -跨线程；
  -跨 C ABI；
  -内存 Tag；
  -调试信息。

---

## 10.5 可选 mimalloc

mimalloc 作为可选 Backend，不作为硬依赖。

适合：

* Editor；
  -服务器；
  -大量小对象；
  -多线程工具；
  -内存碎片明显场景。

游戏 Runtime 是否使用，应由性能数据决定。

---

# 11. 容器

## 11.1 默认使用 Zig std

默认不自研：

* Vector；
* HashMap；
* Set；
* Tree；
  -普通 Queue；
  -普通 String。

---

## 11.2 需要自行提供的特殊容器

只实现项目确实需要、标准库缺失或语义特殊的容器：

* HandleTable；
* SlotMap；
* Bounded MPSC Queue；
* SPSC Ring Buffer；
* Small Inline Buffer；
  -固定容量 Mailbox；
  -Generation Pool。

---

## 11.3 Stable Handle

```zig
pub const Handle = packed struct {
    index: u32,
    generation: u32,
};
```

适用于：

* Agent；
* Job；
* Operation；
* Stream；
* Tool；
  -插件；
  -游戏对象桥接。

必须支持：

* Generation 校验；
  -类型区分；
  -Debug Type Tag；
  -C ABI `u64`；
  -快速查找；
  -安全复用 Slot。

---

# 12. 错误模型

第三方库错误需要统一映射：

```text
Zig error
curl code
uv error
SQLite code
yyjson error
OS error
```

Foundation 定义统一类别：

```zig
pub const ErrorCategory = enum {
    invalid_argument,
    invalid_state,
    not_found,
    permission_denied,
    cancelled,
    timeout,
    unavailable,
    resource_exhausted,
    io,
    network,
    protocol,
    corrupted_data,
    unsupported,
    internal,
};
```

错误信息：

```zig
pub const ErrorInfo = struct {
    category: ErrorCategory,
    native_code: i64,
    message: []const u8,
    source: SourceLocation,
};
```

原则：

* 不丢失原始错误码；
  -不使用全局 `last_error`；
  -错误可附加上下文；
  -异步错误存入 Operation State；
  -C ABI 使用稳定 Error Code；
  -敏感信息不能直接暴露给用户。

---

# 13. 时间与 Clock

Foundation 自行统一类型，但使用 Zig/OS 实现。

至少区分：

* Monotonic Clock；
* Wall Clock；
* Game Clock；
* Test Clock。

```zig
pub const Duration = struct {
    nanoseconds: i64,
};

pub const MonotonicInstant = struct {
    ticks: u64,
};
```

规则：

* Timeout 使用 Monotonic Clock；
  -日志时间使用 Wall Clock；
  -游戏逻辑使用 Game Clock；
  -测试使用可推进 Test Clock；
  -API 不使用含义不明的裸时间整数。

---

# 14. Cancellation

Cancellation 是必须自行统一的核心语义。

第三方库通常有自己的取消方式：

* libcurl progress callback；
* libuv handle close；
  -引擎 Job Cancel；
  -OS I/O cancel；
  -Future 状态；
  -Process kill。

Foundation 需要将这些映射为同一套模型。

```zig
pub const CancellationSource = struct {
    state: *CancellationState,

    pub fn token(self: *const CancellationSource) CancellationToken;
    pub fn cancel(self: *CancellationSource, reason: CancelReason) void;
};
```

支持：

* 父子传播；
  -取消原因；
  -注册 Callback；
  -取消与完成 Race；
  -Owner Destroy；
  -Timeout；
  -Shutdown。

Cancellation 表示“请求停止”，不保证底层操作立即停止。

---

# 15. Future 与 Operation

Foundation 需要统一 Future 和长操作语义，但不自行实现完整协程 Runtime。

## 15.1 Future

Future 表示一个结果：

```zig
pub const FutureState = enum {
    pending,
    completed,
    failed,
    cancelled,
};
```

## 15.2 Operation

Operation 表示具有生命周期的异步工作：

* 文件请求；
  -HTTP 请求；
  -Process；
  -Tool；
  -模型请求；
  -资源加载。

```zig
pub const OperationHandle = packed struct {
    index: u32,
    generation: u32,
};
```

## 15.3 Executor 回调

所有异步完成回调应显式指定 Executor。

避免：

* 在 libcurl 线程直接调用游戏逻辑；
  -有时同步、有时异步回调；
  -回调线程不可预测；
  -主线程重入。

---

# 16. Executor

Foundation 只定义 Executor 抽象。

```zig
pub const ExecutorVTable = struct {
    submit: *const fn (
        ptr: *anyopaque,
        task: TaskFn,
        userdata: *anyopaque,
        options: SubmitOptions,
    ) SubmitResult,

    cancel: *const fn (
        ptr: *anyopaque,
        handle: TaskHandle,
    ) bool,
};
```

支持 Adapter：

```text
Engine Job System
Resource Task Graph Adapter
libuv Event Loop
Fixed Thread Pool
Main Thread Queue
Immediate Executor
Test Executor
```

Foundation 不强制提供一套生产级 Job System。

可以提供简单 Thread Pool 作为：

* 测试；
  -CLI；
  -示例；
  -独立工具默认实现。

游戏 Runtime 应优先接入引擎已有 Job System。

---

# 17. Channel 与 Mailbox

Foundation 可自行实现少量有界队列，或基于成熟算法实现。

默认优先：

* Bounded SPSC；
* Bounded MPSC；
* Ring Buffer；
* Mailbox。

队列必须定义 Backpressure：

```zig
pub const OverflowPolicy = enum {
    reject,
    block,
    drop_newest,
    drop_oldest,
    coalesce,
};
```

适用示例：

| 场景          | 策略                     |
| ----------- | ---------------------- |
| Gameplay 命令 | Reject                 |
| Profiler 样本 | Drop                   |
| 世界状态更新      | Coalesce               |
| 关键错误        | 保留                     |
| 模型 Token 流  | Bounded + Backpressure |

不应默认提供无界队列。

---

# 18. 文件系统

## 18.1 底层复用

本地文件访问优先使用：

* Zig `std.fs`；
  -OS API；
  -后续可选原生异步 I/O。

---

## 18.2 Foundation 负责的抽象

```zig
pub const FileSystem = struct {
    ptr: *anyopaque,
    vtable: *const FileSystemVTable,
};
```

支持 Backend：

* NativeFileSystem；
* MemoryFileSystem；
* ReadOnlyFileSystem；
* OverlayFileSystem；
* SandboxFileSystem；
* MockFileSystem。

---

## 18.3 为什么仍需要 FileSystem Facade

因为项目需要：

* VFS；
  -内存 Merge；
  -自动测试；
  -Agent 沙箱；
  -Overlay；
  -虚拟路径；
  -多平台；
  -远程文件 Backend。

这不是重复实现 `std.fs`，而是在其上建立业务无关的可替换文件系统接口。

---

## 18.4 必须统一的能力

* Path 类型；
  -原子写；
  -mmap 抽象；
  -异步读取接口；
  -Cancellation；
  -Partial Read/Write；
  -文件监控事件；
  -错误映射；
  -安全路径限制。

---

# 19. HTTP 与网络

## 19.1 默认使用 libcurl

HTTP/HTTPS 默认采用 libcurl。

Foundation 不自研：

* HTTP 协议栈；
  -TLS；
  -代理；
  -证书验证；
  -连接池；
  -HTTP/2；
  -重定向；
  -上传下载协议。

---

## 19.2 HttpClient Facade

```zig
pub const HttpClient = struct {
    backend: HttpBackend,

    pub fn start(
        self: *HttpClient,
        request: HttpRequest,
        options: RequestOptions,
    ) !HttpOperation;
};
```

统一：

* URL；
  -Method；
  -Headers；
  -Body；
  -Response Stream；
  -Cancellation；
  -Timeout；
  -Body Limit；
  -Metrics；
  -Trace；
  -Error Mapping。

---

## 19.3 Backend

```text
CurlBackend        默认生产
MockHttpBackend    测试
EngineHttpBackend  可选
StdHttpBackend     轻量工具或实验
```

业务模块不能直接调用 libcurl。

---

## 19.4 SSE

SSE 可以自行实现轻量增量 Parser。

原因：

* 协议简单；
  -需要处理任意网络 Chunk；
  -与模型流紧密相关；
  -可以复用统一 Stream；
  -无需引入额外库。

但 SSE Parser 只处理协议解析，不处理 HTTP。

---

# 20. libuv 使用策略

libuv 可用于：

* CLI；
  -机器农场终端；
  -Agent Server；
  -工具进程；
  -Process；
  -Pipe；
  -Timer；
  -跨平台 Socket；
  -Event Loop。

不建议游戏 Runtime 强绑定 libuv，因为游戏已有：

* Job System；
  -主线程循环；
  -平台网络；
  -自己的生命周期。

推荐：

```text
Game Runtime
    → Engine Executor / Engine I/O Backend

CLI / Agent Server / Machine Client
    → libuv Backend
```

Foundation 只提供统一接口。

---

# 21. JSON

## 21.1 双 Backend

```text
std.json
    适合配置、小数据、Zig 类型序列化

yyjson
    适合高频 Provider、Tool Call、大量 JSON
```

Foundation 定义：

```zig
pub const JsonCodec = struct {
    ptr: *anyopaque,
    vtable: *const JsonCodecVTable,
};
```

但不应为了抽象而抹平两个库的重要能力。

---

## 21.2 Value View

可以定义轻量只读统一视图：

```zig
pub const JsonValueView = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    unsigned: u64,
    float: f64,
    string: []const u8,
    array: JsonArrayView,
    object: JsonObjectView,
};
```

用于 Tool、Provider 和 C ABI。

---

## 21.3 JSON Schema

不引入重量级完整 Schema Engine。

自研小型、编译后的子集，用于：

* Tool 参数；
  -配置校验；
  -RPC 输入。

支持：

* type；
  -required；
  -properties；
  -array；
  -enum；
  -number range；
  -string length；
  -additionalProperties。

---

# 22. 压缩

不自研压缩算法。

推荐 Backend：

```text
ZstdAdapter
Lz4Adapter
ZlibAdapter
OodleAdapter
```

Foundation 定义：

```zig
pub const Compressor = struct {
    ptr: *anyopaque,
    vtable: *const CompressorVTable,
};
```

能力：

* compress；
  -decompress；
  -stream；
  -bound；
  -dictionary；
  -level；
  -checksum；
  -error mapping。

默认建议：

* zstd：通用和较高压缩率；
* LZ4：超快解压；
* Oodle：商业项目可选；
* zlib：兼容格式。

---

# 23. Hash

## 23.1 分类

不同用途使用不同实现。

| 用途        | 方案                 |
| --------- | ------------------ |
| HashMap   | Zig std            |
| 临时高速 Hash | std 或 xxHash       |
| 内容寻址      | BLAKE3             |
| 安全协议      | SHA-256 等成熟实现      |
| 稳定缓存 Key  | BLAKE3 或版本化稳定 Hash |

---

## 23.2 Foundation 负责

* `ContentHash` 类型；
  -Streaming Hasher 接口；
  -文件 Hash；
  -Hash 版本；
  -序列化；
  -错误处理。

不自行实现 BLAKE3 SIMD。

---

# 24. SQLite

SQLite 作为可选 Adapter，而非 Foundation Core。

适合：

* Agent Session；
  -Trace 索引；
  -缓存元数据；
  -工具状态；
  -机器终端本地数据库；
  -Editor 数据。

Foundation 提供：

* Connection 生命周期；
  -Statement 生命周期；
  -错误映射；
  -事务；
  -Executor 适配；
  -Cancellation 的最佳努力；
  -测试数据库；
  -编译选项统一。

不提供：

* ORM；
  -业务 Schema；
  -自动迁移框架；
  -Repository 模式。

---

# 25. Logging

Logging Facade 适合自研，因为需要统一跨系统语义，但 Sink 可复用现有系统。

```zig
pub const LogRecord = struct {
    timestamp: UnixTimestamp,
    level: LogLevel,
    category: SymbolId,
    message: []const u8,
    fields: []const LogField,
    trace_context: ?TraceContext,
};
```

Sink：

* Console；
  -File；
  -Rotating File；
  -Memory Ring；
  -Engine Console；
  -Tracy；
  -远程系统；
  -Noop。

异步日志必须：

* 有界；
  -可配置 Overflow；
  -Shutdown Flush；
  -统计丢弃量；
  -不阻塞游戏主线程。

---

# 26. Metrics

Foundation 只定义轻量 Metrics Facade：

* Counter；
  -Gauge；
  -Histogram；
  -Timer。

Sink：

* Noop；
  -Log；
  -Prometheus；
  -OpenTelemetry；
  -引擎 Profiler；
  -自研服务。

不绑定：

* 数据库；
  -OTel SDK；
  -监控服务器；
  -特定时序数据库。

---

# 27. Trace 与 Tracy

## 27.1 性能 Trace

优先复用 Tracy。

Tracy 负责：

* CPU Zone；
  -GPU Zone；
  -Frame；
  -Thread；
  -Lock；
  -内存；
  -Plot；
  -远程查看。

Foundation 提供：

```text
Trace Facade
    └── Tracy Adapter
```

---

## 27.2 语义 Trace

以下内容仍需上层自研：

* Agent 模型请求；
  -Tool 调用；
  -Session；
  -Workflow 状态；
  -确定性 Replay；
  -Task Graph 数据；
  -业务事件。

性能 Trace 和语义 Trace 不应混为一体。

---

# 28. TLS 与密码学

绝不自研 TLS 和密码学算法。

优先：

* libcurl 使用系统 TLS；
  -Windows Schannel；
  -Apple 系统 TLS；
  -OpenSSL；
  -Mbed TLS；
  -平台 SDK。

Foundation 只统一：

* TLS Config；
  -证书路径；
  -Trust Store；
  -客户端证书；
  -错误映射；
  -敏感数据清理；
  -测试配置。

---

# 29. Process 与 IPC

## 29.1 Process

底层可使用：

* Zig std；
  -libuv；
  -OS API。

Foundation 统一：

* Executable；
  -Arguments；
  -Environment；
  -Working Directory；
  -stdin/stdout/stderr；
  -Timeout；
  -Cancellation；
  -Exit Code；
  -Process Group；
  -Kill。

---

## 29.2 禁止默认 Shell

默认接口：

```zig
spawn(executable, argv)
```

Shell 执行作为高风险独立模块。

---

## 29.3 IPC

支持抽象：

* Pipe；
  -Named Pipe；
  -Unix Socket；
  -Shared Memory；
  -Local TCP。

Foundation 不定义业务 RPC。

---

# 30. Plugin 与动态库

动态库加载使用 Zig std 或 OS API。

Foundation 自行定义：

* Plugin Descriptor；
  -ABI Version；
  -Feature；
  -Lifetime；
  -Unload Guard；
  -C ABI；
  -Build ID。

禁止第三方插件直接依赖 Zig 内部 ABI。

---

# 31. C ABI

C ABI 是 Foundation Core 的关键组成。

## 31.1 String

```c
typedef struct fd_string_view {
    const char* data;
    size_t size;
} fd_string_view;
```

---

## 31.2 Buffer

```c
typedef void (*fd_release_fn)(
    void* userdata,
    const uint8_t* data,
    size_t size
);

typedef struct fd_buffer {
    const uint8_t* data;
    size_t size;
    fd_release_fn release;
    void* userdata;
} fd_buffer;
```

---

## 31.3 Handle

```c
typedef uint64_t fd_handle;
```

内部通常是：

```text
index + generation
```

---

## 31.4 Struct Version

```c
typedef struct fd_http_request {
    uint32_t struct_size;
    uint32_t struct_version;
    ...
} fd_http_request;
```

支持向后兼容扩展。

---

## 31.5 Callback 规则

所有 Callback 必须声明：

* 调用线程；
  -调用次数；
  -是否可重入；
  -参数生命周期；
  -是否允许阻塞；
  -注销方式；
  -Shutdown 行为。

---

# 32. Testing

## 32.1 复用 Zig 测试

使用：

* `zig test`；
  -`std.testing`；
  -标准测试 Allocator。

---

## 32.2 Foundation 补充设施

自行提供：

* TestClock；
  -TestExecutor；
  -MockFileSystem；
  -MockHttpBackend；
  -MockProcess；
  -FaultInjector；
  -FailAllocator；
  -Deterministic Scheduler；
  -Trace Recorder。

---

## 32.3 Fault Injection

需要支持：

```text
第 N 次分配失败
文件 Partial Read
磁盘满
HTTP 超时
SSE 任意分块
Process 卡死
SQLite Busy
Callback 延迟
Cancel/Complete Race
```

这些设施比重新实现生产 Backend 更有价值。

---

# 33. Shutdown

统一 Shutdown 协议：

```text
1. Stop Accepting New Work
2. Cancel Owned Operations
3. Drain Critical Completion
4. Flush Logs and Trace
5. Stop Event Loops
6. Join Threads
7. Destroy Adapters
8. Report Leaks
```

模式：

```zig
pub const ShutdownMode = enum {
    graceful,
    immediate,
};
```

Graceful 必须有 Deadline，禁止无限等待。

---

# 34. 第三方依赖治理

## 34.1 依赖清单

每个第三方依赖必须记录：

* 名称；
  -版本；
  -Commit；
  -许可证；
  -用途；
  -目标平台；
  -静态或动态链接；
  -是否修改源码；
  -补丁；
  -安全升级策略；
  -替换成本；
  -负责人。

---

## 34.2 目录

```text
third_party/
├── manifests/
├── licenses/
├── patches/
├── build/
└── source/
```

---

## 34.3 规则

1. 业务层禁止直接引用第三方 API。
2. 第三方库通过单一 Adapter 集成。
3. 版本必须锁定。
4. 每个依赖必须有集成测试。
5. 安全依赖必须支持快速升级。
6. 不使用浮动 Git 分支。
7. 不无条件复制第三方源码。
8. 修改源码必须保留 Patch。
9. License 必须进入发布物。
10. Console 平台依赖单独评审。
11. BSL、GPL、AGPL、SSPL 等许可证必须单独审批。
12. 默认优先宽松许可证和官方维护库。
13. 每项依赖都应有移除和替换路径。

---

# 35. Build Profile

## 35.1 Core

```text
base
memory conventions
handle
error
time
cancellation
future
executor interface
buffer
C ABI
```

无：

* 网络；
  -数据库；
  -压缩；
  -Profiler；
  -Process。

---

## 35.2 Game Runtime

```text
Core
Engine Executor Adapter
FileSystem
Compression
Hash
Logging
Tracy
可选 HTTP
```

---

## 35.3 Agent Runtime

```text
Core
HTTP/curl
SSE
yyjson
SQLite
Logging
Metrics
Trace
Process optional
```

---

## 35.4 Tooling

```text
Core
libuv
curl
yyjson
SQLite
Process
File Watch
Compression
Tracy optional
```

---

## 35.5 Server

```text
Core
libuv or server event loop
curl
SQLite
Metrics
Trace
mimalloc optional
```

---

# 36. 目录结构

```text
foundation/
├── build.zig
├── build.zig.zon
├── include/
│   └── foundation.h
├── src/
│   ├── core/
│   ├── memory/
│   ├── containers/
│   ├── text/
│   ├── ids/
│   ├── error/
│   ├── time/
│   ├── sync/
│   ├── async/
│   ├── executor/
│   ├── channel/
│   ├── io/
│   ├── filesystem/
│   ├── network/
│   ├── serialization/
│   ├── compression/
│   ├── hash/
│   ├── database/
│   ├── logging/
│   ├── metrics/
│   ├── trace/
│   ├── process/
│   ├── plugin/
│   ├── platform/
│   ├── cabi/
│   └── testing/
├── adapters/
│   ├── curl/
│   ├── libuv/
│   ├── yyjson/
│   ├── sqlite/
│   ├── zstd/
│   ├── lz4/
│   ├── blake3/
│   ├── mimalloc/
│   ├── tracy/
│   ├── mbedtls/
│   └── engine/
├── third_party/
│   ├── manifests/
│   ├── licenses/
│   ├── patches/
│   └── build/
├── examples/
└── tests/
```

---

# 37. 分阶段实施

## Phase 0：依赖治理与规范

完成：

* Zig 版本锁定；
  -模块边界；
  -第三方依赖规范；
  -License 清单；
  -Ownership 规范；
  -Error 规范；
  -C ABI 规范；
  -Build Feature；
  -CI。

---

## Phase 1：Foundation Core

实现：

* StrongId；
  -HandleTable；
  -SharedBuffer；
  -ErrorInfo；
  -Duration；
  -Clock；
  -Cancellation；
  -Future；
  -Operation；
  -Executor 接口；
  -Shutdown；
  -C ABI 基础。

---

## Phase 2：标准库适配

完成：

* Zig std 容器使用规范；
  -FileSystem；
  -Path；
  -MemoryFileSystem；
  -Native Process；
  -std.json Codec；
  -TestClock；
  -TestExecutor。

---

## Phase 3：第三方核心 Adapter

集成：

* libcurl；
  -yyjson；
  -zstd；
  -LZ4；
  -BLAKE3；
  -SQLite；
  -Tracy。

---

## Phase 4：工具与服务器 Adapter

集成：

* libuv；
  -mimalloc；
  -Mbed TLS，可选；
  -File Watch；
  -IPC；
  -Process Backend。

---

## Phase 5：平台优化

按性能数据增加：

* IOCP Backend；
  -io_uring Backend；
  -kqueue Backend；
  -Console Adapter；
  -平台 HTTP；
  -平台 TLS。

在此之前不主动自研原生异步 I/O Backend。

---

# 38. 自研边界

## 必须自行掌控

* Stable Handle；
  -SharedBuffer；
  -Cancellation；
  -Future/Operation 语义；
  -Executor 接口；
  -Error Mapping；
  -Shutdown；
  -C ABI；
  -FileSystem Facade；
  -HTTP Facade；
  -Logging/Metrics/Trace Facade；
  -JSON Schema 子集；
  -依赖治理；
  -测试设施。

## 优先复用

* 通用 Allocator；
  -基础容器；
  -线程与 Atomic；
  -HTTP；
  -TLS；
  -JSON DOM；
  -压缩算法；
  -Hash 算法；
  -SQLite；
  -Profiler；
  -Event Loop；
  -进程底层；
  -动态库底层；
  -密码学。

## 只有数据证明后才自研

* HTTP Client；
  -通用 Thread Pool；
  -原生异步 I/O；
  -JSON Parser；
  -通用数据库；
  -压缩算法；
  -Profiler；
  -TLS；
  -通用容器库。

---

# 39. 反模式

## 39.1 为“纯 Zig”重新实现成熟 C 库

纯 Zig 不是独立价值。

只有在以下条件下才值得替换：

* 第三方库无法支持目标平台；
  -许可证不合适；
  -依赖体积不可接受；
  -性能明确不足；
  -接口无法满足；
  -安全维护不可控。

---

## 39.2 把所有第三方库塞进 Core

Core 应保持极小。

HTTP、SQLite、Tracy、libuv 都应是可选 Adapter。

---

## 39.3 业务层直接调用第三方库

会造成：

* 锁死实现；
  -错误语义分裂；
  -升级困难；
  -测试困难；
  -跨平台困难。

---

## 39.4 为抽象而抽象

不创建没有实际替换价值的接口。

Facade 应统一真正需要统一的内容：

* 生命周期；
  -取消；
  -错误；
  -Buffer；
  -线程；
  -监控；
  -测试。

---

## 39.5 同时维护多个默认 Backend

每项能力只保留一个明确默认实现。

例如：

```text
HTTP 默认 curl
JSON 高频默认 yyjson
压缩默认 zstd/LZ4
Profiler 默认 Tracy
```

其他 Backend 只有明确场景才维护。

---

# 40. 架构决策记录

## ADR-F001：Foundation 是治理与适配层

不以重写所有底层实现为目标。

---

## ADR-F002：优先复用 Zig std

除非标准库缺失关键语义或稳定性不足。

---

## ADR-F003：HTTP 默认 libcurl

不自研生产级 HTTP/TLS 栈。

---

## ADR-F004：高频 JSON 默认 yyjson

配置和简单 Zig 数据使用 `std.json`。

---

## ADR-F005：压缩直接使用 zstd 和 LZ4

不自研压缩算法。

---

## ADR-F006：内容 Hash 使用 BLAKE3

HashMap 保留 Zig std 默认实现。

---

## ADR-F007：SQLite 作为可选 Adapter

不开发通用 ORM。

---

## ADR-F008：Tracy 负责性能 Timeline

业务 Trace 与 Replay 由上层实现。

---

## ADR-F009：Executor 只定义接口

生产调度复用引擎 Job System 或 libuv。

---

## ADR-F010：Cancellation 由 Foundation 统一

所有 Backend 适配到同一语义。

---

## ADR-F011：C ABI 与第三方 ABI 隔离

业务层不能暴露第三方结构。

---

## ADR-F012：依赖必须可审计、可替换

所有依赖版本和许可证必须进入清单。

---

# 41. 验收标准

Foundation Layer 第一阶段可认为完成，需要满足：

1. 业务模块不直接依赖 libcurl、SQLite、yyjson 等 API。
2. Foundation Core 不依赖网络、数据库和 Profiler。
3. 整个工程使用统一 Cancellation。
4. 整个工程使用统一 Error Mapping。
5. 跨模块 Buffer 生命周期清晰。
6. C ABI 不泄露 Zig 和第三方类型。
7. 游戏 Runtime 不会因 Foundation 隐式创建线程池。
8. HTTP 默认使用 libcurl。
9. JSON 高频路径可使用 yyjson。
10. zstd、LZ4、BLAKE3、SQLite 和 Tracy 通过 Adapter 接入。
11. 所有第三方依赖具有版本和许可证记录。
12. 测试可替换 Mock Backend。
13. 所有异步回调线程可预测。
14. Graceful Shutdown 有 Deadline。
15. Zig 版本升级主要由 Foundation 吸收。
16. 可按 Build Profile 完全裁剪 HTTP、SQLite、libuv 等模块。
17. Agent Runtime、Task Graph 和工具链可以共享同一套基础语义。
18. 未重新实现已有成熟通用库。

---

# 42. 最终建议

Foundation Layer 的建设重点不应是代码量，而应是边界和一致性。

最优先建设顺序：

```text
依赖治理
    ↓
Ownership 和 C ABI
    ↓
Handle 与 SharedBuffer
    ↓
Error 与 Cancellation
    ↓
Future 与 Executor
    ↓
FileSystem 与 HTTP Facade
    ↓
第三方 Adapter
    ↓
Logging / Metrics / Trace
    ↓
测试和故障注入
```

最终 Foundation 应具备以下特征：

* 小型 Core；
  -成熟实现优先；
  -清晰 Adapter；
  -统一生命周期；
  -统一取消；
  -统一错误；
  -统一跨 ABI 内存；
  -可替换；
  -可裁剪；
  -可审计；
  -可测试；
  -不绑定具体业务。

其核心价值不是“拥有自己的 HTTP、JSON、压缩和数据库”，而是：

> 让游戏 Runtime、Agent Runtime、Editor、工具链和服务器能够在不重复造轮子的前提下，使用一致、稳定、可控的基础设施。
