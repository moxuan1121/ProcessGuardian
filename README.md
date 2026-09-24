# ProcessGuardian

iOS 15–17.3 越狱插件：一个设置入口管理应用或进程的 nice 优先级、Jetsam 优先级、前后台内存限额，以及应用的前台 CPU 阈值与后台自动重拉。默认总开关关闭，各条配置默认不改变系统状态。

## 组件

- `ProcessGuardianPrefs.bundle`：设置中的进程列表与单项编辑页。可选应用或输入进程名；后台重拉只适用于应用包名。
- `processguardiand`：root LaunchDaemon，应用内存与优先级设置；不做高频 CPU 采样。
- `ProcessGuardian.dylib`：SpringBoard 前台切换探针与前台 CPU 采样。CPU 达到配置阈值并连续超过指定秒数时，核对 PID、启动时间、路径和包名后发送 `SIGKILL`。
- `ProcessGuardianStay.dylib`：基于 StayAliveLite 重构的 SpringBoard 断言和重拉逻辑。用户上滑关闭会暂停重拉；系统内存限制或 CPU 阈值导致的进程退出可重新拉起。

显式设置的内存上限始终是 fatal 限额，即使开启“防内存溢出被杀”也不覆盖上限。CPU 阈值只监控前台应用；100% 约等于单个核心满载。守护和限额同时启用时，先让旧 PID 退出，再由守护逻辑启动新 PID。

## 构建

需要 Theos 与 iOS SDK。`make package THEOS_PACKAGE_SCHEME=rootless` 输出 `packages/*.deb`。GitHub Actions 中的 `Package` 工作流可手动运行，成功后在该次运行的 Artifacts 下载 deb。

本工程尚需真机验证 SpringBoard 私有 API 和不同越狱环境下的行为。首次测试请选非系统应用，先测试单项设置。

## 来源与许可

CPU 采样与进程身份复核参考 [CPUOverloadKiller](https://github.com/moxuan1121/CPUOverloadKiller)，按 GPL-3.0 许可使用并作了改动：改为读取统一配置、仅监控前台应用，并由本工程的后台守护逻辑处理退出后的重拉。MemoryControlRe、StayAliveLite 的重构源码来自本次提供的本地工程。本项目按 [GPL-3.0](LICENSE) 发布。
