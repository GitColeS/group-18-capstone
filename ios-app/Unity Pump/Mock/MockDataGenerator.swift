//
//  MockDataGenerator.swift
//  Unity Pump
//
//  Created by Emma Starkman on 2026-02-07.
//

import Foundation

final class MockDataGenerator {
    private var current: Double = 110

    func nextGlucose() -> Double {
        let drift = Double.random(in: -3...3)
        current = max(60, min(250, current + drift))
        return current
    }
}
