import AppKit
import FirmwareCore
import SwiftUI

struct SettingsView: View {
    @Environment(UpdaterModel.self) private var model
    @State private var locateError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(isOn: $model.autoFix) {
                    Text("Fix programmer problems automatically")
                    Text("If a PICkit 3 is running the PICkit 3 Programmer App's scripting firmware, switch it to MPLAB mode. If the chip turns out to be the F or LF version of the selected part, switch to it. Either way, try again without asking. A different chip still stops and asks.")
                }
            } header: {
                Text("Automatic fixes")
            }

            Section {
                if let ipecmd = model.ipecmd {
                    LabeledContent("In use") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(ipecmd.version ?? "Custom")
                            Text(ipecmd.displayPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    LabeledContent("In use", value: "Not found")
                }

                if !model.installations.isEmpty {
                    LabeledContent("Detected") {
                        Text(model.installations.compactMap(\.version).joined(separator: ", "))
                    }
                }

                HStack {
                    Button("Choose ipecmd…", action: choose)
                    if model.customInstallation != nil {
                        Button("Use Auto-Detected") { model.clearCustomIPECmd() }
                    }
                    Spacer()
                    Button("Search Again") { model.locateIPE() }
                }
                if let locateError {
                    Notice(style: .error, text: locateError)
                }
            } header: {
                Text("MPLAB IPE command line (ipecmd)")
            } footer: {
                Text("ipecmd comes with MPLAB X IDE, at /Applications/microchip/mplabx/<version>/mplab_platform/mplab_ipe/bin/ipecmd.sh. The PICkit 3 needs v6.20 or earlier; v6.25 and later dropped it. Several versions can be installed side by side, and the newest one that supports your programmer is picked automatically. To choose one yourself, pick its ipecmd.sh, ipecmd.jar, or version folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 560, height: 520)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications/microchip")
        panel.message = "Choose ipecmd.sh, ipecmd.jar, or an MPLAB X version folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        locateError = model.useCustomIPECmd(url) ? nil : "No usable ipecmd was found at \(url.path)."
    }
}
