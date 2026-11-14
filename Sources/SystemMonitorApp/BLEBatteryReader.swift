import CoreBluetooth
import SystemMonitorCore

/// Battery level of connected Bluetooth LE keyboards and mice (Logitech MX Keys, MX Master ...)
/// through the standard GATT Battery Service, which macOS itself does not list. Opt-in: the first
/// read makes macOS ask for Bluetooth access. Each read connects briefly to every connected
/// device that offers a battery service, reads one number and disconnects. Nothing is sent anywhere.
@MainActor
final class BLEBatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    private var central: CBCentralManager?
    private var pending: [UUID: CBPeripheral] = [:]
    private var levels: [String: Int] = [:]
    private var onUpdate: (([DeviceBattery]) -> Void)?
    private var wantRead = false

    /// Starts a read; `onUpdate` receives every device found so far (called again as devices answer).
    func read(onUpdate: @escaping ([DeviceBattery]) -> Void) {
        self.onUpdate = onUpdate
        wantRead = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else if central?.state == .poweredOn { start() }
    }

    func stop() {
        wantRead = false
        for p in pending.values { central?.cancelPeripheralConnection(p) }
        pending = [:]
    }

    private func start() {
        guard wantRead, let central else { return }
        wantRead = false
        let found = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        Self.debug("connected with battery service: \(found.map { $0.name ?? "?" })")
        for p in found {
            pending[p.identifier] = p
            p.delegate = self
            central.connect(p)
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Self.debug("bluetooth state \(central.state.rawValue) auth \(CBCentralManager.authorization.rawValue)")
        Task { @MainActor in if central.state == .poweredOn { self.start() } }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in peripheral.discoverServices([Self.batteryService]) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in self.pending[peripheral.identifier] = nil }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) else {
                self.finish(peripheral); return
            }
            peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.batteryLevel }) else {
                self.finish(peripheral); return
            }
            peripheral.readValue(for: characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let byte = characteristic.value?.first {
                Self.debug("\(peripheral.name ?? "?") battery \(byte)")
                self.levels[peripheral.name ?? "Bluetooth device"] = Int(byte)
                self.onUpdate?(self.levels.map { DeviceBattery(name: $0.key, parts: [("", $0.value)]) }
                    .sorted { $0.name < $1.name })
            }
            self.finish(peripheral)
        }
    }

    nonisolated private static func debug(_ text: String) {
        if ProcessInfo.processInfo.environment["LANES_DEBUG_BLE"] != nil { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    }

    private func finish(_ peripheral: CBPeripheral) {
        pending[peripheral.identifier] = nil
        central?.cancelPeripheralConnection(peripheral)
    }
}
