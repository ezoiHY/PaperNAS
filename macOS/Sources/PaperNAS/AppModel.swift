import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var credentials: Credentials?
    @Published var groups: [PaperGroup] = []
    @Published var counts: [String:Int] = [:]
    @Published var online = false
    @Published var connecting = false
    @Published var restoringLogin = true
    @Published var error: String?
    @Published var change = 0
    @Published var overview: JSON = .null
    @Published var capabilities: JSON = .null
    @Published var showConnection = false
    @Published var showAdd = false
    @Published var toast: String?
    private(set) var api: APIClient?
    private var eventTask: Task<Void,Never>?
    private var refreshTask: Task<Void,Never>?
    private var cursor = 0
    private var toastTask: Task<Void,Never>?

    private var hasStarted = false
    private let loadCredentials:@Sendable () async throws -> Credentials?

    init(loadCredentials:@escaping @Sendable () async throws -> Credentials? = {
        try await Task.detached(priority:.userInitiated) {try CredentialVault.restore(arguments:CommandLine.arguments)}.value
    }) {
        self.loadCredentials = loadCredentials
    }
    var host: String { URL(string:credentials?.serverURL ?? "")?.host ?? "尚未连接" }
    var serverID: String { credentials?.serverID ?? "" }
    var isV2:Bool {(credentials?.apiVersion ?? 1) >= 2}
    var supportsResearch:Bool {isV2 && capabilities["features"]["research_space"].flag}
    func start() async {
        guard !hasStarted else {return}
        hasStarted = true
        // A Keychain prompt may wait for the user. Never block window creation or AppKit.
        do {
            credentials = try await loadCredentials()
            if let credentials {api = try APIClient(baseURL:credentials.serverURL,token:credentials.token,apiVersion:credentials.apiVersion ?? 1)}
        } catch {self.error = error.localizedDescription}
        restoringLogin = false
        guard api != nil else {showConnection = true;return}
        await refresh()
        startEvents()
        change += 1
    }
    func connect(address:String,key:String) async throws {
        connecting = true
        defer { connecting = false }
        let probe = try APIClient(baseURL:address)
        let version = try await probe.negotiatedVersion()
        let client = try APIClient(baseURL:address,apiVersion:version)
        let reply = try await client.request("auth/devices",method:"POST",body:.object([
            "access_key":.string(key.trimmingCharacters(in:.whitespacesAndNewlines)),
            "device_name":.string(Host.current().localizedName ?? "Mac")]))
        let saved = Credentials(serverURL:address.trimmingCharacters(in:CharacterSet(charactersIn:"/ ")),
                                token:reply["device"]["token"].text,deviceID:reply["device"]["id"].text,
                                serverID:reply["server_id"].text,apiVersion:version)
        try await Task.detached {try CredentialVault.save(saved)}.value
        eventTask?.cancel()
        credentials = saved
        api = try APIClient(baseURL:saved.serverURL,token:saved.token,apiVersion:version)
        cursor = reply["event_cursor"].int
        error = nil; showConnection = false
        await refresh(); startEvents(); change += 1
    }
    func disconnect() async {
        if let api, let id = credentials?.deviceID { _ = try? await api.request("devices/\(id)",method:"DELETE",body:.object([:])) }
        eventTask?.cancel(); eventTask = nil; refreshTask?.cancel()
        await Task.detached {CredentialVault.remove()}.value
        credentials = nil; api = nil; online = false
        groups = []; counts = [:]; overview = .null; capabilities = .null; change += 1
        await FileCache.shared.clear()
        showConnection = true
    }
    func refresh() async {
        guard let api else { return }
        let currentServer = serverID
        do {
            async let g = api.request("groups")
            async let o = api.request("overview")
            async let c = api.request("capabilities")
            let (groupsReply,overviewReply,capabilities) = try await (g,o,c)
            guard currentServer == serverID,self.api != nil else {return}
            groups = groupsReply["groups"].values.map { PaperGroup(raw:$0) }
            overview = overviewReply
            self.capabilities = capabilities
            if isV2 {counts = overviewReply["counts"].dictionary.mapValues(\.int)}
            // The v2 cursor advances only after receiving events, not after unrelated GETs.
            if !isV2 {cursor = max(cursor,capabilities["event_cursor"].int)}
            online = true
        } catch { online = false; handle(error,silent:true) }
    }
    func request(_ path:String, method:String = "GET", body:JSON? = nil, query:[String:String] = [:]) async throws -> JSON {
        guard let api else { throw ServerError(message:"请先连接论文服务器") }
        let currentServer = serverID
        do { let result = try await api.request(path,method:method,body:body,query:query);guard currentServer == serverID,self.api != nil else {throw CancellationError()}; online = true; return result }
        catch { handle(error,silent:true); throw error }
    }
    func perform(_ path:String, method:String = "POST", body:JSON = .object([:]), message:String? = nil) async {
        do {
            _ = try await request(path,method:method,body:body)
            change += 1
            await refresh()
            if let message { notify(message) }
        } catch { handle(error) }
    }
    func job(_ action:String, key:String? = nil, keys:[String]? = nil, extra:[String:JSON] = [:]) async throws -> JSON {
        var body = extra
        body["action"] = .string(action)
        if let key { body["key"] = .string(key) }
        if let keys { body["keys"] = .strings(keys) }
        let result = try await request("jobs",method:"POST",body:.object(body))
        change += 1
        notify("已提交到服务器")
        return result
    }
    func handle(_ issue:Error, silent:Bool = false) {
        if issue is CancellationError || (issue as NSError).code == NSURLErrorCancelled { return }
        if let value = issue as? ServerError, value.status == 401 { showConnection = true; online = false }
        if (issue as NSError).domain == NSURLErrorDomain {online = false}
        if !silent { error = issue.localizedDescription }
    }
    func notify(_ message:String) {
        toastTask?.cancel(); toast = message
        toastTask = Task { try? await Task.sleep(for:.seconds(3)); if !Task.isCancelled { toast = nil } }
    }
    private func startEvents() {
        eventTask?.cancel()
        guard let api else { return }
        eventTask = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await api.events(after:self.cursor) { [weak self] id,kind,payload in
                        await self?.received(id:id,kind:kind,payload:payload)
                    }
                    delay = 1
                } catch {
                    guard !Task.isCancelled else { return }
                    self.online = false
                    self.handle(error,silent:true)
                }
                try? await Task.sleep(for:.seconds(delay))
                guard !Task.isCancelled else { return }
                await self.refresh()
                self.change += 1
                delay = min(delay * 2,30)
            }
        }
    }
    private func received(id:Int,kind:String,payload:JSON) {
        cursor = max(cursor,id); online = true
        if kind == "reading.changed" { return }
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for:.milliseconds(350))
            guard !Task.isCancelled else { return }
            await refresh(); change += 1
        }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var papers: [Paper] = []
    @Published var total = 0
    @Published var loading = false
    @Published var error: String?
    @Published var query = ""
    @Published var sort = "published_desc"
    @Published var status = ""
    @Published var source = ""
    @Published var mode = "keyword"
    @Published var page = 0
    @Published var similar = ""
    private var generation = UUID()
    func load(app:AppModel,shelf:Shelf,reset:Bool = false) async {
        if reset { page = 0 }
        guard app.api != nil else {generation = UUID();papers = []; total = 0;loading = false; return }
        let generation = UUID(); self.generation = generation
        loading = true; error = nil
        var params = ["collection":shelf.collection,"q":query,"sort":sort,"status":status,
                      "source":source,"mode":mode,"offset":String(page*40),"limit":"40"]
        if !shelf.groupID.isEmpty { params["group"] = shelf.groupID }
        if !similar.isEmpty { params["similar"] = similar }
        do {
            let result = try await app.request("papers",query:params)
            guard self.generation == generation else { return }
            papers = result["papers"].values.map { Paper(raw:$0) }
            total = result["total"].int
            let counts = result["counts_by_collection"].dictionary.mapValues(\.int)
            if !counts.isEmpty { app.counts = counts }
        } catch {
            guard self.generation == generation else { return }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        if self.generation == generation { loading = false }
    }
}
