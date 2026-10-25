import SwiftUI

extension JSON {
    func at(_ path:[String])->JSON {path.reduce(self){$0[$1]}}
    mutating func set(_ path:[String],_ value:JSON) {
        guard let first = path.first else {self = value;return}
        var child = self[first];child.set(Array(path.dropFirst()),value);self[first] = child
    }
}

struct PreferencesView:View {
    @EnvironmentObject var app:AppModel
    @AppStorage("appearance") private var appearance = "system"
    @ViewState private var pane = "general"
    @ViewState private var config:JSON = .null
    @ViewState private var original:JSON = .null
    @ViewState private var revision = ""
    @ViewState private var skills:JSON = .null
    @ViewState private var devices:[JSON] = []
    @ViewState private var error:String?
    @ViewState private var busy = false
    @ViewState private var apiKey = ""
    @ViewState private var keyConfigured = false
    @ViewState private var cacheBytes = 0
    @ViewState private var status:String?
    @ViewState private var revoke:JSON?
    @ViewState private var arrayInputs:[String:String] = [:]
    @ViewState private var index:JSON = .null
    var body:some View {
        HStack(spacing:0) {
            List(selection:$pane) {
                Label("通用",systemImage:"gearshape").tag("general")
                Label("研究兴趣",systemImage:"person.crop.circle").tag("interests")
                Label("论文来源",systemImage:"network").tag("sources")
                Label("发现与计划",systemImage:"calendar").tag("discovery")
                Label("模型",systemImage:"sparkles").tag("model")
                Label("阅读规范",systemImage:"text.book.closed").tag("plan")
                Label("设备",systemImage:"laptopcomputer").tag("devices")
            }.listStyle(.sidebar).frame(width:170)
            Divider()
            VStack(spacing:0) {
                if let error {InlineError(message:error).padding(16)}
                Form {
                    if pane == "general" {general}
                    else if pane == "devices" {deviceSettings}
                    else if config.isNull {Section {Text("连接服务器后可编辑设置").foregroundStyle(.secondary)}}
                    else if pane == "interests" {interests}
                    else if pane == "sources" {sourceSettings}
                    else if pane == "discovery" {discovery}
                    else if pane == "model" {modelSettings}
                    else if pane == "plan" {planSettings}
                }.formStyle(.grouped)
                Divider()
                HStack {
                    if let status {Text(status).font(.caption).foregroundStyle(.secondary)}
                    Spacer()
                    if busy {ProgressView().controlSize(.small)}
                    Button("重新载入") {Task {await load()}}.disabled(busy)
                    Button("保存") {Task {await save()}}.buttonStyle(.borderedProminent).keyboardShortcut("s")
                        .disabled(busy || config == original || config.isNull)
                }.padding(16)
            }
        }.frame(width:850,height:660).task {await load()}
            .alert("撤销此设备的连接？",isPresented:Binding(get:{revoke != nil},set:{if !$0 {revoke = nil}})) {
                Button("取消",role:.cancel) {revoke = nil}
                Button("撤销",role:.destructive) {if let d = revoke {Task {await app.perform("devices/\(d["id"].text)",method:"DELETE");await loadDevices()}};revoke = nil}
            } message:{Text("该设备需要重新输入访问密钥才能连接。")}
    }
    private var general:some View {
        Group {
            Section("外观") {
                Picker("主题",selection:$appearance) {Text("跟随系统").tag("system");Text("浅色").tag("light");Text("深色").tag("dark")}
            }
            Section("服务器") {
                LabeledContent("地址",value:app.host)
                LabeledContent("状态",value:app.online ? "已连接" : "未连接")
                Button("连接服务器…") {app.showConnection = true}
                if app.credentials != nil {Button("断开当前设备",role:.destructive) {Task {await app.disconnect()}}}
            }
            Section("临时文件") {
                LabeledContent("本机 PDF 缓存",value:ByteCountFormatter.string(fromByteCount:Int64(cacheBytes),countStyle:.file))
                Text("论文、笔记和处理结果保存在服务器。本机按需缓存已打开的 PDF，默认上限 512 MB；单篇超大 PDF 可能暂时超过此值。").font(.caption).foregroundStyle(.secondary)
                Button("清理缓存") {Task {await FileCache.shared.clear();cacheBytes = await FileCache.shared.size();status = "缓存已清理"}}
            }
            if !index.isNull {
                Section("服务器搜索") {
                    LabeledContent("已建立索引",value:"\(index["indexed"].int) 篇")
                    LabeledContent("待处理",value:"\(index["pending"].int) 篇")
                    if !index["error"].text.isEmpty {Text(index["error"].text).font(.caption).foregroundStyle(.orange)}
                    Button("刷新搜索索引",systemImage:"arrow.clockwise") {Task {
                        do {index = try await app.request("local-index",method:"POST",body:.object([:]));status = "服务器正在刷新索引"}
                        catch {self.error = error.localizedDescription}
                    }}
                }
            }
            Section {LabeledContent("Paper NAS",value:"\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版") · macOS")}
        }
    }
    private var interests:some View {
        Section("研究兴趣") {
            Text("用于服务器筛选论文和生成个性化解读。").font(.caption).foregroundStyle(.secondary)
            TextEditor(text:string(["interests"])).frame(minHeight:360).font(.body).accessibilityLabel("研究兴趣")
        }
    }
    private var sourceSettings:some View {
        Group {
            ForEach(Array(config["sources"].values.enumerated()),id:\.offset) {index,source in
                Section(source["name"].text.isEmpty ? "论文来源" : source["name"].text) {
                    Toggle("启用",isOn:sourceBool(index,"enabled"))
                    TextField("名称",text:sourceString(index,"name"))
                    Picker("类型",selection:sourceString(index,"type")) {ForEach(["arxiv","crossref","openreview","pmlr","rss_proceedings"],id:\.self){Text($0).tag($0)}}
                    TextField("检索式",text:sourceString(index,"query"))
                    TextField("分类（逗号分隔）",text:sourceArray(index,"categories"))
                    TextField("ISSN（逗号分隔）",text:sourceArray(index,"issns"))
                    TextField("会议标识",text:sourceString(index,"venue_id"))
                    TextField("来源网址",text:sourceString(index,"url"))
                    TextField("API 网址",text:sourceString(index,"api_url"))
                    TextField("最大结果数",text:sourceNumber(index,"max_results"))
                    TextField("分页大小",text:sourceNumber(index,"page_size"))
                    Button("移除来源",role:.destructive) {var a = config["sources"].values;a.remove(at:index);config["sources"] = .array(a)}
                }
            }
            Section {
                Button("添加来源",systemImage:"plus") {
                    var a = config["sources"].values;a.append(.object(["name":.string("新来源"),"type":.string("arxiv"),"enabled":.bool(false),"query":.string(""),"categories":.array([]),"issns":.array([]),"venue_id":.string(""),"url":.string(""),"api_url":.string(""),"max_results":.integer(100),"page_size":.integer(100)]));config["sources"] = .array(a)
                }
            }
        }
    }
    private var discovery:some View {
        Group {
            Section("发现") {
                numeric("回溯天数",["discovery","lookback_days"])
                TextField("包含词（逗号分隔）",text:array(["discovery","include_terms"]))
                TextField("排除词（逗号分隔）",text:array(["discovery","exclude_terms"]))
                numeric("最大论文数 · 留空不限",["discovery","max_papers"],nullable:true)
                numeric("请求间隔（秒）",["discovery","request_delay"])
                numeric("请求超时（秒）",["discovery","timeout_seconds"])
                numeric("PDF 上限（MB）· 留空不限",["discovery","max_download_mb"],nullable:true)
            }
            Section("自动筛选") {
                Toggle("每天运行",isOn:boolean(["daily","enabled"]))
                TextField("执行时间（HH:mm）",text:string(["daily","time"]))
                TextField("时区",text:string(["daily","timezone"]))
                numeric("候选上限",["daily","candidate_limit"])
                numeric("初读数量",["daily","selected_count"])
                numeric("精读数量",["daily","deep_count"])
                numeric("最低分数",["daily","min_score"])
            }
            Section("服务器下载") {
                numeric("并发数量（1–4）",["downloads","concurrency"])
                numeric("低速阈值（KB/s）",["downloads","low_speed_kbps"])
                numeric("低速检测时间（秒）",["downloads","low_speed_seconds"])
                numeric("重连次数",["downloads","max_reconnects"])
                numeric("重试次数",["downloads","retries"])
            }
        }
    }
    private var modelSettings:some View {
        Group {
            Section("模型连接") {
                TextField("API 地址",text:string(["analysis","base_url"]))
                TextField("模型名称",text:string(["analysis","model"]))
                SecureField(keyConfigured ? "已配置密钥 · 输入以替换" : "API 密钥",text:$apiKey)
                Button("保存密钥") {Task {await saveKey()}}.disabled(apiKey.isEmpty || busy)
                Button("测试已保存的连接",systemImage:"network") {Task {do {_ = try await app.job("test_api");status = "测试任务已提交，可在任务页查看"} catch {self.error = error.localizedDescription}}}
            }
            Section("分析") {
                TextField("输出语言",text:string(["analysis","language"]))
                Picker("PDF 解析器",selection:string(["analysis","parser"])) {Text("pypdf").tag("pypdf");Text("Docling").tag("docling")}
                Picker("响应格式",selection:string(["analysis","response_format"])) {Text("JSON 对象").tag("json_object");Text("JSON Schema").tag("json_schema");Text("不指定格式").tag("none")}
                numeric("请求超时（秒）",["analysis","timeout_seconds"])
                numeric("重试次数",["analysis","retries"])
                numeric("每段字符数",["analysis","chunk_chars"])
                numeric("最大分段数 · 留空不限",["analysis","max_chunks"],nullable:true)
                numeric("输出 token 上限 · 留空不限",["analysis","max_output_tokens"],nullable:true)
                numeric("提示词字符上限 · 留空不限",["analysis","max_prompt_chars"],nullable:true)
                numeric("每次运行请求上限 · 留空不限",["analysis","max_requests_per_run"],nullable:true)
            }
        }
    }
    private var planSettings:some View {
        Group {
            Section("解读栏目") {
                ForEach(Array(skills["sections"].values.enumerated()),id:\.offset) {_,s in Toggle(s["name"].text,isOn:contains(["analysis","plan","sections"],s["id"].text))}
            }
            Section("阅读规范") {
                ForEach(Array(skills["skills"].values.enumerated()),id:\.offset) {_,s in
                    DisclosureGroup {
                        Text(s["description"].text).font(.caption).foregroundStyle(.secondary)
                        ScrollView {Text(s["content"].text).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}.frame(maxHeight:200)
                    } label:{Toggle(s["name"].text,isOn:contains(["analysis","plan","skills"],s["id"].text)).disabled(s["kind"].text == "required")}
                }
                Toggle("修订待修改结论并再次核对",isOn:boolean(["analysis","revise_after_check"]))
            }
            Section("补充问题与要求") {
                TextField("问题（每行一条）",text:array(["analysis","plan","questions"],separator:"\n"),axis:.vertical).lineLimit(3...8)
                TextEditor(text:string(["analysis","plan","instructions"])).frame(minHeight:100).accessibilityLabel("补充阅读要求")
            }
        }
    }
    private var deviceSettings:some View {
        Section("已连接设备") {
            ForEach(Array(devices.enumerated()),id:\.offset) {_,d in
                HStack {
                    Label(d["name"].text,systemImage:"laptopcomputer")
                    Spacer()
                    if d["id"].text == app.credentials?.deviceID {Text("本机").font(.caption).foregroundStyle(.secondary)}
                    else {IconButton(title:"撤销连接",symbol:"xmark.circle",role:.destructive) {revoke = d}.buttonStyle(.borderless)}
                }
            }
        }
    }
    private func string(_ path:[String])->Binding<String> {Binding(get:{config.at(path).text},set:{config.set(path,.string($0));status = nil})}
    private func boolean(_ path:[String])->Binding<Bool> {Binding(get:{config.at(path).flag},set:{config.set(path,.bool($0));status = nil})}
    private func array(_ path:[String],separator:String = ", ")->Binding<String> {Binding(get:{arrayInputs[path.joined(separator:".")] ?? config.at(path).values.map(\.text).joined(separator:separator)},set:{arrayInputs[path.joined(separator:".")] = $0;config.set(path,.strings($0.components(separatedBy:separator == "\n" ? .newlines : CharacterSet(charactersIn:",，")).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}));status = nil})}
    private func contains(_ path:[String],_ id:String)->Binding<Bool> {Binding(get:{config.at(path).values.contains(.string(id))},set:{on in var v = config.at(path).values.filter{$0 != .string(id)};if on {v.append(.string(id))};config.set(path,.array(v));status = nil})}
    private func numeric(_ title:String,_ path:[String],nullable:Bool = false)->some View {
        TextField(title,text:Binding(get:{let v = config.at(path);if v.isNull {return ""};if case .number(let n) = v {return n.rounded() == n ? String(Int(n)) : String(n)};return v.text},set:{v in config.set(path,v.isEmpty && nullable ? .null : Double(v).map(JSON.number) ?? .string(v));status = nil}))
    }
    private func sourceBinding(_ i:Int,_ field:String)->Binding<JSON> {Binding(get:{let a = config["sources"].values;return a.indices.contains(i) ? a[i][field] : .null},set:{v in var a = config["sources"].values;guard a.indices.contains(i) else {return};a[i][field] = v;config["sources"] = .array(a);status = nil})}
    private func sourceString(_ i:Int,_ f:String)->Binding<String> {let b = sourceBinding(i,f);return Binding(get:{b.wrappedValue.text},set:{b.wrappedValue = .string($0)})}
    private func sourceBool(_ i:Int,_ f:String)->Binding<Bool> {let b = sourceBinding(i,f);return Binding(get:{b.wrappedValue.flag},set:{b.wrappedValue = .bool($0)})}
    private func sourceNumber(_ i:Int,_ f:String)->Binding<String> {let b = sourceBinding(i,f);return Binding(get:{b.wrappedValue.text.isEmpty ? String(b.wrappedValue.int) : b.wrappedValue.text},set:{b.wrappedValue = Double($0).map(JSON.number) ?? .string($0)})}
    private func sourceArray(_ i:Int,_ f:String)->Binding<String> {let b = sourceBinding(i,f);let key = "sources.\(i).\(f)";return Binding(get:{arrayInputs[key] ?? b.wrappedValue.values.map(\.text).joined(separator:", ")},set:{arrayInputs[key] = $0;b.wrappedValue = .strings($0.components(separatedBy:CharacterSet(charactersIn:",，")).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty})})}
    private func load() async {
        cacheBytes = await FileCache.shared.size();guard app.api != nil else {return};busy = true;defer {busy = false}
        do {async let c = app.request("config");async let s = app.request("skills");let (v,sk) = try await(c,s);config = v["config"];original = config;revision = v["revision"].text;keyConfigured = v["key_configured"].flag;skills = sk;arrayInputs = [:];error = nil;status = nil;await loadDevices()}
        catch {self.error = error.localizedDescription}
    }
    private func loadDevices() async {
        if let v = try? await app.request("devices") {devices = v["devices"].values}
        if let v = try? await app.request("local-index") {index = v}
    }
    private func save() async {
        busy = true;defer {busy = false}
        do {let v = try await app.request("config",method:"PUT",body:.object(["config":config,"revision":.string(revision)]));config = v["config"];original = config;revision = v["revision"].text;error = nil;status = "已保存，下次任务生效";await app.refresh()}
        catch {self.error = (error as? ServerError)?.status == 409 ? "服务器配置已变化或有任务正在运行。当前修改已保留，请待任务完成或核对新配置后保存。" : error.localizedDescription}
    }
    private func saveKey() async {
        busy = true;defer {busy = false}
        do {_ = try await app.request("key",method:"PUT",body:.object(["api_key":.string(apiKey)]));apiKey = "";keyConfigured = true;status = "密钥已保存在服务器";error = nil}
        catch {self.error = error.localizedDescription}
    }
}
