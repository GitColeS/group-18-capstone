//
//  ContentView.swift
//  Unity Pump
//
//  Created by Emma Starkman on 2026-02-06.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                DashboardView()
            }
            .tabItem {
                Label("Dashboard", systemImage: "waveform.path.ecg")
            }

            NavigationStack {
                ControlsView()
            }
            .tabItem {
                Label("Controls", systemImage: "slider.horizontal.3")
            }
        }
    }
}

