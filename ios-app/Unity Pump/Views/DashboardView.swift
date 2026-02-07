//
//  DashboardView.swift
//  Unity Pump
//
//  Created by Emma Starkman on 2026-02-07.
//

import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    
    private var last60Min: [GlucosePoint] {
        let cutoff = Date().addingTimeInterval(-60 * 60)
        return model.glucoseHistory.filter { $0.time >= cutoff }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {

                // Connection banner
                HStack(spacing: 10) {
                    Circle()
                        .frame(width: 10, height: 10)
                        .foregroundStyle(model.isConnected ? .green : .red)

                    Text(model.isConnected ? "Connected" : "Disconnected")
                        .font(.headline)

                    Spacer()

                    Text("Updated \(model.lastUpdateTime, style: .time)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                // Current glucose
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current Glucose")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(model.displayGlucoseString(Double(model.currentGlucoseMgdl)))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))

                // Glucose chart
                VStack(alignment: .leading, spacing: 6) {
                    Text("Glucose (last 60 min)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    GlucoseChartView(points: last60Min, unit: model.glucoseUnit)
                        .frame(height: 220)
                }
                .padding()
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))


                // Pump status
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pump")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("State")
                        Spacer()
                        Text(model.pumpState.rawValue)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Last dose")
                        Spacer()
                        Text("\(String(format: "%.1f", model.lastDoseUnits)) U at \(model.lastDoseTime, style: .time)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Last command")
                        Spacer()
                        Text(model.lastCommandText)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))

            }
            .padding()
        }
        .navigationTitle("Dashboard")
    }
}
