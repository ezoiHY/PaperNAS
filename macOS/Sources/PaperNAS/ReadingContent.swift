import Foundation

enum ReadingDepth: String, CaseIterable {
    case deep, brief
    var title: String { self == .deep ? "精读" : "初读" }
}

struct ReadingClaim: Identifiable {
    var id: String
    var label: String = ""
    var text: String
    var status: String
    var evidenceIDs: [String]
    var figureIDs: [String]

    init(id: String, label: String = "", raw: JSON) {
        self.id = id
        self.label = label
        text = raw.text.isEmpty ? raw["text"].text : raw.text
        status = raw["status"].text
        evidenceIDs = raw["evidence_ids"].values.map(\.text)
        figureIDs = raw["figure_ids"].values.map(\.text)
    }
}

struct ReadingGroup: Identifiable {
    var id: String
    var title: String
    var claims: [ReadingClaim]
}

struct ReadingSection: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var groups: [ReadingGroup]
    var claims: [ReadingClaim] { groups.flatMap(\.claims) }
}

/// Presents the server's typed findings without rewriting their research content.
/// Markdown is used only for compatibility with old, unstructured reports.
struct ReadingContent {
    let depth: ReadingDepth
    let summary: String
    let sections: [ReadingSection]
    let evidence: [JSON]
    let checks: [JSON]
    let metadata: JSON

    static let definitions: [(String, String, String)] = [
        ("overview", "概览", "text.alignleft"),
        ("problem", "研究问题", "questionmark.circle"),
        ("work", "方法与工作", "point.3.connected.trianglepath.dotted"),
        ("contributions", "主要贡献", "lightbulb"),
        ("data_sources", "数据与划分", "cylinder.split.1x2"),
        ("experiments", "实验与结果", "chart.xyaxis.line"),
        ("strengths", "优势", "plus.circle"),
        ("limitations", "局限", "minus.circle"),
        ("questions", "研究问答", "bubble.left.and.text.bubble.right")
    ]
    static let dataFields = [
        ("origin", "来源"), ("purpose", "用途"), ("collection", "采集"),
        ("size", "规模"), ("processing", "处理"), ("split", "划分"), ("availability", "获取")
    ]

    init(paper: Paper, depth: ReadingDepth) {
        self.depth = depth
        let source = depth == .brief ? paper.raw["brief"] : paper.raw["report"]
        metadata = source
        if source["schema"].text == "papernas.report.v2" {
            summary = ""
            checks = []
            var references:[JSON] = []
            var groups:[ReadingSection] = []
            for (key,title,symbol,values) in [
                ("overview","概览","text.alignleft",[source["summary"]]),
                ("findings","主要依据","text.magnifyingglass",source["findings"].values),
                ("limitations","条件与局限","minus.circle",source["limitations"].values),
                ("unknowns","尚不能确定","questionmark.circle",source["unknowns"].values),
                ("next_steps","建议的下一步 · 尚未执行","arrow.right.circle",source["suggested_next_steps"].values)
            ] {
                var claims:[ReadingClaim] = []
                for (index,value) in values.enumerated() {
                    var raw:JSON = value.text.isEmpty ? value : .object(["text":value])
                    var ids:[String] = []
                    for citation in value["citations"].values {
                        let id = "v2-reference-\(references.count + 1)"
                        references.append(.object(["id":.string(id),"block_id":citation["block_id"],"quote":citation["quote"]]))
                        ids.append(id)
                    }
                    raw["evidence_ids"] = .strings(ids)
                    if key == "next_steps" {raw["status"] = .string("inferred")}
                    let claim = ReadingClaim(id:"v2-\(key)-\(index)",raw:raw)
                    if !claim.text.isEmpty {claims.append(claim)}
                }
                if !claims.isEmpty {groups.append(ReadingSection(id:key,title:title,symbol:symbol,groups:[ReadingGroup(id:key,title:"",claims:claims)]))}
            }
            evidence = references
            sections = groups
            return
        }
        summary = depth == .brief ? source["summary"].text : ""
        let findings = source["findings"]
        evidence = findings["evidence"].values
        checks = depth == .deep ? source["checks"]["items"].values : []

        var built: [ReadingSection] = []
        for (key, title, symbol) in Self.definitions {
            let values = findings[key].values
            var groups: [ReadingGroup] = []
            if key == "data_sources" {
                groups = values.enumerated().map { index, item in
                    let claims = Self.dataFields.map { field, label in
                        ReadingClaim(id: "data-\(index)-\(field)", label: label, raw: item[field])
                    }.filter { !$0.text.isEmpty }
                    return ReadingGroup(id: "data-\(index)", title: item["name"].text, claims: claims)
                }
            } else if key == "questions" {
                groups = values.enumerated().map { index, item in
                    ReadingGroup(id: "question-\(index)", title: item["question"].text,
                                 claims: [ReadingClaim(id: "answer-\(index)", raw: item["answer"])]
                                    .filter { !$0.text.isEmpty })
                }
            } else {
                let claims = values.enumerated().map {
                    ReadingClaim(id: "\(key)-\($0.offset)", raw: $0.element)
                }.filter { !$0.text.isEmpty }
                if !claims.isEmpty { groups = [ReadingGroup(id: key, title: "", claims: claims)] }
            }
            groups = groups.filter { !$0.claims.isEmpty }
            if !groups.isEmpty { built.append(ReadingSection(id: key, title: title, symbol: symbol, groups: groups)) }
        }
        if built.isEmpty {
            let fallback = depth == .deep ? paper.reportMarkdown : source.text
            built = Self.legacySections(fallback)
        }
        sections = built
    }

    var allClaims: [ReadingClaim] { sections.flatMap(\.claims) }
    var issues: [JSON] { checks.filter { $0["verdict"].text != "supported" } }

    func evidence(for claim: ReadingClaim) -> [JSON] {
        // Follow the order of citations in the claim, even if the server stores
        // its evidence index in a different order. Unresolved IDs remain in the claim.
        claim.evidenceIDs.compactMap { id in evidence.first { $0["id"].text == id } }
    }

    func check(for claim: ReadingClaim) -> JSON? {
        checks.first { $0["claim"].text == claim.text && $0["verdict"].text != "supported" }
    }

    static func activeSection(_ positions: [String: Double], ordered: [String], threshold: Double = 64) -> String? {
        ordered.last { positions[$0].map { $0.isFinite && $0 <= threshold } ?? false } ?? ordered.first
    }

    private static func legacySections(_ text: String) -> [ReadingSection] {
        var sections: [ReadingSection] = []
        var title = "解读"
        var lines: [String] = []
        func append() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, !["报告信息", "材料与核对提示"].contains(title) else { return }
            let id = "legacy-\(sections.count)"
            sections.append(.init(id: id, title: title, symbol: "text.alignleft",
                                  groups: [.init(id: id, title: "", claims: [.init(id: id, raw: .string(body))])]))
        }
        let input = text.components(separatedBy: .newlines)
        // Generated Markdown stores its technical metadata before the first H2.
        // A plain-text legacy response with no sections remains fully readable.
        let start = input.firstIndex(where: { $0.hasPrefix("## ") }) ?? 0
        for line in input.dropFirst(start) {
            if line.hasPrefix("## ") {
                append()
                title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                lines = []
            } else {
                lines.append(line)
            }
        }
        append()
        return sections
    }
}
