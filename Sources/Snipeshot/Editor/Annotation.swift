import AppKit

/// sRGB colour, stored in edit files as `#RRGGBB` or `#RRGGBBAA`.
struct RGBA: Codable, Equatable, Hashable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat = 1

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        r = CGFloat((v >> (16 + shift)) & 0xFF) / 255
        g = CGFloat((v >> (8 + shift)) & 0xFF) / 255
        b = CGFloat((v >> shift) & 0xFF) / 255
        a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
    }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = RGBA(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad colour \(s)"))
        }
        self = c
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(a < 1 ? hex + String(format: "%02X", Int((a * 255).rounded())) : hex)
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { nsColor.cgColor }
    func withAlpha(_ alpha: CGFloat) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

    /// Whether dark text reads better on top of this colour.
    var isLight: Bool { (0.299 * r + 0.587 * g + 0.114 * b) > 0.66 }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    init(_ nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? .black
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }

    static let red = RGBA(hex: "#E5342E")!
    static let orange = RGBA(hex: "#F27A1A")!
    static let yellow = RGBA(hex: "#F5C518")!
    static let green = RGBA(hex: "#2E9E5B")!
    static let blue = RGBA(hex: "#2F6FEB")!
    static let ink = RGBA(hex: "#16171A")!
    static let white = RGBA(hex: "#FFFFFF")!

    static let palette: [(name: String, color: RGBA)] = [
        ("Red", .red), ("Orange", .orange), ("Yellow", .yellow), ("Green", .green),
        ("Blue", .blue), ("Ink", .ink), ("White", .white),
    ]
}

enum AnnotationType: String, Codable, CaseIterable {
    case rectangle, ellipse, line, arrow, pen, highlighter, text, step, redaction

    /// Free rectangle with eight resize handles.
    var isBoxed: Bool { self == .rectangle || self == .ellipse || self == .redaction }
    /// Two endpoints in `points`.
    var isSegment: Bool { self == .line || self == .arrow }
    var isFreehand: Bool { self == .pen || self == .highlighter }
    var usesStroke: Bool { self != .text && self != .step && self != .redaction }
    var usesTextSize: Bool { self == .text || self == .step }
    var canFill: Bool { self == .rectangle || self == .ellipse }
}

enum Redaction: String, Codable, CaseIterable {
    case pixelate, blur, blackout

    var title: String {
        switch self {
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .blackout: return "Black out"
        }
    }
}

/// One edit on top of a capture, in image points (origin top-left).
struct Annotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: AnnotationType
    var frame: CGRect = .zero
    var points: [CGPoint] = []
    var color: RGBA = .red
    var stroke: CGFloat = 4
    var filled = false
    var text = ""
    var textSize: CGFloat = 28
    var step = 1
    var redaction: Redaction = .pixelate

    init(type: AnnotationType) { self.type = type }

    private enum CodingKeys: String, CodingKey {
        case id, type, frame, points, color, stroke, filled, text, textSize = "text_size", step, redaction
    }

    // Compact encoding: only the fields that matter for the type.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(color, forKey: .color)
        if type.isSegment || type.isFreehand {
            try c.encode(points.map { [$0.x, $0.y] }, forKey: .points)
        } else {
            try c.encode([frame.minX, frame.minY, frame.width, frame.height], forKey: .frame)
        }
        if type.usesStroke { try c.encode(stroke, forKey: .stroke) }
        if type.canFill && filled { try c.encode(true, forKey: .filled) }
        if type == .text { try c.encode(text, forKey: .text) }
        if type.usesTextSize { try c.encode(textSize, forKey: .textSize) }
        if type == .step { try c.encode(step, forKey: .step) }
        if type == .redaction { try c.encode(redaction, forKey: .redaction) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try c.decode(AnnotationType.self, forKey: .type)
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? .red
        if let f = try c.decodeIfPresent([CGFloat].self, forKey: .frame), f.count == 4 {
            frame = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
        points = (try c.decodeIfPresent([[CGFloat]].self, forKey: .points) ?? []).compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        stroke = try c.decodeIfPresent(CGFloat.self, forKey: .stroke) ?? 4
        filled = try c.decodeIfPresent(Bool.self, forKey: .filled) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        textSize = try c.decodeIfPresent(CGFloat.self, forKey: .textSize) ?? 28
        step = try c.decodeIfPresent(Int.self, forKey: .step) ?? 1
        redaction = try c.decodeIfPresent(Redaction.self, forKey: .redaction) ?? .pixelate
    }

    /// Bounds for hit testing, selection and invalidation.
    var bounds: CGRect {
        guard type.isSegment || type.isFreehand, let first = points.first else { return frame.standardized }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    mutating func offset(by d: CGVector) {
        frame = frame.offsetBy(dx: d.dx, dy: d.dy)
        points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
    }
}

/// Backdrop presets: flat or barely two-tone, never loud.
enum BackdropPreset: String, Codable, CaseIterable {
    case snow, slate, mist, sky, sage, dusk

    var title: String { rawValue.capitalized }

    var colors: [RGBA] {
        switch self {
        case .snow: return [RGBA(hex: "#F5F6F7")!, RGBA(hex: "#ECEEF0")!]
        case .slate: return [RGBA(hex: "#30343A")!, RGBA(hex: "#272A2F")!]
        case .mist: return [RGBA(hex: "#E3E8ED")!, RGBA(hex: "#CDD5DD")!]
        case .sky: return [RGBA(hex: "#D9E7F4")!, RGBA(hex: "#BCD3E9")!]
        case .sage: return [RGBA(hex: "#DCE4DA")!, RGBA(hex: "#C3D1C1")!]
        case .dusk: return [RGBA(hex: "#3A4250")!, RGBA(hex: "#1F242C")!]
        }
    }
}

enum BackdropFill: Equatable {
    case preset(BackdropPreset)
    case color(RGBA)
}

struct Backdrop: Equatable {
    var enabled = false
    var fill: BackdropFill = .preset(.mist)
    var padding: CGFloat = 48
    var radius: CGFloat = 10
    var shadow = true
}

extension Backdrop: Codable {
    private enum CodingKeys: String, CodingKey { case enabled, preset, color, padding, radius, shadow }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        if let color = try c.decodeIfPresent(RGBA.self, forKey: .color) {
            fill = .color(color)
        } else {
            fill = .preset(try c.decodeIfPresent(BackdropPreset.self, forKey: .preset) ?? .mist)
        }
        padding = try c.decodeIfPresent(CGFloat.self, forKey: .padding) ?? 48
        radius = try c.decodeIfPresent(CGFloat.self, forKey: .radius) ?? 10
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        switch fill {
        case .preset(let p): try c.encode(p, forKey: .preset)
        case .color(let rgba): try c.encode(rgba, forKey: .color)
        }
        try c.encode(padding, forKey: .padding)
        try c.encode(radius, forKey: .radius)
        try c.encode(shadow, forKey: .shadow)
    }
}

/// The edit file kept next to a capture so the original pixels are never touched.
struct EditFile: Codable, Equatable {
    static let currentFormat = 1

    var format = EditFile.currentFormat
    var scale: CGFloat
    var annotations: [Annotation]
    var crop: CGRect?
    var backdrop: Backdrop

    init(scale: CGFloat, annotations: [Annotation], crop: CGRect?, backdrop: Backdrop) {
        self.scale = scale
        self.annotations = annotations
        self.crop = crop
        self.backdrop = backdrop
    }

    private enum CodingKeys: String, CodingKey { case format, scale, annotations, crop, backdrop }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        scale = try c.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1
        annotations = try c.decodeIfPresent([Annotation].self, forKey: .annotations) ?? []
        if let f = try c.decodeIfPresent([CGFloat].self, forKey: .crop), f.count == 4 {
            crop = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
        backdrop = try c.decodeIfPresent(Backdrop.self, forKey: .backdrop) ?? Backdrop()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(scale, forKey: .scale)
        try c.encode(annotations, forKey: .annotations)
        if let crop { try c.encode([crop.minX, crop.minY, crop.width, crop.height], forKey: .crop) }
        try c.encode(backdrop, forKey: .backdrop)
    }

    var hasEdits: Bool { !annotations.isEmpty || crop != nil || backdrop.enabled }
}
