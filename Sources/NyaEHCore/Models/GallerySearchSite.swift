// 本文件定义 GallerySearchSite 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

enum GallerySearchSite: String, CaseIterable, Identifiable, Codable, Sendable {
    case eHentai = "e-hentai"
    case exHentai = "exhentai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .eHentai:
            return "E-Hentai"
        case .exHentai:
            return "ExHentai"
        }
    }

    var searchHost: String {
        switch self {
        case .eHentai:
            return "e-hentai.org"
        case .exHentai:
            return "exhentai.org"
        }
    }
}

struct GalleryMetadataFetchConfiguration: Equatable, Sendable {
    var site: GallerySearchSite
    var igneous: String
    var ipbPassHash: String
    var ipbMemberID: String
    var star: String
    var proxySettings: NetworkProxySettings

    init(
        site: GallerySearchSite = .eHentai,
        igneous: String = "",
        ipbPassHash: String = "",
        ipbMemberID: String = "",
        star: String = "",
        proxySettings: NetworkProxySettings = NetworkProxySettings()
    ) {
        self.site = site
        self.igneous = igneous
        self.ipbPassHash = ipbPassHash
        self.ipbMemberID = ipbMemberID
        self.star = star
        self.proxySettings = proxySettings
    }
}
