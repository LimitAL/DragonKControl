import Combine
import Foundation

struct SystemLoadPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let value: Int
}

@MainActor
final class AppModel: ObservableObject {
    let manager: CoolerManager
    let hostMonitor: HostMonitor

    @Published private(set) var loadPercentage = 0
    @Published private(set) var loadHistory: [SystemLoadPoint] = []

    private var cancellables: Set<AnyCancellable> = []

    init() {
        manager = CoolerManager()
        hostMonitor = HostMonitor()

        hostMonitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.manager.evaluateSmartSwitch(snapshot)
                self.refreshLoad(using: snapshot, appendHistory: snapshot.hasAnyValue)
            }
            .store(in: &cancellables)

        manager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.objectWillChange.send()
                    self.refreshLoad(using: self.hostMonitor.snapshot, appendHistory: false)
                }
            }
            .store(in: &cancellables)

        hostMonitor.start()
    }

    deinit {
        hostMonitor.stop()
    }

    private func refreshLoad(using snapshot: HostSensorSnapshot, appendHistory: Bool) {
        let next = Self.calculateLoad(snapshot: snapshot, manager: manager)
        if loadPercentage != next { loadPercentage = next }
        guard appendHistory else { return }
        loadHistory.append(SystemLoadPoint(timestamp: Date(), value: next))
        if loadHistory.count > 90 { loadHistory.removeFirst(loadHistory.count - 90) }
    }

    private static func calculateLoad(snapshot: HostSensorSnapshot,
                                      manager: CoolerManager) -> Int {
        var weightedTotal = 0.0
        var availableWeight = 0.0

        func add(_ score: Double?, weight: Double) {
            guard let score, score.isFinite else { return }
            weightedTotal += min(max(score, 0), 1) * weight
            availableWeight += weight
        }

        let thresholds = manager.smartThresholds
        add(snapshot.cpuPower.map { $0 / max(thresholds.expertPower, 1) }, weight: 0.30)
        add(snapshot.cpuTemperature.map {
            ($0 - 35) / max(thresholds.expertTemperature - 35, 1)
        }, weight: 0.25)
        add(snapshot.fanRPM.map {
            ($0 - 1_000) / max(thresholds.expertFanRPM - 1_000, 100)
        }, weight: 0.15)

        if manager.isConnected {
            let coldCore = [manager.coldCoreA, manager.coldCoreB, manager.coldCoreC]
                .compactMap { $0 }.max()
            add(coldCore.map { Double($0) / 100 }, weight: 0.12)
            add(manager.telemetryPumpPower.map {
                (Double($0) - 42) / 58
            }, weight: 0.08)
            add(manager.telemetryFanPower.map { Double($0) / 100 }, weight: 0.10)
        }

        guard availableWeight > 0 else { return 0 }
        return Int((weightedTotal / availableWeight * 100).rounded())
    }
}
