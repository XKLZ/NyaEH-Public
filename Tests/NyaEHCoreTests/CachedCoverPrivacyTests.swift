import AppKit
import SwiftUI
import Testing
@testable import NyaEHCore

@Suite("First frame of a cached cover")
struct CachedCoverPrivacyTests {
    @MainActor @Test(arguments: [CoverPrivacyMode.blur, .conceal, .off])
    func fittedCoverLeavesSideMarginClear(mode: CoverPrivacyMode) throws {
        let path = UUID().uuidString
        let book = LibraryBook(title: "Fit", coverPath: path, hash: path, filepath: path)
        let source = try #require(ImageRenderer(content: Color.red.frame(width: 30, height: 60)).nsImage)
        CoverImageCache.shared.store(source, for: path, pixelBucket: 512, cost: 7200)
        defer { CoverImageCache.shared.removeImage(for: path) }
        let cover = BookCoverThumbnail(book: book, width: 100, height: 60, cornerRadius: 4,
                                       fitsEntireImage: true, showsFitBackground: false)
            .environment(\.coverPrivacyRule, CoverPrivacyRule(mode: mode))
        let image = try #require(ImageRenderer(content: cover).cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        #expect(try #require(bitmap.colorAt(x: 14, y: 30)).alphaComponent > 0.9)
        #expect(try #require(bitmap.colorAt(x: 35, y: 30)).alphaComponent < 0.01)
    }

    @MainActor @Test(arguments: [ColorScheme.light, .dark])
    func concealmentIsOpaqueOnFirstRender(scheme: ColorScheme) throws {
        let path = "privacy-fixture-" + UUID().uuidString
        let book = LibraryBook(title: "Synthetic cover", coverPath: path, hash: path, filepath: path)
        let source = try #require(ImageRenderer(content: Color.red.frame(width: 40, height: 40)).nsImage)
        CoverImageCache.shared.store(source, for: path, pixelBucket: 512, cost: 40 * 40 * 4)
        defer { CoverImageCache.shared.removeImage(for: path) }

        func sample(_ mode: CoverPrivacyMode) throws -> NSColor {
            let thumbnail = BookCoverThumbnail(book: book, width: 40, height: 40, cornerRadius: 3)
                .environment(\.coverPrivacyRule, CoverPrivacyRule(mode: mode, revealDelay: 0))
                .environment(\.colorScheme, scheme)
            let image = try #require(ImageRenderer(content: thumbnail).cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            return try #require(bitmap.colorAt(x: 6, y: 6)?.usingColorSpace(.sRGB))
        }

        let original = try sample(.off)
        #expect(original.redComponent - original.greenComponent > 0.5)
        let protected = try sample(.conceal)
        #expect(protected.alphaComponent > 0.99)
        #expect(abs(protected.redComponent - protected.greenComponent) < 0.04)
        #expect(abs(protected.redComponent - protected.blueComponent) < 0.04)
    }
}
