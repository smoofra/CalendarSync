//
//  CalendarSyncApp.swift
//  CalendarSync
//
//  Created by Lawrence D'Anna on 2/5/24.
//

import SwiftUI
import EventKit
import BackgroundTasks

struct SyncStatus {
    let ok : Bool
    let t : Date
}

extension String : Error { }

actor EK {

    public enum AuthState : Int {
        case requested
        case authorized
        case denied
    }
    
    @Observable
    class State {
        var auth: AuthState? = nil
        var last_sync_status : SyncStatus? = nil
    }
    
    let state : State = State()
    let store : EKEventStore = EKEventStore()

    func request() async {
        if state.auth != nil {
            return
        }
        switch EKEventStore.authorizationStatus(for: .event)  {
        case .fullAccess, .authorized:
            state.auth = .authorized
            return
        case .notDetermined:
            break
        default:
            state.auth = .denied
            return
        }

        state.auth = .requested

        let ok : Bool
        do {
            if #available(iOS 17.0, *) {
                ok = try await store.requestFullAccessToEvents()
            } else {
                ok = try await store.requestAccess(to: .event)
            }
        } catch {
            ok = false
            print("oh no \(error)")
        }
        state.auth = ok ? .authorized : .denied
    }
    
    func doSync(from: String, to: String) throws {
        guard let source = ek.store.calendar(withIdentifier: from), let dest = ek.store.calendar(withIdentifier: to) else {
            throw "calendar no longer exists"
        }
        let p = ek.store.predicateForEvents(withStart: Date(), end: Date(timeIntervalSinceNow: 60 * 60 * 24 * 365), calendars: [source, dest])
        struct Key : Hashable {
            let title: String
            let startDate: Date
            let endDate: Date
            let isAllDay: Bool
        }
        struct Pair {
            var a, b : EKEvent?
        }
        var d = Dictionary<Key, Pair>()
        print("collecting")
        for e in ek.store.events(matching: p) {
            let k = Key(title: e.title, startDate: e.startDate, endDate: e.endDate, isAllDay: e.isAllDay)
            var pair = d[k, default: Pair()]
            if e.calendar == source {
                pair.a = e
            } else if e.calendar == dest {
                if e.notes != "synced calendar item" {
                    continue
                }
                pair.b = e
            } else {
                fatalError("OH NO")
            }
            d[k] = pair
        }
        print("copying..")
        for (k, pair) in d {
            if let orig = pair.a {
                if let clone = pair.b {
                    clone.availability = orig.availability
                    try ek.store.save(clone, span: .thisEvent, commit: false)
                } else {
                    let clone = EKEvent(eventStore: ek.store)
                    clone.notes = "synced calendar item"
                    clone.title = k.title
                    clone.startDate = k.startDate
                    clone.endDate = k.endDate
                    clone.isAllDay = k.isAllDay
                    clone.availability = orig.availability
                    clone.calendar = dest
                    try ek.store.save(clone, span: .thisEvent, commit: false)
                }
            } else if let clone = pair.b {
                try ek.store.remove(clone, span: .thisEvent, commit: false)
            }
        }
        print("commiting...")
        try ek.store.commit()
        print("done!")
    }
    
    
    func trySync(from: String, to: String, cause: String) -> SyncStatus {
        state.last_sync_status = nil
        let t = Date()
        var status : SyncStatus
        let header = cause + " " + t.description
        do {
            try doSync(from: from, to: to)
            status = SyncStatus(ok: true, t: t)
            log("\(header) ok\n")
        } catch {
            print("oh no: \(error)")
            status = SyncStatus(ok: false, t: t)
            log("\(header): \(error)")
        }
        state.last_sync_status = status
        return status
    }
}

let ek = EK()


func log(_ line: String) {
    let url = URL.documentsDirectory.appending(path: "calendar_sync_log.txt")
    let manager = FileManager.default
    if !manager.fileExists(atPath: url.path) {
        manager.createFile(atPath: url.path, contents: Data())
    }
    do {
        let f = try FileHandle(forUpdating: url)
        f.seekToEndOfFile()
        f.write(Data(line.utf8))
        try f.close()
    } catch {
        fatalError("could not write log: \(error)")
    }
}

func printLog() {
    let url = URL.documentsDirectory.appending(path: "calendar_sync_log.txt")
    do {
        let log = try String(contentsOf: url, encoding: .utf8)
        log.enumerateLines { line, stop in
            print(line)
        }

    } catch {
        print("error reading log")
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    
    @AppStorage("from") var from : String?
    @AppStorage("to") var to : String?
    @AppStorage("background") var sync_in_background : Bool = false
    

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        Task { await ek.request() }
        printLog()
        register()
        schedule()
        return true
    }
    
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "org.elder-gods.sync", using: nil) { task in
            print("WOOOOOOOOO")
            self.schedule()
            if !self.sync_in_background || ek.state.auth != .authorized {
                task.setTaskCompleted(success: true)
                return
            }
            guard let from = self.from, let to = self.to else {
                task.setTaskCompleted(success: true)
                return
            }
            Task {
                let status = await ek.trySync(from: from, to: to, cause: "background")
                task.setTaskCompleted(success: status.ok)
            }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(self.storeChanged(_:)), name: .EKEventStoreChanged, object: ek.store)

        //UIApplication.shared.setMinimumBackgroundFetchInterval(1)
        print("registered")
    }
    
    @objc
    func storeChanged(_ notification:  NSNotification){
        if ek.state.auth != .authorized || !sync_in_background{
            return
        }
        guard let from = self.from, let to = self.to else {
            return
        }
        Task {
            await ek.trySync(from: from, to: to, cause: "notification")
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        print("did enter background")
        schedule()
    }
    
    func schedule() {
        let request = BGProcessingTaskRequest(identifier: "org.elder-gods.sync")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1)
        request.requiresNetworkConnectivity = true
        do {
            try BGTaskScheduler.shared.submit(request)
            print("scheduled")
        } catch {
            print("could not schedule task \(error)")
        }
    }

}


@main
struct CalendarSyncApp: App {
    
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
