import SwiftUI
import AppKit

/// Live mitlaufende Ausgabe der Python-Läufe.
struct LogView: View {
    @EnvironmentObject var log: LogStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: log.lines.count) {
                    proxy.scrollTo(log.lines.count - 1, anchor: .bottom)
                }
            }

            Divider()

            HStack {
                Text("\(log.lines.count) Zeilen")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([log.logFileURL])
                }
                Button("Leeren") { log.clear() }
            }
            .padding(8)
        }
        .frame(minWidth: 720, minHeight: 420)
    }
}
