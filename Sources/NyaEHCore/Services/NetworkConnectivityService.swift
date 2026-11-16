// 本文件用于设置页网络连通性测试，复用应用代理配置但不持久化任何秘密。

import Foundation

struct NetworkConnectivityResult: Equatable, Sendable {
    var success: Bool
    var statusCode: Int?
    var message: String
}

protocol NetworkConnectivityHTTPClient: Sendable {
    func statusCode(for request: URLRequest, proxySettings: NetworkProxySettings) async throws -> Int
}

struct URLSessionNetworkConnectivityHTTPClient: NetworkConnectivityHTTPClient {
    func statusCode(for request: URLRequest, proxySettings: NetworkProxySettings) async throws -> Int {
        let session = URLSession(configuration: .nyaehDefault(proxySettings: proxySettings))
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GalleryMetadataFetchError.invalidResponse
        }
        return httpResponse.statusCode
    }
}

struct NetworkConnectivityService: Sendable {
    private let httpClient: any NetworkConnectivityHTTPClient

    init(httpClient: any NetworkConnectivityHTTPClient = URLSessionNetworkConnectivityHTTPClient()) {
        self.httpClient = httpClient
    }

    func testProxy(settings: NetworkProxySettings) async -> NetworkConnectivityResult {
        guard settings.isUsable else {
            return NetworkConnectivityResult(success: false, statusCode: nil, message: "Proxy settings are incomplete.")
        }
        return await test(url: URL(string: "https://www.apple.com/library/test/success.html")!, proxySettings: settings)
    }

    func testGitHub(proxySettings: NetworkProxySettings) async -> NetworkConnectivityResult {
        await test(url: GitHubEhTagTranslationRemoteClient().url, proxySettings: proxySettings)
    }

    func testEHentai(configuration: GalleryMetadataFetchConfiguration) async -> NetworkConnectivityResult {
        let useExHentai = GalleryMetadataFetchService.cookieHeader(for: configuration) != nil
        let site = useExHentai ? GallerySearchSite.exHentai : .eHentai
        var request = URLRequest(url: URL(string: "https://\(site.searchHost)/")!)
        request.httpMethod = "GET"
        request.setValue("NyaEH", forHTTPHeaderField: "User-Agent")
        if useExHentai, let cookieHeader = GalleryMetadataFetchService.cookieHeader(for: configuration) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        return await test(request: request, proxySettings: configuration.proxySettings)
    }

    private func test(url: URL, proxySettings: NetworkProxySettings) async -> NetworkConnectivityResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("NyaEH", forHTTPHeaderField: "User-Agent")
        return await test(request: request, proxySettings: proxySettings)
    }

    private func test(request: URLRequest, proxySettings: NetworkProxySettings) async -> NetworkConnectivityResult {
        do {
            let statusCode = try await httpClient.statusCode(for: request, proxySettings: proxySettings)
            let success = (200..<400).contains(statusCode)
            return NetworkConnectivityResult(
                success: success,
                statusCode: statusCode,
                message: success ? "Reachable (HTTP \(statusCode))." : "Request failed with HTTP \(statusCode)."
            )
        } catch {
            return NetworkConnectivityResult(success: false, statusCode: nil, message: error.localizedDescription)
        }
    }
}
