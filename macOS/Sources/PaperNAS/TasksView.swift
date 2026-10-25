import SwiftUI
import AppKit

struct TasksView:View {
    @EnvironmentObject var app:AppModel
    @ViewState private var jobs:[ServerJob] = []
    @ViewState private var downloads:[JSON] = []
    @ViewState private var selection:String?
    @ViewState private var error:String?
    @ViewState private var loading = false
    @ViewState private var showDownloads = false
    @ViewState private var cancel:ServerJob?
    private var selected:ServerJob? { jobs.first{$0.id == selection} }
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:16) {
                VStack(alignment:.leading,spacing:5) {
                    Text(showDownloads ? "PDF 下载队列" : "服务器任务").font(.title2.weight(.semibold))
                    let schedule = app.overview["collection_schedule"]
                    Text(showDownloads ? "\(downloads.count) 条下载记录" : schedule["next_run"].text.isEmpty ? "关闭 App 后，服务器仍会继续处理。" : "下次自动筛选：\(ServerTimestamp.display(schedule["next_run"].text))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if loading {ProgressView().controlSize(.small)}
                IconButton(title:"刷新任务",symbol:"arrow.clockwise") {Task {await load()}}.buttonStyle(.borderless)
                Menu {
                    Button("每日筛选",systemImage:"sparkles") {submit("daily")}
                    Button("采集论文",systemImage:"tray.and.arrow.down") {submit("collect")}
                    Button("提取论文库",systemImage:"doc.text.viewfinder") {submit("extract")}
                    Button("精读论文库",systemImage:"text.book.closed") {submit("analyze")}
                    Button("检查来源",systemImage:"network") {submit("check_sources")}
                } label:{Image(systemName:"play.circle")}.menuStyle(.borderlessButton).fixedSize().help("开始服务器任务").accessibilityLabel("开始服务器任务")
                IconButton(title:showDownloads ? "返回服务器任务" : "PDF 下载队列",symbol:showDownloads ? "list.bullet.rectangle" : "arrow.down.circle") {showDownloads.toggle()}.buttonStyle(.borderless)
            }.padding(24)
            if let error {InlineError(message:error) {Task {await load()}}.padding(.horizontal,20).padding(.bottom,12)}
            Divider()
            if showDownloads {downloadPane}
            else if jobs.isEmpty && !loading {EmptyState(symbol:"clock",title:"暂无任务",detail:"从右上角开始采集或筛选论文。")}
            else {
                HSplitView {
                    List(jobs,selection:$selection) {job in
                        HStack(alignment:.top,spacing:12) {
                            Image(systemName:job.symbol).foregroundStyle(job.color).font(.title3).frame(width:24)
                            VStack(alignment:.leading,spacing:7) {
                                HStack {Text(job.title).font(.headline);Spacer();Text(job.statusLabel).font(.caption).foregroundStyle(job.color)}
                                Text(job.progress["stage"].text.isEmpty ? job.raw["model"].text : job.progress["stage"].text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                Text(ServerTimestamp.display(job.raw["started_at"].text)).font(.caption).foregroundStyle(.tertiary)
                                if job.active && job.progress["total"].int > 0 {ProgressView(value:Double(job.progress["completed"].int),total:Double(job.progress["total"].int)).controlSize(.small)}
                            }
                        }.padding(.vertical,10).tag(job.id)
                    }.listStyle(.inset).frame(minWidth:290,idealWidth:360,maxWidth:460)
                    if let selected {jobDetails(selected).frame(minWidth:330,maxWidth:.infinity)}
                    else {EmptyState(symbol:"text.alignleft",title:"选择一个任务").frame(minWidth:330)}
                }
            }
        }
        .task {await load()}
        .task(id:app.change) {await load()}
        .alert("取消这个服务器任务？",isPresented:Binding(get:{cancel != nil},set:{if !$0 {cancel = nil}})) {
            Button("继续任务",role:.cancel) {cancel = nil}
            Button("取消任务",role:.destructive) {if let job = cancel {control(job,"cancel")};cancel = nil}
        } message:{Text("服务器会停止后续处理，已保存的结果会保留。")}
    }
    private func jobDetails(_ job:ServerJob)->some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Text(job.title).font(.title2.weight(.semibold));Spacer()
                if ["running","pausing","paused"].contains(job.status) {
                    IconButton(title:job.status == "paused" ? "继续任务" : "暂停任务",symbol:job.status == "paused" ? "play" : "pause") {control(job,job.status == "paused" ? "resume" : "pause")}.disabled(job.status == "pausing")
                }
                if job.active {IconButton(title:"取消任务",symbol:"stop",role:.destructive) {cancel = job}}
                if ["failed","cancelled","waiting"].contains(job.status) {IconButton(title:"重试任务",symbol:"arrow.clockwise") {control(job,"retry")}}
                IconButton(title:"导出日志",symbol:"square.and.arrow.up") {Task {await export(job)}}
            }.buttonStyle(.borderless)
            HStack(spacing:20) {
                Label(job.statusLabel,systemImage:job.symbol).foregroundStyle(job.color)
                if job.progress["total"].int > 0 {Text("\(job.progress["completed"].int) / \(job.progress["total"].int) 篇").foregroundStyle(.secondary)}
                if job.progress["deep_target"].int > 0 {Text("精读 \(job.progress["deep_completed"].int) / \(job.progress["deep_target"].int)").foregroundStyle(.secondary)}
            }.font(.callout)
            if !job.paperTitle.isEmpty {Text(job.paperTitle).font(.headline).textSelection(.enabled)}
            if !job.progress["stage"].text.isEmpty {Text(job.progress["stage"].text).foregroundStyle(.secondary)}
            if job.progress["request_pending"].flag {Label("模型正在处理请求",systemImage:"ellipsis.message").font(.caption).foregroundStyle(.secondary)}
            Divider()
            ScrollView {
                LazyVStack(alignment:.leading,spacing:8) {
                    ForEach(Array(job.raw["log"].values.enumerated()),id:\.offset) {_,line in Text(line.text).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
                }
            }
        }.padding(24)
    }
    private var downloadPane:some View {
        List {
            if downloads.isEmpty {EmptyState(symbol:"arrow.down.circle",title:"没有 PDF 下载任务")}
            ForEach(Array(downloads.enumerated()),id:\.offset) {_,d in
                HStack {
                    Image(systemName:"doc.richtext").foregroundStyle(.secondary)
                    VStack(alignment:.leading,spacing:5) {Text(d["title"].text);Text(downloadStatus(d["status"].text)).font(.caption).foregroundStyle(.secondary)}
                    Spacer()
                    if ["queued","downloading","retrying","waiting"].contains(d["status"].text) {IconButton(title:"暂停下载",symbol:"pause") {downloadControl(d,"pause")}}
                    if d["status"].text == "paused" {IconButton(title:"继续下载",symbol:"play") {downloadControl(d,"resume")}}
                    if d["status"].text == "failed" {IconButton(title:"重新下载",symbol:"arrow.clockwise") {downloadControl(d,"retry")}}
                }.padding(.vertical,10).buttonStyle(.borderless)
            }
        }.listStyle(.inset)
    }
    private func load() async {
        guard app.api != nil else {return};loading = true;defer {loading = false}
        do {
            async let response = app.request("jobs")
            async let ds = app.request("downloads")
            let (j,d) = try await(response,ds)
            var seen = Set<String>()
            jobs = ([j["active"],j["pending"]] + j["queued"].values + j["recent"].values).filter{!$0["id"].text.isEmpty && seen.insert($0["id"].text).inserted}.map{ServerJob(raw:$0)}
            downloads = d["downloads"].values; error = nil
            if selection == nil {selection = jobs.first?.id}
        } catch {self.error = error.localizedDescription}
    }
    private func submit(_ action:String) {Task {do {_ = try await app.job(action);await load()} catch {app.handle(error)}}}
    private func control(_ job:ServerJob,_ action:String) {Task {await app.perform("jobs/\(job.id)/\(action)");await load()}}
    private func downloadControl(_ d:JSON,_ action:String) {Task {await app.perform("downloads/\(d["key"].text)/\(action)");await load()}}
    private func downloadStatus(_ status:String)->String {
        ["ready":"已下载","queued":"排队中","downloading":"下载中","retrying":"正在重试","waiting":"等待下载","paused":"已暂停","failed":"下载失败","cancelled":"已取消"][status] ?? status
    }
    private func export(_ job:ServerJob) async {
        guard let api = app.api else {return};let panel = NSSavePanel();panel.nameFieldStringValue = "task-\(job.id).log"
        if panel.runModal() == .OK,let url = panel.url {do {try await api.download("jobs/\(job.id)/log",destination:url)} catch {app.handle(error)}}
    }
}
