import Foundation
import Testing
@testable import NyaEHCore

@Suite("NyaEH development configuration")
struct NyaEHDevelopmentConfigurationTests {
    @Test("explicit comic archive environment path takes priority")
    func explicitEnvironmentPathTakesPriority() {
        let currentDirectory = URL(fileURLWithPath: "/tmp/nyaeh-checkout", isDirectory: true)
        let configuration = NyaEHDevelopmentConfiguration.resolved(
            environment: [
                NyaEHDevelopmentConfiguration.comicArchiveEnvironmentKey:
                    "/tmp/custom-reader-fixture.zip"
            ],
            currentDirectoryURL: currentDirectory
        )

        #expect(configuration.readerTestArchiveURL.path == "/tmp/custom-reader-fixture.zip")
    }

    @Test("missing environment path falls back to repository development fixture")
    func missingEnvironmentPathUsesRepositoryFixture() {
        let currentDirectory = URL(fileURLWithPath: "/tmp/nyaeh-checkout", isDirectory: true)
        let configuration = NyaEHDevelopmentConfiguration.resolved(
            environment: [:],
            currentDirectoryURL: currentDirectory
        )

        #expect(
            configuration.readerTestArchiveURL.path
                == "/tmp/nyaeh-checkout/.nyaeh-dev/comic/comictest.zip"
        )
    }
}
