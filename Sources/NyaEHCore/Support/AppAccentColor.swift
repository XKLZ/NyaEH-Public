// 本文件提供 AppAccentColor 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import AppKit
import SwiftUI

enum AppAccentColor: String, CaseIterable, Identifiable, Sendable {
    case system
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case graphite
    case custom

    static let standardCases: [AppAccentColor] = [
        .blue,
        .purple,
        .pink,
        .red,
        .orange,
        .yellow,
        .green,
        .graphite
    ]

    var id: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .system:
            return .accentColorSystem
        case .blue:
            return .accentColorBlue
        case .purple:
            return .accentColorPurple
        case .pink:
            return .accentColorPink
        case .red:
            return .accentColorRed
        case .orange:
            return .accentColorOrange
        case .yellow:
            return .accentColorYellow
        case .green:
            return .accentColorGreen
        case .graphite:
            return .accentColorGraphite
        case .custom:
            return .accentColorCustom
        }
    }

    func color(customHex: String) -> Color? {
        nsColor(customHex: customHex).map(Color.init(nsColor:))
    }

    func nsColor(customHex: String) -> NSColor? {
        switch self {
        case .system:
            return nil
        case .blue:
            return .systemBlue
        case .purple:
            return .systemPurple
        case .pink:
            return .systemPink
        case .red:
            return .systemRed
        case .orange:
            return .systemOrange
        case .yellow:
            return .systemYellow
        case .green:
            return .systemGreen
        case .graphite:
            return .systemGray
        case .custom:
            return NSColor.nyaehColor(hex: customHex) ?? AppAccentColor.blue.nsColor(customHex: customHex)
        }
    }
}

extension NSColor {
    static func nyaehColor(hex: String) -> NSColor? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else {
            return nil
        }

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        if value.count == 8 {
            red = CGFloat((number & 0xFF00_0000) >> 24) / 255
            green = CGFloat((number & 0x00FF_0000) >> 16) / 255
            blue = CGFloat((number & 0x0000_FF00) >> 8) / 255
            alpha = CGFloat(number & 0x0000_00FF) / 255
        } else {
            red = CGFloat((number & 0xFF0000) >> 16) / 255
            green = CGFloat((number & 0x00FF00) >> 8) / 255
            blue = CGFloat(number & 0x0000FF) / 255
            alpha = 1
        }

        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var nyaehHexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        let alpha = Int(round(color.alphaComponent * 255))
        return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }
}
