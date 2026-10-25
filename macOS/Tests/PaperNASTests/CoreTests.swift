import Testing
import PDFKit
@testable import PaperNAS

struct CoreTests {
    @Test func testServerTimestampsKeepTheInstantAcrossTimeZones() throws {
        // Both server generations return fractional UTC times. The UI must not
        // display the raw UTC prefix as if it were the user's local wall time.
        let utc = try #require(ServerTimestamp.parse("2026-10-22T19:00:27.344592+00:00"))
        let local = try #require(ServerTimestamp.parse("2026-10-23T03:00:27.344592+08:00"))
        #expect(utc == local)
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = try #require(TimeZone(identifier:"Asia/Shanghai"))
        let parts = calendar.dateComponents([.day,.hour,.minute],from:utc)
        #expect(parts.day == 23 && parts.hour == 3 && parts.minute == 0)
        #expect(ServerTimestamp.parse("2026-10-22T19:00:27Z") == ServerTimestamp.parse("2026-10-23T03:00:27+08:00"))
        #expect(ServerTimestamp.parse("unrecognized timestamp") == nil)
        #expect(ServerTimestamp.display("unrecognized timestamp") == "unrecognized timestamp")
    }
    @Test func testVersionTwoRoutesAndOldCredentials() async throws {
        let api = try APIClient(baseURL:"http://127.0.0.1:8788",token:"test",apiVersion:2)
        #expect(try await api.url("/api/v2/blocks/example").path == "/api/v2/blocks/example")
        #expect(try await api.url("papers").path == "/api/v2/papers")
        let old = try JSONDecoder().decode(Credentials.self,from:Data("{\"serverURL\":\"https://example.org\",\"token\":\"t\",\"deviceID\":\"d\",\"serverID\":\"s\"}".utf8))
        #expect(old.apiVersion == nil)
    }
    @Test func testCandidateRelevanceUsesSavedInterestScore() {
        var paper = Paper(raw:.object(["enrichment":.object(["score":.number(92),"reason":.string("Matches research interests")]),"search_match":.object(["score":.number(0.25)])]))
        #expect(paper.relevanceScore == 92)
        #expect(paper.relevanceReason == "Matches research interests")
        paper.raw["enrichment"]["score"] = .number(0)
        #expect(paper.relevanceScore == 0)
        for value in [JSON.null,.string("92"),.number(-1),.number(101),.number(.nan)] {
            paper.raw["enrichment"]["score"] = value
            #expect(paper.relevanceScore == nil)
            #expect(paper.relevanceLabel == "未评分")
        }
    }
    @Test func testPaperAttentionIncludesMissingMaterialsWithoutHidingBriefs() {
        let healthy:JSON = .object([
            "has_report":.bool(true),"has_brief":.bool(false),
            "materials":.object(["structure":.string("ready"),"figures":.object(["ready":.integer(2),"failed":.integer(0),"page_fallback":.integer(0)])])
        ])
        #expect(!Paper(raw:healthy).attention)
        for status in ["failed","page_fallback"] {
            var raw = healthy
            raw["materials"]["figures"][status] = .integer(1)
            #expect(Paper(raw:raw).attention)
            #expect(Paper(raw:raw).stateName == "需要处理")
        }
        var missing = healthy;missing["materials"]["structure"] = .string("missing")
        #expect(Paper(raw:missing).attention)
        var stale = healthy;stale["report_stale"] = .bool(true)
        #expect(Paper(raw:stale).attention)
        var unread = healthy;unread["has_report"] = .bool(false)
        #expect(Paper(raw:unread).attention)
        var brief = unread;brief["has_brief"] = .bool(true)
        #expect(!Paper(raw:brief).attention)
        #expect(Paper(raw:brief).stateName == "初读")
        var pending = healthy;pending["materials"]["figures"]["pending"] = .integer(1)
        #expect(!Paper(raw:pending).attention)
    }
    @Test func testFigureDownloadKeepsOriginalFormatAndLegacyFallback() {
        var figure:JSON = .object(["id":.string("figure-2"),"asset_url":.string("/display.png"),
                                  "original_url":.string("/display.png"),"mime_type":.string("image/png"),
                                  "original_download_url":.string("/original"),"original_mime_type":.string("image/svg+xml")])
        for (mime,suffix) in [("image/png","png"),("image/jpeg","jpg"),("image/svg+xml; charset=utf-8","svg"),
                              ("image/webp","webp"),("image/gif","gif"),("image/tiff","tiff"),("image/avif","avif"),
                              ("application/octet-stream","bin")] {
            figure["original_mime_type"] = .string(mime)
            let original = FigureDownload(figure)
            #expect(original.path == "/original")
            #expect(original.filename == "figure-2." + suffix)
        }
        figure["original_download_url"] = .null
        figure["original_url"] = .string("/old-original.jpg")
        figure["mime_type"] = .string("image/jpeg")
        #expect(FigureDownload(figure).path == "/old-original.jpg")
        #expect(FigureDownload(figure).filename == "figure-2.jpg")
        figure["id"] = .string("../../figure:2/\n")
        #expect(FigureDownload(figure).filename == "figure2.jpg")
        figure["id"] = .string("")
        #expect(FigureDownload(figure).filename == "figure.jpg")
    }
    @Test @MainActor func testStartupCanWaitForCredentialsWithoutBlockingTheWindow() async {
        let gate = CredentialTestGate()
        let app = AppModel(loadCredentials:{await gate.wait();return nil})
        #expect(await gate.calls == 0)
        let startup = Task {await app.start()}
        while await gate.calls == 0 {await Task.yield()}
        #expect(app.restoringLogin)
        #expect(!app.showConnection)
        // A second window does not cause a second Keychain prompt.
        await app.start()
        #expect(await gate.calls == 1)
        await gate.finish()
        await startup.value
        #expect(!app.restoringLogin)
        #expect(app.showConnection)
    }
    @Test func testNativeResourceURLsCannotLeaveServer() async throws {
        let api = try APIClient(baseURL:"https://papers.example.ts.net",token:"secret")
        let url = try await api.url("/api/papers/abc/figures/fig-1?size=thumb")
        #expect(url.absoluteString == "https://papers.example.ts.net/api/v1/papers/abc/figures/fig-1?size=thumb")
        do {_ = try await api.url("https://evil.example/");Issue.record("External path permitted")} catch {}
        do {_ = try await api.url("../secret");Issue.record("Parent path permitted")} catch {}
        #expect(throws: ServerError.self) {try APIClient(baseURL:"http://public.example")}
        #expect(throws: ServerError.self) {try APIClient(baseURL:"https://user:password@example.com")}
        #expect(throws: ServerError.self) {try APIClient(baseURL:"https://example.com/subpath")}
        #expect(throws: ServerError.self) {try APIClient(baseURL:"http://100.100.1.2.example.com")}
        #expect(throws: ServerError.self) {try APIClient(baseURL:"http://100.100.999.999")}
        _ = try APIClient(baseURL:"http://100.64.0.2:8788")
    }
    @Test func testCoordinatesRemainNormalizedAndRoundTrip() {
        for page in [CGRect(x:30,y:70,width:612,height:792),CGRect(x:-20,y:90,width:792,height:612)] {
            let target = CGRect(x:page.minX+25,y:page.minY+80,width:150,height:18)
            for flipped in [true,false] {
            let normalized = PDFCoordinates.normalize(target,in:page,isFlipped:flipped)
            #expect((0...1).contains(normalized.minX));#expect((0...1).contains(normalized.maxY))
            let result = PDFCoordinates.expand(normalized,in:page,isFlipped:flipped)
            #expect(abs(result.minX-target.minX) < 0.00001)
            #expect(abs(result.minY-target.minY) < 0.00001)
            #expect(abs(result.width-target.width) < 0.00001)
            }
        }
        #expect(PDFCoordinates.normalize(.zero,in:.zero) == .zero)
    }
    @Test func testMarkdownEscapesUntrustedHTMLAndOnlyLinksKnownEvidence() {
        let text = "# Paper\n\n<script>evil()</script>\n\nClaim [known] [unknown]\n\n[unsafe](javascript:alert(1))"
        let html = SafeMarkdown.html(text,evidence:["known"])
        #expect(!html.contains("<script>"))
        #expect(!html.contains("href=\"javascript:"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("evidence://known"))
        #expect(!html.contains("evidence://unknown"))
    }
    @Test func testPaperStateDoesNotConflateCollectionsAndDepth() {
        let p = Paper(raw:.object(["collection":.string("candidates"),"has_report":.bool(true)]))
        #expect(p.stateName == "精读");#expect(p.collection == "candidates");#expect(!p.attention)
        var raw = p.raw;raw["report_stale"] = .bool(true)
        #expect(Paper(raw:raw).attention)
    }
    @Test func testCompleteReportWinsOverShortIntroduction() {
        let full = "# Paper\n\nMetadata\n\n## 方法与具体工作\n\nMethod\n\n## 实验与结果\n\nResult [ev-1](#evidence-abc)\n\n## 局限与待验证问题\n\nLimit\n\n## 原文证据\n\n<a id=\"evidence-abc\"></a>\n\n> Original source"
        var paper = Paper(raw:.object(["markdown":.string(full),"report":.object(["explanation":.string("Introduction only")])]))
        #expect(paper.reportMarkdown == full)
        let rendered = SafeMarkdown.document(paper.reportMarkdown,evidence:["ev-1"])
        for section in ["方法与具体工作","实验与结果","局限与待验证问题","原文证据","Original source"] {#expect(rendered.contains(section))}
        #expect(rendered.contains("href=\"evidence://ev-1\""))
        #expect(!rendered.contains("(#evidence-abc)"))
        #expect(!rendered.contains("&lt;a id="))
        #expect(rendered.contains("href=\"#section-1\""))
        #expect(rendered.contains("id=\"section-1\""))
        paper.raw["markdown"] = .string(" \n")
        #expect(paper.reportMarkdown == "Introduction only")
    }
    @Test func testReportAnchorsAndEntitiesStayInert() {
        let rendered = SafeMarkdown.html("<a id=\"figure-ok\"></a>\n\n<a id=\"figure-bad\" onclick=\"evil()\"></a>\n\n&#60;script&#62;evil()&#60;/script&#62;\n\nA\\_t B&#123;t+w&#125; [Figure](#figure-ok)")
        #expect(rendered.contains("<a id=\"figure-ok\"></a>"))
        #expect(!rendered.contains("<script>"))
        #expect(!rendered.contains("<a id=\"figure-bad\""))
        #expect(rendered.contains("A_t B{t+w}"))
        #expect(rendered.contains("href=\"#figure-ok\""))
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["PAPER_NAS_REPORT_FIXTURES"] != nil))
    func testExistingArchivedReportsRemainComplete() throws {
        let directory = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PAPER_NAS_REPORT_FIXTURES"]!)
        for key in ["360f353e81e713a08a7d","52af0d1bc83f3a76e0a8","72fd78a7f5e21204f171"] {
            let raw = try JSONDecoder().decode(JSON.self,from:Data(contentsOf:directory.appendingPathComponent(key + ".json")))
            let paper = Paper(raw:raw)
            #expect(paper.reportMarkdown.count > 20_000)
            #expect(paper.reportMarkdown == raw["markdown"].text)
            let rendered = SafeMarkdown.document(paper.reportMarkdown,evidence:Set(raw["report"]["findings"]["evidence"].values.map{$0["id"].text}))
            for section in ["一分钟概览","研究问题","方法与具体工作","贡献与创新","数据从哪里来，如何划分","实验与结果","优势与局限","关键结论核对","原文证据"] {#expect(rendered.contains(section))}
            #expect(!rendered.contains("&lt;a id="))
            #expect(!rendered.contains("](#evidence-"))
            #expect(rendered.contains("href=\"evidence://"))
        }
    }
    @Test func testReadingAndBatchSelectionNeverDisagree() {
        let ids = ["a","b","c","d"]
        var state = LibraryNavigation()
        state.click("a",ordered:ids)
        #expect(state.reader == "a");#expect(state.selection == ["a"])
        state.reader = nil
        state.click("b",ordered:ids)
        #expect(state.reader == "b");#expect(state.selection == ["b"])
        state.reader = nil
        state.click("d",ordered:ids,shift:true)
        #expect(state.reader == nil);#expect(state.selection == ["b","c","d"])
        state.click("c",ordered:ids,command:true)
        #expect(state.reader == nil);#expect(state.selection == ["b","d"])
        state.move(1,ordered:ids)
        #expect(state.selection == ["c"]);#expect(state.cursor == "c")
        state.open(state.cursor!)
        #expect(state.reader == "c");#expect(state.selection == ["c"])
        state.reader = nil
        state.click("c",ordered:ids) // Clicking the retained selection opens it again.
        #expect(state.reader == "c")
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["PAPER_NAS_TEST_CONNECTION_FILE"] != nil))
    @MainActor func testLiveLibraryAndExistingPDFNotes() async throws {
        let path = ProcessInfo.processInfo.environment["PAPER_NAS_TEST_CONNECTION_FILE"]!
        let credentials = try JSONDecoder().decode(Credentials.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let api = try APIClient(baseURL:credentials.serverURL,token:credentials.token,apiVersion:credentials.apiVersion ?? 1)
        let library = try await api.request("papers",query:["collection":"library"])
        #expect(library["total"].int >= 3)
        let key = "52af0d1bc83f3a76e0a8"
        let info = try await api.request("papers/\(key)/pdf/info")
        #expect(info["page_count"].int == 26)
        let url = try await FileCache.shared.pdf(api:api,serverID:credentials.serverID,key:key,sha:info["sha256"].text)
        let document = try #require(PDFDocument(url:url))
        #expect(document.pageCount == 26)
        let notes = try await api.request("papers/\(key)/notes")["notes"].values.map{PaperNote(raw:$0)}
        let note = try #require(notes.first)
        #expect(note.current)
        let view = PDFView(frame:CGRect(x:0,y:0,width:800,height:1000))
        view.document = document;view.autoScales = true
        let page = try #require(document.page(at:note.page-1))
        let displayed = view.convert(page.bounds(for:.cropBox),from:page)
        let recovered = note.rects.compactMap { r -> String? in
            let rect = view.convert(PDFCoordinates.expand(r,in:displayed,isFlipped:view.isFlipped),to:page)
            return page.selection(for:rect)?.string
        }.joined(separator:" ")
        #expect(recovered.contains("sEMG"))
        #expect(recovered.contains("pose"))
    }
}

private actor CredentialTestGate {
    var calls = 0
    private var continuation:CheckedContinuation<Void,Never>?
    func wait() async {calls += 1;await withCheckedContinuation {continuation = $0}}
    func finish() {continuation?.resume();continuation = nil}
}
