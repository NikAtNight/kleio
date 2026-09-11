import EventKit
import SwiftUI

struct CalendarSettingsView: View {
    @EnvironmentObject private var calendarSync: CalendarSync
    @State private var showsConsentSheet = false
    @State private var subscriptionURL = ""
    @State private var subscriptionError: String?

    /// EventKit cannot create subscriptions, so feed URLs are normalized to
    /// webcal:// and handed to macOS; Calendar shows its subscribe sheet and
    /// the result flows back into the list through EventKit.
    private var normalizedSubscriptionURL: URL? {
        var raw = subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        for scheme in ["https://", "http://"] where raw.lowercased().hasPrefix(scheme) {
            raw = "webcal://" + raw.dropFirst(scheme.count)
        }
        guard raw.lowercased().hasPrefix("webcal://"),
              let url = URL(string: raw), url.host?.isEmpty == false else { return nil }
        return url
    }

    private func subscribe() {
        guard let url = normalizedSubscriptionURL else {
            subscriptionError = "Enter a webcal:// or https:// calendar feed URL."
            return
        }
        subscriptionError = nil
        NSWorkspace.shared.open(url)
        subscriptionURL = ""
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show upcoming meetings", isOn: Binding(
                    get: { calendarSync.isEnabled },
                    set: { calendarSync.isEnabled = $0 }
                ))

                if calendarSync.isEnabled && calendarSync.authorizationStatus != .fullAccess {
                    Text("Calendar access is not available.")
                        .foregroundStyle(.secondary)
                    Button("Open Calendar Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
            } header: {
                Text("Calendar")
            }

            if calendarSync.isEnabled && calendarSync.authorizationStatus == .fullAccess {
                Section("Calendars") {
                    ForEach(groupedCalendars, id: \.source.sourceIdentifier) { group in
                        Text(group.source.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                            Toggle(calendar.title, isOn: selectedBinding(for: calendar.calendarIdentifier))
                        }
                    }
                }

                Section("Subscriptions") {
                    HStack(spacing: 8) {
                        TextField("webcal:// or https:// calendar feed", text: $subscriptionURL)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(subscribe)
                        Button("Subscribe", action: subscribe)
                            .disabled(normalizedSubscriptionURL == nil)
                    }
                    if let subscriptionError {
                        Text(subscriptionError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("macOS handles the subscription; the calendar appears in the list above once added. Calendars from Apple Calendar, Google, or Outlook accounts on this Mac show up automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Reminders") {
                    Picker("Notify", selection: Binding(
                        get: { calendarSync.leadMinutes },
                        set: { calendarSync.leadMinutes = $0 }
                    )) {
                        Text("At start").tag(0)
                        Text("1 minute before").tag(1)
                        Text("2 minutes before").tag(2)
                        Text("5 minutes before").tag(5)
                        Text("10 minutes before").tag(10)
                    }
                    Toggle("Only events with meeting links", isOn: Binding(
                        get: { calendarSync.onlyWithLinks },
                        set: { calendarSync.onlyWithLinks = $0 }
                    ))
                }

                Section("Auto-record") {
                    Toggle("Automatically record selected meetings", isOn: autoRecordEnabledBinding)

                    if let problem = calendarSync.autoRecordProblem {
                        Text(problem)
                            .foregroundStyle(.red)
                    }

                    if calendarSync.autoRecordEnabled {
                        Text("Kleio checks for a call locally, then gives you 10 seconds to cancel before recording starts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(groupedCalendars, id: \.source.sourceIdentifier) { group in
                            Text(group.source.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                                Toggle(calendar.title, isOn: autoRecordCalendarBinding(for: calendar.calendarIdentifier))
                            }
                        }

                        Picker("Late join window", selection: Binding(
                            get: { calendarSync.autoRecordLateJoinMinutes },
                            set: { calendarSync.autoRecordLateJoinMinutes = $0 }
                        )) {
                            Text("5 minutes").tag(5)
                            Text("10 minutes").tag(10)
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                        }

                        Picker("End grace period", selection: Binding(
                            get: { calendarSync.autoRecordGraceMinutes },
                            set: { calendarSync.autoRecordGraceMinutes = $0 }
                        )) {
                            Text("None").tag(0)
                            Text("2 minutes").tag(2)
                            Text("5 minutes").tag(5)
                            Text("10 minutes").tag(10)
                        }

                        Picker("Stop after silence", selection: Binding(
                            get: { calendarSync.autoRecordSilenceMinutes },
                            set: { calendarSync.autoRecordSilenceMinutes = $0 }
                        )) {
                            Text("1 minute").tag(1)
                            Text("2 minutes").tag(2)
                            Text("3 minutes").tag(3)
                            Text("5 minutes").tag(5)
                        }

                        Toggle("Save the meeting title and calendar event ID", isOn: Binding(
                            get: { calendarSync.storesAutoRecordEventDetails },
                            set: { calendarSync.storesAutoRecordEventDetails = $0 }
                        ))

                        Text("Audio, call detection, and transcription stay on this Mac. Kleio does not save attendees or calendar notes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text("Calendar details stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { calendarSync.refresh() }
        .sheet(isPresented: $showsConsentSheet) {
            AutoRecordConsentSheet(
                onContinue: {
                    calendarSync.hasShownAutoRecordConsent = true
                    calendarSync.autoRecordEnabled = true
                    showsConsentSheet = false
                },
                onCancel: { showsConsentSheet = false }
            )
        }
    }

    private var groupedCalendars: [(source: EKSource, calendars: [EKCalendar])] {
        Dictionary(grouping: calendarSync.availableCalendars, by: \.source)
            .map { (source: $0.key, calendars: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.source.title < $1.source.title }
    }

    private func selectedBinding(for identifier: String) -> Binding<Bool> {
        Binding(
            get: { calendarSync.selectedCalendarIDs.isEmpty || calendarSync.selectedCalendarIDs.contains(identifier) },
            set: { selected in
                var ids = Set(calendarSync.selectedCalendarIDs)
                if selected {
                    ids.insert(identifier)
                } else {
                    if ids.isEmpty {
                        ids = Set(calendarSync.availableCalendars.map(\.calendarIdentifier))
                    }
                    ids.remove(identifier)
                }
                calendarSync.selectedCalendarIDs = Array(ids)
            }
        )
    }

    private var autoRecordEnabledBinding: Binding<Bool> {
        Binding(
            get: { calendarSync.autoRecordEnabled },
            set: { enabled in
                if enabled && !calendarSync.hasShownAutoRecordConsent {
                    showsConsentSheet = true
                } else {
                    calendarSync.autoRecordEnabled = enabled
                }
            }
        )
    }

    private func autoRecordCalendarBinding(for identifier: String) -> Binding<Bool> {
        Binding(
            get: { calendarSync.autoRecordCalendarIDs.contains(identifier) },
            set: { selected in
                var ids = Set(calendarSync.autoRecordCalendarIDs)
                if selected { ids.insert(identifier) } else { ids.remove(identifier) }
                calendarSync.autoRecordCalendarIDs = Array(ids)
            }
        )
    }
}

private struct AutoRecordConsentSheet: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before auto-recording")
                .font(.title2.bold())
            Text("Kleio records and transcribes calls on this Mac. Nothing from auto-recording is uploaded.")
            Text("Recording laws differ by location. You are responsible for telling everyone on the call that you are recording and getting any consent the law requires.")
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
