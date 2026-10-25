import SwiftUI
import AppKit

enum ReadingFontStyle: String, CaseIterable, Identifiable {
    case book, modern
    var id: String { rawValue }
    var title: String { self == .book ? "书页" : "现代" }
}

enum ReadingLineSpacing: String, CaseIterable, Identifiable {
    case compact, comfortable, airy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: return "紧凑"
        case .comfortable: return "舒适"
        case .airy: return "宽松"
        }
    }
    var multiplier: CGFloat {
        switch self {
        case .compact: return 1.55
        case .comfortable: return 1.8
        case .airy: return 2.0
        }
    }
}

enum ReadingMeasure: String, CaseIterable, Identifiable {
    case compact, standard, wide
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: return "窄"
        case .standard: return "标准"
        case .wide: return "宽"
        }
    }
}

/// Shared metrics for native text, captions and the isolated formula renderer.
/// The environment stores choices, rather than a platform font object, so its
/// value remains stable across normal SwiftUI layout updates.
struct ReadingTypography: Equatable {
    var fontStyle: ReadingFontStyle
    var bodySize: CGFloat
    var spacing: ReadingLineSpacing
    var measure: ReadingMeasure

    init(fontStyle: ReadingFontStyle = .book, bodySize: CGFloat = 17,
         spacing: ReadingLineSpacing = .comfortable, measure: ReadingMeasure = .standard) {
        self.fontStyle = fontStyle
        self.bodySize = bodySize.isFinite ? min(21, max(15, bodySize)) : 17
        self.spacing = spacing
        self.measure = measure
    }

    var textWidth: CGFloat {
        switch measure {
        case .compact: return 660
        case .standard: return 820
        case .wide: return 960
        }
    }

    var figureWidth: CGFloat {
        switch measure {
        case .compact: return 820
        case .standard: return 1000
        case .wide: return 1120
        }
    }

    var lineHeight: CGFloat { spacing.multiplier }

    /// SwiftUI adds spacing to a font's natural line box; CSS line-height is the
    /// whole box. Account for the verified CJK fallback's taller metrics so the
    /// same Chinese paragraph has comparable rhythm in both renderers.
    var lineSpacing: CGFloat {
        let base = nativeFont(size: bodySize, weight: .regular)
        var naturalHeight = base.ascender - base.descender + base.leading
        let fallback = fontStyle == .book ? Self.chineseSerifName : "PingFang SC"
        if let fallback, let chinese = NSFont(name: fallback, size: bodySize) {
            naturalHeight = max(naturalHeight, chinese.ascender - chinese.descender + chinese.leading)
        }
        return max(0, bodySize * lineHeight - naturalHeight)
    }

    var cssFontFamily: String {
        switch fontStyle {
        case .book: return "ui-serif, \"Songti SC\", \"STSong\", serif"
        case .modern: return "-apple-system, BlinkMacSystemFont, \"PingFang SC\", sans-serif"
        }
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(nativeFont(size: size, weight: weight))
    }

    private func nativeFont(size: CGFloat, weight: Font.Weight) -> NSFont {
        let resolvedSize = size.isFinite ? max(1, size) : bodySize
        let system = NSFont.systemFont(ofSize: resolvedSize, weight: Self.nativeWeight(weight))
        guard fontStyle == .book else { return system }
        var descriptor = system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor
        // Songti is bundled by macOS, but check its presence before naming it.
        // Use the system serif for Latin and Songti only as the CJK cascade.
        if let name = Self.chineseSerifName, let chinese = NSFont(name: name, size: resolvedSize) {
            let fallback = chinese.fontDescriptor.addingAttributes([
                .traits: [NSFontDescriptor.TraitKey.weight: Self.nativeWeight(weight).rawValue]
            ])
            descriptor = descriptor.addingAttributes([.cascadeList: [fallback]])
        }
        return NSFont(descriptor: descriptor, size: resolvedSize) ?? system
    }

    private static let chineseSerifName: String? = ["Songti SC", "STSong"].first {
        NSFont(name: $0, size: 17) != nil
    }

    private static func nativeWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

private enum ReadingTypographyKey: EnvironmentKey {
    static let defaultValue = ReadingTypography()
}

extension EnvironmentValues {
    var readingTypography: ReadingTypography {
        get { self[ReadingTypographyKey.self] }
        set { self[ReadingTypographyKey.self] = newValue }
    }
}

private struct ReadingAppearanceModifier: ViewModifier {
    @AppStorage("reader.fontStyle") private var fontStyle = ReadingFontStyle.book.rawValue
    @AppStorage("reader.fontSize") private var fontSize = 17.0
    @AppStorage("reader.lineSpacing") private var spacing = ReadingLineSpacing.comfortable.rawValue
    @AppStorage("reader.measure") private var measure = ReadingMeasure.standard.rawValue

    func body(content: Content) -> some View {
        content.environment(\.readingTypography, ReadingTypography(
            fontStyle: ReadingFontStyle(rawValue: fontStyle) ?? .book,
            bodySize: CGFloat(fontSize),
            spacing: ReadingLineSpacing(rawValue: spacing) ?? .comfortable,
            measure: ReadingMeasure(rawValue: measure) ?? .standard))
    }
}

extension View {
    func readingAppearance() -> some View { modifier(ReadingAppearanceModifier()) }
}

/// Native popover controls. Preferences are local to this Mac and propagate to
/// every open reader through AppStorage, without changing any paper content.
struct ReadingAppearanceControls: View {
    @AppStorage("reader.fontStyle") private var fontStyle = ReadingFontStyle.book.rawValue
    @AppStorage("reader.fontSize") private var fontSize = 17.0
    @AppStorage("reader.lineSpacing") private var spacing = ReadingLineSpacing.comfortable.rawValue
    @AppStorage("reader.measure") private var measure = ReadingMeasure.standard.rawValue

    private var typography: ReadingTypography {
        ReadingTypography(fontStyle: ReadingFontStyle(rawValue: fontStyle) ?? .book,
                          bodySize: CGFloat(fontSize),
                          spacing: ReadingLineSpacing(rawValue: spacing) ?? .comfortable,
                          measure: ReadingMeasure(rawValue: measure) ?? .standard)
    }
    private var sizeBinding: Binding<Double> {
        Binding(get: { Double(typography.bodySize) }, set: { fontSize = min(21, max(15, $0.rounded())) })
    }
    private var isDefault: Bool { typography == ReadingTypography() }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("阅读外观").font(.headline)
                Spacer()
                Button("重置", action: reset).buttonStyle(.borderless).font(.caption).disabled(isDefault)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("字体").font(.caption).foregroundStyle(.secondary)
                Picker("正文字体", selection: $fontStyle) {
                    ForEach(ReadingFontStyle.allCases) { style in Text(style.title).tag(style.rawValue) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            Stepper(value: sizeBinding, in: 15...21, step: 1) {
                HStack {
                    Text("字号")
                    Spacer()
                    Text("\(Int(typography.bodySize)) pt").monospacedDigit().foregroundStyle(.secondary)
                }
            }.accessibilityLabel("正文字号")
            VStack(alignment: .leading, spacing: 8) {
                Text("行距").font(.caption).foregroundStyle(.secondary)
                Picker("正文行距", selection: $spacing) {
                    ForEach(ReadingLineSpacing.allCases) { item in Text(item.title).tag(item.rawValue) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("版心").font(.caption).foregroundStyle(.secondary)
                Picker("正文宽度", selection: $measure) {
                    ForEach(ReadingMeasure.allCases) { item in Text(item.title).tag(item.rawValue) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            Divider()
            Text("让阅读更从容。\nRead at your own pace.")
                .font(typography.font(size: typography.bodySize))
                .lineSpacing(typography.lineSpacing)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.vertical, 5)
                .accessibilityLabel("字体预览")
        }
        .padding(22)
        .frame(width: 310)
    }

    private func reset() {
        fontStyle = ReadingFontStyle.book.rawValue
        fontSize = 17
        spacing = ReadingLineSpacing.comfortable.rawValue
        measure = ReadingMeasure.standard.rawValue
    }
}
