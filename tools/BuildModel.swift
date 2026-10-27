// Собирает бинарную модель языка: одно слово — одна запись с частотой.
// Использование: BuildModel <ru|en> <subtitles.txt> <dictionary.txt> <slang.txt> <clean-dir> <output.bin>
//
// 1. Субтитры (частоты живой речи): каждое слово проверяется словарём macOS
//    (или с заглавной буквы — так проходят имена). Мусор и опечатки выбрасываются, частоты сохраняются.
// 2. Сленг из slang.txt проходит без проверки словарём.
// 3. Полный словарь словоформ: каждое слово, которое подтверждает словарь macOS и которого не было
//    в субтитрах, добавляется с частотой 1 — «слово существует, но редкое».
// 4. Ё: слово с «ё» помечается для ёфикатора, если в субтитрах его пишут через «ё» хотя бы в 25% случаев
//    (у однозначных слов — 30–45%: ещё, идёт, ребёнок; если «е»-вариант — другое слово, доля мала: чём/чем, жёны/жены).
//    Неоднозначные пары с большой долей (всё/все) — в data/yo_ambiguous_<lang>.txt.
// Промежуточные чистые файлы пишутся в <clean-dir> (чтобы их можно было посмотреть), в приложение идёт только .bin.

import Cocoa

let args = CommandLine.arguments
guard args.count == 7, args[1] == "ru" || args[1] == "en" else {
    print("usage: BuildModel ru|en subtitles.txt dictionary.txt slang.txt clean-dir output.bin")
    exit(1)
}
let lang = args[1]
let minCount = 3
let started = Date()

func alphabetOK(_ w: String) -> Bool {
    guard let f = w.unicodeScalars.first, let l = w.unicodeScalars.last,
          CharacterSet.letters.contains(f), CharacterSet.letters.contains(l) else { return false }
    return w.unicodeScalars.allSatisfy { sc in
        if sc == "-" { return true }
        if lang == "en" { return ("a"..."z").contains(sc) || sc == "'" }
        return (0x0430...0x044F).contains(sc.value) || sc.value == 0x0451
    }
}

// Проверка словарём пачками: каждый вызов NSSpellChecker — запрос к процессу AppleSpell (~0.25 мс),
// поэтому склеиваем до 20 тыс. слов через перевод строки и получаем все ошибки одним запросом.
let checker = NSSpellChecker.shared
checker.automaticallyIdentifiesLanguages = false
_ = checker.setLanguage(lang)

/// Индексы слов, которые словарь считает ошибкой.
func misspelled(_ words: [String]) -> Set<Int> {
    var bad = Set<Int>()
    var start = 0
    while start < words.count { autoreleasepool {
        // без autoreleasepool результаты всех пачек копятся в памяти до конца программы (на 8 ГБ — падение)
        let chunk = words[start..<min(start + 20_000, words.count)]
        var offsets: [Int] = []
        var text = ""
        var pos = 0
        for w in chunk {
            offsets.append(pos)
            text += w + "\n"
            pos += (w as NSString).length + 1
        }
        let results = checker.check(text, range: NSRange(location: 0, length: pos),
                                    types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                                    options: nil, inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
        for r in results {
            // какому слову принадлежит найденная ошибка
            var lo = 0, hi = offsets.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if offsets[mid] <= r.range.location { lo = mid } else { hi = mid - 1 }
            }
            bad.insert(start + lo)
        }
        start += chunk.count
    } }
    return bad
}

/// Слова, которые подтверждает словарь (или с заглавной буквы — так словарь признаёт имена).
func confirmed(_ words: [String]) -> Set<String> {
    let bad = misspelled(words)
    var ok = Set(words.indices.filter { !bad.contains($0) }.map { words[$0] })
    let retry = bad.sorted().map { words[$0] }
    let badCap = misspelled(retry.map { $0.capitalized })
    for (i, w) in retry.enumerated() where !badCap.contains(i) { ok.insert(w) }
    return ok
}

func readLines(_ path: String) -> [Substring] {
    let data = FileManager.default.contents(atPath: path) ?? Data()
    let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) ?? ""
    return text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
}

var counts: [String: Int] = [:]
var total = 0

// Сленг
var slang: [String: Int?] = [:]
for line in readLines(args[4]) where !line.hasPrefix("#") {
    let p = line.split(separator: " ")
    guard let w = p.first else { continue }
    slang[String(w).lowercased()] = p.count > 1 ? Int(p[1]) : nil
}

// Шаг 1: субтитры
// Обрывки английских сокращений (don, didn, wasn…) — это don't, didn't, wasn't: в исходных данных апострофов нет вообще.
// Имя Don при этом не теряется — оно вернётся из полного словаря как редкое слово.
let enStems: Set<String> = ["don", "isn", "aren", "didn", "doesn", "wasn", "weren", "wouldn", "couldn", "shouldn", "hasn", "hadn", "haven", "ain", "mustn", "needn"]
var droppedSubs = 0
var subs: [(String, Int)] = []
for line in readLines(args[2]) {
    let p = line.split(separator: " ")
    guard p.count == 2, let n = Int(p[1]) else { continue }
    total += n
    var w = String(p[0]).lowercased()
    if lang == "en" && enStems.contains(w) { w += "'t" }
    guard n >= minCount, alphabetOK(w) else { droppedSubs += 1; continue }
    subs.append((w, n))
}
let bypass = Set(slang.keys).union(enStems.map { $0 + "'t" })
let subsOK = confirmed(subs.map { $0.0 }.filter { !bypass.contains($0) })
for (w, n) in subs {
    guard bypass.contains(w) || subsOK.contains(w) else { droppedSubs += 1; continue }
    counts[w, default: 0] += n
}
for (w, n) in slang where alphabetOK(w) {
    counts[w] = max(counts[w] ?? 0, n ?? 100)
}
let fromSubs = counts.count

func writeClean(_ name: String, _ items: [(String, Int)]) {
    let dir = URL(fileURLWithPath: args[5])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let text = items.map { "\($0.0) \($0.1)" }.joined(separator: "\n") + "\n"
    try! text.write(to: dir.appendingPathComponent("\(lang)_\(name).txt"), atomically: true, encoding: .utf8)
}
writeClean("freq", counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) })

// Шаг 4 (до словаря — нужны только частоты живой речи): какие слова ёфикатор пишет через «ё»
let yoAmbiguous = Set(readLines("data/yo_ambiguous_\(lang).txt").filter { !$0.hasPrefix("#") }.map { String($0).lowercased() })
var yoWords: [(String, Int)] = []
for (w, n) in counts where w.contains("ё") && !yoAmbiguous.contains(w) {
    let plain = counts[w.replacingOccurrences(of: "ё", with: "е")] ?? 0
    if Double(n) / Double(n + plain) >= 0.25 { yoWords.append((w, n)) }
}
writeClean("yo", yoWords.sorted { $0.1 > $1.1 })

// Шаг 2: полный словарь словоформ с частотой 1
var dictWords: [String] = []
var seen = Set<String>()
for line in readLines(args[3]) {
    let w = String(line).trimmingCharacters(in: .whitespaces).lowercased()
    guard counts[w] == nil, alphabetOK(w), seen.insert(w).inserted else { continue }
    dictWords.append(w)
}
let dictOK = confirmed(dictWords)
let dictAdded = dictWords.filter { dictOK.contains($0) }
let droppedDict = dictWords.count - dictAdded.count
for w in dictAdded { counts[w] = 1 }
writeClean("dict", dictAdded.sorted().map { ($0, 1) })

// Шаг 3: бинарник.
// Формат: "CLM1" | UInt32 число записей | UInt64 сумма частот субтитров | записи (UInt64 хеш FNV-1a, UInt32 частота) по возрастанию хеша.
func fnv(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}
var byHash: [UInt64: UInt32] = [:]
for (w, n) in counts { byHash[fnv(w), default: 0] &+= UInt32(min(n, Int(UInt32.max / 2))) }
// метка ёфикатора: отдельная запись с ключом «ё>слово»
for (w, _) in yoWords { byHash[fnv("ё>" + w)] = 1 }

var out = Data("CLM1".utf8)
func append<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
append(UInt32(byHash.count))
append(UInt64(total))
for (h, n) in byHash.sorted(by: { $0.key < $1.key }) {
    append(h)
    append(n)
}
try! out.write(to: URL(fileURLWithPath: args[6]))

print("""
\(lang): из субтитров \(fromSubs) слов (выброшено \(droppedSubs)), из словаря +\(dictAdded.count) (выброшено \(droppedDict)), \
ё: \(yoWords.count), итого \(byHash.count) записей, \(out.count / 1024 / 1024) МБ, \(Int(Date().timeIntervalSince(started))) с
""")
