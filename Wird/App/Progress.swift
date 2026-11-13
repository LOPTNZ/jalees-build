import Foundation

/// Progress rules shared by every screen that moves a book forward (05-session.js: syncStatus, afterProgress).
@MainActor
enum ProgressRules {
    /// The status that follows from the position: done at the end (unless still being published), reading once started.
    static func syncStatus(_ b: inout Book) {
        let last = max(0, b.volumes.count - 1)
        b.vi = min(max(b.vi, 0), last)
        let total = b.volumes.isEmpty ? nil : b.volumes[last].total
        let atEnd = b.vi == last && (total ?? 0) > 0 && b.pos >= (total ?? 0)
        if atEnd && !b.ongoing {
            if b.status != .done { b.status = .done; b.finish = Millis.now }
        } else if b.status == .done {
            b.status = .reading
            b.finish = nil
        } else if (b.pos > 0 || b.vi > 0) && b.status == .want {
            b.status = .reading
            if b.start == nil { b.start = Millis.now }
        }
    }

    /// After a progress change: the next volume when one ends, the status, and the finishing card when it is done.
    static func after(_ id: String, prevVi: Int, prevStatus: BookStatus) {
        var finishedVolume: String?
        var nowDone = false
        Library.shared.changeBook(id) { b in
            if b.series {
                let vols = b.volumes
                if b.vi < vols.count, let t = vols[b.vi].total, b.pos >= t, b.vi < vols.count - 1 {
                    finishedVolume = vols[b.vi].id
                    b.vi += 1
                    b.pos = 0
                } else if b.vi > prevVi, b.vi - 1 < vols.count {
                    finishedVolume = vols[b.vi - 1].id
                }
            }
            syncStatus(&b)
            nowDone = b.status == .done && prevStatus != .done
        }
        Achievements.check()
        WidgetFeed.update()
        guard let b = Library.shared.state.book(id) else { return }
        if nowDone { Flows.finish(b.id, volume: nil); return }
        if let v = finishedVolume, b.volReviews[v] == nil { Flows.finish(b.id, volume: v) }
    }

    /// Saves a new position (the quick progress sheet). Returns an error to show, or nil.
    static func save(_ id: String, vi: Int, pos: Double) -> String? {
        guard let b = Library.shared.state.book(id) else { return nil }
        let v = min(max(vi, 0), max(0, b.volumes.count - 1))
        let total = b.volumes.isEmpty ? nil : b.volumes[v].total
        let p = max(0, pos.rounded())
        if let t = total, p > t {
            return b.unit.time ? "الوقت أكبر من مدة الكتاب (\(Words.hm(t)))." : "الرقم أكبر من العدد الكلي (\(Int(t)))."
        }
        let prevVi = b.vi, prevStatus = b.status
        Library.shared.changeBook(id) { x in
            x.vi = v
            x.pos = p
            x.opened = Millis.now
        }
        after(id, prevVi: prevVi, prevStatus: prevStatus)
        if Library.shared.state.book(id)?.status != .done { ToastCenter.shared.show("تم حفظ تقدمك") }
        return nil
    }
}
