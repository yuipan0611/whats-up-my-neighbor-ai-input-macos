import AppKit
import Foundation

@main enum ExportCatAssets {
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let output=root.appendingPathComponent("windows-lite/NekoChat.Windows/Assets")
        let source=root.appendingPathComponent("Resources/DesktopPet/sit.svg")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for id in CatAppearance.presetIDs {
            let painter=CatAppearanceArtwork(CatAppearance.makePreset(id)!)
            let image=painter.desktopImage(at:source,asset:"sit")!
            let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
            let bitmap=NSBitmapImageRep(cgImage:cg)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(id+".png"))
        }
        // Same trusted path markers as CatAppearanceArtwork.desktopImage.
        var mask=try String(contentsOf:source,encoding:.utf8)
        let regex=try NSRegularExpression(pattern:"<path\\b[^>]*?/>")
        for match in regex.matches(in:mask,range:NSRange(mask.startIndex...,in:mask)).reversed() {
            let tag=(mask as NSString).substring(with:match.range)
            guard tag.contains("fill=\"#101114\"") else {continue}
            let part:CatBodyPart=tag.contains("id=\"Vector\"") ? .tail : tag.contains("id=\"Vector_2\"") ? .body : tag.contains("id=\"Vector_4\"") ? .frontLeftPaw : tag.contains("id=\"Vector_5\"") ? .frontRightPaw : .head
            let index=CatBodyPart.allCases.firstIndex(of:part)!
            mask=(mask as NSString).replacingCharacters(in:match.range,with:tag.replacingOccurrences(of:"#101114",with:String(format:"#FF00%02X",(index+1)*14)))
        }
        let cg=NSImage(data:Data(mask.utf8))!.cgImage(forProposedRect:nil,context:nil,hints:nil)!
        let w=cg.width,h=cg.height
        var pixels=[UInt8](repeating:0,count:w*h*4)
        pixels.withUnsafeMutableBytes { bytes in
            let ctx=CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
        }
        var map=Data()
        func appendFloat(_ value:Float) { var v=value.bitPattern.littleEndian; withUnsafeBytes(of:&v){map.append(contentsOf:$0)} }
        for y in 0..<h { for x in 0..<w {
            let i=(y*w+x)*4,a=Double(pixels[i+3])/255
            var forced:CatBodyPart?
            if a>0 && Double(pixels[i])/a>245 && Double(pixels[i+1])/a<8 {
                let index=Int((Double(pixels[i+2])/a+7)/14)-1
                if CatBodyPart.allCases.indices.contains(index) {forced=CatBodyPart.allCases[index]}
            }
            let sample=CatAnatomy.sample(x:Double(x),y:Double(y),width:Double(w),height:Double(h),layout:.desktop("sit"),forcedPart:forced)
            map.append(UInt8(CatBodyPart.allCases.firstIndex(of:sample.part)!)); appendFloat(Float(sample.u)); appendFloat(Float(sample.v))
        }}
        try map.write(to:output.appendingPathComponent("anatomy.bin"))
        // Sample the exact native authored tabby masks, retaining antialiasing.
        let overrides=Dictionary(uniqueKeysWithValues:CatBodyPart.allCases.map {($0.rawValue,["color":"#000000","pattern":"tabby","patternColor":"#FFFFFF"])})
        let appearance=try CatAppearance.parse(["preset":"orange-tabby","seed":1,"parts":overrides])
        let painter=CatAppearanceArtwork(appearance)
        var masks=Data()
        for part in [CatBodyPart.head,.body,.tail] { for y in 0..<512 {for x in 0..<512 {
            masks.append(UInt8(painter.rgb(.init(part:part,u:Double(x)/512,v:Double(y)/512)).r.rounded()))
        }}}
        try masks.write(to:output.appendingPathComponent("tabby.bin"))
        print("Exported 9 native coats, \(w)×\(h) anatomy and native tabby masks.")
    }
}
