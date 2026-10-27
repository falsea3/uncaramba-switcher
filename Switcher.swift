// Перехват клавиатуры: буфер слова, одиночный/двойной Shift, отправка исправлений.

import Cocoa

final class Switcher {
    let layouts = Layouts()
    let store = Store()
    lazy var brain = Brain(layouts: layouts, store: store)

    var tap: CFMachPort?
    var frontBundleID = ""
    var frontName = ""
    var frontIsGame = false

    var buffer: [Stroke] = []
    var keySerial = 0  // растёт на каждое нажатие — чтобы не исправлять, если вы уже печатаете дальше
    var bufferLang: Lang = .en
    var lastWord: WordRecord?

    var shiftCandidate = false
    var shiftDownAt = Date.distantPast
    var lastShiftTap = Date.distantPast
    var pendingSingle: Timer?

    var onChange: (() -> Void)?

    /// Режим для активной программы с учётом правил и игр.
    var frontMode: AppMode {
        if let r = store.rule(for: frontBundleID) { return r.mode }
        if frontIsGame && store.config.gamesOff { return .off }
        return .auto
    }

    func pass(_ e: CGEvent) -> Unmanaged<CGEvent>? { Unmanaged.passUnretained(e) }

    func resetAll() {
        buffer.removeAll()
        lastWord = nil
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass(event)
        }
        // наши собственные события, окно настроек и выключенные программы не трогаем
        if event.getIntegerValueField(.eventSourceUserData) == MAGIC || NSApp.isActive || frontMode == .off {
            return pass(event)
        }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            shiftCandidate = false
            resetAll()
        case .flagsChanged:
            handleFlags(event)
        case .keyDown:
            shiftCandidate = false
            return keyDown(event)
        default: break
        }
        return pass(event)
    }

    // MARK: Одиночный и двойной Shift

    func handleFlags(_ e: CGEvent) {
        let key = UInt16(e.getIntegerValueField(.keyboardEventKeycode))
        let f = e.flags
        guard key == 56 || key == 60 else { shiftCandidate = false; return }
        if f.contains(.maskShift) {
            shiftCandidate = !f.contains(.maskCommand) && !f.contains(.maskControl) && !f.contains(.maskAlternate)
            shiftDownAt = Date()
        } else if shiftCandidate {
            shiftCandidate = false
            if Date().timeIntervalSince(shiftDownAt) < 0.4 { shiftTapped() }
        }
    }

    func shiftTapped() {
        let now = Date()
        if let t = pendingSingle, now.timeIntervalSince(lastShiftTap) < 0.35 {
            t.invalidate()
            pendingSingle = nil
            doubleShift()
        } else {
            lastShiftTap = now
            pendingSingle = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                self?.pendingSingle = nil
                self?.singleShift()
            }
        }
    }

    func singleShift() {
        guard store.config.shiftSwitch, let cur = layouts.current() else { return }
        layouts.select(cur.other)
        store.play(store.config.switchSound)
        buffer.removeAll()
    }

    func doubleShift() {
        if !buffer.isEmpty {
            // ручное переключение слова, которое набирается сейчас
            let target = bufferLang.other
            replace(count: layouts.render(buffer, bufferLang).count, with: layouts.render(buffer, target))
            bufferLang = target
            layouts.select(target)
            store.play(store.config.switchSound)
            return
        }
        guard var w = lastWord, w.boundaryKey == kSpace else { return }
        let typed = layouts.render(w.strokes, w.typedLang)
        let typedKey = brain.core(typed).lowercased()
        let newLang: Lang
        let newText: String
        if w.auto {
            // отмена автоисправления + слово (или склейка) уходит в «Не трогать»
            newLang = w.typedLang
            newText = w.restore
            store.learn(w.joined ?? typedKey, .never)
        } else {
            newLang = w.shownLang.other
            newText = (w.shownText.hasPrefix(" ") ? " " : "") + layouts.render(w.strokes, newLang)
            store.learn(typedKey, newLang != w.typedLang ? .always : nil)
        }
        replace(count: w.shownText.count + 1, with: newText + " ")
        if layouts.current() != newLang { layouts.select(newLang) }
        store.play(store.config.switchSound)
        w.shownLang = newLang
        w.shownText = newText
        w.auto = false
        lastWord = w
        brain.lastLang = newLang
    }

    // MARK: Клавиши

    func keyDown(_ e: CGEvent) -> Unmanaged<CGEvent>? {
        let key = UInt16(e.getIntegerValueField(.keyboardEventKeycode))
        let f = e.flags
        keySerial &+= 1
        if f.contains(.maskCommand) || f.contains(.maskControl) || f.contains(.maskAlternate) {
            resetAll()
            return pass(e)
        }
        switch key {
        case kBackspace:
            if !buffer.isEmpty {
                buffer.removeLast()
            } else if let w = lastWord, w.boundaryKey == kSpace, w.shownText == layouts.render(w.strokes, w.shownLang) {
                // стёрли пробел — продолжаем редактировать прошлое слово
                buffer = w.strokes
                bufferLang = w.shownLang
                lastWord = nil
            } else {
                lastWord = nil
            }
            return pass(e)
        case kSpace, kReturn, kEnter, kTab:
            return boundary(key, e)
        default:
            guard layouts.isTextKey(key), let lang = layouts.current() else {
                resetAll()
                return pass(e)
            }
            if buffer.isEmpty || bufferLang != lang {
                buffer.removeAll()
                bufferLang = lang
            }
            var m = 0
            if f.contains(.maskShift) { m |= 1 }
            if f.contains(.maskAlphaShift) { m |= 2 }
            buffer.append(Stroke(key: key, mods: m))
            if buffer.count > 64 { buffer.removeAll() }
            return pass(e)
        }
    }

    func boundary(_ key: UInt16, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        let word = buffer
        let lang = bufferLang
        buffer.removeAll()
        guard !word.isEmpty else { lastWord = nil; return pass(e) }
        let typed = layouts.render(word, lang)
        let rec = WordRecord(strokes: word, typedLang: lang, shownLang: lang, shownText: typed, auto: false, boundaryKey: key, restore: typed)
        let prev = lastWord  // слово прямо перед этим (lastWord сбрасывается мышью, стрелками, двойным пробелом)
        lastWord = rec
        if typed.contains(where: { $0.isLetter }) { brain.lastLang = lang }
        guard store.config.autoSwitch && frontMode == .auto else { return pass(e) }

        if key == kSpace {
            // Пробел пропускаем сразу, слово проверяем следом — клавиатура не ждёт словаря.
            let serial = keySerial
            DispatchQueue.main.async { [self] in
                guard keySerial == serial else { return }
                let d = brain.decide(word, typedIn: lang)
                let text = d?.text ?? typed
                let textLang = d?.lang ?? lang
                // «во первых» -> «во-первых»: стираем и это слово, и пробел перед ним
                if let p = prev, p.boundaryKey == kSpace, p.shownLang == .ru, textLang == .ru,
                   brain.joinFix(prev: p.shownText, cur: text, .ru) {
                    replace(count: typed.count + 2, with: "-" + text + " ")
                    var r = rec
                    r.restore = " " + typed
                    r.joined = (p.shownText + "-" + brain.core(text)).lowercased()
                    applied(Decision(lang: textLang, text: "-" + text, kind: .typo), to: r)
                    return
                }
                guard let d, d.text != typed else { return }
                replace(count: typed.count + 1, with: d.text + " ")
                applied(d, to: rec)
            }
            return pass(e)
        }
        // Enter и Tab отправить «потом» нельзя (сообщение уже уйдёт), поэтому здесь решаем сразу.
        guard let d = brain.decide(word, typedIn: lang), d.text != typed else { return pass(e) }
        replace(count: typed.count, with: d.text)
        postKey(key, flags: e.flags.intersection(.maskShift))
        applied(d, to: rec)
        return nil  // оригинальный Enter/Tab проглатываем, мы его уже отправили
    }

    private func applied(_ d: Decision, to rec: WordRecord) {
        if d.lang != layouts.current() { layouts.select(d.lang) }
        switch d.kind {
        case .switchLayout: store.play(store.config.switchSound)
        case .typo, .caps, .replace: store.play(store.config.typoSound)
        case .yo: break
        }
        var r = rec
        r.shownLang = d.lang
        r.shownText = d.text
        r.auto = true
        lastWord = r
        brain.lastLang = d.lang
    }

    // MARK: Отправка событий

    func mark(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: MAGIC)
        e.post(tap: .cgSessionEventTap)
    }

    func postKey(_ key: UInt16, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            mark(e)
        }
    }

    func typeText(_ s: String) {
        for ch in s {
            let u = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                mark(e)
            }
        }
    }

    func replace(count: Int, with text: String) {
        for _ in 0..<count { postKey(kBackspace) }
        typeText(text)
    }

    // MARK: Активное приложение

    func updateFrontApp(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        resetAll()
        frontBundleID = app.bundleIdentifier ?? ""
        frontName = app.localizedName ?? frontBundleID
        frontIsGame = false
        if let url = app.bundleURL {
            let cat = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String ?? ""
            frontIsGame = url.path.contains("/Games/") || cat.contains("games")
        }
        onChange?()
    }

    func startTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { return false }
        tap = t
        let rl = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), rl, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }
}
