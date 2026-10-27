// Языковая логика: что сделать с только что набранным словом.
// Решения принимаются только по модели (FreqModel): частоты из субтитров + полный словарь словоформ.

import Cocoa

struct Decision {
    enum Kind { case switchLayout, typo, caps, yo, replace }
    let lang: Lang
    let text: String
    let kind: Kind
}

final class Brain {
    let layouts: Layouts
    let store: Store
    let models: [Lang: FreqModel]
    var lastLang: Lang?  // язык предыдущего слова — контекст

    /// Порог «живого» слова: встречается хотя бы раз на миллион слов.
    static let common = 1.0
    /// Слова из полного словаря без единого употребления в субтитрах имеют частоту 1 на всю выборку — это меньше 0.05 на миллион.
    static let dictionaryOnly = 0.05

    static let singles: [Lang: Set<String>] = [.en: ["a", "i"], .ru: ["а", "в", "и", "к", "о", "с", "у", "я", "ж", "б"]]
    static let alphabet: [Lang: [Character]] = [.en: Array("abcdefghijklmnopqrstuvwxyz"), .ru: Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюя")]
    /// Сокращения с точкой: рубю -> руб.
    static let abbreviations: Set<String> = ["руб", "коп", "тыс", "млн", "млрд", "ул", "кв", "тд", "тп", "др", "пр", "см", "стр", "рис",
                                             "тел", "доб", "мин", "макс", "сек", "кг", "км", "шт", "долл", "проф", "доц", "акад", "т.д", "т.п"]
    /// по-… через дефис: остальное «по …» бывает и раздельно (по моему мнению), его не трогаем.
    static let poAdverbs: Set<String> = ["прежнему", "другому", "настоящему", "разному", "любому", "честному", "нормальному", "всякому", "иному"]

    init(layouts: Layouts, store: Store) {
        self.layouts = layouts
        self.store = store
        var m: [Lang: FreqModel] = [:]
        for l in [Lang.en, .ru] { m[l] = FreqModel.load(l) }
        models = m
    }

    var config: Config { store.config }

    // MARK: Слова и частоты

    func core(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.letters.inverted)
    }

    /// Заменяет «ядро» слова, не трогая знаки препинания вокруг.
    private func swapCore(_ text: String, _ new: String) -> String {
        let c = core(text)
        guard let r = text.range(of: c) else { return new }
        return text.replacingCharacters(in: r, with: new)
    }

    private func alphabetOK(_ w: String, _ l: Lang) -> Bool {
        w.unicodeScalars.allSatisfy { sc in
            if "-'’ ".unicodeScalars.contains(sc) { return true }
            switch l {
            case .en: return ("a"..."z").contains(sc) || ("A"..."Z").contains(sc)
            case .ru: return (0x0410...0x044F).contains(sc.value) || sc.value == 0x0401 || sc.value == 0x0451
            }
        }
    }

    private func langOf(_ s: String) -> Lang? {
        if alphabetOK(core(s), .ru) { return .ru }
        if alphabetOK(core(s), .en) { return .en }
        return nil
    }

    /// Частота на миллион; для нескольких слов через пробел — частота самого редкого.
    func freq(_ w: String, _ l: Lang) -> Double {
        guard !w.isEmpty, alphabetOK(w, l), let m = models[l] else { return 0 }
        if w.contains(" ") { return w.split(separator: " ").map { freq(String($0), l) }.min() ?? 0 }
        return m.perMillion(w)
    }

    /// Слово существует: есть в модели (субтитры + полный словарь) или в ваших словах «Не трогать».
    func known(_ w: String, _ l: Lang) -> Bool {
        if w.count == 1 { return Brain.singles[l]!.contains(w.lowercased()) }
        return freq(w, l) > 0 || store.never.contains(w.lowercased())
    }

    // MARK: Мелкие правила

    /// «ПРивет» -> «Привет»
    func capsFix(_ s: String) -> String? {
        let ch = Array(s)
        let letters = ch.filter { $0.isLetter }
        guard letters.count >= 3, letters[0].isUppercase, letters[1].isUppercase,
              letters.dropFirst(2).allSatisfy({ $0.isLowercase }),
              let i = ch.firstIndex(where: { $0.isLetter }), let j = ch[(i + 1)...].firstIndex(where: { $0.isLetter })
        else { return nil }
        var out = ch
        out[j] = Character(String(ch[j]).lowercased())
        return String(out)
    }

    /// Сложный пароль: длиннее 6 символов, есть строчные, заглавные и цифры/знаки.
    func looksLikePassword(_ s: String) -> Bool {
        guard s.count > 6 else { return false }
        let lower = s.contains { $0.isASCII && $0.isLowercase }
        let upper = s.contains { $0.isASCII && $0.isUppercase }
        let other = s.contains { $0.isNumber || ($0.isASCII && $0.isPunctuation) || ($0.isASCII && $0.isSymbol) }
        return lower && upper && other
    }

    private func matchCase(_ rep: String, like orig: String) -> String {
        let letters = orig.filter { $0.isLetter }
        if letters.count > 1 && letters.allSatisfy({ $0.isUppercase }) { return rep.uppercased() }
        if letters.first?.isUppercase == true { return rep.prefix(1).uppercased() + rep.dropFirst() }
        return rep
    }

    // MARK: Опечатки

    /// Перебираем все варианты на одну правку от слова и берём лучший по «вес правки × частота в модели».
    /// Никаких правил под конкретные слова: «вообщем» -> «в общем», «зделать» -> «сделать» находит сама модель.
    /// Если даже лучший вариант слишком редкий — слово не трогаем (лучше не исправить, чем испортить).
    func typoFix(_ text: String, _ l: Lang, minScore: Double = Brain.common) -> String? {
        let c = core(text)
        guard c.count >= 3, alphabetOK(c, l), store.never.contains(c.lowercased()) == false else { return nil }
        // заглавные внутри слова — бренд или код (iPhone, YouTube, JavaScript), не опечатка
        guard !c.dropFirst().contains(where: { $0.isUppercase }) || c.allSatisfy({ !$0.isLowercase }) else { return nil }
        // слово есть в модели (частоты, сленг, полный словарь) — значит, это не ошибка, не трогаем
        guard !known(c, l) else { return nil }
        guard let (fixed, score) = bestEdit(c, l), score >= minScore else { return nil }
        return swapCore(text, matchCase(fixed, like: c))
    }

    /// Лучший вариант на одну правку: вес правки × частота. При равенстве — по алфавиту, чтобы результат был стабильным.
    func bestEdit(_ c: String, _ l: Lang) -> (String, Double)? {
        var best: (String, Double)?
        for (cand, weight) in edits(Array(c.lowercased()), l) {
            let score = editScore(cand, l) * weight
            guard score > 0 else { continue }
            if best == nil || score > best!.1 || (score == best!.1 && cand < best!.0) { best = (cand, score) }
        }
        return best
    }

    /// Частота варианта. Для двух слов — оценка частоты пары «как если бы слова шли независимо»,
    /// умноженная на 30: устойчивые пары (не знаю, в общем, a lot) на деле встречаются гораздо чаще случайных.
    func editScore(_ cand: String, _ l: Lang) -> Double {
        let parts = cand.split(separator: " ")
        guard parts.count == 2 else { return freq(cand, l) }
        guard max(parts[0].count, parts[1].count) >= 3 else { return 0 }  // «о к» — не разбиение, а мусор
        // слитно пишут короткое служебное слово со следующим: в общем, не знаю, как будто, a lot.
        // Длинное слово + что-то — это скорее редкая форма (приоритетнее ≠ приоритет не)
        guard parts[0].count <= 3 else { return 0 }
        let a = freq(String(parts[0]), l), b = freq(String(parts[1]), l)
        return a * b / 1_000_000 * 30
    }

    /// Звонкие/глухие пары — пишут, как слышат: зделать, редьким.
    private static let voicing: [Character: Character] = ["з": "с", "с": "з", "д": "т", "т": "д", "б": "п", "п": "б",
                                                          "в": "ф", "ф": "в", "г": "к", "к": "г", "ж": "ш", "ш": "ж"]
    private static let vowels: [Character: Character] = ["а": "о", "о": "а", "е": "и", "и": "е"]

    /// Все варианты на одну правку с весом — насколько правдоподобна такая ошибка.
    func edits(_ a: [Character], _ l: Lang) -> [String: Double] {
        var out: [String: Double] = [:]
        func add(_ b: [Character], _ w: Double) {
            let s = String(b)
            if w > (out[s] ?? 0) { out[s] = w }
        }
        let n = a.count
        // ё модель считает вместе с е (её расставит ёфикатор); в английском можно пропустить апостроф: dont -> don't
        let letters = Brain.alphabet[l]!.filter { $0 != "ё" } + (l == .en ? ["'"] : [])
        // переставленные соседние буквы
        for i in 0..<(n - 1) where a[i] != a[i + 1] {
            var b = a; b.swapAt(i, i + 1); add(b, 1)
        }
        // замена буквы
        for i in 0..<n {
            for s in neighbors(a[i], l) { var b = a; b[i] = s; add(b, 1) }       // соседняя клавиша
            if l == .ru {
                if let v = Brain.voicing[a[i]] { var b = a; b[i] = v; add(b, 0.6) }
                if i < n - 1, let v = Brain.vowels[a[i]] { var b = a; b[i] = v; add(b, 0.5) }  // не в окончании
            }
        }
        // пропущенная буква
        for i in 0...n {
            for ch in letters { var b = a; b.insert(ch, at: i); add(b, i == n ? 0.2 : 1) }
        }
        // лишняя буква: удвоенная или задетая соседняя клавиша — частая ошибка, любая другая — реже
        for i in 0..<n {
            let around = [i > 0 ? a[i - 1] : nil, i + 1 < n ? a[i + 1] : nil].compactMap { $0 }
            // удвоенная буква — 1, задетая соседняя клавиша — 0.5, любая другая — 0.1;
            // в начале слова лишняя буква бывает реже, а последнюю почти никогда не «отрезаем» (коек -> кое, ошибок -> ошибо)
            let doubled = around.contains { $0 == a[i] }
            let slip = around.contains { neighbors($0, l).contains(a[i]) }
            var b = a; b.remove(at: i); add(b, (doubled ? 1 : slip ? 0.5 : 0.1) * (i == 0 ? 0.5 : i == n - 1 ? 0.2 : 1))
        }
        // потерянный пробел: незнаю -> не знаю, вообщем -> в общем (оценка — в editScore)
        func splits(_ x: [Character]) {
            for i in 1..<x.count { add(Array(String(x[..<i]) + " " + String(x[i...])), 1) }
        }
        splits(a)
        // слияние с удвоенной буквой на стыке: вообщем (вообще + м) -> в общем
        for i in 0..<(n - 1) where a[i] == a[i + 1] {
            var b = a; b.remove(at: i); splits(b)
        }
        out[String(a)] = nil
        return out
    }

    // Физическое расположение клавиш (ANSI): ряды кодов клавиш и их сдвиг вправо.
    private static let keyRows: [[UInt16]] = [
        [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30],
        [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],
        [6, 7, 8, 9, 11, 45, 46, 43, 47, 44],
    ]
    private static let rowShift: [Double] = [0, 0.25, 0.75]
    private static let keyPos: [UInt16: (Double, Double)] = {
        var m: [UInt16: (Double, Double)] = [:]
        for (r, row) in keyRows.enumerated() {
            for (c, k) in row.enumerated() { m[k] = (Double(c) + rowShift[r], Double(r)) }
        }
        return m
    }()

    private var neighborCache: [Lang: [Character: [Character]]] = [:]

    /// Буквы на соседних клавишах.
    private func neighbors(_ x: Character, _ l: Lang) -> [Character] {
        if let c = neighborCache[l]?[x] { return c }
        var res: [Character] = []
        if let kx = layouts.strokes(for: String(x), in: l).first?.key, let px = Brain.keyPos[kx] {
            for (k, p) in Brain.keyPos {
                let dx = abs(px.0 - p.0), dy = abs(px.1 - p.1)
                guard (dy == 0 && dx == 1) || (dy == 1 && dx <= 0.8) else { continue }
                if let ch = layouts.render([Stroke(key: k, mods: 0)], l).first, ch.isLetter { res.append(ch) }
            }
        }
        neighborCache[l, default: [:]][x] = res
        return res
    }

    // MARK: Пунктуация и слитные слова

    /// Пунктуация мимо Shift, знаки из чужой раскладки, слипшиеся слова и частицы. nil — нечего править.
    func tricks(_ text: String, _ l: Lang) -> String? {
        guard config.tricks else { return nil }
        var t = edgeFix(text, l)
        let c = core(t)
        if c.count >= 3, !known(c, l), let f = glueFix(c, l) { t = swapCore(t, f) }
        return t == text ? nil : t
    }

    /// привет1 -> привет!, 9хорошо -> (хорошо, хорошо0 -> хорошо), что7 -> что?, хочуЁ -> хочу!
    private func edgeFix(_ text: String, _ l: Lang) -> String {
        let ch = Array(text)
        var trailing: [Character: Character] = ["1": "!", "0": ")"]
        if l == .ru { trailing["7"] = "?"; trailing["Ё"] = "!" } else { trailing["/"] = "?" }
        var i = 0, j = ch.count
        while i < j, ch[i] == "9" || ch[i] == "(" { i += 1 }
        while j > i, trailing[ch[j - 1]] != nil {
            // Ё — это промах мимо «!» только после строчной буквы (иначе это просто буква)
            if ch[j - 1] == "Ё", !(j >= 2 && ch[j - 2].isLowercase) { break }
            j -= 1
        }
        while j > i, ch[j - 1] == "!" || ch[j - 1] == ")" || ch[j - 1] == "?" { j -= 1 }
        let middle = String(ch[i..<j])
        guard middle.count >= 2, middle.allSatisfy({ $0.isLetter || $0 == "-" }), known(middle, l) else { return text }
        let head = String(ch[..<i]).replacingOccurrences(of: "9", with: "(")
        let tail = String(ch[j...].map { trailing[$0] ?? $0 })
        return head + middle + tail
    }

    /// Для слов, которых нет ни в модели, ни в словаре: перебираем варианты и берём самый частый.
    private func glueFix(_ c: String, _ l: Lang) -> String? {
        let lower = c.lowercased()
        var cands: [(String, Double)] = []

        // потерянный пробел перед заглавной: сонатуБаха -> сонату Баха (только русский: в английском это iPhone, YouTube)
        let ch = Array(c)
        if l == .ru, let i = ch.indices.dropFirst().first(where: { ch[$0].isUppercase && ch[$0 - 1].isLowercase }) {
            let left = String(ch[..<i]), right = String(ch[i...])
            if left.count >= 2, right.count >= 2, right.dropFirst().allSatisfy({ $0.isLowercase }) {
                // сама «аномалия» строчная→заглавная — сильный сигнал, достаточно, чтобы обе части существовали
                // (справа часто имя собственное, которого нет в разговорной модели)
                if known(left, l) && known(right, l) {
                    cands.append((left + " " + right, max(min(freq(left, l), freq(right, l)), Brain.common)))
                }
            }
        }
        if l == .ru {
            // точка и запятая с «английской» клавиши: пирогб -> пирог, ошибкамиб -> ошибками, рубю -> руб.
            // Ставим знак, если слово без последней буквы существует и опечатка не вероятнее (любю -> люблю, а не «люб.»)
            if let last = c.last, last == "б" || last == "ю" {
                let stem = String(c.dropLast())
                let sf = freq(stem, l)
                let isAbbr = last == "ю" && Brain.abbreviations.contains(stem.lowercased())
                if known(stem, l) || isAbbr, (bestEdit(c, l)?.1 ?? 0) <= sf {
                    cands.append((stem + (last == "б" ? "," : "."), max(sf, Brain.common)))
                }
            }
            // дефис: коекто -> кое-кто, почемуто -> почему-то (сравниваем частоту целого слова с дефисом)
            if lower.hasPrefix("кое"), c.count > 4 {
                let h = String(c.prefix(3)) + "-" + String(c.dropFirst(3))
                cands.append((h, freq(h, l)))
            }
            for suf in ["нибудь", "либо", "таки", "то", "ка"] where lower.hasSuffix(suf) && c.count > suf.count + 1 {
                let h = String(c.dropLast(suf.count)) + "-" + String(c.suffix(suf.count))
                cands.append((h, freq(h, l)))
            }
            // частицы: кембы -> кем бы, хорошобы -> хорошо бы
            for p in ["бы", "же", "ли"] where lower.hasSuffix(p) && c.count >= 4 {
                let stem = String(c.dropLast(2))
                cands.append((stem + " " + String(c.suffix(2)), freq(stem, l)))
            }
        }
        guard let best = cands.max(by: { $0.1 < $1.1 }), best.1 >= Brain.common else { return nil }
        return best.0
    }

    /// «во первых» -> «во-первых»: только пары, где раздельное написание почти всегда ошибка.
    func joinFix(prev: String, cur: String, _ l: Lang) -> Bool {
        guard l == .ru, config.tricks else { return false }
        let p = prev.lowercased(), c = core(cur).lowercased()
        guard core(prev) == prev, !c.isEmpty, cur.hasPrefix(core(cur)) else { return false }
        let joined = p + "-" + c
        let f = freq(joined, l)
        guard !store.never.contains(joined), f > 0 else { return false }
        // частицы бывают и отдельными словами, поэтому для них нужна высокая частота слитного варианта
        if ["то", "либо", "нибудь", "ка", "таки"].contains(c) {
            return f >= Brain.common && !(c == "то" && ["так", "если", "а", "и", "но", "то"].contains(p))
        }
        if p == "кое" { return true }
        if (p == "во" || p == "в") && (c.hasSuffix("ых") || c.hasSuffix("их")) { return true }   // во-первых, в-третьих
        if p == "из" && (c == "за" || c == "под") { return true }
        if p == "по" && (c.hasSuffix("ски") || c.hasSuffix("цки") || Brain.poAdverbs.contains(c)) { return true }
        return false
    }

    // MARK: Решение

    /// Ёфикатор по модели: пробуем заменить одну «е» на «ё» и смотрим, есть ли такое слово с меткой ё.
    /// Регистр букв сохраняется: Еще -> Ещё.
    func yoFix(_ word: String) -> String? {
        guard let m = models[.ru] else { return nil }
        let lower = Array(word.lowercased()), orig = Array(word)
        guard lower.count == orig.count else { return nil }
        for i in lower.indices where lower[i] == "е" {
            var cand = lower
            cand[i] = "ё"
            if m.isYo(String(cand)) {
                var out = orig
                out[i] = orig[i].isUppercase ? "Ё" : "ё"
                return String(out)
            }
        }
        return nil
    }

    /// Финальный шаг: пунктуация, слитные слова и ёфикатор.
    private func finish(_ l: Lang, _ text: String, _ kind: Decision.Kind?) -> Decision? {
        var t = text
        var k = kind
        if let tr = tricks(t, l) {
            t = tr
            k = k ?? .typo
        }
        if l == .ru && config.yo, let y = yoFix(core(t)) {
            t = swapCore(t, y)
            k = k ?? .yo
        }
        guard let k else { return nil }
        return Decision(lang: l, text: t, kind: k)
    }

    /// Стоит ли переключить раскладку: сравниваем, насколько вероятно слово в каждой из них.
    private func switchDecision(_ cur: String, _ oth: String, _ lang: Lang) -> Decision? {
        let other = lang.other
        let curCore = core(cur), othCore = core(oth)
        // набрано без единой буквы (запятая, точка с запятой) — это знак, а не слово: не переключаем («,» -> «б»)
        guard !curCore.isEmpty, !othCore.isEmpty, oth.filter({ !$0.isLetter && $0 != "-" }).count <= 1 else { return nil }
        if let f = capsFix(cur), known(core(f), lang) { return nil }
        if tricks(cur, lang) != nil { return nil }

        let curKnown = known(curCore, lang)
        if othCore.count == 1 {
            // одиночные буквы переключаем только если предыдущее слово было на том языке
            return (!curKnown && known(othCore, other) && lastLang == other) ? finish(other, oth, .switchLayout) : nil
        }
        let cand = capsFix(oth).flatMap { known(core($0), other) ? $0 : nil } ?? oth
        let othF = freq(core(cand), other)
        guard othF > 0 else { return nil }
        if !curKnown { return finish(other, cand, .switchLayout) }
        // слово существует в обеих раскладках — решает частота
        let curF = freq(curCore, lang)
        // текущее есть только в полном словаре (в живой речи не встречается), а «чужое» — живое слово
        if curF < Brain.dictionaryOnly && othF >= Brain.common { return finish(other, cand, .switchLayout) }
        // оба живые: переключаем, только если «чужое» в сотни раз частотнее и предыдущее слово было на том языке
        // (иначе «vs» посреди английского текста станет «мы»)
        if lastLang == other && othF >= Brain.common && othF > curF * 300 { return finish(other, cand, .switchLayout) }
        // приоритет русского: если сейчас не пишем по-английски, хватает 5-кратного перевеса (bp -> из, jr -> ок)
        if other == .ru && lastLang != .en && othF >= Brain.common && othF > curF * 5 { return finish(other, cand, .switchLayout) }
        return nil
    }

    /// Что сделать со словом, набранным в раскладке `lang`. nil — ничего.
    func decide(_ strokes: [Stroke], typedIn lang: Lang) -> Decision? {
        let other = lang.other
        let cur = layouts.render(strokes, lang), oth = layouts.render(strokes, other)
        let curCore = core(cur), othCore = core(oth)
        let key = curCore.lowercased()

        // Пользовательские правила
        for (text, c, l) in [(cur, curCore, lang), (oth, othCore, other)] {
            if let rep = store.replace[c.lowercased()] {
                return Decision(lang: langOf(rep) ?? l, text: swapCore(text, matchCase(rep, like: c)), kind: .replace)
            }
        }
        if store.never.contains(key) { return nil }
        if store.always.contains(key) { return finish(other, oth, .switchLayout) }

        if lang == .ru && looksLikePassword(oth) && !known(curCore, .ru) {
            return Decision(lang: .en, text: oth, kind: .switchLayout)
        }

        if let d = switchDecision(cur, oth, lang) { return d }

        // Слово в текущей раскладке
        if let f = capsFix(cur), known(core(f), lang) { return finish(lang, f, .caps) }
        // существующее слово не меняем — только ёфикатор и пунктуация на краях (привет1 -> привет!)
        if known(curCore, lang) { return finish(lang, cur, nil) }
        if let tr = tricks(cur, lang) { return finish(lang, tr, .typo) }

        // Опечатки: сначала в текущей раскладке, потом (строже) — в другой
        if config.typos {
            if let f = typoFix(cur, lang) { return finish(lang, f, .typo) }
            if let f = typoFix(oth, other, minScore: 5) { return finish(other, f, .switchLayout) }
        }
        return nil
    }

    /// Подтягиваем страницы модели в память заранее, а не на первом пробеле.
    func warmUp() {
        _ = freq("привет", .ru)
        _ = freq("hello", .en)
    }
}
