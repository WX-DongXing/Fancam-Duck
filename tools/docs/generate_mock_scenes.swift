// Generates documentation diagrams from geometric primitives; no source photographs.
// swift -module-cache-path /tmp/fancamduck-doc-module-cache tools/docs/generate_mock_scenes.swift
import AppKit
let folder=URL(fileURLWithPath:CommandLine.arguments.count>1 ? CommandLine.arguments[1] : "docs/design-assets")
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
func color(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat,_ a:CGFloat=1)->NSColor {NSColor(srgbRed:r,green:g,blue:b,alpha:a)}
let ink=color(0.12,0.16,0.18), gold=color(1,0.8,0.24)
func rect(_ r:NSRect,_ c:NSColor,_ radius:CGFloat=0) {c.setFill();NSBezierPath(roundedRect:r,xRadius:radius,yRadius:radius).fill()}
func line(_ points:[NSPoint],_ c:NSColor,_ width:CGFloat) {let p=NSBezierPath();p.move(to:points[0]);for a in points.dropFirst(){p.line(to:a)};p.lineWidth=width;p.lineCapStyle = .round;p.lineJoinStyle = .round;c.setStroke();p.stroke()}
func text(_ s:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ c:NSColor) {(s as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:.medium),.foregroundColor:c])}
for style in ["baseline","face-frosted","face-mosaic","face-image","person-frosted","person-mosaic","person-image"] {
 let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1200,pixelsHigh:720,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
 rect(NSRect(x:0,y:0,width:1200,height:720),color(0.12,0.22,0.24))
 rect(NSRect(x:0,y:0,width:1200,height:195),color(0.44,0.48,0.43))
 for x in stride(from:40,through:1160,by:224) {let p=NSBezierPath(rect:NSRect(x:x,y:220,width:200,height:400));color(1,1,1,0.10).setStroke();p.lineWidth=2;p.stroke()}
 for y in stride(from:25,through:180,by:34) {line([NSPoint(x:0,y:y),NSPoint(x:1200,y:y)],color(1,1,1,0.1),1)}
 for i in 0..<5 {
  let x=CGFloat(140+i*230),y:CGFloat = i%2==0 ? 195 : 210
  let shirts=[color(0.77,0.79,0.70),color(0.61,0.69,0.69),color(0.42,0.68,0.57),color(0.67,0.64,0.57),color(0.62,0.70,0.76)]
  line([NSPoint(x:x-13,y:y+140),NSPoint(x:x-44,y:y+70),NSPoint(x:x-69,y:y)],ink,29)
  line([NSPoint(x:x+13,y:y+140),NSPoint(x:x+48,y:y+70),NSPoint(x:x+75,y:y)],ink,29)
  line([NSPoint(x:x-77,y:y),NSPoint(x:x-54,y:y)],color(0.90,0.91,0.87),13)
  line([NSPoint(x:x+65,y:y),NSPoint(x:x+90,y:y)],color(0.90,0.91,0.87),13)
  rect(NSRect(x:x-37,y:y+138,width:74,height:143),shirts[i],12)
  line([NSPoint(x:x-24,y:y+265),NSPoint(x:x-80,y:y+215),NSPoint(x:x-114,y:y+274)],shirts[i],26)
  line([NSPoint(x:x+25,y:y+265),NSPoint(x:x+77,y:y+236),NSPoint(x:x+107,y:y+286)],shirts[i],26)
  color(0.75,0.64,0.53).setFill();NSBezierPath(ovalIn:NSRect(x:x-26,y:y+290,width:52,height:72)).fill()
  rect(NSRect(x:x-30,y:y+342,width:60,height:21),ink,11)
  if i==2 {
   let p=NSBezierPath(roundedRect:NSRect(x:x-112,y:y-23,width:224,height:410),xRadius:16,yRadius:16);gold.setStroke();p.lineWidth=3;p.stroke()
   rect(NSRect(x:x-45,y:y+397,width:90,height:36),gold,12);text("主角",x-24,y+404,21,ink)
  } else if style != "baseline" {
   let r = style.hasPrefix("face") ? NSRect(x:x-39,y:y+282,width:78,height:91) : NSRect(x:x-107,y:y-12,width:214,height:393)
   if style.hasSuffix("frosted") {
    rect(r,color(0.69,0.79,0.80,0.94),14)
    rect(NSRect(x:r.minX+4,y:r.maxY-5,width:r.width-8,height:2),color(1,1,1,0.6),1)
   } else if style.hasSuffix("mosaic") {
    let step:CGFloat=style.hasPrefix("face") ? 18 : 30
    for row in 0..<Int(ceil(r.height/step)) {for col in 0..<Int(ceil(r.width/step)) {let c=CGFloat((row*7+col*3+i)%5)/12;rect(NSRect(x:r.minX+CGFloat(col)*step,y:r.minY+CGFloat(row)*step,width:min(step,r.width-CGFloat(col)*step),height:min(step,r.height-CGFloat(row)*step)),color(0.34+c,0.42+c,0.43+c))}}
   } else {
    rect(r,color(0.42,0.42,0.80),14)
    let cx=r.midX,cy=r.midY
    color(1,1,1,0.95).setFill()
    NSBezierPath(ovalIn:NSRect(x:cx-19,y:cy+10,width:9,height:9)).fill();NSBezierPath(ovalIn:NSRect(x:cx+10,y:cy+10,width:9,height:9)).fill()
    line([NSPoint(x:cx-18,y:cy-8),NSPoint(x:cx,y:cy-18),NSPoint(x:cx+18,y:cy-8)],color(1,1,1),5)
   }
  }
 }
 rect(NSRect(x:24,y:654,width:178,height:40),color(0.05,0.1,0.12,0.8),12);text("模拟人物示意",42,664,21,color(0.87,0.93,0.92))
 text("FANCAM DUCK  /  DESIGN SAMPLE",25,24,17,color(0.85,0.90,0.88))
 NSGraphicsContext.restoreGraphicsState()
 try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(style+".png"))
 try bitmap.representation(using:.jpeg,properties:[.compressionFactor:0.9])!.write(to:folder.appendingPathComponent(style+".jpg"))
}
