import SwiftUI

struct ContainerConfigurationView: View {
    let inspection: ContainerInspection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Container Configuration")
                        .font(.title2.bold())
                    Spacer()
                    InspectionCopyRawJSONButton(rawJSON: inspection.rawJSON)
                }

                ContainerIdentitySection(details: inspection.details)
                ContainerProcessSection(process: inspection.details.process)
                ContainerResourcesSection(
                    resources: inspection.details.resources,
                    sharedMemorySize: inspection.details.shmSize
                )
                ContainerRuntimeSection(details: inspection.details)
                ContainerNetworkInspectionSection(
                    activeNetworks: inspection.details.networks,
                    configuredNetworks: inspection.details.configuredNetworks,
                    dns: inspection.details.dns
                )
                ContainerExposureSection(
                    ports: inspection.details.ports,
                    sockets: inspection.details.sockets
                )
                ContainerMountInspectionSection(mounts: inspection.details.mounts)
                ContainerSecuritySection(details: inspection.details)
                ContainerMetadataSection(
                    labels: inspection.details.labels,
                    sysctls: inspection.details.sysctls
                )
            }
            .padding()
        }
        .accessibilityIdentifier("container.configuration")
    }
}

private struct ContainerIdentitySection: View {
    let details: ContainerDetails

    var body: some View {
        InspectionSection("General", systemImage: "shippingbox") {
            InspectionValueRow("ID / Name", value: details.id)
            InspectionValueRow("State", value: details.summary.state.localizedTitleString)
            InspectionValueRow("Image", value: details.summary.image)
            InspectionValueRow("Image digest", value: details.imageDigest)
            InspectionValueRow("Platform", value: inspectionPlatform(details.platform))
            InspectionValueRow("Created", value: details.createdAt?.formatted(date: .abbreviated, time: .standard))
            InspectionValueRow("Started", value: details.startedAt?.formatted(date: .abbreviated, time: .standard))
            InspectionValueRow("Exit code", value: details.exitCode.map(String.init))
        }
    }
}

private struct ContainerProcessSection: View {
    let process: InitProcessDTO?

    var body: some View {
        InspectionSection("Process", systemImage: "terminal") {
            InspectionValueRow("Executable", value: process?.executable)
            InspectionValueRow("Working directory", value: process?.workingDirectory)
            InspectionValueRow("User", value: process?.user?.processUserDescription)
            if let terminal = process?.terminal {
                InspectionBooleanRow(label: "Terminal", value: terminal)
            }

            Text("Arguments")
                .font(.subheadline.weight(.medium))
            InspectionTokenList(process?.arguments ?? [], emptyText: "No arguments")

            Text("Environment")
                .font(.subheadline.weight(.medium))
            InspectionEnvironmentList(values: process?.environment ?? [])

            if let groups = process?.supplementalGroups, !groups.isEmpty {
                Text("Supplemental groups")
                    .font(.subheadline.weight(.medium))
                InspectionTokenList(groups.map(String.init))
            }

            if let limits = process?.rlimits, !limits.isEmpty {
                Text("Resource limits")
                    .font(.subheadline.weight(.medium))
                ForEach(limits) { limit in
                    InspectionValueRow(
                        LocalizedStringKey(limit.limit ?? "Unknown limit"),
                        value: "soft \(limit.soft.map(String.init) ?? "—") / hard \(limit.hard.map(String.init) ?? "—")"
                    )
                }
            }
        }
    }
}

private struct ContainerResourcesSection: View {
    let resources: ContainerResourcesDTO?
    let sharedMemorySize: UInt64?

    var body: some View {
        InspectionSection("Resources", systemImage: "gauge.with.dots.needle.67percent") {
            InspectionValueRow("CPUs", value: resources?.cpus.map(String.init))
            InspectionValueRow("CPU overhead", value: resources?.cpuOverhead.map(String.init))
            InspectionValueRow("Memory", value: resources?.memoryInBytes.map(inspectionByteCount))
            InspectionValueRow("Storage", value: resources?.storage.map(inspectionByteCount))
            InspectionValueRow("Shared memory", value: sharedMemorySize.map(inspectionByteCount))
        }
    }
}

private struct ContainerRuntimeSection: View {
    let details: ContainerDetails

    var body: some View {
        InspectionSection("Runtime", systemImage: "cpu") {
            InspectionValueRow("Handler", value: details.runtimeHandler)
            InspectionValueRow("Stop signal", value: details.stopSignal)
            if let rosetta = details.rosetta {
                InspectionBooleanRow(label: "Rosetta", value: rosetta)
            }
            if let virtualization = details.virtualization {
                InspectionBooleanRow(label: "Nested virtualization", value: virtualization)
            }
            if let ssh = details.ssh {
                InspectionBooleanRow(label: "SSH agent forwarding", value: ssh)
            }
            if let useInit = details.useInit {
                InspectionBooleanRow(label: "Minimal init", value: useInit)
            }
        }
    }
}

private struct ContainerNetworkInspectionSection: View {
    let activeNetworks: [ContainerNetwork]
    let configuredNetworks: [ContainerNetworkDTO]
    let dns: ContainerDNSDTO?

    var body: some View {
        InspectionSection("Networking", systemImage: "network") {
            if activeNetworks.isEmpty {
                Text("No active network attachments")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activeNetworks) { network in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(network.name ?? "Network")
                            .font(.subheadline.weight(.semibold))
                        InspectionValueRow("Hostname", value: network.hostname)
                        InspectionValueRow("IPv4", value: network.ipv4Address)
                        InspectionValueRow("IPv6", value: network.ipv6Address)
                        InspectionValueRow("Gateway", value: network.gateway)
                        InspectionValueRow("MAC address", value: network.macAddress)
                        InspectionValueRow("MTU", value: network.mtu.map(String.init))
                        InspectionValueRow("Variant", value: network.variant)
                    }
                }
            }

            if !configuredNetworks.isEmpty {
                Divider()
                Text("Configured attachments")
                    .font(.subheadline.weight(.medium))
                ForEach(configuredNetworks) { network in
                    InspectionValueRow(
                        LocalizedStringKey(network.network ?? "Network"),
                        value: network.options?.hostname ?? network.hostname
                    )
                }
            }

            if let dns {
                Divider()
                Text("DNS")
                    .font(.subheadline.weight(.medium))
                InspectionValueRow("Nameservers", value: dns.nameservers?.joined(separator: ", "))
                InspectionValueRow("Domain", value: dns.domain)
                InspectionValueRow("Search domains", value: dns.searchDomains?.joined(separator: ", "))
                InspectionValueRow("Options", value: dns.options?.joined(separator: ", "))
            }
        }
    }
}

private struct ContainerExposureSection: View {
    let ports: [PublishedPortDTO]
    let sockets: [PublishedSocketDTO]

    var body: some View {
        InspectionSection("Published Endpoints", systemImage: "arrow.left.arrow.right") {
            if ports.isEmpty && sockets.isEmpty {
                Text("No published ports or sockets")
                    .foregroundStyle(.secondary)
            }
            ForEach(ports) { port in
                InspectionValueRow(
                    LocalizedStringKey(portLabel(port)),
                    value: hostLabel(port)
                )
            }
            ForEach(sockets) { socket in
                VStack(alignment: .leading, spacing: 4) {
                    InspectionValueRow("Container socket", value: socket.containerPath)
                    InspectionValueRow("Host socket", value: socket.hostPath)
                    InspectionValueRow("Permissions", value: socket.permissions?.compactDescription)
                }
            }
        }
    }

    private func portLabel(_ port: PublishedPortDTO) -> String {
        let count = max(port.count ?? 1, 1)
        let start = port.containerPort.map(String.init) ?? "—"
        let range = count > 1 ? "\(start)–\((port.containerPort ?? 0) + count - 1)" : start
        return "\(range)/\(port.proto ?? "tcp")"
    }

    private func hostLabel(_ port: PublishedPortDTO) -> String {
        let count = max(port.count ?? 1, 1)
        let start = port.hostPort.map(String.init) ?? "—"
        let range = count > 1 ? "\(start)–\((port.hostPort ?? 0) + count - 1)" : start
        return "\(port.hostAddress ?? "0.0.0.0"):\(range)"
    }
}

private struct ContainerMountInspectionSection: View {
    let mounts: [ContainerMountDTO]

    var body: some View {
        InspectionSection("Mounts", systemImage: "externaldrive") {
            if mounts.isEmpty {
                Text("No mounts")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mounts) { mount in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mount.destination ?? "Unknown destination")
                            .font(.subheadline.weight(.semibold))
                        InspectionValueRow("Source", value: mount.source)
                        InspectionValueRow("Type", value: mount.type)
                        InspectionValueRow("Options", value: mount.options?.joined(separator: ", "))
                    }
                }
            }
        }
    }
}

private struct ContainerSecuritySection: View {
    let details: ContainerDetails

    var body: some View {
        InspectionSection("Security", systemImage: "lock.shield") {
            if let readOnly = details.readOnly {
                InspectionBooleanRow(label: "Read-only root filesystem", value: readOnly)
            }
            Text("Added capabilities")
                .font(.subheadline.weight(.medium))
            InspectionTokenList(details.capAdd)
            Text("Dropped capabilities")
                .font(.subheadline.weight(.medium))
            InspectionTokenList(details.capDrop)
            if let maskedPaths = details.maskedPaths {
                Text("Masked paths")
                    .font(.subheadline.weight(.medium))
                InspectionTokenList(maskedPaths)
            }
            if let readonlyPaths = details.readonlyPaths {
                Text("Read-only paths")
                    .font(.subheadline.weight(.medium))
                InspectionTokenList(readonlyPaths)
            }
        }
    }
}

private struct ContainerMetadataSection: View {
    let labels: [String: String]
    let sysctls: [String: String]

    var body: some View {
        InspectionSection("Metadata", systemImage: "tag") {
            Text("Labels")
                .font(.subheadline.weight(.medium))
            InspectionKeyValueList(labels)
            Text("System controls")
                .font(.subheadline.weight(.medium))
            InspectionKeyValueList(sysctls)
        }
    }
}
