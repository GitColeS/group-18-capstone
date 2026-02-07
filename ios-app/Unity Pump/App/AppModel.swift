//
//  AppModel.swift
//  Unity Pump
//
//  Created by Emma Starkman on 2026-02-07.
//

import SwiftUI
import Foundation
import Combine

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

@MainActor
final class AppModel: ObservableObject {

    @Published var isConnected: Bool = true
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

    private let generator = MockDataGenerator()
    private var timer: Timer?

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
    }
}
