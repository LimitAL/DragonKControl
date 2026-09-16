# DragonKControl

原生 macOS（SwiftUI）应用，用于控制 BLE 水冷散热设备 `DragonK-XAR1500236`：菜单栏综合负载监控、文档/娱乐/专家三档官方调度、固定输出精细控制、按本机负载自动切档的智能策略，以及断线自动重连与配置保活。

## 功能特性

- **菜单栏监控**：常驻综合负载百分比胶囊，左键打开自适应高度的浮动面板，实时查看负载趋势、CPU 功率/温度、Mac 风扇、冷凝面、水温、冷核、水泵与设备风扇状态。
- **三档官方调度**：文档、娱乐、专家三档配置（`0x81`/`0x82`/`0x83`），温差/温度/功率三种控制方式可独立自定义目标值、水泵与风扇上下限、曲线系数，并持久化保存。
- **固定输出**：原始 `0x84` 控制包精细调节，按官方节奏每 1.5 秒刷新。
- **智能切换**：依据本机 CPU 封装功率、CPU 温度、Mac 风扇三项负载指标自动选择三档，可视化阈值轨道、回差与降档驻留时间，开启后锁定手动档位、待机与固定输出。
- **连接保活**：`AE02` 通知就绪后按官方顺序握手、读取三档配置、恢复最后一次模式；支持意外断线自动重连，最后模式与自定义参数不会丢失。
- **节能采样**：主窗口打开时约 10 秒采样一次，进入菜单栏后台约 30 秒采样一次，并合并系统唤醒定时器。

综合负载并非 macOS CPU 占用率，而是将 CPU 封装功率、CPU 温度、Mac 风扇、冷核最高功率、水泵功率、设备风扇功率按 30%/25%/15%/12%/8%/10% 加权归一化为 0–100，缺失项目会从权重中剔除。

## 环境要求

- macOS 13 及以上
- Xcode 15 及以上（Swift 5）
- 蓝牙权限（entitlement 已内置于 `Resources/DragonKControl.entitlements`）

## 构建与运行

### 使用 Xcode

1. 打开 `DragonKControl.xcodeproj`
2. 选择共享 scheme `DragonKControl` 与运行目标 `My Mac`
3. Build/Run（⌘R）

### 命令行构建

```bash
xcodebuild -project DragonKControl.xcodeproj -scheme DragonKControl -configuration Release build
```

## 下载

预编译的 Release 版本发布在 [GitHub Releases](https://github.com/LimitAL/DragonKControl/releases)，同时提供 Apple Silicon（`arm64`）与 Intel（`x86_64`）两个独立压缩包。由于未经 Apple 公证，首次打开时 Gatekeeper 会拦截，可在「系统设置 → 隐私与安全性」中选择仍要打开，或执行：

```bash
xattr -cr /path/to/DragonKControl.app
```

## 项目结构

| 文件 | 职责 |
| --- | --- |
| [DragonKControlApp.swift](DragonKControl/DragonKControlApp.swift) | App 入口与主窗口场景 |
| [AppModel.swift](DragonKControl/AppModel.swift) | 共享监控状态与综合负载计算 |
| [AppLifecycle.swift](DragonKControl/AppLifecycle.swift) | 原生状态栏、左右键操作、主窗口与 Dock 生命周期 |
| [Bluetooth/CoolerManager.swift](DragonKControl/Bluetooth/CoolerManager.swift) | 扫描、连接、GATT、智能策略与日志 |
| [Protocol/DragonKProtocol.swift](DragonKControl/Protocol/DragonKProtocol.swift) | 官方 20 字节控制包与设备回报解析 |
| [System/HostMonitor.swift](DragonKControl/System/HostMonitor.swift) | HID/AppleSMC 本机传感器采集 |
| [UI/MainView.swift](DragonKControl/UI/MainView.swift) | 主窗口界面 |
| [UI/MenuBarPanel.swift](DragonKControl/UI/MenuBarPanel.swift) | 菜单栏浮动面板 |
| `Resources/` | 蓝牙用途说明文案与 entitlement |

## 协议与硬件细节

协议来自本机安装的官方 DragonKing 1.2.0、官方实机写包，以及厂商微信小程序解包源码。实测确认 `AE00` 服务、`AE01` 写入、`AE02` 通知；`0x84` 控制包第 7/12 字节分别设置水泵/风扇目标，物理水泵与风扇实际功率来自 `C0[13]/[14]`，`49`/`4F` 帧为控制器内部通道/调度值，不等价于实际输出。

完整的能力盘点、已验证协议字段与移植状态见 [CAPABILITIES.md](CAPABILITIES.md)；本机负载采集与智能切换状态机设计见 [Documentation/SmartSwitchDesign.md](Documentation/SmartSwitchDesign.md)；断线恢复与配置保活的实机验证记录见 [RECONNECT-TEST-2026-09-16.md](RECONNECT-TEST-2026-09-16.md)。

## 更新日志

详见 [CHANGELOG.md](CHANGELOG.md)。
