// 本文件提供 NyaEHAccentColorEnvironment 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import SwiftUI

private struct NyaEHAccentColorKey: EnvironmentKey {
    static let defaultValue = Color.accentColor
}

extension EnvironmentValues {
    var nyaehAccentColor: Color {
        get { self[NyaEHAccentColorKey.self] }
        set { self[NyaEHAccentColorKey.self] = newValue }
    }
}
