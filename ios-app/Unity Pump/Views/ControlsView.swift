//
//  ControlsView.swift
//  Unity Pump
//
//  Created by Emma Starkman on 2026-02-07.
//

import SwiftUI

struct ControlsView: View {
    @EnvironmentObject var model: AppModel
    @State private var carbsText = ""
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {

                // Carbs input
                VStack(alignment: .leading, spacing: 10) {
                    Text("Carbohydrates")
                        .font(.headline)

                    HStack {
                        TextField("Carbs (g)", text: $carbsText)
                            .keyboardType(.numberPad)
                            .focused($keyboardFocused)
                            .textFieldStyle(.roundedBorder)

                        Button("Send") {
                            let grams = Int(carbsText) ?? 0
                            model.sendCarbs(grams)
                            carbsText = ""
                            keyboardFocused = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))
                
                // Settings (MVP: read-only)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Settings")
                        .font(.headline)

                    HStack {
                        Text("I:C Ratio")
                        Spacer()
                        Text("\(String(format: "%.1f", model.icRatio)) g/U")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Correction Factor")
                        Spacer()
                        Text("\(String(format: "%.0f", model.correctionFactor)) mg/dL per U")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Target")
                        Spacer()
                        Text("\(String(format: "%.0f", model.targetGlucose)) mg/dL")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))

                // Event log
                VStack(alignment: .leading, spacing: 8) {
                    Text("Event Log")
                        .font(.headline)

                    if model.events.isEmpty {
                        Text("No events yet.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(model.events.prefix(20)) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.message)
                                Text(event.time, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)

                            Divider()
                        }
                    }
                }
                .padding()
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))
            }
            .padding()
        }
        .onTapGesture {
            keyboardFocused = false
        }
        .navigationTitle("Controls")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { keyboardFocused = false }
            }
        }
    }
}
