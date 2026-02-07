//
//  GlucoseChartView.swift
//  Unity Pump
//
//  Created by Emma Starkman on 2026-02-07.
//

import SwiftUI
import Charts

struct GlucoseChartView: View {
    let points: [GlucosePoint]
    let unit: GlucoseUnit
    
    private func yValue(_ mgdl: Double) -> Double {
        unit == .mgdl ? mgdl : (mgdl / 18.0)
    }

    var body: some View {
        Chart {
            ForEach(points) { p in
                LineMark(
                    x: .value("Time", p.time),
                    y: .value("Glucose", yValue(p.mgdl))
                )
                .interpolationMethod(.catmullRom)
            }
        }
        .chartYScale(domain: unit == .mgdl ? 60...250 : (60.0/18.0)...(250.0/18.0))
        .chartYAxisLabel(unit.rawValue, position: .leading)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
    }
}
