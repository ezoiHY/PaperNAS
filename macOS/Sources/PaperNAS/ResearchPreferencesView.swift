import SwiftUI

struct ResearchPreferencesView:View {
    @EnvironmentObject private var app:AppModel
    @AppStorage("appearance") private var appearance = "system"
    @ViewState private var pane = "model"
    @ViewState private var model:JSON = .null
    @ViewState private var discovery:JSON = .null
    @ViewState private var modelRevision = 0
    @ViewState private var discoveryRevision = 0
    @ViewState private var apiKey = ""
    @ViewState private var keyConfigured = false
    @ViewState private var devices:[JSON] = []
    @ViewState private var busy = false
    @ViewState private var error:String?
    @ViewState private var status:String?
    @ViewState private var cacheBytes = 0
    var body:some View {
        HStack(spacing:0) {
            List(selection:$pane) {
                Label("通用",systemImage:"gearshape").tag("general")
                Label("模型",systemImage:"sparkles").tag("model")
                Label("发现与订阅",systemImage:"magnifyingglass").tag("discovery")
                Label("设备",systemImage:"laptopcomputer").tag("devices")
            }.listStyle(.sidebar).frame(width:170)
            Divider()
            VStack(spacing:0) {
                if let error {InlineError(message:error).padding(18)}
                Form {
                    if pane == "general" {
                        Section("外观") {Picker("主题",selection:$appearance) {Text("跟随系统").tag("system");Text("浅色").tag("light");Text("深色").tag("dark")}}
                        Section("服务器") {
                            LabeledContent("地址",value:app.host)
                            LabeledContent("状态",value:app.online ? "已连接" : "未连接")
                            LabeledContent("服务",value:"Paper NAS v2")
                            Button("连接其他服务器…") {app.showConnection = true}
                            Button("断开当前设备",role:.destructive) {Task {await app.disconnect()}}
                        }
                        Section("本机缓存") {
                            LabeledContent("PDF 缓存",value:ByteCountFormatter.string(fromByteCount:Int64(cacheBytes),countStyle:.file))
                            Text("证据始终指向保存时的 PDF 版本。清理本机缓存不会删除服务器记录。").font(.caption).foregroundStyle(.secondary)
                            Button("清理缓存") {Task {await FileCache.shared.clear();cacheBytes = await FileCache.shared.size()}}
                        }
                    } else if pane == "model" {
                        Section("模型连接") {
                            TextField("API 地址",text:modelText("base_url"),prompt:Text("https://provider.example/v1"))
                            TextField("模型名称",text:modelText("model"))
                            Text("支持兼容 OpenAI Chat Completions 的接口。生成分析或比较时，会向此服务发送所选论文的正文片段与当前研究问题。").font(.caption).foregroundStyle(.secondary)
                            SecureField(keyConfigured ? "密钥已配置 · 输入以替换" : "API 密钥",text:$apiKey)
                            Button("保存密钥") {Task {await saveKey()}}.disabled(apiKey.isEmpty || busy)
                        }
                        Section("生成限制") {
                            Stepper("每次输出最多 \(max(512,model["max_output_tokens"].int)) tokens",value:Binding(get:{max(512,model["max_output_tokens"].int)},set:{model["max_output_tokens"] = .integer($0)}),in:512...12000,step:512)
                            Text("分析任务会预留 token 预算，并保留原始响应。未确认结果的调用需在任务页核对后处理。").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if pane == "discovery" {
                        Section("关注范围") {
                            TextField("检索式",text:discoveryText("query"),axis:.vertical).lineLimit(2...5)
                            Text("可输入英文关键词或 arXiv 检索式，例如 cat:cs.RO AND all:manipulation。").font(.caption).foregroundStyle(.secondary)
                            Toggle("arXiv",isOn:source("arxiv"));Toggle("Crossref",isOn:source("crossref"))
                            TextField("arXiv 专用检索式（可选）",text:sourceQuery("arxiv"),axis:.vertical).lineLimit(1...3)
                            TextField("Crossref 专用关键词（可选）",text:sourceQuery("crossref"),axis:.vertical).lineLimit(1...3)
                            Text("填写后用于对应来源；留空时使用上方检索式。").font(.caption).foregroundStyle(.secondary)
                            Stepper("每个来源最多 \(max(1,discovery["limit"].int)) 篇",value:Binding(get:{max(1,discovery["limit"].int)},set:{discovery["limit"] = .integer($0)}),in:1...100)
                        }
                        Section("定时获取候选") {
                            Toggle("每天获取",isOn:Binding(get:{discovery["enabled"].flag},set:{discovery["enabled"] = .bool($0)}))
                            TextField("执行时间（HH:mm）",text:discoveryText("time"))
                            TextField("时区",text:discoveryText("timezone"))
                            Text("服务器按来源分别获取，结果进入待选池。任务页显示实际获取范围与失败项；精读和比较由你选择材料后发起。").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Section("已连接设备") {
                            ForEach(devices,id:\.["id"].text) {device in
                                HStack {Text(device["name"].text);Spacer();if device["id"].text == app.credentials?.deviceID {Text("本机").foregroundStyle(.secondary)}
                                    else {Button("撤销",role:.destructive) {Task {await app.perform("devices/\(device["id"].text)",method:"DELETE");await load()}}}}
                            }
                        }
                    }
                }.formStyle(.grouped)
                Divider()
                HStack {
                    if let status {Text(status).font(.caption).foregroundStyle(.secondary)}
                    Spacer();if busy {ProgressView().controlSize(.small)}
                    Button("重新载入") {Task {await load()}}.disabled(busy)
                    if pane == "model" || pane == "discovery" {Button("保存设置") {Task {await save()}}.keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(busy)}
                }.padding(18)
            }
        }.frame(width:850,height:660).task {await load()}
    }
    private func modelText(_ field:String)->Binding<String> {Binding(get:{model[field].text},set:{model[field] = .string($0);status = nil})}
    private func discoveryText(_ field:String)->Binding<String> {Binding(get:{discovery[field].text},set:{discovery[field] = .string($0);status = nil})}
    private func sourceQuery(_ field:String)->Binding<String> {Binding(get:{discovery["source_queries"][field].text},set:{value in var queries = discovery["source_queries"];if case .null = queries {queries = .object([:])};queries[field] = .string(value);discovery["source_queries"] = queries;status = nil})}
    private func source(_ value:String)->Binding<Bool> {Binding(get:{discovery["sources"].values.contains(.string(value))},set:{on in var values = discovery["sources"].values.filter{$0 != .string(value)};if on {values.append(.string(value))};discovery["sources"] = .array(values)})}
    private func load() async {
        busy = true;defer {busy = false}
        do {
            async let m = app.request("settings/model");async let d = app.request("settings/discovery");async let v = app.request("devices")
            let (mr,dr,vr) = try await (m,d,v)
            model = mr["config"];modelRevision = mr["revision"].int;keyConfigured = mr["key_configured"].flag
            if model["max_output_tokens"].isNull {model["max_output_tokens"] = .integer(4000)}
            discovery = dr["config"];discoveryRevision = dr["revision"].int;devices = vr["devices"].values
            cacheBytes = await FileCache.shared.size();error = nil
        } catch {self.error = error.localizedDescription}
    }
    private func save() async {
        busy = true;defer {busy = false}
        var body = pane == "model" ? model : discovery
        body["revision"] = .integer(pane == "model" ? modelRevision : discoveryRevision)
        do {_ = try await app.request("settings/" + (pane == "model" ? "model" : "discovery"),method:"PUT",body:body);await load();status = "已保存，下次任务生效"}
        catch {self.error = error.localizedDescription}
    }
    private func saveKey() async {
        busy = true;defer {busy = false}
        do {_ = try await app.request("settings/model/key",method:"PUT",body:.object(["api_key":.string(apiKey)]));apiKey = "";keyConfigured = true;status = "密钥已保存";error = nil}
        catch {self.error = error.localizedDescription}
    }
}
