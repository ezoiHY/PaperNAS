import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Explicit property-wrapper alias supports command-line SDKs without SwiftUIMacros.
typealias ViewState<Value> = SwiftUI.State<Value>

/// AppKit keeps toolbar search in the window's responder chain, including Cmd-F.
struct LibrarySearchField: NSViewRepresentable {
    @Binding var text:String
    @ObservedObject var controller:LibrarySearchController
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "搜索论文"
        field.setAccessibilityLabel("搜索论文")
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.setContentHuggingPriority(.defaultLow,for:.horizontal)
        return field
    }
    func updateNSView(_ field:NSSearchField,context:Context) {
        context.coordinator.parent = self
        if field.stringValue != text {field.stringValue = text}
        if controller.handled != controller.request {
            controller.handled = controller.request
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }
    final class Coordinator:NSObject,NSSearchFieldDelegate {
        var parent:LibrarySearchField
        init(_ parent:LibrarySearchField) {self.parent = parent}
        func controlTextDidChange(_ notification:Notification) {
            if let field = notification.object as? NSSearchField {changed(field)}
        }
        @objc func changed(_ field:NSSearchField) {
            if parent.text != field.stringValue {parent.text = field.stringValue}
        }
    }
}

struct IconButton: View {
    let title: String
    let symbol: String
    var role: ButtonRole? = nil
    let action: () -> Void
    var body: some View {
        Button(role:role,action:action) { Label(title,systemImage:symbol).labelStyle(.iconOnly) }
            .help(title).accessibilityLabel(title)
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var detail: String = ""
    var body: some View {
        VStack(spacing:12) {
            Image(systemName:symbol).font(.system(size:34,weight:.light)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.medium))
            if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:340) }
        }.padding(32).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}

struct InlineError: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        HStack(alignment:.top,spacing:9) {
            Image(systemName:"exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
            if let retry { IconButton(title:"重试",symbol:"arrow.clockwise",action:retry).buttonStyle(.plain) }
        }.padding(12).background(.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
    }
}

@MainActor
final class ImageMemory {
    static let shared = ImageMemory()
    let images = NSCache<NSString,NSImage>()
    init() { images.totalCostLimit = 96 * 1024 * 1024; images.countLimit = 200 }
}

struct RemoteFigure: View {
    @EnvironmentObject var app: AppModel
    let path: String
    var fit: ContentMode = .fit
    var altText:String? = nil
    @ViewState private var image: NSImage?
    @ViewState private var failed = false
    var body: some View {
        ZStack {
            Color.white
            if let image { Image(nsImage:image).resizable().aspectRatio(contentMode:fit).padding(5) }
            else { Image(systemName:path.isEmpty || failed ? "doc.richtext" : "photo").font(.title2.weight(.light)).foregroundStyle(.gray.opacity(0.55)) }
        }
        .clipShape(RoundedRectangle(cornerRadius:8))
        .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color.primary.opacity(0.07),lineWidth:0.5))
        .accessibilityHidden(altText == nil).accessibilityLabel(altText ?? "")
        .task(id:app.serverID + path) {
            image = nil; failed = false
            guard !path.isEmpty, let api = app.api else { return }
            let key = (app.serverID + path) as NSString
            if let saved = ImageMemory.shared.images.object(forKey:key) { image = saved; return }
            do {
                let data = try await api.data(path)
                try Task.checkCancellation()
                guard let decoded = NSImage(data:data) else { failed = true; return }
                ImageMemory.shared.images.setObject(decoded,forKey:key,cost:data.count)
                image = decoded
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct StateDot: View {
    let paper: Paper
    var body: some View {
        Circle().fill(paper.stateColor).frame(width:6,height:6)
            .help(paper.stateName).accessibilityLabel(paper.stateName)
    }
}

struct GroupChips: View {
    let groups: [PaperGroup]
    var body: some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:6) { ForEach(groups) { group in chip(group.name) } }
            HStack(spacing:6) { if let first = groups.first { chip(first.name) }; if groups.count > 1 { Text("+\(groups.count-1)").font(.caption2).foregroundStyle(.secondary) } }
        }
    }
    private func chip(_ name:String) -> some View {
        Label(name,systemImage:"folder").font(.system(size:10,weight:.medium))
            .foregroundStyle(.secondary).padding(.horizontal,6).padding(.vertical,3)
            .background(.quaternary.opacity(0.6),in:RoundedRectangle(cornerRadius:4))
    }
}

struct ConnectionView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var address = UserDefaults.standard.string(forKey:"lastServerAddress") ?? "http://127.0.0.1:8788"
    @ViewState private var key = ""
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            HStack(spacing:13) {
                Image(systemName:"externaldrive.connected.to.line.below").font(.system(size:30,weight:.light)).foregroundStyle(.tint)
                VStack(alignment:.leading,spacing:5) {
                    Text("连接论文服务器").font(.title2.weight(.semibold))
                    Text("论文和分析留在服务器，阅读随设备继续。").foregroundStyle(.secondary).font(.callout)
                }
            }
            VStack(alignment:.leading,spacing:8) {
                Text("服务器地址").font(.callout.weight(.medium))
                TextField("https://server.example.ts.net",text:$address).textFieldStyle(.roundedBorder)
                Text("私有服务器需要设备已连接 Tailscale。").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment:.leading,spacing:8) {
                Text("访问密钥").font(.callout.weight(.medium))
                SecureField("服务器访问密钥",text:$key).textFieldStyle(.roundedBorder).onSubmit { connect() }
                Text("验证后仅将此设备的登录凭据保存在钥匙串。").font(.caption).foregroundStyle(.secondary)
            }
            if let error { InlineError(message:error) }
            HStack {
                Button("取消",role:.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if app.connecting { ProgressView().controlSize(.small) }
                Button("连接") { connect() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(app.connecting || key.isEmpty || address.isEmpty)
            }
        }.padding(30).frame(width:450)
    }
    private func connect() {
        error = nil
        Task {
            do { try await app.connect(address:address,key:key); UserDefaults.standard.set(address,forKey:"lastServerAddress"); key = ""; dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct AddPaperView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    @ViewState private var input = ""
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var file:URL?
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Label("添加论文",systemImage:"doc.badge.plus").font(.title2.weight(.semibold))
            TextField(app.isV2 ? "论文链接、DOI 或 arXiv ID" : "arXiv 链接或编号",text:$input).textFieldStyle(.roundedBorder).onSubmit { submit() }.disabled(file != nil)
            if app.isV2 {
                HStack {Button("选择 PDF 文件…",systemImage:"doc.badge.plus") {choosePDF()};if let file {Text(file.lastPathComponent).font(.caption).lineLimit(1);Button("移除") {self.file = nil}}}
                Text("原始文件、正文与图表会保存在服务器。可在任务页查看进度，完成后再选择是否生成分析。").font(.callout).foregroundStyle(.secondary)
            } else {Text("加入待选池，由服务器保存并生成一句话总结。").font(.callout).foregroundStyle(.secondary)}
            if let error { InlineError(message:error) }
            HStack {
                Button("取消",role:.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("添加") { submit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled((input.isEmpty && file == nil) || busy)
            }
        }.padding(26).frame(width:430)
    }
    static func identifier(_ input:String) -> String {
        var value = input.trimmingCharacters(in:.whitespacesAndNewlines)
        if let url = URL(string:value), url.host?.hasSuffix("arxiv.org") == true {
            value = url.path.replacingOccurrences(of:"/abs/",with:"").replacingOccurrences(of:"/pdf/",with:"")
        }
        if value.hasSuffix(".pdf") { value = String(value.dropLast(4)) }
        return value
    }
    private func submit() {
        guard !busy,(!input.isEmpty || file != nil) else {return}
        busy = true; error = nil
        Task {
            do {
                if app.isV2 {
                    if let file,let api = app.api {_ = try await api.uploadPDF(file)}
                    else {_ = try await app.request("operations",method:"POST",body:.object(["kind":.string("import"),"reference":.string(input)]))}
                    app.change += 1;app.notify("论文导入已加入服务器任务")
                } else {_ = try await app.job("add_candidate",extra:["arxiv_id":.string(Self.identifier(input))])}
                dismiss()
            }
            catch { self.error = error.localizedDescription; busy = false }
        }
    }
    private func choosePDF() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.pdf];panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {file = panel.url}
    }
}
