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

    var body: some View {
        Chart {
            ForEach(points) { p in
                LineMark(
                    x: .value("Time", p.time),
                    y: .value("Glucose", p.mgdl)
                )
                .interpolationMethod(.catmullRom)
            }
        }
        .chartYScale(domain: 60...250)
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
