# 后台上传与备份 —— 实现记录

> **这份文件是给未来的维护者（包括未来的我）看的。**
> 记录的是「为什么这么做」和「踩过的坑」，不是 API 文档。
> 上游 `origin/main` @ `87ef89504` 出发的 fork 私有改动，共 23 文件 +862/−35。
> 分支 `bgsync4`。

---

## 目录

1. [一分钟概览](#一分钟概览)
2. [为什么必须换 Cronet](#为什么必须换-cronet)
3. [五个缺陷的完整成因](#五个缺陷的完整成因)
4. [实现细节与决策](#实现细节与决策)
5. [排查手册（症状 → 命令 → 判据）](#排查手册症状--命令--判据)
6. [验证数据](#验证数据)
7. [已知边界](#已知边界)
8. [回滚](#回滚)

---

## 一分钟概览

Android 端「后台备份」长期不工作。表象是切后台后通知不出现、一个字节都不传、
日志里没有任何报错。

根因是**五个独立缺陷叠在一起**，前一个的症状会遮住后一个：

| # | 缺陷 | 症状 | 一句话根因 |
|---|---|---|---|
| 1 | 大文件 OOM | 传 2GB 时进程涨到 3.4GB 被杀 | `cronet_http` 把 body 拷三份进内存 |
| 2 | 取消计成功 | 传 0 字节却报 `0 uploads failed` | `cancelled()` 不走 `onError` |
| 3 | 双备份互踩 | 进度条抽搐、1 分钟 11,629 条异常 | splash 与 resume 两条路径都起备份 |
| 4 | 退避累积 | 后台「永远不启动」 | 跳过时返回 `retry()`，WorkManager 当失败翻倍 |
| 5 | 同步无超时 | worker 卡 RUNNING 7 分钟无日志 | `_remoteSyncService.sync()` 没有 timeout |

另含一个新增功能：后台同步开关（默认关闭）。

---

## 为什么必须换 Cronet

目标链路：手机 → 杭州入口（`118.178.58.100:443`）→ 家宽回源。

该入口按 **TLS ClientHello 首包大小**过滤，不是按 SNI、不是按 ALPN：

| 首包大小 | 结果 |
|---|---|
| 1428 B | RST |
| 1437 B | 放行 |
| 1475 B | 放行 |

门槛在 **1440 B** 附近。

**TLS 1.2 的 ClientHello 天然只有 208–517 B，必被拒。** 这不是版本协商问题，
是物理尺寸不够——请求还没进到 TLS 层就被掐了。

要过这道门，握手包里必须带**后量子 key share**：

- `X25519MLKEM768`（group `0x11ec`）单独贡献约 **1180 B**
- 加上原有字段，首包能到 **1733 B**

两个客户端的实测对比：

| 客户端 | 实际发出的 key share | ClientHello | 结果 |
|---|---|---|---|
| OkHttp 4.12（系统 Conscrypt） | 只有 `x25519`（32 B） | **517 B** | RST |
| Cronet 143 | 含 `X25519MLKEM768` | **1733 B** | 通 |

同一个 APK 内的对照证据：缩略图走 Cronet 成功，API 走 OkHttp 失败。

> ⚠️ **这里最容易搞错**：不是「Cronet 更快所以换」，而是「换个客户端的
> ClientHello 才够大」。哪天上游或系统 Conscrypt 默认带后量子了，
> 这个改动就可以撤。判断依据是抓包看首包大小，不是看客户端名字。

---

## 五个缺陷的完整成因

### 缺陷 1：`cronet_http` 全量缓冲

源码 `cronet_client.dart`（1.8.0 与最新 1.10.1 相同）：

```dart
final stream = request.finalize();
final body = await stream.toBytes();        // ① 整个 body 进 Dart 堆
profile?.requestData.bodySink.add(body);    // ② 再拷一份给 profile
data = body.toJByteBuffer()                 // ③ 转 JNI ByteBuffer（第三份）
builder.setUploadDataProvider(
    jb.UploadDataProviders.create$2(data), ...)   // ④ Cronet 只接受 buffer
```

**三份拷贝，2 GB 视频需要约 6 GB 峰值。**

上游知道这个限制。源码里有一段注释：可以「逐步增大 body 直到复现
`OutOfMemoryError`」，并专门 catch 该异常转成 `ClientException`。

实测内存曲线（2 GB 视频）：

```
21:04:58.9  RSS 2,042 MB
21:04:59.1  RSS 2,250 MB    +208 MB / 0.2 s
21:04:59.3  RSS 2,769 MB    +519 MB / 0.2 s
21:05:13.6  RSS 3,360 MB    ← 峰值
21:05:34    上传失败，error 对象为 null
21:19:40    am_proc_died: pid=17473
```

**判据**：如果是这个缺陷，`logcat` 里 `HyperSentinel` 会打印 RSS 持续上涨，
且 `UploadResult.errorMessage` 常为 `null`（OOM 不是正常异常路径）。

### 缺陷 2：取消的上传被统计为成功

```dart
// foreground_upload.service.dart
callbacks: UploadCallbacks(onError: (_, _) => failed++)
```

但 `UploadResult.cancelled()` 走的是 `result.isCancelled` 分支，
**不触发 `onError`**。于是 `failed` 永远是 0：

```
21:05:48  Background backup finished, 0 uploads failed   ← 假的
```

worker 返回 `Result.success()`，WorkManager 认为完成，永不重试。

**判据**：日志同时出现 `was cancelled` 和 `0 uploads failed`。

### 缺陷 3：两条路径同时启动前台备份

两条独立入口，都是 `unawaited(...)`：

| 入口 | 文件 |
|---|---|
| 冷启动 | `splash_screen.page.dart:407` |
| 切回前台 | `app_life_cycle.provider.dart:173` |

而 `startForegroundBackup` 开头是「先杀后起」：

```dart
if (_cancelToken != null) {
  stopForegroundBackup(reason: "restarting the backup");   // 清空 uploadItems
}
```

后到的干掉先到的 token，但先到的 `uploadCandidates` 已经在跑了。
两个任务抢同一批 asset → 进度回调互相覆盖。

实测：

```
20:43:59  App resumed
20:44:01  Foreground backup cancelled: restarting the backup
20:44:01  ForegroundUploadService 启动（日志出现 2 次）
20:44:04  PlatformDispatcher - Catch all  ← 开始刷屏
20:44 这一分钟：11,629 条
```

**判据**：`immich_logs.sqlite` 里同一秒出现两次
`ForegroundUploadService Network capabilities`，或
`BackupNotifier: Foreground backup cancelled: restarting the backup`。

### 缺陷 4：跳过时返回 retry 累积退避

`BackgroundWorker.startWork()`：

```kotlin
if (BackgroundWorkerPreferences(ctx).isLocked() && BackgroundEngineLock.connectEngines > 0) {
  Log.i(TAG, "Foreground engine active, skipping background worker")
  return Futures.immediateFuture(Result.retry())
}
```

WorkManager 把每次 retry 当一次失败尝试，退避翻倍：
`30s → 1m → 2m → 4m → 8m …`

前台备份动辄几分钟，这期间被拒两三次，退避就涨到 4 分钟以上。
前台结束后后台还要再等 4 分钟 —— **看起来就像后台完全不会工作**。

现场抓到的 JobScheduler 状态：

```
JOB u0a625/157:
  Trace tag: BackgroundWorker
  Satisfied constraints:   BATTERY_NOT_LOW FLEXIBILITY DEVICE_NOT_DOZING
                           BACKGROUND_NOT_RESTRICTED WITHIN_QUOTA SSRU
  Unsatisfied constraints: TIMING_DELAY          ← 只剩退避
  Minimum latency: +3m59s968ms
  Backoff: policy=1 initial=+1m0s0s
```

`WorkSpec.run_attempt_count` 已累积到 6–7。

> ⚠️ **这里有个反直觉的点**：`dumpsys jobscheduler` 会显示
> `Restricted due to: frozen.`，看起来像 MIUI 冻结了任务。
> **但这是陈旧标记**——同一份 dumpsys 里 `Freezer settings` 写着
> `use_freezer=false`、`Apps frozen: 0`。别被它带偏。

**判据**：`Unsatisfied constraints` 只剩 `TIMING_DELAY`，
且 `run_attempt_count` 在涨。

### 缺陷 5：远程同步无超时

```dart
// background_worker.service.dart → _syncAssets()
final isSuccess = await _remoteSyncService.sync();   // 没有 timeout
```

请求一挂住，整个流程永远出不来：

```
18:01:01  Android background upload started
18:01:01  Device sync took - 2ms
18:01:01  SyncStreamService  Remote sync request for user
          ← 之后 7 分钟零日志
```

`dumpsys` 同时显示：worker 仍是 `RUNNING`、FGS 活着、21 个 socket 打开。

**没有报错，因为代码没抛异常，就是在死等。**

**判据**：日志停在 `Remote sync request for user`，
`WorkSpec.state = RUNNING`（1），且启动时间已过去数分钟。

---

## 实现细节与决策

### 后台开关（默认关闭）

| 层 | 文件 | 说明 |
|---|---|---|
| 配置 | `settings_key.dart` / `app_config.dart` / `backup_config.dart` | `backgroundSync` 三件套 |
| 文案 | `i18n/en.json` | `background_sync` / `background_sync_description` |
| UI | `backup_settings.dart` | `_BackgroundSyncSwitch` |
| 启停 | `main.dart` | 按开关决定 `enable()` / `disable()` |
| 立即触发 | `app_life_cycle.provider.dart` | `_performPause()` → `runNow()` |
| 桥接 | `pigeon/background_worker_api.dart` + `BackgroundWorkerApiImpl.kt` | `runNow()` → `enqueueBackgroundWorker` |

打开时：`configure()` → `enable()` → `runNow()`，切后台立刻触发一次。

### Cronet 引擎的两处取舍

**取舍一：`CacheMode.memory` 而非 disk**

两个 isolate（主引擎 + 后台 worker）共用同一个 `storagePath` 会报：

```
Disk cache storage path already in use
```

所以用内存缓存，`cacheMaxSize: 64 MB`。

**取舍二：两个引擎，无法合并**

`cronet_http` 的 `CronetEngine._` 是私有构造，只能 `build()` 新建。

- 缩略图/视频 → `HttpClientManager.cronetEngine`（原生侧，带 disk cache）
- API/上传 → `NetworkRepository` 自建（memory cache）

两套引擎各自持有连接池，这是已知代价。

### `_CronetAuthClient` 为什么必须存在

Cronet **不能**像 OkHttp 那样挂 interceptor 设 header。
`cronet_http` 只接受 `BaseRequest` 上已有的 header。

所以包一层 `http.BaseClient`，每次 `send()` 前：

```dart
final headers = await networkApi.requestAuthHeaders(request.url.toString());
headers.forEach((k, v) {
  if (!request.headers.containsKey(k)) request.headers[k] = v;
});
```

`requestAuthHeaders` 读的是原生侧持久化的 header（`immich.request_headers`）
+ cookie jar，含 Bearer token。这也是 `api.service.dart` 要多传 `token` 的原因。

### 原生流式上传的关键约束

`StreamingFileUploader.kt` 用 Cronet `UploadDataProvider` 直接从磁盘读。

**约束一：`getLength()` 必须精确**

```kotlin
override fun getLength(): Long = header.size + fileLength + footer.size
```

返回不准，Cronet 会改用 chunked encoding。
**该入口对 chunked 的容忍度未经验证** —— 所以 multipart 边界和字段段长度
必须全部在原生侧预先算好。

**约束二：buffer 是 direct，不能 `.array()`**

```kotlin
// ✗ buffer.array() → UnsupportedOperationException
// ✓ 读进 scratch 再 put
if (scratch.size < want) scratch = ByteArray(want)
stream.read(scratch, 0, want)
buffer.put(scratch, 0, read)
```

**约束三：`onReadSucceeded` 的 finalChunk 标志**

```kotlin
if (wrote == 0) {
  sink.onReadSucceeded(true)    // 结束
  return
}
sink.onReadSucceeded(false)     // 还有后续
```

**约束四：Cronet 不会自动跟随重定向**

必须显式实现 `onRedirectReceived` 并调 `request.followRedirect()`。

**约束五：进度与结果必须回主线程**

Cronet 在自己的线程调回调，Pigeon 的 channel 必须走平台线程：

```kotlin
android.os.Handler(android.os.Looper.getMainLooper()).post { ... }
```

不这么做编译能过，**运行时炸**。

### 阈值 16 MB 的理由

```dart
const int kStreamingUploadThreshold = 16 * 1024 * 1024;
```

- 小图（绝大多数）走 `cronet_http`，那是长期验证过的路径
- 只有大视频吃新代码，把回归面压到最小
- 原生路径失败会返回 `null`，调用方自动回退到 Dart 客户端（慢但不丢资产）

### 防并发的槽位必须在第一个 await 之前占好

```dart
final runGuard = Completer<void>();
_activeBackupUserId = userId;
_activeBackupRun = runGuard.future;     // ← 先占位

try {
  await getBackupStatus(userId);        // ← 这里有空窗期
  await _foregroundUploadService.uploadCandidates(...);
} finally {
  if (identical(_activeBackupRun, runGuard.future)) {
    _activeBackupRun = null;
    _activeBackupUserId = null;
  }
  if (!runGuard.isCompleted) runGuard.complete();
}
```

如果直接存 `final run = uploadCandidates(...)` 再赋值，
`getBackupStatus()` 那段 await 期间第二次调用仍会击穿守卫。

**并且** `stopForegroundBackup` 要清空槽位：

```dart
_activeBackupRun = null;
_activeBackupUserId = null;
```

否则暂停后立刻恢复，新调用会 join 到一个**已经取消**的 run，备份再也不启动。

### `handleHostResult` 里的 `retry()` 要保留

```kotlin
if (needsRetry && !tags.contains(BackgroundWorkerApiImpl.RETRY_TAG)) {
  BackgroundWorkerApiImpl.enqueueBackgroundWorkerWhenConnected(ctx)
  complete(Result.success())
} else {
  complete(if (needsRetry) Result.retry() else Result.success())
}
```

这里是**真正的上传失败**，不是「前台占用」。
配合缺陷 2 的修复（取消计入失败），`needsRetry` 才可靠。

**只改 `startWork()` 里那两处，不要动这里。**

---

## 排查手册（症状 → 命令 → 判据）

### 通用工具

```bash
# App 日志（必须连 -wal 一起拷，否则漏未 checkpoint 的记录）
D=/data/data/com.termux/files/usr/tmp/opencode/logprobe
su -c "cp /data/data/app.alextran.immich.pr999/app_flutter/immich_logs.sqlite* $D/"

# WorkManager 队列
su -c "cp /data/data/app.alextran.immich.pr999/no_backup/androidx.work.workdb* $D/"

# JobScheduler
su -c 'dumpsys jobscheduler' > js.txt
grep -A 30 "JOB androidx.work.systemjobscheduler:u0a625" js.txt

# 内存
su -c 'dumpsys meminfo app.alextran.immich.pr999 | grep "TOTAL PSS"'

# 前台服务
su -c 'dumpsys activity services app.alextran.immich.pr999 | grep -E "isForeground|startRequested"'
```

> ⚠️ **UID 是 `u0a625`，不是 `u0a10625`**。`grep u0a10625` 会漏掉全部结果。

> ⚠️ **`topResumedActivity` 在 MIUI 上经常抓不到**。
> 改用 `dumpsys window | grep mCurrentFocus`。

### 症状对照表

| 你看到的 | 大概率是 | 去看 |
|---|---|---|
| RSS 持续上涨到 GB 级 | 缺陷 1 | 是否走到 `StreamingFileUploader` |
| `0 uploads failed` + `was cancelled` | 缺陷 2 | `onCancelled` 是否被调用 |
| 进度条抽搐 / 1 分钟上万条异常 | 缺陷 3 | 是否出现 `joining it` |
| worker 一直 `ENQUEUED` | 缺陷 4 | `Unsatisfied constraints` 是否只剩 `TIMING_DELAY` |
| 日志停在 `Remote sync request` | 缺陷 5 | `WorkSpec.state == 1` |
| `Skipping upload ... requires WiFi` | **不是 bug** | 见下节 |

### 「Skipping upload because it requires WiFi」

这是 **Immich 的既有产品行为**，不是缺陷：

```dart
bool _shouldRequireWiFi(LocalAsset asset) {
  final backup = SettingsRepository.instance.appConfig.backup;
  if (asset.isVideo && backup.useCellularForVideos) return false;
  if (!asset.isVideo && backup.useCellularForPhotos) return false;
  return true;
}
```

上传条件：`hasWifi == true`，而 `hasWifi = networkCapabilities.isUnmetered`。

**踩过的坑**：手机连热点 + 开 Tailscale 时，Android 把默认网络判成计费：

```
Network capabilities: [vpn, wifi], hasWifi/isUnmetered: false
```

原因：默认网络是 Tailscale 的 VPN（`network{255}`），它不带 `NOT_METERED` 标记，
即使底层 WiFi（`network{262}`）有该标记。

解法：
1. 依次关闭 Tailscale（`am force-stop com.tailscale.ipn`）
2. App 内打开「使用蜂窝数据上传照片/视频」
3. 或换一个不计费的 WiFi

**设置项存在 `settings` 表**：`backupUseCellularForPhotos` / `backupUseCellularForVideos`。

> ⚠️ 直接改库要 **force-stop App 再重启**，因为 `SettingsRepository` 是
> `CachedKeyValueRepository`，后台 isolate 有自己的内存快照。

---

## 验证数据

环境：小米 Android（MIUI）、Immich 3.3.6、杭州入口 → 家宽回源。

### 内存（决定性）

| | RSS 峰值 | 结果 |
|---|---|---|
| 改前 | 3,360 MB | 进程被杀，上传失败 |
| 改后 | **178–210 MB** | **2 GB 视频上传成功**（远程 2171 → 2172）|

改后连续采样 2 分钟：`213,803 KB → 208,751 KB`，基本不变。

### 错误风暴

| | 每分钟 `PlatformDispatcher - Catch all` |
|---|---|
| 改前 | 11,629 |
| 改后 | **0** |

### 调度（缺陷 4 修复）

```
16:41:43.449  Starting work for BackgroundWorker
16:41:43.449  Foreground engine active, skipping background worker
16:41:43.467  Worker result SUCCESS          ← 不再是 RETRY
16:43:24.846  Starting background upload worker   ← 后续调度成功
```

### 并发（缺陷 3 修复）

```
18:01:00  Foreground backup for 018dd19e-... already running, joining it
```

### 前台服务

```
SystemForegroundService
  isForeground   = true
  foregroundId   = 100
  foregroundNoti = Notification(channel=immich::background_worker::notif ...)
  startRequested = true
```

> 通知本身是**上游既有实现**（`BackgroundWorker.showNotification()` /
> `BackupNotifier`），本次改动没有碰它。之前「通知不出现」是因为 worker
> 秒退，系统立刻 `Cancel FGS notification`。

### 吞吐（旁证，非本 PR 目标）

同一链路：杭州节点 **12.7–15.8 MB/s**（≈100–126 Mbps），
50 MB 文件 3.2–3.9 秒。对照 Cloudflare 仅 2.0 MB/s。

---

## 已知边界

1. **16 MB 阈值是经验值** —— 调 `kStreamingUploadThreshold` 即可改路径。

2. **两个 Cronet 引擎各自持有连接池** —— 见上文取舍二。

3. **原生上传依赖 platform channel 投递结果** —— 已加 30 分钟兜底超时，
   但 channel 完全失联时仍需等。

4. **MIUI 计费网络判定影响备份** —— 见排查手册，属产品既有行为。

5. **未覆盖**：上游停滞但连接不断（无内容产出）的看门狗、
   上游 500 的重试策略。这两项属于 `buddy-proxy`（另一套服务），不在本分支范围。

6. **上游 `CONTRIBUTING.md` 禁止 LLM 生成代码的 PR** ——
   本分支仅留在 fork，不向上游提交。

---

## 回滚

四个 commit 相互独立，可逐个 revert：

| commit | 内容 |
|---|---|
| `a102ac5a7` | 后台开关 + Cronet 换用 |
| `b34b6c4b6` | 流式上传 + 取消计数 + 防并发 |
| `34b03b82d` | 退避修复 |
| `eb5bcb755` | 远程同步超时 |

**只回滚网络层**：revert `a102ac5a7` 里 `network.repository.dart` 的部分 ——
但该入口会立刻恢复 ClientHello 被 RST 的状态，**上传全部失败**。

**只回滚流式上传**：把 `kStreamingUploadThreshold` 调到极大 ——
退回 `cronet_http`，大文件仍会 OOM。

---

## 改动文件清单

```
i18n/en.json                                             +2
android/.../background/BackgroundWorker.kt               +8
android/.../background/BackgroundWorkerApiImpl.kt        +4
android/.../core/HttpClientManager.kt                    +5
android/.../core/NetworkApiPlugin.kt                    +91
android/.../core/StreamingFileUploader.kt               +337   (新增)
mobile/lib/constants/constants.dart                      +5
mobile/lib/domain/models/config/app_config.dart          +2
mobile/lib/domain/models/config/backup_config.dart       +1
mobile/lib/domain/models/settings_key.dart               +1
mobile/lib/domain/services/background_worker.service.dart +29
mobile/lib/infrastructure/repositories/network.repository.dart +94
mobile/lib/main.dart                                    +11
mobile/lib/providers/app_life_cycle.provider.dart        +5
mobile/lib/providers/backup/backup.provider.dart        +79
mobile/lib/providers/infrastructure/platform.provider.dart +11
mobile/lib/repositories/upload.repository.dart         +117
mobile/lib/services/api.service.dart                     +3
mobile/lib/services/foreground_upload.service.dart      +15
mobile/lib/widgets/settings/backup_settings/backup_settings.dart +25
mobile/pigeon/background_worker_api.dart                 +2
mobile/pigeon/network_api.dart                          +49
mobile/pubspec.yaml                                      +1
```
