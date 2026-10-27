import Cocoa
import Carbon
import SwiftUI

let sw = Switcher()
let tapCallback: CGEventTapCallBack = { _, type, event, _ in sw.handle(type: type, event: event) }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var settingsWindow: NSWindow?
    let updater = Updater()
    var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        setupMainMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        if let err = sw.layouts.load() { alert(err) }
        sw.onChange = { [weak self] in self?.refreshTitle() }
        sw.updateFrontApp(NSWorkspace.shared.frontmostApplication)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            sw.updateFrontApp(n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            self?.refreshTitle()
        }
        dnc.addObserver(forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main) { _ in
            _ = sw.layouts.load()
        }

        refreshTitle()
        updater.start()
        DispatchQueue.main.async { sw.brain.warmUp() }
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in sw.brain.warmUp() }
        if !sw.startTap() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            CGRequestListenEventAccess()
            item.button?.title = "⚠︎"
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if sw.startTap() { t.invalidate(); self?.refreshTitle() }
            }
        }
    }

    /// Без главного меню в окне настроек не работают ⌘C / ⌘V.
    func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func refreshTitle() {
        let l = sw.layouts.current()?.title ?? "··"
        let active = sw.store.config.autoSwitch && sw.frontMode == .auto
        item.button?.title = active ? l : l.lowercased()
        item.button?.toolTip = active ? "UnCarambaSwitcher: автопереключение включено"
            : "UnCarambaSwitcher: автопереключение выключено (\(sw.frontMode.title.lowercased()))"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: sw.tap == nil ? "UnCarambaSwitcher — нужны разрешения" : "UnCarambaSwitcher \(Updater.current)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        add(menu, "Автопереключение", #selector(toggleEnabled), on: sw.store.config.autoSwitch)
        add(menu, "Опечатки", #selector(toggleTypos), on: sw.store.config.typos)
        add(menu, "Ёфикатор", #selector(toggleYo), on: sw.store.config.yo)
        add(menu, "Пунктуация и слитные слова", #selector(toggleTricks), on: sw.store.config.tricks)
        add(menu, "Звуки", #selector(toggleSounds), on: sw.store.config.sounds)
        if !sw.frontBundleID.isEmpty {
            let sub = NSMenu()
            let current = sw.store.rule(for: sw.frontBundleID)?.mode
            for m in AppMode.allCases {
                let mi = NSMenuItem(title: m.title, action: #selector(setAppMode(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = m.rawValue
                mi.state = (current ?? (sw.frontIsGame && sw.store.config.gamesOff ? .off : .auto)) == m ? .on : .off
                sub.addItem(mi)
            }
            let mi = NSMenuItem(title: "В «\(sw.frontName)»", action: nil, keyEquivalent: "")
            mi.submenu = sub
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        add(menu, "Настройки…", #selector(openSettings), key: ",")
        if updater.installing {
            let mi = NSMenuItem(title: "Обновление…", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        } else if let r = updater.available {
            add(menu, "Обновить до \(r.version)…", #selector(installUpdate))
        } else {
            add(menu, "Проверить обновления", #selector(checkUpdates))
        }
        if sw.tap == nil { add(menu, "Открыть настройки разрешений…", #selector(openPrivacy)) }
        menu.addItem(.separator())
        add(menu, "Выход", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, on: Bool? = nil, key: String = "") {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        if let on { mi.state = on ? .on : .off }
        menu.addItem(mi)
    }

    @objc func toggleEnabled() { sw.store.config.autoSwitch.toggle(); refreshTitle() }
    @objc func toggleTypos() { sw.store.config.typos.toggle() }
    @objc func toggleYo() { sw.store.config.yo.toggle() }
    @objc func toggleTricks() { sw.store.config.tricks.toggle() }
    @objc func toggleSounds() { sw.store.config.sounds.toggle() }
    @objc func setAppMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = AppMode(rawValue: raw) else { return }
        sw.store.setMode(m, for: sw.frontBundleID)
        refreshTitle()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "UnCarambaSwitcher"
            w.contentView = NSHostingView(rootView: SettingsView(store: sw.store))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func checkUpdates() { updater.check(interactive: true) }
    @objc func installUpdate() { updater.install() }

    func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "UnCarambaSwitcher"
        a.informativeText = text
        a.runModal()
    }
}

// MARK: - Запуск

if CommandLine.arguments.contains("--test") {
    // Проверка логики без перехвата клавиатуры: слово и раскладка, в которой оно «набрано».
    let layouts = Layouts()
    if let err = layouts.load() { print(err); exit(1) }
    let store = Store(dir: FileManager.default.temporaryDirectory.appendingPathComponent("uncaramba-test-\(getpid())"))
    store.config.words = [WordRule(word: "спб", kind: .replace, replacement: "Санкт-Петербург")]
    let brain = Brain(layouts: layouts, store: store)
    let cases: [(String, Lang)] = [
        ("ghbdtn", .en), ("привет", .ru), ("hello", .en), ("руддщ", .ru), ("руку", .ru), ("ghbdtn?", .en), ("руддщб", .ru),
        ("ПРивет", .ru), ("GHbdtn", .en), ("yt", .en), ("не", .ru), ("rfr", .en), ("ckjdj", .en),
        ("ыщьуерштп", .ru), ("Qwerty12!", .en), ("123", .en), ("rnj-nj", .en),
        // опечатки
        ("пирвет", .ru), ("спасибл", .ru), ("малоко", .ru), ("recieve", .en), ("teh", .en), ("Москва", .ru), ("кароч", .ru), ("ошибок", .ru), ("ошибко", .ru), ("приввет", .ru), ("превет", .ru), ("helol", .en), ("tset", .en),
        // ёфикатор
        ("еще", .ru), ("все", .ru), ("желтый", .ru), ("Ее", .ru), ("tot", .en), ("ctqxfc", .en), ("удаленной", .ru), ("берет", .ru),
        // правило-замена, набранное в любой раскладке
        ("спб", .ru), ("cg,", .en),
        // пунктуация и слитные слова
        ("привет1", .ru), ("hello1", .en), ("ghbdtn1", .en), ("привет11", .ru), ("9хорошо", .ru), ("(хорошо0", .ru), ("9хорошо0", .ru),
        ("что7", .ru), ("хочуЁ", .ru), ("моё", .ru), ("пирогб", .ru), ("ошибкамиб", .ru), ("рубю", .ru), ("любю", .ru), ("сонатуБаха", .ru),
        ("helloWorld", .en), ("iPhone", .en), ("почемуто", .ru), ("чтото", .ru), ("гденибудь", .ru), ("коекто", .ru),
        ("давайка", .ru), ("всетаки", .ru), ("кембы", .ru), ("хорошобы", .ru), ("чтобы", .ru), ("также", .ru), ("2024", .ru), ("test1", .en), ("xcode", .en), ("jwt", .en), ("зумер", .ru), ("скуф", .ru), ("билде", .ru), ("билда", .ru), ("билдом", .ru), ("ghbdtyxbr", .en), ("кринжатина", .ru), (",", .en), (";", .en), ("[", .en),
        // частотная модель
        ("кароч", .ru), ("bp", .en), ("jr", .en), ("lf", .en), ("приоритетнее", .ru), ("приоритетне", .ru), ("все-таки", .ru), ("Все-таки", .ru), ("Еще", .ru), ("идет", .ru), ("ребенок", .ru), ("чем", .ru), ("жены", .ru), ("небо", .ru), ("берет", .ru), ("всем", .ru), ("ckjdj", .en), ("привт", .ru), ("ghbdtyn", .en), ("vs", .en), ("he", .en), ("nj", .en), ("ok", .en), ("щл", .ru),
        ("норм", .ru), ("щас", .ru), ("вообщем", .ru), ("Вообщем", .ru), ("окк", .ru), ("ок", .ru), ("незнаю", .ru), ("зделать", .ru), ("извени", .ru), ("агенство", .ru), ("будующий", .ru), ("alot", .en), ("коек", .ru), ("джон", .ru), ("didn't", .en), ("didnt", .en), ("крч", .ru), ("ктото", .ru), ("какбудто", .ru), ("dct,otv", .en), ("dont", .en), ("малоко", .ru), ("также", .ru), ("тоже", .ru), ("сначала", .ru), ("навсегда", .ru), ("Ghbdtn", .en), ("dct", .en), ("ckjdj", .en),
    ]
    for (text, lang) in cases {
        let r = brain.decide(layouts.strokes(for: text, in: lang), typedIn: lang)
        print(text.padding(toLength: 12, withPad: " ", startingAt: 0), "->", r.map { "\($0.text)  [\($0.lang.title), \($0.kind)]" } ?? "(оставить)")
    }
    print("— live-переключение —")
    for (text, lang) in [("ghbdtn", Lang.en), ("руку", .ru)] {
        let strokes = layouts.strokes(for: text, in: lang)
        var evidence = brain.beginLiveTrigrams(typedIn: lang)
        for stroke in strokes { brain.appendLiveTrigram(stroke, to: &evidence) }
        let target = brain.liveSwitch(strokes, typedIn: lang, evidence: evidence)
        print("~\(text)".padding(toLength: 12, withPad: " ", startingAt: 0), "->", target?.title ?? "(оставить)")
    }
    print("— склейка двух слов —")
    for (a, b) in [("во", "первых"), ("во", "вторых,"), ("в", "третьих"), ("из", "за"), ("по", "прежнему"), ("по", "русски"), ("кое", "как"),
                   ("кто", "то"), ("что", "то"), ("так", "то"), ("давай", "ка"), ("по", "моему"), ("в", "общем"), ("во", "время")] {
        print("\(a) \(b)".padding(toLength: 14, withPad: " ", startingAt: 0), "->", brain.joinFix(prev: a, cur: b, .ru) ? "\(a)-\(b)" : "(оставить)")
    }
    try? FileManager.default.removeItem(at: store.dir)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
