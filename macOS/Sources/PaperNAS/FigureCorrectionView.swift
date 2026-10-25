import SwiftUI
import AppKit

struct FigureCorrectionView:View {
    @EnvironmentObject private var app:AppModel
    @Environment(\.dismiss) private var dismiss
    let workID:String
    let figure:JSON
    @ViewState private var page = 1
    @ViewState private var pageCount = 500
    @ViewState private var pageSize = CGSize(width:612,height:792)
    @ViewState private var image:NSImage?
    @ViewState private var region = CGRect.zero
    @ViewState private var loading = false
    @ViewState private var busy = false
    @ViewState private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Text("调整 " + figure["label"].text + " 的范围").font(.title2.weight(.semibold));Spacer();Stepper("第 \(page) 页",value:$page,in:1...max(1,pageCount)).fixedSize()}
            Text("在原文页面上拖出包含完整图表及所有子图的区域，也可以编辑下方百分比。图注保持独立保存。").font(.callout).foregroundStyle(.secondary)
            GeometryReader {geometry in
                let fitted = fit(in:geometry.size)
                ZStack(alignment:.topLeading) {
                    Color(nsColor:.underPageBackgroundColor)
                    if let image {
                        Image(nsImage:image).resizable().frame(width:fitted.width,height:fitted.height).position(x:fitted.midX,y:fitted.midY).accessibilityLabel("第 \(page) 页原文预览")
                        if region.width > 0 && region.height > 0 {
                            Rectangle().fill(Color.accentColor.opacity(0.12)).overlay(Rectangle().stroke(Color.accentColor,lineWidth:2))
                                .frame(width:region.width*fitted.width,height:region.height*fitted.height)
                                .position(x:fitted.minX+region.midX*fitted.width,y:fitted.minY+region.midY*fitted.height).allowsHitTesting(false)
                        }
                    }
                    if loading {ProgressView().frame(width:geometry.size.width,height:geometry.size.height)}
                }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:2).onChanged {value in
                    guard !loading,image != nil else {return}
                    let start = normalized(value.startLocation,in:fitted),end = normalized(value.location,in:fitted)
                    region = CGRect(x:min(start.x,end.x),y:min(start.y,end.y),width:abs(end.x-start.x),height:abs(end.y-start.y))
                })
            }.frame(minHeight:410).clipShape(RoundedRectangle(cornerRadius:8))
            HStack(spacing:14) {
                coordinate("左",\.origin.x);coordinate("上",\.origin.y);coordinate("宽",\.size.width);coordinate("高",\.size.height)
                Button("整页") {region = CGRect(x:0,y:0,width:1,height:1)}
            }.font(.caption)
            if let error {InlineError(message:error)}
            HStack {Button("取消") {dismiss()}.keyboardShortcut(.cancelAction);Spacer();if busy {ProgressView().controlSize(.small)};Button("保存图表范围") {Task {await save()}}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy || loading || region.width*pageSize.width < 8 || region.height*pageSize.height < 8 || region.maxX > 1.001 || region.maxY > 1.001)}
        }.padding(24).frame(width:780,height:740)
            .onAppear {page = max(1,figure["page"].int)}
            .task(id:page) {await load()}
    }
    private func fit(in size:CGSize)->CGRect {
        let scale = min(size.width/pageSize.width,size.height/pageSize.height)
        let width = pageSize.width*scale,height = pageSize.height*scale
        return CGRect(x:(size.width-width)/2,y:(size.height-height)/2,width:width,height:height)
    }
    private func normalized(_ point:CGPoint,in frame:CGRect)->CGPoint {
        CGPoint(x:min(1,max(0,(point.x-frame.minX)/frame.width)),y:min(1,max(0,(point.y-frame.minY)/frame.height)))
    }
    private func coordinate(_ label:String,_ path:WritableKeyPath<CGRect,CGFloat>)->some View {
        HStack(spacing:4) {Text(label);TextField(label,text:Binding(get:{String(format:"%.1f",Double(region[keyPath:path])*100)},set:{if let value = Double($0),value.isFinite,(0...100).contains(value) {region[keyPath:path] = CGFloat(value/100)}})).textFieldStyle(.roundedBorder).frame(width:55);Text("%").foregroundStyle(.secondary)}
    }
    private func load() async {
        let requested = page
        loading = true;error = nil
        defer {if page == requested && !Task.isCancelled {loading = false}}
        do {
            guard let api = app.api else {return}
            let preview = try await app.request("figures/\(figure["id"].text)/page-preview",query:["page":String(requested)])
            let bytes = try await api.data(preview["asset_url"].text)
            guard page == requested,!Task.isCancelled else {return}
            error = nil
            pageCount = preview["page_count"].int;pageSize = CGSize(width:preview["width"].double,height:preview["height"].double);image = NSImage(data:bytes)
            let box = figure["bbox"]
            if requested == figure["page"].int,!box["x1"].isNull {
                region = CGRect(x:box["x0"].double/pageSize.width,y:box["y0"].double/pageSize.height,width:(box["x1"].double-box["x0"].double)/pageSize.width,height:(box["y1"].double-box["y0"].double)/pageSize.height)
            } else {region = .zero}
        } catch {
            guard page == requested,!Task.isCancelled,!(error is CancellationError),
                  (error as NSError).code != NSURLErrorCancelled else {return}
            self.error = error.localizedDescription
        }
    }
    private func save() async {
        busy = true;defer {busy = false}
        let bbox:JSON = .object(["x0":.number(region.minX*pageSize.width),"y0":.number(region.minY*pageSize.height),"x1":.number(region.maxX*pageSize.width),"y1":.number(region.maxY*pageSize.height)])
        do {_ = try await app.request("operations",method:"POST",body:.object(["kind":.string("repair_figure"),"figure_id":figure["id"],"figure_page":.integer(page),"bbox":bbox]));app.change += 1;app.notify("图表调整已提交");dismiss()}
        catch {self.error = error.localizedDescription}
    }
}
