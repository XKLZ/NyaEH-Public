// 本文件定义 WorkDetailRepository 数据访问协议，隔离服务层和具体 SQLite 实现。

import Foundation

protocol WorkDetailRepository {
    func fetchWorkDetail(parodyTagID: Tag.DatabaseID, languageCode: String?) throws -> WorkDetail?
    func fetchCharacterDetail(characterTagID: Tag.DatabaseID, languageCode: String?) throws -> CharacterDetail?
    func fetchWorkCharacterCandidates(parodyTagID: Tag.DatabaseID, languageCode: String?) throws -> [WorkCharacterCandidate]
    func addCharacterTag(to bookID: LibraryBook.DatabaseID, pair: WorkCharacterPair) throws -> WorkCharacterTagAddition
    func setWorkCharacterDecision(_ decision: WorkCharacterManualDecision?, pair: WorkCharacterPair) throws
    func setAutomaticClaimSuppressed(_ isSuppressed: Bool, bookID: LibraryBook.DatabaseID, pair: WorkCharacterPair) throws
}
