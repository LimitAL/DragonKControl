import Charts
import SwiftUI

struct MainView: View {
    @StateObject private var manager = CoolerManager()
    @State private var waterLevel = 70.0
    @State private var fanLevel = 70.0

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

                GroupBox("散热强度") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("水泵与风扇可以分别设定目标值。设备会根据自身温控策略调整实时输出。")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button {
                                waterLevel = 42
                                fanLevel = 42
                                manager.enterStandby()
                            } label: {
                                Label("进入待机 · 42/42", systemImage: "pause.circle.fill")
                            }
                            Button {
                                manager.startRunning(water: Int(waterLevel), fan: Int(fanLevel))
                            } label: {
                                Label("运行 · 应用当前设定", systemImage: "play.circle.fill")
                            }
                        }
                        .disabled(!manager.canSend)
                        HStack(spacing: 12) {
                            presetButton("低", level: 42, symbol: "fanblades")
                            presetButton("中", level: 70, symbol: "fanblades.fill")
                            presetButton("高", level: 100, symbol: "wind")
                        }
                        targetSlider("水泵", value: $waterLevel)
                        targetSlider("风扇", value: $fanLevel)
                        Button("分别应用") {
                            manager.sendTargets(water: Int(waterLevel), fan: Int(fanLevel))
                        }.disabled(!manager.canSend)
                        HStack(spacing: 22) {
                            feedback("水泵", target: manager.requestedWater, confirmed: manager.confirmedWater, output: manager.waterOutput,
                                     demand: manager.waterDemand)
                            feedback("风扇", target: manager.requestedFan, confirmed: manager.confirmedFan, output: manager.fanOutput,
                                     demand: manager.fanDemand)
                        }
                        Text(manager.statusMessage).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(6)
                }

                GroupBox("运行趋势") {
                    VStack(alignment: .leading, spacing: 10) {
                        if manager.samples.isEmpty {
                            Text("连接后将在这里显示水泵与风扇的设备输出。")
                                .foregroundStyle(.secondary)
                        } else {
                            Chart(manager.samples) { sample in
                                LineMark(x: .value("时间", sample.timestamp),
                                         y: .value("设备输出", sample.value))
                                    .foregroundStyle(by: .value("通道", sample.channel))
                            }
                            .chartYScale(domain: 0...100)
                            .frame(height: 175)
                        }
                        Text("数值来自设备通知。控制器会按温控策略暂停某一路，因此运行时单路输出为 0 属于有效状态；数值尚未校准为 RPM。")
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
                        metric("最长通知间隔", String(format: "%.1f 秒", manager.longestNotificationGap))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
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
    }

    private func presetButton(_ title: String, level: Int, symbol: String) -> some View {
        Button {
            waterLevel = Double(level)
            fanLevel = Double(level)
            manager.sendLevel(level)
        } label: {
            Label("\(title)档 · \(level)%", systemImage: symbol)
                .frame(maxWidth: .infinity).padding(.vertical, 9)
        }
        .disabled(!manager.canSend)
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
            Text("设备输出：\(output.map { "\($0)%" } ?? "—") · 调度：\(demand.map { "\($0)%" } ?? "—")")
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
