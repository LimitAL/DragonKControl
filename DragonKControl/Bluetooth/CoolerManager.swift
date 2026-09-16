import AppKit
import CoreBluetooth
import SwiftUI

struct PowerSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let channel: String
    let value: Int
}

struct CharacteristicRow: Identifiable {
    let id: String
    let service: String
    let uuid: String
    let properties: String
    let value: String
    let writable: Bool
}

final class CoolerManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum OperatingState: String {
        case unknown = "等待设备状态"
        case standby = "待机"
        case running = "运行"
    }

    @Published var bluetoothState = "正在检测蓝牙…"
    @Published var connectionState = "未连接"
    @Published var discoveredName = ""
    @Published var rssi = ""
    @Published var rows: [CharacteristicRow] = []
    @Published var selectedID = ""
    @Published private(set) var canSend = false
    @Published var waterOutput: Int?
    @Published var fanOutput: Int?
    @Published var confirmedWater: Int?
    @Published var confirmedFan: Int?
    @Published var waterDemand: Int?
    @Published var fanDemand: Int?
    @Published var leftCondensationTemperature: Int?
    @Published var rightCondensationTemperature: Int?
    @Published var environmentTemperature: Int?
    @Published var waterTemperature: Int?
    @Published var setTemperature: Int?
    @Published var coldCoreA: Int?
    @Published var coldCoreB: Int?
    @Published var coldCoreC: Int?
    @Published var telemetryPumpPower: Int?
    @Published var telemetryFanPower: Int?
    @Published var machineType: Int?
    @Published var operatingState: OperatingState = .unknown
    @Published private(set) var controlMode = CoolerManager.savedControlMode()
    @Published private(set) var profileSettings = CoolerManager.savedProfiles()
    @Published private(set) var deviceProfileReadback: [DragonKControlMode: DragonKProfileSettings] = [:]
    @Published private(set) var requestedWater: Int? = CoolerManager.savedTarget(forKey: "desiredWater")
    @Published private(set) var requestedFan: Int? = CoolerManager.savedTarget(forKey: "desiredFan")
    @Published var statusMessage = "正在连接散热器。"
    @Published var log: [String] = []
    @Published var samples: [PowerSample] = []
    @Published var notificationCount = 0
    @Published var disconnectCount = 0
    @Published var reconnectCount = 0
    @Published var longestNotificationGap: TimeInterval = 0
    @Published var lastNotificationAt: Date?
    @Published var controlRefreshCount = 0
    @Published var protocolQueryCount = 0
    @Published var autoReconnect = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]
    private var scanning = false
    private var scanGeneration = 0
    private var wantsConnection = true
    private var hasConnectedOnce = false
    private var restoringAfterReconnect = false
    private var notificationReady = false
    private var didHandshakeThisConnection = false
    private var handshakeGeneration = 0
    private var controlTimer: Timer?
    private let controlInterval: TimeInterval = 1.5
#if DEBUG
    private var didScheduleDebugDisconnect = false
#endif

    private static func savedTarget(forKey key: String) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return (42...100).contains(value) ? value : 42
    }

    private static func savedControlMode() -> DragonKControlMode {
        guard let raw = UserDefaults.standard.string(forKey: "controlMode"),
              let mode = DragonKControlMode(rawValue: raw) else { return .document }
        return mode
    }

    private static func savedProfiles() -> [DragonKControlMode: DragonKProfileSettings] {
        var profiles: [DragonKControlMode: DragonKProfileSettings] = [:]
        for mode in [DragonKControlMode.document, .entertainment, .expert] {
            let key = "profile.\(mode.rawValue)"
            if let data = UserDefaults.standard.data(forKey: key),
               let stored = try? JSONDecoder().decode(DragonKProfileSettings.self, from: data) {
                profiles[mode] = stored.normalized()
            } else {
                profiles[mode] = .defaults(for: mode)
            }
        }
        return profiles
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        note("程序已启动，目标设备：\(targetName)")
    }

    var isConnected: Bool { peripheral?.state == .connected }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothState = "蓝牙已开启"
            note("蓝牙已开启")
            if wantsConnection { scan() }
        case .poweredOff:
            bluetoothState = "蓝牙已关闭；请在系统设置中开启"
            connectionState = "未连接"
            scanning = false
            scanGeneration += 1
        case .unauthorized:
            bluetoothState = "蓝牙权限未授权；请在隐私与安全性设置中允许"
        case .unsupported:
            bluetoothState = "此环境未提供可用蓝牙控制器"
        case .resetting:
            bluetoothState = "蓝牙正在重置"
        default:
            bluetoothState = "正在检测蓝牙…"
        }
        objectWillChange.send()
    }

    func scan() {
        guard central.state == .poweredOn else {
            statusMessage = bluetoothState
            return
        }
        guard !isConnected else { return }
        wantsConnection = true
        if scanning { central.stopScan() }
        scanGeneration += 1
        let generation = scanGeneration
        peripheral = nil
        rows = []
        characteristics = [:]
        selectedID = ""
        canSend = false
        waterOutput = nil
        fanOutput = nil
        confirmedWater = nil
        confirmedFan = nil
        waterDemand = nil
        fanDemand = nil
        leftCondensationTemperature = nil
        rightCondensationTemperature = nil
        environmentTemperature = nil
        waterTemperature = nil
        setTemperature = nil
        coldCoreA = nil
        coldCoreB = nil
        coldCoreC = nil
        telemetryPumpPower = nil
        telemetryFanPower = nil
        machineType = nil
        operatingState = .unknown
        samples = []
        connectionState = "正在扫描…"
        scanning = true
        central.scanForPeripherals(withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        note("开始扫描附近的 BLE 设备")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.scanning, self.scanGeneration == generation else { return }
            self.central.stopScan()
            self.scanning = false
            self.connectionState = "未找到设备"
            self.statusMessage = "20 秒内未发现 \(targetName)。请确认设备通电、处于蓝牙广播模式，并靠近 Mac。"
            self.note("扫描超时，未发现目标设备")
            self.scheduleReconnect()
        }
    }

    func disconnect() {
        wantsConnection = false
        stopControlLoop()
        handshakeGeneration += 1
        scanGeneration += 1
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        if scanning { central.stopScan(); scanning = false }
        connectionState = "未连接"
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name == targetName else { return }
        self.peripheral = peripheral
        discoveredName = name
        rssi = "\(RSSI) dBm"
        central.stopScan()
        scanning = false
        connectionState = "正在连接…"
        peripheral.delegate = self
        note("发现目标设备；标识 \(peripheral.identifier)，信号 \(RSSI) dBm")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        restoringAfterReconnect = hasConnectedOnce
        if restoringAfterReconnect { reconnectCount += 1 }
        hasConnectedOnce = true
        notificationReady = false
        didHandshakeThisConnection = false
        handshakeGeneration += 1
        connectionState = "已连接 · 正在读取服务"
        statusMessage = "已连接。正在读取 BLE 服务和特征。"
        note("连接成功")
        peripheral.discoverServices(nil)
#if DEBUG
        scheduleDebugDisconnectIfRequested(peripheral)
#endif
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = "连接失败"
        statusMessage = error?.localizedDescription ?? "无法连接设备"
        note("连接失败：\(statusMessage)")
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        disconnectCount += 1
        stopControlLoop()
        handshakeGeneration += 1
        connectionState = "连接已断开"
        characteristics = [:]
        canSend = false
        note("设备断开：\(error?.localizedDescription ?? "正常断开")")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard wantsConnection, autoReconnect, central.state == .poweredOn else { return }
        connectionState = "正在重连…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.wantsConnection, self.autoReconnect,
                  self.central.state == .poweredOn, !self.isConnected, !self.scanning else { return }
            self.scan()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { note("读取服务失败：\(error.localizedDescription)"); return }
        for service in peripheral.services ?? [] {
            note("服务 \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
        if (peripheral.services ?? []).isEmpty { statusMessage = "设备没有暴露 BLE 服务。它可能使用经典蓝牙协议。" }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error { note("读取特征失败：\(error.localizedDescription)"); return }
        for characteristic in service.characteristics ?? [] {
            let props = characteristic.properties
            let id = "\(service.uuid.uuidString)/\(characteristic.uuid.uuidString)"
            let names = [
                props.contains(.read) ? "读" : nil,
                props.contains(.write) ? "写" : nil,
                props.contains(.writeWithoutResponse) ? "无响应写" : nil,
                props.contains(.notify) ? "通知" : nil,
                props.contains(.indicate) ? "指示" : nil
            ].compactMap { $0 }.joined(separator: " · ")
            let writable = props.contains(.write) || props.contains(.writeWithoutResponse)
            characteristics[id] = characteristic
            rows.append(CharacteristicRow(id: id, service: service.uuid.uuidString,
                uuid: characteristic.uuid.uuidString, properties: names, value: "", writable: writable))
            note("特征 \(id) [\(names)]")
            if service.uuid == DragonKProtocol.serviceUUID &&
               characteristic.uuid == DragonKProtocol.writeUUID && writable {
                selectedID = id
                canSend = true
                activateProtocolIfReady()
            }
            if props.contains(.read) { peripheral.readValue(for: characteristic) }
            if props.contains(.notify) || props.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        connectionState = "已连接"
        statusMessage = selectedID.isEmpty ? "未找到官方协议的 AE00 / AE01 写入特征。" :
            "已识别官方协议，可以调节水泵与风扇目标值。"
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            note("订阅 \(characteristic.uuid.uuidString) 失败：\(error.localizedDescription)")
            return
        }
        guard characteristic.uuid == DragonKProtocol.notifyUUID,
              characteristic.isNotifying else { return }
        notificationReady = true
        note("AE02 实时通知已启用")
        activateProtocolIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        let id = "\(characteristic.service?.uuid.uuidString ?? "")/\(characteristic.uuid.uuidString)"
        if let error { note("读取 \(id) 失败：\(error.localizedDescription)"); return }
        let data = characteristic.value ?? Data()
        let now = Date()
        if let lastNotificationAt {
            longestNotificationGap = max(longestNotificationGap, now.timeIntervalSince(lastNotificationAt))
        }
        lastNotificationAt = now
        notificationCount += 1
        let value = data.hex
        if let index = rows.firstIndex(where: { $0.id == id }) {
            let old = rows[index]
            rows[index] = CharacteristicRow(id: old.id, service: old.service, uuid: old.uuid,
                properties: old.properties, value: value, writable: old.writable)
        }
        note("收到 \(id)：\(value)")
        if characteristic.uuid == DragonKProtocol.notifyUUID,
           let feedback = DragonKProtocol.feedback(from: data) {
            switch feedback {
            case let .water(target, output, demand):
                confirmedWater = target
                waterOutput = output
                waterDemand = demand
                appendSample("水泵", value: output)
            case let .fan(target, output, demand):
                confirmedFan = target
                fanOutput = output
                fanDemand = demand
                appendSample("风扇", value: output)
            case let .telemetry(telemetry):
                machineType = telemetry.machineType
                leftCondensationTemperature = telemetry.leftCondensationTemperature
                rightCondensationTemperature = telemetry.rightCondensationTemperature
                environmentTemperature = telemetry.environmentTemperature
                waterTemperature = telemetry.waterTemperature
                coldCoreA = telemetry.coldCoreA
                coldCoreB = telemetry.coldCoreB
                coldCoreC = telemetry.coldCoreC
                telemetryPumpPower = telemetry.pumpPower
                telemetryFanPower = telemetry.fanPower
                if controlMode != .manual,
                   let settings = profileSettings[controlMode] {
                    switch settings.control {
                    case .temperatureDifference:
                        setTemperature = telemetry.environmentTemperature - settings.controlValue
                    case .temperature:
                        setTemperature = settings.controlValue
                    case .power:
                        setTemperature = nil
                    }
                    statusMessage = "设备正在\(controlMode.title)运行；已收到 C0 实时状态。"
                }
            case let .profile(mode, settings):
                deviceProfileReadback[mode] = settings
                note("设备回报\(mode.title)配置：\(profileSummary(mode, settings: settings))")
            }
            updateOperatingState()
            if controlMode == .manual,
               let requestedWater, let requestedFan,
               confirmedWater == requestedWater, confirmedFan == requestedFan {
                statusMessage = "设备已确认水泵 \(requestedWater)%、风扇 \(requestedFan)% 的目标值。"
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            statusMessage = "写入失败：\(error.localizedDescription)"
            note(statusMessage)
        } else {
            statusMessage = "设备确认了 BLE 写入；请观察散热器是否切换强度。"
            note("设备确认写入 \(characteristic.uuid.uuidString)")
        }
    }

    func sendLevel(_ level: Int) {
        sendTargets(water: level, fan: level)
    }

    func applyProfile(_ mode: DragonKControlMode) {
        guard mode != .manual else { return }
        controlMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "controlMode")
        writeActiveConfiguration(reason: "用户切换到\(mode.title)", announce: true)
        startControlLoop(restoring: false, sendImmediately: false)
        updateOperatingState()
    }

    func settings(for mode: DragonKControlMode) -> DragonKProfileSettings {
        profileSettings[mode] ?? .defaults(for: mode)
    }

    func updateProfile(_ mode: DragonKControlMode,
                       _ update: (inout DragonKProfileSettings) -> Void) {
        guard mode != .manual else { return }
        var settings = self.settings(for: mode)
        update(&settings)
        settings = settings.normalized()
        profileSettings[mode] = settings
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "profile.\(mode.rawValue)")
        }
    }

    func enterStandby() {
        sendTargets(water: 42, fan: 42)
        statusMessage = "已请求待机（设备安全最低档 42/42），等待设备确认…"
    }

    func startRunning(water: Int, fan: Int) {
        sendTargets(water: water, fan: fan)
    }

    func sendTargets(water: Int, fan: Int) {
        controlMode = .manual
        UserDefaults.standard.set(controlMode.rawValue, forKey: "controlMode")
        rememberTargets(water: water, fan: fan)
        writeActiveConfiguration(reason: "用户设置固定输出", announce: true)
        startControlLoop(restoring: false, sendImmediately: false)
    }

    private func writeActiveConfiguration(reason: String, announce: Bool) {
        let data: Data?
        let summary: String
        switch controlMode {
        case .document, .entertainment, .expert:
            let settings = settings(for: controlMode)
            data = DragonKProtocol.profilePacket(controlMode, settings: settings)
            summary = profileSummary(controlMode, settings: settings)
        case .manual:
            guard let water = requestedWater, let fan = requestedFan else { return }
            data = DragonKProtocol.setTargetsPacket(water: water, fan: fan)
            summary = "固定输出：水泵 \(water)%、风扇 \(fan)%"
        }
        guard let data else { return }
        guard writePacket(data, announceFailure: announce) else { return }
        controlRefreshCount += 1
        if announce {
            statusMessage = "已发送\(summary)，等待设备反馈…"
            note("\(reason)：\(summary) → \(selectedID)：\(data.hex)")
        }
    }

    private func writePacket(_ data: Data, announceFailure: Bool) -> Bool {
        guard let peripheral, peripheral.state == .connected,
              let characteristic = characteristics[selectedID],
              let row = rows.first(where: { $0.id == selectedID }), row.writable else {
            if announceFailure { statusMessage = "请先连接设备；官方写入特征 AE01 尚未就绪。" }
            return false
        }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ?
            .withResponse : .withoutResponse
        let maxLength = peripheral.maximumWriteValueLength(for: type)
        guard data.count <= maxLength else {
            if announceFailure {
                statusMessage = "指令长 \(data.count) 字节，超过此特征的单次写入上限 \(maxLength) 字节。"
            }
            return false
        }
        peripheral.writeValue(data, for: characteristic, type: type)
        return true
    }

    private func activateProtocolIfReady() {
        guard canSend, notificationReady, !didHandshakeThisConnection else { return }
        didHandshakeThisConnection = true
        let generation = handshakeGeneration
        for (index, packet) in DragonKProtocol.connectionHandshakePackets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.15) { [weak self] in
                guard let self, self.handshakeGeneration == generation, self.canSend else { return }
                if self.writePacket(packet, announceFailure: false) {
                    self.protocolQueryCount += 1
                    self.note("连接协议查询：\(packet.hex)")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, self.handshakeGeneration == generation, self.canSend else { return }
            self.startControlLoop(restoring: self.restoringAfterReconnect)
        }
    }

    private func profileSummary(_ mode: DragonKControlMode,
                                settings: DragonKProfileSettings) -> String {
        "\(mode.title)：\(settings.control.title) \(settings.controlValue)，水泵 \(settings.pumpFixed)，风扇自动 \(settings.fanMinimum)–\(settings.fanMaximum)，曲线 \(settings.fanCurve)"
    }

    private func rememberTargets(water: Int, fan: Int) {
        requestedWater = water
        requestedFan = fan
        UserDefaults.standard.set(water, forKey: "desiredWater")
        UserDefaults.standard.set(fan, forKey: "desiredFan")
    }

    private func startControlLoop(restoring: Bool, sendImmediately: Bool = true) {
        stopControlLoop()
        guard canSend else { return }
        if sendImmediately {
            writeActiveConfiguration(reason: restoring ? "重连恢复配置" : "恢复保存配置",
                                     announce: true)
        }
        guard controlMode == .manual else {
            note("官方温控模式仅在切换或重连后写入一次，避免重复初始化设备调度器")
            return
        }
        controlTimer = Timer.scheduledTimer(withTimeInterval: controlInterval, repeats: true) { [weak self] _ in
            guard let self, self.canSend else { return }
            self.writeActiveConfiguration(reason: "配置保活", announce: false)
        }
        note("已启动配置保活，每 \(controlInterval) 秒刷新一次")
    }

    private func stopControlLoop() {
        controlTimer?.invalidate()
        controlTimer = nil
    }

#if DEBUG
    private func scheduleDebugDisconnectIfRequested(_ peripheral: CBPeripheral) {
        guard !didScheduleDebugDisconnect,
              let raw = ProcessInfo.processInfo.environment["DRAGONK_TEST_DISCONNECT_AFTER"],
              let delay = TimeInterval(raw), delay > 0 else { return }
        didScheduleDebugDisconnect = true
        note("调试：将在 \(delay) 秒后模拟意外断开")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak peripheral] in
            guard let self, let peripheral, peripheral.state == .connected else { return }
            self.note("调试：触发一次 CoreBluetooth 连接中断")
            self.central.cancelPeripheralConnection(peripheral)
        }
    }
#endif

    private func updateOperatingState() {
        if controlMode != .manual {
            operatingState = .running
            return
        }
        guard let confirmedWater, let confirmedFan else {
            operatingState = .unknown
            return
        }
        // The official app labels the real device as standby at its 42/42
        // safety floor. Values above that floor are its running state.
        operatingState = confirmedWater > 42 || confirmedFan > 42 ? .running : .standby
    }

    func copyDiagnostics() {
        let report = (["DragonK Control 诊断", "目标：\(targetName)",
                       "蓝牙：\(bluetoothState)", "连接：\(connectionState)",
                       "设备：\(discoveredName)", "信号：\(rssi)",
                       "特征："] + rows.map { "\($0.id) [\($0.properties)] value=\($0.value)" } +
                      ["日志："] + log).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        statusMessage = "诊断信息已复制到剪贴板。"
    }

    private func note(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("\(stamp)  \(message)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private func appendSample(_ channel: String, value: Int) {
        guard (0...100).contains(value) else { return }
        samples.append(PowerSample(timestamp: Date(), channel: channel, value: value))
        if samples.count > 240 { samples.removeFirst(samples.count - 240) }
    }
}
