import AppKit
import SwiftUI

@main
struct RFGEN44UpdaterApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = UpdaterModel()

    var body: some Scene {
        Window("RFGEN44 Firmware Updater", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 680, minHeight: 720)
                .task {
                    appDelegate.model = model
                    model.start()
                }
        }
        .defaultSize(width: 760, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Firmware…") { NotificationCenter.default.post(name: .openFirmware, object: nil) }
                    .keyboardShortcut("o")
            }
            CommandGroup(before: .help) {
                Button("PICkit 3 Wiring Guide…") { NotificationCenter.default.post(name: .showWiring, object: nil) }
            }
            CommandMenu("Device") {
                Button("Program & Verify…") { NotificationCenter.default.post(name: .requestProgram, object: nil) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.blockingReason(needsFirmware: true) != nil)
                Button("Verify") { model.verify() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.verifyBlockingReason != nil)
                Button("Test Connection") { model.testConnection() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.blockingReason(needsFirmware: false) != nil)
                Divider()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(".")
                    .disabled(!model.isBusy)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files opened from Finder before the window is ready wait here.
    private var pendingFiles: [URL] = []

    var model: UpdaterModel? {
        didSet {
            if let model, let file = pendingFiles.last { model.openFirmware(file) }
            pendingFiles.removeAll()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let file = urls.last(where: { $0.isFileURL }) else { return }
        if let model, !model.isBusy {
            model.openFirmware(file)
        } else if model == nil {
            pendingFiles.append(file)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare executable (`swift run`) starts as a background process; the .app bundle doesn't need this.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension Notification.Name {
    static let openFirmware = Notification.Name("openFirmware")
    static let requestProgram = Notification.Name("requestProgram")
    static let showWiring = Notification.Name("showWiring")
}
