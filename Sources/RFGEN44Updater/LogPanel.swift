import AppKit
import FirmwareCore
import SwiftUI

struct LogPanel: View {
    @Environment(UpdaterModel.self) private var model
    @Binding var expanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Label("Log", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)

                if let last = model.log.last, !expanded {
                    Text(last.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                }
                Button("Save…", action: save)
                Button("Clear") { model.clearLog() }
                    .disabled(model.isBusy)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            if expanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(model.log) { line in
                                LogLineView(line: line).id(line.id)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: model.log.last?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                .frame(height: 150)
            }
        }
        .background(.bar)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "RFGEN44-updater-log.txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? model.logText.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private struct LogLineView: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .foregroundStyle(.tertiary)
            Text(line.text)
                .foregroundStyle(color)
                .fontWeight(line.kind == .app ? .semibold : .regular)
                .textSelection(.enabled)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var color: Color {
        switch line.severity {
        case .error: .red
        case .warning: .orange
        case .success: .green
        case .info: line.kind == .command ? .blue : .primary
        }
    }
}
