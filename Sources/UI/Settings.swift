import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: Store

    var body: some View {
        TabView {
            GeneralTab(store: store).tabItem { Text("Основные") }
            AppsTab(store: store).tabItem { Text("Программы") }
            WordsTab(store: store).tabItem { Text("Слова") }
        }
        .padding()
        .frame(width: 640, height: 480)
    }
}

struct GeneralTab: View {
    @ObservedObject var store: Store
    private let sounds = Store.systemSounds

    var body: some View {
        Form {
            Section {
                Toggle("Автоматически исправлять раскладку", isOn: $store.config.autoSwitch)
                Toggle("Менять язык одиночным нажатием Shift", isOn: $store.config.shiftSwitch)
                Toggle("Исправлять опечатки (русский и английский)", isOn: $store.config.typos)
                Toggle("Ёфикатор — расставлять «ё» там, где она однозначна", isOn: $store.config.yo)
                Toggle("Пунктуация и слитные слова: привет1 → привет!, пирогб → пирог,, почемуто → почему-то", isOn: $store.config.tricks)
                Toggle("Выключать в играх и программах из папки Games", isOn: $store.config.gamesOff)
            }
            Divider().padding(.vertical, 6)
            Section {
                Toggle("Звуки", isOn: $store.config.sounds)
                soundPicker("Звук переключения раскладки", $store.config.switchSound)
                soundPicker("Звук исправления опечатки", $store.config.typoSound)
            }
            Divider().padding(.vertical, 6)
            Text("""
            Двойной Shift — отменить последнее исправление (слово запомнится как «Не трогать») \
            или переключить слово вручную (запомнится как «Всегда переключать»).
            """)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    private func soundPicker(_ title: String, _ sel: Binding<String>) -> some View {
        let playing = Binding(get: { sel.wrappedValue }, set: { name in
            sel.wrappedValue = name
            if !name.isEmpty { NSSound(named: NSSound.Name(name))?.play() }
        })
        return Picker(title, selection: playing) {
            Text("Без звука").tag("")
            ForEach(sounds, id: \.self) { Text($0).tag($0) }
        }
        .disabled(!store.config.sounds)
    }
}

struct AppsTab: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("«Авто» — всё работает. «Только вручную» — без автоисправлений, но Shift и двойной Shift работают. «Выключено» — программа вообще не вмешивается.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(store.config.apps) { rule in
                    HStack {
                        let info = appInfo(rule.bundleID)
                        if let icon = info.icon {
                            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 22, height: 22)
                        }
                        VStack(alignment: .leading) {
                            Text(info.name)
                            if info.name != rule.bundleID {
                                Text(rule.bundleID).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Picker("", selection: modeBinding(rule.bundleID)) {
                            ForEach(AppMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Button { store.setMode(nil, for: rule.bundleID) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Menu("Добавить запущенную программу") {
                    ForEach(runningApps(), id: \.self) { id in
                        Button(appInfo(id).name) { store.setMode(.manual, for: id) }
                    }
                }
                .frame(width: 260)
                Button("Добавить из папки…", action: pickApp)
                Spacer()
            }
        }
    }

    private func modeBinding(_ id: String) -> Binding<AppMode> {
        Binding(get: { store.config.apps.first { $0.bundleID == id }?.mode ?? .auto },
                set: { m in
                    if let i = store.config.apps.firstIndex(where: { $0.bundleID == id }) { store.config.apps[i].mode = m }
                })
    }

    private func runningApps() -> [String] {
        let known = Set(store.config.apps.map(\.bundleID))
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != Bundle.main.bundleIdentifier && !known.contains($0) }
        return Array(Set(ids)).sorted { appInfo($0).name < appInfo($1).name }
    }

    private func pickApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, let url = p.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        store.setMode(.manual, for: id)
    }
}

func appInfo(_ id: String) -> (name: String, icon: NSImage?) {
    if id.hasSuffix("*") { return ("Все программы \(id)", nil) }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return (id, nil) }
    let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    return (name, NSWorkspace.shared.icon(forFile: url.path))
}

struct WordsTab: View {
    @ObservedObject var store: Store
    @State private var search = ""

    private var shown: [WordRule] {
        let q = search.lowercased()
        return q.isEmpty ? store.config.words
            : store.config.words.filter { $0.word.lowercased().contains(q) || $0.replacement.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Поиск", text: $search).textFieldStyle(.roundedBorder)
                Button("Добавить слово") {
                    search = ""
                    store.config.words.insert(WordRule(word: "", kind: .never), at: 0)
                }
            }
            List {
                ForEach(shown) { rule in
                    HStack {
                        TextField("слово", text: binding(rule, \.word)).frame(width: 160)
                        Picker("", selection: binding(rule, \.kind)) {
                            ForEach(WordKind.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        if rule.kind == .replace {
                            TextField("на что", text: binding(rule, \.replacement))
                        } else {
                            Spacer()
                        }
                        Button { store.config.words.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Text("Слов: \(store.config.words.count). Двойной Shift добавляет сюда слова сам.")
                    .font(.callout).foregroundColor(.secondary)
                Spacer()
                Button("Импорт правил…", action: importRules)
                Button("Экспорт…", action: exportRules)
            }
        }
    }

    private func binding<T>(_ rule: WordRule, _ path: WritableKeyPath<WordRule, T>) -> Binding<T> {
        let id = rule.id
        return Binding(get: { (store.config.words.first { $0.id == id } ?? rule)[keyPath: path] },
                set: { v in
                    if let i = store.config.words.firstIndex(where: { $0.id == id }) { store.config.words[i][keyPath: path] = v }
                })
    }

    private func importRules() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json, .plainText]
        guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) else { return }
        var incoming: [WordRule] = []
        if let rules = try? JSONDecoder().decode([WordRule].self, from: data) {
            incoming = rules.map { WordRule(word: $0.word, kind: $0.kind, replacement: $0.replacement) }
        } else if let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let w = parts.first, !w.isEmpty, !w.hasPrefix("#") else { continue }
                incoming.append(parts.count > 1 ? WordRule(word: w, kind: .replace, replacement: parts[1]) : WordRule(word: w, kind: .never))
            }
        }
        let existing = Set(store.config.words.map { $0.word.lowercased() })
        store.config.words += incoming.filter { !existing.contains($0.word.lowercased()) }
    }

    private func exportRules() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "uncaramba-words.json"
        guard p.runModal() == .OK, let url = p.url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(store.config.words).write(to: url)
    }
}
