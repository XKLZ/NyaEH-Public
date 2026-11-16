// 本文件定义 LibrarySearchRepository 数据访问协议，隔离服务层和具体 SQLite 实现。

import Foundation

protocol LibrarySearchRepository {
    func search(_ request: LibrarySearchRequest) throws -> LibrarySearchResponse
    func tagFacets(_ request: LibrarySearchRequest, knownTotalCount: Int?) throws -> [SearchTagFacet]
    func tagSuggestions(_ request: SearchTagSuggestionRequest) throws -> [SearchTagSuggestion]
}
