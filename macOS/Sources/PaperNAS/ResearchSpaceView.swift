import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ResearchEditorTarget:Identifiable {
    let id = UUID()
    var kind:String
    var record:JSON = .null
}

struct ResearchSourceTarget:Identifiable {
    var id:String
    var blockID:String = ""
    var sha:String = ""
    var page:Int = 1
    var title:String = "原文出处"
    var excerpt:String = ""
    init(evidence:JSON) {
        id = evidence["id"].text;blockID = evidence["block_id"].text;sha = evidence["pdf_sha256"].text
        page = evidence["page"].int;title = evidence["work_title"].text;excerpt = evidence["quote"].text
    }
    init(blockID:String) {id = blockID;self.blockID = blockID}
}

func researchStatus(_ value:String)->String {
    ["active":"进行中","paused":"暂缓","completed":"已完成","tentative":"待验证","accepted":"已确认","revised":"已修订",
     "planned":"计划中","running":"执行中","abandoned":"已停止","supports":"支持","contradicts":"反对","context":"背景",
     "inconclusive":"尚无定论","observation":"观察记录"][value] ?? value
}

struct ResearchSpaceView:View {
    @EnvironmentObject private var app:AppModel
    let openPaper:(String)->Void
    @ViewState private var questions:[JSON] = []
    @ViewState private var selection:String?
    @ViewState private var detail:JSON = .null
    @ViewState private var pane = "materials"
    @ViewState private var query = ""
    @ViewState private var loading = false
    @ViewState private var error:String?
    @ViewState private var editor:ResearchEditorTarget?
    @ViewState private var linkSheet = false
    @ViewState private var discoverSheet = false
    @ViewState private var source:ResearchSourceTarget?
    @ViewState private var history:JSON?
    @ViewState private var comparisonBusy = false
    var body:some View {
        HSplitView {
            VStack(spacing:0) {
                HStack {
                    Text("研究问题").font(.headline)
                    Spacer()
                    IconButton(title:"新建研究问题",symbol:"plus") {editor = .init(kind:"question")}.buttonStyle(.borderless)
                }.padding(16)
                TextField("查找研究问题",text:$query).textFieldStyle(.roundedBorder).padding(.horizontal,12).padding(.bottom,10)
                List(selection:$selection) {
                    ForEach(questions,id:\.["id"].text) {question in
                        VStack(alignment:.leading,spacing:6) {
                            Text(question["title"].text).font(.system(size:13,weight:.medium)).lineLimit(3)
                            Text("\(question["work_count"].int) 篇材料 · \(question["evidence_count"].int) 条证据")
                                .font(.caption).foregroundStyle(.secondary)
                            if question["status"].text != "active" {Text(researchStatus(question["status"].text)).font(.caption).foregroundStyle(.secondary)}
                        }.padding(.vertical,6).tag(question["id"].text)
                    }
                }.listStyle(.inset)
                if questions.isEmpty && !loading {Text(query.isEmpty ? "从一个想弄清楚的问题开始。" : "没有匹配的问题。")
                    .font(.callout).foregroundStyle(.secondary).padding(18)}
            }.frame(minWidth:190,idealWidth:230,maxWidth:290)
            VStack(spacing:0) {
                if let error {InlineError(message:error) {Task {await refresh()}}.padding(16)}
                if !detail.isNull {
                    questionHeader
                    Picker("研究内容",selection:$pane) {
                        Text("材料与证据").tag("materials")
                        Text("判断与计划").tag("decisions")
                        Text("结果与认识").tag("results")
                        Text("比较").tag("comparison")
                    }.pickerStyle(.segmented).padding(.horizontal,24).padding(.bottom,16)
                    Divider()
                    ScrollView {
                        VStack(alignment:.leading,spacing:28) {
                            if pane == "materials" {materials; evidence}
                            else if pane == "decisions" {judgments;actions}
                            else if pane == "results" {results;snapshots}
                            else {comparison}
                        }.padding(24).frame(maxWidth:900,alignment:.leading).frame(maxWidth:.infinity)
                    }
                } else if loading {ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)}
                else {VStack(spacing:18) {
                    EmptyState(symbol:"square.stack.3d.up",title:"把阅读连接到研究",detail:"保存问题、原文证据和自己的判断，再记录接下来做了什么。")
                    Button("新建研究问题",systemImage:"plus") {editor = .init(kind:"question")}.buttonStyle(.borderedProminent)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)}
            }.frame(minWidth:380,maxWidth:.infinity,maxHeight:.infinity)
        }
        .background(Color(nsColor:.textBackgroundColor))
        .task {await refresh()}
        .task(id:selection) {await loadDetail()}
        .task(id:query) {try? await Task.sleep(for:.milliseconds(280));guard !Task.isCancelled else {return};await loadQuestions()}
        .onChange(of:app.change) {_,_ in Task {await refresh()}}
        .sheet(item:$editor) {target in
            ResearchRecordEditor(kind:target.kind,question:detail,record:target.record) {saved in
                if target.kind == "question" {selection = saved["id"].text}
                Task {await refresh()}
            }.environmentObject(app)
        }
        .sheet(isPresented:$linkSheet) {if let selection {LinkResearchPaper(questionID:selection,linked:Set(detail["works"].values.map{$0["id"].text})) {Task {await refresh()}}.environmentObject(app)}}
        .sheet(isPresented:$discoverSheet) {DiscoverySheet(questionID:selection,suggestedQuery:detail["title"].text).environmentObject(app)}
        .sheet(item:$source) {target in ResearchSourceView(target:target).environmentObject(app)}
        .sheet(isPresented:Binding(get:{history != nil},set:{if !$0 {history = nil}})) {
            if let history,let selection {JudgmentHistoryView(questionID:selection,judgment:history).environmentObject(app)}
        }
    }
    private var questionHeader:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(alignment:.top,spacing:14) {
                Text(detail["title"].text).font(.title2.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
                Menu {
                    Button("编辑问题",systemImage:"pencil") {editor = .init(kind:"question",record:detail)}
                    Button("导出研究备忘录…",systemImage:"square.and.arrow.up") {Task {await export("markdown")}}
                    Button("导出全部记录（JSON）…") {Task {await export("json")}}
                    Button("刷新",systemImage:"arrow.clockwise") {Task {await refresh()}}
                } label:{Image(systemName:"ellipsis.circle")}.menuStyle(.borderlessButton).fixedSize().help("研究问题操作")
            }
            HStack {Text(researchStatus(detail["status"].text));Text("·");Text("\(detail["works"].values.count) 篇材料 · \(detail["evidence"].values.count) 条证据");if loading {ProgressView().controlSize(.mini)}}
                .font(.caption).foregroundStyle(.secondary)
            if !detail["context"].text.isEmpty || !detail["constraints"].text.isEmpty {
                DisclosureGroup("问题背景与约束") {
                    VStack(alignment:.leading,spacing:10) {
                        if !detail["context"].text.isEmpty {Text(detail["context"].text)}
                        if !detail["constraints"].text.isEmpty {Text("约束：" + detail["constraints"].text)}
                    }.font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.top,8).frame(maxWidth:.infinity,alignment:.leading)
                }.font(.callout)
            }
        }.padding(24)
    }
    private var materials:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("相关材料").font(.headline);Spacer();Button("发现论文",systemImage:"magnifyingglass") {discoverSheet = true};Button("关联论文",systemImage:"link") {linkSheet = true}}
            if detail["works"].values.isEmpty {hint("先从文献库关联论文，或按问题检索候选。阅读原文时可直接保存证据。")}
            ForEach(detail["works"].values,id:\.["id"].text) {work in
                VStack(alignment:.leading,spacing:8) {
                    HStack(alignment:.top) {
                        Button {openPaper(work["id"].text)} label:{Text(work["title"].text).font(.system(size:14,weight:.medium)).multilineTextAlignment(.leading)}.buttonStyle(.plain)
                        Spacer(minLength:12)
                        Menu {
                            Button("打开阅读",systemImage:"book") {openPaper(work["id"].text)}
                            Button("提取全文",systemImage:"doc.text.viewfinder") {Task {do {_ = try await app.job("extract_paper",key:work["id"].text)} catch {app.handle(error)}}}
                            ForEach(["useful","known","later","irrelevant"],id:\.self) {choice in
                                Button(["useful":"有用","known":"已知","later":"稍后读","irrelevant":"不相关"][choice]!) {Task {await app.perform("works/\(work["id"].text)/feedback",method:"PUT",body:.object(["choice":.string(choice),"question_id":detail["id"]]),message:"已保存反馈")}}
                            }
                            Divider()
                            Button("移除此关联",role:.destructive) {Task {await app.perform("research/questions/\(detail["id"].text)/works/\(work["id"].text)",method:"DELETE");await refresh()}}
                        } label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).fixedSize().help("材料操作")
                    }
                    HStack {Text(work["current_document_id"].isNull ? "仅元数据" : "正文已解析");if !work["reason"].text.isEmpty {Text("·");Text(work["reason"].text).lineLimit(2)}}.font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical,4)
                Divider()
            }
        }
    }
    private var evidence:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("原文证据").font(.headline)
            if detail["evidence"].values.isEmpty {hint("打开论文的“提取原文”或“图表”，把需要保留的内容保存到这个问题。")}
            ForEach(detail["evidence"].values,id:\.["id"].text) {item in evidenceCard(item)}
        }
    }
    private func evidenceCard(_ item:JSON)->some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {Text(researchStatus(item["relation"].text)).font(.caption.weight(.medium));Spacer();Button(item["page"].int > 0 ? "查看第 \(item["page"].int) 页" : "查看原文") {source = .init(evidence:item)}.buttonStyle(.link)}
            Text(item["quote"].text).font(.callout).lineSpacing(4).textSelection(.enabled)
            if !item["note"].text.isEmpty {Text(item["note"].text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)}
            Text(item["work_title"].text).font(.caption).foregroundStyle(.secondary)
            if item["source_is_older"].flag {Label("此证据引用较早的文档版本",systemImage:"clock").font(.caption).foregroundStyle(.orange)}
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
    }
    private var judgments:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("当前判断").font(.headline);Spacer();Button("记录判断",systemImage:"plus") {editor = .init(kind:"judgment")}}
            if detail["judgments"].values.isEmpty {hint("写下目前的判断、依据和下一步。没有充分证据时可以保存为“待验证”。")}
            ForEach(detail["judgments"].values,id:\.["id"].text) {item in
                VStack(alignment:.leading,spacing:12) {
                    HStack {Text(researchStatus(item["status"].text)).font(.caption).foregroundStyle(.secondary);Spacer();Button("修订") {editor = .init(kind:"judgment",record:item)};Button("历史") {history = item}}
                    Text(item["statement"].text).font(.headline).textSelection(.enabled)
                    if !item["rationale"].text.isEmpty {Text(item["rationale"].text).font(.callout).textSelection(.enabled)}
                    if !item["next_step"].text.isEmpty {Label(item["next_step"].text,systemImage:"arrow.right.circle").font(.callout).foregroundStyle(.secondary)}
                    if !item["evidence_ids"].values.isEmpty {
                        DisclosureGroup("\(item["evidence_ids"].values.count) 条依据") {
                            ForEach(detail["evidence"].values.filter{item["evidence_ids"].values.contains($0["id"])},id:\.["id"].text) {e in evidenceCard(e).padding(.top,8)}
                        }.font(.callout)
                    }
                }.padding(.vertical,4)
                Divider()
            }
        }
    }
    private var actions:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("验证计划").font(.headline);Spacer();Button("新建计划",systemImage:"plus") {editor = .init(kind:"action")}}
            if detail["actions"].values.isEmpty {hint("把待验证的判断变成具体步骤，写清基线、指标和停止条件。")}
            ForEach(detail["actions"].values,id:\.["id"].text) {item in
                VStack(alignment:.leading,spacing:10) {
                    HStack {Text(item["title"].text).font(.headline);Spacer();Button("编辑") {editor = .init(kind:"action",record:item)}}
                    Text(researchStatus(item["status"].text)).font(.caption).foregroundStyle(.secondary)
                    if !item["hypothesis"].text.isEmpty {Text(item["hypothesis"].text).font(.callout)}
                    if !item["method"].text.isEmpty {Text(item["method"].text).font(.callout).textSelection(.enabled)}
                    if !item["success_criterion"].text.isEmpty {Text("判据：" + item["success_criterion"].text).font(.callout).foregroundStyle(.secondary)}
                    Button("记录结果",systemImage:"square.and.pencil") {editor = .init(kind:"result",record:.object(["action_id":item["id"],"judgment_id":item["judgment_id"]]))}.buttonStyle(.link)
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
            }
        }
    }
    private var results:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("实际结果").font(.headline);Spacer();Button("记录结果",systemImage:"plus") {editor = .init(kind:"result")}}
            if detail["results"].values.isEmpty {hint("在外部工具完成实验或调查后，记录实际观察，并连接到对应计划。")}
            ForEach(detail["results"].values,id:\.["id"].text) {item in
                VStack(alignment:.leading,spacing:10) {
                    Text(item["title"].text).font(.headline)
                    Text(researchStatus(item["outcome"].text) + " · " + String(item["created_at"].text.prefix(10))).font(.caption).foregroundStyle(.secondary)
                    Text(item["body"].text).font(.callout).lineSpacing(4).textSelection(.enabled)
                    if let url = URL(string:item["artifact_url"].text),["http","https"].contains(url.scheme ?? "") {Link("查看结果材料",destination:url)}
                }
                Divider()
            }
        }
    }
    private var snapshots:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("认识快照").font(.headline);Spacer();Button("保存当前认识",systemImage:"plus") {editor = .init(kind:"snapshot")}}
            if detail["snapshots"].values.isEmpty {hint("阶段性记下已经弄清楚的内容、仍有分歧的问题，以及下一轮关注方向。")}
            ForEach(detail["snapshots"].values,id:\.["id"].text) {item in
                VStack(alignment:.leading,spacing:10) {
                    Text(item["title"].text).font(.headline)
                    Text(String(item["created_at"].text.prefix(10))).font(.caption).foregroundStyle(.secondary)
                    Text(item["understanding"].text).font(.callout).lineSpacing(4).textSelection(.enabled)
                    if !item["open_questions"].text.isEmpty {Text("待解问题：" + item["open_questions"].text).font(.callout).foregroundStyle(.secondary)}
                    if !item["next_focus"].text.isEmpty {Text("下一步关注：" + item["next_focus"].text).font(.callout).foregroundStyle(.secondary)}
                }
                Divider()
            }
        }
    }
    private var comparison:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Text("围绕问题比较材料").font(.headline);Spacer();if comparisonBusy {ProgressView().controlSize(.small)};Button("生成比较",systemImage:"sparkles") {Task {await compare()}}.disabled(comparisonBusy || detail["works"].values.filter{!$0["current_document_id"].isNull}.count < 2)}
            hint("使用当前问题下已解析的论文正文，保留条件差异和未知项。至少需要两篇材料，输出中的研究结论需要你核验。")
            if let item = detail["comparisons"].values.first {
                let report = item["data"]
                Text(report["title"].text).font(.title3.weight(.semibold))
                Text("生成于 " + ServerTimestamp.display(item["created_at"].text) + " · 引用 \(report["coverage"]["selected_blocks"].int) 个原文段落")
                    .font(.caption).foregroundStyle(.secondary)
                comparisonClaim(report["summary"])
                ForEach(Array(report["findings"].values.enumerated()),id:\.offset) {_,claim in comparisonClaim(claim)}
                if !report["limitations"].values.isEmpty {Text("条件与局限").font(.headline);ForEach(Array(report["limitations"].values.enumerated()),id:\.offset) {_,claim in comparisonClaim(claim)}}
                if !report["unknowns"].values.isEmpty {Text("尚不能确定").font(.headline);ForEach(Array(report["unknowns"].values.enumerated()),id:\.offset) {_,line in Text("• " + line.text).font(.callout)}}
                if !report["suggested_next_steps"].values.isEmpty {Text("建议的下一步 · 尚未执行").font(.headline);ForEach(Array(report["suggested_next_steps"].values.enumerated()),id:\.offset) {_,line in Text("• " + line.text).font(.callout)}}
            }
        }
    }
    private func comparisonClaim(_ claim:JSON)->some View {
        VStack(alignment:.leading,spacing:10) {
            Text(claim["text"].text).font(.callout).lineSpacing(4).textSelection(.enabled)
            ForEach(Array(claim["citations"].values.enumerated()),id:\.offset) {_,citation in
                Button {source = .init(blockID:citation["block_id"].text)} label:{Label(citation["quote"].text,systemImage:"text.quote").font(.caption).multilineTextAlignment(.leading)}.buttonStyle(.link)
            }
        }.padding(.vertical,5)
    }
    private func hint(_ text:String)->some View {Text(text).font(.callout).foregroundStyle(.secondary).lineSpacing(3).frame(maxWidth:.infinity,alignment:.leading)}
    private func loadQuestions() async {
        do {let value = try await app.request("research/questions",query:["q":query]);guard !Task.isCancelled else {return};questions = value["questions"].values;if selection == nil {selection = questions.first?["id"].text};error = nil}
        catch {if !(error is CancellationError) {self.error = error.localizedDescription}}
    }
    private func loadDetail() async {
        guard let selection else {detail = .null;return}
        loading = true;defer {loading = false}
        do {let value = try await app.request("research/questions/\(selection)");guard self.selection == selection,!Task.isCancelled else {return};detail = value;error = nil}
        catch {if !(error is CancellationError) {self.error = error.localizedDescription}}
    }
    private func refresh() async {await loadQuestions();await loadDetail()}
    private func compare() async {
        guard let selection else {return};comparisonBusy = true;defer {comparisonBusy = false}
        do {_ = try await app.request("operations",method:"POST",body:.object(["kind":.string("compare"),"question_id":.string(selection)]));app.notify("比较已加入服务器任务");app.change += 1}
        catch {self.error = error.localizedDescription}
    }
    private func export(_ format:String) async {
        guard let selection,let api = app.api else {return}
        let panel = NSSavePanel();panel.nameFieldStringValue = String(detail["title"].text.prefix(60)).replacingOccurrences(of:"/",with:"-") + (format == "json" ? ".json" : ".md")
        if panel.runModal() == .OK,let url = panel.url {
            do {try await api.download("research/questions/\(selection)/export",destination:url,query:["format":format]);app.notify("研究记录已导出")}
            catch {self.error = error.localizedDescription}
        }
    }
}
