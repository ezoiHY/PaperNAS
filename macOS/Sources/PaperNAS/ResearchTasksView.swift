import SwiftUI

func operationLabel(_ value:String)->String {
    ["import":"导入论文","import_pdf":"导入 PDF","resolve":"取得论文信息","fetch_pdf":"获取 PDF","fetch_html":"获取原文网页",
     "parse":"解析正文与布局","figure":"准备图表","analyze":"生成论文分析","extract":"提取论文材料","discover":"发现论文","compare":"比较研究材料","repair_figure":"修正图表",
     "queued":"排队中","pending":"待处理","running":"进行中","ready":"已完成","succeeded":"已完成","failed":"失败",
     "completed_with_gaps":"部分完成","needs_input":"需要处理","paused":"已暂停","cancelled":"已取消","skipped":"已跳过","todo":"排队中","doing":"处理中"] [value] ?? value
}

struct ResearchTasksView:View {
    @EnvironmentObject private var app:AppModel
    @ViewState private var operations:[JSON] = []
    @ViewState private var selection:String?
    @ViewState private var detail:JSON = .null
    @ViewState private var error:String?
    @ViewState private var loading = false
    @ViewState private var discover = false
    @ViewState private var resolution:JSON?
    @ViewState private var cancel = false
    var body:some View {
        VStack(spacing:0) {
            HStack {VStack(alignment:.leading,spacing:5) {Text("服务器任务").font(.title2.weight(.semibold));Text("已完成的材料会保留；关闭客户端后服务器继续工作。").font(.caption).foregroundStyle(.secondary)};Spacer();Button("发现论文",systemImage:"magnifyingglass") {discover = true};IconButton(title:"刷新任务",symbol:"arrow.clockwise") {Task {await load()}}.buttonStyle(.borderless)}.padding(24)
            if let error {InlineError(message:error).padding(.horizontal,24)}
            Divider()
            HSplitView {
                List(selection:$selection) {
                    ForEach(operations,id:\.["id"].text) {operation in
                        VStack(alignment:.leading,spacing:6) {
                            Text(operationLabel(operation["kind"].text)).font(.headline)
                            Text(operationLabel(operation["state"].text)).font(.caption).foregroundStyle(["needs_input","failed","completed_with_gaps"].contains(operation["state"].text) ? Color.orange : .secondary)
                            Text(ServerTimestamp.display(operation["created_at"].text)).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical,6).tag(operation["id"].text)
                    }
                }.listStyle(.inset).frame(minWidth:190,idealWidth:235,maxWidth:290)
                ScrollView {
                    if !detail.isNull {operationDetail.padding(24).frame(maxWidth:850,alignment:.leading).frame(maxWidth:.infinity)}
                    else {EmptyState(symbol:"clock.arrow.circlepath",title:loading ? "正在读取任务" : "选择一个任务")}
                }.frame(minWidth:380,maxWidth:.infinity)
            }
        }.task {await load()}.task(id:selection) {await loadDetail()}.onChange(of:app.change) {_,_ in Task {await load()}}
            .sheet(isPresented:$discover) {DiscoverySheet().environmentObject(app)}
            .sheet(isPresented:Binding(get:{resolution != nil},set:{if !$0 {resolution = nil}})) {if let resolution {ModelResolutionView(invocation:resolution) {Task {await load()}}.environmentObject(app)}}
            .alert("取消这个任务？",isPresented:$cancel) {Button("保留",role:.cancel) {};Button("取消任务",role:.destructive) {Task {await control("cancel")}}} message:{Text("已完成的材料仍会保留。已经发出的模型调用可能继续计费，其结果会记录在调用历史中。")}
    }
    private var operationDetail:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {Text(operationLabel(detail["kind"].text)).font(.title3.weight(.semibold));Spacer();controls}
            Text(operationLabel(detail["state"].text)).font(.headline)
            HStack(spacing:20) {Text("完成 \(detail["progress"]["completed"].int) / \(detail["progress"]["total"].int) 个阶段");if detail["budget_used"].int > 0 || detail["budget_reserved"].int > 0 {Text("已用 \(detail["budget_used"].int) · 预留 \(detail["budget_reserved"].int) tokens")}}
                .font(.caption).foregroundStyle(.secondary)
            ForEach(detail["stages"].values,id:\.["id"].text) {stage in
                VStack(alignment:.leading,spacing:9) {
                    HStack {Text(operationLabel(stage["kind"].text)).font(.headline);Spacer();Text(operationLabel(stage["outcome"].text == "pending" && !stage["execution_status"].text.isEmpty ? stage["execution_status"].text : stage["outcome"].text)).font(.caption).foregroundStyle(.secondary)}
                    if !stage["error"]["message"].text.isEmpty {Text(stage["error"]["message"].text).font(.callout).foregroundStyle(.orange).textSelection(.enabled)}
                    if !stage["result"]["coverage"].isNull {
                        let coverage = stage["result"]["coverage"]
                        Text("本次返回 \(coverage["returned"].int) 篇 · 每页上限 \(coverage["limit"].int) · 第 \(coverage["page"].int + 1) 页")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("这是该检索范围内的结果，未声称覆盖全部历史论文。").font(.caption).foregroundStyle(.secondary)
                    }
                    if !stage["result"]["warning"].text.isEmpty {Text(stage["result"]["warning"].text).font(.caption).foregroundStyle(.secondary)}
                    ForEach(Array(stage["result"]["warnings"].values.enumerated()),id:\.offset) {_,warning in Text(warning.text).font(.caption).foregroundStyle(.secondary)}
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
            }
            if !detail["invocations"].values.isEmpty {
                Text("模型调用记录").font(.headline)
                ForEach(detail["invocations"].values,id:\.["id"].text) {invocation in
                    VStack(alignment:.leading,spacing:8) {
                        Text(invocation["model"].text).font(.callout.weight(.medium))
                        HStack {Text(invocation["state"].text == "unknown" ? "结果未知 · 已保留预算" : invocation["state"].text == "received" ? "响应已保存" : invocation["state"].text == "resolved" ? "已人工核对" : invocation["state"].text).font(.caption).foregroundStyle(.secondary);Spacer();if invocation["state"].text == "unknown" {Button("核对后处理") {resolution = invocation}}}
                    }.padding(.vertical,8)
                }
            }
        }
    }
    @ViewBuilder private var controls:some View {
        if detail["state"].text == "paused" {Button("继续",systemImage:"play") {Task {await control("resume")}}}
        if ["queued","running"].contains(detail["state"].text) {Button("暂停",systemImage:"pause") {Task {await control("pause")}}}
        if ["failed","needs_input","completed_with_gaps"].contains(detail["state"].text) {Button("重试未完成项",systemImage:"arrow.clockwise") {Task {await control("retry")}}.disabled(detail["invocations"].values.contains{["sending","unknown"].contains($0["state"].text)})}
        if ["queued","running","paused","needs_input"].contains(detail["state"].text) {Button("取消",role:.destructive) {cancel = true}}
    }
    private func load() async {
        loading = true;defer {loading = false}
        do {operations = try await app.request("operations")["operations"].values;if selection == nil {selection = operations.first?["id"].text};error = nil;await loadDetail()}
        catch {self.error = error.localizedDescription}
    }
    private func loadDetail() async {
        guard let selection else {return}
        do {let value = try await app.request("operations/\(selection)");guard self.selection == selection else {return};detail = value;error = nil}
        catch {self.error = error.localizedDescription}
    }
    private func control(_ action:String) async {
        guard let selection else {return}
        do {_ = try await app.request("operations/\(selection)/\(action)",method:"POST",body:.object([:]));await load();app.change += 1}
        catch {self.error = error.localizedDescription}
    }
}

struct ModelResolutionView:View {
    @EnvironmentObject private var app:AppModel
    @Environment(\.dismiss) private var dismiss
    let invocation:JSON
    let saved:()->Void
    @ViewState private var outcome = "charged_no_result"
    @ViewState private var tokens = ""
    @ViewState private var note = ""
    @ViewState private var busy = false
    @ViewState private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("处理结果未知的调用").font(.title2.weight(.semibold))
            Text("先查看模型提供商的调用或账单记录。保存核对结果后，仍需手动选择是否重新运行任务。").font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("核对结果",selection:$outcome) {Text("已计费，但没有可用响应").tag("charged_no_result");Text("确认请求未计费").tag("not_charged")}
                if outcome == "charged_no_result" {TextField("实际使用 tokens",text:$tokens)}
                TextField("核对依据",text:$note,axis:.vertical).lineLimit(3...5)
            }.formStyle(.grouped)
            if let error {InlineError(message:error)}
            HStack {Button("取消") {dismiss()}.keyboardShortcut(.cancelAction);Spacer();if busy {ProgressView().controlSize(.small)};Button("保存核对结果") {Task {await save()}}.buttonStyle(.borderedProminent).disabled(busy || note.isEmpty || (outcome == "charged_no_result" && (Int(tokens) ?? 0) <= 0))}
        }.padding(24).frame(width:580,height:400)
    }
    private func save() async {
        busy = true;defer {busy = false}
        do {_ = try await app.request("model-invocations/\(invocation["id"].text)/resolve",method:"POST",body:.object(["outcome":.string(outcome),"used_tokens":.integer(outcome == "not_charged" ? 0 : Int(tokens) ?? 0),"note":.string(note)]));saved();dismiss()}
        catch {self.error = error.localizedDescription}
    }
}
