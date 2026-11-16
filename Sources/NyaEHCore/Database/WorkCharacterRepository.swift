// 本文件定义 WorkCharacterRepository 数据访问协议，隔离服务层和具体 SQLite 实现。

import Foundation

protocol WorkCharacterRepository {
    func rebuildIndex() throws -> WorkCharacterIndexUpdateResult
    func updateIndexIncrementally() throws -> WorkCharacterIndexUpdateResult
    func hasIncrementalChanges() throws -> Bool
    func fetchWorks(languageCode: String?) throws -> [WorkCharacterWorkSummary]
    func fetchCharacters(parodyTagID: Tag.DatabaseID, languageCode: String?) throws -> [WorkCharacterCharacterSummary]
}
