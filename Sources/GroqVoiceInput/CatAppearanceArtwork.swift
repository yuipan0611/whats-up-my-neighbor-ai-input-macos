import AppKit

/// Repaint only RGB, retaining every source alpha pixel and the original pose.
/// Trusted bundled sources only. User PNGs never enter this renderer.
final class CatAppearanceArtwork {
    private static let markerParts = CatBodyPart.allCases
    struct RGB {
        let r: Double, g: Double, b: Double
        init(_ hex: String) {
            let n = UInt32(hex.dropFirst(), radix: 16)!
            r = Double((n >> 16) & 255); g = Double((n >> 8) & 255); b = Double(n & 255)
        }
        var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }
        var color: NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
        func mixed(with other: RGB, amount: Double) -> RGB {
            RGB(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
        }
        private init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    }
    private static let lightInk = RGB("#FFF8EC"), darkInk = RGB("#51443A"), calicoDark = RGB("#393431")
    private struct Paint {
        let base: RGB, secondary: RGB, pattern: CatPattern
    }
    let appearance: CatAppearance
    private let paints: [CatBodyPart: Paint]
    private let tabbyMasks: [TabbyRegion: TabbyMask]
    private var textureCache: [String: NSImage] = [:]
    init(_ appearance: CatAppearance) {
        self.appearance = appearance
        paints = Dictionary(uniqueKeysWithValues: CatBodyPart.allCases.map { part in
            let style = appearance[part]
            return (part, Paint(base: RGB(style.color), secondary: RGB(style.patternColor), pattern: style.pattern))
        })
        tabbyMasks = appearance.parts.values.contains(where: { $0.pattern == .tabby })
            ? Self.makeTabbyMasks(seed: appearance.seed) : [:]
    }

    func rgb(_ sample: CatAnatomy.Sample) -> RGB {
        let p = paints[sample.part]!, u = sample.u, v = sample.v
        let shift = Double(appearance.seed % 997) / 997 * 0.12
        switch p.pattern {
        case .none: return p.base
        case .tabby:
            let region: TabbyRegion = sample.part == .head ? .head : sample.part == .tail ? .tail : .torso
            // The recording face has a lower, flatter forehead. Match its
            // forehead/eye landmarks instead of clipping the marks above it.
            let patternV = sample.part == .head && sample.headProfile == .recording
                ? (v < 0.66 ? 0.24 + (v - 0.43) * 0.42 / 0.23 : 0.66 + (v - 0.66) * 0.34 / 0.25)
                : v
            return p.base.mixed(with: p.secondary, amount: tabbyMasks[region]!.coverage(u, patternV))
        case .patches, .calico:
            let orange = ellipse(u, v, 0.20 + shift, 0.30, 0.24, 0.36) || ellipse(u, v, 0.75, 0.79 - shift, 0.27, 0.31)
            let dark = ellipse(u, v, 0.89 - shift, 0.22, 0.24, 0.34) || ellipse(u, v, 0.15, 0.87, 0.28, 0.28)
            if orange { return p.secondary }
            if p.pattern == .calico && sample.part == .head && !dark && (u < 0.25 || u > 0.78) {
                // The two cheek patches must meet at the face contour. A pair
                // of isolated ellipses leaves white triangular slivers there.
                // Extend the nearer patch only at the sides; keep the central
                // white blaze and independently configured muzzle untouched.
                let left = u < 0.5
                let orangeDistance = left
                    ? ellipseDistance(u, v, 0.20 + shift, 0.30, 0.24, 0.36)
                    : ellipseDistance(u, v, 0.75, 0.79 - shift, 0.27, 0.31)
                let darkDistance = left
                    ? ellipseDistance(u, v, 0.15, 0.87, 0.28, 0.28)
                    : ellipseDistance(u, v, 0.89 - shift, 0.22, 0.24, 0.34)
                return orangeDistance < darkDistance ? p.secondary : Self.calicoDark
            }
            return p.pattern == .calico && dark ? Self.calicoDark : p.base
        case .whiteSpots:
            return ellipse(u, v, 0.48 + shift, 0.65, 0.23, 0.42) ? p.secondary : p.base
        case .point:
            return ellipse(u, v, 0.50, 0.76, 0.36, 0.23) ? p.secondary : p.base
        }
    }

    private enum TabbyRegion: Hashable { case head, torso, tail }

    /// Authored, tapered fur marks in anatomical coordinates. The same masks
    /// follow the original parts in SVGs, pickup frames and animated repairs.
    /// Cache antialiased coverage once, rather than testing paths per pixel.
    private struct TabbyMask {
        static let size = 512
        let pixels: [UInt8]
        init(_ draw: (CGContext) -> Void) {
            let n = Self.size
            var pixels = [UInt8](repeating: 0, count: n * n)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: n, height: n, bitsPerComponent: 8,
                    bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                // Bitmap rows are top-down, matching CatAnatomy samples.
                context.translateBy(x: 0, y: CGFloat(n))
                context.scaleBy(x: CGFloat(n), y: -CGFloat(n))
                context.setFillColor(gray: 1, alpha: 1)
                draw(context)
            }
            self.pixels = pixels
        }
        func coverage(_ u: Double, _ v: Double) -> Double {
            guard u >= 0, u <= 1, v >= 0, v <= 1 else { return 0 }
            let x = u * Double(Self.size - 1), y = v * Double(Self.size - 1)
            let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, Self.size - 1), y1 = min(y0 + 1, Self.size - 1)
            let dx = x - Double(x0), dy = y - Double(y0)
            let top = Double(pixels[y0 * Self.size + x0]) * (1 - dx) + Double(pixels[y0 * Self.size + x1]) * dx
            let bottom = Double(pixels[y1 * Self.size + x0]) * (1 - dx) + Double(pixels[y1 * Self.size + x1]) * dx
            return (top * (1 - dy) + bottom * dy) / 255
        }
    }

    private static func makeTabbyMasks(seed: UInt32) -> [TabbyRegion: TabbyMask] {
        // A small stable displacement changes the coat without turning each
        // animation frame into a new random drawing.
        let offset = CGFloat(Double(seed % 997) / 996 - 0.5) * 0.012
        func path(_ start: CGPoint, _ curves: [(CGPoint, CGPoint, CGPoint)]) -> CGPath {
            let p = CGMutablePath(); p.move(to: start)
            for (c1, c2, end) in curves { p.addCurve(to: end, control1: c1, control2: c2) }
            p.closeSubpath(); return p
        }
        func pair(_ p: CGPath, in context: CGContext) {
            context.addPath(p); context.fillPath()
            context.saveGState(); context.translateBy(x: 1, y: 0); context.scaleBy(x: -1, y: 1)
            context.addPath(p); context.fillPath(); context.restoreGState()
        }
        return [
            .head: TabbyMask { context in
                context.translateBy(x: 0, y: offset)
                // Three short forehead marks, with tapered ends and a clear
                // gap above the eyes. Cheek bars stay outside the X/check.
                pair(path(CGPoint(x: 0.36, y: 0.22), [
                    (.init(x: 0.36, y: 0.30), .init(x: 0.38, y: 0.38), .init(x: 0.425, y: 0.415)),
                    (.init(x: 0.44, y: 0.425), .init(x: 0.445, y: 0.409), .init(x: 0.432, y: 0.385)),
                    (.init(x: 0.405, y: 0.33), .init(x: 0.405, y: 0.26), .init(x: 0.40, y: 0.22))
                ]), in: context)
                context.addPath(path(CGPoint(x: 0.488, y: 0.22), [
                    (.init(x: 0.478, y: 0.29), .init(x: 0.485, y: 0.37), .init(x: 0.50, y: 0.42)),
                    (.init(x: 0.515, y: 0.37), .init(x: 0.522, y: 0.29), .init(x: 0.512, y: 0.22))
                ])); context.fillPath()
                pair(path(CGPoint(x: -0.02, y: 0.51), [
                    (.init(x: 0.04, y: 0.51), .init(x: 0.105, y: 0.54), .init(x: 0.15, y: 0.575)),
                    (.init(x: 0.17, y: 0.595), .init(x: 0.15, y: 0.605), .init(x: 0.125, y: 0.598)),
                    (.init(x: 0.06, y: 0.58), .init(x: 0.01, y: 0.575), .init(x: -0.02, y: 0.575))
                ]), in: context)
                pair(path(CGPoint(x: -0.02, y: 0.735), [
                    (.init(x: 0.035, y: 0.73), .init(x: 0.085, y: 0.745), .init(x: 0.13, y: 0.775)),
                    (.init(x: 0.145, y: 0.79), .init(x: 0.12, y: 0.80), .init(x: 0.10, y: 0.795)),
                    (.init(x: 0.05, y: 0.79), .init(x: 0.01, y: 0.80), .init(x: -0.02, y: 0.80))
                ]), in: context)
            },
            .torso: TabbyMask { context in
                context.translateBy(x: 0, y: offset)
                // Curved flank marks end before the bib/belly and never
                // create a horizontal belt through the middle of the cat.
                pair(path(CGPoint(x: -0.03, y: 0.26), [
                    (.init(x: 0.09, y: 0.27), .init(x: 0.21, y: 0.33), .init(x: 0.285, y: 0.41)),
                    (.init(x: 0.30, y: 0.435), .init(x: 0.27, y: 0.44), .init(x: 0.245, y: 0.425)),
                    (.init(x: 0.14, y: 0.375), .init(x: 0.04, y: 0.365), .init(x: -0.03, y: 0.36))
                ]), in: context)
                pair(path(CGPoint(x: -0.03, y: 0.59), [
                    (.init(x: 0.07, y: 0.58), .init(x: 0.17, y: 0.62), .init(x: 0.24, y: 0.675)),
                    (.init(x: 0.26, y: 0.695), .init(x: 0.23, y: 0.71), .init(x: 0.205, y: 0.70)),
                    (.init(x: 0.12, y: 0.68), .init(x: 0.03, y: 0.69), .init(x: -0.03, y: 0.69))
                ]), in: context)
            },
            .tail: TabbyMask { context in
                context.addPath(path(CGPoint(x: 0.52, y: -0.02), [
                    (.init(x: 0.55, y: 0.12), .init(x: 0.60, y: 0.21), .init(x: 0.68, y: 0.27)),
                    (.init(x: 0.72, y: 0.29), .init(x: 0.76, y: 0.245), .init(x: 0.735, y: 0.21)),
                    (.init(x: 0.67, y: 0.13), .init(x: 0.64, y: 0.05), .init(x: 0.63, y: -0.02))
                ])); context.fillPath()
                context.addPath(path(CGPoint(x: 0.79, y: 0.44), [
                    (.init(x: 0.86, y: 0.43), .init(x: 0.95, y: 0.455), .init(x: 1.03, y: 0.49)),
                    (.init(x: 1.04, y: 0.53), .init(x: 1.02, y: 0.58), .init(x: 0.98, y: 0.58)),
                    (.init(x: 0.90, y: 0.54), .init(x: 0.84, y: 0.53), .init(x: 0.78, y: 0.53))
                ])); context.fillPath()
                context.addPath(path(CGPoint(x: 0.39, y: 0.73), [
                    (.init(x: 0.45, y: 0.78), .init(x: 0.48, y: 0.88), .init(x: 0.50, y: 1.03)),
                    (.init(x: 0.54, y: 1.04), .init(x: 0.59, y: 1.03), .init(x: 0.60, y: 0.99)),
                    (.init(x: 0.56, y: 0.85), .init(x: 0.52, y: 0.76), .init(x: 0.47, y: 0.70))
                ])); context.fillPath()
            }
        ]
    }
    private func ellipse(_ u: Double, _ v: Double, _ x: Double, _ y: Double, _ rx: Double, _ ry: Double) -> Bool {
        ellipseDistance(u, v, x, y, rx, ry) < 1
    }
    private func ellipseDistance(_ u: Double, _ v: Double, _ x: Double, _ y: Double, _ rx: Double, _ ry: Double) -> Double {
        let a = (u - x) / rx, b = (v - y) / ry
        return a * a + b * b
    }
    func color(_ part: CatBodyPart, u: Double = 0.5, v: Double = 0.5) -> NSColor {
        rgb(.init(part: part, u: u, v: v)).color
    }
    func ink(_ part: CatBodyPart = .head, u: Double = 0.5, v: Double = 0.7) -> NSColor {
        if appearance.hasOriginalCoat { return NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1) }
        return (rgb(.init(part: part, u: u, v: v)).luminance > 150 ? Self.darkInk : Self.lightInk).color
    }

    /// Use original SVG path ordering to distinguish a tail behind the torso
    /// from body pixels at the same coordinates. Marker SVGs exist only in RAM.
    func desktopImage(at url: URL, asset: String) -> NSImage? {
        guard let source = NSImage(contentsOf: url) else { return nil }
        if appearance.isOriginal { source.cacheMode = .never; return source }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let regex = try! NSRegularExpression(pattern: "<path\\b[^>]*?/>")
        var mask = text
        func marked(_ tag: String, _ part: CatBodyPart) -> String {
            let index = Self.markerParts.firstIndex(of: part)!
            return tag.replacingOccurrences(of: "#101114", with: String(format: "#FF00%02X", (index + 1) * 14))
        }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let tag = (text as NSString).substring(with: match.range)
            guard tag.contains("fill=\"#101114\"") else { continue }
            let part: CatBodyPart
            if asset == "tail" { part = .tail }
            else if asset == "body" { part = .body }
            else if asset.hasPrefix("walk-foot-"), let i = Int(asset.suffix(1)) { part = CatAnatomy.legParts[i] }
            else if asset == "walk-head" || asset == "walk-front-face" || asset == "groom-head" { part = .head }
            else if tag.contains("id=\"Vector\"") { part = .tail }
            else if tag.contains("id=\"Vector_2\"") { part = .body }
            else if asset.hasPrefix("walk") && tag.contains("id=\"Vector_3\"") {
                let dRegex = try! NSRegularExpression(pattern: "\\bd=\"([^\"]+)\"")
                let m = dRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))!
                let d = (tag as NSString).substring(with: m.range(at: 1))
                let subpaths = d.components(separatedBy: "M").filter { !$0.isEmpty }
                guard subpaths.count == 4 else { return nil }
                let replacement = subpaths.enumerated().map { i, d in marked("<path d=\"M\(d)\" fill=\"#101114\"/>", CatAnatomy.legParts[i]) }.joined()
                mask = (mask as NSString).replacingCharacters(in: match.range, with: replacement)
                continue
            } else if !asset.hasPrefix("walk") && tag.contains("id=\"Vector_4\"") { part = .frontLeftPaw }
            else if !asset.hasPrefix("walk") && tag.contains("id=\"Vector_5\"") { part = .frontRightPaw }
            else { part = .head }
            mask = (mask as NSString).replacingCharacters(in: match.range, with: marked(tag, part))
        }
        guard let maskImage = NSImage(data: Data(mask.utf8)) else { return nil }
        return image(source, layout: .desktop(asset), partMask: maskImage)
    }

    /// Removes the neutral mouth BEFORE recoloring, so the new pattern remains
    /// continuous under the animated mouth instead of a black repair rectangle.
    func image(_ source: NSImage, layout: CatAnatomy.Layout, removeMouth: Bool = false, partMask: NSImage? = nil) -> NSImage? {
        if appearance.isOriginal && !removeMouth { return source }
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, w <= 2048, h <= 2048 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var maskPixels = [UInt8](repeating: 0, count: partMask == nil ? 0 : w * h * 4)
        if let partMask, let maskCG = partMask.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            maskPixels.withUnsafeMutableBytes { bytes in
                let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(maskCG, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        let head = Self.featureHead(layout: layout, width: w, height: h)
        let leftEye = appearance.features.eyes.left.map(RGB.init)
        let rightEye = appearance.features.eyes.right.map(RGB.init)
        let hasEyeColors = leftEye != nil || rightEye != nil
        let recolored = data.withUnsafeMutableBytes { bytes -> NSImage? in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            let pixels = bytes.bindMemory(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4, alpha = Double(pixels[i + 3]) / 255
                    if alpha == 0 { continue }
                    let r = Double(pixels[i]) / alpha, g = Double(pixels[i + 1]) / alpha, b = Double(pixels[i + 2]) / alpha
                    let l = (r + g + b) / 3
                    // Pink tongue and other chromatic expression accents stay intact.
                    if max(r, max(g, b)) - min(r, min(g, b)) > 50 && l > 70 { continue }
                    var forced: CatBodyPart?
                    if !maskPixels.isEmpty, maskPixels[i + 3] > 0 {
                        let a = Double(maskPixels[i + 3]) / 255
                        if Double(maskPixels[i]) / a > 245 && Double(maskPixels[i + 1]) / a < 8 {
                            let index = Int((Double(maskPixels[i + 2]) / a + 7) / 14) - 1
                            if Self.markerParts.indices.contains(index) { forced = Self.markerParts[index] }
                        }
                    }
                    let sample = CatAnatomy.sample(x: Double(x), y: Double(y), width: Double(w), height: Double(h), layout: layout, forcedPart: forced)
                    let coat = rgb(sample)
                    let mouth = removeMouth && Double(x) / Double(w) > 0.448 && Double(x) / Double(w) < 0.552 &&
                        Double(y) / Double(h) > 0.755 && Double(y) / Double(h) < 0.84
                    let feature = mouth ? 0 : max(0, min(1, (l - 65) / 175))
                    var ink = coat.luminance > 150 ? Self.darkInk : Self.lightInk
                    var customEye: RGB?
                    if hasEyeColors, let head {
                        let u = (Double(x) - Double(head.rect.minX)) / Double(head.rect.width)
                        let v = (Double(y) - Double(head.rect.minY)) / Double(head.rect.height)
                        let eyeY = head.recording ? 0.52...0.79 : 0.55...0.82
                        if eyeY.contains(v) {
                            if (0.13...0.36).contains(u) { customEye = leftEye }
                            if (0.63...0.90).contains(u) { customEye = rightEye }
                        }
                    }
                    // For the original black coat, keep every unmodified source
                    // pixel. Color only the existing light eye glyph pixels.
                    if appearance.hasOriginalCoat && !mouth {
                        guard let customEye, feature > 0 else { continue }
                        pixels[i] = UInt8(max(0, min(255, r * (1 - feature) + customEye.r * feature)) * alpha)
                        pixels[i + 1] = UInt8(max(0, min(255, g * (1 - feature) + customEye.g * feature)) * alpha)
                        pixels[i + 2] = UInt8(max(0, min(255, b * (1 - feature) + customEye.b * feature)) * alpha)
                        continue
                    }
                    if let customEye { ink = customEye }
                    var detail = mouth ? 1 : min(1.08, max(0.72, 0.88 + l * 0.006))
                    // Original gray limb/contour strokes need dark contrast on
                    // pale coats, rather than turning into brighter white lines.
                    if !mouth && coat.luminance > 150 && l > 27 && l < 90 {
                        detail = 1 - 0.60 * (l - 27) / 63
                    }
                    pixels[i] = UInt8(max(0, min(255, coat.r * detail * (1 - feature) + ink.r * feature)) * alpha)
                    pixels[i + 1] = UInt8(max(0, min(255, coat.g * detail * (1 - feature) + ink.g * feature)) * alpha)
                    pixels[i + 2] = UInt8(max(0, min(255, coat.b * detail * (1 - feature) + ink.b * feature)) * alpha)
                }
            }
            guard let result = context.makeImage() else { return nil }
            return NSImage(cgImage: result, size: source.size)
        }
        guard let recolored, let head else { return recolored }
        let features = appearance.features
        let includeAccessories: Bool
        if case .desktop = layout { includeAccessories = false } else { includeAccessories = true }
        guard features.nose.shape != .none || features.nose.freckles ||
            (includeAccessories && (features.collar.enabled || features.bow.enabled)) else { return recolored }
        // Compose at native pixel dimensions once; retaining source.size keeps
        // pickup hit/grip coordinates and the recording HUD layout unchanged.
        let canvas = NSSize(width: CGFloat(w), height: CGFloat(h))
        let decorated = NSImage(size: canvas, flipped: true) { _ in
            recolored.draw(in: CGRect(origin: .zero, size: canvas), from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            self.drawNose(headIn: head.rect, recording: head.recording)
            if includeAccessories { self.drawAccessories(headIn: head.rect, recording: head.recording) }
            return true
        }
        guard let result = decorated.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSImage(cgImage: result, size: source.size)
    }

    /// A local paint texture fills native animated geometry and repairs closed
    /// eyes without erasing their underlying spots. Cached once per view.
    func fill(_ path: NSBezierPath, layout: CatAnatomy.Layout, in rect: CGRect, cacheKey: String) {
        let texture: NSImage
        if let cached = textureCache[cacheKey] { texture = cached }
        else {
            let size = 256
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
            let p = bitmap.bitmapData!
            for y in 0..<size { for x in 0..<size {
                let sample: CatAnatomy.Sample
                if case .part(let part) = layout { sample = .init(part: part, u: Double(x) / Double(size), v: Double(y) / Double(size)) }
                else { sample = CatAnatomy.sample(x: Double(rect.minX) + Double(x) / Double(size) * Double(rect.width),
                    y: Double(rect.minY) + Double(y) / Double(size) * Double(rect.height), width: 400, height: 400, layout: layout) }
                let color = rgb(sample), i = (y * size + x) * 4
                p[i] = UInt8(color.r); p[i + 1] = UInt8(color.g); p[i + 2] = UInt8(color.b); p[i + 3] = 255
            } }
            texture = NSImage(size: NSSize(width: size, height: size)); texture.addRepresentation(bitmap)
            textureCache[cacheKey] = texture
        }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        texture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private struct FeatureHead {
        let rect: CGRect
        let recording: Bool
    }
    private static func featureHead(layout: CatAnatomy.Layout, width: Int, height: Int) -> FeatureHead? {
        switch layout {
        case .hud:
            return FeatureHead(rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), recording: true)
        case .pickup(let map):
            return FeatureHead(rect: CGRect(x: map.head[0], y: map.head[1], width: map.head[2], height: map.head[3]), recording: false)
        case .desktop(let asset):
            guard ["sit", "reply", "walk", "walk-front-face", "walk-head", "groom-head"].contains(asset) else { return nil }
            let x = asset.hasPrefix("walk") ? 25.0 : 45.0
            return FeatureHead(rect: CGRect(x: x / 400 * Double(width), y: 18.0 / 400 * Double(height),
                width: 312.0 / 400 * Double(width), height: 208.0 / 400 * Double(height)), recording: false)
        case .part: return nil
        }
    }

    /// Attachments use authored anatomical coordinates, never screen position.
    /// Desktop callers draw these inside the same breathing/head transform as
    /// the body; pickup and HUD images bake them once into their cached image.
    func drawAccessories(headIn head: CGRect, recording: Bool = false) {
        let features = appearance.features
        guard features.collar.enabled || features.bow.enabled else { return }
        let neckY = recording ? head.minY + head.height * 0.90 : head.maxY + head.height * 0.015
        let half = head.width * (recording ? 0.145 : 0.22)
        if features.collar.enabled {
            let band = NSBezierPath()
            band.move(to: CGPoint(x: head.midX - half, y: neckY - head.height * 0.015))
            band.curve(to: CGPoint(x: head.midX + half, y: neckY - head.height * 0.015),
                controlPoint1: CGPoint(x: head.midX - half * 0.42, y: neckY + head.height * 0.045),
                controlPoint2: CGPoint(x: head.midX + half * 0.42, y: neckY + head.height * 0.045))
            band.lineWidth = head.height * (recording ? 0.022 : 0.042)
            band.lineCapStyle = .round
            RGB(features.collar.color).color.setStroke(); band.stroke()
        }
        if features.bow.enabled {
            let center: CGPoint, size: CGSize, angle: CGFloat
            switch features.bow.position {
            case .neck:
                center = CGPoint(x: head.midX, y: neckY + head.height * (recording ? 0.025 : 0.055))
                size = CGSize(width: head.width * (recording ? 0.13 : 0.23), height: head.height * (recording ? 0.105 : 0.17))
                angle = 0
            case .leftEar, .rightEar:
                let left = features.bow.position == .leftEar
                center = CGPoint(x: head.minX + head.width * (left ? 0.20 : 0.80),
                    y: head.minY + head.height * (recording ? 0.30 : 0.21))
                size = CGSize(width: head.width * (recording ? 0.12 : 0.18), height: head.height * (recording ? 0.11 : 0.16))
                angle = left ? -22 : 22
            }
            drawBow(at: center, size: size, angle: angle)
        }
    }

    private func drawBow(at center: CGPoint, size: CGSize, angle: CGFloat) {
        let bow = appearance.features.bow
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: angle)
        transform.concat()
        let x = size.width / 2, y = size.height / 2
        let loops = NSBezierPath()
        loops.move(to: CGPoint(x: -x * 0.08, y: 0))
        loops.curve(to: CGPoint(x: -x, y: -y * 0.72),
            controlPoint1: CGPoint(x: -x * 0.58, y: -y * 0.9), controlPoint2: CGPoint(x: -x * 0.98, y: -y * 1.25))
        loops.curve(to: CGPoint(x: -x, y: y * 0.72),
            controlPoint1: CGPoint(x: -x * 1.08, y: -y * 0.2), controlPoint2: CGPoint(x: -x * 1.08, y: y * 0.2))
        loops.curve(to: CGPoint(x: -x * 0.08, y: 0),
            controlPoint1: CGPoint(x: -x * 0.98, y: y * 1.25), controlPoint2: CGPoint(x: -x * 0.58, y: y * 0.9))
        loops.close()
        loops.move(to: CGPoint(x: x * 0.08, y: 0))
        loops.curve(to: CGPoint(x: x, y: -y * 0.72),
            controlPoint1: CGPoint(x: x * 0.58, y: -y * 0.9), controlPoint2: CGPoint(x: x * 0.98, y: -y * 1.25))
        loops.curve(to: CGPoint(x: x, y: y * 0.72),
            controlPoint1: CGPoint(x: x * 1.08, y: -y * 0.2), controlPoint2: CGPoint(x: x * 1.08, y: y * 0.2))
        loops.curve(to: CGPoint(x: x * 0.08, y: 0),
            controlPoint1: CGPoint(x: x * 0.98, y: y * 1.25), controlPoint2: CGPoint(x: x * 0.58, y: y * 0.9))
        loops.close()
        RGB(bow.color).color.setFill(); loops.fill()
        let knot = NSBezierPath(roundedRect: CGRect(x: -x * 0.18, y: -y * 0.42, width: x * 0.36, height: y * 0.84),
            xRadius: y * 0.18, yRadius: y * 0.18)
        RGB(bow.knotColor).color.setFill(); knot.fill()
    }

    func drawNose(headIn head: CGRect, recording: Bool = false) {
        let nose = appearance.features.nose
        guard nose.shape != .none || nose.freckles else { return }
        let center = CGPoint(x: head.midX, y: head.minY + head.height * (recording ? 0.735 : 0.72))
        let w = head.width * (recording ? 0.04 : 0.06), h = head.height * (recording ? 0.037 : 0.06)
        let shape = NSBezierPath()
        switch nose.shape {
        case .none: break
        case .triangle:
            shape.move(to: CGPoint(x: center.x - w / 2, y: center.y - h / 2))
            shape.line(to: CGPoint(x: center.x + w / 2, y: center.y - h / 2))
            shape.curve(to: CGPoint(x: center.x, y: center.y + h / 2),
                controlPoint1: CGPoint(x: center.x + w * 0.4, y: center.y), controlPoint2: CGPoint(x: center.x + w * 0.12, y: center.y + h / 2))
            shape.curve(to: CGPoint(x: center.x - w / 2, y: center.y - h / 2),
                controlPoint1: CGPoint(x: center.x - w * 0.12, y: center.y + h / 2), controlPoint2: CGPoint(x: center.x - w * 0.4, y: center.y))
            shape.close()
        case .round:
            shape.appendOval(in: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h))
        case .heart:
            shape.move(to: CGPoint(x: center.x, y: center.y + h * 0.6))
            shape.curve(to: CGPoint(x: center.x, y: center.y - h * 0.23),
                controlPoint1: CGPoint(x: center.x - w, y: center.y - h * 0.35),
                controlPoint2: CGPoint(x: center.x - w * 0.32, y: center.y - h * 0.95))
            shape.curve(to: CGPoint(x: center.x, y: center.y + h * 0.6),
                controlPoint1: CGPoint(x: center.x + w * 0.32, y: center.y - h * 0.95),
                controlPoint2: CGPoint(x: center.x + w, y: center.y - h * 0.35))
            shape.close()
        }
        RGB(nose.color).color.setFill(); shape.fill()
        if nose.freckles {
            let radius = head.width * (recording ? 0.0038 : 0.006)
            let dots: [(CGFloat, CGFloat)] = [(0.088, 0.005), (0.115, 0.025), (0.080, 0.045)]
            for side: CGFloat in [-1, 1] {
                for (dx, dy) in dots {
                    let dot = CGRect(x: center.x + side * head.width * dx - radius,
                        y: center.y + head.height * dy - radius, width: radius * 2, height: radius * 2)
                    NSBezierPath(ovalIn: dot).fill()
                }
            }
        }
    }

}
