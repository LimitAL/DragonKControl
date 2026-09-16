import Charts
import SwiftUI

struct MainView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var manager: CoolerManager
    @ObservedObject private var hostMonitor: HostMonitor
    @State private var waterLevel = 70.0
    @State private var fanLevel = 70.0
    @State private var editingProfile = DragonKControlMode.document

    private let dashboardColumns = [
        GridItem(.adaptive(minimum: 168, maximum: 260), spacing: 14)
    ]
    private let overviewColumns = [
        GridItem(.adaptive(minimum: 105, maximum: 150), spacing: 10)
    ]

    init(model: AppModel) {
        self.model = model
        manager = model.manager
        hostMonitor = model.hostMonitor
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            LinearGradient(colors: [Color.cyan.opacity(0.09), .clear, Color.blue.opacity(0.04)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    heroHeader
                    hostLoadAndSmartControl
                    thermalOverview
                    modeControl
                    hardwareOutput
                    internalControl
                    stabilityAndDiagnostics
                }
                .padding(24)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 680)
        .onAppear {
            waterLevel = Double(manager.requestedWater ?? 70)
            fanLevel = Double(manager.requestedFan ?? 70)
        }
    }

    private var heroHeader: some View {
        VStack(spacing: 15) {
            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.cyan.opacity(0.9), .blue],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                    Image(systemName: "snowflake")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 62, height: 62)
                .shadow(color: .cyan.opacity(0.25), radius: 16, y: 8)

                VStack(alignment: .leading, spacing: 4) {
                    Text("DragonK Control")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(targetName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 7) {
                        statusPill("\(model.loadPercentage)% 负载",
                                   symbol: "gauge.with.dots.needle.50percent",
                                   tint: loadTint)
                        statusPill(manager.controlMode.title,
                                   symbol: modeSymbol(manager.controlMode),
                                   tint: modeTint(manager.controlMode))
                        statusPill(manager.connectionState,
                                   symbol: manager.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right",
                                   tint: manager.isConnected ? .green : .orange)
                        statusPill(manager.operatingState.rawValue,
                                   symbol: manager.operatingState == .running ? "bolt.fill" : "pause.fill",
                                   tint: manager.operatingState == .running ? .cyan : .gray)
                        if !manager.rssi.isEmpty {
                            statusPill(manager.rssi, symbol: "wave.3.right", tint: .gray)
                        }
                    }

                    HStack(spacing: 8) {
                        if manager.smartSwitchEnabled {
                            Label("智能接管", systemImage: "wand.and.stars")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.indigo)
                        }
                        Toggle(isOn: $manager.autoReconnect) {
                            Label("自动重连", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Button {
                            manager.scan()
                        } label: {
                            Label("扫描连接", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .disabled(manager.bluetoothState != "蓝牙已开启" || manager.isConnected)

                        Button(role: .destructive) {
                            manager.disconnect()
                        } label: {
                            Label("断开", systemImage: "xmark.circle")
                        }
                        .disabled(!manager.isConnected)
                    }
                    .controlSize(.small)
                }
            }

            Divider().opacity(0.7)

            LazyVGrid(columns: overviewColumns, spacing: 10) {
                overviewTile("CPU 封装",
                             value: hostMonitor.snapshot.cpuPower.map { String(format: "%.1f W", $0) } ?? "—",
                             symbol: "bolt.fill", tint: .orange)
                overviewTile("整机功率",
                             value: hostMonitor.snapshot.systemPower.map { String(format: "%.1f W", $0) } ?? "—",
                             symbol: "powerplug.fill", tint: .yellow)
                overviewTile("CPU 温度",
                             value: hostMonitor.snapshot.cpuTemperature.map { String(format: "%.1f℃", $0) } ?? "—",
                             symbol: "thermometer.high", tint: .red)
                overviewTile("Mac 风扇",
                             value: hostMonitor.snapshot.fanRPM.map { String(format: "%.0f RPM", $0) } ?? "—",
                             symbol: "fanblades.fill", tint: .mint)
                overviewTile("冷凝面",
                             value: pairedTemperature(manager.leftCondensationTemperature,
                                                      manager.rightCondensationTemperature),
                             symbol: "snowflake", tint: .cyan)
                overviewTile("水温",
                             value: temperatureValue(manager.waterTemperature),
                             symbol: "drop.fill", tint: .teal)
                overviewTile("冷核最高",
                             value: maximumPower(manager.coldCoreA, manager.coldCoreB, manager.coldCoreC),
                             symbol: "cpu.fill", tint: .indigo)
                overviewTile("水泵功率",
                             value: percentValue(manager.telemetryPumpPower),
                             symbol: "drop.circle.fill", tint: .teal)
                overviewTile("设备风扇",
                             value: percentValue(manager.telemetryFanPower),
                             symbol: "fanblades.fill", tint: .green)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var thermalOverview: some View {
        DashboardCard(title: "实时热状态",
                      subtitle: "冷凝面、水路与目标温度",
                      symbol: "thermometer.medium",
                      tint: .cyan) {
            LazyVGrid(columns: dashboardColumns, spacing: 14) {
                telemetryTile("左冷凝面", manager.leftCondensationTemperature, suffix: "℃",
                              symbol: "snowflake", tint: .cyan)
                telemetryTile("右冷凝面", manager.rightCondensationTemperature, suffix: "℃",
                              symbol: "snowflake", tint: .blue)
                telemetryTile("设定温度", manager.setTemperature, suffix: "℃",
                              symbol: "scope", tint: .purple)
                telemetryTile("环境温度", manager.environmentTemperature, suffix: "℃",
                              symbol: "house.fill", tint: .orange)
                telemetryTile("水温", manager.waterTemperature, suffix: "℃",
                              symbol: "drop.fill", tint: .teal)
                telemetryTile("设备类型", manager.machineType, suffix: "",
                              symbol: "externaldrive.fill", tint: .gray)
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text("温差模式的设定温度由环境温度减去目标温差计算；其余实时数值来自设备 C0 帧。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var hostLoadAndSmartControl: some View {
        DashboardCard(title: "本机负载与智能切换",
                      subtitle: "主窗口约 10 秒、菜单栏后台约 30 秒采样并平滑",
                      symbol: "macbook.and.iphone",
                      tint: .indigo) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("智能切换", systemImage: "wand.and.stars")
                        .font(.headline)
                    Text(manager.smartSwitchEnabled ? manager.smartStatus : hostMonitor.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { manager.smartSwitchEnabled },
                    set: { manager.setSmartSwitchEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("智能切换")
            }
            .padding(14)
            .background(manager.smartSwitchEnabled ? Color.indigo.opacity(0.10) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 14))

            VStack(spacing: 14) {
                thresholdEditor("CPU 功率", current: hostMonitor.snapshot.cpuPower,
                                unit: "W", range: 3...100, step: 1,
                                entertainment: smartThresholdBinding(\.entertainmentPower),
                                expert: smartThresholdBinding(\.expertPower),
                                symbol: "bolt.fill", tint: .orange)
                thresholdEditor("CPU 温度", current: hostMonitor.snapshot.cpuTemperature,
                                unit: "℃", range: 35...100, step: 1,
                                entertainment: smartThresholdBinding(\.entertainmentTemperature),
                                expert: smartThresholdBinding(\.expertTemperature),
                                symbol: "thermometer.high", tint: .red)
                thresholdEditor("风扇转速", current: hostMonitor.snapshot.fanRPM,
                                unit: "RPM", range: 1_000...8_000, step: 100,
                                entertainment: smartThresholdBinding(\.entertainmentFanRPM),
                                expert: smartThresholdBinding(\.expertFanRPM),
                                symbol: "fanblades.fill", tint: .mint)
            }
            .disabled(!manager.smartSwitchEnabled)
            .opacity(manager.smartSwitchEnabled ? 1 : 0.48)

            Label("任一指标达到阈值会立即升档；降档要求所有可用指标回落，并保留回差和 20 秒驻留时间。",
                  systemImage: "arrow.up.arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modeControl: some View {
        DashboardCard(title: "散热模式",
                      subtitle: "官方调度与每档独立参数",
                      symbol: "dial.medium.fill",
                      tint: .blue) {
            HStack(spacing: 12) {
                profileCard(.document, symbol: "doc.text.fill", tint: .blue)
                profileCard(.entertainment, symbol: "play.rectangle.fill", tint: .purple)
                profileCard(.expert, symbol: "gauge.with.dots.needle.67percent", tint: .orange)
            }

            if manager.smartSwitchEnabled {
                Label("三档选择和固定输出已由智能切换接管",
                      systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
            }

            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(manager.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            Divider()

            DisclosureGroup {
                profileConfigurationEditor
                    .padding(.top, 14)
            } label: {
                disclosureLabel("自定义三档参数", symbol: "slider.horizontal.3", tint: .blue)
            }

            Divider()

            DisclosureGroup {
                fixedOutputEditor
                    .padding(.top, 14)
            } label: {
                disclosureLabel("高级固定输出", symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    private var hardwareOutput: some View {
        DashboardCard(title: "硬件实时功率",
                      subtitle: "设备 C0 帧中的物理输出",
                      symbol: "cpu.fill",
                      tint: .teal) {
            LazyVGrid(columns: dashboardColumns, spacing: 14) {
                powerTile("冷核 A", manager.coldCoreA, symbol: "snowflake", tint: .cyan)
                powerTile("冷核 B", manager.coldCoreB, symbol: "snowflake", tint: .blue)
                powerTile("冷核 C", manager.coldCoreC, symbol: "snowflake", tint: .indigo)
                powerTile("水泵", manager.telemetryPumpPower, symbol: "drop.circle.fill", tint: .teal)
                powerTile("风扇", manager.telemetryFanPower, symbol: "fanblades.fill", tint: .mint)
            }
        }
    }

    private var internalControl: some View {
        DashboardCard(title: "内部控制器",
                      subtitle: "49/4F 通道状态，用于诊断调度过程",
                      symbol: "waveform.path.ecg",
                      tint: .purple) {
            HStack(spacing: 14) {
                feedbackCard("水泵", symbol: "drop.fill", tint: .teal,
                             target: manager.requestedWater,
                             confirmed: manager.confirmedWater,
                             output: manager.waterOutput,
                             demand: manager.waterDemand)
                feedbackCard("风扇", symbol: "fanblades.fill", tint: .mint,
                             target: manager.requestedFan,
                             confirmed: manager.confirmedFan,
                             output: manager.fanOutput,
                             demand: manager.fanDemand)
            }

            if manager.samples.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("等待控制器数据")
                        .font(.headline)
                    Text("连接后将在这里显示内部通道趋势。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
            } else {
                Chart(manager.samples) { sample in
                    LineMark(x: .value("时间", sample.timestamp),
                             y: .value("内部通道", sample.value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(by: .value("通道", sample.channel))
                    AreaMark(x: .value("时间", sample.timestamp),
                             y: .value("内部通道", sample.value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(by: .value("通道", sample.channel))
                        .opacity(0.08)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 190)
            }

            Label("内部通道值不等同于物理水泵或风扇功率；实际功率请查看上方硬件卡片。",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stabilityAndDiagnostics: some View {
        DashboardCard(title: "连接与诊断",
                      subtitle: "稳定性计数和底层 BLE 信息",
                      symbol: "stethoscope",
                      tint: .green) {
            LazyVGrid(columns: dashboardColumns, spacing: 12) {
                metricTile("通知", value: "\(manager.notificationCount)", symbol: "bell.badge.fill", tint: .blue)
                metricTile("断开", value: "\(manager.disconnectCount)", symbol: "bolt.slash.fill", tint: .red)
                metricTile("自动恢复", value: "\(manager.reconnectCount)", symbol: "arrow.clockwise.circle.fill", tint: .green)
                metricTile("配置写入", value: "\(manager.controlRefreshCount)", symbol: "square.and.arrow.down.fill", tint: .purple)
                metricTile("协议查询", value: "\(manager.protocolQueryCount)", symbol: "point.3.connected.trianglepath.dotted", tint: .teal)
                metricTile("最长间隔", value: String(format: "%.1f 秒", manager.longestNotificationGap),
                           symbol: "timer", tint: .orange)
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Label("服务 AE00 · 写入 AE01 · 通知 AE02",
                          systemImage: "point.3.filled.connected.trianglepath.dotted")
                        .font(.callout.monospaced())

                    if manager.rows.isEmpty {
                        Text("连接后显示服务、特征、属性和原始值。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(manager.rows) { row in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: row.writable ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .foregroundStyle(row.writable ? .orange : .blue)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(row.service) / \(row.uuid)")
                                        .font(.caption.monospaced())
                                    Text("\(row.properties)    \(row.value)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                        }
                    }

                    Button {
                        manager.copyDiagnostics()
                    } label: {
                        Label("复制诊断信息", systemImage: "doc.on.doc")
                    }
                }
                .padding(.top, 14)
            } label: {
                disclosureLabel("BLE 特征与原始数据", symbol: "terminal.fill", tint: .gray)
            }
        }
    }

    private var profileConfigurationEditor: some View {
        let settings = manager.settings(for: editingProfile)
        return VStack(alignment: .leading, spacing: 16) {
            Picker("配置", selection: $editingProfile) {
                Label("文档", systemImage: "doc.text.fill").tag(DragonKControlMode.document)
                Label("娱乐", systemImage: "play.rectangle.fill").tag(DragonKControlMode.entertainment)
                Label("专家", systemImage: "gauge.with.dots.needle.67percent").tag(DragonKControlMode.expert)
            }
            .pickerStyle(.segmented)

            Picker("控制方式", selection: profileControlBinding(editingProfile)) {
                ForEach(DragonKCoolingControl.allCases) { control in
                    Text(control.title).tag(control)
                }
            }
            .pickerStyle(.segmented)

            parameterStepper(settings.control.valueLabel,
                             value: profileIntBinding(editingProfile, \.controlValue),
                             range: settings.control.allowedValues,
                             suffix: settings.control == .power ? "%" : "℃",
                             symbol: settings.control == .power ? "bolt.fill" : "thermometer.medium",
                             tint: .cyan)
            profileSlider("水泵固定值", value: profileIntBinding(editingProfile, \.pumpFixed),
                          range: 42...100, symbol: "drop.fill", tint: .teal)
            profileSlider("风扇最小值", value: profileIntBinding(editingProfile, \.fanMinimum),
                          range: 0...100, symbol: "fanblades", tint: .mint)
            profileSlider("风扇最大值", value: profileIntBinding(editingProfile, \.fanMaximum),
                          range: 0...100, symbol: "fanblades.fill", tint: .green)
            parameterStepper("风扇曲线系数",
                             value: profileIntBinding(editingProfile, \.fanCurve),
                             range: 0...500,
                             step: 5,
                             suffix: "",
                             symbol: "chart.xyaxis.line",
                             tint: .purple)

            HStack(spacing: 12) {
                Button {
                    manager.applyProfile(editingProfile)
                } label: {
                    Label("应用\(editingProfile.title)", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!manager.canSend || manager.smartSwitchEnabled)

                if let readback = manager.deviceProfileReadback[editingProfile] {
                    Label("设备回读：\(readback.control.title) \(readback.controlValue) · 泵 \(readback.pumpFixed) · 风扇 \(readback.fanMinimum)–\(readback.fanMaximum)",
                          systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private var fixedOutputEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("固定输出会绕过三档温控曲线。较高数值会显著增加水泵流量、泡沫和风扇噪音。",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)

            targetSlider("水泵", value: $waterLevel, symbol: "drop.fill", tint: .teal)
            targetSlider("风扇", value: $fanLevel, symbol: "fanblades.fill", tint: .mint)

            HStack(spacing: 10) {
                Button {
                    waterLevel = 42
                    fanLevel = 42
                    manager.enterStandby()
                } label: {
                    Label("安全待机 · 42/42", systemImage: "pause.circle.fill")
                }
                Button {
                    manager.startRunning(water: Int(waterLevel), fan: Int(fanLevel))
                } label: {
                    Label("应用固定输出", systemImage: "bolt.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(!manager.canSend || manager.smartSwitchEnabled)
        }
        .padding(16)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func profileCard(_ mode: DragonKControlMode, symbol: String, tint: Color) -> some View {
        let settings = manager.settings(for: mode)
        let isSelected = manager.controlMode == mode
        return Button {
            manager.applyProfile(mode)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(tint)
                        .frame(width: 38, height: 38)
                        .background(tint.opacity(0.13), in: Circle())
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(tint)
                    }
                }
                Text(mode.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 3) {
                    Label("\(settings.control.title) \(settings.controlValue)\(settings.control == .power ? "%" : "℃")",
                          systemImage: "thermometer.medium")
                    Label("水泵 \(settings.pumpFixed)% · 风扇 \(settings.fanMinimum)–\(settings.fanMaximum)%",
                          systemImage: "fanblades")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
            .background(isSelected ? tint.opacity(0.12) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(isSelected ? tint.opacity(0.8) : Color.primary.opacity(0.08),
                            lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!manager.canSend || manager.smartSwitchEnabled)
    }

    private func overviewTile(_ title: String, value: String,
                              symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func modeSymbol(_ mode: DragonKControlMode) -> String {
        switch mode {
        case .document: return "doc.text.fill"
        case .entertainment: return "play.rectangle.fill"
        case .expert: return "gauge.with.dots.needle.67percent"
        case .manual: return "slider.horizontal.3"
        }
    }

    private func modeTint(_ mode: DragonKControlMode) -> Color {
        switch mode {
        case .document: return .blue
        case .entertainment: return .purple
        case .expert: return .orange
        case .manual: return .teal
        }
    }

    private var loadTint: Color {
        switch model.loadPercentage {
        case 0..<35: return .cyan
        case 35..<70: return .orange
        default: return .red
        }
    }

    private func temperatureValue(_ value: Int?) -> String {
        value.map { "\($0)℃" } ?? "—"
    }

    private func pairedTemperature(_ left: Int?, _ right: Int?) -> String {
        switch (left, right) {
        case let (.some(left), .some(right)): return "\(left) / \(right)℃"
        case let (.some(value), .none), let (.none, .some(value)): return "\(value)℃"
        case (.none, .none): return "—"
        }
    }

    private func percentValue(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "—"
    }

    private func maximumPower(_ first: Int?, _ second: Int?, _ third: Int?) -> String {
        guard let maximum = [first, second, third].compactMap({ $0 }).max() else { return "—" }
        return "\(maximum)%"
    }

    private func telemetryTile(_ title: String, _ value: Int?, suffix: String,
                               symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value.map { "\($0)\(suffix)" } ?? "—")
                    .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private func thresholdEditor(_ title: String, current: Double?, unit: String,
                                 range: ClosedRange<Double>, step: Double,
                                 entertainment: Binding<Double>, expert: Binding<Double>,
                                 symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(tint)
                Spacer()
                Text(current.map { thresholdValue($0, unit: unit) } ?? "当前 —")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            thresholdTrack(current: current, range: range,
                           entertainment: entertainment.wrappedValue,
                           expert: expert.wrappedValue)

            HStack(spacing: 14) {
                thresholdSlider("娱乐", value: entertainment, range: range, step: step,
                                unit: unit, tint: .purple)
                thresholdSlider("专家", value: expert, range: range, step: step,
                                unit: unit, tint: .orange)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private func thresholdTrack(current: Double?, range: ClosedRange<Double>,
                                entertainment: Double, expert: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let lower = range.lowerBound
            let span = range.upperBound - lower
            let entertainmentX = width * (entertainment - lower) / span
            let expertX = width * (expert - lower) / span
            let currentX = current.map { width * (min(max($0, lower), range.upperBound) - lower) / span }

            ZStack(alignment: .leading) {
                Capsule().fill(Color.blue.opacity(0.22))
                Capsule().fill(Color.purple.opacity(0.34))
                    .frame(width: max(0, expertX - entertainmentX))
                    .offset(x: entertainmentX)
                Capsule().fill(Color.orange.opacity(0.48))
                    .frame(width: max(0, width - expertX))
                    .offset(x: expertX)
                if let currentX {
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.primary.opacity(0.45), lineWidth: 2))
                        .shadow(radius: 2)
                        .offset(x: min(max(currentX - 6, 0), width - 12))
                }
            }
        }
        .frame(height: 12)
    }

    private func thresholdSlider(_ title: String, value: Binding<Double>,
                                 range: ClosedRange<Double>, step: Double,
                                 unit: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Spacer()
                Text(thresholdValue(value.wrappedValue, unit: unit))
                    .font(.caption.monospacedDigit())
            }
            Slider(value: value, in: range, step: step).tint(tint)
        }
    }

    private func thresholdValue(_ value: Double, unit: String) -> String {
        unit == "W" ? String(format: "%.1f %@", value, unit) :
            String(format: "%.0f %@", value, unit)
    }

    private func smartThresholdBinding(_ keyPath: WritableKeyPath<SmartSwitchThresholds, Double>) -> Binding<Double> {
        Binding {
            manager.smartThresholds[keyPath: keyPath]
        } set: { value in
            manager.updateSmartThresholds { $0[keyPath: keyPath] = value }
        }
    }

    private func powerTile(_ title: String, _ value: Int?, symbol: String, tint: Color) -> some View {
        let safeValue = Double(min(max(value ?? 0, 0), 100))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(tint)
                Spacer()
                Text(value.map { "\($0)%" } ?? "—")
                    .font(.title3.bold().monospacedDigit())
            }
            ProgressView(value: safeValue, total: 100)
                .tint(tint)
            Text(powerDescription(value))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private func feedbackCard(_ title: String, symbol: String, tint: Color,
                              target: Int?, confirmed: Int?, output: Int?, demand: Int?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            HStack(spacing: 18) {
                compactValue("已发送", target)
                compactValue("设备目标", confirmed)
                compactValue("内部通道", output)
                compactValue("内部调度", demand)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private func compactValue(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.map { "\($0)%" } ?? "—")
                .font(.headline.monospacedDigit())
        }
    }

    private func metricTile(_ title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline.monospacedDigit())
            }
            Spacer()
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusPill(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func disclosureLabel(_ title: String, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(tint)
    }

    private func powerDescription(_ value: Int?) -> String {
        guard let value else { return "等待设备数据" }
        switch value {
        case 0: return "当前暂停"
        case 1..<35: return "低负载"
        case 35..<70: return "中等负载"
        default: return "高负载"
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

    private func profileSlider(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                               symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(title).frame(width: 104, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .tint(tint)
            Text("\(value.wrappedValue)%")
                .font(.body.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func parameterStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                                  step: Int = 1, suffix: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(title)
            Spacer()
            Stepper("\(value.wrappedValue)\(suffix)", value: value, in: range, step: step)
                .monospacedDigit()
        }
    }

    private func targetSlider(_ title: String, value: Binding<Double>, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(title).frame(width: 50, alignment: .leading)
            Slider(value: value, in: 42...100, step: 1)
                .tint(tint)
                .accessibilityLabel("\(title)目标强度")
            Text("\(Int(value.wrappedValue))%")
                .font(.body.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
        }
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let content: Content

    init(title: String, subtitle: String, symbol: String, tint: Color,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.bold())
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            content
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}
