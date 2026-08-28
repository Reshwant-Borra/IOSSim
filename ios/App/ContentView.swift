import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = POCViewModel()
    @State private var importing = false
    @State private var exporting = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section("Status") {
                Text(model.actionStatus)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            Section("Pairing") {
                Button("IMPORT RPPAIRING") { importing = true }
                Text(model.pairingSummary)
                    .font(.caption.monospaced())
            }

            Section("Session") {
                LabeledContent("ID", value: model.sessionID)
                LabeledContent("Elapsed", value: model.sessionElapsed)
                LabeledContent("CoreLocation", value: model.coreLocationState)
                LabeledContent("Last DVT event", value: model.lastDVTEvent)
                LabeledContent("Last CoreLocation", value: model.lastCoreLocationUpdate)
            }

            Section("Coordinates") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Requested")
                        .foregroundStyle(.secondary)
                    Text(model.requestedCoordinate)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Observed")
                        .foregroundStyle(.secondary)
                    Text(model.observedCoordinate)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section("Actions") {
                Button("RUN DIAGNOSTICS") { model.runDiagnostics() }
                Button("CONNECT") { model.connect() }
                Button("SET TEST LOCATION") { model.setTestLocation() }
                Button("CLEAR SIMULATION") { model.clear() }
                Button("DISCONNECT") { model.disconnect() }
                Button("ADD MARKER") { model.addMarker() }
                Button("EXPORT DIAGNOSTICS") {
                    model.prepareExport()
                    exporting = true
                }
            }

            Section("E1 Stages") {
                ForEach(model.stageRows) { row in
                    HStack {
                        Text(row.label)
                        Spacer()
                        Text(row.status)
                            .font(.caption.monospaced())
                    }
                    if let detail = row.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Session Timeline") {
                ForEach(model.timeline.indices.reversed(), id: \.self) { index in
                    Text(model.timeline[index])
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section("Log") {
                ForEach(model.log.indices.reversed(), id: \.self) { index in
                    Text(model.log[index])
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("On-Device DVT POC")
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.propertyList, .data, .item],
            allowsMultipleSelection: false
        ) { result in
            model.importPairing(result)
        }
        .task {
            await model.refresh()
            model.startRefreshLoop()
        }
        .onChange(of: scenePhase) { _, phase in
            model.recordScenePhase(String(describing: phase))
        }
        .sheet(isPresented: $exporting) {
            ShareSheet(activityItems: model.exportURLs)
        }
    }
}

#if canImport(UIKit)
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems.map { $0 as Any }, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
struct ShareSheet: View {
    let activityItems: [URL]

    var body: some View {
        Text(activityItems.map(\.lastPathComponent).joined(separator: "\n"))
    }
}
#endif
