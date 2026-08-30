import Foundation
import XCTest
@testable import Container_GUI

final class MachineManagementTests: XCTestCase {

    // MARK: - Value types

    func testMachineIdentifierValidation() throws {
        for valid in ["dev", "alpine-3.22", "kvm_lab", "a.b-c_1", "UPPER"] {
            XCTAssertNoThrow(try MachineIdentifier(validating: valid), "Rejected \(valid)")
        }
        for invalid in ["", "-leading-dash", "has space", "has/slash", "quote\"mark", "new\nline"] {
            XCTAssertThrowsError(try MachineIdentifier(validating: invalid), "Accepted \(invalid)")
        }
    }

    /// `machine set memory=100M` fails with "Must be greater than 1gb", so the
    /// rule is enforced here rather than round-tripping through the CLI.
    func testMachineMemoryEnforcesTheCLIMinimum() throws {
        XCTAssertEqual(try MachineMemory("8G").value, "8G")
        XCTAssertEqual(try MachineMemory("2048M").value, "2048M")
        XCTAssertEqual(try MachineMemory("2GB").value, "2GB")

        for tooSmall in ["1G", "100M", "512M", "1024M", "900K"] {
            XCTAssertThrowsError(try MachineMemory(tooSmall), "Accepted \(tooSmall)")
        }
        for malformed in ["", "G", "8Q", "-8G", "8.5G", "eight"] {
            XCTAssertThrowsError(try MachineMemory(malformed), "Accepted \(malformed)")
        }
    }

    func testMachineCPUCountAndHomeMount() throws {
        XCTAssertEqual(try MachineCPUCount(8).value, 8)
        XCTAssertThrowsError(try MachineCPUCount(0))
        XCTAssertThrowsError(try MachineCPUCount(-1))
        XCTAssertThrowsError(try MachineCPUCount(2_048))

        XCTAssertEqual(try MachineHomeMount(validating: "RW"), .readWrite)
        XCTAssertEqual(try MachineHomeMount(validating: "ro"), .readOnly)
        XCTAssertEqual(try MachineHomeMount(validating: "none"), MachineHomeMount.none)
        XCTAssertThrowsError(try MachineHomeMount(validating: "bogus"))
    }

    /// The design shows the kernel as a tilde path, which `LocalPath` would
    /// reject outright.
    func testMachineKernelPathExpandsTilde() throws {
        let expanded = try MachineKernelPath(validating: "~/kernels/vmlinux-6.13")
        XCTAssertTrue(expanded.rawValue.hasPrefix("/"))
        XCTAssertTrue(expanded.rawValue.hasSuffix("/kernels/vmlinux-6.13"))
        XCTAssertFalse(expanded.rawValue.contains("~"))

        XCTAssertEqual(
            try MachineKernelPath(validating: "/opt/kernels/vmlinux").rawValue,
            "/opt/kernels/vmlinux"
        )
        XCTAssertThrowsError(try MachineKernelPath(validating: ""))
        XCTAssertThrowsError(try MachineKernelPath(validating: "   "))
        XCTAssertThrowsError(try MachineKernelPath(validating: "relative/vmlinux"))
    }

    func testMachineStateDegradesUnknownValues() {
        XCTAssertEqual(MachineState("running"), .running)
        XCTAssertEqual(MachineState("Stopped"), .stopped)
        XCTAssertEqual(MachineState("exited"), .stopped)
        XCTAssertEqual(MachineState("provisioning"), .unknown("provisioning"))
        XCTAssertEqual(MachineState(nil), .unknown("unknown"))
    }

    /// `container machine` arrived in Apple Container 1.0.0; the app supports
    /// 0.12.0 upward, so the destination has to disappear below that.
    func testMachineCapabilitiesGateOnOnePointZero() throws {
        XCTAssertFalse(MachineCapabilities(version: try SemanticVersion("0.12.0")).isSupported)
        XCTAssertFalse(MachineCapabilities(version: try SemanticVersion("0.99.9")).isSupported)
        XCTAssertTrue(MachineCapabilities(version: try SemanticVersion("1.0.0")).isSupported)
        XCTAssertTrue(MachineCapabilities(version: try SemanticVersion("1.3.0")).isSupported)
    }

    // MARK: - Boot configuration

    func testBootConfigurationSerialisesBothWays() throws {
        let boot = MachineBootConfiguration(
            cpus: try MachineCPUCount(8),
            memory: try MachineMemory("8G"),
            homeMount: .readOnly,
            virtualization: true,
            kernel: try MachineKernelPath(validating: "/opt/kernels/vmlinux")
        )

        XCTAssertEqual(
            boot.settings,
            ["cpus=8", "memory=8G", "home-mount=ro", "virtualization=true", "kernel=/opt/kernels/vmlinux"]
        )
        XCTAssertEqual(
            boot.createFlags,
            ["--cpus", "8", "--memory", "8G", "--home-mount", "ro", "--virtualization",
             "--kernel", "/opt/kernels/vmlinux"]
        )
        XCTAssertFalse(boot.isEmpty)
        XCTAssertTrue(MachineBootConfiguration().isEmpty)
    }

    /// Clearing the kernel is not the same as leaving it alone: the CLI resets
    /// to the system kernel only when it receives an empty value.
    func testResettingTheKernelIsDistinctFromLeavingItAlone() {
        var untouched = MachineBootConfiguration()
        untouched.cpus = try? MachineCPUCount(4)
        XCTAssertEqual(untouched.settings, ["cpus=4"])

        var reset = MachineBootConfiguration()
        reset.resetsKernel = true
        XCTAssertEqual(reset.settings, ["kernel="])
        XCTAssertFalse(reset.isEmpty)

        // An explicit path wins over the reset flag rather than emitting both.
        var both = MachineBootConfiguration()
        both.kernel = try? MachineKernelPath(validating: "/opt/vmlinux")
        both.resetsKernel = true
        XCTAssertEqual(both.settings, ["kernel=/opt/vmlinux"])
    }

    /// `virtualization` is only a create flag when enabled — the CLI has no
    /// `--no-virtualization`, so false must not emit anything.
    func testVirtualizationOnlyAppearsAsACreateFlagWhenEnabled() {
        var disabled = MachineBootConfiguration()
        disabled.virtualization = false
        XCTAssertEqual(disabled.createFlags, [])
        XCTAssertEqual(disabled.settings, ["virtualization=false"])
    }

    // MARK: - Command arguments

    func testCreateConfigurationArguments() throws {
        let configuration = try MachineCreateConfiguration(
            image: "alpine:3.22",
            name: "alpine-3-22",
            operatingSystem: "linux",
            architecture: "arm64",
            boot: MachineBootConfiguration(
                cpus: try MachineCPUCount(8),
                memory: try MachineMemory("8G"),
                homeMount: .readWrite
            ),
            setsDefault: true,
            bootsAfterCreating: false
        )

        XCTAssertEqual(
            ContainerCommand.createMachine(configuration: configuration).arguments,
            ["machine", "create", "--name", "alpine-3-22", "--os", "linux", "--arch", "arm64",
             "--cpus", "8", "--memory", "8G", "--home-mount", "rw",
             "--set-default", "--no-boot", "alpine:3.22"]
        )

        // The image is positional and must stay last, after every flag.
        let minimal = try MachineCreateConfiguration(image: "alpine:3.22")
        XCTAssertEqual(minimal.arguments, ["machine", "create", "alpine:3.22"])
        XCTAssertEqual(minimal.arguments.last, "alpine:3.22")

        XCTAssertThrowsError(try MachineCreateConfiguration(image: ""))
        XCTAssertThrowsError(try MachineCreateConfiguration(image: "alpine", name: "bad name"))
    }

    func testSetConfigurationArguments() throws {
        let named = try MachineSetConfiguration(
            name: "kvm-lab",
            boot: MachineBootConfiguration(
                cpus: try MachineCPUCount(8),
                homeMount: .readOnly
            )
        )
        XCTAssertEqual(
            ContainerCommand.setMachineConfiguration(named).arguments,
            ["machine", "set", "--name", "kvm-lab", "cpus=8", "home-mount=ro"]
        )

        // Omitting the name is how the CLI's default-machine fallback is reached.
        let defaulted = try MachineSetConfiguration(
            name: nil,
            boot: MachineBootConfiguration(cpus: try MachineCPUCount(2))
        )
        XCTAssertEqual(defaulted.arguments, ["machine", "set", "cpus=2"])

        // Nothing to change is a programming error, not an empty command.
        XCTAssertThrowsError(
            try MachineSetConfiguration(name: "kvm-lab", boot: MachineBootConfiguration())
        )
    }

    func testRunConfigurationArguments() throws {
        let shell = try MachineRunConfiguration(name: "ubuntu-24-04")
        XCTAssertTrue(shell.isLoginShell)
        XCTAssertEqual(
            shell.arguments,
            ["machine", "run", "--name", "ubuntu-24-04", "--interactive", "--tty"]
        )

        let command = try MachineRunConfiguration(
            name: "ubuntu-24-04",
            command: ["nproc"],
            environment: [try EnvironmentVariable(key: "RUST_LOG", value: "debug")],
            environmentFile: "/Users/test/.env.local",
            workingDirectory: "/Users/test/code",
            interactive: false,
            tty: false,
            detached: true
        )
        XCTAssertFalse(command.isLoginShell)
        XCTAssertEqual(
            command.arguments,
            ["machine", "run", "--name", "ubuntu-24-04", "--env", "RUST_LOG=debug",
             "--env-file", "/Users/test/.env.local", "--workdir", "/Users/test/code",
             "--detach", "--", "nproc"]
        )

        // `--` separates the command so an argument starting with a dash cannot
        // be read as a flag to `machine run` itself.
        let dashed = try MachineRunConfiguration(name: "dev", command: ["ls", "-la"])
        XCTAssertEqual(Array(dashed.arguments.suffix(3)), ["--", "ls", "-la"])

        XCTAssertThrowsError(try MachineRunConfiguration(name: "dev", user: "bad user"))
        XCTAssertThrowsError(
            try MachineRunConfiguration(name: "dev", user: "root", runsAsRoot: true)
        )
    }

    func testLogOptionArguments() throws {
        let boot = try MachineLogOptions(
            name: "kvm-lab",
            showsBootLog: true,
            follow: true,
            tail: 200
        )
        XCTAssertEqual(
            ContainerCommand.machineLogs(boot).arguments,
            ["machine", "logs", "--boot", "--follow", "-n", "200", "kvm-lab"]
        )

        let stdio = try MachineLogOptions(name: nil)
        XCTAssertEqual(stdio.arguments, ["machine", "logs"])

        XCTAssertThrowsError(try MachineLogOptions(name: "dev", tail: 0))
        XCTAssertThrowsError(try MachineLogOptions(name: "dev", tail: -5))
    }

    func testSimpleMachineCommandArguments() throws {
        let id = try MachineIdentifier(validating: "dev-box")

        XCTAssertEqual(
            ContainerCommand.listMachines.arguments,
            ["machine", "list", "--format", "json"]
        )
        XCTAssertEqual(
            ContainerCommand.inspectMachine(id: id).arguments,
            ["machine", "inspect", "dev-box"]
        )
        XCTAssertEqual(
            ContainerCommand.inspectMachine(id: nil).arguments,
            ["machine", "inspect"]
        )
        XCTAssertEqual(
            ContainerCommand.setDefaultMachine(id: id).arguments,
            ["machine", "set-default", "dev-box"]
        )
        XCTAssertEqual(
            ContainerCommand.stopMachine(id: id).arguments,
            ["machine", "stop", "dev-box"]
        )
        XCTAssertEqual(ContainerCommand.stopMachine(id: nil).arguments, ["machine", "stop"])
        XCTAssertEqual(
            ContainerCommand.deleteMachine(id: id).arguments,
            ["machine", "delete", "dev-box"]
        )
    }
}
