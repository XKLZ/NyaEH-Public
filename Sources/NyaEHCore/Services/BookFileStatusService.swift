// 本文件把源文件存在性转换为书籍状态，缺失文件以状态表达而不是抛成致命错误。

import Foundation

struct BookFileStatusService {
    func status(forFilepath filepath: String) -> (status: BookStatus, exist: Bool) {
        let exists = FileManager.default.fileExists(atPath: filepath)
        return exists ? (.correct, true) : (.missing, false)
    }
}
