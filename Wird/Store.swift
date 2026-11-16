import UIKit

/// Durable storage: the library as one JSON file and each image as its own file, in Application Support
/// (kept in iPhone backups). Writes run on a serial queue; reads wait for pending writes.
final class Store {
    static let shared = Store()

    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "wird.store", qos: .utility)
    private let root: URL
    private let imgDir: URL
    private var keptPrevious = false
    /// the latest data a save could not write, and how many saves in a row failed (both used on the queue only)
    private var unsaved: Data?
    private var failures = 0

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wird", isDirectory: true)
        root = base
        imgDir = base.appendingPathComponent("img", isDirectory: true)
        try? fm.createDirectory(at: imgDir, withIntermediateDirectories: true)
    }

    private var stateURL: URL { root.appendingPathComponent("state.json") }

    func loadStateData() -> Data? {
        queue.sync { try? Data(contentsOf: stateURL) }
    }

    /// A copy of the library file under another name, made only if that name doesn't exist yet: never overwritten,
    /// so the library as it was before the Swift version (or a file it couldn't read) can always be brought back.
    func keepCopy(as name: String) {
        queue.sync {
            let dst = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: stateURL.path), !fm.fileExists(atPath: dst.path) else { return }
            try? fm.copyItem(at: stateURL, to: dst)
        }
    }

    /// `done` runs on the store's queue once the file is written (or skipped).
    func saveState(_ json: String, done: (() -> Void)? = nil) {
        guard let data = json.data(using: .utf8), !data.isEmpty else { done?(); return }
        queue.async {
            defer { done?() }
            // keep the version from the start of this launch, in case something goes wrong
            if !self.keptPrevious, self.fm.fileExists(atPath: self.stateURL.path) {
                let prev = self.root.appendingPathComponent("state.previous.json")
                try? self.fm.removeItem(at: prev)
                try? self.fm.copyItem(at: self.stateURL, to: prev)
                self.keptPrevious = true
            }
            self.write(data)
        }
    }

    /// Writes the library file. A failed write (a full disk, say) is logged and the data kept as unsaved: the next save
    /// replaces it with newer data, and if none comes it is tried once more after 5 s. Failing twice in a row tells the owner.
    /// (Runs on the store's queue.)
    private func write(_ data: Data) {
        do {
            try data.write(to: stateURL, options: .atomic)
            failures = 0
            unsaved = nil
        } catch {
            failures += 1
            unsaved = data
            NSLog("jalees store: saving the library failed (%d in a row): %@", failures, String(describing: error))
            if failures == 1 {
                queue.asyncAfter(deadline: .now() + 5) { if let d = self.unsaved { self.write(d) } }
            } else if failures == 2 {
                Task { @MainActor in ToastCenter.shared.show("ما انحفظت بياناتك. تأكد أن في الجوال مساحة فاضية") }
            }
        }
    }

    /// The library as it is now, kept under its own name (never overwritten). Used before a restore replaces it.
    func keepSnapshot(_ json: String, as name: String) {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return }
        queue.async {
            let dst = self.root.appendingPathComponent(name)
            guard !self.fm.fileExists(atPath: dst.path) else { return }
            do { try data.write(to: dst, options: .atomic) } catch { NSLog("jalees store: keeping %@ failed: %@", name, String(describing: error)) }
        }
    }

    private func safe(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(String.UnicodeScalarView(id.unicodeScalars.filter { allowed.contains($0) }))
    }

    private func imageURL(_ id: String) -> URL { imgDir.appendingPathComponent(safe(id)) }

    func putImage(_ id: String, dataURL: String) {
        guard !safe(id).isEmpty, let comma = dataURL.firstIndex(of: ",") else { return }
        let b64 = String(dataURL[dataURL.index(after: comma)...])
        queue.async {
            if let d = Data(base64Encoded: b64) { try? d.write(to: self.imageURL(id), options: .atomic) }
        }
    }

    func hasImage(_ id: String) -> Bool {
        guard !safe(id).isEmpty else { return false }
        return queue.sync { fm.fileExists(atPath: imageURL(id).path) }
    }

    func imageData(_ id: String) -> Data? {
        guard !safe(id).isEmpty else { return nil }
        return queue.sync { try? Data(contentsOf: imageURL(id)) }
    }

    func image(_ id: String) -> UIImage? { imageData(id).flatMap { UIImage(data: $0) } }

    func deleteImage(_ id: String) {
        guard !safe(id).isEmpty else { return }
        queue.async { try? self.fm.removeItem(at: self.imageURL(id)) }
    }

    static func mime(of d: Data) -> String {
        let b = [UInt8](d.prefix(12))
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b.count >= 12, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        return "image/jpeg"
    }
}
