# ProcessGuardian

iOS 15–17.3 RootHide 隐根插件：在设置中管理进程的 nice 与 Jetsam 优先级、前后台内存上限和前后台 CPU 阈值。默认总开关关闭，初次安装的进程列表为空。此分支已移除后台保活、自动重拉和注销后拉起功能。

## 组件

- `ProcessGuardianPrefs.bundle`：设置中的进程列表与单项编辑页，可从候选列表选择应用或系统进程。
- `processguardiand`：root LaunchDaemon，应用内存、优先级和 CPU 设置。CPU 限制仅使用 XNU fatal CPU monitor，支持 2～100% 阈值；同一配置对前台和后台均生效。接口不可用或设置失败时记录错误，旧的每秒 CPU 采样、连续超限累计和 `SIGKILL` 回退已删除。
- `ProcessGuardian.dylib`：SpringBoard 前台切换与应用启动探针，仅通知服务检查配置；切换前台不会撤销后台进程的 CPU 限额。

显式内存上限始终为 fatal 限额。100% 约等于单个核心满载。CPU 检测按内核时间窗口判定，窗口默认 10 秒，支持 1～3600 秒；前后台进程达到内核超限条件均可被结束。挂起、不消耗 CPU 的进程不会因空等窗口时长而被杀。旧配置超过 100% 时不会启用 CPU 检测，需要改为支持的阈值。总开关关闭、CPU 配置关闭或移除记录时停用本插件持有的监控；XNU 的 fatal 标志在进程存活期间不能清除，需真机验证与系统 CPU 策略的交互。限额触发退出后，本插件不再自动启动应用。服务每 30 分钟兜底巡检一次；前台变化、应用启动和设置变更会立即触发检查，相同 PID 与 CPU 配置不会重复重置监控窗口。

从旧版升级后需重新加载 SpringBoard，以卸载内存中的旧保活模块。旧配置中的 `KeepAlive` 和 `RelaunchAfterRespring` 字段会被忽略，现有 CPU、内存和优先级设置继续使用。

## 构建

Jetsam 配置保留 0～210 的统一档位。iOS 15 写入对应的 0～21 内核档位（如配置 150 → 内核 15）；iOS 16 起使用 0～210。列表当前状态显示实际内核值，配置行显示保存的配置值，日志同时记录换算及回读结果。依据 Apple XNU [8020](https://github.com/apple-oss-distributions/xnu/blob/xnu-8020.140.41/bsd/sys/kern_memorystatus.h) 与 [8792](https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.41.9/bsd/sys/kern_memorystatus.h) 的档位定义。

需要 RootHide Theos 与 iOS SDK。`make package THEOS_PACKAGE_SCHEME=roothide` 输出 `iphoneos-arm64e` 的 `packages/*.deb`。GitHub Actions 中的 `Package` 工作流可手动运行，成功后在该次运行的 Artifacts 下载 deb。仅支持 RootHide 隐根环境。

本工程尚需 RootHide 真机验证 SpringBoard 私有 API 的运行行为。首次测试请选非系统应用，先测试单项设置。

## 来源与许可

进程身份复核参考 [CPUOverloadKiller](https://github.com/moxuan1121/CPUOverloadKiller)，按 GPL-3.0 许可使用并作了改动；原 CPU 采样代码现已删除。MemoryControlRe 的重构源码来自本次提供的本地工程；历史版本使用过 StayAliveLite 重构源码，当前已移除其保活模块。本项目按 [GPL-3.0](LICENSE) 发布。
