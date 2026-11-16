import Foundation
import Testing
@testable import NyaEHCore

@Suite("Network proxy and connectivity")
struct NetworkConnectivityTests {
    @Test("proxy settings build HTTP and SOCKS dictionaries")
    func proxySettingsBuildDictionaries() throws {
        let http = NetworkProxySettings(isEnabled: true, type: .http, host: "127.0.0.1", port: 7890)
        let httpDictionary = try #require(http.connectionProxyDictionary)
        #expect(httpDictionary[kCFNetworkProxiesHTTPEnable as String] as? Bool == true)
        #expect(httpDictionary[kCFNetworkProxiesHTTPProxy as String] as? String == "127.0.0.1")
        #expect(httpDictionary[kCFNetworkProxiesHTTPPort as String] as? Int == 7890)
        #expect(httpDictionary[kCFNetworkProxiesHTTPSEnable as String] as? Bool == true)

        let socks = NetworkProxySettings(isEnabled: true, type: .socks, host: "localhost", port: 1080)
        let socksDictionary = try #require(socks.connectionProxyDictionary)
        #expect(socksDictionary[kCFNetworkProxiesSOCKSEnable as String] as? Bool == true)
        #expect(socksDictionary[kCFNetworkProxiesSOCKSProxy as String] as? String == "localhost")
        #expect(socksDictionary[kCFNetworkProxiesSOCKSPort as String] as? Int == 1080)
        #expect(NetworkProxySettings(isEnabled: false, type: .http, host: "127.0.0.1", port: 7890).connectionProxyDictionary == nil)
    }

    @Test("connectivity treats 2xx and 3xx as success")
    func connectivityTreatsSuccessfulStatusCodesAsSuccess() async {
        let client = MockConnectivityHTTPClient(statusCodes: [204, 302, 500])
        let service = NetworkConnectivityService(httpClient: client)

        let proxy = await service.testProxy(settings: .init(isEnabled: true, type: .http, host: "127.0.0.1", port: 7890))
        let github = await service.testGitHub(proxySettings: .init())
        let ehentai = await service.testEHentai(configuration: .init(site: .eHentai))

        #expect(proxy.success)
        #expect(github.success)
        #expect(!ehentai.success)
        #expect(ehentai.statusCode == 500)
    }

    @Test("ExHentai test uses cookies when complete otherwise falls back")
    func exhentaiTestUsesCookiesWhenCompleteOtherwiseFallsBack() async throws {
        let client = MockConnectivityHTTPClient(statusCodes: [200, 200])
        let service = NetworkConnectivityService(httpClient: client)

        _ = await service.testEHentai(configuration: .init(site: .exHentai))
        _ = await service.testEHentai(
            configuration: .init(
                site: .exHentai,
                igneous: "igneous",
                ipbPassHash: "pass",
                ipbMemberID: "member"
            )
        )

        let first = try #require(client.requests.first)
        let second = try #require(client.requests.dropFirst().first)
        #expect(first.url?.host == "e-hentai.org")
        #expect(first.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(second.url?.host == "exhentai.org")
        #expect(second.value(forHTTPHeaderField: "Cookie")?.contains("igneous=igneous") == true)
    }
}

private final class MockConnectivityHTTPClient: NetworkConnectivityHTTPClient, @unchecked Sendable {
    private var statusCodes: [Int]
    private(set) var requests: [URLRequest] = []

    init(statusCodes: [Int]) {
        self.statusCodes = statusCodes
    }

    func statusCode(for request: URLRequest, proxySettings: NetworkProxySettings) async throws -> Int {
        requests.append(request)
        return statusCodes.removeFirst()
    }
}
