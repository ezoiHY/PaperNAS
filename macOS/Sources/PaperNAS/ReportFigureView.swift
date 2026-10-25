import SwiftUI
import AppKit

/// An archived paper figure is a server asset, not an external Markdown image.
struct ReportFigureView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.readingTypography) private var typography
    let figure: JSON
    @StateObject private var asset = ReportFigureAsset()
    @ViewState private var expanded = false
    @ViewState private var retry = 0
    @ViewState private var hovering = false

    private var label: String { figure["label"].text.isEmpty ? "论文插图" : figure["label"].text }
    private var path: String { figure["asset_url"].text.isEmpty ? figure["original_url"].text : figure["asset_url"].text }
    private var server: String { reportFigureServerIdentity(app) }
    private var resourceID: String { server + "|" + path + "|" + figure["sha256"].text }
    private var image: NSImage? { asset.resourceID == resourceID ? asset.image : nil }
    private var caption: String { figure["caption"].text }
    private var captionBody: String {
        // Split only a repeated figure label for the hanging caption layout.
        // The complete source caption stays intact in accessibility and the sheet.
        guard !figure["label"].text.isEmpty, caption.hasPrefix(label) else { return caption }
        return String(caption.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn:":：")))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let image {
                Button { expanded = true } label: {
                    ReportFigureAspectLayout(aspectRatio: reportFigureRatio(figure, image: image)) {
                        Image(nsImage: image).resizable().scaledToFit().padding(16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(hovering ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.10), lineWidth: 0.5))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).help("点击查看原图，可缩放")
                .accessibilityLabel("\(label)，\(caption)").accessibilityHint("打开可缩放的原图")
                .onHover { hovering = $0 }
            } else if asset.resourceID == resourceID, let failure = asset.failure {
                ReportFigureFailure(message: failure, source: figure["source_url"].text, retry: { retry += 1 })
            } else {
                ReportFigureAspectLayout(aspectRatio: figure["width"].double > 0 && figure["height"].double > 0 ? figure["width"].double / figure["height"].double : 1.5) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在载入插图…").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(label).font(.system(size: 11, weight: .semibold))
                        .tracking(0.25).foregroundStyle(Color.primary.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                    if image != nil {
                        Button { expanded = true } label: {
                            Label("放大查看", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .medium))
                                .frame(minHeight: 22, alignment: .leading)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("放大查看原图").accessibilityLabel("放大查看 \(label)")
                    }
                }.frame(width: 76, alignment: .leading)
                if !captionBody.isEmpty {
                    Text(captionBody)
                        .font(typography.font(size: max(13, typography.bodySize - 3)))
                        .foregroundStyle(.secondary)
                        .lineSpacing(max(2, typography.lineSpacing * 0.5))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: typography.textWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.bottom, 6)
        .frame(maxWidth: typography.figureWidth, alignment: .leading)
        .task(id: resourceID + "|\(retry)") {
            await asset.load(path: path, resourceID: resourceID, api: app.api)
        }
        .onChange(of: server) { _, _ in expanded = false }
        .sheet(isPresented: $expanded) {
            ReportFigureSheet(figure: figure).environmentObject(app)
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private final class ReportFigureAsset: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var failure: String?
    @Published private(set) var resourceID = ""

    func load(path: String, resourceID: String, api: APIClient?) async {
        self.resourceID = resourceID
        image = nil
        failure = nil
        guard let api else { failure = "请连接论文服务器后查看插图。"; return }
        guard !path.isEmpty else { failure = "服务器尚未提供这张插图。"; return }
        let cacheKey = ("report-figure|" + resourceID) as NSString
        if let cached = ImageMemory.shared.images.object(forKey: cacheKey) {
            image = cached
            return
        }
        do {
            // APIClient only permits same-server resources and redirects, and adds
            // the device credential. source_url is deliberately never fetched here.
            let bytes = try await api.data(path)
            try Task.checkCancellation()
            guard self.resourceID == resourceID else { return }
            guard let decoded = NSImage(data: bytes), decoded.size.width > 0, decoded.size.height > 0 else {
                failure = "这张插图暂时无法读取。"
                return
            }
            let pixelCost = decoded.representations.reduce(0) { total, representation in
                max(total, max(0, representation.pixelsWide) * max(0, representation.pixelsHigh) * 4)
            }
            ImageMemory.shared.images.setObject(decoded, forKey: cacheKey, cost: max(bytes.count, pixelCost))
            image = decoded
        } catch {
            guard !Task.isCancelled, self.resourceID == resourceID else { return }
            if let error = error as? ServerError, error.status == 401 {
                failure = "连接已失效，请重新连接论文服务器。"
            } else {
                failure = "插图未能载入，请检查服务器连接后重试。"
            }
        }
    }
}

private struct ReportFigureAspectLayout: Layout {
    let aspectRatio: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 650)
        return CGSize(width: width, height: min(420, max(1, width - 32) / max(0.1, aspectRatio) + 32))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

private struct ReportFigureFailure: View {
    let message: String
    let source: String
    let retry: () -> Void
    private var sourceURL: URL? {
        guard let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(.tertiary)
            Text(message).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Button("重试", action: retry).controlSize(.small)
            if let sourceURL {
                Link(destination: sourceURL) { Image(systemName: "arrow.up.right.square") }
                    .help("在浏览器中打开图片来源").accessibilityLabel("打开图片来源")
            }
        }.padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ReportFigureSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let figure: JSON
    @StateObject private var asset = ReportFigureAsset()
    @ViewState private var retry = 0
    @ViewState private var scale: CGFloat?

    private var path: String { figure["original_url"].text.isEmpty ? figure["asset_url"].text : figure["original_url"].text }
    private var server: String { reportFigureServerIdentity(app) }
    private var resourceID: String { server + "|" + path + "|" + figure["sha256"].text }
    private var image: NSImage? { asset.resourceID == resourceID ? asset.image : nil }
    private var label: String { figure["label"].text.isEmpty ? "论文插图" : figure["label"].text }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label.trimmingCharacters(in: CharacterSet(charactersIn: ":： "))).font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            GeometryReader { geometry in
                if let image {
                    let natural = reportFigureSize(figure, image: image)
                    let fit = min(1, min(max(1, geometry.size.width - 32) / natural.width,
                                         max(1, geometry.size.height - 74) / natural.height))
                    let zoom = scale ?? fit
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            Button { scale = max(0.05, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                                .help("缩小").accessibilityLabel("缩小插图")
                            Text("\(Int((zoom * 100).rounded()))%").font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary).frame(minWidth: 40)
                            Button { scale = min(8, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                                .help("放大").accessibilityLabel("放大插图")
                            Divider().frame(height: 16)
                            Button("适合窗口") { scale = nil }
                            Button("实际大小") { scale = 1 }
                            Spacer()
                        }.buttonStyle(.borderless).padding(.horizontal, 20).frame(height: 42)
                        Divider()
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image).resizable().interpolation(.high)
                                .frame(width: natural.width * zoom, height: natural.height * zoom)
                                .background(Color.white).padding(16)
                                .frame(minWidth: geometry.size.width, minHeight: max(1, geometry.size.height - 43))
                                .accessibilityLabel("\(label)，\(figure["caption"].text)")
                        }.background(Color(nsColor: .underPageBackgroundColor))
                    }
                } else if asset.resourceID == resourceID, let failure = asset.failure {
                    ReportFigureFailure(message: failure, source: figure["source_url"].text, retry: { retry += 1 })
                        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("正在载入原图…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if !figure["caption"].text.isEmpty {
                Divider()
                ScrollView {
                    Text(figure["caption"].text).font(.callout).foregroundStyle(.secondary)
                        .lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                }.frame(maxHeight: 110)
            }
        }
        .frame(width: min(1100, (NSScreen.main?.visibleFrame.width ?? 1300) - 120),
               height: min(780, (NSScreen.main?.visibleFrame.height ?? 900) - 120))
        .task(id: resourceID + "|\(retry)") { await asset.load(path: path, resourceID: resourceID, api: app.api) }
        .onChange(of: server) { _, _ in dismiss() }
    }
}

@MainActor
private func reportFigureServerIdentity(_ app: AppModel) -> String {
    // Include endpoint and device, so replacing credentials or reconnecting to a
    // different endpoint can never briefly display the previous session's image.
    [app.credentials?.serverURL ?? "", app.serverID, app.credentials?.deviceID ?? ""].joined(separator: "|")
}

private func reportFigureSize(_ figure: JSON, image: NSImage) -> CGSize {
    if figure["width"].double > 0, figure["height"].double > 0 {
        return CGSize(width: figure["width"].double, height: figure["height"].double)
    }
    return CGSize(width: max(1, image.size.width), height: max(1, image.size.height))
}

private func reportFigureRatio(_ figure: JSON, image: NSImage) -> CGFloat {
    let size = reportFigureSize(figure, image: image)
    return size.width / size.height
}
