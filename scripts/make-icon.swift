import AppKit
let directory = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
for size in [16,32,64,128,256,512,1024] {
    let image = NSImage(size:NSSize(width:size,height:size))
    image.lockFocus()
    let scale = CGFloat(size)/1024
    let transform = NSAffineTransform();transform.scale(by:scale);transform.concat()
    let bounds = NSRect(x:64,y:64,width:896,height:896)
    let path = NSBezierPath(roundedRect:bounds,xRadius:200,yRadius:200)
    let gradient = NSGradient(starting:NSColor(calibratedRed:0.16,green:0.36,blue:0.48,alpha:1),ending:NSColor(calibratedRed:0.07,green:0.20,blue:0.31,alpha:1))!
    gradient.draw(in:path,angle:-70)
    NSColor.white.withAlphaComponent(0.12).setStroke();path.lineWidth = 5;path.stroke()
    let config = NSImage.SymbolConfiguration(pointSize:430,weight:.light)
    if let symbol = NSImage(systemSymbolName:"books.vertical",accessibilityDescription:nil)?.withSymbolConfiguration(config) {
        symbol.isTemplate = false
        let glyph = NSImage(size:symbol.size);glyph.lockFocus();symbol.draw(at:.zero,from:.zero,operation:.sourceOver,fraction:1)
        NSColor.white.setFill();NSRect(origin:.zero,size:symbol.size).fill(using:.sourceAtop);glyph.unlockFocus()
        let ratio = min(500/symbol.size.width,500/symbol.size.height)
        let s = NSSize(width:symbol.size.width*ratio,height:symbol.size.height*ratio)
        glyph.draw(in:NSRect(x:(1024-s.width)/2,y:(1024-s.height)/2,width:s.width,height:s.height))
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
    let data = bitmap.representation(using:.png,properties:[:])!
    let names:[String]
    switch size {
    case 16:names = ["icon_16x16.png"]
    case 32:names = ["icon_16x16@2x.png","icon_32x32.png"]
    case 64:names = ["icon_32x32@2x.png"]
    case 128:names = ["icon_128x128.png"]
    case 256:names = ["icon_128x128@2x.png","icon_256x256.png"]
    case 512:names = ["icon_256x256@2x.png","icon_512x512.png"]
    default:names = ["icon_512x512@2x.png"]
    }
    for name in names {try data.write(to:directory.appendingPathComponent(name))}
}
