import Foundation

// Markdown remains available for export compatibility and isolated formula text.
// The reading interface itself is native SwiftUI.
enum SafeMarkdown {
    static func escape(_ s:String)->String { s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;") }
    static func inline(_ value:String,evidence:Set<String>)->String {
        // Decode the server's Markdown entities before escaping HTML again.
        var decoded = value
        if let re = try? NSRegularExpression(pattern:#"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for m in re.matches(in:decoded,range:NSRange(decoded.startIndex...,in:decoded)).reversed() {
                guard let range = Range(m.range,in:decoded),let digits = Range(m.range(at:1),in:decoded) else {continue}
                let raw = String(decoded[digits]);let number = raw.hasPrefix("x") ? UInt32(raw.dropFirst(),radix:16) : UInt32(raw)
                if let number,let scalar = UnicodeScalar(number) {decoded.replaceSubrange(range,with:String(scalar))}
            }
        }
        for (entity,character) in [("&lt;","<"),("&gt;",">"),("&quot;","\""),("&amp;","&")] {decoded = decoded.replacingOccurrences(of:entity,with:character)}
        var s = escape(decoded)
        for (pattern,template) in [(#"(?<!\\)`([^`]+)(?<!\\)`"#,"<code>$1</code>"),(#"(?<!\\)\*\*([^*]+)(?<!\\)\*\*"#,"<strong>$1</strong>")] {
            s = s.replacingOccurrences(of:pattern,with:template,options:.regularExpression)
        }
        if let re = try? NSRegularExpression(pattern:#"(?<!\\)\[([^\]]+)\]\((https?://[^\s)]+|#[a-zA-Z0-9_-]+)\)"#) {
            for m in re.matches(in:s,range:NSRange(s.startIndex...,in:s)).reversed() {
                guard let range = Range(m.range,in:s),let lr = Range(m.range(at:1),in:s),let ur = Range(m.range(at:2),in:s) else {continue}
                let label = String(s[lr]),url = String(s[ur])
                let link = evidence.contains(label) && url.hasPrefix("#evidence-") ? citation(label) : "<a href=\"\(url)\">\(label)</a>"
                s.replaceSubrange(range,with:link)
            }
        }
        for id in evidence.sorted() where s.contains("[\(id)]") {s = s.replacingOccurrences(of:"[\(id)]",with:citation(id))}
        // These are Markdown escapes produced by the server, not literal slashes.
        s = s.replacingOccurrences(of:#"\\([\\`*_\[\]|#])"#,with:"$1",options:.regularExpression)
        return s
    }
    private static func citation(_ id:String)->String {
        "<a class=\"cite\" href=\"evidence://\(escape(id))\" title=\"查看原文引用 \(escape(id))\" aria-label=\"查看原文引用\">↗</a>"
    }
    static func document(_ text:String,evidence:Set<String> = [])->String {
        var lines = text.components(separatedBy:.newlines)
        var preamble = "", hints = ""
        if lines.first?.hasPrefix("# ") == true, let firstSection = lines.firstIndex(where:{$0.hasPrefix("## ")}) {
            preamble = html(lines[1..<firstSection].joined(separator:"\n"),evidence:evidence)
            lines = Array(lines[firstSection...])
            if lines.first == "## 材料与核对提示" {
                let end = lines.dropFirst().firstIndex(where:{$0.hasPrefix("## ")}) ?? lines.count
                hints = html(lines[1..<end].joined(separator:"\n"),evidence:evidence)
                lines = Array(lines.dropFirst(end))
            }
        }
        var sections:[String] = [], index = 0, code = false
        for line in lines {
            if line.hasPrefix("```") {code.toggle();continue}
            if code {continue}
            let hashes = line.prefix(while:{$0 == "#"}).count
            if (1...6).contains(hashes),line.dropFirst(hashes).hasPrefix(" ") {
                if hashes == 2 {sections.append("<a href=\"#section-\(index)\">" + inline(String(line.dropFirst(3)),evidence:[]) + "</a>")}
                index += 1
            }
        }
        var out = ""
        if !sections.isEmpty {out += "<details><summary>章节目录</summary><nav>" + sections.joined() + "</nav></details>"}
        if !preamble.isEmpty {out += "<details><summary>报告信息</summary>" + preamble + "</details>"}
        if !hints.isEmpty {out += "<details><summary>材料与核对提示</summary>" + hints + "</details>"}
        return (out.isEmpty ? "" : "<div class=\"report-tools\">" + out + "</div>") + html(lines.joined(separator:"\n"),evidence:evidence)
    }
    static func html(_ text:String,evidence:Set<String> = [])->String {
        var out = "",paragraph:[String] = [],code = false,codeLines:[String] = [],listIndents:[Int] = [],table = false,heading = 0
        func flush() {if !paragraph.isEmpty {out += "<p>" + paragraph.map{inline($0,evidence:evidence)}.joined(separator:"<br>") + "</p>";paragraph = []}}
        func closeLists() {while !listIndents.isEmpty {out += "</li></ul>";listIndents.removeLast()}}
        func closeTable() {if table {out += "</table>";table = false}}
        for line in text.components(separatedBy:.newlines) {
            if line.hasPrefix("```") {flush();closeLists();closeTable();if code {out += "<pre><code>" + escape(codeLines.joined(separator:"\n")) + "</code></pre>";codeLines = []};code.toggle();continue}
            if code {codeLines.append(line);continue}
            let t = line.trimmingCharacters(in:.whitespaces)
            if t.isEmpty {flush();closeLists();closeTable();continue}
            // Accept only the inert anchors emitted by the report exporter.
            if t.range(of:#"^<a id="(?:evidence|figure)-[a-zA-Z0-9_-]+"></a>$"#,options:.regularExpression) != nil {
                flush();closeLists();closeTable();out += t;continue
            }
            if t.hasPrefix("|") && t.hasSuffix("|") {
                flush();closeLists();if t.range(of:#"^[| :\-]+$"#,options:.regularExpression) != nil {continue}
                if !table {out += "<table>";table = true}
                out += "<tr>" + t.dropFirst().dropLast().split(separator:"|",omittingEmptySubsequences:false).map{"<td>"+inline(String($0),evidence:evidence)+"</td>"}.joined() + "</tr>";continue
            }
            closeTable()
            if t.hasPrefix("- ") || t.hasPrefix("* ") {
                flush();let indent = line.prefix(while:{$0.isWhitespace}).count
                while let last = listIndents.last,last > indent {out += "</li></ul>";listIndents.removeLast()}
                if listIndents.last == indent {out += "</li>"}
                else {out += "<ul>";listIndents.append(indent)}
                out += "<li>" + inline(String(t.dropFirst(2)),evidence:evidence);continue
            }
            closeLists()
            let hashes = t.prefix(while:{$0 == "#"}).count
            if (1...6).contains(hashes),t.dropFirst(hashes).hasPrefix(" ") {
                flush();out += "<h\(hashes) id=\"section-\(heading)\">" + inline(String(t.dropFirst(hashes+1)),evidence:evidence) + "</h\(hashes)>";heading += 1
            } else if t == "---" {flush();out += "<hr>"}
            else if t.hasPrefix("> ") {flush();out += "<blockquote>"+inline(String(t.dropFirst(2)),evidence:evidence)+"</blockquote>"}
            else {paragraph.append(line)}
        }
        flush();if code {out += "<pre>"+escape(codeLines.joined(separator:"\n"))+"</pre>"};closeLists();closeTable();return out
    }
}
