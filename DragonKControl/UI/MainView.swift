import Charts
import SwiftUI

struct MainView: View {
    @StateObject private var manager = CoolerManager()
    @State private var waterLevel = 70.0
    @State private var fanLevel = 70.0
    @State private var editingProfile = DragonKControlMode.document

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("DragonK 散热控制").font(.largeTitle.bold())
                        Text(targetName).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "fanblades.fill")
                        .font(.system(size: 35)).foregroundStyle(.cyan)
                }

                GroupBox("设备") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(manager.connectionState, systemImage: manager.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                            Spacer()
                            Label(manager.operatingState.rawValue,
                                  systemImage: manager.operatingState == .running ? "bolt.fill" : "pause.circle")
                                .foregroundStyle(manager.operatingState == .running ? .green : .secondary)
                            Text(manager.rssi).foregroundStyle(.secondary)
                        }
                        Text(manager.bluetoothState).foregroundStyle(.secondary)
                        HStack {
                            Button("扫描并连接") { manager.scan() }
                                .disabled(manager.bluetoothState != "蓝牙已开启" || manager.isConnected)
                            Button("断开") { manager.disconnect() }.disabled(!manager.isConnected)
                        }
                        Toggle("意外断开时自动重连", isOn: $manager.autoReconnect)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                GroupBox("官方温控模式") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("默认三档沿用官方温差调度：水泵保持 42，风扇按 20–50 的线性曲线自动调整。专家模式提高温差目标，并不直接提高转速；每档参数可在下方独立修改。")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            profileButton(.document, symbol: "doc.text")
                            profileButton(.entertainment, symbol: "play.rectangle")
                            profileButton(.expert, symbol: "gauge.with.dots.needle.67percent")
                        }
                        Text("当前控制：\(manager.controlMode.title)")
                            .font(.headline)
                        DisclosureGroup("自定义三档参数") {
                            profileConfigurationEditor
                                .padding(.top, 8)
                        }
                        DisclosureGroup("高级固定输出（0x84 原始控制）") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("固定输出会绕过官方三档曲线。较高数值会显著提高水泵流量和风扇噪音。")
                                    .font(.caption).foregroundStyle(.orange)
                                HStack(spacing: 12) {
                                    Button {
                                        waterLevel = 42
                                        fanLevel = 42
                                        manager.enterStandby()
                                    } label: {
                                        Label("待机 · 42/42", systemImage: "pause.circle.fill")
                                    }
                                    Button {
                                        manager.startRunning(water: Int(waterLevel), fan: Int(fanLevel))
                                    } label: {
                                        Label("应用固定输出", systemImage: "slider.horizontal.3")
                                    }
                                }
                                .disabled(!manager.canSend)
                                targetSlider("水泵", value: $waterLevel)
                                targetSlider("风扇", value: $fanLevel)
                            }.padding(.top, 8)
                        }
                        HStack(spacing: 22) {
                            feedback("水泵", target: manager.requestedWater, confirmed: manager.confirmedWater, output: manager.waterOutput,
                                     demand: manager.waterDemand)
                            feedback("风扇", target: manager.requestedFan, confirmed: manager.confirmedFan, output: manager.fanOutput,
                                     demand: manager.fanDemand)
                        }
                        Text("49/4F 回报的是控制器内部通道值；设备当前实际水泵与风扇功率以“实时温度与冷核功率”中的 C0 数据为准。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(manager.statusMessage).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(6)
                }

                GroupBox("实时温度与冷核功率") {
                    VStack(alignment: .leading, spacing: 12) {
                        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                            GridRow {
                                telemetryValue("左冷凝面", manager.leftCondensationTemperature, suffix: "℃")
                                telemetryValue("右冷凝面", manager.rightCondensationTemperature, suffix: "℃")
                                telemetryValue("设定温度", manager.setTemperature, suffix: "℃")
                            }
                            GridRow {
                                telemetryValue("环境温度", manager.environmentTemperature, suffix: "℃")
                                telemetryValue("水温", manager.waterTemperature, suffix: "℃")
                                telemetryValue("设备类型", manager.machineType, suffix: "")
                            }
                            GridRow {
                                telemetryValue("冷核 A", manager.coldCoreA, suffix: "%")
                                telemetryValue("冷核 B", manager.coldCoreB, suffix: "%")
                                telemetryValue("冷核 C", manager.coldCoreC, suffix: "%")
                            }
                            GridRow {
                                telemetryValue("水泵功率", manager.telemetryPumpPower, suffix: "%")
                                telemetryValue("风扇功率", manager.telemetryFanPower, suffix: "%")
                                Color.clear.frame(height: 1)
                            }
                        }
                        Text("数据来自设备 C0 实时帧；字段位置与厂商源码页面及 49/4F 回报交叉对齐。温差模式的设定温度按环境温度减目标温差计算。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("内部控制趋势") {
                    VStack(alignment: .leading, spacing: 10) {
                        if manager.samples.isEmpty {
                            Text("连接后将在这里显示 49/4F 控制器通道值。")
                                .foregroundStyle(.secondary)
                        } else {
                            Chart(manager.samples) { sample in
                                LineMark(x: .value("时间", sample.timestamp),
                                         y: .value("内部通道值", sample.value))
                                    .foregroundStyle(by: .value("通道", sample.channel))
                            }
                            .chartYScale(domain: 0...100)
                            .frame(height: 175)
                        }
                        Text("数值来自 49/4F 通知，用于观察控制器内部调度，不等同于物理水泵或风扇功率。实际功率显示在上方 C0 实时数据中。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                GroupBox("已识别协议") {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("服务 AE00 · 写入 AE01 · 状态通知 AE02")
                            .font(.body.monospaced())
                        Text("控制包来自本机官方 DragonKing 1.2.0；水泵与风扇的独立设定已通过设备状态回报验证。")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(6)
                }

                GroupBox("连接稳定性") {
                    HStack(spacing: 24) {
                        metric("通知", "\(manager.notificationCount)")
                        metric("断开", "\(manager.disconnectCount)")
                        metric("自动恢复", "\(manager.reconnectCount)")
                        metric("配置刷新", "\(manager.controlRefreshCount)")
                        metric("协议查询", "\(manager.protocolQueryCount)")
                        metric("最长通知间隔", String(format: "%.1f 秒", manager.longestNotificationGap))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    Text("最后一次设定保存在本机；固定输出每 1.5 秒刷新，官方温控模式只在切换或重连时写入。")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.bottom, 6)
                }

                GroupBox("BLE 特征与诊断") {
                    VStack(alignment: .leading, spacing: 12) {
                        if manager.rows.isEmpty {
                            Text("连接后将在这里显示设备服务、特征、属性及读取值。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(manager.rows) { row in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(row.service) / \(row.uuid)").font(.caption.monospaced())
                                    Text("\(row.properties)    \(row.value)").font(.caption)
                                        .foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                        }
                        Button("复制诊断信息") { manager.copyDiagnostics() }
                    }.padding(6)
                }
            }
            .padding(26)
        }
        .frame(minWidth: 640, minHeight: 650)
        .onAppear {
            waterLevel = Double(manager.requestedWater ?? 70)
            fanLevel = Double(manager.requestedFan ?? 70)
        }
    }

    private func profileButton(_ mode: DragonKControlMode, symbol: String) -> some View {
        let settings = manager.settings(for: mode)
        return Button {
            manager.applyProfile(mode)
        } label: {
            VStack(spacing: 4) {
                Label(mode.title, systemImage: symbol)
                Text("\(settings.control.title) \(settings.controlValue) · 泵 \(settings.pumpFixed) · 风扇 \(settings.fanMinimum)–\(settings.fanMaximum)")
                    .font(.caption)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 7)
        }
        .buttonStyle(.bordered)
        .tint(manager.controlMode == mode ? .accentColor : .secondary)
        .disabled(!manager.canSend)
    }

    private var profileConfigurationEditor: some View {
        let settings = manager.settings(for: editingProfile)
        return VStack(alignment: .leading, spacing: 11) {
            Picker("配置", selection: $editingProfile) {
                Text("文档").tag(DragonKControlMode.document)
                Text("娱乐").tag(DragonKControlMode.entertainment)
                Text("专家").tag(DragonKControlMode.expert)
            }
            .pickerStyle(.segmented)

            Picker("控制方式", selection: profileControlBinding(editingProfile)) {
                ForEach(DragonKCoolingControl.allCases) { control in
                    Text(control.title).tag(control)
                }
            }
            .pickerStyle(.segmented)

            Stepper("\(settings.control.valueLabel)：\(settings.controlValue)\(settings.control == .power ? "%" : "℃")",
                    value: profileIntBinding(editingProfile, \.controlValue),
                    in: settings.control.allowedValues)
            profileSlider("水泵固定值", value: profileIntBinding(editingProfile, \.pumpFixed), range: 42...100)
            profileSlider("风扇最小值", value: profileIntBinding(editingProfile, \.fanMinimum), range: 0...100)
            profileSlider("风扇最大值", value: profileIntBinding(editingProfile, \.fanMaximum), range: 0...100)
            Stepper("风扇曲线系数：\(settings.fanCurve)",
                    value: profileIntBinding(editingProfile, \.fanCurve), in: 0...500, step: 5)

            HStack {
                Button("应用 \(editingProfile.title)") {
                    manager.applyProfile(editingProfile)
                }
                .disabled(!manager.canSend)
                if let readback = manager.deviceProfileReadback[editingProfile] {
                    Text("设备已读回：\(readback.control.title) \(readback.controlValue)，泵 \(readback.pumpFixed)，风扇 \(readback.fanMinimum)–\(readback.fanMaximum)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func profileControlBinding(_ mode: DragonKControlMode) -> Binding<DragonKCoolingControl> {
        Binding {
            manager.settings(for: mode).control
        } set: { value in
            manager.updateProfile(mode) {
                $0.control = value
                $0.controlValue = min(max($0.controlValue, value.allowedValues.lowerBound),
                                      value.allowedValues.upperBound)
            }
        }
    }

    private func profileIntBinding(_ mode: DragonKControlMode,
                                   _ keyPath: WritableKeyPath<DragonKProfileSettings, Int>) -> Binding<Int> {
        Binding {
            manager.settings(for: mode)[keyPath: keyPath]
        } set: { value in
            manager.updateProfile(mode) { $0[keyPath: keyPath] = value }
        }
    }

    private func profileSlider(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title).frame(width: 96, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
            Text("\(value.wrappedValue)%").font(.body.monospacedDigit()).frame(width: 46)
        }
    }

    private func telemetryValue(_ title: String, _ value: Int?, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { "\($0)\(suffix)" } ?? "—")
                .font(.title3.monospacedDigit())
        }
        .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
    }

    private func targetSlider(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 38, alignment: .leading)
            Slider(value: value, in: 42...100, step: 1)
                .accessibilityLabel("\(title)目标强度")
            Text("\(Int(value.wrappedValue))%")
                .font(.body.monospacedDigit()).frame(width: 52)
        }
    }

    private func feedback(_ title: String, target: Int?, confirmed: Int?, output: Int?, demand: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title)已发送目标：\(target.map { "\($0)%" } ?? "—")")
                .font(.headline)
            Text("设备目标：\(confirmed.map { "\($0)%" } ?? "—")")
                .font(.callout).foregroundStyle(.secondary)
            Text("内部通道：\(output.map { "\($0)%" } ?? "—") · 内部调度：\(demand.map { "\($0)%" } ?? "—")")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
    }
}
