import Foundation
import CoreFoundation

/// Display-only anatomy. Left/right refer to the front-view artwork, not ownership.
enum CatBodyPart: String, CaseIterable {
    case head, leftEar, rightEar, muzzle, chest, belly, body
    case frontLeftLeg, frontRightLeg, rearLeftLeg, rearRightLeg
    case frontLeftPaw, frontRightPaw, rearLeftPaw, rearRightPaw, tail
}

enum CatPattern: String, CaseIterable {
    case none, tabby, patches, calico, whiteSpots, point
}

struct CatPartStyle: Equatable {
    var color: String
    var pattern: CatPattern = .none
    var patternColor: String = "#C88C4E"
}

enum CatNoseShape: String, CaseIterable { case none, triangle, round, heart }
enum CatBowPosition: String, CaseIterable { case neck, leftEar, rightEar }

struct CatEyeFeatures: Equatable {
    /// Front-view left/right. Keep the original X/check glyphs and click targets.
    var left: String? = nil
    var right: String? = nil
}
struct CatNoseFeatures: Equatable {
    var shape: CatNoseShape = .none
    var color = "#C98784"
    var freckles = false
}
struct CatCollarFeatures: Equatable {
    var enabled = false
    var color = "#A45E58"
}
struct CatBowFeatures: Equatable {
    var enabled = false
    var color = "#C98784"
    var knotColor = "#9F5B60"
    var position: CatBowPosition = .neck
}

/// Small, data-only additions to the shared yui-cat-v1 drawing template.
/// Disabled settings may retain their chosen colors without changing the art.
struct CatFeatures: Equatable {
    var eyes = CatEyeFeatures()
    var nose = CatNoseFeatures()
    var collar = CatCollarFeatures()
    var bow = CatBowFeatures()
    var isEmpty: Bool {
        eyes.left == nil && eyes.right == nil && nose.shape == .none &&
            !nose.freckles && !collar.enabled && !bow.enabled
    }
    var jsonObject: [String: Any] {
        var eyeObject: [String: Any] = [:]
        if let left = eyes.left { eyeObject["left"] = left }
        if let right = eyes.right { eyeObject["right"] = right }
        return ["eyes": eyeObject,
            "nose": ["shape": nose.shape.rawValue, "color": nose.color, "freckles": nose.freckles],
            "collar": ["enabled": collar.enabled, "color": collar.color],
            "bow": ["enabled": bow.enabled, "color": bow.color, "knotColor": bow.knotColor, "position": bow.position.rawValue]]
    }
    static func parse(_ value: Any) throws -> CatFeatures {
        let object = try dictionary(value, keys: ["eyes", "nose", "collar", "bow"])
        var features = CatFeatures()
        if let value = object["eyes"] {
            let eyes = try dictionary(value, keys: ["left", "right"])
            if let color = eyes["left"] { features.eyes.left = try CatAppearance.hex(color) }
            if let color = eyes["right"] { features.eyes.right = try CatAppearance.hex(color) }
        }
        if let value = object["nose"] {
            let nose = try dictionary(value, keys: ["shape", "color", "freckles"])
            if let value = nose["shape"] {
                guard let name = value as? String, let shape = CatNoseShape(rawValue: name) else { throw CatAppearance.Invalid.appearance }
                features.nose.shape = shape
            }
            if let color = nose["color"] { features.nose.color = try CatAppearance.hex(color) }
            if let value = nose["freckles"] { features.nose.freckles = try boolean(value) }
        }
        if let value = object["collar"] {
            let collar = try dictionary(value, keys: ["enabled", "color"])
            if let value = collar["enabled"] { features.collar.enabled = try boolean(value) }
            if let color = collar["color"] { features.collar.color = try CatAppearance.hex(color) }
        }
        if let value = object["bow"] {
            let bow = try dictionary(value, keys: ["enabled", "color", "knotColor", "position"])
            if let value = bow["enabled"] { features.bow.enabled = try boolean(value) }
            if let color = bow["color"] { features.bow.color = try CatAppearance.hex(color) }
            if let color = bow["knotColor"] { features.bow.knotColor = try CatAppearance.hex(color) }
            if let value = bow["position"] {
                guard let name = value as? String, let position = CatBowPosition(rawValue: name) else { throw CatAppearance.Invalid.appearance }
                features.bow.position = position
            }
        }
        return features
    }
    private static func dictionary(_ value: Any, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: keys) else { throw CatAppearance.Invalid.appearance }
        return object
    }
    private static func boolean(_ value: Any) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw CatAppearance.Invalid.appearance }
        return number.boolValue
    }
}

/// Immutable, fully resolved preset + overrides. No accounts, draws or writes.
struct CatAppearance: Equatable {
    static let presetIDs = ["original", "black", "white", "blue", "orange-tabby", "tuxedo", "calico", "tortoiseshell", "colorpoint"]
    static let presetNames = ["原版黑貓", "黑貓", "白貓", "灰貓", "橘虎斑", "賓士貓", "三花貓", "玳瑁貓", "重點色貓"]
    let preset: String
    let seed: UInt32
    private(set) var parts: [CatBodyPart: CatPartStyle]
    private(set) var features = CatFeatures()
    static let original = makePreset("original")!
    var hasOriginalCoat: Bool { parts == Self.original.parts }
    var isOriginal: Bool { hasOriginalCoat && features.isEmpty }
    func replacingFeatures(_ features: CatFeatures) -> CatAppearance {
        var copy = self
        copy.features = features
        return copy
    }
    var title: String { Self.presetNames[Self.presetIDs.firstIndex(of: preset) ?? 0] }
    subscript(_ part: CatBodyPart) -> CatPartStyle { parts[part]! }

    static func makePreset(_ id: String, seed: UInt32 = 1) -> CatAppearance? {
        guard presetIDs.contains(id) else { return nil }
        let base: String
        switch id {
        case "original": base = "#101114"
        case "black": base = "#242323"
        case "white", "calico": base = "#F4EFE5"
        case "blue": base = "#8D9295"
        case "orange-tabby": base = "#D6A366"
        case "tuxedo": base = "#292828"
        case "tortoiseshell": base = "#3C3530"
        default: base = "#E2D3BA"
        }
        let pattern: CatPattern = id == "orange-tabby" ? .tabby : id == "calico" ? .calico : id == "tortoiseshell" ? .patches : .none
        let secondary = id == "orange-tabby" ? "#9A5F2D" : id == "tortoiseshell" ? "#B77D42" : "#C88C4E"
        var parts = Dictionary(uniqueKeysWithValues: CatBodyPart.allCases.map {
            ($0, CatPartStyle(color: base, pattern: pattern, patternColor: secondary))
        })
        let paws: [CatBodyPart] = [.frontLeftPaw, .frontRightPaw, .rearLeftPaw, .rearRightPaw]
        if id == "orange-tabby" {
            for part in [CatBodyPart.leftEar, .rightEar, .muzzle] { parts[part] = CatPartStyle(color: base) }
        }
        if id == "tuxedo" {
            for part in [.muzzle, .chest, .belly] + paws { parts[part] = CatPartStyle(color: "#F4EFE5") }
        }
        if id == "calico" {
            for part in [.muzzle, .chest, .belly] + paws { parts[part] = CatPartStyle(color: "#F4EFE5") }
            parts[.leftEar] = CatPartStyle(color: "#C88C4E")
            parts[.rightEar] = CatPartStyle(color: "#393431")
        }
        if id == "colorpoint" {
            for part in [.leftEar, .rightEar, .tail] + paws {
                parts[part] = CatPartStyle(color: "#685145")
            }
            parts[.muzzle] = CatPartStyle(color: "#806659")
            parts[.head] = CatPartStyle(color: base, pattern: .point, patternColor: "#806659")
        }
        return CatAppearance(preset: id, seed: seed, parts: parts)
    }

    enum Invalid: Error { case appearance }

    static func parse(_ value: Any) throws -> CatAppearance {
        guard let object = value as? [String: Any],
              Set(object.keys).isSubset(of: ["preset", "seed", "parts", "features"]),
              let id = object["preset"] as? String else { throw Invalid.appearance }
        var seed: UInt32 = 1
        if let value = object["seed"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: number.objCType)),
                  number.doubleValue >= 0, number.doubleValue <= Double(UInt32.max) else { throw Invalid.appearance }
            seed = number.uint32Value
        }
        guard var appearance = makePreset(id, seed: seed) else { throw Invalid.appearance }
        if let value = object["parts"] {
            guard let overrides = value as? [String: Any] else { throw Invalid.appearance }
            for (key, value) in overrides {
                guard let part = CatBodyPart(rawValue: key), let fields = value as? [String: Any],
                      Set(fields.keys).isSubset(of: ["color", "pattern", "patternColor"]) else { throw Invalid.appearance }
                var style = appearance[part]
                if let color = fields["color"] { style.color = try hex(color) }
                if let color = fields["patternColor"] { style.patternColor = try hex(color) }
                if let value = fields["pattern"] {
                    guard let name = value as? String, let pattern = CatPattern(rawValue: name) else { throw Invalid.appearance }
                    style.pattern = pattern
                }
                appearance.parts[part] = style
            }
        }
        if let value = object["features"] { appearance.features = try CatFeatures.parse(value) }
        return appearance
    }

    fileprivate static func hex(_ value: Any) throws -> String {
        guard let text = value as? String, text.utf8.count == 7, text.first == "#",
              text.dropFirst().utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw Invalid.appearance }
        return text.uppercased()
    }

    /// Full editable examples; every anatomical feature is filled explicitly.
    var jsonObject: [String: Any] {
        ["preset": preset, "seed": seed, "features": features.jsonObject, "parts": Dictionary(uniqueKeysWithValues: CatBodyPart.allCases.map { part in
            (part.rawValue, ["color": self[part].color, "pattern": self[part].pattern.rawValue,
                             "patternColor": self[part].patternColor])
        })]
    }
}
