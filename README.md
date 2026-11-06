# RemoveJobNotVpn

一个极简、零副作用的 Xposed / LSPosed 模块，用于移除应用向 Android 系统 `JobScheduler` 提交后台任务时附带的 `NET_CAPABILITY_NOT_VPN` 网络限制。

## 背景与解决的问题

在 Android 系统中，部分应用（典型如 **Gmail (`com.google.android.gm`)** 内置的 Google Notifications Platform `GnpSdk` / `#GnpWorker#`）在通过 `WorkManager` / `JobScheduler` 调度后台同步或推送注册任务时，构造的自定义 `NetworkRequest` 会默认包含 `NET_CAPABILITY_NOT_VPN`（要求当前网络不能是 VPN）：

```text
Trace tag: GnpWorker
Network type: NetworkRequest [ NONE id=0, [ Capabilities: INTERNET&NOT_RESTRICTED&TRUSTED&NOT_VPN&VALIDATED... ] ]
Unsatisfied constraints: CONNECTIVITY [0x10000000]
```

当用户在需要代理的网络环境下常年开启基于 `VpnService` 的代理工具（如 `v2rayNG`、Clash for Android 等）并将 Gmail 纳入分应用代理时，会产生经典的**死锁现象**：
1. **开启 VPN 时**：系统 `ConnectivityController` 判定当前网络带有 `TRANSPORT_VPN` 且不具备 `NOT_VPN` 能力，导致 `#GnpWorker#` 永远处于 `Unsatisfied constraints: CONNECTIVITY` 挂起状态，无法执行。
2. **关闭 VPN 时**：虽然满足了 `NOT_VPN` 条件，但直连网络无法访问 Google 服务器，导致请求超时失败。
3. **最终表现**：Gmail 启动时报错 `ChimeNotificationManagerImpl: GNP registration failure: RTID not found for the provided account`，无法向云端注册获取推送目标 ID（`RTID`），从而导致新邮件无法通过 FCM 实时推送、打开应用也无法自动刷新。

## 工作原理

本模块仅精准拦截 `android.app.job.JobInfo$Builder.setRequiredNetwork(android.net.NetworkRequest)` 方法：
- 当检测到目标应用提交给 `JobScheduler` 的 `NetworkRequest` 包含 `NET_CAPABILITY_NOT_VPN`（常量值 `15`）时：
  1. 优先调用 Android 12+ 公开 API `new NetworkRequest.Builder(originalRequest).removeCapability(NET_CAPABILITY_NOT_VPN).build()` 重建不含 `NOT_VPN` 限制的请求并替换原参数。
  2. 若公开构造器不可用，则自动回退至反射调用 `NetworkCapabilities.removeCapability(15)`。
- **安全无副作用**：只作用于 `JobInfo.Builder`，不篡改全局网络状态，不影响应用在前台正常的网络请求与 VPN 状态判断。

## 使用方法

1. 安装本模块 APK。
2. 打开 **LSPosed 管理器** -> **模块** -> 启用 **RemoveJobNotVpn**。
3. 勾选作用域（默认推荐）：
   - **Gmail** (`com.google.android.gm`)
   - **Google Play 服务** (`com.google.android.gms`)
   - 其他因挂 VPN 导致 `JobScheduler` 后台任务卡在 `NOT_VPN` 的应用。
4. 强行停止并重新打开目标应用（如 Gmail）。

## 验证方法

在电脑端通过 `adb shell` 查看当前系统中是否存在仍带有 `NOT_VPN` 限制的 Job：

```bash
dumpsys jobscheduler | grep "NetworkRequest" | grep "NOT_VPN"
```

启用本模块并重启 Gmail 后，再查看 Gmail（如 `UID 10353`）的 `JobScheduler` 网络要求：

```bash
dumpsys jobscheduler | grep -B 10 -A 6 "u0a353/555"
```

可以看到 `#GnpWorker#` 的 `NetworkRequest` 中已不再包含 `NOT_VPN`，且任务能够通过 VPN 正常执行并获取 `RTID`。

## 附：直接通过 ADB 命令恢复 Gmail 推送（免安装模块 / 应急触发）

如果你暂时不想安装模块，或者想在开启 VPN（代理）的状态下**立即触发 Gmail 向 Google 服务器注册 `RTID` 并恢复实时推送**，可以直接通过 `adb shell` 强制运行 Gmail 被挂起的 `JobScheduler` 任务（`-f` 参数表示强制忽略 `NOT_VPN` 等未满足的约束条件）：

### 1. 查询并执行单条命令

Gmail 内置的 `WorkManager` 任务 ID 固定以 **`555000`** 开头（从 `555000000` 起自增，不同手机或不同安装周期末尾数字会有所差异，例如 `555000026`）：

```bash
# 第一步：查询当前手机上 Gmail 挂起的 GnpWorker 任务 ID
adb shell "dumpsys jobscheduler | grep -B 4 'GnpWorker'"

# 输出示例（其中 555000026 即为当前手机上的 Job ID）：
#   JOB #u0a353/555000026: 9d0a1b2 com.google.android.gm/androidx.work.impl.background.systemjob.SystemJobService
#     u0a353 tag=*job*/com.google.android.gm/androidx.work.systemjobscheduler#GnpWorker#

# 第二步：强制执行该 Job（将末尾的 555000026 替换为你实际查出的 ID）
adb shell "cmd jobscheduler run -f -n androidx.work.systemjobscheduler com.google.android.gm 555000026"
```

### 2. 跨手机通用的全自动一行命令（推荐）

无需手动查询 ID，下面这条命令会自动提取当前手机上 Gmail 所有 `555` 开头的 `WorkManager` 任务并全部强制执行一次：

```bash
adb shell "for id in $(dumpsys jobscheduler | grep -oE 'u0a[0-9]+/555[0-9]+' | cut -d/ -f2 | sort -u); do echo Running Job $id; cmd jobscheduler run -f -n androidx.work.systemjobscheduler com.google.android.gm $id; done"
```

> **关于通用性与持久性的说明**：
> - **是否所有手机通用**：`cmd jobscheduler run -f -n androidx.work.systemjobscheduler com.google.android.gm <JobID>` 在所有 Android 11+ 手机上均通用；如果设备的 `WorkManager` 未启用命名空间（部分旧版本系统），去掉 `-n androidx.work.systemjobscheduler` 即可：
>   `cmd jobscheduler run -f com.google.android.gm <JobID>`
> - **效果持久性**：只要在挂着代理的状态下通过上述命令成功跑通一次 `#GnpWorker#`，Gmail 就会将获取到的 `RTID` 持久化保存在本地数据库中，此后很长一段时间内 FCM 实时邮件推送都会恢复正常。但当 Gmail 清除数据、重装升级或定期轮换注册 Token 时，仍会重新创建带 `NOT_VPN` 的后台任务，因此长期使用建议配合本 LSPosed 模块一劳永逸地移除 `NOT_VPN` 限制。

## 编译构建

### 方式一：使用 PowerShell 快速构建脚本（无需下载完整 Gradle）

确保已配置 `ANDROID_HOME` 和 `JAVA_HOME` 环境变量，在项目根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\build_apk.ps1
```

编译并签名完成的安装包将直接输出至项目根目录下的 `RemoveJobNotVpn.apk`。

### 方式二：使用 Gradle 构建

使用 Android Studio 打开本项目，或通过 Gradle 执行：

```bash
gradle assembleRelease
```
