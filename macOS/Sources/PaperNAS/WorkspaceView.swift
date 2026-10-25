import SwiftUI
import AppKit

@MainActor final class LibrarySearchController:ObservableObject {
    @Published var request = 0
    var handled = 0
    func focus() {request += 1}
}
struct LibrarySearchKey:FocusedValueKey {typealias Value = LibrarySearchController}
extension FocusedValues {var librarySearch:LibrarySearchController? {get {self[LibrarySearchKey.self]} set {self[LibrarySearchKey.self] = newValue}}}

struct WorkspaceView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var library = LibraryModel()
    @ViewState private var shelf: Shelf? = .library
    @ViewState private var navigation = LibraryNavigation()
    @FocusState private var libraryFocused:Bool
    @StateObject private var search = LibrarySearchController()
    @ViewState private var filterVisible = false
    @ViewState private var newGroup = false
    @ViewState private var groupName = ""
    @ViewState private var groupToRename:PaperGroup?
    @ViewState private var batchGrouping = false
    @ViewState private var paperToDelete: Paper?
    @ViewState private var groupToDelete: PaperGroup?
    @ViewState private var assigning: Paper?
    @AppStorage("libraryLayout") private var layout = "list"
    private var current: Shelf { shelf ?? .library }
    private var title: String { if case .group(let id) = current { return app.groups.first{$0.id == id}?.name ?? "分组" }; return current.title }

    var body: some View {
        Group {
            if let key = navigation.reader {
                ReaderView(key:key).id(key)
                    .navigationTitle("阅读")
                    .toolbar {
                        ToolbarItem(placement:.navigation) {
                            IconButton(title:"返回" + title,symbol:"chevron.left") { navigation.reader = nil }
                                .keyboardShortcut("[",modifiers:.command)
                        }
                    }
            } else {
                NavigationSplitView {
                    sidebar.navigationSplitViewColumnWidth(min:175,ideal:205,max:260)
                } detail: {
                    Group {
                        if current == .tasks {if app.isV2 {ResearchTasksView()} else {TasksView()}}
                        else if current == .research {ResearchSpaceView {key in navigation.open(key)}}
                        else { libraryPane }
                    }
                    .navigationTitle(title)
                    .toolbar { toolbar }
                }
            }
        }
        .frame(minWidth:850,minHeight:580)
        .sheet(isPresented:$app.showConnection) { ConnectionView().environmentObject(app) }
        .sheet(isPresented:$app.showAdd) { AddPaperView().environmentObject(app) }
        .sheet(item:$assigning) { paper in GroupAssignmentView(paper:paper).environmentObject(app) }
        .sheet(isPresented:$batchGrouping) {BatchGroupAssignmentView(papers:library.papers.filter{navigation.selection.contains($0.id)}).environmentObject(app)}
        .alert(groupToRename == nil ? "新建分组" : "重命名分组",isPresented:$newGroup) {
            TextField("分组名称",text:$groupName)
            Button("取消",role:.cancel) { groupName = "";groupToRename = nil }
            Button(groupToRename == nil ? "创建" : "保存") {
                let group = groupToRename;var body:JSON = .object(["name":.string(groupName)])
                if let group {body["revision"] = .integer(group.revision)}
                Task { await app.perform(group.map{"groups/\($0.id)"} ?? "groups",method:group == nil ? "POST" : "PATCH",body:body) }
                groupName = "";groupToRename = nil
            }.disabled(groupName.trimmingCharacters(in:.whitespaces).isEmpty)
        }
        .alert("删除论文？",isPresented:Binding(get:{paperToDelete != nil},set:{if !$0 { paperToDelete = nil }})) {
            Button("取消",role:.cancel) { paperToDelete = nil }
            Button("删除",role:.destructive) {
                if let paper = paperToDelete { Task { await app.perform("papers/\(paper.id)",method:"DELETE",message:"论文已删除"); if navigation.reader == paper.id { navigation.reader = nil }; navigation.selection.remove(paper.id) } }
                paperToDelete = nil
            }
        } message: { Text(app.isV2 ? "将从文献库移除此论文；已有研究证据和引用仍会保留。" : "将从服务器删除这篇论文及其文件、报告和笔记，所有设备都会同步。") }
        .alert("删除分组？",isPresented:Binding(get:{groupToDelete != nil},set:{if !$0 { groupToDelete = nil }})) {
            Button("取消",role:.cancel) { groupToDelete = nil }
            Button("删除",role:.destructive) {
                if let group = groupToDelete { Task { await app.perform("groups/\(group.id)",method:"DELETE"); shelf = .library } }
                groupToDelete = nil
            }
        } message: { Text("分组中的论文会保留在论文库。") }
        .alert("未能完成操作",isPresented:Binding(get:{app.error != nil},set:{if !$0 { app.error = nil }})) {
            Button("好",role:.cancel) { app.error = nil }
        } message: { Text(app.error ?? "") }
        .overlay(alignment:.bottom) {
            if let toast = app.toast {
                Label(toast,systemImage:"checkmark.circle.fill").font(.callout).padding(.horizontal,16).padding(.vertical,11)
                    .background(.regularMaterial,in:Capsule()).shadow(color:.black.opacity(0.08),radius:12,y:4).padding(22).allowsHitTesting(false)
            }
        }
        .task(id:current) { navigation = LibraryNavigation(); library.similar = ""; await load(reset:true) }
        .task(id:library.query) { try? await Task.sleep(for:.milliseconds(280)); guard !Task.isCancelled else { return }; await load(reset:true) }
        .onChange(of:app.change) { _,_ in Task { await load() } }
        .onChange(of:search.request) { _,_ in navigation.reader = nil }
        .focusedSceneValue(\.librarySearch,search)
    }
    private var sidebar: some View {
        VStack(spacing:0) {
            List(selection:$shelf) {
                Section {
                    shelfRow(.library,count:app.counts["library"])
                    shelfRow(.candidates,count:app.counts["candidates"])
                    if app.supportsResearch {shelfRow(.research,count:nil)}
                    shelfRow(.tasks,count:nil)
                }
                Section {
                    ForEach(app.groups) { group in
                        HStack {
                            Label(group.name,systemImage:"folder")
                            Spacer()
                            if group.count > 0 { Text("\(group.count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit() }
                        }.tag(Shelf.group(group.id))
                        .contextMenu {
                            Button("重命名",systemImage:"pencil") {groupToRename = group;groupName = group.name;newGroup = true}
                            Button("删除分组",systemImage:"trash",role:.destructive) { groupToDelete = group }
                        }
                    }
                } header: {
                    HStack {
                        Text("分组")
                        Spacer()
                        IconButton(title:"新建分组",symbol:"plus") { groupToRename = nil;newGroup = true }.buttonStyle(.plain)
                    }
                }
            }.listStyle(.sidebar)
            HStack(spacing:9) {
                Button { app.showConnection = true } label: {
                    HStack(spacing:7) {
                        Image(systemName:app.online ? "externaldrive.connected.to.line.below" : "externaldrive.badge.exclamationmark")
                            .foregroundStyle(app.online ? Color.secondary : Color.orange)
                        VStack(alignment:.leading,spacing:2) {
                            Text(app.restoringLogin ? "正在恢复登录" : app.online ? "服务器已连接" : "服务器未连接").font(.caption)
                            Text(app.host).font(.system(size:9)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }.buttonStyle(.plain).help("连接服务器").disabled(app.restoringLogin)
                Spacer(minLength:0)
                SettingsLink { Image(systemName:"gearshape") }.buttonStyle(.plain).help("设置").accessibilityLabel("设置")
            }.padding(14)
        }
    }
    private func shelfRow(_ value:Shelf,count:Int?) -> some View {
        HStack {
            Label(value.title,systemImage:value.icon)
            Spacer()
            if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }.tag(value)
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if current != .tasks && current != .research {
            ToolbarItem(placement:.automatic) {
                LibrarySearchField(text:$library.query,controller:search)
                    .frame(minWidth:160,idealWidth:210,maxWidth:240)
            }
            ToolbarItemGroup(placement:.primaryAction) {
                if navigation.selection.count > 1 {
                    Menu {
                        Text("已选择 \(navigation.selection.count) 篇")
                        Button("批量精读",systemImage:"sparkles") {batchJob("analyze_selected")}
                        Button("批量提取原文",systemImage:"doc.text.viewfinder") {batchJob("extract_selected")}
                        Button("添加到分组",systemImage:"folder") {batchGrouping = true}
                        if current == .candidates {Button("加入论文库",systemImage:"books.vertical") {approveSelection()}}
                        Divider();Button("取消选择") {navigation.selection = []}
                    } label:{Image(systemName:"checklist")}.help("批量操作").accessibilityLabel("批量操作")
                }
                IconButton(title:"筛选与排序",symbol:library.status.isEmpty && library.source.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") { filterVisible.toggle() }
                    .popover(isPresented:$filterVisible) { filters }
                Picker("显示方式",selection:$layout) {
                    Image(systemName:"list.bullet").tag("list").help("列表视图").accessibilityLabel("列表视图")
                    Image(systemName:"square.grid.2x2").tag("grid").help("图文视图").accessibilityLabel("图文视图")
                }.pickerStyle(.segmented).frame(width:78)
                IconButton(title:"添加论文",symbol:"plus") { app.showAdd = true }.disabled(app.api == nil)
            }
        }
    }
    private var filters: some View {
        Form {
            Picker("排序",selection:$library.sort) {
                Text("最新发表").tag("published_desc"); Text("最早发表").tag("published_asc")
                Text("最近加入").tag("added_desc"); Text("最早加入").tag("added_asc")
                Text("标题 A–Z").tag("title")
                if !app.isV2 {Text("检索相关度").tag("relevance"); Text("推荐得分").tag("recommended")}
            }
            Picker("状态",selection:$library.status) { Text("全部").tag(""); Text("精读").tag("analyzed"); if !app.isV2 {Text("初读").tag("brief")}; Text("需要处理").tag("attention"); Text("已提取").tag("extracted") }
            Picker("来源",selection:$library.source) { Text("全部").tag(""); Text("arXiv").tag("arxiv"); Text("期刊").tag("crossref"); if !app.isV2 {Text("OpenReview").tag("openreview"); Text("PMLR").tag("pmlr")}; Text("本地材料").tag("local") }
            if !app.isV2 {Picker("检索",selection:$library.mode) { Text("关键词").tag("keyword"); Text("智能检索").tag("hybrid"); Text("语义检索").tag("semantic") }}
            HStack {
                Button("重置") { library.status = ""; library.source = ""; library.sort = "published_desc"; library.mode = "keyword"; library.similar = "" }
                Spacer()
                Button("应用") { filterVisible = false; Task { await load(reset:true) } }.keyboardShortcut(.defaultAction)
            }
        }.formStyle(.grouped).padding(4).frame(width:300,height:270)
    }
    private var libraryPane: some View {
        VStack(spacing:0) {
            HStack {
                Text(app.restoringLogin ? "正在恢复连接" : library.loading && library.papers.isEmpty ? "正在载入论文" : "\(library.total) 篇")
                    .font(.callout).foregroundStyle(.secondary)
                if !library.similar.isEmpty {
                    Button { library.similar = ""; Task { await load(reset:true) } } label: { Label("相似论文",systemImage:"xmark.circle.fill") }.buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                }
                Spacer()
                if library.loading { ProgressView().controlSize(.small) }
            }.padding(.horizontal,20).padding(.vertical,10)
            if let error = library.error { InlineError(message:error,retry:{Task { await load() }}).padding(.horizontal,16).padding(.bottom,8) }
            if app.restoringLogin {
                VStack(spacing:14) {
                    ProgressView()
                    Text("正在恢复服务器连接").font(.callout)
                    Text("如果 macOS 询问，请允许 Paper NAS 访问已保存的登录。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if library.papers.isEmpty && !library.loading {
                EmptyState(symbol:library.query.isEmpty ? "books.vertical" : "magnifyingglass",title:app.api == nil ? "连接你的论文库" : "暂无论文",detail:app.api == nil ? "文件集中保存在服务器，随时从这里开始阅读。" : "添加论文，或调整搜索与筛选条件。")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        if layout == "grid" {
                            LazyVGrid(columns:[GridItem(.adaptive(minimum:280,maximum:440),spacing:20)],alignment:.leading,spacing:20) {
                                ForEach(library.papers) { paper in paperButton(paper,grid:true).id(paper.id) }
                            }.padding(20)
                        } else {
                            LazyVStack(spacing:6) {
                                ForEach(library.papers) { paper in paperButton(paper,grid:false).id(paper.id) }
                            }.padding(.horizontal,16).padding(.bottom,16)
                        }
                    }
                    .focusable().focused($libraryFocused).focusEffectDisabled()
                    .onKeyPress(.downArrow) { moveSelection(1,extend:NSEvent.modifierFlags.contains(.shift)); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1,extend:NSEvent.modifierFlags.contains(.shift)); return .handled }
                    .onKeyPress(.return) { if let id = navigation.cursor {navigation.open(id)};return .handled }
                    .onChange(of:navigation.cursor) { _,id in if let id {proxy.scrollTo(id)} }
                    .onAppear {
                        if let id = navigation.cursor {proxy.scrollTo(id);libraryFocused = true}
                    }
                }
            }
            if library.total > 40 {
                Divider()
                HStack {
                    IconButton(title:"上一页",symbol:"chevron.left") { library.page -= 1; Task { await load() } }.disabled(library.page == 0)
                    Spacer(); Text("\(library.page+1) / \(max(1,(library.total+39)/40))").font(.caption).monospacedDigit().foregroundStyle(.secondary); Spacer()
                    IconButton(title:"下一页",symbol:"chevron.right") { library.page += 1; Task { await load() } }.disabled((library.page+1)*40 >= library.total)
                }.buttonStyle(.plain).padding(.horizontal,22).padding(.vertical,9)
            }
        }.background(Color(nsColor:.controlBackgroundColor))
    }
    private func paperButton(_ paper:Paper,grid:Bool)->some View {
        Button {
            let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            navigation.click(paper.id,ordered:library.papers.map(\.id),command:flags.contains(.command),shift:flags.contains(.shift))
            if navigation.reader == nil {libraryFocused = true}
        } label: {
            Group {
                if grid {PaperCard(paper:paper)}
                else {PaperRow(paper:paper).padding(.horizontal,14).padding(.vertical,12)}
            }.frame(maxWidth:.infinity,alignment:.leading).contentShape(RoundedRectangle(cornerRadius:10))
        }
        .buttonStyle(PaperItemStyle(selected:navigation.selection.contains(paper.id),grid:grid))
        .contextMenu {paperMenu(paper)}
        .accessibilityLabel(paper.title)
        .accessibilityValue([navigation.selection.contains(paper.id) ? "已选择" : "",paper.collection == "candidates" ? paper.relevanceLabel : ""].filter{!$0.isEmpty}.joined(separator:"，"))
        .accessibilityAction(named:"选择或取消选择") {
            navigation.click(paper.id,ordered:library.papers.map(\.id),command:true)
            libraryFocused = true
        }
        .accessibilityHint("打开阅读；按住 Command 或 Shift 可选择多篇")
    }
    private func moveSelection(_ delta:Int,extend:Bool) {
        navigation.move(delta,ordered:library.papers.map(\.id),extend:extend)
    }
    @ViewBuilder private func paperMenu(_ paper:Paper) -> some View {
        Button("阅读",systemImage:"book") { navigation.open(paper.id) }
        Button("在新窗口打开",systemImage:"macwindow") { openWindow(id:"paper",value:paper.id) }
        Divider()
        if paper.collection == "candidates" {
            Button("加入论文库",systemImage:"books.vertical") { Task { await app.perform("papers/\(paper.id)",method:"PATCH",body:.object(["collection":.string("library"),"revision":.integer(paper.revision)]),message:"已加入论文库") } }
        }
        Button("整理分组",systemImage:"folder") { assigning = paper }
        if !app.isV2 {Button("相似论文",systemImage:"sparkle.magnifyingglass") { library.similar = paper.id; library.sort = "relevance"; Task { await load(reset:true) } }}
        Divider()
        if !app.isV2 {Button("初读",systemImage:"text.alignleft") { run("brief_paper",paper:paper) }}
        Button("精读",systemImage:"sparkles") { run("analyze_paper",paper:paper) }
        if !app.isV2 {Button("更新一句话总结",systemImage:"text.bubble") { run("summarize_paper",paper:paper) }}
        Divider()
        if let url = paper.sourceURL { Link(destination:url) { Label("打开论文来源",systemImage:"arrow.up.right.square") } }
        Button("删除论文",systemImage:"trash",role:.destructive) { paperToDelete = paper }
    }
    private func run(_ action:String,paper:Paper) { Task { do { _ = try await app.job(action,key:paper.id) } catch { app.handle(error) } } }
    private func batchJob(_ action:String) {let keys = navigation.selection.sorted();Task {do {_ = try await app.job(action,keys:keys)} catch {app.handle(error)}}}
    private func approveSelection() {
        let papers = library.papers.filter{navigation.selection.contains($0.id)}
        Task {do {
            for p in papers {_ = try await app.request("papers/\(p.id)",method:"PATCH",body:.object(["revision":.integer(p.revision),"collection":.string("library")]))}
            app.change += 1;navigation.selection = [];app.notify("已加入论文库")
        } catch {app.change += 1;app.handle(error)}}
    }
    private func load(reset:Bool = false) async { if current != .tasks && current != .research { await library.load(app:app,shelf:current,reset:reset) } }
}

struct BatchGroupAssignmentView:View {
    @EnvironmentObject var app:AppModel
    @Environment(\.dismiss) var dismiss
    let papers:[Paper]
    @ViewState private var selected:Set<String> = []
    @ViewState private var error:String?
    @ViewState private var busy = false
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("添加到分组").font(.title2.weight(.semibold))
            Text("为 \(papers.count) 篇论文添加分组，保留各自已有分组。").font(.callout).foregroundStyle(.secondary)
            ForEach(app.groups) {g in Toggle(g.name,isOn:Binding(get:{selected.contains(g.id)},set:{if $0 {selected.insert(g.id)} else {selected.remove(g.id)}}))}
            if let error {InlineError(message:error)}
            HStack {Button("取消") {dismiss()}.disabled(busy);Spacer();Button("保存") {Task {await save()}}.buttonStyle(.borderedProminent).disabled(busy || selected.isEmpty)}
        }.padding(26).frame(width:410)
    }
    private func save() async {
        busy = true;defer {busy = false};var completed = 0
        do {for p in papers {
            _ = try await app.request("papers/\(p.id)",method:"PATCH",body:.object(["revision":.integer(p.revision),"group_ids":.strings(Set(p.groupIDs).union(selected).sorted())]));completed += 1
        };app.change += 1;await app.refresh();dismiss()}
        catch {app.change += 1;self.error = "已更新 \(completed) 篇。\(error.localizedDescription) 请关闭后刷新再处理其余论文。"}
    }
}

struct PaperRow: View {
    let paper: Paper
    var compact = false
    var body: some View {
        HStack(alignment:.top,spacing:compact ? 13 : 22) {
            RemoteFigure(path:paper.coverPath).frame(width:compact ? 88 : 156,height:compact ? 72 : 114)
            VStack(alignment:.leading,spacing:compact ? 5 : 7) {
                HStack(spacing:8) {
                    if paper.collection == "candidates" { StateDot(paper:paper) }
                    Text(paper.date); Text(paper.venue)
                    if paper.collection == "candidates" {Spacer(minLength:8);CandidateRelevanceBadge(paper:paper)}
                }.font(.system(size:11)).foregroundStyle(.secondary)
                Text(paper.title).font(.system(size:compact ? 14 : 17,weight:.semibold)).lineLimit(compact ? 3 : 2).fixedSize(horizontal:false,vertical:true)
                if !paper.byline.isEmpty { Text(paper.byline).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(compact ? 2 : 1) }
                if !paper.summary.isEmpty { Text(paper.summary).font(.system(size:compact ? 12 : 13)).foregroundStyle(.secondary).lineSpacing(3).lineLimit(compact ? 3 : 3) }
                if !paper.groups.isEmpty { GroupChips(groups:paper.groups).padding(.top,2) }
            }
            Spacer(minLength:0)
        }.padding(.vertical,5).accessibilityElement(children:.combine)
    }
}

struct PaperItemStyle:ButtonStyle {
    var selected:Bool
    var grid:Bool
    func makeBody(configuration:Configuration)->some View {
        PaperItemSurface(content:configuration.label,selected:selected,pressed:configuration.isPressed,grid:grid)
    }
}

private struct CandidateRelevanceBadge:View {
    let paper:Paper
    var body:some View {
        Text(paper.relevanceLabel)
            .font(.system(size:11,weight:.medium)).monospacedDigit()
            .foregroundStyle(paper.relevanceScore == nil ? Color.secondary : Color.accentColor)
            .padding(.horizontal,8).padding(.vertical,4)
            .background(paper.relevanceScore == nil ? Color.primary.opacity(0.04) : Color.accentColor.opacity(0.09),in:Capsule())
            .fixedSize()
            .help(paper.relevanceReason.isEmpty ? "与研究兴趣的匹配评分" : paper.relevanceReason)
    }
}
private struct PaperItemSurface<Content:View>:View {
    var content:Content
    var selected:Bool
    var pressed:Bool
    var grid:Bool
    @ViewState private var hovered = false
    var body:some View {
        content
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(pressed ? 0.10 : hovered ? 0.055 : 0),in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(grid ? 0.08 : 0),lineWidth:1))
            .contentShape(RoundedRectangle(cornerRadius:10))
            .onHover {hovered = $0}
    }
}

struct PaperCard: View {
    let paper: Paper
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            RemoteFigure(path:paper.coverPath).frame(height:170)
            HStack(spacing:7) {
                if paper.collection == "candidates" {StateDot(paper:paper)}
                Text(paper.date);Text(paper.venue)
                if paper.collection == "candidates" {Spacer(minLength:4);CandidateRelevanceBadge(paper:paper)}
            }.font(.caption).foregroundStyle(.secondary)
            Text(paper.title).font(.system(size:15,weight:.semibold)).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading)
            if !paper.byline.isEmpty { Text(paper.byline).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Text(paper.summary).font(.callout).foregroundStyle(.secondary).lineSpacing(3).lineLimit(4)
            GroupChips(groups:paper.groups)
            Spacer(minLength:0)
        }.padding(12).frame(maxWidth:.infinity,minHeight:370,alignment:.topLeading)
            .accessibilityElement(children:.combine).accessibilityAddTraits(.isButton)
    }
}

struct GroupAssignmentView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let paper: Paper
    @ViewState private var selected: Set<String> = []
    @ViewState private var saving = false
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("整理分组").font(.title2.weight(.semibold))
            Text(paper.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            if app.groups.isEmpty { Text("请先在侧栏新建分组。").foregroundStyle(.secondary) }
            ForEach(app.groups) { group in
                Toggle(group.name,isOn:Binding(get:{selected.contains(group.id)},set:{if $0 { selected.insert(group.id) } else { selected.remove(group.id) }}))
            }
            if let error { InlineError(message:error) }
            HStack { Button("取消",role:.cancel) { dismiss() }; Spacer(); Button("保存") { save() }.buttonStyle(.borderedProminent).disabled(saving) }
        }.padding(26).frame(width:390).onAppear { selected = Set(paper.groupIDs) }
    }
    private func save() {
        saving = true
        Task {
            do { _ = try await app.request("papers/\(paper.id)",method:"PATCH",body:.object(["group_ids":.strings(selected.sorted()),"revision":.integer(paper.revision)])); app.change += 1; await app.refresh(); dismiss() }
            catch { self.error = error.localizedDescription; saving = false }
        }
    }
}
