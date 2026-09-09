import XCTest
@testable import CargoDeck

final class ContainerConfigFileTests: XCTestCase {
    private let path = "/Users/test/.config/container/config.toml"

    private func setting(_ domain: String, in text: String) throws -> String {
        try ConfigTOML.settingServiceDomain(domain, in: text, path: path)
    }

    func testReplacesTheDomainInTheShippingConfig() throws {
        let existing = "[dns]\ndomain = \"cont\"\n"
        XCTAssertEqual(try setting("test", in: existing), "[dns]\ndomain = \"test\"\n")
    }

    func testWritesTheTableIntoAnEmptyOrMissingFile() throws {
        XCTAssertEqual(try setting("test", in: ""), "[dns]\ndomain = \"test\"\n")
    }

    func testAppendsTheTableWithoutTouchingOtherSettings() throws {
        let existing = """
        # Tuned by hand.
        [build]
        cpus = 2
        memory = "2048mb"

        [registry]
        domain = "ghcr.io"

        """
        let updated = try setting("test", in: existing)
        XCTAssertTrue(updated.hasPrefix(existing))
        XCTAssertTrue(updated.hasSuffix("[dns]\ndomain = \"test\"\n"))
        XCTAssertFalse(updated.contains("\n\n\n"))
        // The registry table has its own `domain`, which must survive untouched.
        XCTAssertTrue(updated.contains("[registry]\ndomain = \"ghcr.io\""))
    }

    func testOnlyTheDNSDomainChangesWhenOtherTablesHaveOne() throws {
        let existing = """
        [registry]
        domain = "docker.io"

        [dns]
        domain = "cont"

        [build]
        cpus = 4
        """
        let updated = try setting("test", in: existing)
        XCTAssertEqual(updated, """
        [registry]
        domain = "docker.io"

        [dns]
        domain = "test"

        [build]
        cpus = 4
        """)
    }

    func testAddsTheKeyToAnExistingButEmptyDNSTable() throws {
        let existing = "[dns]\n\n[build]\ncpus = 2\n"
        XCTAssertEqual(try setting("test", in: existing), "[dns]\ndomain = \"test\"\n\n[build]\ncpus = 2\n")
    }

    func testKeepsCommentsIndentationAndQuotedKeys() throws {
        let existing = "[dns]  # local names\n  \"domain\"  =  'cont'  # was test\n"
        XCTAssertEqual(try setting("test", in: existing), "[dns]  # local names\ndomain = \"test\"\n")
    }

    func testUpdatesADottedKeyInPlace() throws {
        let existing = "dns.domain = \"cont\"\n[build]\ncpus = 2\n"
        XCTAssertEqual(try setting("test", in: existing), "dns.domain = \"test\"\n[build]\ncpus = 2\n")
    }

    func testDoesNotMistakeAnotherTablesDomainForTheDNSOne() throws {
        let existing = "[registry]\ndomain = \"docker.io\"\n"
        let updated = try setting("test", in: existing)
        XCTAssertTrue(updated.contains("[registry]\ndomain = \"docker.io\""))
        XCTAssertTrue(updated.contains("[dns]\ndomain = \"test\""))
    }

    func testRefusesToEditShapesItCannotChangeSafely() {
        for existing in ["dns = { domain = \"cont\" }\n", "[[dns]]\ndomain = \"cont\"\n"] {
            XCTAssertThrowsError(try setting("test", in: existing)) { error in
                XCTAssertEqual(error as? ConfigFileError, .unsupportedLayout(path: path))
            }
        }
    }

    func testWritesAndRewritesARealFileWithoutLosingTheRest() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cargodeck-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: ".config/container/config.toml")
        let file = ContainerConfigFile(url: url)

        // The directory does not exist yet, which is the first-run case.
        XCTAssertEqual(try file.writeServiceDomain(DNSDomainName(validating: "test")), url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[dns]\ndomain = \"test\"\n")

        try "[build]\ncpus = 2\n\n[dns]\ndomain = \"test\"\n".write(to: url, atomically: true, encoding: .utf8)
        _ = try file.writeServiceDomain(DNSDomainName(validating: "svc.test"))
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "[build]\ncpus = 2\n\n[dns]\ndomain = \"svc.test\"\n"
        )
    }

    func testWritingAnUnchangedDomainLeavesTheFileAlone() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cargodeck-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.toml")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // No trailing newline, so a needless rewrite would be visible.
        try "[dns]\ndomain = \"cont\"".write(to: url, atomically: true, encoding: .utf8)

        _ = try ContainerConfigFile(url: url).writeServiceDomain(DNSDomainName(validating: "cont"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[dns]\ndomain = \"cont\"")
    }
}
