import SwiftUI
import AppKit

struct ResearchRecordEditor:View {
    @EnvironmentObject private var app:AppModel
    @Environment(\.dismiss) private var dismiss
    let kind:String
    let question:JSON
    let record:JSON
    var saved:(JSON)->Void
    @ViewState private var form:JSON = .object([:])
    @ViewState private var evidenceIDs:Set<String> = []
    @ViewState private var busy = false
    @ViewState private var error:String?
    private var editing:Bool {!record["id"].text.isEmpty}
    private var title:String { ["question":editing ? "编辑研究问题" : "新建研究问题","judgment":editing ? "修订研究判断" : "记录研究判断",
                               "action":editing ? "编辑验证计划" : "新建验证计划","result":"记录实际结果","snapshot":"保存当前认识"][kind] ?? "研究记录" }
    private var valid:Bool {
        let primary = kind == "judgment" ? "statement" : "title"
        return !form[primary].text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && (kind != "result" || !form["body"].text.isEmpty) && (kind != "snapshot" || !form["understanding"].text.isEmpty)
    }
    var body:some View {
        VStack(spacing:0) {
            HStack {Text(title).font(.title2.weight(.semibold));Spacer()}.padding(24)
            Form {
                if kind == "question" {
                    Section("研究范围") {
                        TextField("想弄清楚的问题",text:text("title"),axis:.vertical).lineLimit(2...4)
                        multiline("为什么关注、已经知道什么","context",lines:3...6)
                        multiline("时间、数据、算力等约束","constraints",lines:2...4)
                        choice("状态","status",["active","paused","completed"])
                    }
                } else if kind == "judgment" {
                    Section("当前看法") {
                        multiline("判断","statement",lines:2...5)
                        multiline("依据与适用条件","rationale",lines:3...6)
                        multiline("什么新证据会改变判断、接下来做什么","next_step",lines:2...4)
                        choice("状态","status",["tentative","accepted","revised"])
                    }
                    evidenceChoices
                } else if kind == "action" {
                    Section("验证目标") {
                        TextField("计划名称",text:text("title"))
                        judgmentPicker
                        multiline("要验证的假设","hypothesis",lines:2...4)
                    }
                    Section("最小验证") {
                        multiline("步骤与控制变量","method",lines:3...6)
                        TextField("比较基线",text:text("baseline"),axis:.vertical)
                        TextField("指标与评估条件",text:text("metrics"),axis:.vertical)
                        TextField("成功或失败判据",text:text("success_criterion"),axis:.vertical)
                        TextField("停止条件",text:text("stop_condition"),axis:.vertical)
                        TextField("时间与资源预算",text:text("resource_budget"),axis:.vertical)
                        choice("执行状态","status",["planned","running","completed","abandoned"])
                    }
                } else if kind == "result" {
                    Section("实际观察") {
                        TextField("记录标题",text:text("title"))
                        Picker("对应计划",selection:text("action_id")) {
                            Text("独立记录").tag("")
                            ForEach(question["actions"].values,id:\.["id"].text) {Text($0["title"].text).tag($0["id"].text)}
                        }
                        judgmentPicker
                        choice("结果","outcome",["supports","contradicts","inconclusive","observation"])
                        multiline("实际做了什么、观察到什么、有哪些局限","body",lines:5...10)
                        TextField("日志、代码或结果链接（可选）",text:text("artifact_url"))
                        Text("结果会保存为新的记录。需要修正之前的结论时，可在判断页修订并保留历史。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("阶段性认识") {
                        TextField("快照标题",text:text("title"))
                        multiline("现在如何理解这个问题","understanding",lines:4...8)
                        multiline("仍未解决的问题与分歧","open_questions",lines:2...5)
                        multiline("下一轮关注方向","next_focus",lines:2...4)
                    }
                    evidenceChoices
                }
            }.formStyle(.grouped)
            if let error {InlineError(message:error).padding(.horizontal,24).padding(.bottom,12)}
            Divider()
            HStack {
                Button("取消") {dismiss()}.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy {ProgressView().controlSize(.small)}
                Button("保存") {Task {await save()}}.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(busy || !valid)
            }.padding(20)
        }.frame(width:630,height:650).onAppear {
            form = record.isNull ? .object([:]) : record
            if form["status"].text.isEmpty {form["status"] = .string(kind == "question" ? "active" : kind == "action" ? "planned" : "tentative")}
            if form["outcome"].text.isEmpty {form["outcome"] = .string("observation")}
            evidenceIDs = Set(record["evidence_ids"].values.map(\.text))
        }.interactiveDismissDisabled(busy)
    }
    private var judgmentPicker:some View {
        Picker("对应判断",selection:text("judgment_id")) {
            Text("暂不关联").tag("")
            ForEach(question["judgments"].values,id:\.["id"].text) {Text($0["statement"].text).tag($0["id"].text)}
        }
    }
    private var evidenceChoices:some View {
        Section("依据") {
            if question["evidence"].values.isEmpty {Text("尚无已保存证据；可先保存待验证的看法。确认判断前需要关联证据。")
                .font(.callout).foregroundStyle(.secondary)}
            ForEach(question["evidence"].values,id:\.["id"].text) {evidence in
                Toggle(isOn:Binding(get:{evidenceIDs.contains(evidence["id"].text)},set:{if $0 {evidenceIDs.insert(evidence["id"].text)} else {evidenceIDs.remove(evidence["id"].text)}})) {
                    VStack(alignment:.leading,spacing:4) {
                        Text(evidence["quote"].text).font(.callout).lineLimit(3)
                        Text(evidence["work_title"].text + " · p. \(evidence["page"].int)").font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.checkbox)
            }
        }
    }
    private func text(_ key:String)->Binding<String> {Binding(get:{form[key].text},set:{form[key] = .string($0)})}
    private func multiline(_ label:String,_ key:String,lines:ClosedRange<Int>)->some View {TextField(label,text:text(key),axis:.vertical).lineLimit(lines)}
    private func choice(_ label:String,_ key:String,_ values:[String])->some View {Picker(label,selection:text(key)) {ForEach(values,id:\.self) {Text(researchStatus($0)).tag($0)}}}
    private func save() async {
        busy = true;error = nil;defer {busy = false}
        let fields:[String]
        let resource:String
        switch kind {
        case "question":fields = ["title","context","constraints","status"];resource = ""
        case "judgment":fields = ["statement","rationale","next_step","status"];resource = "judgments"
        case "action":fields = ["title","hypothesis","method","baseline","metrics","success_criterion","stop_condition","resource_budget","status"];resource = "actions"
        case "result":fields = ["title","body","outcome","artifact_url"];resource = "results"
        default:fields = ["title","understanding","open_questions","next_focus"];resource = "snapshots"
        }
        var body:JSON = .object(Dictionary(uniqueKeysWithValues:fields.map{($0,JSON.string(form[$0].text))}))
        if kind == "judgment" || kind == "snapshot" {body["evidence_ids"] = .strings(evidenceIDs.sorted())}
        if kind == "action" || kind == "result",!form["judgment_id"].text.isEmpty {body["judgment_id"] = form["judgment_id"]}
        if kind == "result",!form["action_id"].text.isEmpty {body["action_id"] = form["action_id"]}
        var path = "research/questions"
        if kind != "question" {path += "/\(question["id"].text)/\(resource)"}
        if editing {path += "/\(record["id"].text)";body["revision"] = record["revision"]}
        do {let result = try await app.request(path,method:editing ? "PATCH" : "POST",body:body);saved(result);app.change += 1;dismiss()}
        catch {self.error = error.localizedDescription}
    }
}

struct SaveResearchEvidenceView:View {
    @EnvironmentObject private var app:AppModel
    @Environment(\.dismiss) private var dismiss
    let paper:Paper
    var block:JSON = .null
    var figure:JSON = .null
    @ViewState private var questions:[JSON] = []
    @ViewState private var selection = ""
    @ViewState private var quote = ""
    @ViewState private var note = ""
    @ViewState private var relation = "context"
    @ViewState private var error:String?
    @ViewState private var busy = false
    @ViewState private var createQuestion = false
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("保存研究证据").font(.title2.weight(.semibold))
            Text(paper.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Form {
                Section {
                    Picker("研究问题",selection:$selection) {Text("选择问题").tag("");ForEach(questions,id:\.["id"].text) {Text($0["title"].text).tag($0["id"].text)}}
                    Button("新建研究问题…",systemImage:"plus") {createQuestion = true}
                    Picker("用途",selection:$relation) {ForEach(["context","supports","contradicts"],id:\.self) {Text(researchStatus($0)).tag($0)}}
                }
                Section("原文摘录") {
                    TextField("保留需要引用的原文",text:$quote,axis:.vertical).lineLimit(4...10)
                    Text("摘录必须保留原文。解释、条件或质疑写在下方备注中。").font(.caption).foregroundStyle(.secondary)
                }
                Section("我的备注") {TextField("这段证据对问题意味着什么",text:$note,axis:.vertical).lineLimit(3...6)}
            }.formStyle(.grouped)
            if let error {InlineError(message:error)}
            HStack {Button("取消") {dismiss()}.keyboardShortcut(.cancelAction);Spacer();if busy {ProgressView().controlSize(.small)};Button("保存证据") {Task {await save()}}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selection.isEmpty || quote.isEmpty || busy)}
        }.padding(24).frame(width:630,height:650)
            .task {quote = block.isNull ? figure["caption"].text : block["text"].text;await load()}
            .sheet(isPresented:$createQuestion) {ResearchRecordEditor(kind:"question",question:.null,record:.null) {value in selection = value["id"].text;Task {await load()}}.environmentObject(app)}
    }
    private func load() async {do {questions = try await app.request("research/questions")["questions"].values;if selection.isEmpty {selection = questions.first?["id"].text ?? ""}} catch {self.error = error.localizedDescription}}
    private func save() async {
        busy = true;error = nil;defer {busy = false}
        var body:JSON = .object(["work_id":.string(paper.id),"quote":.string(quote),"note":.string(note),"relation":.string(relation)])
        if !block.isNull {body["block_id"] = block["id"]}
        if !figure.isNull {body["figure_id"] = figure["id"]}
        do {_ = try await app.request("research/questions/\(selection)/evidence",method:"POST",body:body);app.change += 1;app.notify("证据已保存到研究问题");dismiss()}
        catch {self.error = error.localizedDescription}
    }
}

struct LinkResearchPaper:View {
    @EnvironmentObject private var app:AppModel
    @Environment(\.dismiss) private var dismiss
    let questionID:String
    let linked:Set<String>
    let saved:()->Void
    @ViewState private var query = ""
    @ViewState private var papers:[Paper] = []
    @ViewState private var selected:String?
    @ViewState private var reason = ""
    @ViewState private var busy = false
    @ViewState private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("关联已有论文").font(.title2.weight(.semibold))
            TextField("搜索文献库",text:$query).textFieldStyle(.roundedBorder)
            List(selection:$selected) {
                ForEach(papers.filter{!linked.contains($0.id)}) {paper in VStack(alignment:.leading,spacing:5) {Text(paper.title).font(.headline).lineLimit(2);Text(paper.byline).font(.caption).foregroundStyle(.secondary)}.padding(.vertical,5).tag(paper.id)}
            }.listStyle(.inset).frame(minHeight:250)
            TextField("为什么与这个问题相关（可选）",text:$reason,axis:.vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            if let error {InlineError(message:error)}
            HStack {Button("取消") {dismiss()}.keyboardShortcut(.cancelAction);Spacer();if busy {ProgressView().controlSize(.small)};Button("关联") {Task {await link()}}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selected == nil || busy)}
        }.padding(24).frame(width:630,height:560)
            .task(id:query) {try? await Task.sleep(for:.milliseconds(250));guard !Task.isCancelled else {return};do {let result = try await app.request("works",query:["q":query,"limit":"100"]);guard !Task.isCancelled else {return};papers = result["works"].values.map{Paper(raw:$0)}} catch {if !(error is CancellationError) {self.error = error.localizedDescription}}}
    }
    private func link() async {
        guard let selected else {return};busy = true;defer {busy = false}
        do {_ = try await app.request("research/questions/\(questionID)/works",method:"POST",body:.object(["work_id":.string(selected),"reason":.string(reason)]));saved();app.change += 1;dismiss()}
        catch {self.error = error.localizedDescription}
    }
}

struct DiscoverySheet:View {
    @EnvironmentObject private var app:AppModel
    @Environment(\.dismiss) private var dismiss
    var questionID:String?
    var suggestedQuery = ""
    @ViewState private var query = ""
    @ViewState private var arxiv = true
    @ViewState private var crossref = false
    @ViewState private var limit = 15
    @ViewState private var busy = false
    @ViewState private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("发现相关论文").font(.title2.weight(.semibold))
            Form {
                TextField("检索式",text:$query,axis:.vertical).lineLimit(2...4)
                Text("使用英文关键词或 arXiv 检索式，例如 cat:cs.RO AND all:manipulation。").font(.caption).foregroundStyle(.secondary)
                Toggle("arXiv",isOn:$arxiv);Toggle("Crossref",isOn:$crossref)
                Stepper("每个来源最多 \(limit) 篇",value:$limit,in:5...100,step:5)
            }.formStyle(.grouped)
            Text(questionID == nil ? "结果进入待选池；已知论文会合并，不会重复导入。" : "结果进入待选池，并关联到当前研究问题。只有取得全文后才可作为全文分析材料。")
                .font(.callout).foregroundStyle(.secondary)
            if let error {InlineError(message:error)}
            HStack {Button("取消") {dismiss()}.keyboardShortcut(.cancelAction);Spacer();if busy {ProgressView().controlSize(.small)};Button("开始检索") {Task {await submit()}}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy || query.isEmpty || (!arxiv && !crossref))}
        }.padding(24).frame(width:580,height:430).onAppear {query = suggestedQuery}
    }
    private func submit() async {
        busy = true;defer {busy = false}
        var body:JSON = .object(["kind":.string("discover"),"query":.string(query),"sources":.strings((arxiv ? ["arxiv"] : []) + (crossref ? ["crossref"] : [])),"limit":.integer(limit)])
        if let questionID {body["question_id"] = .string(questionID)}
        do {_ = try await app.request("operations",method:"POST",body:body);app.change += 1;app.notify("检索已提交，来源进度可在任务页查看");dismiss()}
        catch {self.error = error.localizedDescription}
    }
}

struct ResearchSourceView:View {
    @EnvironmentObject private var app:AppModel
    @Environment(\.dismiss) private var dismiss
    let target:ResearchSourceTarget
    @StateObject private var controller = PDFController()
    @ViewState private var url:URL?
    @ViewState private var sha = ""
    @ViewState private var page = 1
    @ViewState private var title = "原文出处"
    @ViewState private var excerpt = ""
    @ViewState private var unknownPage = false
    @ViewState private var error:String?
    var body:some View {
        VStack(spacing:0) {
            HStack {Text(title).font(.headline).lineLimit(2);Spacer();Button("完成") {dismiss()}.keyboardShortcut(.cancelAction)}.padding(18)
            Divider()
            if unknownPage {
                VStack(alignment:.leading,spacing:8) {
                    Label("这段旧资料没有已确认的 PDF 页码，原文从首页打开。",systemImage:"info.circle").font(.callout).foregroundStyle(.secondary)
                    if !excerpt.isEmpty {ScrollView {Text(excerpt).font(.callout).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(maxHeight:120)}
                }.padding(16)
            }
            if let url {
                HStack {Button("上一页",systemImage:"chevron.up") {controller.go(controller.page-1)}.disabled(controller.page <= 1);Text("\(controller.page) / \(controller.pageCount)").monospacedDigit();Button("下一页",systemImage:"chevron.down") {controller.go(controller.page+1)}.disabled(controller.page >= controller.pageCount);Spacer();Button("适合窗口") {controller.fit()}}
                    .font(.caption).padding(12)
                NativePDF(url:url,sha:sha,notes:[],initialPage:page,controller:controller)
            } else if let error {InlineError(message:error).padding(24);Spacer()}
            else {ProgressView("正在打开所引 PDF 版本…").frame(maxWidth:.infinity,maxHeight:.infinity)}
        }.frame(width:820,height:720).task {
            do {
                guard let api = app.api else {return}
                var resolvedSHA = target.sha;var resolvedPage = target.page;var resolvedTitle = target.title
                excerpt = target.excerpt
                if !target.blockID.isEmpty {
                    let block = try await app.request("blocks/\(target.blockID)")
                    resolvedSHA = block["pdf_sha256"].text;resolvedPage = block["page"].int;resolvedTitle = block["work_title"].text
                    if excerpt.isEmpty {excerpt = block["text"].text}
                }
                sha = resolvedSHA;page = max(1,resolvedPage);title = resolvedTitle;unknownPage = resolvedPage < 1
                guard !resolvedSHA.isEmpty else {throw ServerError(message:"此旧资料未保存 PDF；上方保留了原文摘录。")}
                url = try await FileCache.shared.sourcePDF(api:api,serverID:app.serverID,sha:resolvedSHA)
            } catch {self.error = error.localizedDescription}
        }
    }
}

struct JudgmentHistoryView:View {
    @EnvironmentObject private var app:AppModel
    @Environment(\.dismiss) private var dismiss
    let questionID:String
    let judgment:JSON
    @ViewState private var history:[JSON] = []
    @ViewState private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Text("判断修订历史").font(.title2.weight(.semibold));Spacer();Button("完成") {dismiss()}.keyboardShortcut(.cancelAction)}
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    entry(judgment)
                    ForEach(history,id:\.["revision"].int) {entry($0["snapshot"])}
                    if history.isEmpty {Text("还没有较早的修订。").foregroundStyle(.secondary)}
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            if let error {InlineError(message:error)}
        }.padding(24).frame(width:620,height:540).task {do {history = try await app.request("research/questions/\(questionID)/judgments/\(judgment["id"].text)/history")["history"].values} catch {self.error = error.localizedDescription}}
    }
    private func entry(_ item:JSON)->some View {
        VStack(alignment:.leading,spacing:8) {Text("修订 \(item["revision"].int) · " + researchStatus(item["status"].text)).font(.caption).foregroundStyle(.secondary);Text(item["statement"].text).font(.headline);Text(item["rationale"].text).font(.callout);Text(item["next_step"].text).font(.callout).foregroundStyle(.secondary);Divider()}.textSelection(.enabled)
    }
}
