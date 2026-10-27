import Cocoa

final class Updater {
    static let repo = "falsea3/uncaramba-switcher"
    static let interval: TimeInterval = 600

    struct Release {
        let version: String
        let dmg: URL
    }

    private(set) var available: Release?
    private(set) var installing = false
    private var asked: Set<String> = []
    private var timer: Timer?
    var onChange: (() -> Void)?

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: Updater.interval, repeats: true) { [weak self] _ in self?.check() }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func check(interactive: Bool = false) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            var found: Release?
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String,
               let assets = json["assets"] as? [[String: Any]],
               let dmg = assets.compactMap({ $0["browser_download_url"] as? String }).first(where: { $0.hasSuffix(".dmg") }),
               let url = URL(string: dmg) {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if Updater.isNewer(version, than: Updater.current) { found = Release(version: version, dmg: url) }
            }
            DispatchQueue.main.async {
                self.available = found
                self.onChange?()
                if let r = found, interactive || !self.asked.contains(r.version) {
                    self.asked.insert(r.version)
                    self.ask(r)
                } else if interactive {
                    self.alert("У вас последняя версия (\(Updater.current)).")
                }
            }
        }.resume()
    }

    private func ask(_ r: Release) {
        let a = NSAlert()
        a.messageText = "Доступна версия \(r.version)"
        a.informativeText = "У вас \(Updater.current). Обновить сейчас? Приложение перезапустится."
        a.addButton(withTitle: "Обновить")
        a.addButton(withTitle: "Позже")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { install(r) }
    }

    func install(_ r: Release? = nil) {
        guard let r = r ?? available, !installing else { return }
        installing = true
        onChange?()
        URLSession.shared.downloadTask(with: r.dmg) { [weak self] file, _, error in
            guard let self else { return }
            do {
                guard let file else { throw error ?? URLError(.badServerResponse) }
                try self.replaceApp(fromDMG: file)
                DispatchQueue.main.async { self.relaunch() }
            } catch {
                DispatchQueue.main.async {
                    self.installing = false
                    self.onChange?()
                    self.alert("Не удалось обновиться: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    private func replaceApp(fromDMG dmg: URL) throws {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("uncaramba-update-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noverify", "-mountpoint", mount.path])
        defer {
            try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: mount)
        }

        guard let app = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
        else { throw CocoaError(.fileNoSuchFile) }
        let dest = Bundle.main.bundleURL
        let staged = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).new")
        defer { try? fm.removeItem(at: staged) }
        try? fm.removeItem(at: staged)
        try run("/usr/bin/ditto", [app.path, staged.path])
        _ = try fm.replaceItemAt(dest, withItemAt: staged)
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"$0\"", Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "UnCarambaSwitcher"
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
