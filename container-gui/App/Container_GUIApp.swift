//
//  Container_GUIApp.swift
//  Container GUI
//
//  Created by Bram Gussekloo on 30/07/2026.
//

import AppKit
import SwiftUI

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard
            let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else { return }

        NSApplication.shared.applicationIconImage = icon
    }
}

@main
struct Container_GUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var updates: UpdateModel

    init() {
        _updates = State(initialValue: AppDependencies.makeUpdateModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: AppDependencies.makeAppModel(), updates: updates)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updates.checkNow() }
                }
                .disabled(updates.isChecking)
            }
        }
    }
}
