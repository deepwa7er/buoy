//
//  BuoyApp.swift
//  Buoy
//
//  Created by Joe on 5/26/26.
//

import SwiftUI

@main
struct BuoyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Color(red: 0.910, green: 0.349, blue: 0.047))
        }
        // Registers the background-refresh handler (the modern replacement for
        // BGTaskScheduler.register in an AppDelegate). iOS only — macOS keeps
        // its store warm while running and syncs on foreground / capture / pull.
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundSync.taskIdentifier)) {
            await BackgroundSync.run()
        }
        #endif
    }
}
