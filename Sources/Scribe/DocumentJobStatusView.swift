import SwiftUI

/// Pending results stay visible when moving between recordings.
struct DocumentJobStatusView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var summaries: SummaryJobs
    @EnvironmentObject private var appState: AppState

    private var pendingIDs: [UUID] {
        queue.pendingSaveIDs.union(summaries.pendingSaveIDs).union(summaries.errors.keys)
            .union(queue.automaticExportErrors.keys).sorted { $0.uuidString < $1.uuidString }
    }
    var body: some View {
        ForEach(pendingIDs, id: \.self) { id in
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(queue.pendingSaveIDs.contains(id) || summaries.pendingSaveIDs.contains(id)
                         ? "\(summaries.pendingSaveIDs.contains(id) ? "Summary" : "Transcript processing") needs to be saved"
                         : queue.automaticExportErrors[id] != nil ? "Automatic export didn't finish" : "Summary didn't finish")
                        .font(.callout.weight(.medium))
                    Button(library.document(id: id)?.title ?? "Open recording") { appState.select(document: id) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption).lineLimit(1)
                    if let error = queue.automaticExportErrors[id] {
                        Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if queue.pendingSaveIDs.contains(id) || summaries.pendingSaveIDs.contains(id) {
                    Button("Retry Save") {
                        if queue.pendingSaveIDs.contains(id) { queue.retrySave(id) }
                        if summaries.pendingSaveIDs.contains(id) { summaries.retrySave(id) }
                    }
                    .buttonStyle(.bordered)
                } else if queue.automaticExportErrors[id] != nil {
                    Button("Retry Export") { queue.retryAutomaticExport(id) }.buttonStyle(.bordered)
                    Button("Dismiss") { queue.dismissAutomaticExportError(id) }.buttonStyle(.borderless)
                } else {
                    Button("Retry") { summaries.start(id) }.buttonStyle(.bordered)
                    Button("Dismiss") { summaries.dismissError(id) }.buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.bar)
        }
    }
}
