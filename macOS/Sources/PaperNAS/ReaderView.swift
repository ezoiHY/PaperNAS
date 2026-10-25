import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class ReaderModel:ObservableObject {
    @Published var paper:Paper?
    @Published var notes:[PaperNote] = []
    @Published var info:JSON = .null
    @Published var reading:JSON = .null
    @Published var pdfURL:URL?
    @Published var loading = false
    @Published var downloading = false
    @Published var error:String?
    @Published var section = "report"
    @Published var sourceTarget = ""
    private var positionTask:Task<Void,Never>?
    private var savingPosition = false
    var key = ""
    func load(app:AppModel,key:String) async {
        guard app.api != nil else {paper = nil;pdfURL = nil;notes = [];info = .null;reading = .null;return}
        let first = paper == nil; self.key = key
        if first { loading = true }; defer { loading = false }
        do {
            async let p = app.request("papers/\(key)")
            async let n = app.request("papers/\(key)/notes")
            async let i = app.request("papers/\(key)/pdf/info")
            let (paper,notes,info) = try await(p,n,i)
            try Task.checkCancellation()
            self.paper = Paper(raw:paper); self.notes = notes["notes"].values.map{PaperNote(raw:$0)}
            if self.info["sha256"] != info["sha256"] { pdfURL = nil }
            self.info = info; error = nil
            if first {
                reading = try await app.request("papers/\(key)/reading-state")["reading"]
                if !reading["section"].text.isEmpty { section = reading["section"].text }
            }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    func loadPDF(app:AppModel) async {
        guard pdfURL == nil,!downloading,info["available"].flag,let api = app.api else { return }
        downloading = true; defer { downloading = false }
        do { pdfURL = try await FileCache.shared.pdf(api:api,serverID:app.serverID,key:key,sha:info["sha256"].text) }
        catch { self.error = error.localizedDescription }
    }
    func position(app:AppModel,page:Int) {
        positionTask?.cancel()
        positionTask = Task {
            try? await Task.sleep(for:.milliseconds(900)); guard !Task.isCancelled else { return }
            await savePosition(app:app,page:page)
        }
    }
    func savePosition(app:AppModel,page:Int) async {
        guard paper != nil,!savingPosition else { return }
        savingPosition = true; defer { savingPosition = false }
        var body:JSON = .object(["page":.integer(max(1,page)),"section":.string(section),"revision":.integer(reading["revision"].int)])
        if !info["sha256"].text.isEmpty { body["pdf_sha256"] = info["sha256"] }
        do { reading = try await app.request("papers/\(key)/reading-state",method:"PUT",body:body)["reading"] }
        catch {
            if (error as? ServerError)?.status == 409 {
                // Preserve the other device's position. Only a subsequent local movement writes again.
                if let value = try? await app.request("papers/\(key)/reading-state") { reading = value["reading"] }
                app.notify("其他设备已更新阅读位置")
            }
        }
    }
    var initialPage:Int { reading["pdf_sha256"].text == info["sha256"].text ? max(1,reading["page"].int) : 1 }
}

struct NoteEditorTarget:Identifiable {
    var id:String { note?.id ?? "new" }
    var note:PaperNote?
    var anchor:NoteAnchor
}

struct ReaderView:View {
    @EnvironmentObject var app:AppModel
    @Environment(\.openWindow) var openWindow
    let key:String
    @StateObject private var model = ReaderModel()
    @StateObject private var pdf = PDFController()
    @ViewState private var showNotes = false
    @ViewState private var editing:NoteEditorTarget?
    @ViewState private var deleting:PaperNote?
    @ViewState private var showAudit = false
    @ViewState private var depth:ReadingDepth = .deep
    @ViewState private var showContents = true
    @ViewState private var showInfo = false
    @ViewState private var showAppearance = false
    @ViewState private var focusedReading = false
    @ViewState private var previousContents = true
    @ViewState private var previousNotes = false
    @ViewState private var researchEvidence:JSON?
    @ViewState private var researchFigure:JSON?
    @ViewState private var correctingFigure:JSON?
    var body:some View {
        VStack(spacing:0) {
            if let paper = model.paper {
                readerHeader(paper)
                Divider()
                if let error = model.error { InlineError(message:error) { Task { await model.load(app:app,key:key) } }.padding(12) }
                HSplitView {
                    VStack(spacing:0) {
                        if model.section == "pdf" { pdfPane }
                        else if model.section == "source" { sourcePane(paper) }
                        else if model.section == "figures" { figuresPane(paper) }
                        else { reportPane(paper) }
                    }.frame(minWidth:350,maxWidth:.infinity,maxHeight:.infinity)
                    if showNotes { notesPane.frame(minWidth:230,idealWidth:260,maxWidth:340) }
                }
            } else if model.loading { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity) }
            else if let error = model.error { InlineError(message:error) { Task { await model.load(app:app,key:key) } }.padding() }
            else { EmptyState(symbol:"doc.text",title:"打开论文") }
        }
        .frame(minWidth:showNotes ? 620 : 500)
        .background(Color(nsColor:.textBackgroundColor))
        .task(id:key) { await model.load(app:app,key:key); if model.section == "pdf" { await model.loadPDF(app:app) } }
        .onChange(of:app.change) { _,_ in Task { await model.load(app:app,key:key) } }
        .onChange(of:model.section) { _,s in
            if s != "report",focusedReading {toggleFocus()}
            Task { if s == "pdf" { await model.loadPDF(app:app) }; model.position(app:app,page:pdf.pageCount > 0 ? pdf.page : model.initialPage) }
        }
        .onAppear { pdf.pageChanged = { model.position(app:app,page:$0) } }
        .sheet(item:$editing) { target in
            NoteEditor(key:key,target:target) { Task { await model.load(app:app,key:key) } }.environmentObject(app)
        }
        .sheet(isPresented:$showAudit) { if let paper = model.paper { AuditView(paper:paper) } }
        .sheet(isPresented:Binding(get:{researchEvidence != nil || researchFigure != nil},set:{if !$0 {researchEvidence = nil;researchFigure = nil}})) {
            if let paper = model.paper {SaveResearchEvidenceView(paper:paper,block:researchEvidence ?? .null,figure:researchFigure ?? .null).environmentObject(app)}
        }
        .sheet(isPresented:Binding(get:{correctingFigure != nil},set:{if !$0 {correctingFigure = nil}})) {
            if let figure = correctingFigure {FigureCorrectionView(workID:key,figure:figure).environmentObject(app)}
        }
        .alert("删除这条笔记？",isPresented:Binding(get:{deleting != nil},set:{if !$0 { deleting = nil }})) {
            Button("取消",role:.cancel) { deleting = nil }
            Button("删除",role:.destructive) {
                if let note = deleting { Task { await app.perform("papers/\(key)/notes/\(note.id)",method:"DELETE",body:.object(["revision":.integer(note.revision)])); await model.load(app:app,key:key) } }
                deleting = nil
            }
        } message: { Text("此修改将同步到所有设备。") }
        .readingAppearance()
    }
    private func readerHeader(_ paper:Paper)->some View {
        VStack(alignment:.leading,spacing:12) {
            if model.section != "report" {
                HStack(alignment:.top,spacing:14) {
                    VStack(alignment:.leading,spacing:5) {
                        Text(paper.title).font(.system(size:19,weight:.semibold)).lineLimit(2).textSelection(.enabled)
                        Text([paper.byline,paper.venue,paper.date].filter{!$0.isEmpty}.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength:0)
                    paperMenu(paper)
                }
            }
            HStack(spacing:12) {
                Picker("阅读内容",selection:$model.section) {
                    Image(systemName:"text.book.closed").tag("report").help("解读").accessibilityLabel("解读")
                    Image(systemName:"doc.richtext").tag("pdf").help("PDF 原文").accessibilityLabel("PDF 原文")
                    Image(systemName:"text.alignleft").tag("source").help("提取原文").accessibilityLabel("提取原文")
                    Image(systemName:"photo.on.rectangle").tag("figures").help("图表").accessibilityLabel("图表")
                }.pickerStyle(.segmented).labelsHidden().frame(width:164)
                if model.section == "report",paper.hasReport && paper.hasBrief {
                    Picker("解读深度",selection:$depth) {Text("精读").tag(ReadingDepth.deep);Text("初读").tag(ReadingDepth.brief)}
                        .pickerStyle(.segmented).labelsHidden().frame(width:106)
                }
                Spacer(minLength:12)
                if model.section == "report" {
                    Text(paper.title).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth:360).help(paper.title).layoutPriority(-1)
                    Spacer(minLength:12)
                    IconButton(title:"阅读外观",symbol:"textformat") {showAppearance.toggle()}
                        .buttonStyle(.borderless).foregroundStyle(showAppearance ? Color.accentColor : .secondary)
                        .popover(isPresented:$showAppearance,arrowEdge:.bottom) {ReadingAppearanceControls()}
                    IconButton(title:focusedReading ? "退出专注阅读" : "专注阅读",symbol:"viewfinder") {toggleFocus()}
                        .buttonStyle(.borderless).foregroundStyle(focusedReading ? Color.accentColor : .secondary)
                        .keyboardShortcut("f",modifiers:[.command,.shift])
                        .accessibilityValue(focusedReading ? "开启" : "关闭")
                }
                IconButton(title:"论文信息",symbol:"info.circle") {showInfo.toggle()}
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .popover(isPresented:$showInfo,arrowEdge:.bottom) {ReadingInfoView(paper:paper,depth:effectiveDepth(paper))}
                IconButton(title:showNotes ? "隐藏笔记" : "显示笔记",symbol:"sidebar.right") {
                    if focusedReading {toggleFocus();showNotes = true} else {showNotes.toggle()}
                }.buttonStyle(.borderless).foregroundStyle(showNotes ? Color.accentColor : .secondary)
                if model.section == "report" {paperMenu(paper)}
            }
        }.padding(.horizontal,22).padding(.vertical,model.section == "report" ? 11 : 14)
            .background(Color(nsColor:.windowBackgroundColor))
    }
    private func toggleFocus() {
        if focusedReading {
            showContents = previousContents;showNotes = previousNotes
        } else {
            previousContents = showContents;previousNotes = showNotes
            showContents = false;showNotes = false
        }
        focusedReading.toggle()
    }
    private func paperMenu(_ paper:Paper)->some View {
        Menu {
            if !app.isV2 {Button("初读",systemImage:"text.book.closed") {submit("brief_paper")}}
            Button("精读",systemImage:"sparkles") {submit("analyze_paper")}
            if !app.isV2 {Button("生成一句话总结",systemImage:"text.alignleft") {submit("summarize_paper")}}
            Button("重新提取原文",systemImage:"doc.text.viewfinder") {submit("extract_paper")}
            Divider()
            Button("在新窗口打开",systemImage:"macwindow.on.rectangle") {openWindow(id:"paper",value:key)}
            if let url = paper.sourceURL {Link("论文主页",destination:url)}
            Button("导出分析报告…",systemImage:"square.and.arrow.up") {exportReport(paper)}.disabled(paper.raw["markdown"].text.isEmpty)
            Button("导出 PDF…",systemImage:"arrow.down.doc") {Task {await exportPDF(paper)}}.disabled(!model.info["available"].flag)
            if !app.isV2 {Button("引用与核对",systemImage:"checkmark.shield") {showAudit = true}.disabled(!paper.hasReport)}
        } label:{Image(systemName:"ellipsis.circle")}
            .menuStyle(.borderlessButton).fixedSize().help("论文操作").accessibilityLabel("论文操作")
    }
    private func effectiveDepth(_ paper:Paper)->ReadingDepth {paper.hasReport ? (paper.hasBrief ? depth : .deep) : .brief}
    @ViewBuilder private func reportPane(_ paper:Paper)->some View {
        if paper.hasReport || paper.hasBrief {
            if paper.raw["report_stale"].flag { Label("分析方案已更新，可重新精读",systemImage:"clock.arrow.circlepath").font(.caption).foregroundStyle(.orange).padding(.top,10) }
            NativeReportView(paper:paper,depth:effectiveDepth(paper),showContents:Binding(get:{showContents},set:{visible in
                if visible && focusedReading {toggleFocus()}
                showContents = visible
            })) { blockID in
                model.sourceTarget = blockID; model.section = "source"
            }
        } else {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    if !paper.summary.isEmpty && !paper.abstract.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix(paper.summary.trimmingCharacters(in:.whitespacesAndNewlines)) {
                        Text(paper.summary).font(.title3)
                    }
                    Text("摘要").font(.headline)
                    Text(paper.abstract).font(.body).lineSpacing(7).textSelection(.enabled)
                    HStack {if !app.isV2 {Button("初读") {submit("brief_paper")}};Button("精读") { submit("analyze_paper") }.buttonStyle(.borderedProminent)
                        if app.isV2 {Button("阅读原文") {model.section = "pdf";Task {await model.loadPDF(app:app)}}}
                    }
                }.padding(30).frame(maxWidth:760)
            }
        }
    }
    @ViewBuilder private var pdfPane:some View {
        if let url = model.pdfURL {
            PDFTools(controller:pdf) { if let anchor = pdf.selection { editing = NoteEditorTarget(anchor:anchor) } }
            NativePDF(url:url,sha:model.info["sha256"].text,notes:model.notes,initialPage:model.initialPage,controller:pdf)
        } else if model.downloading { VStack(spacing:14) { ProgressView();Text("正在从服务器载入 PDF…").foregroundStyle(.secondary) }.frame(maxWidth:.infinity,maxHeight:.infinity) }
        else if model.info["available"].flag {
            VStack { EmptyState(symbol:"doc.richtext",title:"PDF 尚未载入");Button("载入 PDF") { Task { await model.loadPDF(app:app) } }.padding(.bottom,40) }
        } else {
            VStack {
                EmptyState(symbol:"arrow.down.doc",title:"服务器尚未保存 PDF",detail:"下载在服务器执行，完成后各设备都可阅读。")
                Button("下载到服务器") { Task { await app.perform("papers/\(key)/pdf",message:"已加入服务器下载队列") } }.buttonStyle(.borderedProminent).padding(.bottom,40)
            }
        }
    }
    private func sourcePane(_ paper:Paper)->some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment:.leading,spacing:24) {
                    if paper.blocks.isEmpty { EmptyState(symbol:"text.alignleft",title:"尚未提取原文",detail:"从论文操作菜单选择“重新提取原文”。") }
                    if app.isV2,paper.raw["document"]["structure_quality"].text == "basic" {Label("当前为 PDF 文字提取；公式、表格和阅读顺序请结合原文核对。",systemImage:"info.circle").font(.callout).foregroundStyle(.secondary).frame(maxWidth:780,alignment:.leading)}
                    if app.isV2,paper.raw["document"]["structure_quality"].text == "legacy" {Label("保留的旧版提取结果；没有页码的段落尚未与 PDF 页面对应。",systemImage:"info.circle").font(.callout).foregroundStyle(.secondary).frame(maxWidth:780,alignment:.leading)}
                    ForEach(paper.blocks,id:\.["id"].text) { block in
                        VStack(alignment:.leading,spacing:9) {
                            HStack { Text(block["section"].text).font(.headline);Spacer();if block["page"].int > 0 { Button("第 \(block["page"].int) 页") { model.section = "pdf";Task { await model.loadPDF(app:app);pdf.go(block["page"].int) } }.buttonStyle(.link) } }
                            Text(block["text"].text).lineSpacing(6).textSelection(.enabled)
                            if app.supportsResearch {Button("保存为研究证据",systemImage:"text.badge.plus") {researchEvidence = block}.buttonStyle(.link).font(.caption)}
                        }.padding(16).frame(maxWidth:780,alignment:.leading)
                            .background(block["id"].text == model.sourceTarget ? Color.accentColor.opacity(0.08) : .clear,in:RoundedRectangle(cornerRadius:10))
                            .id(block["id"].text)
                    }
                }.padding(18).frame(maxWidth:.infinity)
            }.onAppear { proxy.scrollTo(model.sourceTarget,anchor:.top) }
                .onChange(of:model.sourceTarget) { _,id in proxy.scrollTo(id,anchor:.top) }
        }
    }
    private func figuresPane(_ paper:Paper)->some View {
        ScrollView {
            LazyVStack(alignment:.center,spacing:30) {
                if paper.figures.isEmpty { EmptyState(symbol:"photo",title:"尚无可用图表") }
                ForEach(paper.figures,id:\.["id"].text) { figure in
                    VStack(alignment:.leading,spacing:12) {
                        ReportFigureView(figure:figure)
                        HStack { Spacer();
                            IconButton(title:"设为代表图",symbol:paper.raw["cover_figure_id"] == figure["id"] ? "photo.badge.checkmark" : "photo") {
                                Task { await app.perform("papers/\(key)",method:"PATCH",body:.object(["revision":.integer(paper.revision),"cover_figure_id":figure["id"]]),message:"代表图已更新") }
                            }.buttonStyle(.borderless)
                            IconButton(title:"导出原图",symbol:"square.and.arrow.up") { Task { await exportFigure(figure) } }.buttonStyle(.borderless)
                        }
                        if app.isV2 {
                            if figure["status"].text == "page_fallback" {Label("当前显示对应 PDF 整页，可手动调整图表范围。",systemImage:"doc.viewfinder").font(.caption).foregroundStyle(.secondary)}
                            HStack {Button("保存为研究证据",systemImage:"text.badge.plus") {researchFigure = figure};Button("调整图表范围",systemImage:"crop") {correctingFigure = figure}}.buttonStyle(.link).font(.caption)
                        }
                    }.frame(maxWidth:800,alignment:.leading)
                }
            }.padding(28).frame(maxWidth:.infinity)
        }
    }
    private var notesPane:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack { Text("笔记").font(.headline);Text("\(model.notes.count)").foregroundStyle(.tertiary);Spacer();IconButton(title:"关闭笔记",symbol:"xmark") { showNotes = false }.buttonStyle(.plain) }.padding(16)
            Divider()
            if model.notes.isEmpty { EmptyState(symbol:"square.and.pencil",title:"留下你的想法",detail:"在 PDF 中选中文字，然后点击笔记图标。") }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:14) {
                    ForEach(model.notes) { note in
                        VStack(alignment:.leading,spacing:10) {
                            HStack { Button("第 \(note.page) 页") { model.section = "pdf";Task { await model.loadPDF(app:app);pdf.show(note) } }.buttonStyle(.link).disabled(!note.current);Spacer();
                                Menu { Button("编辑") { editing = NoteEditorTarget(note:note,anchor:NoteAnchor(page:note.page,quote:note.quote,rects:note.rects,sha:note.fingerprint)) }; Button("删除",role:.destructive) { deleting = note } } label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).fixedSize().help("笔记操作")
                            }
                            Text(note.quote).font(.caption).foregroundStyle(.secondary).lineLimit(5)
                            Text(note.body).font(.callout).textSelection(.enabled)
                            if !note.current { Label("来自旧版 PDF",systemImage:"clock").font(.caption).foregroundStyle(.orange) }
                        }.padding(13).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
                    }
                }.padding(12)
            }
        }.background(Color(nsColor:.controlBackgroundColor))
    }
    private func submit(_ action:String) { Task { do { _ = try await app.job(action,key:key) } catch { app.handle(error) } } }
    private func exportReport(_ paper:Paper) {
        let panel = NSSavePanel();panel.nameFieldStringValue = String(paper.title.prefix(80)) + ".md"; panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url { do { try paper.raw["markdown"].text.write(to:url,atomically:true,encoding:.utf8) } catch { app.handle(error) } }
    }
    private func exportPDF(_ paper:Paper) async {
        await model.loadPDF(app:app);guard let source = model.pdfURL else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = String(paper.title.prefix(80)) + ".pdf"; panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK,let destination = panel.url {
            do { try Data(contentsOf:source,options:.mappedIfSafe).write(to:destination,options:.atomic) } catch { app.handle(error) }
        }
    }
    private func exportFigure(_ figure:JSON) async {
        guard let api = app.api else {return}
        let download = FigureDownload(figure)
        guard !download.path.isEmpty else {app.handle(ServerError(message:"服务器尚未提供这张插图。"));return}
        let panel = NSSavePanel();panel.nameFieldStringValue = download.filename
        if panel.runModal() == .OK,let url = panel.url {
            do { try await api.download(download.path,destination:url) } catch {app.handle(error)}
        }
    }
}

struct NoteEditor:View {
    @EnvironmentObject var app:AppModel
    @Environment(\.dismiss) var dismiss
    let key:String
    let target:NoteEditorTarget
    let saved:()->Void
    @ViewState private var bodyText = ""
    @ViewState private var error:String?
    @ViewState private var busy = false
    @ViewState private var requestID = UUID().uuidString
    @ViewState private var restoredAnchor:NoteAnchor?
    @ViewState private var restored = false
    private var anchor:NoteAnchor {restoredAnchor ?? target.anchor}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(target.note == nil ? "添加笔记" : "编辑笔记").font(.title2.weight(.semibold))
            Text("第 \(anchor.page) 页").font(.caption).foregroundStyle(.secondary)
            Text(anchor.quote).font(.callout).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
            if restored {
                Label("已恢复此 Mac 上的未发送草稿",systemImage:"doc.badge.clock").font(.caption).foregroundStyle(.secondary)
                if target.note == nil,anchor != target.anchor {
                    Button("将草稿关联到当前选文") {restoredAnchor = target.anchor;DraftStore.save(.init(body:bodyText,anchor:target.anchor),server:app.serverID,key:key,id:target.id)}
                }
                if let note = target.note,note.body != bodyText {
                    DisclosureGroup("查看服务器当前版本") {Text(note.body).font(.callout).textSelection(.enabled)}
                }
            }
            TextEditor(text:$bodyText).font(.body).scrollContentBackground(.hidden).padding(8)
                .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8)).frame(minHeight:150)
                .accessibilityLabel("笔记内容")
            if let error { InlineError(message:error) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("保存") { Task { await save() } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(busy || bodyText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width:500)
            .onAppear {
                if let draft = DraftStore.load(server:app.serverID,key:key,id:target.id) {
                    restoredAnchor = draft.anchor;bodyText = draft.body;restored = true
                } else {bodyText = target.note?.body ?? ""}
            }
            .onChange(of:bodyText) { _,value in DraftStore.save(.init(body:value,anchor:anchor),server:app.serverID,key:key,id:target.id) }
    }
    private func save() async {
        busy = true;error = nil;defer {busy = false}
        do {
            var body = target.note == nil ? anchor.json : .object(["revision":.integer(target.note!.revision)])
            body["body"] = .string(bodyText)
            guard let api = app.api else {throw ServerError(message:"请先连接服务器")}
            _ = try await api.request("papers/\(key)/notes" + (target.note.map{"/\($0.id)"} ?? ""),method:target.note == nil ? "POST" : "PATCH",body:body,requestID:requestID)
            DraftStore.remove(server:app.serverID,key:key,id:target.id);app.change += 1;saved();dismiss()
        } catch {
            self.error = (error as? ServerError)?.status == 409 ? (target.note == nil ? "PDF 版本或请求状态已变化。草稿已保留，请刷新 PDF 和笔记后核对。" : "笔记已被另一设备修改。你的草稿已保留；关闭后重新打开笔记核对最新版本。") : error.localizedDescription
            if let e = error as? ServerError,e.status >= 400,e.status < 500 {requestID = UUID().uuidString}
        }
    }
}

enum DraftStore {
    struct Record:Codable {var body:String;var anchor:NoteAnchor}
    static func file(server:String,key:String,id:String)->URL {
        let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("PaperNAS/Drafts")
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        return root.appendingPathComponent([server,key,id].joined(separator:"-")+".json")
    }
    static func load(server:String,key:String,id:String)->Record? {
        guard let data = try? Data(contentsOf:file(server:server,key:key,id:id)) else {return nil}
        return try? JSONDecoder().decode(Record.self,from:data)
    }
    static func save(_ value:Record,server:String,key:String,id:String) {
        let url = file(server:server,key:key,id:id);if let data = try? JSONEncoder().encode(value) {try? data.write(to:url,options:.atomic)}
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    static func remove(server:String,key:String,id:String) {try? FileManager.default.removeItem(at:file(server:server,key:key,id:id))}
}

struct AuditView:View {
    @Environment(\.dismiss) var dismiss
    let paper:Paper
    @ViewState private var onlyIssues = true
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text("引用与核对").font(.title2.weight(.semibold));Spacer();Button("完成") {dismiss()}.keyboardShortcut(.cancelAction) }
            Toggle("仅显示待核查内容",isOn:$onlyIssues)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:20) {
                    ForEach(Array(paper.raw["report"]["checks"]["items"].values.enumerated()),id:\.offset) { _,check in
                        if !onlyIssues || check["verdict"].text != "supported" {
                            VStack(alignment:.leading,spacing:8) {
                                Label(check["verdict"].text == "supported" ? "引用支持" : "待核查",systemImage:check["verdict"].text == "supported" ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(check["verdict"].text == "supported" ? .green : .orange)
                                Text(check["claim"].text).font(.headline)
                                Text(check["reason"].text).foregroundStyle(.secondary)
                            }.textSelection(.enabled)
                        }
                    }
                    Text("AI 辅助解读，请结合论文原文核查。").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical,8)
            }
        }.padding(26).frame(width:660,height:620)
    }
}
