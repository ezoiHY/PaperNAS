import Foundation
import SwiftUI

enum JSON: Codable, Equatable, Sendable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSON {
        get { if case .object(let v) = self { return v[key] ?? .null }; return .null }
        set { var v = dictionary; v[key] = newValue; self = .object(v) }
    }
    var dictionary: [String: JSON] { if case .object(let v) = self { return v }; return [:] }
    var values: [JSON] { if case .array(let v) = self { return v }; return [] }
    var text: String { if case .string(let v) = self { return v }; return "" }
    var int: Int { if case .number(let v) = self, v.isFinite { return Int(v) }; return 0 }
    var double: Double { if case .number(let v) = self { return v }; return 0 }
    var flag: Bool { if case .bool(let v) = self { return v }; return false }
    var isNull: Bool { self == .null }
    static func strings(_ v: [String]) -> JSON { .array(v.map(JSON.string)) }
    static func integer(_ v: Int) -> JSON { .number(Double(v)) }
    var pretty: String { guard let data = try? JSONEncoder.pretty.encode(self) else { return "" }; return String(decoding: data, as: UTF8.self) }
}

extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}

struct Paper: Identifiable, Equatable, Sendable {
    var raw: JSON
    var id: String { raw["key"].text }
    var title: String { raw["paper"]["title"].text }
    var authors: [String] { raw["paper"]["authors"].values.map(\.text) }
    var affiliations: [String] { raw["bibliography"]["first_author_affiliations"].values.map(\.text) }
    var byline: String { ([authors.first ?? ""] + affiliations).filter { !$0.isEmpty }.joined(separator: " · ") }
    var summary: String { raw["summary"].text }
    var date: String { String(raw["paper"]["published_at"].text.prefix(10)).replacingOccurrences(of: "-", with: ".") }
    var venue: String { raw["paper"]["venue"].text.isEmpty ? (raw["paper"]["source"].text == "arxiv" ? "arXiv" : raw["paper"]["source"].text) : raw["paper"]["venue"].text }
    var collection: String { raw["collection"].text }
    var relevanceScore: Double? {
        guard case .number(let score) = raw["enrichment"]["score"],score.isFinite,(0...100).contains(score) else {return nil}
        return score
    }
    var relevanceLabel: String {
        relevanceScore.map {"相关度 \($0.formatted(.number.precision(.fractionLength(0...1)))) 分"} ?? "未评分"
    }
    var relevanceReason: String {raw["enrichment"]["reason"].text}
    var revision: Int { raw["revision"].int }
    var groups: [PaperGroup] { raw["groups"].values.map { PaperGroup(raw: $0) } }
    var groupIDs: [String] { raw["group_ids"].values.map(\.text) }
    var coverPath: String { raw["cover_asset_url"].text }
    var hasReport: Bool { raw["has_report"].flag }
    var hasBrief: Bool { raw["has_brief"].flag }
    var attention: Bool {
        let materials = raw["materials"]
        return raw["status"].text == "failed" || !raw["error"].text.isEmpty || raw["report_stale"].flag || (!hasReport && !hasBrief)
            || materials["structure"].text == "missing" || materials["figures"]["failed"].int > 0 || materials["figures"]["page_fallback"].int > 0
    }
    var stateName: String { attention ? "需要处理" : hasReport ? "精读" : "初读" }
    var stateColor: Color { attention ? .orange : hasReport ? .blue : .green }
    var sourceURL: URL? { URL(string: raw["paper"]["url"].text) }
    // explanation is only the short introduction. The archived Markdown contains
    // the complete findings, data, experiments, checks and evidence.
    var reportMarkdown: String {
        let complete = raw["markdown"].text
        return complete.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? raw["report"]["explanation"].text : complete
    }
    var abstract: String { raw["paper"]["abstract"].text }
    var figures: [JSON] { raw["document"]["figures"].values }
    var blocks: [JSON] { raw["document"]["blocks"].values }
}

struct PaperGroup: Identifiable, Equatable, Sendable {
    var raw: JSON
    var id: String { raw["id"].text }
    var name: String { raw["name"].text }
    var count: Int { raw["count"].isNull ? raw["paper_count"].int : raw["count"].int }
    var revision: Int { raw["revision"].int }
}

struct FigureDownload {
    let path:String
    let filename:String

    init(_ figure:JSON) {
        let original = figure["original_download_url"].text
        path = original.isEmpty ? figure["original_url"].text : original
        let mime = (original.isEmpty ? figure["mime_type"].text : figure["original_mime_type"].text)
            .split(separator:";",maxSplits:1).first?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() ?? ""
        let suffix = ["image/png":"png","image/x-png":"png","image/jpeg":"jpg","image/jpg":"jpg",
                      "image/svg+xml":"svg","image/webp":"webp","image/gif":"gif","image/tiff":"tiff",
                      "image/bmp":"bmp","image/x-ms-bmp":"bmp","image/avif":"avif","image/heic":"heic",
                      "image/heif":"heif","image/x-icon":"ico","image/vnd.microsoft.icon":"ico","application/pdf":"pdf"][mime] ?? "bin"
        let allowed = CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let identifier = String(String.UnicodeScalarView(figure["id"].text.unicodeScalars.filter{allowed.contains($0)}).prefix(128))
        filename = (identifier.isEmpty ? "figure" : identifier) + "." + suffix
    }
}

struct PaperNote: Identifiable, Equatable, Sendable {
    var raw: JSON
    var id: String { raw["id"].text }
    var body: String { raw["body"].text }
    var quote: String { raw["selected_text"].text }
    var page: Int { raw["page"].int }
    var revision: Int { raw["revision"].int }
    var fingerprint: String { raw["pdf_sha256"].text }
    var current: Bool { raw["pdf_current"].flag }
    var rects: [CGRect] { raw["rects"].values.map { CGRect(x: $0["x"].double, y: $0["y"].double, width: $0["width"].double, height: $0["height"].double) } }
}

enum ServerTimestamp {
    static func parse(_ value:String)->Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        if let date = formatter.date(from:value) {return date}
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from:value)
    }
    static func display(_ value:String)->String {
        guard let date = parse(value) else {return value.isEmpty ? "时间未知" : value}
        return date.formatted(date:.abbreviated,time:.shortened)
    }
}

struct ServerJob: Identifiable, Equatable, Sendable {
    var raw: JSON
    var id: String { raw["id"].text }
    var status: String { raw["status"].text }
    var active: Bool { ["running", "queued", "waiting", "pausing", "paused"].contains(status) }
    var action: String { raw["action"].text }
    var title: String { ActionNames[action] ?? action }
    var paperTitle: String { raw["progress"]["paper_title"].text.isEmpty ? raw["papers"].values.first?["title"].text ?? "" : raw["progress"]["paper_title"].text }
    var progress: JSON { raw["progress"] }
    var statusLabel: String { ["succeeded":"已完成", "failed":"失败", "cancelled":"已取消", "running":"进行中", "queued":"排队中", "waiting":"等待重试", "pausing":"正在暂停", "paused":"已暂停"][status] ?? status }
    var symbol: String { status == "succeeded" ? "checkmark.circle.fill" : status == "failed" ? "exclamationmark.circle.fill" : status == "paused" ? "pause.circle" : active ? "arrow.triangle.2.circlepath" : "stop.circle" }
    var color: Color { status == "succeeded" ? .green : status == "failed" ? .orange : active ? .accentColor : .secondary }
}

let ActionNames = ["daily":"每日筛选", "collect":"采集论文", "analyze_paper":"精读论文", "analyze_selected":"批量精读", "brief_paper":"初读论文", "summarize_paper":"一句话总结", "extract_paper":"提取原文", "extract_selected":"批量提取", "add_candidate":"添加论文", "inspect":"添加并解读", "test_api":"测试模型连接", "check_sources":"检查论文来源", "run":"处理论文库", "analyze":"精读论文库", "extract":"提取论文库"]

enum Shelf: Hashable {
    case library, candidates, research, tasks, group(String)
    var collection: String { self == .candidates ? "candidates" : "library" }
    var title: String { switch self { case .library:return "论文库"; case .candidates:return "待选池"; case .research:return "研究空间"; case .tasks:return "任务"; case .group:return "分组" } }
    var icon: String { switch self { case .library:return "books.vertical"; case .candidates:return "tray"; case .research:return "square.stack.3d.up"; case .tasks:return "clock.arrow.circlepath"; case .group:return "folder" } }
    var groupID: String { if case .group(let id) = self { return id }; return "" }
}

/// One navigation state owns both the selected items and the paper being read.
/// Modified clicks select a batch; an ordinary click always opens that exact paper.
struct LibraryNavigation {
    var selection:Set<String> = []
    var cursor:String?
    var rangeAnchor:String?
    var reader:String?
    mutating func open(_ id:String) {
        selection = [id]; cursor = id; rangeAnchor = id; reader = id
    }
    mutating func click(_ id:String,ordered:[String],command:Bool = false,shift:Bool = false) {
        guard ordered.contains(id) else {return}
        if shift,let anchor = rangeAnchor,let a = ordered.firstIndex(of:anchor),let b = ordered.firstIndex(of:id) {
            let range = Set(ordered[min(a,b)...max(a,b)])
            selection = command ? selection.union(range) : range; cursor = id
        } else if command {
            if selection.contains(id) {selection.remove(id)} else {selection.insert(id)}
            cursor = selection.contains(id) ? id : ordered.first{selection.contains($0)}
            rangeAnchor = cursor
        } else {open(id)}
    }
    mutating func move(_ delta:Int,ordered:[String],extend:Bool = false) {
        guard !ordered.isEmpty else {return}
        let index = cursor.flatMap{ordered.firstIndex(of:$0)} ?? (delta > 0 ? -1 : ordered.count)
        let id = ordered[min(max(index+delta,0),ordered.count-1)]
        if extend,let anchor = rangeAnchor,let a = ordered.firstIndex(of:anchor),let b = ordered.firstIndex(of:id) {
            selection = Set(ordered[min(a,b)...max(a,b)])
        } else {selection = [id];rangeAnchor = id}
        cursor = id
    }
}

struct Credentials: Codable, Equatable, Sendable {
    var serverURL: String
    var token: String
    var deviceID: String
    var serverID: String
    var apiVersion:Int? = nil
}

struct ServerError: LocalizedError {
    var message: String
    var status: Int = 0
    var errorDescription: String? { message }
}
