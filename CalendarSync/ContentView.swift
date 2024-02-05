//
//  ContentView.swift
//  CalendarSync
//
//  Created by Lawrence D'Anna on 2/5/24.
//

import SwiftUI
import EventKit
import BackgroundTasks


struct ContentView: View {

    @AppStorage("from") var from : String?
    @AppStorage("to") var to : String?
    @AppStorage("background") var sync_in_background : Bool = false

    struct Choice: Identifiable {
        let calendar : EKCalendar
        let name : String
        init(calendar: EKCalendar) {
            self.calendar = calendar
            self.name = "\(calendar.source.title) - \(calendar.title)"
        }
        var id: String? {calendar.calendarIdentifier}
    }

    func calendars() -> [Choice] {
        var a : [Choice] = []
        for cal in ek.store.calendars(for: .event) {
            a.append(Choice(calendar: cal ))
        }
        a.sort { a, b in
            a.name < b.name
        }
        return a
    }

    func trySync() {
        guard let from = from, let to = to else {
            return
        }
        Task {
            await ek.trySync(from: from, to: to, background: false)
        }
    }
    
    var auth_state : String {
        switch ek.state.auth {
        case .requested, nil:
            return "requesting calendar access"
        case .authorized:
            return "calendar access granted"
        case .denied:
            return "calendar access denied"
        }
    }

    var body: some View {
        return VStack {
            if ek.state.auth != .authorized {
                Text(auth_state)
            } else {
                let choices = calendars()
                HStack {
                    Text("From:")
                    Picker("from", selection: $from) {
                        Text("pick one").tag(Optional<String>(nil))
                        ForEach(choices) {choice in
                            Text(choice.name).tag(choice.id)
                        }
                    }.accentColor(from == nil ? .gray : .blue)
                }
                HStack {
                    Text("To:")
                    Picker("to", selection: $to) {
                        Text("pick one").tag(Optional<String>(nil))
                        ForEach(choices) {choice in
                            Text(choice.name).tag(choice.id)
                        }
                    }.accentColor(to == nil ? .gray : .blue)
                }
                Toggle(isOn: $sync_in_background) {
                    Text("Sync In Background")
                }.frame(maxWidth: 300)
                Button(action: trySync) {
                    Text("Sync")
                }.padding().disabled(from == nil || to == nil).buttonStyle(.borderedProminent)
                if let status = ek.state.last_sync_status {
                    Text(status.t.description(with:Locale.current))
                    Text(status.ok ? "ok ✅" : "failed ❌")
                }

            }
        }
        .padding()
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
