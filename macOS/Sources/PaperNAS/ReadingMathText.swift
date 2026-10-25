import SwiftUI
import AppKit
import WebKit

/// A formula-sized typesetting surface. Ordinary reading text stays in SwiftUI.
struct ReadingMathText: View {
    let text: String
    var fontSize: CGFloat?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.readingTypography) private var typography
    @ViewState private var contentHeight: CGFloat = 28

    var body: some View {
        ReadingMathFragment(text: text, fontSize: fontSize ?? typography.bodySize,
                            fontFamily: typography.cssFontFamily, lineHeight: typography.lineHeight,
                            dark: colorScheme == .dark,
                            height: $contentHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: contentHeight)
    }
}

private struct ReadingMathFragment: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let fontFamily: String
    let lineHeight: CGFloat
    let dark: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FormulaWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(FormulaResources(), forURLScheme: FormulaResources.scheme)
        configuration.userContentController.add(WeakFormulaMessageHandler(context.coordinator), name: "formulaHeight")
        let view = FormulaWebView(frame: .zero, configuration: configuration)
        let coordinator = context.coordinator
        view.navigationDelegate = coordinator
        view.onWidthChange = { [weak view, weak coordinator] in
            guard let view else { return }
            coordinator?.measure(view)
        }
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityLabel("数学公式")
        return view
    }

    func updateNSView(_ view: FormulaWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onHeight = { newHeight in
            if abs(height - newHeight) >= 1 { height = newHeight }
        }
        let identity = FormulaIdentity(text: text, fontSize: fontSize,
                                       fontFamily: fontFamily, lineHeight: lineHeight, dark: dark)
        guard coordinator.identity != identity else { return }
        coordinator.identity = identity
        coordinator.generation = UUID().uuidString
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.loadHTMLString(Self.document(identity, generation: coordinator.generation),
                            baseURL: URL(string: "\(FormulaResources.scheme)://bundle/"))
    }

    static func dismantleNSView(_ view: FormulaWebView, coordinator: Coordinator) {
        coordinator.onHeight = nil
        view.onWidthChange = nil
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "formulaHeight")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var identity: FormulaIdentity?
        var generation = ""
        var onHeight: ((CGFloat) -> Void)?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "formulaHeight", message.frameInfo.isMainFrame,
                  let payload = message.body as? [String: Any],
                  let token = payload["generation"] as? String, token == generation,
                  let value = payload["height"] as? NSNumber else { return }
            acceptHeight(value, generation: token)
        }

        private func acceptHeight(_ value: NSNumber, generation token: String) {
            let measured = CGFloat(value.doubleValue)
            guard measured.isFinite, measured > 0, measured < 100_000 else { return }
            // Never mutate SwiftUI state from within an NSView update/layout pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.onHeight?(ceil(measured))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
        }

        func measure(_ webView: WKWebView) {
            guard onHeight != nil, webView.bounds.width > 0 else { return }
            let token = generation
            // Width changes and finished navigation do not depend on WebKit's
            // animation clock. A scrolled-offscreen fragment may never receive
            // requestAnimationFrame or ResizeObserver callbacks until shown.
            let script = """
            (() => {
              if (document.documentElement.dataset.formulaGeneration !== '\(token)') return 0;
              const article = document.querySelector('article');
              return article ? Math.ceil(Math.max(article.getBoundingClientRect().height, article.scrollHeight)) : 0;
            })()
            """
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self, self.generation == token, let value = result as? NSNumber else { return }
                self.acceptHeight(value, generation: token)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.navigationType == .linkActivated {
                if ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            // Only the initial, locally constructed document may navigate the view.
            let localDocument = url.absoluteString == "about:blank" ||
                (url.scheme == FormulaResources.scheme && url.host == "bundle" && url.path == "/")
            decisionHandler(localDocument && navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }

    private static func document(_ identity: FormulaIdentity, generation: String) -> String {
        let nonce = UUID().uuidString
        let root = "\(FormulaResources.scheme)://bundle"
        let foreground = cssColor(.labelColor, dark: identity.dark)
        let secondary = cssColor(.secondaryLabelColor, dark: identity.dark)
        let link = cssColor(.linkColor, dark: identity.dark)
        let separator = cssColor(.separatorColor, dark: identity.dark)
        let size = max(10, min(40, identity.fontSize.isFinite ? identity.fontSize : 17))
        return """
        <!doctype html><html data-formula-generation="\(generation)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src \(FormulaResources.scheme): 'nonce-\(nonce)'; style-src \(FormulaResources.scheme): 'unsafe-inline'; font-src \(FormulaResources.scheme):; img-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <link rel="stylesheet" href="\(root)/katex/katex.min.css">
        <style>
        :root { color-scheme: \(identity.dark ? "dark" : "light"); }
        html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
        body { color: \(foreground); font: \(size)px/\(identity.lineHeight) \(identity.fontFamily); overflow-wrap: anywhere; -webkit-text-size-adjust: none; }
        article { display: flow-root; padding: 2px 0; min-width: 0; }
        p { margin: 0; } p + p { margin-top: .75em; }
        a { color: \(link); text-decoration: none; } a:hover { text-decoration: underline; }
        strong { font-weight: 600; }
        code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .92em; }
        pre { white-space: pre-wrap; margin: .7em 0; }
        blockquote { color: \(secondary); margin: .7em 0; padding-left: 1em; border-left: 2px solid \(separator); }
        ul { padding-left: 1.4em; margin: .5em 0; } li + li { margin-top: .25em; }
        table { border-collapse: collapse; max-width: 100%; } td { padding: .4em .6em; border: 1px solid \(separator); }
        .katex { font-size: 1.08em; } .katex-display { margin: .65em 0; overflow-x: auto; overflow-y: hidden; padding: 3px 0; }
        .katex-display > .katex { white-space: nowrap; }
        </style></head><body><article>\(protectedHTML(identity.text))</article>
        <script src="\(root)/katex/katex.min.js"></script><script src="\(root)/math.js"></script>
        <script nonce="\(nonce)">
        (() => {
          const article = document.querySelector('article');
          let lastHeight = -1;
          const measure = () => {
            // Measure immediately: offscreen WKWebViews suspend animation-frame
            // callbacks even when KaTeX has already produced a complete layout.
            const height = Math.ceil(Math.max(article.getBoundingClientRect().height, article.scrollHeight));
            if (height > 0 && height !== lastHeight) {
              lastHeight = height;
              window.webkit.messageHandlers.formulaHeight.postMessage({ generation: '\(generation)', height });
            }
          };
          new ResizeObserver(measure).observe(article);
          window.addEventListener('resize', measure);
          document.fonts.ready.then(measure);
          document.fonts.addEventListener('loadingdone', measure);
          measure();
        })();
        </script></body></html>
        """
    }

    // Protect TeX before Markdown unescapes characters such as \\ and \_. A whole
    // display equation stays in one text node, including multi-line align blocks.
    private static func protectedHTML(_ text: String) -> String {
        let pattern = #"(?<!\\)\$\$[\s\S]+?(?<!\\)\$\$|\\\[[\s\S]+?\\\]|\\\([\s\S]+?\\\)|(?<!\\)\$[^$\n]+?(?<!\\)\$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return SafeMarkdown.html(text) }
        let token = "PAPERNASMATH" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var protected = text
        var replacements: [(String, String)] = []
        for (index, match) in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).enumerated().reversed() {
            guard let range = Range(match.range, in: protected) else { continue }
            let placeholder = token + "X\(index)X"
            replacements.append((placeholder, "<span>" + SafeMarkdown.escape(String(protected[range])) + "</span>"))
            protected.replaceSubrange(range, with: placeholder)
        }
        var result = SafeMarkdown.html(protected)
        for (placeholder, math) in replacements { result = result.replacingOccurrences(of: placeholder, with: math) }
        return result
    }

    private static func cssColor(_ color: NSColor, dark: Bool) -> String {
        var resolved = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return "rgba(\(Int((resolved.redComponent * 255).rounded())),\(Int((resolved.greenComponent * 255).rounded())),\(Int((resolved.blueComponent * 255).rounded())),\(resolved.alphaComponent))"
    }
}

private struct FormulaIdentity: Equatable {
    let text: String
    let fontSize: CGFloat
    let fontFamily: String
    let lineHeight: CGFloat
    let dark: Bool
}

private final class WeakFormulaMessageHandler: NSObject, WKScriptMessageHandler {
    weak var receiver: WKScriptMessageHandler?
    init(_ receiver: WKScriptMessageHandler) { self.receiver = receiver }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        receiver?.userContentController(userContentController, didReceive: message)
    }
}

private final class FormulaWebView: WKWebView {
    var onWidthChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = frame.width
        super.setFrameSize(newSize)
        if newSize.width > 0, abs(previousWidth - newSize.width) >= 1 {
            // SwiftUI may still be in a layout pass; defer only to the next main
            // queue turn, never to a visibility-dependent browser animation tick.
            DispatchQueue.main.async { [weak self] in self?.onWidthChange?() }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Keep a wide display equation horizontally scrollable, while vertical
        // gestures always scroll the surrounding native report.
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// WebKit can read only the bundled typesetter through this scheme. No report
/// data becomes a path, and no HTTP request or authenticated server URL is used.
private final class FormulaResources: NSObject, WKURLSchemeHandler {
    static let scheme = "papernas-math"

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "bundle",
              url.query == nil, url.fragment == nil else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL)); return
        }
        let path = url.path
        let allowed = ["/math.js", "/katex/katex.min.js", "/katex/katex.min.css"].contains(path) ||
            path.range(of: #"^/katex/fonts/KaTeX_[A-Za-z0-9_-]+\.(woff2?|ttf)$"#, options: .regularExpression) != nil
        guard allowed, let resourceRoot = Bundle.module.resourceURL else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let resource = resourceRoot.appendingPathComponent("Resources").appendingPathComponent(String(path.dropFirst()))
        do {
            let data = try Data(contentsOf: resource)
            let mime = ["js": "application/javascript", "css": "text/css", "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf"][resource.pathExtension] ?? "application/octet-stream"
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: ["js", "css"].contains(resource.pathExtension) ? "utf-8" : nil))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
