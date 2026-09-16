import CoreFoundation
import Foundation
import IOKit

struct HostSensorSnapshot: Equatable {
    var cpuPower: Double?
    var systemPower: Double?
    var cpuTemperature: Double?
    var fanRPM: Double?
    var sampledAt = Date()

    var hasAnyValue: Bool {
        cpuPower != nil || cpuTemperature != nil || fanRPM != nil
    }
}

struct SmartSwitchThresholds: Codable, Equatable {
    var entertainmentPower = 20.0
    var expertPower = 35.0
    var entertainmentTemperature = 60.0
    var expertTemperature = 75.0
    var entertainmentFanRPM = 2_500.0
    var expertFanRPM = 4_000.0

    static let defaults = SmartSwitchThresholds()

    func normalized() -> SmartSwitchThresholds {
        var value = self
        value.entertainmentPower = min(max(value.entertainmentPower, 3), 95)
        value.expertPower = min(max(value.expertPower, value.entertainmentPower + 1), 100)
        value.entertainmentTemperature = min(max(value.entertainmentTemperature, 35), 99)
        value.expertTemperature = min(max(value.expertTemperature, value.entertainmentTemperature + 1), 100)
        value.entertainmentFanRPM = min(max(value.entertainmentFanRPM, 1_000), 7_900)
        value.expertFanRPM = min(max(value.expertFanRPM, value.entertainmentFanRPM + 100), 8_000)
        return value
    }
}

final class HostMonitor: ObservableObject {
    @Published private(set) var snapshot = HostSensorSnapshot()
    @Published private(set) var status = "正在准备本机传感器…"

    private let reader = HostSensorReader()
    private let queue = DispatchQueue(label: "local.codex.dragonk.host-sensors", qos: .utility)
    private var timer: Timer?
    private var isSampling = false
    private var recentSamples: [HostSensorSnapshot] = []

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard !isSampling else { return }
        isSampling = true
        queue.async { [weak self] in
            guard let self else { return }
            let next = self.reader.read()
            DispatchQueue.main.async {
                let smoothed = self.smoothed(next)
                self.snapshot = smoothed
                let count = [smoothed.cpuPower, smoothed.cpuTemperature, smoothed.fanRPM].compactMap { $0 }.count
                self.status = count == 3 ? "本机传感器实时采集中" :
                    (count > 0 ? "部分传感器可用；不可用指标不会参与切档" : "本机未返回可用传感器")
                self.isSampling = false
            }
        }
    }

    private func smoothed(_ sample: HostSensorSnapshot) -> HostSensorSnapshot {
        recentSamples.append(sample)
        recentSamples = recentSamples.filter { sample.sampledAt.timeIntervalSince($0.sampledAt) <= 6 }

        func average(_ values: [Double?]) -> Double? {
            let available = values.compactMap { $0 }
            guard !available.isEmpty else { return nil }
            return available.reduce(0, +) / Double(available.count)
        }

        return HostSensorSnapshot(
            cpuPower: average(recentSamples.map(\.cpuPower)),
            systemPower: average(recentSamples.map(\.systemPower)),
            cpuTemperature: average(recentSamples.map(\.cpuTemperature)),
            fanRPM: average(recentSamples.map(\.fanRPM)),
            sampledAt: sample.sampledAt
        )
    }
}

private final class HostSensorReader {
    private let hid = HIDSensorReader()
    private let smc = SMCReader()

    func read() -> HostSensorSnapshot {
        let thermal = hid.values(usagePage: 0xff00, usage: 5, eventType: 15, field: 0x0f0000)
        let currents = hid.values(usagePage: 0xff08, usage: 2, eventType: 25, field: 0x190000)
        let voltages = hid.values(usagePage: 0xff08, usage: 3, eventType: 25, field: 0x190000)

        let cpuThermal = thermal.filter { Self.isCPUSensor($0.name) }.map(\.value).max()
            ?? thermal.first?.value
            ?? smc.cpuTemperature()
        let cpuPower = Self.cpuPower(currents: currents, voltages: voltages) ?? smc.cpuPower()

        return HostSensorSnapshot(
            cpuPower: Self.valid(cpuPower, in: 0...150),
            systemPower: Self.valid(smc.systemPower(), in: 0...250),
            cpuTemperature: Self.valid(cpuThermal, in: 10...125),
            fanRPM: Self.valid(smc.averageFanRPM(), in: 0...20_000),
            sampledAt: Date()
        )
    }

    private static func cpuPower(currents: [HIDReading], voltages: [HIDReading]) -> Double? {
        var voltageByName: [String: Double] = [:]
        for reading in voltages {
            voltageByName[normalizedName(reading.name)] = reading.value
        }
        var railPowers: [Double] = []

        for current in currents where isCPUSensor(current.name) {
            let name = normalizedName(current.name)
            guard let voltage = voltageByName[name] ?? closestVoltage(to: name, in: voltageByName) else { continue }
            let amps = abs(current.value) > 100 ? current.value / 1_000 : current.value
            let volts = abs(voltage) > 100 ? voltage / 1_000 : voltage
            let watts = abs(amps * volts)
            if watts.isFinite, watts > 0.01, watts < 200 { railPowers.append(watts) }
        }
        return railPowers.isEmpty ? nil : railPowers.reduce(0, +)
    }

    private static func closestVoltage(to name: String, in values: [String: Double]) -> Double? {
        values.first { candidate, _ in
            candidate.contains(name) || name.contains(candidate)
        }?.value
    }

    private static func normalizedName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "current", with: "")
            .replacingOccurrences(of: "voltage", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private static func isCPUSensor(_ name: String) -> Bool {
        let value = name.lowercased()
        return value.contains("cpu") || value.contains("processor") ||
            value.contains("p-core") || value.contains("e-core") || value.contains("package")
    }

    private static func valid(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }
}

private struct HIDReading {
    let name: String
    let value: Double
}

private typealias HIDClient = UnsafeMutableRawPointer
private typealias HIDService = UnsafeMutableRawPointer
private typealias HIDEvent = UnsafeMutableRawPointer

@_silgen_name("IOHIDEventSystemClientCreate")
private func HIDEventSystemClientCreate(_ allocator: CFAllocator?) -> HIDClient?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func HIDEventSystemClientSetMatching(_ client: HIDClient, _ matching: CFDictionary)
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func HIDEventSystemClientCopyServices(_ client: HIDClient) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func HIDServiceClientCopyEvent(_ service: HIDService, _ type: Int64,
                                       _ options: Int32, _ timestamp: Int64) -> HIDEvent?
@_silgen_name("IOHIDEventGetFloatValue")
private func HIDEventGetFloatValue(_ event: HIDEvent, _ field: Int32) -> Double
@_silgen_name("IOHIDServiceClientCopyProperty")
private func HIDServiceClientCopyProperty(_ service: HIDService, _ property: CFString) -> Unmanaged<AnyObject>?

private final class HIDSensorReader {
    func values(usagePage: Int, usage: Int, eventType: Int64, field: Int32) -> [HIDReading] {
        guard let client = HIDEventSystemClientCreate(kCFAllocatorDefault) else { return [] }
        defer { Unmanaged<AnyObject>.fromOpaque(client).release() }

        let matching = ["PrimaryUsagePage": usagePage, "PrimaryUsage": usage] as CFDictionary
        HIDEventSystemClientSetMatching(client, matching)
        guard let copied = HIDEventSystemClientCopyServices(client) else { return [] }
        let services = copied.takeRetainedValue()

        return (0..<CFArrayGetCount(services)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(services, index) else { return nil }
            let service = UnsafeMutableRawPointer(mutating: pointer)
            guard let event = HIDServiceClientCopyEvent(service, eventType, 0, 0) else { return nil }
            defer { Unmanaged<AnyObject>.fromOpaque(event).release() }
            let value = HIDEventGetFloatValue(event, field)
            guard value.isFinite else { return nil }
            let name = HIDServiceClientCopyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String ?? "sensor-\(index)"
            return HIDReading(name: name, value: value)
        }
    }
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private final class SMCReader {
    private struct Value {
        let type: String
        let bytes: [UInt8]
    }

    private var connection: io_connect_t = 0

    init() {
        guard let matching = IOServiceMatching("AppleSMC") else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            connection = 0
            return
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func averageFanRPM() -> Double? {
        let count = Int(read("FNum")?.bytes.first ?? 0)
        let values = (0..<max(count, 1)).compactMap { index -> Double? in
            guard let value = read("F\(index)Ac") else { return nil }
            return number(value)
        }.filter { $0 > 0 }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    func cpuTemperature() -> Double? {
        for key in ["TC0D", "TC0P", "TC0H"] {
            guard let stored = read(key) else { continue }
            let value = number(stored)
            if (10...125).contains(value) { return value }
        }
        return nil
    }

    func cpuPower() -> Double? {
        for key in ["PCPT", "PCTR", "PC0C", "PCAC", "PCAM", "PCPC"] {
            guard let stored = read(key) else { continue }
            let value = number(stored)
            if (0.05...150).contains(value) { return value }
        }
        return nil
    }

    func systemPower() -> Double? {
        for key in ["PSTR", "PDTR"] {
            guard let stored = read(key) else { continue }
            let value = number(stored)
            if (0.05...250).contains(value) { return value }
        }
        return nil
    }

    private func number(_ value: Value) -> Double {
        let bytes = value.bytes
        switch value.type {
        case "flt " where bytes.count >= 4:
            let little = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 |
                UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let big = UInt32(bytes[3]) | UInt32(bytes[2]) << 8 |
                UInt32(bytes[1]) << 16 | UInt32(bytes[0]) << 24
            let candidates = [Double(Float(bitPattern: little)), Double(Float(bitPattern: big))]
            return candidates.first { $0.isFinite && (0.01...20_000).contains($0) } ?? .nan
        case let type where type.hasPrefix("sp") && bytes.count >= 2:
            guard let fractionBits = fixedPointFractionBits(type) else { return .nan }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / pow(2, Double(fractionBits))
        case let type where type.hasPrefix("fp") && bytes.count >= 2:
            guard let fractionBits = fixedPointFractionBits(type) else { return .nan }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(raw) / pow(2, Double(fractionBits))
        case "ui16" where bytes.count >= 2:
            return Double((Int(bytes[0]) << 8) + Int(bytes[1]))
        case "ui32" where bytes.count >= 4:
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 |
                          UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default:
            return .nan
        }
    }

    private func fixedPointFractionBits(_ type: String) -> Int? {
        guard type.count >= 4 else { return nil }
        let index = type.index(type.startIndex, offsetBy: 3)
        return Int(String(type[index]), radix: 16)
    }

    private func read(_ key: String) -> Value? {
        guard connection != 0, key.utf8.count == 4 else { return nil }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = key.utf8.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) }
        input.data8 = 9
        guard call(input: &input, output: &output) else { return nil }
        let dataSize = output.keyInfo.dataSize
        let dataType = output.keyInfo.dataType
        input.keyInfo.dataSize = dataSize
        input.data8 = 5
        guard call(input: &input, output: &output) else { return nil }
        let size = min(Int(dataSize), 32)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        let typeBytes = [UInt8(dataType >> 24), UInt8((dataType >> 16) & 0xff),
                         UInt8((dataType >> 8) & 0xff), UInt8(dataType & 0xff)]
        return Value(type: String(bytes: typeBytes, encoding: .ascii) ?? "", bytes: bytes)
    }

    private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> Bool {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(connection, 2, inputPointer, inputSize,
                                          outputPointer, &outputSize)
            }
        }
        return result == KERN_SUCCESS && output.result == 0
    }
}
