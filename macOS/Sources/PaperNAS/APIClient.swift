import Foundation
import CryptoKit

final class SameServerDelegate: NSObject, URLSessionTaskDelegate {
    let origin: URL
    init(origin: URL) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let permitted = request.url?.scheme == origin.scheme && request.url?.host == origin.host && request.url?.port == origin.port
        completionHandler(permitted ? request : nil)
    }
}

actor APIClient {
    let base: URL
    let token: String
    let apiVersion: Int
    let session: URLSession
    init(baseURL: String, token: String = "", apiVersion:Int = 1) throws {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw ServerError(message:"请输入服务器地址，例如 https://server.example.ts.net")
        }
        if url.scheme == "http" {
            let h = url.host ?? ""
            let parts = h.split(separator:".",omittingEmptySubsequences:false)
            let octets = parts.compactMap { Int($0) }
            let tailnet = parts.count == 4 && octets.count == 4 && octets.allSatisfy{(0...255).contains($0)} && octets[0] == 100 && (64...127).contains(octets[1])
            guard h == "localhost" || h == "127.0.0.1" || h == "::1" || tailnet else {
                throw ServerError(message:"远程服务器请使用 HTTPS；HTTP 仅支持本机和 Tailscale 私有地址")
            }
        }
        base = url; self.token = token; self.apiVersion = apiVersion == 2 ? 2 : 1
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 3600
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration:config, delegate:SameServerDelegate(origin:url), delegateQueue:nil)
    }
    func url(_ path: String, query: [String:String] = [:]) throws -> URL {
        let normalized: String
        if path.hasPrefix("/api/v1/") || path.hasPrefix("/api/v2/") { normalized = String(path.dropFirst(8)) }
        else if path.hasPrefix("/api/") { normalized = String(path.dropFirst(5)) }
        else { normalized = path.trimmingCharacters(in:CharacterSet(charactersIn:"/")) }
        guard !normalized.contains("://"), !normalized.split(separator:"/").contains("..") else {
            throw ServerError(message:"无效的服务器资源地址")
        }
        var c = URLComponents(url:base, resolvingAgainstBaseURL:false)!
        let split = normalized.split(separator:"?", maxSplits:1, omittingEmptySubsequences:false)
        c.path = "/api/v\(apiVersion)/" + String(split[0])
        if split.count > 1 { c.percentEncodedQuery = String(split[1]) }
        if !query.isEmpty { c.queryItems = (c.queryItems ?? []) + query.sorted{$0.key < $1.key}.map { URLQueryItem(name:$0.key,value:$0.value) } }
        guard let result = c.url else { throw ServerError(message:"无效的资源地址") }
        return result
    }
    func negotiatedVersion() async throws -> Int {
        let (data,response) = try await session.data(from:base.appendingPathComponent("health"))
        try validate(response,data:data)
        let value = try JSONDecoder().decode(JSON.self,from:data)
        guard [1,2].contains(value["api_version"].int) else {throw ServerError(message:"服务器 API 版本不受此客户端支持")}
        return value["api_version"].int
    }
    func uploadPDF(_ file:URL,title:String = "",workID:String? = nil) async throws -> JSON {
        let bytes = try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard bytes <= 80*1024*1024 else {throw ServerError(message:"PDF 大于 80 MB，请使用较小的文件")}
        let boundary = "PaperNAS-" + UUID().uuidString
        var query = ["title":title]
        if let workID {query["work_id"] = workID}
        var request = try makeRequest("imports/pdf",query:query)
        request.httpMethod = "POST"
        request.setValue(UUID().uuidString,forHTTPHeaderField:"Idempotency-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type")
        let filename = file.lastPathComponent.replacingOccurrences(of:"\"",with:"_").replacingOccurrences(of:"\r",with:"_").replacingOccurrences(of:"\n",with:"_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/pdf\r\n\r\n".utf8)
        body.append(try Data(contentsOf:file,options:.mappedIfSafe))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (data,response) = try await session.upload(for:request,from:body)
        try validate(response,data:data)
        return try JSONDecoder().decode(JSON.self,from:data)
    }
    func request(_ path: String, method: String = "GET", body: JSON? = nil,
                 query: [String:String] = [:], requestID: String? = nil) async throws -> JSON {
        var r = try makeRequest(path, query:query)
        r.httpMethod = method
        if let body { r.httpBody = try JSONEncoder().encode(body); r.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        if method != "GET" && method != "HEAD" {
            r.setValue(requestID ?? UUID().uuidString, forHTTPHeaderField:"Idempotency-Key")
        }
        let (data,response) = try await session.data(for:r)
        try validate(response,data:data)
        return try JSONDecoder().decode(JSON.self,from:data)
    }
    func data(_ path: String, query: [String:String] = [:]) async throws -> Data {
        let (data,response) = try await session.data(for:makeRequest(path,query:query))
        try validate(response,data:data)
        return data
    }
    func download(_ path: String, destination: URL, expectedSHA: String? = nil,
                  query: [String:String] = [:]) async throws {
        let (temporary,response) = try await session.download(for:makeRequest(path,query:query))
        defer { try? FileManager.default.removeItem(at:temporary) }
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            let data = (try? Data(contentsOf:temporary)) ?? Data()
            try validate(response,data:data); return
        }
        if let sha = expectedSHA, !sha.isEmpty {
            let handle = try FileHandle(forReadingFrom:temporary)
            defer { try? handle.close() }
            var hash = SHA256()
            while let part = try handle.read(upToCount:1024*1024), !part.isEmpty { hash.update(data:part) }
            let actual = hash.finalize().map{String(format:"%02x",$0)}.joined()
            guard actual == sha else { throw ServerError(message:"PDF 校验失败，请重新下载") }
        }
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        // Never replace a user-chosen export silently; the save panel handles approval.
        if FileManager.default.fileExists(atPath:destination.path) { try FileManager.default.removeItem(at:destination) }
        try FileManager.default.moveItem(at:temporary,to:destination)
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
    }
    func events(after: Int, receive: @escaping @Sendable (Int,String,JSON) async -> Void) async throws {
        var request = try makeRequest("events",query:["after":String(after)])
        request.setValue("text/event-stream",forHTTPHeaderField:"Accept")
        request.timeoutInterval = 60
        let (bytes,response) = try await session.bytes(for:request)
        try validate(response,data:Data())
        var id = after, kind = "", payload = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("id:") { id = Int(line.dropFirst(3).trimmingCharacters(in:.whitespaces)) ?? id }
            else if line.hasPrefix("event:") { kind = line.dropFirst(6).trimmingCharacters(in:.whitespaces) }
            else if line.hasPrefix("data:") {
                payload = line.dropFirst(5).trimmingCharacters(in:.whitespaces)
                let value = (try? JSONDecoder().decode(JSON.self,from:Data(payload.utf8))) ?? .null
                await receive(id,kind,value)
            }
        }
    }
    private func makeRequest(_ path:String, query:[String:String] = [:]) throws -> URLRequest {
        var r = URLRequest(url:try url(path,query:query))
        r.setValue("PaperNAS-macOS/0.1.0",forHTTPHeaderField:"User-Agent")
        if !token.isEmpty { r.setValue("Bearer " + token,forHTTPHeaderField:"Authorization") }
        return r
    }
    private func validate(_ response: URLResponse, data: Data) throws {
        guard let r = response as? HTTPURLResponse else { throw ServerError(message:"无法读取服务器响应") }
        guard (200...299).contains(r.statusCode) else {
            let value = try? JSONDecoder().decode(JSON.self,from:data)
            let message = value?["error"].text ?? value?["detail"].text ?? ""
            throw ServerError(message:message.isEmpty ? "服务器返回 HTTP \(r.statusCode)" : message,status:r.statusCode)
        }
    }
}

actor FileCache {
    static let shared = FileCache()
    let root: URL
    let limit = 512 * 1024 * 1024
    private var inFlight:[String:Task<URL,Error>] = [:]
    init() {
        root = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("com.harryhan.paper-nas/Files",isDirectory:true)
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    }
    func pdf(api:APIClient, serverID:String, key:String, sha:String) async throws -> URL {
        let name = serverID + "-" + key + "-" + sha + ".pdf"
        let destination = root.appendingPathComponent(name)
        if let task = inFlight[name] {return try await task.value}
        if FileManager.default.fileExists(atPath:destination.path) {
            try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:destination.path)
            return destination
        }
        let task = Task {try await api.download("papers/\(key)/pdf",destination:destination,expectedSHA:sha);return destination}
        inFlight[name] = task
        defer {inFlight[name] = nil}
        _ = try await task.value
        prune(protect:destination)
        return destination
    }
    func size() -> Int {
        files().reduce(0) { $0 + ((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
    }
    func sourcePDF(api:APIClient,serverID:String,sha:String) async throws -> URL {
        guard sha.count == 64,sha.allSatisfy({$0.isHexDigit}) else {throw ServerError(message:"原文文件标识无效")}
        let name = serverID + "-source-" + sha + ".pdf"
        let destination = root.appendingPathComponent(name)
        if let task = inFlight[name] {return try await task.value}
        if FileManager.default.fileExists(atPath:destination.path) {return destination}
        let task = Task {try await api.download("assets/\(sha)",destination:destination,expectedSHA:sha);return destination}
        inFlight[name] = task
        defer {inFlight[name] = nil}
        _ = try await task.value
        prune(protect:destination)
        return destination
    }
    func clear() { for file in files() { try? FileManager.default.removeItem(at:file) } }
    private func files() -> [URL] { (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey])) ?? [] }
    private func prune(protect:URL) {
        let values = files().sorted { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var total = size()
        for file in values where file != protect {
            guard total > limit else { break }
            let bytes = (try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
            if (try? FileManager.default.removeItem(at:file)) != nil { total -= bytes }
        }
    }
}
