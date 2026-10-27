// Модель и чтение раскладок клавиатуры.

import Cocoa
import Carbon

// MARK: - Модель

enum Lang {
    case en, ru
    var other: Lang { self == .en ? .ru : .en }
    var code: String { self == .en ? "en" : "ru" }
    var title: String { self == .en ? "EN" : "RU" }
}

/// Одно нажатие: код клавиши + модификаторы (bit0 = Shift, bit1 = CapsLock).
struct Stroke {
    let key: UInt16
    let mods: Int
}

struct WordRecord {
    let strokes: [Stroke]
    let typedLang: Lang     // в какой раскладке набрано руками
    var shownLang: Lang     // что сейчас на экране
    var shownText: String
    var auto: Bool          // true, если мы сами исправили слово
    let boundaryKey: UInt16 // чем закончилось слово (пробел / enter / tab)
    var restore: String     // что вернуть при отмене (для склейки «во-первых» — оба слова через пробел)
    var joined: String? = nil  // склеенное через дефис слово, если была склейка
}

let kSpace: UInt16 = 49, kReturn: UInt16 = 36, kEnter: UInt16 = 76, kTab: UInt16 = 48, kBackspace: UInt16 = 51
let MAGIC: Int64 = 0xCA4AB4  // метка наших собственных событий

// MARK: - Раскладки

final class Layouts {
    private(set) var sources: [Lang: TISInputSource] = [:]
    private var table: [Lang: [[String]]] = [:]  // [mods][keycode] -> символ
    private var reverse: [Lang: [Character: Stroke]] = [:]

    private func prop<T>(_ s: TISInputSource, _ key: CFString) -> T? {
        guard let p = TISGetInputSourceProperty(s, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? T
    }

    private func lang(of s: TISInputSource) -> Lang? {
        let langs: [String] = prop(s, kTISPropertyInputSourceLanguages) ?? []
        guard let first = langs.first else { return nil }
        if first.hasPrefix("ru") { return .ru }
        if first.hasPrefix("en") { return .en }
        return nil
    }

    func load() -> String? {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        let list = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
        let withLayout = list.filter { TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) != nil }
        func id(_ s: TISInputSource) -> String { prop(s, kTISPropertyInputSourceID) ?? "" }
        let en = withLayout.filter { lang(of: $0) == .en }
        let ru = withLayout.filter { lang(of: $0) == .ru }
        sources[.en] = en.first { id($0) == "com.apple.keylayout.US" } ?? en.first { id($0) == "com.apple.keylayout.ABC" } ?? en.first
        sources[.ru] = ru.first { id($0) == "com.apple.keylayout.RussianWin" } ?? ru.first
        guard sources[.en] != nil, sources[.ru] != nil else {
            return "Нужны две раскладки: английская (US/ABC) и русская (лучше «Русская — ПК»)."
        }
        for l in [Lang.en, .ru] { buildTable(l) }
        return nil
    }

    private func buildTable(_ l: Lang) {
        let src = sources[l]!
        let data = Unmanaged<CFData>.fromOpaque(TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)).takeUnretainedValue() as Data
        var t = [[String]](repeating: [String](repeating: "", count: 128), count: 4)
        var rev: [Character: Stroke] = [:]
        data.withUnsafeBytes { raw in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            for m in 0..<4 {
                var carbon: UInt32 = 0
                if m & 1 != 0 { carbon |= UInt32(shiftKey >> 8) }
                if m & 2 != 0 { carbon |= UInt32(alphaLock >> 8) }
                for k in 0..<128 where k != Int(kSpace) {
                    var dead: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var len = 0
                    let st = UCKeyTranslate(layout, UInt16(k), UInt16(kUCKeyActionDown), carbon, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                    guard st == noErr, len == 1, chars[0] >= 0x21, chars[0] != 0x7F, !(0xF700...0xF8FF).contains(chars[0]) else { continue }
                    let s = String(utf16CodeUnits: chars, count: len)
                    t[m][k] = s
                    if m < 2, let c = s.first, rev[c] == nil { rev[c] = Stroke(key: UInt16(k), mods: m) }
                }
            }
        }
        table[l] = t
        reverse[l] = rev
    }

    func isTextKey(_ key: UInt16) -> Bool {
        key < 128 && !(table[.en]?[0][Int(key)].isEmpty ?? true) && !(table[.ru]?[0][Int(key)].isEmpty ?? true)
    }

    func render(_ strokes: [Stroke], _ l: Lang) -> String {
        guard let t = table[l] else { return "" }
        return strokes.map { t[$0.mods][Int($0.key)] }.joined()
    }

    /// Обратное преобразование — для режима --test.
    func strokes(for text: String, in l: Lang) -> [Stroke] {
        text.compactMap { reverse[l]?[$0] }
    }

    func current() -> Lang? {
        let cur = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return lang(of: cur)
    }

    func select(_ l: Lang) {
        if let s = sources[l] { TISSelectInputSource(s) }
    }
}
