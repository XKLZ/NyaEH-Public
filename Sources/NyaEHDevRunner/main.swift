// 本文件是 SwiftPM 开发运行入口，只负责启动共享的 NyaEHScene，正式打包仍由外部 NyaEH Xcode 壳承载。

import SwiftUI
import NyaEHCore

@main
struct NyaEHDevRunnerApp: App {
    var body: some Scene {
        NyaEHScene(
            developmentConfiguration: NyaEHDevelopmentConfiguration.resolved()
        )
    }
}
