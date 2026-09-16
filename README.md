# DragonKControl

正式的 macOS SwiftUI/Xcode App 项目，控制 BLE 设备 `DragonK-XAR1500236`。打开 `DragonKControl.xcodeproj`，选择共享 scheme `DragonKControl` 和 `My Mac`，在 Xcode 中 Build/Run。项目最低支持 macOS 13，蓝牙用途说明及蓝牙 entitlement 已配置。

界面提供三档同步控制（42%、70%、100%），也可分别设置水泵与风扇目标值。设备通知回报两者的确认目标值和运行数值，运行趋势图显示最近 240 个样本。意外断开时可自动重连，手动断开不会触发重连。目标值不保证恒定的实际输出，硬件仍会按自身温控策略调整。

代码按职责组织：`Bluetooth/CoolerManager.swift` 负责扫描、连接、GATT 和日志；`Protocol/DragonKProtocol.swift` 负责官方 20 字节控制包及设备回报解析；`UI/MainView.swift` 负责界面。`Resources` 中是蓝牙用途说明和 entitlement。

协议来自本机安装的官方 DragonKing 1.2.0。实际设备测试确认：`AE00` 服务、`AE01` 写入、`AE02` 通知；控制包第 7 字节设置水泵目标，`4F` 通知第 16 字节回报；第 12 字节设置风扇目标，`49` 通知第 12 字节回报。独立测试 `水泵=80/风扇=42`、`水泵=42/风扇=80`，并在每次测试后恢复 `42/42`。

构建检查：

```sh
xcodebuild -project DragonKControl.xcodeproj -scheme DragonKControl \
  -configuration Debug -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO build
```

`CAPABILITIES.md` 记录了官方软件和硬件的能力、目前已移植部分与需要继续确认的协议。
