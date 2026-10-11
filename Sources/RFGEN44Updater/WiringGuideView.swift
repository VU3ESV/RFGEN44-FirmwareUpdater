import SwiftUI

/// PICkit 3 ICSP header pinout (PICkit 3 User's Guide, figure 1-2) and how it maps to the target.
struct WiringGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Pin: Identifiable {
        let number: Int
        let signal: String
        let target: String
        let note: String?
        var id: Int { number }
    }

    private let pins: [Pin] = [
        Pin(number: 1, signal: "MCLR/VPP", target: "MCLR (RA3)", note: "Carries the ~9 V programming voltage"),
        Pin(number: 2, signal: "VDD Target", target: "VDD", note: "Senses target voltage, or supplies it if enabled"),
        Pin(number: 3, signal: "VSS", target: "GND", note: nil),
        Pin(number: 4, signal: "PGD (ICSPDAT)", target: "ICSPDAT", note: nil),
        Pin(number: 5, signal: "PGC (ICSPCLK)", target: "ICSPCLK", note: nil),
        Pin(number: 6, signal: "PGM (LVP)", target: "Not connected", note: "This firmware disables low-voltage programming"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connecting the PICkit 3")
                .font(.title2.bold())

            HStack(alignment: .center, spacing: 28) {
                connectorDrawing
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("Pin").bold()
                        Text("PICkit 3").bold()
                        Text("RFGEN44 / PIC16(L)F1459").bold()
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(pins) { pin in
                        GridRow(alignment: .firstTextBaseline) {
                            Text("\(pin.number)")
                                .monospacedDigit()
                                .fontWeight(pin.number == 1 ? .bold : .regular)
                            Text(pin.signal)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pin.target)
                                if let note = pin.note {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Pin 1 is marked with a ▶ arrow on the PICkit 3. Line it up with pin 1 (MCLR) on the RFGEN44's programming header.", systemImage: "arrowtriangle.right.fill")
                Label("Power the RFGEN44 from its usual supply, or turn on \"Power the target from the programmer\" if nothing else powers it. Never do both.", systemImage: "bolt.trianglebadge.exclamationmark")
                Label("Keep the ICSP leads short, under 15 cm, and don't touch the board while it is being programmed.", systemImage: "ruler")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
    }

    private var connectorDrawing: some View {
        ZStack(alignment: .trailing) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 60, topTrailingRadius: 60)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14))
                .frame(width: 130, height: 170)
                .overlay(alignment: .topLeading) {
                    Text("PICkit 3")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(10)
                }
            VStack(spacing: 4) {
                ForEach(pins) { pin in
                    HStack(spacing: 4) {
                        if pin.number == 1 {
                            Image(systemName: "arrowtriangle.right.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                        }
                        Text("\(pin.number)")
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(.white)
                        Rectangle()
                            .fill(LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom))
                            .frame(width: 22, height: 8)
                    }
                }
            }
            .offset(x: 22)
        }
        .padding(.trailing, 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PICkit 3 six-pin header, pin 1 marked with an arrow")
    }
}
