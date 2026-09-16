import CoreBluetooth
import Foundation

enum DragonKControlMode: String, CaseIterable, Identifiable {
    case document
    case entertainment
    case expert
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .document: return "文档模式"
        case .entertainment: return "娱乐模式"
        case .expert: return "专家模式"
        case .manual: return "固定输出"
        }
    }

    var temperatureDifference: Int? {
        switch self {
        case .document: return 2
        case .entertainment: return 5
        case .expert: return 10
        case .manual: return nil
        }
    }

    var opcode: UInt8? {
        switch self {
        case .document: return 0x81
        case .entertainment: return 0x82
        case .expert: return 0x83
        case .manual: return nil
        }
    }
}

enum DragonKCoolingControl: Int, Codable, CaseIterable, Identifiable {
    case temperatureDifference = 1
    case temperature = 2
    case power = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .temperatureDifference: return "温差控制"
        case .temperature: return "温度控制"
        case .power: return "功率控制"
        }
    }

    var valueLabel: String {
        switch self {
        case .temperatureDifference: return "目标温差"
        case .temperature: return "目标温度"
        case .power: return "冷核功率"
        }
    }

    var allowedValues: ClosedRange<Int> {
        switch self {
        case .temperatureDifference: return 0...20
        case .temperature: return 0...60
        case .power: return 0...100
        }
    }
}

struct DragonKProfileSettings: Codable, Equatable {
    var control: DragonKCoolingControl
    var controlValue: Int
    var pumpFixed: Int
    var fanMinimum: Int
    var fanMaximum: Int
    var fanCurve: Int

    static func defaults(for mode: DragonKControlMode) -> Self {
        Self(control: .temperatureDifference,
             controlValue: mode.temperatureDifference ?? 2,
             pumpFixed: 42,
             fanMinimum: 20,
             fanMaximum: 50,
             fanCurve: 80)
    }

    func normalized() -> Self {
        var copy = self
        copy.controlValue = min(max(copy.controlValue, copy.control.allowedValues.lowerBound),
                                copy.control.allowedValues.upperBound)
        copy.pumpFixed = min(max(copy.pumpFixed, 42), 100)
        copy.fanMinimum = min(max(copy.fanMinimum, 0), 100)
        copy.fanMaximum = min(max(copy.fanMaximum, copy.fanMinimum), 100)
        copy.fanCurve = min(max(copy.fanCurve, 0), 500)
        return copy
    }
}

struct DragonKTelemetry: Equatable {
    let machineType: Int
    let leftCondensationTemperature: Int
    let rightCondensationTemperature: Int
    let environmentTemperature: Int
    let waterTemperature: Int
    let coldCoreA: Int
    let coldCoreB: Int
    let coldCoreC: Int
    let pumpPower: Int
    let fanPower: Int
}

enum DragonKProtocol {
    static let targetName = "DragonK-XAR1500236"
    static let serviceUUID = CBUUID(string: "AE00")
    static let writeUUID = CBUUID(string: "AE01")
    static let notifyUUID = CBUUID(string: "AE02")

    enum Feedback {
        case water(target: Int, output: Int, demand: Int)
        case fan(target: Int, output: Int, demand: Int)
        case telemetry(DragonKTelemetry)
        case profile(mode: DragonKControlMode, settings: DragonKProfileSettings)
    }

    static func profilePacket(_ mode: DragonKControlMode,
                              settings: DragonKProfileSettings) -> Data? {
        guard let opcode = mode.opcode else { return nil }
        let settings = settings.normalized()

        // DragonKing 1.2.0 and the vendor mini-program both use the same
        // 20-byte layout for modes 1...3:
        //   [3]  cooling logic 1 = temperature-difference control
        //   [4]  target difference
        //   [5]  pump logic 2 = fixed speed, [7] = 42
        //   [10] fan logic 1 = linear curve
        //   [11]/[12] fan maximum/minimum = 50/20
        //   [13...14] fan curve coefficient = 80
        return Data([opcode, 0x00, 0x03, UInt8(settings.control.rawValue), UInt8(settings.controlValue),
                     0x02, 0x00, UInt8(settings.pumpFixed), 0x00, 0x00,
                     0x01, UInt8(settings.fanMaximum), UInt8(settings.fanMinimum),
                     UInt8((settings.fanCurve >> 8) & 0xFF), UInt8(settings.fanCurve & 0xFF),
                     0x00, 0x00, 0x00, 0x00, 0x00])
    }

    static var connectionHandshakePackets: [Data] {
        [Data([0x4E, 0x00, 0x01, 0x01]),
         Data([0x81, 0x00, 0x00]),
         Data([0x82, 0x00, 0x00]),
         Data([0x83, 0x00, 0x00])]
    }

    static func setTargetsPacket(water: Int, fan: Int) -> Data? {
        guard (42...100).contains(water), (42...100).contains(fan) else { return nil }
        // Captured from the installed DragonKing 1.2.0 app. Independent writes
        // to the real device confirmed byte 7 = water and byte 12 = fan.
        var bytes: [UInt8] = [0x84,0x00,0x02,0x01,0x05,0x02,0x00,0x2A,0x00,0x00,
                              0x02,0x00,0x2A,0x00,0x00,0x04,0x00,0x1E,0x00,0x00]
        bytes[7] = UInt8(water)
        bytes[12] = UInt8(fan)
        return Data(bytes)
    }

    static func feedback(from data: Data) -> Feedback? {
        guard data.count >= 18 else { return nil }
        switch data[0] {
        // 49/4F byte 7 is an internal controller-channel value rather than the
        // physical pump/fan power reported in C0[13]/C0[14]. The official app
        // and live traces can show 49[7] = 100 while C0 fan power remains 37.
        case 0x4F: return .water(target: Int(data[17]), output: Int(data[7]), demand: Int(data[9]))
        case 0x49: return .fan(target: Int(data[12]), output: Int(data[7]), demand: Int(data[6]))
        case 0xC0:
            guard data.count >= 18 else { return nil }
            return .telemetry(DragonKTelemetry(
                machineType: Int(data[2]),
                leftCondensationTemperature: signed(data[4]),
                rightCondensationTemperature: signed(data[5]),
                environmentTemperature: signed(data[8]),
                waterTemperature: signed(data[9]),
                coldCoreA: Int(data[10]),
                coldCoreB: Int(data[11]),
                coldCoreC: Int(data[12]),
                pumpPower: Int(data[13]),
                fanPower: Int(data[14])))
        case 0x81, 0x82, 0x83:
            guard data.count >= 15,
                  let mode = mode(forOpcode: data[0]),
                  let control = DragonKCoolingControl(rawValue: Int(data[3])) else { return nil }
            let settings = DragonKProfileSettings(
                control: control,
                controlValue: Int(data[4]),
                pumpFixed: Int(data[7]),
                fanMinimum: Int(data[12]),
                fanMaximum: Int(data[11]),
                fanCurve: Int(data[13]) << 8 | Int(data[14]))
            return .profile(mode: mode, settings: settings.normalized())
        default: return nil
        }
    }

    private static func signed(_ byte: UInt8) -> Int {
        Int(Int8(bitPattern: byte))
    }

    private static func mode(forOpcode opcode: UInt8) -> DragonKControlMode? {
        switch opcode {
        case 0x81: return .document
        case 0x82: return .entertainment
        case 0x83: return .expert
        default: return nil
        }
    }
}

let targetName = DragonKProtocol.targetName

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
