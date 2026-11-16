// 本文件定义 NetworkProxySettings 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

enum NetworkProxyType: String, CaseIterable, Identifiable, Codable, Sendable {
    case socks
    case http

    var id: String { rawValue }
}

struct NetworkProxySettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var type: NetworkProxyType
    var host: String
    var port: Int

    init(
        isEnabled: Bool = false,
        type: NetworkProxyType = .http,
        host: String = "",
        port: Int = 7890
    ) {
        self.isEnabled = isEnabled
        self.type = type
        self.host = host
        self.port = min(max(port, 1), 65_535)
    }

    var normalizedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isUsable: Bool {
        isEnabled && !normalizedHost.isEmpty && (1...65_535).contains(port)
    }
}

extension URLSessionConfiguration {
    static func nyaehDefault(proxySettings: NetworkProxySettings = NetworkProxySettings()) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.connectionProxyDictionary = proxySettings.connectionProxyDictionary
        return configuration
    }
}

extension NetworkProxySettings {
    var connectionProxyDictionary: [AnyHashable: Any]? {
        guard isUsable else {
            return nil
        }

        switch type {
        case .http:
            return [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: normalizedHost,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: normalizedHost,
                kCFNetworkProxiesHTTPSPort as String: port
            ]
        case .socks:
            return [
                kCFNetworkProxiesSOCKSEnable as String: true,
                kCFNetworkProxiesSOCKSProxy as String: normalizedHost,
                kCFNetworkProxiesSOCKSPort as String: port
            ]
        }
    }
}
