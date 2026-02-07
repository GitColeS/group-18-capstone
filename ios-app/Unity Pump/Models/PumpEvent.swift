//
//  PumpEvent.swift
//  Unity Pump
//
//  Created by Emma Starkman on 2026-02-07.
//

import Foundation

enum PumpEventType {
    case glucose
    case carbs
    case dose
    case connection
}

struct PumpEvent: Identifiable {
    let id = UUID()
    let time: Date
    let type: PumpEventType
    let message: String
}
