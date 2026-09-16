import CoreBluetooth
import Foundation

enum DragonKProtocol {
    static let targetName = "DragonK-XAR1500236"
    static let serviceUUID = CBUUID(string: "AE00")
    static let writeUUID = CBUUID(string: "AE01")
    static let notifyUUID = CBUUID(string: "AE02")

    enum Feedback {
        case water(target: Int, running: Int)
        case fan(target: Int, running: Int)
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
        guard data.count >= 17 else { return nil }
        switch data[0] {
        case 0x4F: return .water(target: Int(data[16]), running: Int(data[7]))
        case 0x49: return .fan(target: Int(data[12]), running: Int(data[7]))
        default: return nil
        }
    }
}

let targetName = DragonKProtocol.targetName

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
