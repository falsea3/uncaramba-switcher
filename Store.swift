// Настройки, программы-исключения и слова-исключения. Всё хранится в config.json.

import Cocoa

/// Как программа ведёт себя в конкретном приложении.
enum AppMode: String, Codable, CaseIterable {
    case auto, manual, off
    var title: String {
        switch self {
        case .auto: return "Авто"
        case .manual: return "Только вручную"
        case .off: return "Выключено"
        }
    }
}

enum WordKind: String, Codable, CaseIterable {
    case never, always, replace
    var title: String {
        switch self {
        case .never: return "Не трогать"
        case .always: return "Всегда переключать"
        case .replace: return "Заменять на…"
        }
    }
}

struct WordRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var word: String
    var kind: WordKind
    var replacement = ""
}

struct AppRule: Codable, Identifiable, Hashable {
    var bundleID: String   // может заканчиваться на * — тогда это префикс
    var mode: AppMode
    var id: String { bundleID }
}

struct Config {
    var autoSwitch = true
    var shiftSwitch = true
    var typos = true
    var yo = true
    var tricks = true
    var gamesOff = true
    var sounds = true
    var switchSound = "Tink"
    var typoSound = "Pop"
    var apps: [AppRule] = Config.defaultApps
    var words: [WordRule] = []

    static let defaultApps: [AppRule] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.apple.dt.Xcode", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4", "com.jetbrains.*",
        "com.google.android.studio", "com.valvesoftware.steam",
    ].map { AppRule(bundleID: $0, mode: .manual) } + [AppRule(bundleID: "com.microsoft.rdc.macos", mode: .off)]
}

extension Config: Codable {
    enum CodingKeys: String, CodingKey {
        case autoSwitch, shiftSwitch, typos, yo, tricks, gamesOff, sounds, switchSound, typoSound, apps, words
    }

    // Недостающие в файле поля берутся по умолчанию — так старый config.json переживёт обновления.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        autoSwitch = try c.decodeIfPresent(Bool.self, forKey: .autoSwitch) ?? d.autoSwitch
        shiftSwitch = try c.decodeIfPresent(Bool.self, forKey: .shiftSwitch) ?? d.shiftSwitch
        typos = try c.decodeIfPresent(Bool.self, forKey: .typos) ?? d.typos
        yo = try c.decodeIfPresent(Bool.self, forKey: .yo) ?? d.yo
        tricks = try c.decodeIfPresent(Bool.self, forKey: .tricks) ?? d.tricks
        gamesOff = try c.decodeIfPresent(Bool.self, forKey: .gamesOff) ?? d.gamesOff
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        switchSound = try c.decodeIfPresent(String.self, forKey: .switchSound) ?? d.switchSound
        typoSound = try c.decodeIfPresent(String.self, forKey: .typoSound) ?? d.typoSound
        apps = try c.decodeIfPresent([AppRule].self, forKey: .apps) ?? d.apps
        words = try c.decodeIfPresent([WordRule].self, forKey: .words) ?? d.words
    }
}

final class Store: ObservableObject {
    let dir: URL
    @Published var config = Config() {
        didSet { rebuild(); save() }
    }

    // Быстрые таблицы для проверки слов (ключ — слово в нижнем регистре)
    private(set) var never: Set<String> = []
    private(set) var always: Set<String> = []
    private(set) var replace: [String: String] = [:]

    init(dir: URL? = nil) {
        self.dir = dir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UnCarambaSwitcher")
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: configFile), let c = try? JSONDecoder().decode(Config.self, from: data) {
            config = c
        } else {
            migrateTxt()
        }
        rebuild()
    }

    var configFile: URL { dir.appendingPathComponent("config.json") }

    /// Перенос выученных слов из первой версии (never.txt / always.txt).
    private func migrateTxt() {
        func lines(_ n: String) -> [String] {
            ((try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)) ?? "")
                .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        config.words = lines("never.txt").map { WordRule(word: $0, kind: .never) }
            + lines("always.txt").map { WordRule(word: $0, kind: .always) }
    }

    private func rebuild() {
        never = []; always = []; replace = [:]
        for w in config.words {
            let k = w.word.trimmingCharacters(in: .whitespaces).lowercased()
            guard !k.isEmpty else { continue }
            switch w.kind {
            case .never: never.insert(k)
            case .always: always.insert(k)
            case .replace: if !w.replacement.isEmpty { replace[k] = w.replacement }
            }
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(config) { try? data.write(to: configFile, options: .atomic) }
    }

    /// Запоминает слово после двойного Shift (nil — забыть).
    func learn(_ word: String, _ kind: WordKind?) {
        let k = word.lowercased()
        guard !k.isEmpty else { return }
        var words = config.words.filter { !($0.kind != .replace && $0.word.lowercased() == k) }
        if let kind { words.insert(WordRule(word: k, kind: kind), at: 0) }
        config.words = words
    }

    func rule(for bundleID: String) -> AppRule? {
        config.apps.first { $0.bundleID == bundleID }
            ?? config.apps.first { $0.bundleID.hasSuffix("*") && bundleID.hasPrefix(String($0.bundleID.dropLast())) }
    }

    func setMode(_ mode: AppMode?, for bundleID: String) {
        var apps = config.apps.filter { $0.bundleID != bundleID }
        if let mode { apps.append(AppRule(bundleID: bundleID, mode: mode)) }
        config.apps = apps
    }

    static var systemSounds: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return files.map { ($0 as NSString).deletingPathExtension }.sorted()
    }

    func play(_ name: String) {
        guard config.sounds, !name.isEmpty else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
