import Foundation
import CoreGraphics

enum L {
    static func t(_ key: String) -> String { NSLocalizedString(key, comment: "") }
    static func f(_ key: String, _ values: String...) -> String {
        String(format: t(key), locale: Locale.current, arguments: values)
    }
}

enum Launch {
    static let freePeriod = false
    static func has(_ flag: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(flag)
        #else
        false
        #endif
    }
    static var demo: Bool { has("-demo-album") }
    static var isolated: Bool { demo || has("-camera-denied") }
}

struct Corners: Codable, Equatable {
    var tl: CGPoint
    var tr: CGPoint
    var br: CGPoint
    var bl: CGPoint

    static let full = Corners(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
    static let centered = Corners(rect: CGRect(x: 0.17, y: 0.17, width: 0.66, height: 0.66))

    init(rect: CGRect) {
        tl = CGPoint(x: rect.minX, y: rect.minY)
        tr = CGPoint(x: rect.maxX, y: rect.minY)
        br = CGPoint(x: rect.maxX, y: rect.maxY)
        bl = CGPoint(x: rect.minX, y: rect.maxY)
    }

    init(tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint) {
        self.tl = tl
        self.tr = tr
        self.br = br
        self.bl = bl
    }

    var points: [CGPoint] { [tl, tr, br, bl] }
    var bounds: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }
    var area: CGFloat {
        let vertices = points
        return abs(vertices.indices.reduce(CGFloat.zero) { sum, i in
            let a = vertices[i], b = vertices[(i + 1) % 4]
            return sum + a.x * b.y - a.y * b.x
        }) / 2
    }
    var valid: Bool {
        let vertices = points
        return area >= 0.003 && vertices.allSatisfy {
            (0...1).contains($0.x) && (0...1).contains($0.y)
        } && vertices.indices.allSatisfy { i in
            let a = vertices[i], b = vertices[(i + 1) % 4], c = vertices[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) > 0.0001
        }
    }
    func moving(_ index: Int, to point: CGPoint) -> Corners {
        var result = points
        result[index] = CGPoint(x: max(0, min(1, point.x)), y: max(0, min(1, point.y)))
        let candidate = Corners(tl: result[0], tr: result[1], br: result[2], bl: result[3])
        return candidate.valid ? candidate : self
    }
    func inset(_ fraction: CGFloat) -> Corners {
        let b = bounds
        func shifted(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + (b.midX - point.x) * fraction,
                    y: point.y + (b.midY - point.y) * fraction)
        }
        return Corners(tl: shifted(tl), tr: shifted(tr), br: shifted(br), bl: shifted(bl))
    }
    static func filter(_ boxes: [Corners], single: Bool = false) -> [Corners] {
        let usable = boxes.filter { $0.valid && $0.area >= 0.011 }.sorted { $0.area > $1.area }
        if single { return usable.first.map { [$0] } ?? [] }
        let inner = usable.filter { candidate in
            let children = usable.filter {
                $0.area < candidate.area * 0.65 && candidate.bounds.insetBy(dx: -0.008, dy: -0.008).contains($0.bounds)
            }
            let hasSeparateChildren = children.indices.contains { i in
                children.dropFirst(i + 1).contains { !$0.bounds.intersects(children[i].bounds) }
            }
            return !hasSeparateChildren && (candidate.bounds.width < 0.92 || candidate.bounds.height < 0.92)
        }
        let candidates = inner.count >= 2 ? inner : usable
        var distinct: [Corners] = []
        for item in candidates where !distinct.contains(where: { accepted in
            let overlap = accepted.bounds.intersection(item.bounds)
            return !overlap.isNull && overlap.width * overlap.height > item.bounds.width * item.bounds.height * 0.70
        }) { distinct.append(item) }
        return distinct.sorted { a, b in
            let rowA = Int(a.bounds.midY / 0.17), rowB = Int(b.bounds.midY / 0.17)
            return rowA == rowB ? a.bounds.midX < b.bounds.midX : rowA < rowB
        }
    }
    static func stable(_ a: [Corners], _ b: [Corners], tolerance: CGFloat = 0.027) -> Bool {
        !a.isEmpty && a.count == b.count && zip(a, b).allSatisfy { pair in
            zip(pair.0.points, pair.1.points).allSatisfy { points in
                hypot(points.0.x - points.1.x, points.0.y - points.1.y) < tolerance
            }
        }
    }
}

struct AutoShutter {
    private var anchor: [Corners] = []
    private var anchorSignature: [Double] = []
    private var settledAt: TimeInterval = 0
    private var lastCapture: [Corners] = []
    private var lastSignature: [Double] = []
    private var departed = true
    private var emptySince: TimeInterval?

    mutating func update(boxes: [Corners], signature: [Double], now: TimeInterval) -> Bool {
        if boxes.isEmpty {
            if emptySince == nil { emptySince = now }
            if let emptySince, now - emptySince > 0.45 { departed = true }
        } else {
            emptySince = nil
        }
        guard Corners.stable(anchor, boxes), Self.signatureDelta(anchorSignature, signature) <= 0.035 else {
            anchor = boxes
            anchorSignature = signature
            settledAt = now
            return false
        }
        let change = Self.signatureDelta(lastSignature, signature)
        let changed = departed || !Corners.stable(lastCapture, boxes, tolerance: 0.047) || change > 0.085
        return changed && now - settledAt >= 1
    }

    static func signatureDelta(_ a: [Double], _ b: [Double]) -> Double {
        guard !b.isEmpty, a.count == b.count else { return 0 }
        return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(b.count)
    }

    mutating func captured(_ boxes: [Corners], signature: [Double]) {
        lastCapture = boxes
        lastSignature = signature
        departed = false
        emptySince = nil
    }

    mutating func resetStability() { anchor = [] }
}

struct PhotoDate: Codable, Equatable, Hashable {
    enum Precision: String, CaseIterable, Codable { case year, month, day, decade }
    var year: Int
    var month: Int?
    var day: Int?
    var precision: Precision = .year

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }
    var date: Date? {
        guard (1800...2100).contains(year) else { return nil }
        let targetYear = precision == .decade ? year / 10 * 10 + 5 : year
        let targetMonth = precision == .day || precision == .month ? month ?? 7 : 7
        let targetDay = precision == .day ? day ?? 1 : 1
        let calendar = Self.calendar
        guard let value = calendar.date(from: DateComponents(year: targetYear, month: targetMonth, day: targetDay, hour: 12)) else { return nil }
        let parts = calendar.dateComponents([.month, .day], from: value)
        return parts.month == targetMonth && parts.day == targetDay ? value : nil
    }
    var label: String {
        guard let date else { return "" }
        if precision == .decade { return L.f("decade_format", String(year / 10 * 10)) }
        if precision == .year { return L.f("year_format", String(year)) }
        let formatter = DateFormatter()
        formatter.calendar = Self.calendar
        formatter.timeZone = Self.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(precision == .month ? "yMMMM" : "yMMMd")
        return formatter.string(from: date)
    }

    static func ocrSuggestion(_ lines: [String]) -> PhotoDate? {
        let pattern = #"民[國国]\s*[0-9〇零○一二兩两三四五六七八九元十百]{1,7}\s*年|(?<![0-9〇零○一二兩两三四五六七八九])(?:[〇零○一二兩两三四五六七八九]{4}\s*年|(?:18\d{2}|19\d{2}|20\d{2}|2100)(?!\d))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let dates = Set(lines.compactMap(parse))
        guard dates.count == 1, let suggestion = dates.first else { return nil }
        let explicitYears = Set(lines.flatMap { line in
            let text = line.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? line
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
                Range(result.range, in: text).flatMap { parse(String(text[$0]))?.year }
            }
        })
        return explicitYears.isEmpty || explicitYears == [suggestion.year] ? suggestion : nil
    }

    static func parse(_ input: String) -> PhotoDate? {
        let text = input.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? input
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<result.numberOfRanges).map { index in
                Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
        let digits = "〇零○一二兩两三四五六七八九"
        func digit(_ character: Character) -> Int? {
            if let value = character.wholeNumberValue { return value }
            guard let index = digits.firstIndex(of: character) else { return nil }
            return [0, 0, 0, 1, 2, 2, 2, 3, 4, 5, 6, 7, 8, 9][digits.distance(from: digits.startIndex, to: index)]
        }
        func number(_ value: String) -> Int? {
            if value == "元" { return 1 }
            let hundreds = value.split(separator: "百", omittingEmptySubsequences: false)
            if hundreds.count == 2, hundreds[0].count == 1, let prefix = hundreds[0].first.flatMap(digit) {
                let suffix = String(hundreds[1])
                if suffix.isEmpty { return prefix * 100 }
                if let remainder = number(suffix), remainder < 100 { return prefix * 100 + remainder }
                return nil
            }
            if value.contains("十") {
                let tens = value.split(separator: "十", omittingEmptySubsequences: false)
                guard tens.count == 2, tens.allSatisfy({ $0.count <= 1 }) else { return nil }
                return (tens[0].first.flatMap(digit) ?? 1) * 10 + (tens[1].first.flatMap(digit) ?? 0)
            }
            let values = value.compactMap(digit)
            return values.count == value.count && !values.isEmpty ? values.reduce(0) { $0 * 10 + $1 } : nil
        }
        if match("民國|民国") != nil {
            guard let m = match("民[國国]\\s*([0-9\(digits)元十百]{1,7})\\s*年"),
                  let year = number(m[0]), (1...189).contains(year) else { return nil }
            return PhotoDate(year: year + 1911)
        }
        if let m = match("(?<![0-9\(digits)])([\(digits)]{4})\\s*年"),
           let year = number(m[0]), (1800...2100).contains(year) { return PhotoDate(year: year) }
        if let m = match(#"(?<!\d)((?:18|19|20)\d0)\s*(?:s\b|年代)"#), let year = Int(m[0]) {
            return PhotoDate(year: year, precision: .decade)
        }
        if let m = match(#"(?<!\d)((?:18|19|20)\d{2})(?:年\s*|[./-])\s*(\d{1,2})(?!\d)(?:月)?(?:\s*[./-]?\s*(\d{1,2})(?!\d)(?:日)?)?"#),
           let year = Int(m[0]), let month = Int(m[1]) {
            let day = Int(m[2])
            let result = PhotoDate(year: year, month: month, day: day, precision: day == nil ? .month : .day)
            return result.date == nil ? nil : result
        }
        if let m = match(#"\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+((?:18|19|20)\d{2})\b"#),
           let year = Int(m[1]) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let month = formatter.monthSymbols.firstIndex { $0.lowercased() == m[0].lowercased() }.map { $0 + 1 }
            return PhotoDate(year: year, month: month, precision: .month)
        }
        if let m = match(#"(?<!\d)(18\d{2}|19\d{2}|20\d{2}|2100)(?!\d)"#), let year = Int(m[0]) {
            return PhotoDate(year: year)
        }
        if let m = match(#"(?<![\d./-])(\d{2})[./](0?[1-9]|1[012])(?![\d./-])"#),
           let year = Int(m[0]), let month = Int(m[1]), year >= 20 {
            return PhotoDate(year: 1900 + year, month: month, precision: .month)
        }
        return nil
    }
}

struct Place: Codable, Equatable {
    var name: String
    var latitude: Double?
    var longitude: Double?
}

struct Album: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var title: String { name.isEmpty ? L.f("album_number", "1") : name }
}

struct Scan: Codable, Identifiable, Equatable {
    var id = UUID()
    var albumID: UUID
    var pageID: UUID
    var storageAlbumID: UUID?
    var created = Date()
    var corners: Corners
    var rotation = 0
    var whiteBorder = true
    var strength: Double = 0
    var date: PhotoDate?
    var place: Place?
    var people = ""
    var note = ""
    var backText = ""
    var suggestedDate: PhotoDate?
    var saved = false
    var reflected = false
    var glareReduced = false
    var width = 0
    var height = 0
    var revision = UUID()
    var enhancement: AppliedEnhancement?
    var unenhanced: Bool?
    var sceneTags: [SceneTag]?
    var faces: [PhotoFace]?
    var colorizable: Bool?
    var needsDate: Bool { date == nil }
}

struct Preferences: Codable {
    var autoCapture = true
    var autoRestore = true
    var autoSave = true
}

enum ScanError: Error { case image, disk, noCamera, photoAccess, alignment, invalidCode }

struct FamilyCode: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id: UUID
        var date: PhotoDate?
        var place = ""
        var people = ""
    }
    var version = 1
    var reply = false
    var entries: [Entry]

    static let prefix = "OLDPHOTO1 "
    func encode() throws -> String {
        let base64 = try JSONEncoder().encode(self).base64EncodedString()
        return Self.prefix + base64.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ input: String) throws -> FamilyCode {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(prefix), text.count < 32768 else { throw ScanError.invalidCode }
        var payload = String(text.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let code = try? JSONDecoder().decode(FamilyCode.self, from: data),
              code.version == 1, (1...9).contains(code.entries.count),
              Set(code.entries.map(\.id)).count == code.entries.count,
              code.entries.allSatisfy({ ($0.date == nil || $0.date?.date != nil)
                  && $0.people.count < 301 && $0.place.count < 301 }) else { throw ScanError.invalidCode }
        return code
    }
}
