import Foundation

final class FreqModel {
    private let data: Data
    private let count: Int
    private let total: Double

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.count >= 16,
              String(decoding: d.prefix(4), as: UTF8.self) == "CLM1" else { return nil }
        data = d
        count = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian })
        total = Double(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian })
    }

    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    func rawCount(_ word: String) -> Int {
        let h = FreqModel.fnv(word)
        return data.withUnsafeBytes { raw -> Int in
            var lo = 0, hi = count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let off = 16 + mid * 12
                let mh = raw.loadUnaligned(fromByteOffset: off, as: UInt64.self).littleEndian
                if mh == h { return Int(raw.loadUnaligned(fromByteOffset: off + 8, as: UInt32.self).littleEndian) }
                if mh < h { lo = mid + 1 } else { hi = mid - 1 }
            }
            return 0
        }
    }

    func perMillion(_ word: String) -> Double {
        let w = word.lowercased()
        var n = rawCount(w)
        if w.contains("ё") { n += rawCount(w.replacingOccurrences(of: "ё", with: "е")) }
        return Double(n) / total * 1_000_000
    }

    func trigram(_ t: String) -> Double { Double(rawCount("3>" + t)) }

    func isYo(_ word: String) -> Bool { rawCount("ё>" + word) > 0 }

    static func load(_ l: Lang) -> FreqModel? {
        let name = l.code
        if let url = Bundle.main.url(forResource: name, withExtension: "bin"), let m = FreqModel(url: url) { return m }
        let local = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("model/\(name).bin")
        return FreqModel(url: local)
    }
}
