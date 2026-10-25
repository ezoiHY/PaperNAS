import SwiftUI
import AppKit

@main
struct PaperNASApp: App {
    @StateObject private var app = AppModel()
    @AppStorage("appearance") private var appearance = "system"
    @FocusedValue(\.librarySearch) private var librarySearch
    private func applyAppearance() {
        // Apply the same appearance to native controls and SwiftUI across every
        // window. Per-window overrides can leave Form controls in the previous
        // theme when switching back to the system appearance.
        NSApplication.shared.appearance = switch appearance {
        case "light": NSAppearance(named:.aqua)
        case "dark": NSAppearance(named:.darkAqua)
        default: nil
        }
    }
    var body: some Scene {
        WindowGroup {
            WorkspaceView().environmentObject(app)
                .onChange(of:appearance,initial:true) {applyAppearance()}
                .task { await app.start() }
        }
        .defaultSize(width:1360,height:880)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after:.newItem) {
                Button("添加论文…") { app.showAdd = true }.keyboardShortcut("n",modifiers:[.command,.shift]).disabled(app.api == nil)
            }
            CommandGroup(after:.toolbar) {
                Button("搜索论文") {librarySearch?.focus()}.keyboardShortcut("f").disabled(librarySearch == nil)
                Button("刷新论文库") { Task { await app.refresh(); app.change += 1 } }.keyboardShortcut("r")
                Button("连接服务器…") { app.showConnection = true }.keyboardShortcut("l",modifiers:[.command,.shift])
            }
        }
        WindowGroup("阅读",id:"paper",for:String.self) { $key in
            if let key { ReaderView(key:key).environmentObject(app).frame(minWidth:700,minHeight:500) }
        }.defaultSize(width:1050,height:850)
        Settings {
            Group {if app.isV2 {ResearchPreferencesView()} else {PreferencesView()}}
                .environmentObject(app)
                .onChange(of:appearance,initial:true) {applyAppearance()}
        }
    }
}
