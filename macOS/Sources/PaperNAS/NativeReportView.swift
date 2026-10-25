import SwiftUI
import AppKit

private struct ReadingPositions:PreferenceKey {
    static var defaultValue:[String:Double] = [:]
    static func reduce(value:inout [String:Double],nextValue:()->[String:Double]) {value.merge(nextValue(),uniquingKeysWith:{$1})}
}

struct NativeReportView:View {
    @Environment(\.readingTypography) private var typography
    let paper:Paper
    let depth:ReadingDepth
    @Binding var showContents:Bool
    let navigate:(String)->Void
    @ViewState private var activeSection = ""
    @ViewState private var progress = 0.0
    @ViewState private var showEvidence = false
    @ViewState private var showChecks = false
    @ViewState private var selectedClaim:ReadingClaim?
    @ViewState private var scrollController = ReadingScrollController()
    private var content:ReadingContent {ReadingContent(paper:paper,depth:depth)}

    var body:some View {
        let reading = content
        GeometryReader { geometry in
            let compact = geometry.size.width < 720
            let hasSidebar = showContents && !compact
            let textSpace = min(typography.textWidth,geometry.size.width - (hasSidebar ? 193 : 0) - 64)
            let reflowKey = ReadingScrollController.ReflowKey(typography:typography,width:geometry.size.width,hasSidebar:hasSidebar)
            HStack(spacing:0) {
                if hasSidebar {
                    contents(reading).frame(width:192)
                    Divider()
                }
                VStack(spacing:0) {
                    ScrollView {
                        VStack(spacing:0) {
                            Color.clear.frame(height:0)
                                .background(ReadingScrollAnchor(id:"top",controller:scrollController))
                                .background(GeometryReader { marker in
                                    Color.clear.preference(key:ReadingPositions.self,value:["__top":Double(marker.frame(in:.named("native-report-scroll")).minY)])
                                })
                            masthead(reading).padding(.bottom,56)
                            if !reading.summary.isEmpty {
                                readingSummary(reading).padding(.bottom,58)
                            }
                            ForEach(Array(reading.sections.enumerated()),id:\.element.id) { index,section in
                                sectionBody(section,index:index,reading:reading,compact:textSpace < 560)
                                    .padding(.bottom,68)
                                    .background(ReadingScrollAnchor(id:section.id,controller:scrollController))
                                    .background(GeometryReader { marker in
                                        Color.clear.preference(key:ReadingPositions.self,value:[section.id:Double(marker.frame(in:.named("native-report-scroll")).minY)])
                                    })
                            }
                            if reading.sections.isEmpty && reading.summary.isEmpty {
                                EmptyState(symbol:"text.book.closed",title:"暂无可读内容",detail:"可从论文操作菜单重新生成解读。")
                            }
                            if !reading.evidence.isEmpty || !reading.checks.isEmpty {
                                VStack(spacing:20) {
                                    Rectangle().fill(Color(nsColor:.separatorColor)).frame(width:48,height:1)
                                    HStack(spacing:24) {
                                        if !reading.evidence.isEmpty {Button {showEvidence = true} label:{Label("全部原文引用",systemImage:"quote.bubble")}}
                                        if !reading.checks.isEmpty {Button {showChecks = true} label:{Label("结论核对",systemImage:"checkmark.shield")}}
                                    }.buttonStyle(.borderless).font(.callout).foregroundStyle(.secondary)
                                }.padding(.top,4)
                            }
                        }
                        .frame(maxWidth:typography.figureWidth)
                        .padding(.horizontal,32).padding(.top,46).padding(.bottom,64)
                        .frame(maxWidth:.infinity)
                        .background(GeometryReader { marker in
                            Color.clear.preference(key:ReadingPositions.self,value:["__bottom":Double(marker.frame(in:.named("native-report-scroll")).maxY)])
                        })
                    }
                    .coordinateSpace(name:"native-report-scroll")
                    .background(GeometryReader { viewport in
                        Color.clear.preference(key:ReadingPositions.self,value:["__viewport":Double(viewport.size.height)])
                    })
                    .onPreferenceChange(ReadingPositions.self) { positions in
                        let top = (positions["__top"] ?? 46) - 46
                        let bottom = positions["__bottom"] ?? 0
                        let viewport = positions["__viewport"] ?? 0
                        let distance = bottom - top - viewport
                        let scrolls = distance > 2
                        let atBottom = scrolls && bottom <= viewport + 2
                        let current = atBottom ? reading.sections.last?.id : ReadingContent.activeSection(positions,ordered:reading.sections.map(\.id))
                        if let current,current != activeSection {activeSection = current}
                        let nextProgress = scrolls ? min(1,max(0,-top / distance)) : 0
                        if abs(nextProgress - progress) > 0.002 {progress = nextProgress}
                        if viewport > 0 {scrollController.recordPosition(for:reflowKey)}
                    }
                    .onChange(of:depth) { _,_ in
                        activeSection = reading.sections.first?.id ?? ""
                        DispatchQueue.main.async {scrollController.scroll(to:"top")}
                    }
                    .onChange(of:reflowKey) { _,key in preserveReadingPosition(for:key) }
                    .accessibilityLabel(depth == .brief ? "初读内容" : "精读内容")
                    readingFooter(reading,compact:compact)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .onAppear {activeSection = reading.sections.first?.id ?? ""}
        .sheet(isPresented:$showEvidence) {
            ReadingEvidenceSheet(evidence:reading.evidence,paper:paper,navigate:navigate)
        }
        .sheet(isPresented:$showChecks) {AuditView(paper:paper)}
        .sheet(item:$selectedClaim) { claim in
            ReadingEvidenceSheet(evidence:reading.evidence(for:claim),check:reading.check(for:claim),paper:paper,navigate:navigate)
        }
    }

    private func masthead(_ reading:ReadingContent)->some View {
        VStack(spacing:20) {
            HStack(spacing:10) {
                Text(depth.title).foregroundStyle(Color.accentColor)
                if !paper.venue.isEmpty {Text("·");Text(paper.venue)}
                if !paper.date.isEmpty {Text("·");Text(paper.date)}
            }.font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
            Text(paper.title)
                .font(.system(size:typography.bodySize + 15,weight:.semibold,design:.serif))
                .multilineTextAlignment(.center).lineSpacing(4)
                .fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if !paper.byline.isEmpty {
                Text(paper.byline).font(.system(size:12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
            }
            if reading.summary.isEmpty {scopeLabel(reading).padding(.top,2)}
        }.frame(maxWidth:typography.textWidth + 60)
    }

    private func readingSummary(_ reading:ReadingContent)->some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:8) {
                Image(systemName:"text.book.closed")
                Text("阅读提要").tracking(1)
            }.font(.system(size:11,weight:.semibold)).foregroundStyle(Color.accentColor)
            NativeReadingText(text:reading.summary,size:typography.bodySize + 2)
            scopeLabel(reading).padding(.top,2)
        }
        .padding(.vertical,24).padding(.horizontal,26)
        .frame(maxWidth:typography.textWidth)
        .background(Color.accentColor.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
        .overlay(alignment:.leading) {RoundedRectangle(cornerRadius:1).fill(Color.accentColor.opacity(0.5)).frame(width:2).padding(.vertical,25)}
    }

    private func contents(_ reading:ReadingContent)->some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("目录").font(.system(size:17,weight:.medium,design:.serif))
                Spacer()
                IconButton(title:"隐藏章节目录",symbol:"sidebar.left") {showContents = false}
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }.padding(.horizontal,20).padding(.top,28).padding(.bottom,18)
            ScrollViewReader { directory in
                ScrollView {
                    VStack(spacing:4) {
                        ForEach(Array(reading.sections.enumerated()),id:\.element.id) { index,section in
                            Button {select(section.id)} label:{
                                HStack(spacing:11) {
                                    Text(String(format:"%02d",index+1)).font(.system(size:10,weight:.medium,design:.monospaced))
                                        .foregroundStyle(activeSection == section.id ? Color.accentColor : Color.secondary)
                                        .frame(width:20).accessibilityHidden(true)
                                    Text(section.title).font(.system(size:13,weight:activeSection == section.id ? .medium : .regular)).multilineTextAlignment(.leading)
                                    Spacer(minLength:0)
                                }.padding(.horizontal,10).padding(.vertical,11).frame(maxWidth:.infinity,alignment:.leading)
                                    .contentShape(RoundedRectangle(cornerRadius:7))
                            }
                            .buttonStyle(ReadingOutlineButtonStyle(selected:activeSection == section.id))
                            .accessibilityLabel("章节：\(section.title)")
                            .accessibilityValue(activeSection == section.id ? "正在阅读" : "")
                            .id("outline-" + section.id)
                        }
                    }.padding(.horizontal,10).padding(.bottom,14)
                }
                .onChange(of:activeSection) { _,id in directory.scrollTo("outline-" + id) }
            }
            Spacer(minLength:0)
            if !reading.evidence.isEmpty || !reading.checks.isEmpty {
                HStack(spacing:18) {
                    if !reading.evidence.isEmpty {IconButton(title:"全部原文引用",symbol:"quote.bubble") {showEvidence = true}}
                    if !reading.checks.isEmpty {IconButton(title:"结论核对",symbol:"checkmark.shield") {showChecks = true}}
                    Spacer()
                }.buttonStyle(.borderless).foregroundStyle(.secondary).padding(20)
            }
        }.background(Color(nsColor:.windowBackgroundColor))
    }

    private func readingFooter(_ reading:ReadingContent,compact:Bool)->some View {
        let index = reading.sections.firstIndex{$0.id == activeSection} ?? 0
        return VStack(spacing:0) {
            GeometryReader { line in
                Rectangle().fill(Color(nsColor:.separatorColor).opacity(0.5))
                Rectangle().fill(Color.accentColor.opacity(0.7)).frame(width:line.size.width * progress)
            }.frame(height:1)
            HStack(spacing:14) {
                Menu {
                    Button("回到开篇") {scrollController.scroll(to:"top")}
                    Divider()
                    ForEach(Array(reading.sections.enumerated()),id:\.element.id) { offset,section in
                        Button("\(String(format:"%02d",offset+1))  \(section.title)") {select(section.id)}
                    }
                    Divider()
                    Toggle("显示侧栏目录",isOn:$showContents).disabled(compact)
                } label:{
                    HStack(spacing:8) {
                        Image(systemName:"list.bullet")
                        Text(reading.sections.first{$0.id == activeSection}?.title ?? "目录").lineLimit(1)
                    }.font(.caption).foregroundStyle(.secondary)
                }.menuStyle(.borderlessButton).fixedSize().help("跳转章节或显示目录").accessibilityLabel("章节导航")
                Spacer(minLength:8)
                if !reading.sections.isEmpty {
                    Button {select(reading.sections[max(0,index-1)].id)} label:{Image(systemName:"chevron.left").frame(width:24,height:24)}
                        .disabled(index == 0).help("上一章").accessibilityLabel("上一章")
                    Text("\(index+1) / \(reading.sections.count)").font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
                        .accessibilityLabel("第 \(index+1) 章，共 \(reading.sections.count) 章")
                    Button {select(reading.sections[min(reading.sections.count-1,index+1)].id)} label:{Image(systemName:"chevron.right").frame(width:24,height:24)}
                        .disabled(index == reading.sections.count-1).help("下一章").accessibilityLabel("下一章")
                }
            }.buttonStyle(.borderless).padding(.horizontal,22).frame(height:42)
        }.background(Color(nsColor:.windowBackgroundColor))
    }

    @ViewBuilder private func scopeLabel(_ reading:ReadingContent)->some View {
        let scope = reading.metadata["scope"].text.isEmpty ? paper.raw["document"]["scope"].text : reading.metadata["scope"].text
        if scope == "abstract_only" || scope == "partial_text" {
            Label(scope == "abstract_only" ? "基于摘要" : "基于部分原文",systemImage:"doc.text.magnifyingglass").font(.caption).foregroundStyle(.secondary)
        } else if depth == .brief,!scope.isEmpty,scope != "main_text" {
            Label(scope.replacingOccurrences(of:"初读 · ",with:""),systemImage:"doc.text.magnifyingglass")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }

    private func sectionBody(_ section:ReadingSection,index:Int,reading:ReadingContent,compact:Bool)->some View {
        VStack(spacing:32) {
            VStack(spacing:12) {
                HStack(spacing:12) {
                    Rectangle().fill(Color(nsColor:.separatorColor)).frame(width:32,height:0.5)
                    Text(String(format:"%02d",index+1)).font(.system(size:11,weight:.medium,design:.monospaced)).foregroundStyle(.secondary)
                    Rectangle().fill(Color(nsColor:.separatorColor)).frame(width:32,height:0.5)
                }.accessibilityHidden(true)
                Text(section.title).font(typography.font(size:typography.bodySize+9,weight:.semibold)).tracking(1)
                    .multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).accessibilityAddTraits(.isHeader)
            }.frame(maxWidth:typography.textWidth).padding(.top,8).padding(.bottom,2)
            ForEach(section.groups) { group in
                if section.id == "data_sources" {
                    dataGroup(group,section:section,reading:reading,compact:compact)
                } else {
                    VStack(spacing:28) {
                        if !group.title.isEmpty {
                            HStack(alignment:.top,spacing:12) {
                                if section.id == "questions" {Image(systemName:"questionmark.circle").font(.system(size:17)).foregroundStyle(Color.accentColor).padding(.top,3)}
                                Text(group.title).font(typography.font(size:typography.bodySize+3,weight:.semibold))
                                    .fixedSize(horizontal:false,vertical:true).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                            }.frame(maxWidth:typography.textWidth,alignment:.leading)
                        }
                        ForEach(Array(group.claims.enumerated()),id:\.element.id) { offset,claim in
                            VStack(spacing:28) {
                                claimView(claim,reading:reading,lead:section.id == "overview" && offset == 0)
                                    .frame(maxWidth:typography.textWidth,alignment:.leading)
                                    .overlay(alignment:.topLeading) {
                                        if ["contributions","strengths","limitations"].contains(section.id) {
                                            Text(String(format:"%02d",offset+1)).font(.system(size:11,weight:.medium,design:.monospaced))
                                                .foregroundStyle(Color.accentColor.opacity(0.7)).frame(width:24,alignment:.leading)
                                                .offset(x:-30,y:5).accessibilityHidden(true)
                                        }
                                    }
                                ForEach(inlineFigures(after:claim,in:section),id:\.["id"].text) { figure in
                                    ReportFigureView(figure:figure).padding(.top,2).padding(.bottom,8)
                                }
                            }.background(ReadingScrollAnchor(id:"claim-"+claim.id,controller:scrollController))
                        }
                    }
                }
            }
        }.frame(maxWidth:.infinity)
    }

    private func dataGroup(_ group:ReadingGroup,section:ReadingSection,reading:ReadingContent,compact:Bool)->some View {
        VStack(alignment:.leading,spacing:22) {
            if !group.title.isEmpty {
                HStack(alignment:.top,spacing:10) {
                    Image(systemName:"cylinder.split.1x2").font(.system(size:15)).foregroundStyle(Color.accentColor).padding(.top,3)
                    Text(group.title).font(typography.font(size:typography.bodySize+3,weight:.semibold))
                        .textSelection(.enabled).fixedSize(horizontal:false,vertical:true).accessibilityAddTraits(.isHeader)
                }
            }
            ForEach(group.claims) { claim in
                VStack(alignment:.leading,spacing:16) {
                    if compact {
                        VStack(alignment:.leading,spacing:9) {
                            dataLabel(claim.label)
                            claimView(claim,reading:reading,showLabel:false)
                        }
                    } else {
                        HStack(alignment:.top,spacing:20) {
                            dataLabel(claim.label).frame(width:48,alignment:.leading).padding(.top,5)
                            claimView(claim,reading:reading,showLabel:false)
                        }
                    }
                    ForEach(inlineFigures(after:claim,in:section),id:\.["id"].text) { figure in ReportFigureView(figure:figure) }
                    if claim.id != group.claims.last?.id {Divider().opacity(0.5).padding(.top,3)}
                }.background(ReadingScrollAnchor(id:"claim-"+claim.id,controller:scrollController))
            }
        }.padding(24).frame(maxWidth:typography.textWidth,alignment:.leading)
            .background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(Color(nsColor:.separatorColor).opacity(0.35),lineWidth:0.5))
    }

    private func dataLabel(_ label:String)->some View {
        Text(label).font(.system(size:11,weight:.semibold)).tracking(1).foregroundStyle(.secondary)
    }
    private func claimView(_ claim:ReadingClaim,reading:ReadingContent,lead:Bool = false,showLabel:Bool = true)->some View {
        ReadingClaimView(claim:claim,evidence:reading.evidence(for:claim),check:reading.check(for:claim),showLabel:showLabel,fontSize:lead ? typography.bodySize+1 : nil) {selectedClaim = claim}
    }
    private func select(_ id:String) {activeSection = id;scrollController.scroll(to:id)}
    private func preserveReadingPosition(for key:ReadingScrollController.ReflowKey) {
        scrollController.preserveForReflow(to:key)
    }
    // Each figure stays after its first discussion in a chapter, preserving the
    // server's real associations, captions and citation order.
    private func inlineFigures(after claim:ReadingClaim,in section:ReadingSection)->[JSON] {
        let earlier = Set(section.claims.prefix(while:{$0.id != claim.id}).flatMap(\.figureIDs))
        var seen = earlier
        return claim.figureIDs.compactMap { id in
            guard seen.insert(id).inserted else {return nil}
            return paper.figures.first{$0["id"].text == id}
        }
    }
}

// Keep chapter jumps tied to the actual AppKit scroll view. SwiftUI's proxy can
// silently miss targets inside the eager report layout on macOS; these anchors
// resolve their enclosing scroll view without relying on private class names.
private final class ReadingScrollController {
    struct Bookmark {let id:String;let fraction:CGFloat}
    struct ReflowKey:Equatable {let typography:ReadingTypography;let width:CGFloat;let hasSidebar:Bool}
    private struct AnchorPosition {let id:String;let start:CGFloat}
    private struct Geometry {
        let scroll:NSScrollView
        let document:NSView
        let start:CGFloat
        let end:CGFloat
        let position:CGFloat
        let anchors:[AnchorPosition]
    }
    private static let frontMatter = "__frontmatter"
    private var anchors:[String:WeakReadingAnchor] = [:]
    private var currentReflowKey:ReflowKey?
    private var stableBookmark:Bookmark?
    private var pendingBookmark:Bookmark?
    private var pendingGeneration:UUID?
    private var inputMonitor:Any?

    func register(_ view:NSView,id:String) {anchors[id] = WeakReadingAnchor(view)}

    func recordPosition(for key:ReflowKey) {
        if currentReflowKey == nil {currentReflowKey = key}
        // A preference update can arrive after new typography has already laid
        // out. Keep the prior layout's bookmark until its reflow is restored.
        guard currentReflowKey == key,pendingGeneration == nil else {return}
        stableBookmark = bookmark()
    }

    func bookmark()->Bookmark? {
        guard let geometry = geometry() else {return nil}
        guard let item = geometry.anchors.last(where:{$0.start <= geometry.position}) else {
            // Title and summary occupy a real reading region. Do not substitute
            // the first claim when the reader is still above the first chapter.
            let end = geometry.anchors.first?.start ?? geometry.end
            return Bookmark(id:Self.frontMatter,fraction:fraction(geometry.position,from:geometry.start,to:end))
        }
        // Chapter anchors cover headings; the interval up to the next anchor
        // includes paragraph spacing and figures, avoiding jumps across gaps.
        return Bookmark(id:item.id,fraction:fraction(geometry.position,from:item.start,to:rangeEnd(after:item,in:geometry)))
    }

    func restore(_ bookmark:Bookmark?) {
        guard let bookmark,let document = anchors["top"]?.view?.enclosingScrollView?.documentView else {return}
        document.layoutSubtreeIfNeeded()
        guard let geometry = geometry() else {return}
        let start:CGFloat,end:CGFloat
        if bookmark.id == Self.frontMatter {
            start = geometry.start
            end = geometry.anchors.first?.start ?? geometry.end
        } else {
            guard let item = geometry.anchors.first(where:{$0.id == bookmark.id}) else {return}
            start = item.start
            end = rangeEnd(after:item,in:geometry)
        }
        move(to:start + max(1,end-start) * bookmark.fraction,in:geometry)
    }

    func preserveForReflow(to key:ReflowKey) {
        currentReflowKey = key
        guard let bookmark = pendingBookmark ?? stableBookmark ?? bookmark(),let scroll = geometry()?.scroll else {return}
        cancelPreservation()
        pendingBookmark = bookmark
        let generation = UUID()
        pendingGeneration = generation
        // Local math fragments report new heights asynchronously. Retry for a
        // short, bounded settling window, and relinquish control on user input.
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching:[.scrollWheel,.leftMouseDown,.keyDown]) { [weak self,weak scroll] event in
            if let scroll,event.window === scroll.window {
                let inside = scroll.bounds.contains(scroll.convert(event.locationInWindow,from:nil))
                if event.type == .keyDown || inside {self?.cancelPreservation()}
            }
            return event
        }
        for delay in [0.0,0.08,0.22,0.5,0.8] {
            DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self] in
                guard let self,self.pendingGeneration == generation else {return}
                self.restore(bookmark)
                if delay == 0.8 {
                    self.cancelPreservation()
                    self.stableBookmark = self.bookmark()
                }
            }
        }
    }

    func scroll(to id:String) {
        cancelPreservation()
        guard let anchor = anchors[id]?.view,let scroll = anchor.enclosingScrollView,
              let document = scroll.documentView else {return}
        let clip = scroll.contentView
        let rect = anchor.convert(anchor.bounds,to:document)
        let y = id == "top" ? (document.isFlipped ? document.bounds.minY : document.bounds.maxY-clip.bounds.height) : (document.isFlipped ? rect.minY : rect.maxY - clip.bounds.height)
        let maximum = max(document.bounds.minY,document.bounds.maxY - clip.bounds.height)
        clip.scroll(to:NSPoint(x:clip.bounds.minX,y:min(maximum,max(document.bounds.minY,y))))
        scroll.reflectScrolledClipView(clip)
        stableBookmark = bookmark()
    }

    private func geometry()->Geometry? {
        guard let anchor = anchors["top"]?.view,let scroll = anchor.enclosingScrollView,
              let document = scroll.documentView else {return nil}
        let clip = scroll.contentView
        let positions = anchors.compactMap { id,weakAnchor -> AnchorPosition? in
            guard id != "top",let view = weakAnchor.view,view.enclosingScrollView === scroll else {return nil}
            let rect = view.convert(view.bounds,to:document)
            return AnchorPosition(id:id,start:document.isFlipped ? rect.minY : -rect.maxY)
        }.sorted {$0.start == $1.start ? $0.id < $1.id : $0.start < $1.start}
        return Geometry(scroll:scroll,document:document,
                        start:document.isFlipped ? document.bounds.minY : -document.bounds.maxY,
                        end:document.isFlipped ? document.bounds.maxY : -document.bounds.minY,
                        position:document.isFlipped ? clip.bounds.minY : -clip.bounds.maxY,
                        anchors:positions)
    }

    private func rangeEnd(after item:AnchorPosition,in geometry:Geometry)->CGFloat {
        geometry.anchors.first(where:{$0.start > item.start + 0.5})?.start ?? geometry.end
    }

    private func fraction(_ position:CGFloat,from start:CGFloat,to end:CGFloat)->CGFloat {
        min(1,max(0,(position-start)/max(1,end-start)))
    }

    private func move(to position:CGFloat,in geometry:Geometry) {
        let clip = geometry.scroll.contentView
        let document = geometry.document
        let y = document.isFlipped ? position : -position-clip.bounds.height
        let maximum = max(document.bounds.minY,document.bounds.maxY-clip.bounds.height)
        let clamped = min(maximum,max(document.bounds.minY,y))
        guard abs(clip.bounds.minY-clamped) > 0.5 else {return}
        clip.scroll(to:NSPoint(x:clip.bounds.minX,y:clamped))
        geometry.scroll.reflectScrolledClipView(clip)
    }

    private func cancelPreservation() {
        pendingGeneration = nil
        pendingBookmark = nil
        if let inputMonitor {NSEvent.removeMonitor(inputMonitor);self.inputMonitor = nil}
    }

    deinit {if let inputMonitor {NSEvent.removeMonitor(inputMonitor)}}
}

private final class WeakReadingAnchor {
    weak var view:NSView?
    init(_ view:NSView) {self.view = view}
}

private final class ReadingAnchorView:NSView {
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func isAccessibilityElement()->Bool {false}
}

private struct ReadingScrollAnchor:NSViewRepresentable {
    let id:String
    let controller:ReadingScrollController
    func makeNSView(context:Context)->NSView {
        let view = ReadingAnchorView()
        controller.register(view,id:id)
        return view
    }
    func updateNSView(_ view:NSView,context:Context) {controller.register(view,id:id)}
}

private struct ReadingOutlineButtonStyle:ButtonStyle {
    let selected:Bool
    func makeBody(configuration:Configuration)->some View {
        configuration.label
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.8))
            .background(selected ? Color.accentColor.opacity(0.12) : configuration.isPressed ? Color.primary.opacity(0.06) : .clear,in:RoundedRectangle(cornerRadius:6))
    }
}

struct NativeReadingText:View {
    @Environment(\.readingTypography) private var typography
    let text:String
    var size:CGFloat?
    var weight:Font.Weight = .regular
    static func attributed(_ text:String)->AttributedString {
        var result = (try? AttributedString(markdown:text,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in result.runs {
            if let link = run.link,
               !["https","http"].contains(link.scheme?.lowercased() ?? "") || (run.link != nil && (run.link?.host == nil || run.link?.user != nil || run.link?.password != nil)) {
                result[run.range].link = nil
            }
        }
        return result
    }
    var body:some View {
        let pointSize = size ?? typography.bodySize
        Group {
            if text.range(of:#"\$[^$]+\$|\\\(|\\\["#,options:.regularExpression) != nil {
                ReadingMathText(text:text,fontSize:pointSize)
            } else {
                Text(Self.attributed(text)).font(typography.font(size:pointSize,weight:weight))
                    .lineSpacing(typography.lineSpacing * pointSize / typography.bodySize).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
}

private struct ReadingClaimView:View {
    let claim:ReadingClaim
    let evidence:[JSON]
    let check:JSON?
    var showLabel = true
    var fontSize:CGFloat?
    let showReferences:()->Void
    private var status:String? {
        if check != nil {return "待核查"}
        return ["author_claim_only":"作者观点","inferred":"推断","not_stated":"原文未说明","conflicting":"证据不一致"][claim.status]
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            if showLabel,!claim.label.isEmpty {Text(claim.label).font(.caption.weight(.medium)).foregroundStyle(.secondary)}
            NativeReadingText(text:claim.text,size:fontSize)
            if !evidence.isEmpty || status != nil {
                HStack(spacing:10) {
                    if let status {
                        Label(status,systemImage:check != nil || claim.status == "conflicting" ? "exclamationmark.circle" : "info.circle")
                            .font(.system(size:11)).foregroundStyle(check != nil || claim.status == "conflicting" ? Color.orange : Color.secondary)
                    }
                    if !evidence.isEmpty || check != nil {
                        Button(action:showReferences) {
                            HStack(spacing:5) {Image(systemName:"quote.bubble");Text(evidence.isEmpty ? "核对说明" : "原文 \(evidence.count)").monospacedDigit()}
                                .padding(.horizontal,8).padding(.vertical,4)
                                .background(Color.primary.opacity(0.04),in:Capsule())
                        }.buttonStyle(.borderless).font(.system(size:10.5)).foregroundStyle(.secondary)
                            .help("查看原文引用与核对说明").accessibilityLabel(evidence.isEmpty ? "查看核对说明" : "查看 \(evidence.count) 处原文引用")
                    }
                    Spacer()
                }
            }
        }
    }
}

private struct ReadingReferences:View {
    let evidence:[JSON]
    var check:JSON?
    let paper:Paper
    let navigate:(String)->Void
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                if let check {
                    Label("核对说明",systemImage:"exclamationmark.circle").font(.headline).foregroundStyle(.orange)
                    Text(check["reason"].text).font(.callout).lineSpacing(4).textSelection(.enabled)
                    if !evidence.isEmpty {Divider()}
                }
                ForEach(evidence,id:\.["id"].text) { item in
                    VStack(alignment:.leading,spacing:9) {
                        let block = paper.blocks.first{$0["id"] == item["block_id"]}
                        HStack {
                            Text(block?["section"].text.isEmpty == false ? block!["section"].text : "原文引用").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Spacer()
                            if block != nil {Button {navigate(item["block_id"].text)} label:{Image(systemName:"arrow.up.right")}.buttonStyle(.borderless).help("在原文中定位").accessibilityLabel("在原文中定位引用")}
                        }
                        Text(item["quote"].text).font(.system(size:13)).lineSpacing(5).textSelection(.enabled)
                    }
                    if item["id"] != evidence.last?["id"] {Divider()}
                }
            }.padding(1)
        }.frame(maxHeight:440)
    }
}

private struct ReadingEvidenceSheet:View {
    @Environment(\.dismiss) var dismiss
    let evidence:[JSON]
    var check:JSON?
    let paper:Paper
    let navigate:(String)->Void
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Text("原文引用").font(.title2.weight(.semibold));Spacer();Button("完成") {dismiss()}.keyboardShortcut(.cancelAction)}
            ReadingReferences(evidence:evidence,check:check,paper:paper) {id in dismiss();navigate(id)}
                .frame(maxWidth:.infinity,maxHeight:.infinity)
        }.padding(26).frame(width:680,height:600)
    }
}

struct ReadingInfoView:View {
    let paper:Paper
    let depth:ReadingDepth
    @ViewState private var technical = false
    private var source:JSON {depth == .brief ? paper.raw["brief"] : paper.raw["report"]}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("论文信息").font(.headline)
            Form {
                LabeledContent("来源",value:paper.venue)
                LabeledContent("日期",value:paper.date)
                if let url = paper.sourceURL {LabeledContent("原文") {Link("论文主页",destination:url)}}
                if !paper.authors.isEmpty {DisclosureGroup("作者") {Text(paper.authors.joined(separator:", ")).font(.callout).textSelection(.enabled)}}
                if !source["model"].text.isEmpty {LabeledContent("分析模型",value:source["model"].text)}
                if !source["generated_at"].text.isEmpty {LabeledContent("生成日期",value:String(source["generated_at"].text.prefix(10)))}
                if !source["scope"].text.isEmpty {LabeledContent("材料范围",value:source["scope"].text)}
                if !source["explanation"].text.isEmpty {DisclosureGroup("生成概述") {NativeReadingText(text:source["explanation"].text,size:13)}}
                if !source["warnings"].values.isEmpty {
                    DisclosureGroup("材料与核对说明") {ForEach(Array(source["warnings"].values.enumerated()),id:\.offset) {_,value in Text(value.text).font(.caption).textSelection(.enabled)}}
                }
                DisclosureGroup("技术详情",isExpanded:$technical) {
                    Text([("解析器",paper.raw["document"]["parser"].text),("材料指纹",paper.raw["document"]["content_hash"].text),("阅读规范",source["skill_hash"].text)].filter{!$0.1.isEmpty}.map{"\($0.0)：\($0.1)"}.joined(separator:"\n\n"))
                        .font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }.padding(18).frame(width:390,height:480)
    }
}
