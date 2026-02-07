//
//  GlucosePoint.swift
//  Unity Pump
//
//  Created by Emma Starkman on 2026-02-07.
//

import Foundation

struct GlucosePoint: Identifiable {
    let id = UUID()
    let time: Date
    let mgdl: Double
}
