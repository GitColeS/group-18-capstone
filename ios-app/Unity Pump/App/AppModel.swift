//
//  AppModel.swift
//  Unity Pump
//
//  Created by Emma Starkman on 2026-02-07.
//

import SwiftUI
import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {

    @Published var isConnected: Bool = true
    @Published var lastUpdateTime: Date = Date()

    @Published var currentGlucoseMgdl: Int = 110
    @Published var glucoseHistory: [GlucosePoint] = []

    @Published var pumpStatusText: String = "Idle"
    @Published var lastDoseUnits: Double = 0.0
    @Published var lastDoseTime: Date = Date()

    @Published var events: [PumpEvent] = []

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

        // Demo: simulate a dose response
        let simulatedDose = Double(grams) / 10.0
        lastDoseUnits = (simulatedDose * 10).rounded() / 10
        lastDoseTime = now
        pumpStatusText = "Delivered"

        events.insert(PumpEvent(time: now, type: .dose,
                                message: "Dose delivered: \(String(format: "%.1f", lastDoseUnits)) U"), at: 0)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.pumpStatusText = "Idle"
        }
    }
}
