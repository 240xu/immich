# 后台上传与备份 —— 实现记录

> 上游 `origin/main` @ `87ef89504` 出发的 fork 私有改动。
> **规模：35 文件 +1978/−56**（含本文档）。
> 最后更新：2026-11-13，HEAD `24922317f`。

---

## 目录

- [一分钟概览](#一分钟概览)
- [为什么必须换 Cronet](#为什么必须换-cronet)
- [五个原始缺陷](#五个原始缺陷)
- [实现细节与决策](#实现细节与决策)
- [评审发现并修复的问题](#评审发现并修复的问题)
- [排查手册](#排查手册)
- [验证数据](#验证数据)
- [已知边界](#已知边界)
- [回滚](#回滚)
- [改动文件清单](#改动文件清单)

---

## 一分钟概览

这个 fork 只做两件事：

1. **加一个「后台同步上传」开关**，默认关
2. **网络层换成 Cronet**，为了支持后量子 TLS（`X25519MLKEM768`）

其他一律尊重官方：不改上传协议、不改服务端、不重构批量/超时/取消逻辑。

| 组件 | 说明 |
|---|---|
| 开关 | `backup.backgroundSync`，默认 `false`。Android 侧镜像进 `BackgroundWorkerPreferences.syncEnabled`，iOS 侧在 Dart 入口强制 |
| 网络层 | Android 走 Cronet（mTLS 用户除外），iOS 仍走 URLSession |
| 大文件 | Android 且 >16 MB 走原生流式上传器（`StreamingFileUploader.kt`） |
| mTLS | 检测到客户端证书时整个网络层退回 OkHttp（Cronet 不支持客户端证书） |

---

## 为什么必须换 Cronet

`package:cronet_http` 在把请求体交给原生层之前会：

```dart
await stream.toBytes()   // cronet_client.dart
```

也就是**把整个文件读进内存**。实测 2 GB 视频会让进程涨到 3.4 GB 然后被杀。

这不是 bug，是该包当前的设计。所以在换 Cronet 的同时，必须为 >16 MB 的文件提供一条不走 Dart 客户端的路径 —— 这就是 `StreamingFileUploader.kt` 存在的原因。它用 `UploadDataProvider` 从磁盘流式读，峰值内存约 1 MB。

---

## 五个原始缺陷

> 这五个是调试期间发现的官方/本分支问题。**注意：缺陷 4 的修复方式已在后续评审中改回官方行为**，详见下方标注。

### 缺陷 1：`cronet_http` 全量缓冲

见上一节。修复：原生流式上传器 + 16 MB 阈值分流。

### 缺陷 2：取消的上传被统计为成功

原逻辑里 `UploadResult.cancelled()` 不计入 `failed`，于是整批备份报「0 uploads failed」，worker 返回 success，剩下的资产被静默丢弃。

修复：`UploadCallbacks` 新增 `onCancelled` 回调，独立计数。

**后续修正**：取消**不**计入 `failed`（否则会触发「取消→重试→再取消」循环）。现在的语义是：

```dart
if (cancelled > 0 && failed == 0) {
  return false;   // 取消不是重试的理由
}
return failed > 0;
```

### 缺陷 3：两条路径同时启动前台备份

`startForegroundBackup` 没有并发保护，splash 恢复和 resume 可能在同一毫秒内都调进来，导致：

- 第二次调用取消第一次的 token
- 然后立刻起一个新 run
- 进度条来回跳

修复：`_activeBackupRun` 槽位在**第一个 `await` 之前**占好，后来的调用 join 已有的 run。

**后续修正**：join 会吞掉用户的显式操作（备份中途拍了新照片，点「立即备份」不会有反应）。现在用户主动触发的三处传 `restart: true`，走官方的「取消并重开」：

| 调用点 | 传参 |
|---|---|
| `backup.page.dart:104`（备份页按钮） | `restart: true` |
| `backup_album_selection.page.dart:132` | `restart: true` |
| `backup_options.page.dart:63` | `restart: true` |
| `splash_screen.page.dart:407`（自动） | 默认 join |
| `app_life_cycle.provider.dart:173`（自动） | 默认 join |

### 缺陷 4：跳过时返回 `retry()` 累积退避

> ⚠️ **这一节描述的现象是真的，但修复方式已经变了。当前代码返回 `success()`，不是 `retry()`。**

`BackgroundWorker.startWork()` 在前台引擎正在备份时会跳过自己。早期版本返回 `Result.retry()`：

```kotlin
// 旧版本（已不存在）
if (BackgroundWorkerPreferences(ctx).isLocked() && BackgroundEngineLock.connectEngines > 0) {
  return Futures.immediateFuture(Result.retry())
}
```

WorkManager 把每次 retry 当一次失败尝试，退避翻倍：`30s → 1m → 2m → 4m → 8m …`。前台备份动辄几分钟，这期间被拒两三次，退避就涨到 4 分钟以上。前台结束后后台还要再等 4 分钟 —— **看起来就像后台完全不会工作**。

现场抓到的 JobScheduler 状态：

```
JOB u0a625/157:
  Trace tag: BackgroundWorker
  Satisfied constraints:   BATTERY_NOT_LOW FLEXIBILITY DEVICE_NOT_DOZING
                           BACKGROUND_NOT_RESTRICTED WITHIN_QUOTA SSRU
  Unsatisfied constraints: TIMING_DELAY          ← 只剩退避
  Minimum latency: +3m59s968ms
  Backoff: policy=1 initial=+1m+0s
```

`WorkSpec.run_attempt_count` 已累积到 6–7。

**现在的代码**（`BackgroundWorker.kt`）：

```kotlin
if (BackgroundWorkerPreferences(ctx).isLocked() && BackgroundEngineLock.connectEngines > 0) {
  Log.i(TAG, "Foreground engine active, skipping background worker")
  activeWorker.compareAndSet(this, null)
  return Futures.immediateFuture(Result.success())   // ← success，不是 retry
}
```

**判据**：`Unsatisfied constraints` 只剩 `TIMING_DELAY`，且 `run_attempt_count` 在涨。

> ⚠️ **这里有个反直觉的点**：`dumpsys jobscheduler` 会显示
> `Restricted due to: frozen.`，看起来像 MIUI 冻结了任务。
> **但这是陈旧标记**——同一份 dumpsys 里 `Freezer settings` 写着
> `use_freezer=false`、`Apps frozen: 0`。别被它带偏。

### 缺陷 5：远程同步无超时

`_remoteSyncService.sync()` 原本没有超时，一个卡住的请求会让 worker 无限期 RUNNING，没有日志也没有上传。

修复：`remoteSyncTimeout = Duration(minutes: 2)`。

> ⚠️ **这是已知的争议点**：官方整个 run 的预算是 19 分钟，2 分钟的 sync 超时对大库/慢链路的首次全量同步偏紧。超时后 `_backgroundLoop` 会跳过本轮备份并返回 `true`（不重试），日志只有一行 warning。见[已知边界](#已知边界)。

---

## 实现细节与决策

### 后台开关（默认关闭）

| 位置 | 作用 |
|---|---|
| `backup_config.dart` | `@Default(false) bool backgroundSync` |
| `settings_key.dart` | `SettingsKey.backgroundSync` |
| `backup_settings.dart` | 设置页开关。开：`configure + enable + runNow`；关：`disable` |
| `main.dart:251` | 启动时按开关决定 `enable()` 还是 `disable()`（官方是无条件 `enable()`） |
| `app_life_cycle.provider.dart:226` | 切后台时开关开才 `runNow()` |

**native 侧镜像**（`BackgroundWorkerPreferences.syncEnabled`）：

`enable()` 写 `true`，`disable()` 写 `false`。所有入队路径都检查它：

- `configure()` — 开关关时只写 settings，不重排 worker
- `enqueueBackgroundWorker()` — 直接 return
- `enqueueBackgroundWorkerWhenConnected()` — 直接 return
- `BackgroundWorker.startWork()` — 直接 return success

**Dart 侧兜底**（`background_worker.service.dart`）：

```dart
bool get _isBackgroundSyncEnabled =>
    SettingsRepository.instance.appConfig.backup.backgroundSync;
```

在 `onAndroidUpload()` 和 `onIosUpload()` 两个入口强制检查。**iOS 必须靠这一层**——Swift 侧的后台调度器会自己续命（`handleBackgroundRefresh` 里再调 `scheduleRefreshWorker`），完全不看 Dart 状态。

### Cronet 引擎的两处取舍

**1. `CacheMode.memory` 而非 disk**

两个 isolate 会各自建一个 Cronet 引擎，disk 模式下会撞同一个 `storagePath`。用内存缓存（64 MB）规避。

**2. 每个 isolate 一个引擎**

官方 OkHttp 通过 JNI global ref 全 isolate 共享。Cronet 做不到（`cronet_http` 没有暴露跨 isolate 的句柄），所以每个 isolate 各建一个。

代价：isolate 拆除时必须显式 `dispose()`，否则 native 线程和 64 MB 缓存会累积。已在两处调用：

- `isolate.dart:62`（`runInIsolateGentle` 的 finally）
- `background_worker.service.dart`（`_handleCleanup` 末尾）

### `_CronetAuthClient` 为什么必须存在

Cronet 不能像 OkHttp 那样挂 interceptor，所以请求头得手动注入：

```dart
final headers = await networkApi.requestAuthHeaders(request.url.toString());
headers.forEach((k, v) => request.headers[k] = v);
```

`requestAuthHeaders` 在 Kotlin 侧调 `HttpClientManager.getAuthHeaders(url)`，返回：

- 用户自定义 header（`network.customHeaders`）
- 从 `PersistentCookieJar` 按 RFC 6265 匹配出的 cookie
- URL 内嵌的 Basic 凭证

> **注意**：这里**无条件覆盖**请求头（不是「只在缺失时填」），与官方 OkHttp 拦截器的 `builder.header(key, value)` 一致 —— 用户配置的 header 必须赢。

**登出时**：Cronet 引擎的 cookie store 没有清除 API，所以 `clearCookies()` 会销毁并重建引擎。但**延迟 30 秒**关闭旧引擎——`CronetEngine.shutdown()` 会取消该引擎上所有在途请求，而登出时 UI 还在拉数据，那些 abort 会被上传路径误判成「用户取消」。

### 原生流式上传的关键约束

**协议必须与官方 `MultipartRequest` 等价**。已核对：

| 项 | 官方 | 本实现 | 结论 |
|---|---|---|---|
| boundary | `dart-http-boundary-` + 62 字符 | `----ImmichUpload` + 32 位 UUID | 都合法 |
| 文件名转义 | `"` → `%22`，`\r\n` → `%0D%0A`，**不转义 `%`** | 同 | 逐字节相同 |
| 字段 charset | 非 ASCII 时加 `content-type: text/plain; charset=utf-8` + `content-transfer-encoding: binary` | 同（已补） | 等价 |
| footer | `\r\n--boundary--\r\n` | 同 | 等价 |
| `Content-Length` | — | `header + file + footer` | 逐字节验证一致 |
| part `Content-Type` | `application/octet-stream` | 按扩展名猜 | **差异**（服务端不读，无影响） |

**重定向**：只跟随 307/308（保证方法和 body 存活）。301/302/303 会拒绝并给出明确错误——官方 `package:http` 会跟随但转成 GET 丢 body，最终同样失败，本实现只是更早、更清楚地报错。

**重试**：官方在 `ClientException` 时重发一次。本实现只在 `statusCode == 0 && bytesSent == 0` 时重试——**半截 body 后重发会产生重复资产**。`bytesSent` 由原生侧从 `maxReported` 回传（不是 `bytesSent`，因为 `rewind()` 会归零）。

### 阈值 16 MB 的理由

三个约束的交点：

- 16 MB 的 `toBytes()` 三份拷贝 ≈ 48 MB，加上 3 并发 ≈ 144 MB，低端机能扛
- 视频是这个 App 的主要负载，1080p 一分钟约 100–200 MB
- 太小会让原生路径承担过多小文件（多一次 Pigeon 往返）

### 防并发的槽位必须在第一个 `await` 之前占好

```dart
Future<void> startForegroundBackup(String userId, {bool restart = false}) async {
  final activeRun = _activeBackupRun;
  if (!restart && activeRun != null && _activeBackupUserId == userId) {
    return activeRun;          // join
  }
  // ...
  _activeBackupRun = runGuard.future;   // ← 在第一个 await 之前
  try {
    await getBackupStatus(userId);
    // ...
```

如果槽位在 `await` 之后才占，两个调用都会看到 `null` 然后各起一个 run。

### `handleHostResult` 里的 `retry()` 要保留

`BackgroundWorker.kt:220`：

```kotlin
complete(if (needsRetry) Result.retry() else Result.success())
```

这里的 `retry()` 是**必要的**——它对应「有上传失败」这个真实失败，需要 WorkManager 重试。与缺陷 4 那个「跳过也 retry」不同。

---

## 评审发现并修复的问题

> 2026-11-13 做了四轮专项评审（跨语言契约 / 并发竞态 / 原生上传器协议 / 官方语义偏移），共 28 项修复。这里只列会**影响用户**的。

### 编译阻断

| 问题 | 后果 |
|---|---|
| Pigeon 新增 5 个 HostApi + `runNow()` 但 Swift 侧零实现 | **iOS 编不过** |
| `StreamingUploadProgressApi` 未 import | Android 编不过（已修） |

### 功能失效

| 问题 | 后果 |
|---|---|
| **iOS 开关完全无效** | 开关关着，iOS 照样每 5–15 分钟后台同步+上传 |
| mTLS 用户的大文件上传绕过 OkHttp 分支 | 握手失败，「小图能传、大视频传不上」 |
| 开关可被绕过（`ImmichApp` 15s 定时器 + `configure()`） | 开关关着，后台任务照样被拉起 |
| 证书导入后需重启才生效 | 注释声称立即生效，实现没有 |

### 数据正确性

| 问题 | 后果 |
|---|---|
| 重试判定依赖可选的 `onProgress` 回调 | 不订阅进度的调用方 `bytesSent` 恒 0 → 传了 200 MB 后断线被误判成零字节 → 重发 → **服务端两条 asset** |
| 流式路径把整个 JSON body 当 errorMessage | `"Quota has been exceeded!"` 匹配不上 → 配额超限后继续逐个撞墙 |
| `_syncAssets` 同步失败后跳过 `hashAssets()` | 官方是失败也哈希；跳过会让新资产拿不到 checksum，后续轮次也传不了 |

### 稳定性

| 问题 | 后果 |
|---|---|
| 登出时立即 shutdown 引擎 | 掐断在途请求 → `RequestAbortedException` → 被上传路径当成「用户取消」 |
| Pigeon 回调到已销毁的 engine | 主线程抛异常 → **进程崩溃** |
| 取消计入失败 | 「取消 → 重试 → 再取消」循环，耗电耗流量 |
| 每个 isolate 的 Cronet 引擎从不关闭 | native 线程 + 64 MB 缓存累积 |
| 响应体无上限 | 反代返回大错误页 → OOM |
| 后台 worker isolate 无进度 handler | 每个 tick 一条错误日志（2 GB 文件约 2000 条） |

---

## 排查手册

### 通用工具

```bash
# App 日志（必须连 -wal 一起拷，否则漏未 checkpoint 的记录）
adb shell "run-as app.alextran.immich.pr999 cat databases/immich_logs.sqlite" > logs.db
adb shell "run-as app.alextran.immich.pr999 cat databases/immich_logs.sqlite-wal" > logs.db-wal

# WorkManager 队列
adb shell dumpsys jobscheduler | grep -A 20 "app.alextran.immich"

# 内存
adb shell dumpsys meminfo app.alextran.immich.pr999

# 前台服务
adb shell dumpsys activity services app.alextran.immich.pr999
```

### 症状对照表

| 症状 | 先查 | 判据 |
|---|---|---|
| 后台完全不工作 | `dumpsys jobscheduler` | `Unsatisfied constraints` 是否只剩 `TIMING_DELAY`；`run_attempt_count` 是否在涨 |
| 大文件传不上去 | logcat 找 `Streaming upload` | 是否 `Native streaming upload failed`；文件是否 >16 MB |
| 上传卡在 99% | logcat 找 `progressKey` | 进度 tick 是否还在来 |
| 传完但服务端没有 | 服务端 `/api/search/metadata` | **必须用 `Authorization: Bearer <token>`**，不是 `x-api-key` |
| 登出后又自动登录 | 查 `clearCookies` 是否被调用 | Cronet 引擎是否重建 |
| 企业证书用户连不上 | 查 `NetworkRepository.usingMtls` | 应为 `true`，走 OkHttp |

### 「Skipping upload because it requires WiFi」

这条日志意味着 `_shouldRequireWiFi(asset)` 返回 true 但 `hasWifi == false`。

**注意 Android 的判定陷阱**：`ConnectivityManager` 会把某些 Wi-Fi 标记为 `Metered hint: true`（例如手机热点），此时 `hasWifi` 为 false 但 `isUnmetered` 也为 false。如果 `backupUseCellularForVideos == true`，上传仍会继续——不要只看 `hasWifi`。

---

## 验证数据

### 内存（决定性）

| 场景 | 峰值 |
|---|---|
| 2 GB 视频走 `cronet_http` | 3.4 GB → 被系统杀 |
| 2 GB 视频走原生流式 | ~1 MB/并发（`ByteBuffer.allocateDirect(256KB)` × 2） |
| <16 MB 文件走 `cronet_http` | 3 × 文件大小 × 并发数（3 并发 16 MB ≈ 144 MB） |

### 大文件完整性

| 项 | 值 |
|---|---|
| 样本 | `VID_20261020_103339_DOLBY.mp4`，150,349,338 bytes（143.4 MiB） |
| 服务端 `exifInfo.fileSizeInByte` | 150,349,338 |
| 本地 SHA-1 | `3596671b5c4247f5e560daa8a5f3de4cea667fec` |
| 服务端 `checksum` | `NZZnG1xCR/XlYNqopfPeTOpmf+w=` |
| 换算校验 | base64(SHA-1 bytes) 完全一致 ✅ |

> **注意**：Immich 的 `checksum` 字段是 **SHA-1**（20 字节），不是 SHA-256。用 SHA-256 比对会得出错误结论。

### 错误风暴

修复前：后台大文件上传时每个 1 MB 进度 tick 产生一条 Pigeon 错误日志（无 handler），2 GB 文件约 2000 条。
修复后：`backgroundSyncNativeEntrypoint` 里注册了 handler，不再产生。

### 吞吐（旁证，非本 PR 目标）

50 MB 文件 3.2–3.9 秒。

---

## 已知边界

### 未验证

| 项 | 为什么 |
|---|---|
| **iOS 能否编译** | CI 只编 Android；本机无 Xcode。Swift 侧仅人工核对 Pigeon 接口 13/13 + 6/6 |
| **mTLS 回退是否真的工作** | 无客户端证书测试环境 |
| **Cronet 是否遵循 `network_security_config` 的 user trust anchors** | 需真机装用户 CA + 私有证书服务器 |
| **慢链路 idle 超时** | `lastProgressAtNanos` 只在 `read()` 更新；Cronet 因 TCP 背压不调 `read()` 时可能误判 stall。需限速环境验证 |
| **`cronet_http` 与 `cronet-embedded` 是否 duplicate class** | 构建能过说明不冲突（间接证据） |

### 已知缺陷（未修，有理由）

| 项 | 影响 | 为什么不修 |
|---|---|---|
| 双 Cronet 引擎各一份 cookie store | Kotlin 引擎的 cookie 无 API 可清 | 实际概率低：native 路径都显式注入 `getAuthHeaders()`，不依赖引擎 store |
| `useBuiltInDnsResolver` 未设 false | 局域网主机名（`immich.local`）可能解析失败 | 该参数只在 `cronet_http` ≥1.10 存在；1.9+ 强制 `jni` 0.15.2→1.x，与 fork 的 `ok_http`/`cupertino_http` 有兼容风险 |
| 跨源重定向不剥 `Authorization`/`Cookie` | 跨域跳转时 token 会跟着走 | Immich 部署常依赖反代 http→https 301，关掉自动跟随风险更高 |
| 流式路径不支持 301/302 | 服务器 URL 是 http 时会明确报错 | 官方跟随但同样失败（转 GET 丢 body），本实现只是更早报错 |
| WebSocket 仍在 OkHttp | 后量子 TLS 不覆盖实时同步通道 | 非本次授权范围 |
| `shouldAbortUpload` 是 service 单例状态 | run2 重置会让 run1 继续上传 | 修复需重构 worker pool 传 run token |
| `getCronetStoragePath` 是死 API | 无功能影响 | 删除要同步改 Pigeon + Kotlin + Swift 三端 |
| 2 分钟 sync 超时对首次全量同步偏紧 | 超时后跳过本轮且不重试，只有一行 warning | 官方无此超时；需按 `backupTimeout` 同源或提高阈值 |

### 开关关闭时仍生效的行为

| 行为 | 说明 |
|---|---|
| >16 MB 走原生流式路径 | 含手动上传、相册上传、分享意图。**用户无法关闭** |
| API 请求走 Cronet | 属第 2 项授权，与开关无关 |
| `updateHeaders()` 带 token 写 cookie | Cronet 必需 |
| 每请求一次同步 Pigeon 调用 | `requestAuthHeaders` 的开销，未量化 |
| 后台 sync 2 分钟超时 | 官方无 |

### 测试覆盖

**零。** `git diff origin/main -- mobile/test` 为空。

现有 `upload_repository_test.dart` 的测试文件只有 7 字节，永远碰不到 16 MB 阈值；`httpClient` 参数被流式路径绕过。

无自动化保护的逻辑：16 MB 分流、mTLS 回退、取消语义、流式重试边界、`_extractErrorMessage` 一致性、`clearCookies()` 后 client 身份保持。

---

## 回滚

| 目标 | 操作 |
|---|---|
| 只关后台同步 | 设置页关掉开关（不改代码） |
| 回退网络层 | `network.repository.dart` 的 `init()` 删掉 Cronet 分支，恢复 `OkHttpClient.fromJniGlobalRef` |
| 回退大文件分流 | `upload.repository.dart:258` 的分支删掉（代价：大文件 OOM 回归） |
| 完全回退 | `git reset --hard 87ef89504` |

---

## 改动文件清单

```
BG_SYNC_IMPLEMENTATION.md                                               +482  -0   (本文档)
i18n/en.json                                                            +2    -0
mobile/android/.../background/BackgroundWorker.kt                       +17   -0
mobile/android/.../background/BackgroundWorkerApiImpl.kt                +26   -0
mobile/android/.../background/BackgroundWorkerPreferences.kt            +20   -0
mobile/android/.../core/HttpClientManager.kt                            +5    -0
mobile/android/.../core/NetworkApiPlugin.kt                             +126  -2
mobile/android/.../core/StreamingFileUploader.kt                        +549  -0   (新增)
mobile/ios/Runner/Background/BackgroundWorkerApiImpl.swift              +12   -0
mobile/ios/Runner/Core/NetworkApiImpl.swift                             +63   -0
mobile/lib/constants/constants.dart                                     +5    -0
mobile/lib/domain/models/config/app_config.dart                         +2    -0
mobile/lib/domain/models/config/backup_config.dart                      +1    -0
mobile/lib/domain/models/settings_key.dart                              +1    -0
mobile/lib/domain/services/background_worker.service.dart               +90   -4
mobile/lib/domain/services/sync_stream.service.dart                     +22   -3
mobile/lib/infrastructure/repositories/network.repository.dart          +146  -4
mobile/lib/main.dart                                                    +10   -1
mobile/lib/pages/backup/backup.page.dart                                +8    -1
mobile/lib/pages/backup/backup_album_selection.page.dart                +1    -1
mobile/lib/pages/backup/backup_options.page.dart                        +1    -1
mobile/lib/providers/app_life_cycle.provider.dart                       +5    -0
mobile/lib/providers/backup/backup.provider.dart                        +140  -26
mobile/lib/providers/infrastructure/platform.provider.dart              +11   -0
mobile/lib/repositories/upload.repository.dart                          +213  -0
mobile/lib/services/api.service.dart                                    +2    -1
mobile/lib/services/auth.service.dart                                   +5    -1
mobile/lib/services/foreground_upload.service.dart                      +29   -1
mobile/lib/utils/isolate.dart                                           +4    -0
mobile/lib/widgets/settings/backup_settings/backup_settings.dart        +25   -0
mobile/lib/widgets/settings/ssl_client_cert_settings.dart               +8    -0
mobile/pigeon/background_worker_api.dart                                +2    -0
mobile/pigeon/network_api.dart                                          +58   -0
mobile/pubspec.lock                                                     +8    -0
mobile/pubspec.yaml                                                     +1    -0
```

**新增文件只有 2 个**：`StreamingFileUploader.kt` 和本文档。其余全是修改官方文件。
