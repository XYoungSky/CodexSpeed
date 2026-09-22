import AppKit

// Vector-first artwork. All bitmap sizes are rendered directly, never upscaled.
let output = CommandLine.arguments[1]
let fm = FileManager.default
let iconset = output + "/AppIcon.iconset"
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
func render(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:pixels, pixelsHigh:pixels, bitsPerSample:8, samplesPerPixel:4, hasAlpha:true, isPlanar:false, colorSpaceName:.deviceRGB, bytesPerRow:0, bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    let transform = AffineTransform(scale:CGFloat(pixels)/1024)
    (transform as NSAffineTransform).concat()
    let tile = NSBezierPath(roundedRect:NSRect(x:64,y:64,width:896,height:896),xRadius:202,yRadius:202)
    NSColor(srgbRed:0.075,green:0.12,blue:0.15,alpha:1).setFill(); tile.fill()
    NSColor(srgbRed:0.34,green:0.89,blue:0.75,alpha:1).setStroke()
    let arc = NSBezierPath()
    arc.appendArc(withCenter:NSPoint(x:512,y:465),radius:274,startAngle:215,endAngle:-35,clockwise:true)
    arc.lineWidth=76; arc.lineCapStyle = .round; arc.stroke()
    let needle = NSBezierPath()
    needle.move(to:NSPoint(x:448,y:401)); needle.line(to:NSPoint(x:636,y:589))
    needle.lineWidth=80; needle.lineCapStyle = .round; needle.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using:.png,properties:[:])!
}
for size in [16,32,128,256,512] {
    try render(size).write(to:URL(fileURLWithPath:iconset+"/icon_\(size)x\(size).png"))
    try render(size*2).write(to:URL(fileURLWithPath:iconset+"/icon_\(size)x\(size)@2x.png"))
}
try render(1024).write(to:URL(fileURLWithPath:output+"/AppIcon.png"))
// PNG-backed ICNS container avoids iconutil's dependency on host image services.
func bigEndian(_ value: Int) -> Data {
    var number = UInt32(value).bigEndian
    return withUnsafeBytes(of:&number) { Data($0) }
}
var chunks = Data()
for (type, size) in [("icp4",16),("icp5",32),("icp6",64),("ic07",128),("ic08",256),("ic09",512),("ic10",1024),("ic11",32),("ic12",64),("ic13",256),("ic14",512)] {
    let png = render(size)
    chunks.append(Data(type.utf8)); chunks.append(bigEndian(png.count+8)); chunks.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(chunks.count+8)); icns.append(chunks)
try icns.write(to:URL(fileURLWithPath:output+"/AppIcon.icns"))
