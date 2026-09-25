# ProcessGuardian

iOS 15–17.3 RootHide 隐根插件，在系统设置中配置进程 Nice、Jetsam 优先级、前后台内存上限与 CPU 连续超限终止。首次安装时进程列表为空，总开关默认关闭。

## CPU 监控

CPU 监控采用 [CPUOverloadKiller](https://github.com/moxuan1121/CPUOverloadKiller) 的自适应采样策略，读取整个进程的累计 CPU 时间。应用默认只在前台监控，可单独开启“后台继续监控”；系统进程在运行期间监控。应用退出前台时，连续超限计时清零。

每个目标可设置 CPU 上限（2～1000%，0 关闭）、连续超限时间、低负载采样间隔、接近阈值比例、接近阈值采样间隔和超限采样间隔。默认值依次为 10 秒、60 秒、67%、15 秒、1 秒。最近一次 CPU 使用率低于“上限 × 接近阈值比例”时按低负载间隔采样；达到该比例时按接近阈值间隔采样；超过上限后按超限间隔采样。低于上限会清零连续超限时间。达到设定时间后，守护进程重新核对 PID、启动时间、可执行路径和进程身份，再终止目标。

所有目标共用 root 守护进程中的一个动态定时器。没有需要监控的前台应用或系统进程时，定时器暂停。SpringBoard 探针只传递前台切换和进程启动事件。旧的 XNU fatal CPU monitor 已移除；升级后需重新加载 SpringBoard。此分支不包含后台保活或自动重拉。

## 构建

需要 RootHide Theos 与 iOS SDK。`make package THEOS_PACKAGE_SCHEME=roothide` 输出 `iphoneos-arm64e` 的 deb。GitHub Actions 的 `Package` 工作流也可手动打包。仅支持 RootHide 隐根环境。

Jetsam 配置保留 0～210 的统一档位。iOS 15 写入对应的 0～21 内核档位（例如配置 150 对应内核 15）；iOS 16 起使用 0～210。列表显示实际内核值。

Jetsam 优先级优先写入 assertion 槽；内核不接受时退回常规优先级槽。关闭配置时按本次实际写入的槽位撤销。每次应用后 10 秒会对同一进程实例回读一次，只有值被覆盖才重新写入；原有 30 分钟巡检仍用于兜底。升级前已经运行的进程可能保留旧版本写入的常规优先级，重新启动该目标进程后可让系统重新建立基线。

## 来源与许可

CPU 采样策略与进程身份复核参考 CPUOverloadKiller，按 [GPL-3.0](LICENSE) 许可使用并作了改动。内存与优先级模块参考本次提供的 MemoryControlRe 重构源码。项目按 GPL-3.0 发布。
