//
//  DrawTraceApp.swift
//  DrawTrace
//
//

import SwiftUI

@main
struct DrawTraceApp: App {
    init() {
        AuthService.configureIfPossible()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
