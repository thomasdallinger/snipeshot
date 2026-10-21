import AppKit
import Combine

enum Tool: String, CaseIterable, Identifiable {
    case select, rectangle, ellipse, arrow, line, pen, highlighter, text, step, redaction, crop
    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .step: return "Step number"
        case .redaction: return "Redact"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .pen: return "pencil"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .step: return "1.circle"
        case .redaction: return "eye.slash"
        case .crop: return "crop"
        }
    }

    /// Single-key shortcut while the canvas has focus.
    var key: Character {
        switch self {
        case .select: return "v"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .arrow: return "a"
        case .line: return "l"
        case .pen: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .step: return "n"
        case .redaction: return "b"
        case .crop: return "c"
        }
    }

    var annotationType: AnnotationType? {
        switch self {
        case .select, .crop: return nil
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .line: return .line
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .text: return .text
        case .step: return .step
        case .redaction: return .redaction
        }
    }

    /// Visual groups in the header; a divider sits between groups.
    static let groups: [[Tool]] = [
        [.select],
        [.rectangle, .ellipse, .arrow, .line],
        [.pen, .highlighter, .text, .step],
        [.redaction, .crop],
    ]
}

enum StrokePreset: CGFloat, CaseIterable, Identifiable {
    case small = 2, medium = 4, large = 8, extraLarge = 14
    var id: CGFloat { rawValue }
    var title: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        case .extraLarge: return "XL"
        }
    }
}

enum TextSizePreset: CGFloat, CaseIterable, Identifiable {
    case small = 18, medium = 28, large = 44
    var id: CGFloat { rawValue }
    var title: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }
}

/// The current tool and the style new annotations get. Style edits also apply to the selection.
final class ToolSettings: ObservableObject {
    @Published var tool: Tool = .arrow
    @Published var color: RGBA = .red
    @Published var stroke: CGFloat = StrokePreset.medium.rawValue
    @Published var textSize: CGFloat = TextSizePreset.medium.rawValue
    @Published var filled = false
    @Published var redaction: Redaction = .pixelate
    @Published var pendingCrop: CGRect?
    /// Short status message shown in the status bar ("Copied").
    @Published var notice: String?

    var isCropping: Bool { tool == .crop }

    private var noticeWorkItem: DispatchWorkItem?

    func notify(_ message: String) {
        noticeWorkItem?.cancel()
        notice = message
        let item = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }
}
