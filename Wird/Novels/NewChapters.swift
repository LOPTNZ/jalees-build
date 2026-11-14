import UIKit
import UserNotifications
import BackgroundTasks

/// New chapters (answers-round2 س44، س45، س60): Jalees looks for them when it opens (at most once an hour), when you
/// pull the updates list, and in the background when iOS lets it. Novels you choose send a notification once N new
/// chapters have gathered, and the app icon carries the number of new chapters you haven't seen yet.
@MainActor
enum NewChapters {
    static let taskID = "com.abdullah.wird.reader.check"
    static let thresholds = [1, 3, 5, 10, 20]

    /// 0: no alerts for this novel; otherwise alert once this many new chapters have gathered.
    static func threshold(_ novel: Int) -> Int { Int(DB.shared.get("alert.\(novel)") ?? "") ?? 0 }

    static func setThreshold(_ novel: Int, _ n: Int) {
        DB.shared.set("alert.\(novel)", String(n))
        guard n > 0 else { return }
        // only chapters from now on count
        DB.shared.set("alert.last.\(novel)", String(Date().timeIntervalSince1970))
        Notify.authorize { ok in
            if !ok { DispatchQueue.main.async { Toaster.show("اسمح لجليس بالإشعارات من إعدادات الجوال") } }
        }
    }

    static var background: Bool {
        get { DB.shared.get("updates.background") != "0" }
        set { DB.shared.set("updates.background", newValue ? "1" : "0"); if newValue { schedule() } else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID) } }
    }

    static var badge: Bool {
        get { DB.shared.get("updates.badge") != "0" }
        set { DB.shared.set("updates.badge", newValue ? "1" : "0"); updateBadge() }
    }

    // MARK: checking

    private static var running = false

    /// When the last check is older than `age` seconds.
    static func checkIfDue(_ age: Double = 3600) async {
        let last = Double(DB.shared.get("updates.checked") ?? "") ?? 0
        guard !running, Date().timeIntervalSince1970 - last > age, !Novels.shared.list.filter({ !["sample", "epub", "archive"].contains($0.source) }).isEmpty else { return }
        running = true
        _ = await Novels.shared.checkAll { _ in }
        running = false
        afterCheck()
    }

    /// After any check (here, in the updates list, on a novel's page): alerts and the icon's number.
    static func afterCheck() {
        notify()
        updateBadge()
    }

    private static func notify() {
        let now = Date().timeIntervalSince1970
        for n in Novels.shared.list where threshold(n.id) > 0 {
            let since = Double(DB.shared.get("alert.last.\(n.id)") ?? "") ?? now
            let rows = DB.shared.query("SELECT num, title FROM chapters WHERE novel=? AND read=0 AND found IS NOT NULL AND found>? ORDER BY idx DESC", [n.id, since])
            guard !rows.isEmpty, rows.count >= threshold(n.id) else { continue }
            let c = UNMutableNotificationContent()
            c.title = n.title
            let k = rows.count
            c.body = (k == 1 ? "وصل فصل جديد" : (k == 2 ? "وصل فصلان جديدان" : (k <= 10 ? "وصلت \(k) فصول جديدة" : "وصل \(k) فصلًا جديدًا")))
                + (rows.first.map { r in " · آخرها الفصل " + r.str("num") } ?? "")
            c.sound = .default
            c.userInfo = ["novel": n.id, "book": n.book]
            c.threadIdentifier = "wird.ch.\(n.id)"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wird.ch.\(n.id).\(Int(now))", content: c, trigger: nil))
            DB.shared.set("alert.last.\(n.id)", String(now))
        }
    }

    /// New chapters not read and not seen in the updates list since they came.
    static var unseen: Int {
        let seen = Double(DB.shared.get("updates.seen") ?? "") ?? 0
        return DB.shared.query("SELECT COUNT(*) AS c FROM chapters WHERE read=0 AND found IS NOT NULL AND found>?", [seen]).first?.int("c") ?? 0
    }

    static func updateBadge() {
        let n = badge ? unseen : 0
        if #available(iOS 16.0, *) { UNUserNotificationCenter.current().setBadgeCount(n) } else { UIApplication.shared.applicationIconBadgeNumber = n }
    }

    /// The updates list was opened: what is in it is seen.
    static func seen() {
        DB.shared.set("updates.seen", String(Date().timeIntervalSince1970))
        updateBadge()
    }

    // MARK: in the background (iOS decides when; never more than about once an hour)

    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let t = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in handle(t) }
        }
    }

    static func schedule() {
        guard background else { return }
        let r = BGAppRefreshTaskRequest(identifier: taskID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(r)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task { @MainActor in
            _ = await Novels.shared.checkAll { _ in }
            afterCheck()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel(); task.setTaskCompleted(success: false) }
    }
}
