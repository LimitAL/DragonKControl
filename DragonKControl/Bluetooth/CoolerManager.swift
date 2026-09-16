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
    @Published var bluetoothState = "正在检测蓝牙…"
    @Published var connectionState = "未连接"
    @Published var discoveredName = ""
    @Published var rssi = ""
    @Published var rows: [CharacteristicRow] = []
    @Published var selectedID = ""
    @Published var confirmedWater: Int?
    @Published var confirmedFan: Int?
    @Published var runningWater: Int?
    @Published var runningFan: Int?
    @Published var requestedWater: Int?
    @Published var requestedFan: Int?
    @Published var statusMessage = "正在连接散热器。"
    @Published var log: [String] = []
    @Published var samples: [PowerSample] = []
    @Published var autoReconnect = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]
    private var scanning = false
    private var scanGeneration = 0
    private var wantsConnection = true

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        note("程序已启动，目标设备：\(targetName)")
    }

    var isConnected: Bool { peripheral?.state == .connected }
    var canSend: Bool { isConnected && characteristics[selectedID] != nil }

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
        confirmedWater = nil
        confirmedFan = nil
        runningWater = nil
        runningFan = nil
        samples = []
        requestedWater = nil
        requestedFan = nil
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
        connectionState = "已连接 · 正在读取服务"
        statusMessage = "已连接。正在读取 BLE 服务和特征。"
        note("连接成功")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = "连接失败"
        statusMessage = error?.localizedDescription ?? "无法连接设备"
        note("连接失败：\(statusMessage)")
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        connectionState = "连接已断开"
        characteristics = [:]
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

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        let id = "\(characteristic.service?.uuid.uuidString ?? "")/\(characteristic.uuid.uuidString)"
        if let error { note("读取 \(id) 失败：\(error.localizedDescription)"); return }
        let data = characteristic.value ?? Data()
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
            case let .water(target, running):
                confirmedWater = target
                runningWater = running
                appendSample("水泵", value: running)
            case let .fan(target, running):
                confirmedFan = target
                runningFan = running
                appendSample("风扇", value: running)
            }
            if let requestedWater, let requestedFan,
               confirmedWater == requestedWater && confirmedFan == requestedFan {
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

    func sendTargets(water: Int, fan: Int) {
        guard let data = DragonKProtocol.setTargetsPacket(water: water, fan: fan) else { return }
        guard let peripheral, peripheral.state == .connected,
              let characteristic = characteristics[selectedID],
              let row = rows.first(where: { $0.id == selectedID }), row.writable else {
            statusMessage = "请先连接设备；官方写入特征 AE01 尚未就绪。"
            return
        }
        let props = characteristic.properties
        let type: CBCharacteristicWriteType = props.contains(.write) ? .withResponse : .withoutResponse
        let maxLength = peripheral.maximumWriteValueLength(for: type)
        guard data.count <= maxLength else {
            statusMessage = "指令长 \(data.count) 字节，超过此特征的单次写入上限 \(maxLength) 字节。"
            return
        }
        peripheral.writeValue(data, for: characteristic, type: type)
        requestedWater = water
        requestedFan = fan
        statusMessage = "已发送水泵 \(water)%、风扇 \(fan)% 目标值，等待设备反馈…"
        note("发送水泵 \(water)%、风扇 \(fan)% → \(selectedID)：\(data.hex)")
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
