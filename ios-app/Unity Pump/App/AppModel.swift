//
//  AppModel.swift
//  Unity Pump
//
//  Created by Emma Starkman on 2026-02-07.
//

import SwiftUI
import Foundation
import Combine
import CoreBluetooth

enum PumpState: String {
    case idle = "Idle"
    case delivering = "Delivering"
    case error = "Error"
}

enum DoseType: String {
    case auto = "Auto"
    case manual = "Manual"
}

enum GlucoseUnit: String, CaseIterable, Identifiable {
    case mgdl = "mg/dL"
    case mmoll = "mmol/L"

    var id: String { rawValue }
}

final class AppModel: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    @Published var isConnected: Bool = false
    @Published var lastUpdateTime: Date = Date()

    @Published var currentGlucoseMgdl: Int = 110
    @Published var glucoseHistory: [GlucosePoint] = []
    @Published var glucoseUnit: GlucoseUnit = .mgdl // store glucose unit

    // Pump
    @Published var pumpState: PumpState = .idle
    @Published var lastDoseUnits: Double = 0.0
    @Published var lastDoseTime: Date = Date()
    @Published var lastDoseType: DoseType = .auto
    @Published var lastCommandText: String = "—"

    @Published var events: [PumpEvent] = []
    
    // Settings (MVP)
    @Published var icRatio: Double = 10.0              // g/U
    @Published var correctionFactor: Double = 50.0     // mg/dL per U
    @Published var targetGlucose: Double = 110.0       // mg/dL

    // Mock data
    private let generator = MockDataGenerator()
    private var timer: Timer?

    // BLE state
    private var centralManager: CBCentralManager?
    private var espPeripheral: CBPeripheral?
    private var carbWriteCharacteristic: CBCharacteristic?
    private var cgmNotifyCharacteristic: CBCharacteristic?

    private let serviceUUID = CBUUID(string: "1234")
    private let carbUUID = CBUUID(string: "5678")
    private let cgmUUID = CBUUID(string: "5679")

    func startMocking() {
        if glucoseHistory.isEmpty {
            seedHistory()
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.addMockGlucosePoint()
            }
        }
    }

    // Always store internally as mg/dL
    func displayGlucose(_ mgdl: Double) -> Double {
        switch glucoseUnit {
        case .mgdl:
            return mgdl
        case .mmoll:
            return mgdl / 18.0
        }
    }
    
    func displayGlucoseString(_ mgdl: Double) -> String {
        switch glucoseUnit {
        case .mgdl:
            return "\(Int(mgdl.rounded())) mg/dL"
        case .mmoll:
            return String(format: "%.1f mmol/L", mgdl / 18.0)
        }
    }
    
    func startBluetooth() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        } else if centralManager?.state == .poweredOn {
            startScanning()
        }
    }
    
    private func seedHistory() {
        let now = Date()
        var points: [GlucosePoint] = []

        for i in stride(from: 60, through: 0, by: -5) {
            let t = now.addingTimeInterval(TimeInterval(-i * 60))
            let g = generator.nextGlucose()
            points.append(GlucosePoint(time: t, mgdl: g))
        }

        glucoseHistory = points
        currentGlucoseMgdl = Int(points.last?.mgdl ?? 110)
        lastUpdateTime = now
    }

    private func addMockGlucosePoint() {
        let g = generator.nextGlucose()
        let now = Date()

        currentGlucoseMgdl = Int(g.rounded())
        lastUpdateTime = now

        glucoseHistory.append(GlucosePoint(time: now, mgdl: g))
        if glucoseHistory.count > 200 {
            glucoseHistory.removeFirst(glucoseHistory.count - 200)
        }

        events.insert(PumpEvent(time: now, type: .glucose,
                                message: "Glucose received: \(currentGlucoseMgdl) mg/dL"), at: 0)
    }

    // MARK: - BLE helpers

    private func startScanning() {
        guard let centralManager, centralManager.state == .poweredOn else { return }

        centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
        events.insert(PumpEvent(time: Date(), type: .connection,
                                message: "Scanning for ESP32-CGM..."), at: 0)
    }

    private func resetConnectionState() {
        isConnected = false
        espPeripheral = nil
        carbWriteCharacteristic = nil
        cgmNotifyCharacteristic = nil
    }

    // MARK: - CoreBluetooth delegate (central)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff, .resetting, .unauthorized, .unsupported, .unknown:
            resetConnectionState()
        @unknown default:
            resetConnectionState()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        // iOS often gives peripheral.name == nil during scan; check advertisement data too
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? ""
        guard name.contains("ESP32-CGM") else { return }

        espPeripheral = peripheral
        espPeripheral?.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)

        events.insert(PumpEvent(time: Date(), type: .connection,
                                message: "Connecting to \(name)..."), at: 0)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        isConnected = true
        carbWriteCharacteristic = nil
        cgmNotifyCharacteristic = nil

        events.insert(PumpEvent(time: Date(), type: .connection,
                                message: "Connected to ESP32-CGM"), at: 0)

        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        resetConnectionState()
        events.insert(PumpEvent(time: Date(), type: .connection,
                                message: "Failed to connect to ESP32-CGM: \(error?.localizedDescription ?? "Unknown error")"),
                      at: 0)
        startScanning()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        resetConnectionState()
        events.insert(PumpEvent(time: Date(), type: .connection,
                                message: "Disconnected from ESP32-CGM"),
                      at: 0)
        startScanning()
    }

    // MARK: - CoreBluetooth delegate (peripheral)

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            events.insert(PumpEvent(time: Date(), type: .connection,
                                    message: "Service discovery failed: \(error.localizedDescription)"),
                          at: 0)
            return
        }

        guard let services = peripheral.services else { return }

        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([carbUUID, cgmUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            events.insert(PumpEvent(time: Date(), type: .connection,
                                    message: "Characteristic discovery failed: \(error.localizedDescription)"),
                          at: 0)
            return
        }

        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            if characteristic.uuid == carbUUID {
                carbWriteCharacteristic = characteristic
            } else if characteristic.uuid == cgmUUID {
                cgmNotifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        if carbWriteCharacteristic != nil && cgmNotifyCharacteristic != nil {
            events.insert(PumpEvent(time: Date(), type: .connection,
                                    message: "BLE ready for CGM updates"),
                          at: 0)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            events.insert(PumpEvent(time: Date(), type: .connection,
                                    message: "Failed to subscribe to CGM updates: \(error.localizedDescription)"),
                          at: 0)
        }
    }

    // MARK: - CGM notifications

    private struct CgmPacket: Decodable {
        let glucose: Double
        let insulin: Double
        let carbs: Double
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            events.insert(PumpEvent(time: Date(), type: .connection,
                                    message: "Error receiving CGM update: \(error.localizedDescription)"),
                          at: 0)
            return
        }

        guard characteristic.uuid == cgmUUID,
              let data = characteristic.value,
              let jsonString = String(data: data, encoding: .utf8),
              let jsonData = jsonString.data(using: .utf8) else {
            return
        }

        do {
            let packet = try JSONDecoder().decode(CgmPacket.self, from: jsonData)
            handleCgmPacket(packet)
        } catch {
            events.insert(PumpEvent(time: Date(), type: .connection,
                                    message: "Failed to decode CGM JSON: \(jsonString)"),
                          at: 0)
        }
    }

    private func handleCgmPacket(_ packet: CgmPacket) {
        let now = Date()

        currentGlucoseMgdl = Int(packet.glucose.rounded())
        lastUpdateTime = now

        glucoseHistory.append(GlucosePoint(time: now, mgdl: packet.glucose))
        if glucoseHistory.count > 200 {
            glucoseHistory.removeFirst(glucoseHistory.count - 200)
        }

        isConnected = true

        events.insert(PumpEvent(time: now, type: .glucose,
                                message: "Glucose received: \(currentGlucoseMgdl) mg/dL"),
                      at: 0)
    }

    func sendCarbs(_ grams: Int) {
        let now = Date()

        events.insert(PumpEvent(time: now, type: .carbs,
                                message: "Carbs sent: \(grams) g"), at: 0)

        // Mock “auto” dose logic (demo only)
        let simulatedDose = Double(grams) / icRatio
        lastDoseUnits = (simulatedDose * 10).rounded() / 10
        lastDoseTime = now
        lastDoseType = .auto
        lastCommandText = "\(String(format: "%.1f", lastDoseUnits)) U (\(lastDoseType.rawValue))"

        pumpState = .delivering
        events.insert(PumpEvent(time: now, type: .dose,
                                message: "Commanded dose: \(lastCommandText)"), at: 0)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.pumpState = .idle
            self.events.insert(PumpEvent(time: Date(), type: .dose,
                                         message: "Delivery complete: \(String(format: "%.1f", self.lastDoseUnits)) U"), at: 0)
        }

        // Send carbs to ESP32 over BLE using UTF-8 numeric string
        if let peripheral = espPeripheral,
           let carbCharacteristic = carbWriteCharacteristic,
           isConnected,
           let data = "\(grams)".data(using: .utf8) {
            peripheral.writeValue(data, for: carbCharacteristic, type: .withResponse)
        } else {
            events.insert(PumpEvent(time: now, type: .connection,
                                    message: "Failed to send carbs to pump (not connected)."),
                          at: 0)
        }
    }
}
