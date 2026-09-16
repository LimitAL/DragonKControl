import AppKit
import Charts
import SwiftUI

struct MenuBarLoadIcon: View {
    let value: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(lineWidth: 1)
            Text("\(value)%")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 34, height: 17)
        .accessibilityLabel("DragonK 综合负载 \(value)%")
    }
}

struct MenuBarPanel: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var manager: CoolerManager
    @ObservedObject private var hostMonitor: HostMonitor
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self.model = model
        manager = model.manager
        hostMonitor = model.hostMonitor
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                loadHeader
                hostSection
                coolerSection
                quickControls
            }
            .padding(14)
        }
        .frame(width: 370, height: 800)
        .background {
            LinearGradient(colors: [Color.indigo.opacity(0.22), Color.blue.opacity(0.06), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var loadHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(loadTint.opacity(0.18), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: Double(model.loadPercentage) / 100)
                        .stroke(loadTint,
                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(model.loadPercentage)%")
                        .font(.title3.bold().monospacedDigit())
                }
                .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 4) {
                    Text("综合负载")
                        .font(.title2.bold())
                    HStack(spacing: 7) {
                        Label(manager.controlMode.title, systemImage: modeSymbol)
                        Text("·")
                        Text(manager.operatingState.rawValue)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Label(manager.connectionState,
                          systemImage: manager.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(manager.isConnected ? .green : .orange)
                }
                Spacer()
            }

            Chart(model.loadHistory) { point in
                AreaMark(x: .value("时间", point.timestamp),
                         y: .value("负载", point.value))
                    .foregroundStyle(LinearGradient(colors: [loadTint.opacity(0.35), .clear],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", point.timestamp),
                         y: .value("负载", point.value))
                    .foregroundStyle(loadTint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 70)
        }
        .panelCard(tint: loadTint)
    }

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelTitle("本机", symbol: "macbook", tint: .blue)
            LazyVGrid(columns: twoColumns, spacing: 8) {
                compactMetric("CPU 封装", power(hostMonitor.snapshot.cpuPower), "bolt.fill", .orange)
                compactMetric("整机功率", power(hostMonitor.snapshot.systemPower), "powerplug.fill", .yellow)
                compactMetric("CPU 温度", temperature(hostMonitor.snapshot.cpuTemperature), "thermometer.high", .red)
                compactMetric("Mac 风扇", rpm(hostMonitor.snapshot.fanRPM), "fanblades.fill", .mint)
            }
        }
        .panelCard(tint: .blue)
    }

    private var coolerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                panelTitle("DragonK 散热器", symbol: "snowflake", tint: .cyan)
                Spacer()
                if !manager.rssi.isEmpty {
                    Text(manager.rssi).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: twoColumns, spacing: 8) {
                compactMetric("冷凝面", condensation, "snowflake", .cyan)
                compactMetric("水温", integerTemperature(manager.waterTemperature), "drop.fill", .teal)
                compactMetric("冷核最高", maximumColdCore, "cpu.fill", .indigo)
                compactMetric("水泵功率", percent(manager.telemetryPumpPower), "drop.circle.fill", .teal)
                compactMetric("设备风扇", percent(manager.telemetryFanPower), "fanblades.fill", .green)
                compactMetric("目标温度", integerTemperature(manager.setTemperature), "scope", .purple)
            }
        }
        .panelCard(tint: .cyan)
    }

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("智能切换", systemImage: "wand.and.stars")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { manager.smartSwitchEnabled },
                    set: { manager.setSmartSwitchEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            HStack(spacing: 7) {
                profileButton(.document, symbol: "doc.text.fill")
                profileButton(.entertainment, symbol: "play.rectangle.fill")
                profileButton(.expert, symbol: "gauge.with.dots.needle.67percent")
            }

            HStack(spacing: 8) {
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("打开主窗口", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    manager.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新扫描设备")
                .disabled(manager.isConnected || manager.bluetoothState != "蓝牙已开启")
            }
        }
        .panelCard(tint: .indigo)
    }

    private func profileButton(_ mode: DragonKControlMode, symbol: String) -> some View {
        Button {
            manager.applyProfile(mode)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                Text(mode.title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(manager.controlMode == mode ? .accentColor : .secondary)
        .disabled(!manager.canSend || manager.smartSwitchEnabled)
    }

    private func compactMetric(_ title: String, _ value: String,
                               _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 25, height: 25)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.semibold).monospacedDigit()).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private func panelTitle(_ title: String, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(tint)
    }

    private var twoColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    private var loadTint: Color {
        switch model.loadPercentage {
        case 0..<35: return .cyan
        case 35..<70: return .orange
        default: return .red
        }
    }

    private var modeSymbol: String {
        switch manager.controlMode {
        case .document: return "doc.text.fill"
        case .entertainment: return "play.rectangle.fill"
        case .expert: return "gauge.with.dots.needle.67percent"
        case .manual: return "slider.horizontal.3"
        }
    }

    private var condensation: String {
        switch (manager.leftCondensationTemperature, manager.rightCondensationTemperature) {
        case let (.some(left), .some(right)): return "\(left) / \(right)℃"
        case let (.some(value), .none), let (.none, .some(value)): return "\(value)℃"
        case (.none, .none): return "—"
        }
    }

    private var maximumColdCore: String {
        guard let value = [manager.coldCoreA, manager.coldCoreB, manager.coldCoreC]
            .compactMap({ $0 }).max() else { return "—" }
        return "\(value)%"
    }

    private func power(_ value: Double?) -> String {
        value.map { String(format: "%.1f W", $0) } ?? "—"
    }

    private func temperature(_ value: Double?) -> String {
        value.map { String(format: "%.1f℃", $0) } ?? "—"
    }

    private func rpm(_ value: Double?) -> String {
        value.map { String(format: "%.0f RPM", $0) } ?? "—"
    }

    private func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "—"
    }

    private func integerTemperature(_ value: Int?) -> String {
        value.map { "\($0)℃" } ?? "—"
    }
}

private extension View {
    func panelCard(tint: Color) -> some View {
        padding(12)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            }
    }
}
