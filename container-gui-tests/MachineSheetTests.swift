import Foundation
import XCTest
@testable import Container_GUI

@MainActor
final class MachineSheetTests: XCTestCase {

    // MARK: - Host defaults

    func testHostDefaultsFollowTheCLIsOwnRules() {
        let defaults = MachineHostDefaults()

        // Half the cores, never fewer than four.
        XCTAssertGreaterThanOrEqual(defaults.cpus, 4)
        XCTAssertTrue(
            defaults.memory.hasSuffix("G"),
            "Memory should be expressed the way --memory wants it, got \(defaults.memory)"
        )
        // Whatever it computed must survive the validator the sheet uses.
        XCTAssertNoThrow(try MachineMemory(defaults.memory))
    }

    /// Nested virtualization needs Apple Silicon M3 or newer; an Intel Mac or an
    /// unrecognised brand string must read as unsupported rather than crashing.
    func testChipGenerationParsing() {
        XCTAssertEqual(MachineHostDefaults.chipGeneration("Apple M3 Pro"), 3)
        XCTAssertEqual(MachineHostDefaults.chipGeneration("Apple M4"), 4)
        XCTAssertEqual(MachineHostDefaults.chipGeneration("Apple M1 Ultra"), 1)
        XCTAssertEqual(MachineHostDefaults.chipGeneration("Apple M14 Max"), 14)
        XCTAssertNil(MachineHostDefaults.chipGeneration("Intel(R) Core(TM) i9-9880H"))
        XCTAssertNil(MachineHostDefaults.chipGeneration(nil))
        XCTAssertNil(MachineHostDefaults.chipGeneration(""))
    }

    // MARK: - Create sheet

    func testCreateSheetOpensSubmittableOnceAnImageIsNamed() {
        let draft = MachineCreateModel()

        XCTAssertFalse(draft.canCreate, "An image is the one thing the CLI cannot default.")

        draft.image = "alpine:3.22"
        XCTAssertTrue(draft.canCreate)
        XCTAssertNil(draft.imageError)
        XCTAssertNil(draft.memoryError)
    }

    /// The preview should list what the user changed, not repeat the defaults
    /// the CLI would have computed anyway.
    func testCreatePreviewOmitsThePlatformWhenItMatchesTheHost() {
        let draft = MachineCreateModel()
        draft.image = "alpine:3.22"

        let preview = draft.commandPreview
        XCTAssertTrue(preview.contains("machine create"))
        XCTAssertTrue(preview.contains("alpine:3.22"))
        XCTAssertFalse(preview.contains("--os"), "linux is the default, got: \(preview)")
        XCTAssertFalse(preview.contains("--arch"), "The host arch is the default, got: \(preview)")
    }

    func testCreateSheetSurfacesInvalidInput() {
        let draft = MachineCreateModel()
        draft.image = "alpine:3.22"

        draft.name = "not a valid name"
        XCTAssertNotNil(draft.nameError)
        XCTAssertFalse(draft.canCreate)

        draft.name = ""
        draft.memory = "100M"
        XCTAssertNotNil(draft.memoryError, "The CLI rejects anything at or below 1G.")
        XCTAssertFalse(draft.canCreate)

        draft.memory = "8G"
        XCTAssertTrue(draft.canCreate)
    }

    func testBootAndDefaultTogglesReachTheCommand() {
        let draft = MachineCreateModel()
        draft.image = "alpine:3.22"
        draft.bootsAfterCreating = false
        draft.setsDefault = true

        let arguments = draft.configuration?.arguments ?? []
        XCTAssertTrue(arguments.contains("--no-boot"))
        XCTAssertTrue(arguments.contains("--set-default"))
    }

    // MARK: - Boot configuration editor

    private func inspection(
        id: String = "kvm-lab",
        status: String = "running",
        cpus: Int = 4,
        memory: UInt64 = 8_589_934_592,
        homeMount: String = "rw"
    ) throws -> MachineInspection {
        let raw = """
        {"id":"\(id)","status":"\(status)","cpus":\(cpus),"memory":\(memory),"homeMount":"\(homeMount)"}
        """
        let dto = try JSONDecoder().decode(MachineInspectionDTO.self, from: Data(raw.utf8))
        return try XCTUnwrap(MachineInspection(dto: dto, rawJSON: raw))
    }

    func testEditorOpensWithNoChangesPending() throws {
        let draft = MachineBootConfigurationModel(
            inspection: try inspection(),
            pending: nil
        )

        XCTAssertEqual(draft.changeCount, 0)
        XCTAssertFalse(draft.canApply, "Applying nothing would build a `machine set` with no settings.")
        XCTAssertEqual(draft.cpus, 4)
        XCTAssertEqual(draft.memory, "8G")
        XCTAssertEqual(draft.homeMount, .readWrite)
    }

    /// Only what differs from the running values is sent, which is what makes
    /// the command preview match the design's promise.
    func testOnlyChangedSettingsAreSent() throws {
        let draft = MachineBootConfigurationModel(
            inspection: try inspection(),
            pending: nil
        )

        draft.cpus = 8
        draft.homeMount = .readOnly

        XCTAssertEqual(draft.changes.settings, ["cpus=8", "home-mount=ro"])
        XCTAssertEqual(draft.changeCount, 2)
        XCTAssertTrue(draft.canApply)
        XCTAssertTrue(draft.commandPreview.contains("cpus=8"))
        XCTAssertFalse(
            draft.commandPreview.contains("memory="),
            "Memory was not touched, so it should not appear: \(draft.commandPreview)"
        )
    }

    func testRevertRestoresTheRunningValues() throws {
        let draft = MachineBootConfigurationModel(
            inspection: try inspection(),
            pending: nil
        )
        draft.cpus = 16
        draft.memory = "32G"
        draft.homeMount = MachineHomeMount.none
        XCTAssertEqual(draft.changeCount, 3)

        draft.revert()

        XCTAssertEqual(draft.changeCount, 0)
        XCTAssertEqual(draft.cpus, 4)
        XCTAssertEqual(draft.memory, "8G")
        XCTAssertEqual(draft.homeMount, .readWrite)
    }

    /// Reopening the editor on a machine with an unapplied change shows what it
    /// will boot with, not what it is running on.
    func testEditorOpensOnThePendingValuesWhenThereAreSome() throws {
        let pending = MachineBootConfiguration(
            cpus: try MachineCPUCount(8),
            homeMount: .readOnly
        )
        let draft = MachineBootConfigurationModel(
            inspection: try inspection(),
            pending: pending
        )

        XCTAssertEqual(draft.cpus, 8)
        XCTAssertEqual(draft.homeMount, .readOnly)
        XCTAssertEqual(draft.currentCPUs, 4, "The running column still shows the live value.")
        XCTAssertEqual(draft.changeCount, 2)
    }

    /// Clearing the field asks the CLI to fall back to the system kernel, which
    /// it spells as an empty value — not as leaving the setting alone.
    func testClearingTheKernelSendsAnExplicitReset() throws {
        let raw = """
        {"id":"kvm-lab","status":"running","cpus":4,"memory":8589934592,"kernelPath":"/opt/vmlinux"}
        """
        let dto = try JSONDecoder().decode(MachineInspectionDTO.self, from: Data(raw.utf8))
        let draft = MachineBootConfigurationModel(
            inspection: try XCTUnwrap(MachineInspection(dto: dto, rawJSON: raw)),
            pending: nil
        )
        XCTAssertEqual(draft.kernelPath, "/opt/vmlinux")

        draft.kernelPath = ""

        XCTAssertEqual(draft.changes.settings, ["kernel="])
    }

    func testAnUnreadableKernelIsRejectedBeforeApplying() throws {
        let draft = MachineBootConfigurationModel(
            inspection: try inspection(),
            pending: nil
        )

        draft.kernelPath = "/nonexistent/vmlinux-6.13"
        XCTAssertNotNil(draft.kernelError)
        XCTAssertFalse(draft.canApply)

        // An existing readable file passes — this test bundle's own binary will do.
        draft.kernelPath = URL(fileURLWithPath: #filePath).path
        XCTAssertNil(draft.kernelError)
        XCTAssertTrue(draft.canApply)
    }

    func testAStoppedMachineIsNotDescribedAsDeferring() throws {
        let draft = MachineBootConfigurationModel(
            inspection: try inspection(status: "stopped"),
            pending: nil
        )
        XCTAssertFalse(draft.isRunning)
    }

    func testMemoryRoundTripsInTheUnitsTheCLIAccepts() {
        XCTAssertEqual(MachineBootConfigurationModel.formatMemory(8_589_934_592), "8G")
        XCTAssertEqual(MachineBootConfigurationModel.formatMemory(9_663_676_416), "9G")
        // Whatever it prints must be re-parseable, since it goes straight back
        // into the field the user can submit.
        XCTAssertNoThrow(
            try MachineMemory(MachineBootConfigurationModel.formatMemory(9_663_676_416))
        )
    }
}
