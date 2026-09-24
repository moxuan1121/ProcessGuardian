# ProcessGuardian

iOS 15–17.3 RootHide 隐根插件：在设置中管理进程的 nice 与 Jetsam 优先级、前后台内存上限、前台 CPU 阈值和后台自动重拉。默认总开关关闭，初次安装的进程列表为空。

## 组件

- `ProcessGuardianPrefs.bundle`：设置中的进程列表与单项编辑页。可选应用或输入进程名；后台重拉只适用于应用包名。
- `processguardiand`：root LaunchDaemon，应用内存与优先级设置；不做高频 CPU 采样。
- `ProcessGuardian.dylib`：SpringBoard 前台切换探针与前台 CPU 采样。CPU 达到配置阈值并连续超过指定秒数时，核对 PID、启动时间、路径和包名后发送 `SIGKILL`。
- `ProcessGuardianStay.dylib`：基于 StayAliveLite 重构的 SpringBoard 断言和重拉逻辑。用户上滑关闭会暂停重拉；系统内存限制或 CPU 阈值导致的进程退出可重新拉起。

显式内存上限始终为 fatal 限额。CPU 阈值只监控前台应用；100% 约等于单个核心满载。守护与限额同时启用时，先让旧 PID 退出，再由守护逻辑启动新 PID。守护进程每 30 分钟兜底巡检一次；前台变化、应用启动和设置变更会立即触发检查。

## 构建

需要 RootHide Theos 与 iOS SDK。`make package THEOS_PACKAGE_SCHEME=roothide` 输出 `iphoneos-arm64e` 的 `packages/*.deb`。GitHub Actions 中的 `Package` 工作流可手动运行，成功后在该次运行的 Artifacts 下载 deb。仅支持 RootHide 隐根环境。

本工程尚需 RootHide 真机验证 SpringBoard 私有 API 的运行行为。首次测试请选非系统应用，先测试单项设置。

## 来源与许可

CPU 采样与进程身份复核参考 [CPUOverloadKiller](https://github.com/moxuan1121/CPUOverloadKiller)，按 GPL-3.0 许可使用并作了改动：改为读取统一配置、仅监控前台应用，并由本工程的后台守护逻辑处理退出后的重拉。MemoryControlRe、StayAliveLite 的重构源码来自本次提供的本地工程。本项目按 [GPL-3.0](LICENSE) 发布。
