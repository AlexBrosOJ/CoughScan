//
//  CoughScanApp.swift
//  CoughScan
//
//  Created by Александр on 21.10.2026.
//

import SwiftUI

@main
struct CoughScanApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(MonitoringManager.shared)
        }
    }
}
