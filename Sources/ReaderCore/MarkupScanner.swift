import Foundation

struct MarkupTag {
    /// Lowercased name without any namespace prefix (`dc:title` becomes `title`).
    let name: String
    /// Attribute names are lowercased and keep their prefix (`epub:type`).
    let attributes: [String: String]
    let isClosing: Bool
    let isSelfClosing: Bool

    /// True when an attribute such as `epub:type` or `role` lists `value`.
    func hasType(_ values: Set<String>) -> Bool {
        for (key, value) in attributes where key == "role" || key == "type" || key.hasSuffix(":type") {
            for token in value.split(separator: " ") where values.contains(token.lowercased()) {
                return true
            }
        }
        return false
    }
}

enum MarkupEvent {
    case tag(MarkupTag)
    case text(String)
}

/// A forgiving tag scanner for XHTML, OPF, NCX and container files.
///
/// Many EPUBs (especially converted ones) are not well-formed XML, and XHTML
/// often uses HTML entities such as `&nbsp;` that XMLParser rejects. This
/// scanner never fails: anything it can't read as a tag is kept as text.
enum MarkupScanner {
    static func scan(_ data: Data, _ handle: (MarkupEvent) -> Void) {
        let b = utf8Bytes(data)
        let n = b.count
        var i = 0
        var textStart = 0

        func flushText(upTo end: Int) {
            guard end > textStart else { return }
            handle(.text(Entities.decode(String(decoding: b[textStart..<end], as: UTF8.self))))
        }

        while i < n {
            guard b[i] == UInt8(ascii: "<") else {
                i += 1
                continue
            }
            if matches(b, i, "<!--") {
                flushText(upTo: i)
                i = find(b, "-->", from: i + 4).map { $0 + 3 } ?? n
                textStart = i
            } else if matches(b, i, "<![CDATA[") {
                flushText(upTo: i)
                let start = i + 9
                let end = find(b, "]]>", from: start) ?? n
                handle(.text(String(decoding: b[start..<end], as: UTF8.self)))
                i = min(n, end + 3)
                textStart = i
            } else if i + 1 < n, b[i + 1] == UInt8(ascii: "!") || b[i + 1] == UInt8(ascii: "?") {
                flushText(upTo: i)
                i = (find(b, ">", from: i) ?? (n - 1)) + 1
                textStart = i
            } else if let (tag, end) = parseTag(b, i) {
                flushText(upTo: i)
                handle(.tag(tag))
                i = end
                if !tag.isClosing, !tag.isSelfClosing, tag.name == "script" || tag.name == "style" {
                    // Raw text: jump straight to the closing tag.
                    i = findIgnoringCase(b, "</" + tag.name, from: i) ?? n
                }
                textStart = i
            } else {
                // A stray "<", as in "a < b". Keep it as text.
                i += 1
            }
        }
        flushText(upTo: n)
    }

    private static func parseTag(_ b: [UInt8], _ start: Int) -> (MarkupTag, Int)? {
        let n = b.count
        var p = start + 1
        var isClosing = false
        if p < n, b[p] == UInt8(ascii: "/") {
            isClosing = true
            p += 1
        }
        let nameStart = p
        while p < n, isNameByte(b[p]) { p += 1 }
        guard p > nameStart, isLetter(b[nameStart]) else { return nil }
        let qualified = String(decoding: b[nameStart..<p], as: UTF8.self).lowercased()
        let name = qualified.split(separator: ":").last.map(String.init) ?? qualified

        var attributes: [String: String] = [:]
        var isSelfClosing = false
        while true {
            while p < n, isSpace(b[p]) { p += 1 }
            guard p < n else { return nil }
            if b[p] == UInt8(ascii: ">") {
                p += 1
                break
            }
            if b[p] == UInt8(ascii: "/") {
                isSelfClosing = true
                p += 1
                continue
            }
            let attributeStart = p
            while p < n, !isSpace(b[p]), b[p] != UInt8(ascii: "="), b[p] != UInt8(ascii: ">"), b[p] != UInt8(ascii: "/") {
                p += 1
            }
            if p == attributeStart {
                p += 1
                continue
            }
            let attributeName = String(decoding: b[attributeStart..<p], as: UTF8.self).lowercased()
            while p < n, isSpace(b[p]) { p += 1 }
            var value = ""
            if p < n, b[p] == UInt8(ascii: "=") {
                p += 1
                while p < n, isSpace(b[p]) { p += 1 }
                if p < n, b[p] == UInt8(ascii: "\"") || b[p] == UInt8(ascii: "'") {
                    let quote = b[p]
                    p += 1
                    let valueStart = p
                    while p < n, b[p] != quote { p += 1 }
                    value = String(decoding: b[valueStart..<min(p, n)], as: UTF8.self)
                    p += 1
                } else {
                    let valueStart = p
                    while p < n, !isSpace(b[p]), b[p] != UInt8(ascii: ">") { p += 1 }
                    value = String(decoding: b[valueStart..<p], as: UTF8.self)
                }
            }
            attributes[attributeName] = Entities.decode(value)
        }
        return (MarkupTag(name: name, attributes: attributes, isClosing: isClosing, isSelfClosing: isSelfClosing), p)
    }

    /// EPUB content should be UTF-8 or UTF-16; fall back to Windows-1252 for broken files.
    private static func utf8Bytes(_ data: Data) -> [UInt8] {
        let b = [UInt8](data)
        if b.count >= 2, (b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF) {
            return Array((String(data: data, encoding: .utf16) ?? "").utf8)
        }
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF {
            return Array(b.dropFirst(3))
        }
        if String(data: data, encoding: .utf8) == nil, let latin = String(data: data, encoding: .windowsCP1252) {
            return Array(latin.utf8)
        }
        return b
    }

    private static func matches(_ b: [UInt8], _ i: Int, _ literal: StaticString) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard i + count <= b.count else { return false }
        return literal.withUTF8Buffer { pattern in
            for k in 0..<count where b[i + k] != pattern[k] { return false }
            return true
        }
    }

    private static func find(_ b: [UInt8], _ literal: StaticString, from start: Int) -> Int? {
        var i = start
        while i < b.count {
            if matches(b, i, literal) { return i }
            i += 1
        }
        return nil
    }

    private static func findIgnoringCase(_ b: [UInt8], _ needle: String, from start: Int) -> Int? {
        let pattern = Array(needle.lowercased().utf8)
        guard !pattern.isEmpty, b.count >= pattern.count else { return nil }
        var i = start
        while i + pattern.count <= b.count {
            var k = 0
            while k < pattern.count, lower(b[i + k]) == pattern[k] { k += 1 }
            if k == pattern.count { return i }
            i += 1
        }
        return nil
    }

    private static func lower(_ c: UInt8) -> UInt8 {
        c >= 65 && c <= 90 ? c + 32 : c
    }

    private static func isLetter(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }

    private static func isNameByte(_ c: UInt8) -> Bool {
        isLetter(c) || (c >= 48 && c <= 57) || c == UInt8(ascii: ":") || c == UInt8(ascii: "-")
            || c == UInt8(ascii: "_") || c == UInt8(ascii: ".")
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C
    }
}

/// Decodes the character references found in EPUB text.
enum Entities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ensp": " ", "emsp": " ", "thinsp": " ", "hairsp": " ",
        "shy": "", "zwj": "", "zwnj": "", "lrm": "", "rlm": "",
        "mdash": "—", "ndash": "–", "minus": "−", "hellip": "…", "bull": "•", "middot": "·",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "prime": "′", "Prime": "″",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "para": "¶", "sect": "§",
        "dagger": "†", "Dagger": "‡", "times": "×", "divide": "÷", "plusmn": "±",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "sup1": "¹", "sup2": "²", "sup3": "³",
        "cent": "¢", "pound": "£", "euro": "€", "yen": "¥", "iexcl": "¡", "iquest": "¿",
        "aacute": "á", "Aacute": "Á", "agrave": "à", "Agrave": "À", "acirc": "â", "Acirc": "Â",
        "auml": "ä", "Auml": "Ä", "atilde": "ã", "Atilde": "Ã", "aring": "å", "Aring": "Å",
        "aelig": "æ", "AElig": "Æ", "ccedil": "ç", "Ccedil": "Ç",
        "eacute": "é", "Eacute": "É", "egrave": "è", "Egrave": "È", "ecirc": "ê", "Ecirc": "Ê",
        "euml": "ë", "Euml": "Ë", "iacute": "í", "Iacute": "Í", "igrave": "ì", "Igrave": "Ì",
        "icirc": "î", "Icirc": "Î", "iuml": "ï", "Iuml": "Ï", "ntilde": "ñ", "Ntilde": "Ñ",
        "oacute": "ó", "Oacute": "Ó", "ograve": "ò", "Ograve": "Ò", "ocirc": "ô", "Ocirc": "Ô",
        "ouml": "ö", "Ouml": "Ö", "otilde": "õ", "Otilde": "Õ", "oslash": "ø", "Oslash": "Ø",
        "oelig": "œ", "OElig": "Œ", "szlig": "ß", "uacute": "ú", "Uacute": "Ú", "ugrave": "ù",
        "Ugrave": "Ù", "ucirc": "û", "Ucirc": "Û", "uuml": "ü", "Uuml": "Ü", "yacute": "ý",
        "Yacute": "Ý", "yuml": "ÿ", "eth": "ð", "ETH": "Ð", "thorn": "þ", "THORN": "Þ",
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            output += rest[..<amp]
            let afterAmp = rest.index(after: amp)
            guard let semicolon = rest[afterAmp...].prefix(12).firstIndex(of: ";") else {
                output += "&"
                rest = rest[afterAmp...]
                continue
            }
            let name = rest[afterAmp..<semicolon]
            if let value = value(of: name) {
                output += value
                rest = rest[rest.index(after: semicolon)...]
            } else {
                output += "&"
                rest = rest[afterAmp...]
            }
        }
        output += rest
        return output
    }

    private static func value(of name: Substring) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let code: UInt32?
            if digits.first == "x" || digits.first == "X" {
                code = UInt32(digits.dropFirst(), radix: 16)
            } else {
                code = UInt32(digits)
            }
            guard let code, let scalar = Unicode.Scalar(code) else { return nil }
            // Soft hyphens and zero-width marks only get in the way of single words.
            if code == 0xAD || code == 0x200B || code == 0x200C || code == 0x200D || code == 0xFEFF { return "" }
            return String(Character(scalar))
        }
        return named[String(name)]
    }
}
