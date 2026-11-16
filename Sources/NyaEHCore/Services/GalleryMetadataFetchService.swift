// 本文件封装 E-Hentai/ExHentai 搜索与 API 元数据获取，网络失败和访问限制都在这里归一化。

import Foundation

struct GallerySearchResult: Equatable, Sendable {
    var title: String
    var url: URL
    var galleryID: Int64
    var galleryToken: String
}

protocol GalleryMetadataHTTPClient: Sendable {
    func data(for request: URLRequest, proxySettings: NetworkProxySettings) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionGalleryMetadataHTTPClient: GalleryMetadataHTTPClient {
    func data(for request: URLRequest, proxySettings: NetworkProxySettings) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: .nyaehDefault(proxySettings: proxySettings))
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GalleryMetadataFetchError.invalidResponse
        }
        return (data, httpResponse)
    }
}

struct GalleryMetadataFetchService: Sendable {
    private let httpClient: GalleryMetadataHTTPClient
    private let apiURL: URL

    init(
        httpClient: GalleryMetadataHTTPClient = URLSessionGalleryMetadataHTTPClient(),
        apiURL: URL = URL(string: "https://api.e-hentai.org/api.php")!
    ) {
        self.httpClient = httpClient
        self.apiURL = apiURL
    }

    func fetchMetadata(
        hash: String,
        configuration: GalleryMetadataFetchConfiguration
    ) async throws -> GalleryMetadata {
        guard Self.isUsableSHA1(hash) else {
            throw GalleryMetadataFetchError.invalidHash
        }

        if configuration.site == .exHentai && Self.cookieHeader(for: configuration) == nil {
            throw GalleryMetadataFetchError.missingExHentaiCookies
        }

        let results = try await search(hash: hash, configuration: configuration)
        guard let result = results.first else {
            throw GalleryMetadataFetchError.noSearchResults
        }

        return try await fetchMetadata(hash: hash, searchResult: result, proxySettings: configuration.proxySettings)
    }

    func search(
        hash: String,
        configuration: GalleryMetadataFetchConfiguration
    ) async throws -> [GallerySearchResult] {
        let url = try Self.searchURL(hash: hash, site: configuration.site)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        if let cookieHeader = Self.cookieHeader(for: configuration) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await httpClient.data(for: request, proxySettings: configuration.proxySettings)
        try Self.validate(response: response)

        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw GalleryMetadataFetchError.invalidResponse
        }

        try Self.validateSearchHTML(html, site: configuration.site)
        return Self.parseSearchResults(html: html, site: configuration.site)
    }

    func fetchMetadata(hash: String, searchResult: GallerySearchResult) async throws -> GalleryMetadata {
        try await fetchMetadata(hash: hash, searchResult: searchResult, proxySettings: NetworkProxySettings())
    }

    private func fetchMetadata(
        hash: String,
        searchResult: GallerySearchResult,
        proxySettings: NetworkProxySettings
    ) async throws -> GalleryMetadata {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GDataRequest(gidlist: [[.int(searchResult.galleryID), .string(searchResult.galleryToken)]])
        )

        let (data, response) = try await httpClient.data(for: request, proxySettings: proxySettings)
        try Self.validate(response: response)

        let apiResponse = try JSONDecoder().decode(GDataResponse.self, from: data)
        guard let item = apiResponse.gmetadata.first else {
            throw GalleryMetadataFetchError.invalidResponse
        }
        if let error = item.error {
            throw GalleryMetadataFetchError.apiError(error)
        }

        return item.metadata(hash: hash, fallback: searchResult)
    }

    func fetchMetadata(hash: String, galleryURL: URL) async throws -> GalleryMetadata {
        let result = try Self.searchResult(fromGalleryURL: galleryURL)
        return try await fetchMetadata(hash: hash, searchResult: result)
    }

    func fetchMetadata(
        hash: String,
        galleryURL: URL,
        configuration: GalleryMetadataFetchConfiguration
    ) async throws -> GalleryMetadata {
        let result = try Self.searchResult(fromGalleryURL: galleryURL)
        return try await fetchMetadata(hash: hash, searchResult: result, proxySettings: configuration.proxySettings)
    }

    static func searchResult(fromGalleryURL url: URL) throws -> GallerySearchResult {
        guard
            let host = url.host?.lowercased(),
            host == GallerySearchSite.eHentai.searchHost || host == GallerySearchSite.exHentai.searchHost
        else {
            throw BookMetadataEditError.invalidGalleryURL
        }

        let components = url.pathComponents.filter { $0 != "/" }
        guard
            components.count >= 3,
            components[0] == "g",
            let galleryID = Int64(components[1]),
            !components[2].isEmpty
        else {
            throw BookMetadataEditError.invalidGalleryURL
        }

        return GallerySearchResult(
            title: url.absoluteString,
            url: url,
            galleryID: galleryID,
            galleryToken: components[2]
        )
    }

    static func isSupportedGalleryURL(_ url: URL) -> Bool {
        (try? searchResult(fromGalleryURL: url)) != nil
    }

    static func searchURL(hash: String, site: GallerySearchSite) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = site.searchHost
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "f_shash", value: hash),
            URLQueryItem(name: "fs_similar", value: "on"),
            URLQueryItem(name: "fs_exp", value: "on"),
            URLQueryItem(name: "f_cats", value: "161")
        ]

        guard let url = components.url else {
            throw GalleryMetadataFetchError.invalidSearchURL
        }
        return url
    }

    static func cookieHeader(for configuration: GalleryMetadataFetchConfiguration) -> String? {
        let requiredPairs = [
            ("igneous", configuration.igneous),
            ("ipb_pass_hash", configuration.ipbPassHash),
            ("ipb_member_id", configuration.ipbMemberID)
        ]

        guard requiredPairs.allSatisfy({ !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }

        var pairs = requiredPairs
        let star = configuration.star.trimmingCharacters(in: .whitespacesAndNewlines)
        if !star.isEmpty {
            pairs.append(("star", star))
        }

        return pairs
            .map { "\($0.0)=\($0.1.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "; ")
    }

    static func parseSearchResults(html: String, site: GallerySearchSite) -> [GallerySearchResult] {
        var seen = Set<String>()
        let containerResults = resultContainers(in: html).compactMap { container in
            searchResult(from: container, site: site, seen: &seen)
        }
        if !containerResults.isEmpty {
            return containerResults
        }

        return galleryLinks(in: html).compactMap { link in
            searchResult(from: link, site: site, seen: &seen)
        }
    }

    private static let userAgent = "NyaEH/1.0"

    private static func validate(response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw GalleryMetadataFetchError.httpStatus(response.statusCode)
        }
    }

    private static func validateSearchHTML(_ html: String, site: GallerySearchSite) throws {
        let lowercased = html.lowercased()
        if lowercased.contains("your ip address has been") {
            throw GalleryMetadataFetchError.ipBanned
        }

        guard site == .exHentai else {
            return
        }

        if lowercased.contains("sad panda")
            || lowercased.contains("exhentai.org is not available")
            || lowercased.contains("please log in")
            || lowercased.contains("not currently available")
            || lowercased.contains("this page requires")
        {
            throw GalleryMetadataFetchError.exHentaiAccessDenied
        }
    }

    private static func resultContainers(in html: String) -> [String] {
        let pattern = #"<[A-Za-z0-9]+\b[^>]*class\s*=\s*["']([^"']*)["'][^>]*>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html))
        let containerMatches = matches.filter { match in
            guard
                let classRange = Range(match.range(at: 1), in: html)
            else {
                return false
            }

            let classNames = html[classRange]
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            return classNames.contains("gl3c") && classNames.contains("glname")
        }

        return containerMatches.enumerated().compactMap { index, match in
            guard let startRange = Range(match.range(at: 0), in: html) else {
                return nil
            }

            let endIndex: String.Index
            if
                index + 1 < containerMatches.count,
                let nextRange = Range(containerMatches[index + 1].range(at: 0), in: html)
            {
                endIndex = nextRange.lowerBound
            } else {
                endIndex = html.endIndex
            }

            return String(html[startRange.lowerBound..<endIndex])
        }
    }

    private static func galleryLinks(in html: String) -> [GalleryLink] {
        let pattern = #"<a\b[^>]*href\s*=\s*["']([^"']*/g/(\d+)/([A-Za-z0-9]+)/?)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        return regex.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)).compactMap { match in
            guard
                let urlRange = Range(match.range(at: 1), in: html),
                let idRange = Range(match.range(at: 2), in: html),
                let tokenRange = Range(match.range(at: 3), in: html),
                let contentRange = Range(match.range(at: 4), in: html),
                let galleryID = Int64(html[idRange])
            else {
                return nil
            }

            return GalleryLink(
                urlString: String(html[urlRange]),
                galleryID: galleryID,
                galleryToken: String(html[tokenRange]),
                titleHTML: String(html[contentRange])
            )
        }
    }

    private static func firstGalleryLink(in html: String) -> GalleryLink? {
        galleryLinks(in: html).first
    }

    private static func searchResult(
        from html: String,
        site: GallerySearchSite,
        seen: inout Set<String>
    ) -> GallerySearchResult? {
        guard let link = firstGalleryLink(in: html) else {
            return nil
        }
        return searchResult(from: link, titleHTML: html, site: site, seen: &seen)
    }

    private static func searchResult(
        from link: GalleryLink,
        site: GallerySearchSite,
        seen: inout Set<String>
    ) -> GallerySearchResult? {
        searchResult(from: link, titleHTML: link.titleHTML, site: site, seen: &seen)
    }

    private static func searchResult(
        from link: GalleryLink,
        titleHTML: String,
        site: GallerySearchSite,
        seen: inout Set<String>
    ) -> GallerySearchResult? {
        let normalizedURLString = normalizeGalleryURL(link.urlString, site: site)
        guard !seen.contains(normalizedURLString), let url = URL(string: normalizedURLString) else {
            return nil
        }
        seen.insert(normalizedURLString)

        let title = extractTitle(fromHTML: titleHTML)
        return GallerySearchResult(
            title: title.isEmpty ? normalizedURLString : title,
            url: url,
            galleryID: link.galleryID,
            galleryToken: link.galleryToken
        )
    }

    private static func normalizeGalleryURL(_ urlString: String, site: GallerySearchSite) -> String {
        if urlString.hasPrefix("//") {
            return "https:\(urlString)"
        }
        if urlString.hasPrefix("/") {
            return "https://\(site.searchHost)\(urlString)"
        }
        return urlString
    }

    private static func isUsableSHA1(_ hash: String) -> Bool {
        let pattern = #"^[A-Fa-f0-9]{40}$"#
        return hash.range(of: pattern, options: .regularExpression) != nil
    }

    private static func extractTitle(fromHTML content: String) -> String {
        if let glinkRegex = try? NSRegularExpression(
            pattern: #"<div\b[^>]*class\s*=\s*["'][^"']*\bglink\b[^"']*["'][^>]*>(.*?)</div>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            if
                let match = glinkRegex.firstMatch(in: content, range: range),
                let titleRange = Range(match.range(at: 1), in: content)
            {
                return Self.decodeHTMLText(String(content[titleRange]))
            }
        }

        return Self.decodeHTMLText(content)
    }

    private static func decodeHTMLText(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        return withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum GalleryMetadataFetchError: LocalizedError, Equatable {
    case invalidHash
    case invalidSearchURL
    case missingExHentaiCookies
    case noSearchResults
    case invalidResponse
    case httpStatus(Int)
    case ipBanned
    case exHentaiAccessDenied
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidHash:
            return "This book does not have a usable SHA1 hash."
        case .invalidSearchURL:
            return "Unable to build the gallery search URL."
        case .missingExHentaiCookies:
            return "ExHentai search requires igneous, ipb_pass_hash, and ipb_member_id cookies."
        case .noSearchResults:
            return "No matching gallery was found for this hash."
        case .invalidResponse:
            return "The gallery metadata response could not be read."
        case .httpStatus(let statusCode):
            return "Gallery metadata request failed with HTTP \(statusCode)."
        case .ipBanned:
            return "Gallery metadata request failed because the IP address appears to be temporarily banned."
        case .exHentaiAccessDenied:
            return "ExHentai returned an access page. Check that the ExHentai cookie values are valid and have permission."
        case .apiError(let message):
            return "Gallery metadata API error: \(message)"
        }
    }
}

private struct GalleryLink {
    var urlString: String
    var galleryID: Int64
    var galleryToken: String
    var titleHTML: String
}

private struct GDataRequest: Encodable {
    var method = "gdata"
    var gidlist: [[GDataValue]]
    var namespace = 1
}

private enum GDataValue: Encodable {
    case int(Int64)
    case string(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

private struct GDataResponse: Decodable {
    var gmetadata: [GDataItem]
}

private struct GDataItem: Decodable {
    var gid: FlexibleInt64?
    var token: String?
    var title: String?
    var titleJpn: String?
    var category: String?
    var posted: FlexibleInt64?
    var filecount: FlexibleInt?
    var filesize: FlexibleInt64?
    var rating: FlexibleDouble?
    var tags: [String]?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case gid
        case token
        case title
        case titleJpn = "title_jpn"
        case category
        case posted
        case filecount
        case filesize
        case rating
        case tags
        case error
    }

    func metadata(hash: String, fallback: GallerySearchResult) -> GalleryMetadata {
        let tagsJSON: String
        if let tags, let data = try? JSONEncoder().encode(tags), let encoded = String(data: data, encoding: .utf8) {
            tagsJSON = encoded
        } else {
            tagsJSON = "[]"
        }

        return GalleryMetadata(
            hash: hash,
            galleryID: gid?.value ?? fallback.galleryID,
            galleryToken: token ?? fallback.galleryToken,
            title: title ?? fallback.title,
            titleJpn: titleJpn,
            status: .correct,
            rating: rating?.value,
            tags: tagsJSON,
            pages: filecount?.value,
            posted: posted?.value,
            filesize: filesize?.value,
            category: category,
            url: fallback.url.absoluteString
        )
    }
}

private struct FlexibleInt: Decodable {
    var value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else {
            let stringValue = try container.decode(String.self)
            value = Int(stringValue) ?? 0
        }
    }
}

private struct FlexibleInt64: Decodable {
    var value: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int64.self) {
            value = intValue
        } else {
            let stringValue = try container.decode(String.self)
            value = Int64(stringValue) ?? 0
        }
    }
}

private struct FlexibleDouble: Decodable {
    var value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else {
            let stringValue = try container.decode(String.self)
            value = Double(stringValue) ?? 0
        }
    }
}
