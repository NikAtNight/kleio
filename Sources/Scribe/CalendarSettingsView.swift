import EventKit
import SwiftUI

struct CalendarSettingsView: View {
    @EnvironmentObject private var calendarSync: CalendarSync

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
            }

            Section {
                Text("Calendar details stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { calendarSync.refresh() }
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
}
