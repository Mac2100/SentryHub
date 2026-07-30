import AppKit
import SwiftUI

@main
struct SentryHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var themeStore = ThemeStore.shared
    @StateObject private var hudStore = HUDStore.shared

    var body: some Scene {
        Window("SentryHub", id: "main") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(themeStore)
                .environmentObject(hudStore)
                .environment(\.appTheme, themeStore.theme)
                .tint(themeStore.theme.primary)
                .frame(minWidth: 1080, minHeight: 700)
                .task {
                    appState.updates.checkOnLaunchIfEnabled()
                    // The local library first: it's small, it's always there,
                    // and it's what the app has to show when no drive is.
                    await LocalLibrary.shared.rescan()
                    await appState.library.restoreLastFolder()
                    // After the restore, so a drive that's already plugged in
                    // only gets adopted when nothing came back from last time.
                    appState.startWatchingDrives()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await appState.updates.check(userInitiated: true) }
                }
                Link("Buy Me a Coffee…", destination: BuyMeACoffee.url)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Back to Library") {
                    appState.closePlayer()
                }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(appState.openClip == nil)
            }
            CommandMenu("Library") {
                Button("Choose TeslaCam Folder…") {
                    Task { await appState.library.chooseFolder() }
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Rescan") {
                    Task {
                        await LocalLibrary.shared.rescan()
                        await appState.library.rescan()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                Button("Clips") { appState.libraryTab = .clips }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Incidents") { appState.libraryTab = .incidents }
                    .keyboardShortcut("2", modifiers: [.command])

                Divider()

                Button("Back to Start Screen") {
                    appState.showStartScreen()
                }
                .disabled(!appState.hasLibrary)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(themeStore)
                .environmentObject(hudStore)
                .environment(\.appTheme, themeStore.theme)
                .tint(themeStore.theme.primary)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeStore.shared.applyAppearance()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard UserDefaults.standard.bool(forKey: "rescanOnActivate") else { return }
        Task { await AppState.shared.library.rescan() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        FolderAccess.releaseAll()
    }
}
