import FirmwareCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let intelHex = UTType(filenameExtension: "hex") ?? .data
}

struct ContentView: View {
    @Environment(UpdaterModel.self) private var model
    @State private var showingImporter = false
    @State private var showingWiring = false
    @State private var dropTargeted = false
    @AppStorage("logExpanded") private var logExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                FirmwareSection(showingImporter: $showingImporter, dropTargeted: dropTargeted)
                ProgrammerSection()
                TargetSection()
                if let report = model.verification {
                    Section {
                        VerificationSummary(report: report)
                    } header: {
                        Text("Last read-back compare")
                    }
                }
            }
            .formStyle(.grouped)

            UploadBar()
            LogPanel(expanded: $logExpanded)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "hex" }) else { return false }
            model.openFirmware(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.intelHex, .plainText, .data]) { result in
            if case let .success(url) = result { model.openFirmware(url) }
        }
        .sheet(isPresented: $showingWiring) { WiringGuideView() }
        .onReceive(NotificationCenter.default.publisher(for: .openFirmware)) { _ in showingImporter = true }
        .onReceive(NotificationCenter.default.publisher(for: .showWiring)) { _ in showingWiring = true }
        .toolbar {
            ToolbarItemGroup {
                Button { showingImporter = true } label: { Label("Open Firmware", systemImage: "doc.badge.plus") }
                    .help("Choose a firmware .hex file")
                Button { model.usb.refresh() } label: { Label("Rescan USB", systemImage: "arrow.clockwise") }
                    .help("Rescan USB for programmers")
                Button { showingWiring = true } label: { Label("Wiring Guide", systemImage: "cable.connector") }
                    .help("How to connect the PICkit 3 to the RFGEN44")
            }
        }
        .navigationSubtitle(model.activity.map { "\($0.title)…" } ?? "PICkit 3 · \(model.device.name)")
    }
}

// MARK: - 1. Firmware

private struct FirmwareSection: View {
    @Environment(UpdaterModel.self) private var model
    @Binding var showingImporter: Bool
    let dropTargeted: Bool

    var body: some View {
        Section {
            if let firmware = model.firmware, let summary = model.summary {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(firmware.url.lastPathComponent).font(.headline)
                        Text(firmware.url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Choose…") { showingImporter = true }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([firmware.url]) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Show in Finder")
                    Button { model.reloadFirmware() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Reload the file from disk")
                }
                .disabled(model.isBusy)

                LabeledContent("Program memory") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(summary.programWordsUsed.formatted()) of \(Int(model.device.programWords).formatted()) words used")
                        ProgressView(value: Double(summary.programWordsUsed), total: Double(model.device.programWords))
                            .frame(width: 180)
                    }
                }
                LabeledContent("Configuration") {
                    HStack(spacing: 6) {
                        Text(summary.configValues.map { value in
                            "\(value.word.name) " + (value.value.map { String(format: "0x%04X", $0) } ?? "—")
                        }.joined(separator: "  "))
                        .monospaced()
                        .textSelection(.enabled)
                        Text("· Code protect \(summary.codeProtectionEnabled == true ? "on" : "off")")
                    }
                }
                LabeledContent("File") {
                    HStack(spacing: 6) {
                        Text("\(firmware.fileSize.formatted(.byteCount(style: .file))) · \(firmware.hex.dataRecordCount) records ·")
                        Text("SHA-256 \(firmware.sha256.prefix(12))…")
                            .monospaced()
                            .help(firmware.sha256)
                            .textSelection(.enabled)
                    }
                }

                if !summary.fitsDevice {
                    Notice(
                        style: .error,
                        text: String(
                            format: "This file has %d words outside %@ memory (first at 0x%04X). It was probably built for a different chip.",
                            summary.outOfRangeWordAddresses.count, model.device.name, summary.outOfRangeWordAddresses[0]
                        )
                    )
                }
                if !summary.hasConfiguration {
                    Notice(style: .warning, text: "This file has no configuration words. The device's current configuration will be erased.")
                }
                if summary.codeProtectionEnabled == true {
                    Notice(style: .warning, text: "Code protection is on, so the read-back compare cannot read the device afterwards. ipecmd's own verify still runs.")
                }
                if let guessed = PICDevice.guess(fromFileName: firmware.url.lastPathComponent), !guessed.isVariant(of: model.device) {
                    Notice(style: .warning, text: "The file name mentions \(guessed.name), but \(model.device.name) is selected.")
                }
            } else {
                HStack(spacing: 14) {
                    Image(systemName: dropTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drop a firmware .hex file here").font(.headline)
                        Text("or choose one from disk").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose Firmware…") { showingImporter = true }
                        .controlSize(.large)
                }
                .padding(.vertical, 6)

                if let error = model.firmwareError {
                    Notice(style: .error, text: error)
                }
            }
        } header: {
            StepHeader(number: 1, title: "Firmware")
        }
    }
}

// MARK: - 2. Programmer

private struct ProgrammerSection: View {
    @Environment(UpdaterModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        Section {
            if model.usb.programmers.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waiting for a programmer…").font(.headline)
                        Text("Connect the PICkit 3 to this Mac with a USB cable. It will appear here automatically. If its status LED blinks red and it never appears, unplug it and plug it back in without holding its button.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                ForEach(model.usb.programmers) { device in
                    ProgrammerRow(
                        device: device,
                        selected: model.selectedProgrammer?.id == device.id,
                        state: model.pickitStates[device.id]
                    )
                        .contentShape(Rectangle())
                        .onTapGesture { if !model.isBusy { model.selectedProgrammerID = device.id } }
                }
            }

            if !model.usb.otherMicrochipDevices.isEmpty {
                LabeledContent("Other Microchip USB devices") {
                    Text(model.usb.otherMicrochipDevices.map { "\($0.displayName) (\($0.usbID))" }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("MPLAB IPE") {
                if model.isLocatingIPE {
                    ProgressView().controlSize(.small)
                } else if let ipecmd = model.ipecmd {
                    let kind = model.selectedProgrammer?.programmer ?? .pickit3
                    let supported = ipecmd.supports(kind)
                    HStack(spacing: 6) {
                        Image(systemName: supported ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(supported ? .green : .orange)
                        Text((ipecmd.version.map { "ipecmd \($0)" } ?? "ipecmd") + (supported ? "" : " — no \(kind.displayName) support"))
                            .help(ipecmd.displayPath)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Not installed")
                        Button("Locate…") { openSettings() }
                    }
                }
            }
            if !model.isLocatingIPE && model.ipecmd == nil {
                HStack(alignment: .firstTextBaseline) {
                    Text("This app drives the PICkit 3 through Microchip's ipecmd tool, part of the free MPLAB X IDE. Install MPLAB X v6.20 from Microchip's archive. It is the last version that supports the PICkit 3. Then relaunch this app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Link("MPLAB X downloads", destination: URL(string: "https://www.microchip.com/en-us/tools-resources/develop/mplab-x-ide")!)
                        .fixedSize()
                }
            }
        } header: {
            HStack {
                StepHeader(number: 2, title: "Programmer")
                Spacer()
                Button { model.usb.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Rescan USB")
            }
        }
    }
}

private struct ProgrammerRow: View {
    let device: USBDevice
    let selected: Bool
    let state: PICkitState?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .font(.title3)
            Image(systemName: "cable.connector.horizontal")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.headline)
                Text(["S/N \(device.serialNumber ?? "unknown")", "USB \(device.usbID)"].joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if state == .checking || state == .switching {
                ProgressView().controlSize(.small)
            }
            Text(status.text)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(status.color.opacity(0.15), in: Capsule())
                .foregroundStyle(status.color)
                .help(status.help ?? "")
        }
        .padding(.vertical, 2)
    }

    private var status: (text: String, color: Color, help: String?) {
        switch state {
        case nil:
            ("Connected", .green, nil)
        case .checking:
            ("Checking firmware…", .secondary, nil)
        case let .mplab(suite):
            ("MPLAB firmware \(suite ?? "")".trimmingCharacters(in: .whitespaces), .green, nil)
        case .bootloader:
            ("MPLAB mode", .green, "MPLAB loads its firmware onto the PICkit on the next connection (about a minute, once).")
        case let .scripting(version):
            ("Scripting firmware \(version)", .orange, "Firmware from the PICkit 3 Programmer App. MPLAB can't use it until the PICkit is switched to MPLAB mode.")
        case .switching:
            ("Switching to MPLAB mode…", .orange, nil)
        case .unresponsive:
            ("Connected", .green, "The PICkit 3 didn't answer the firmware check.")
        case let .switchFailed(reason):
            ("Needs attention", .red, reason)
        }
    }
}

// MARK: - 3. Target

private struct TargetSection: View {
    @Environment(UpdaterModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Picker("Device", selection: $model.device) {
                ForEach(PICDevice.supported) { device in
                    Text(device.name).tag(device)
                }
            }
            .disabled(model.isBusy)

            Toggle(isOn: $model.powerTarget) {
                Text("Power the target from the programmer")
                Text("Leave off when the RFGEN44 has its own supply or is plugged into USB. The PICkit 3 can only supply about 30 mA.")
            }
            .disabled(model.isBusy)

            if model.powerTarget {
                Picker("Supply voltage", selection: $model.powerVoltage) {
                    Text("3.3 V").tag(3.3)
                    Text("5.0 V").tag(5.0).disabled(model.device.isLowVoltagePart)
                }
                .pickerStyle(.segmented)
                .disabled(model.isBusy)
            }

            Toggle(isOn: $model.readbackAfterProgramming) {
                Text("Read back and compare word by word")
                Text("After ipecmd's own verify, reads the whole chip back and checks every word against the file. Applies to Program & Verify and to Verify.")
            }
            .disabled(model.isBusy)

            if let target = model.targetDescription {
                LabeledContent("Last detected target", value: target)
            }
        } header: {
            StepHeader(number: 3, title: "Target")
        }
    }
}

// MARK: - 4. Upload

private struct UploadBar: View {
    @Environment(UpdaterModel.self) private var model
    @State private var confirmingProgram = false
    @State private var confirmingSwitch = false

    var body: some View {
        let programBlocked = model.blockingReason(needsFirmware: true)
        let connectionBlocked = model.blockingReason(needsFirmware: false)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StepHeader(number: 4, title: "Upload")
                    .font(.headline)
                    .padding(.trailing, 8)

                Button {
                    confirmingProgram = true
                } label: {
                    Label("Program & Verify", systemImage: "bolt.fill")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isBusy || programBlocked != nil)
                // Deliberately not bound to Return: a stray keypress must never start erasing the chip.
                .help("Erase the chip, write the firmware and verify it (⇧⌘P)")

                Button {
                    model.verify()
                } label: {
                    Label("Verify", systemImage: "checkmark.shield")
                }
                .controlSize(.large)
                .disabled(model.isBusy || model.verifyBlockingReason != nil)
                .help(model.verifyBlockingReason ?? "Check that the device holds exactly this firmware")

                Menu {
                    Button("Test Connection") { model.testConnection() }
                        .disabled(connectionBlocked != nil)
                    Button("Save Device Memory to File…") { chooseReadDestination() }
                        .disabled(connectionBlocked != nil)
                    if case .scripting? = model.selectedProgrammer.flatMap({ model.pickitStates[$0.id] }) {
                        Divider()
                        Button("Switch PICkit 3 to MPLAB Mode…") { confirmingSwitch = true }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .controlSize(.large)
                .fixedSize()
                .disabled(model.isBusy)

                Spacer()

                if model.isBusy {
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .controlSize(.large)
                }
            }

            if !model.isBusy, let reason = programBlocked {
                Label(reason, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            if !model.stages.isEmpty {
                StageTrack(stages: model.stages, states: model.stageStates, busy: model.isBusy)
            }

            if let detail = model.statusDetail {
                Label(detail, systemImage: "arrow.down.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let outcome = model.outcome {
                OutcomeBanner(outcome: outcome) { action in
                    if action == .switchPICkitToMPLABMode {
                        confirmingSwitch = true
                    } else {
                        model.perform(action)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
        .onReceive(NotificationCenter.default.publisher(for: .requestProgram)) { _ in
            if !model.isBusy && programBlocked == nil { confirmingProgram = true }
        }
        .confirmationDialog("Switch the PICkit 3 to MPLAB mode?", isPresented: $confirmingSwitch) {
            Button("Switch to MPLAB Mode") { model.perform(.switchPICkitToMPLABMode) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This does what \"Revert to MPLAB mode\" does in Microchip's PICkit 3 Programmer App. The PICkit restarts into its bootloader, and MPLAB loads its own firmware onto it on the next connection. Going back to scripting mode later needs the Windows Programmer App.")
        }
        .confirmationDialog(
            "Program \(model.device.name)?",
            isPresented: $confirmingProgram
        ) {
            Button("Erase and Program") { model.programAndVerify() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The firmware currently on the RFGEN44 will be erased and replaced with \(model.firmware?.url.lastPathComponent ?? "the selected file"). Keep the PICkit 3 connected until verification finishes.")
        }
    }

    private func chooseReadDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.intelHex]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "RFGEN44-readback-\(Date().formatted(.iso8601.year().month().day())).hex"
        panel.message = "Save the firmware currently on the device"
        if panel.runModal() == .OK, let url = panel.url {
            model.readDevice(to: url)
        }
    }
}

private struct StageTrack: View {
    let stages: [IPEStage]
    let states: [IPEStage: StageState]
    let busy: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
                let state = states[stage] ?? .pending
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(fill(for: state))
                            .frame(width: 26, height: 26)
                        switch state {
                        case .pending:
                            Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.secondary)
                        case .active:
                            ProgressView().controlSize(.mini).tint(.white)
                        case .done:
                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                        case .failed:
                            Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.white)
                        }
                    }
                    Text(stage.title)
                        .font(.caption)
                        .foregroundStyle(state == .pending ? .secondary : .primary)
                }
                .frame(minWidth: 64)
                if index < stages.count - 1 {
                    Rectangle()
                        .fill(state == .done ? Color.green : Color.secondary.opacity(0.3))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 18)
                }
            }
        }
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.2), value: states)
    }

    private func fill(for state: StageState) -> Color {
        switch state {
        case .pending: Color.secondary.opacity(0.15)
        case .active: Color.accentColor
        case .done: Color.green
        case .failed: Color.red
        }
    }
}

private struct OutcomeBanner: View {
    let outcome: Outcome
    let perform: (OutcomeAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: outcome.success ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .font(.system(size: 26))
                .foregroundStyle(outcome.success ? .green : .red)
            VStack(alignment: .leading, spacing: 3) {
                Text(outcome.title).font(.headline)
                if let detail = outcome.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action = outcome.action {
                    Button(actionTitle(action)) { perform(action) }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background((outcome.success ? Color.green : Color.red).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func actionTitle(_ action: OutcomeAction) -> String {
        switch action {
        case let .useDevice(part): "Use \(part.name)"
        case .switchPICkitToMPLABMode: "Switch PICkit 3 to MPLAB Mode…"
        }
    }
}

private struct VerificationSummary: View {
    let report: VerificationReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Read-back compare")
                .font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                GridRow {
                    Text("Program memory").foregroundStyle(.secondary)
                    Text("\(report.programWordsCompared.formatted()) words")
                }
                GridRow {
                    Text("User ID").foregroundStyle(.secondary)
                    Text("\(report.userIDWordsCompared) words")
                }
                GridRow {
                    Text("Configuration").foregroundStyle(.secondary)
                    Text("\(report.configWordsCompared) words")
                }
                GridRow {
                    Text("Mismatches").foregroundStyle(.secondary)
                    Text("\(report.mismatches.count)")
                        .foregroundStyle(report.mismatches.isEmpty ? .green : .red)
                        .bold()
                }
            }
            .font(.callout)

            if !report.mismatches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(report.mismatches.prefix(12)) { mismatch in
                        Text(String(
                            format: "0x%04X  %@  expected 0x%04X  read 0x%04X",
                            mismatch.wordAddress, mismatch.region.rawValue, mismatch.expected, mismatch.actual
                        ))
                    }
                    if report.mismatches.count > 12 {
                        Text("…and \(report.mismatches.count - 12) more")
                    }
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Shared pieces

struct StepHeader: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.accentColor, in: Circle())
            Text(title)
        }
    }
}

struct Notice: View {
    enum Style { case warning, error }

    let style: Style
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: style == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(style == .error ? .red : .orange)
        }
        .font(.callout)
    }
}
