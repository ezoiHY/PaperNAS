import SwiftUI
import PDFKit
import AppKit

struct NoteAnchor: Codable, Equatable {
    var page: Int
    var quote: String
    var rects: [CGRect]
    var sha: String
    var json: JSON { .object(["page":.integer(page),"selected_text":.string(quote),"pdf_sha256":.string(sha),
        "rects":.array(rects.map { .object(["x":.number($0.minX),"y":.number($0.minY),"width":.number($0.width),"height":.number($0.height)]) }),
        "prefix":.string(""),"suffix":.string("")]) }
}

/// Both clients use rectangles relative to the displayed crop box, origin at top-left.
enum PDFCoordinates {
    static func normalize(_ rect: CGRect, in page: CGRect, isFlipped:Bool = true) -> CGRect {
        guard page.width > 0, page.height > 0 else { return .zero }
        let clipped = rect.intersection(page)
        guard !clipped.isNull else { return .zero }
        return CGRect(x:(clipped.minX-page.minX)/page.width,y:(isFlipped ? clipped.minY-page.minY : page.maxY-clipped.maxY)/page.height,
                      width:clipped.width/page.width,height:clipped.height/page.height)
    }
    static func expand(_ rect: CGRect, in page: CGRect, isFlipped:Bool = true) -> CGRect {
        CGRect(x:page.minX+rect.minX*page.width,y:isFlipped ? page.minY+rect.minY*page.height : page.maxY-rect.maxY*page.height,
               width:rect.width*page.width,height:rect.height*page.height)
    }
}

@MainActor final class PDFController: ObservableObject {
    weak var view: PDFView?
    @Published var page = 1
    @Published var pageCount = 0
    @Published var selection: NoteAnchor?
    @Published var search = ""
    var sha = ""
    var pageChanged: ((Int)->Void)?
    var observations: [NSObjectProtocol] = []
    private var highlights: [(PDFPage,PDFAnnotation)] = []
    private var notesSignature = ""
    func attach(_ view:PDFView) {
        detach(); self.view = view
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewSelectionChanged] {
            observations.append(NotificationCenter.default.addObserver(forName:name,object:view,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
    }
    func detach() { observations.forEach(NotificationCenter.default.removeObserver); observations = []; view = nil }
    func update() {
        guard let view, let document = view.document else { return }
        pageCount = document.pageCount
        if let current = view.currentPage {
            let value = document.index(for:current)+1
            if page != value { page = value; pageChanged?(value) }
        }
        guard let selected = view.currentSelection, selected.pages.count == 1,
              let p = selected.pages.first, let quote = selected.string?.trimmingCharacters(in:.whitespacesAndNewlines),
              !quote.isEmpty else { selection = nil; return }
        let displayed = view.convert(p.bounds(for:.cropBox),from:p)
        let rects = selected.selectionsByLine().map { PDFCoordinates.normalize(view.convert($0.bounds(for:p),from:p),in:displayed,isFlipped:view.isFlipped) }
            .filter { $0.width > 0 && $0.height > 0 }
        selection = NoteAnchor(page:document.index(for:p)+1,quote:quote,rects:rects,sha:sha)
    }
    func go(_ number:Int) {
        guard let view, let p = view.document?.page(at:max(0,number-1)) else { return }
        view.go(to:p); update()
    }
    func zoom(_ direction:Int) { if direction > 0 { view?.zoomIn(nil) } else { view?.zoomOut(nil) } }
    func fit() { view?.autoScales = true }
    func findNext() {
        guard !search.isEmpty,let view,let document = view.document else { return }
        let selection = document.findString(search,fromSelection:view.currentSelection,withOptions:.caseInsensitive)
            ?? document.findString(search,fromSelection:nil,withOptions:.caseInsensitive)
        if let selection { view.setCurrentSelection(selection,animate:true); view.scrollSelectionToVisible(nil) }
    }
    func show(_ note:PaperNote) {
        guard note.fingerprint == sha,let view,let p = view.document?.page(at:note.page-1) else { return }
        view.go(to:p)
        let displayed = view.convert(p.bounds(for:.cropBox),from:p)
        if let rect = note.rects.first {
            let bounds = view.convert(PDFCoordinates.expand(rect,in:displayed,isFlipped:view.isFlipped),to:p)
            view.go(to:PDFDestination(page:p,at:CGPoint(x:bounds.minX,y:bounds.maxY)))
        }
    }
    func annotate(_ notes:[PaperNote],force:Bool = false) {
        let signature = sha + notes.map { $0.id + String($0.revision) }.joined()
        guard force || notesSignature != signature,let view, let doc = view.document else { return }
        notesSignature = signature
        highlights.forEach { $0.0.removeAnnotation($0.1) }; highlights = []
        for note in notes where note.fingerprint == sha {
            guard let p = doc.page(at:note.page-1) else { continue }
            let displayed = view.convert(p.bounds(for:.cropBox),from:p)
            for rect in note.rects {
                let bounds = view.convert(PDFCoordinates.expand(rect,in:displayed,isFlipped:view.isFlipped),to:p)
                let a = PDFAnnotation(bounds:bounds,forType:.highlight,withProperties:nil)
                a.color = NSColor.systemYellow.withAlphaComponent(0.28); a.contents = note.body
                p.addAnnotation(a); highlights.append((p,a))
            }
        }
    }
}

struct NativePDF: NSViewRepresentable {
    var url:URL
    var sha:String
    var notes:[PaperNote]
    var initialPage:Int
    @ObservedObject var controller:PDFController
    func makeNSView(context:Context) -> PDFView {
        let view = PDFView(); view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor; view.autoScales = true
        view.setAccessibilityLabel("论文 PDF 原文")
        controller.attach(view); return view
    }
    func updateNSView(_ view:PDFView,context:Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url:url); view.autoScales = true; controller.sha = sha
            DispatchQueue.main.async { controller.go(initialPage); controller.annotate(notes,force:true); controller.update() }
        } else { DispatchQueue.main.async { controller.annotate(notes) } }
    }
    static func dismantleNSView(_ view:PDFView,coordinator:()) { view.document = nil }
}

struct PDFTools: View {
    @ObservedObject var controller:PDFController
    var addNote:()->Void
    var body:some View {
        HStack(spacing:10) {
            IconButton(title:"上一页",symbol:"chevron.up") { controller.go(controller.page-1) }.disabled(controller.page <= 1)
            Text("\(controller.page) / \(controller.pageCount)").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(minWidth:55)
            IconButton(title:"下一页",symbol:"chevron.down") { controller.go(controller.page+1) }.disabled(controller.page >= controller.pageCount)
            Divider().frame(height:16)
            IconButton(title:"缩小",symbol:"minus.magnifyingglass") { controller.zoom(-1) }
            IconButton(title:"放大",symbol:"plus.magnifyingglass") { controller.zoom(1) }
            IconButton(title:"适合窗口",symbol:"arrow.up.left.and.arrow.down.right") { controller.fit() }
            Spacer(minLength:8)
            TextField("查找原文",text:$controller.search).textFieldStyle(.roundedBorder).frame(maxWidth:160).onSubmit { controller.findNext() }
            IconButton(title:"为所选文字添加笔记",symbol:"square.and.pencil",action:addNote).disabled(controller.selection == nil)
        }.buttonStyle(.borderless).padding(.horizontal,14).padding(.vertical,9).background(.bar)
    }
}
