import Foundation
import Testing
@testable import PaperNAS

struct ReadingContentTests {
    @Test func v2ClaimsKeepExactSourceBlockAndQuote() throws {
        let raw = try decode("""
        {"report":{"schema":"papernas.report.v2","summary":{"text":"Bounded conclusion","citations":[{"block_id":"block-42","quote":"Original measured result"}]},"findings":[],"limitations":[],"unknowns":["Unmeasured"],"suggested_next_steps":["Run a controlled check"]}}
        """)
        let content = ReadingContent(paper:Paper(raw:raw),depth:.deep)
        #expect(content.allClaims.map(\.text) == ["Bounded conclusion","Unmeasured","Run a controlled check"])
        let claim = try #require(content.allClaims.first)
        let reference = try #require(content.evidence(for:claim).first)
        #expect(reference["block_id"].text == "block-42")
        #expect(reference["quote"].text == "Original measured result")
        #expect(content.allClaims.last?.status == "inferred")
    }
    @Test @MainActor func nativeTextRetainsFormattingButRejectsExecutableLinks() {
        let value = NativeReadingText.attributed("**Important** [paper](https://example.org/paper) [bad](javascript:alert) [local](file:///tmp/file)")
        #expect(String(value.characters).contains("Important"))
        let links = value.runs.compactMap(\.link).map(\.absoluteString)
        #expect(links == ["https://example.org/paper"])
    }
    @Test func briefAndDeepNeverShareFindingsOrEvidence() throws {
        let raw = try decode("""
        {"report":{"findings":{"overview":[{"text":"Deep claim","status":"supported","evidence_ids":["deep-e"],"figure_ids":["deep-f"]}],"evidence":[{"id":"deep-e","quote":"Deep quote"}]},"checks":{"items":[{"claim":"Deep claim","verdict":"needs_revision"}]}},
         "brief":{"summary":"Brief summary","scope":"abstract_only","findings":{"problem":[{"text":"Brief claim","status":"inferred","evidence_ids":["brief-e"],"figure_ids":[]}],"evidence":[{"id":"brief-e","quote":"Brief quote"}]}}}
        """)
        let paper = Paper(raw:raw),deep = ReadingContent(paper:paper,depth:.deep),brief = ReadingContent(paper:paper,depth:.brief)
        #expect(deep.allClaims.map(\.text) == ["Deep claim"])
        #expect(brief.allClaims.map(\.text) == ["Brief claim"])
        #expect(brief.summary == "Brief summary")
        #expect(brief.metadata["scope"].text == "abstract_only")
        #expect(deep.evidence.first?["id"].text == "deep-e")
        #expect(brief.evidence.first?["id"].text == "brief-e")
        #expect(brief.checks.isEmpty)
        #expect(deep.check(for:deep.allClaims[0])?["verdict"].text == "needs_revision")
    }

    @Test func datasetsQuestionsAndCitationOrderRemainIntact() throws {
        let raw = try decode("""
        {"report":{"findings":{
          "data_sources":[{"name":"Synthetic dataset","origin":{"text":"A","status":"supported"},"purpose":{"text":"B"},"collection":{"text":"C"},"size":{"text":"D"},"processing":{"text":"E"},"split":{"text":"F"},"availability":{"text":"G"}}],
          "questions":[{"question":"Synthetic question?","answer":{"text":"Synthetic answer","status":"inferred","evidence_ids":["e2","missing","e1"],"figure_ids":["f1"]}}],
          "evidence":[{"id":"e1","quote":"One"},{"id":"e2","quote":"Two"}]}}}
        """)
        let content = ReadingContent(paper:Paper(raw:raw),depth:.deep)
        let data = try #require(content.sections.first{$0.id == "data_sources"})
        #expect(data.groups.first?.title == "Synthetic dataset")
        #expect(data.claims.map(\.text) == ["A","B","C","D","E","F","G"])
        #expect(Set(data.claims.map(\.id)).count == 7)
        let answer = try #require(content.sections.first{$0.id == "questions"}?.claims.first)
        #expect(content.sections.last?.groups.first?.title == "Synthetic question?")
        #expect(content.evidence(for:answer).map{$0["id"].text} == ["e2","e1"])
        #expect(answer.evidenceIDs == ["e2","missing","e1"])
        #expect(answer.figureIDs == ["f1"])
    }

    @Test func outlineFollowsDocumentOrderAndIgnoresNonfiniteGeometry() {
        let order = ["overview","work","data","results"]
        #expect(ReadingContent.activeSection(["results":800,"data":400,"work":70,"overview":-100],ordered:order) == "overview")
        #expect(ReadingContent.activeSection(["overview":-700,"work":-100,"data":20,"results":400],ordered:order) == "data")
        #expect(ReadingContent.activeSection(["work":.nan,"results":.infinity,"overview":-20],ordered:order) == "overview")
        #expect(ReadingContent.activeSection([:],ordered:[]) == nil)
    }

    @Test func legacyContentKeepsSectionsWithoutExposingProvenanceInBody() {
        let markdown = "# Paper\n\nParser: private-metadata\n\n## 材料与核对提示\n\nTechnical warning\n\n## Methods\n\nFull method\n\n## Results\n\nFull result"
        let old = ReadingContent(paper:Paper(raw:.object(["markdown":.string(markdown)])),depth:.deep)
        #expect(old.sections.map(\.title) == ["Methods","Results"])
        #expect(old.allClaims.map(\.text) == ["Full method","Full result"])
        let plain = ReadingContent(paper:Paper(raw:.object(["brief":.string("Legacy brief prose")])),depth:.brief)
        #expect(plain.allClaims.map(\.text) == ["Legacy brief prose"])
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["PAPER_NAS_REPORT_FIXTURES"] != nil))
    func allRealClaimsAndReferencesSurviveTheNativeProjection() throws {
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PAPER_NAS_REPORT_FIXTURES"]!)
        for key in ["360f353e81e713a08a7d","52af0d1bc83f3a76e0a8","72fd78a7f5e21204f171","a07565eeaa1152b4326e"] {
            let raw = try JSONDecoder().decode(JSON.self,from:Data(contentsOf:root.appendingPathComponent(key + ".json")))
            let depth:ReadingDepth = raw["has_report"].flag ? .deep : .brief
            let source = depth == .deep ? raw["report"] : raw["brief"]
            let content = ReadingContent(paper:Paper(raw:raw),depth:depth)
            let original = recursiveClaims(source["findings"])
            let represented = content.allClaims.map { claim in
                JSON.object(["text":.string(claim.text),"status":.string(claim.status),"evidence_ids":.strings(claim.evidenceIDs),"figure_ids":.strings(claim.figureIDs)])
            }
            #expect(original.map(\.pretty).sorted() == represented.map(\.pretty).sorted())
            #expect(!represented.isEmpty)
            #expect(content.evidence == source["findings"]["evidence"].values)
            #expect(content.checks == (depth == .deep ? source["checks"]["items"].values : []))
            #expect(content.allClaims.count == Set(content.allClaims.map(\.id)).count)
            if depth == .brief {#expect(content.summary == source["summary"].text)}
            let figures = Set(Paper(raw:raw).figures.map{$0["id"].text})
            #expect(Set(content.allClaims.flatMap(\.figureIDs)).isSubset(of:figures))
        }
    }

    private func decode(_ text:String)throws->JSON {try JSONDecoder().decode(JSON.self,from:Data(text.utf8))}
    private func recursiveClaims(_ value:JSON)->[JSON] {
        if case .object(let object) = value {
            if object["text"] != nil, object["status"] != nil {
                return [.object(["text":value["text"],"status":value["status"],"evidence_ids":.array(value["evidence_ids"].values),"figure_ids":.array(value["figure_ids"].values)])]
            }
            return object.values.flatMap(recursiveClaims)
        }
        if case .array(let array) = value {return array.flatMap(recursiveClaims)}
        return []
    }
}
