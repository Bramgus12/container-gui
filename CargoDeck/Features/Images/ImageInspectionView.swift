import SwiftUI

struct ImageInspectionView: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.imageInspectionState {
            case .idle, .loading:
                ProgressView("Inspecting image…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let inspection):
                ImageInspectionContent(inspection: inspection)
            case .failed(let message):
                EmptyState(
                    "Inspection Failed",
                    systemImage: "exclamationmark.triangle",
                    message: message
                ) {
                    Button("Try Again") {
                        Task { await model.inspectSelectedImage() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsCanvas)
    }
}

private struct ImageInspectionContent: View {
    let inspection: ImageInspection

    var body: some View {
        InspectionPane {
            ImageInspectionHeader(
                reference: inspection.reference,
                rawJSON: inspection.rawJSON
            )
            ImageDescriptorSection(
                descriptor: inspection.descriptor,
                createdAt: inspection.createdAt
            )

            if inspection.variants.isEmpty {
                InspectionSection("Variants", systemImage: "square.stack.3d.up") {
                    Text("No platform variants were reported")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(inspection.variants) { variant in
                    ImageVariantSection(variant: variant)
                }
            }
        }
        .accessibilityIdentifier("images.inspection")
    }
}

private struct ImageInspectionHeader: View {
    let reference: String
    let rawJSON: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(reference)
                .font(.title3.bold())
                .textSelection(.enabled)
            InspectionCopyRawJSONButton(rawJSON: rawJSON)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ImageDescriptorSection: View {
    let descriptor: ImageDescriptorDTO?
    let createdAt: Date?

    var body: some View {
        InspectionSection("Image", systemImage: "doc.text.magnifyingglass") {
            InspectionValueRow("Created", value: createdAt?.formatted(date: .abbreviated, time: .standard))
            InspectionValueRow("Digest", value: descriptor?.digest)
            InspectionValueRow("Media type", value: descriptor?.mediaType)
            InspectionValueRow("Size", value: descriptor?.size.map(inspectionByteCount))
            InspectionValueRow("Artifact type", value: descriptor?.artifactType)
            if let urls = descriptor?.urls, !urls.isEmpty {
                Text("Alternate locations")
                    .font(.subheadline.weight(.medium))
                InspectionTokenList(urls)
            }
            if let annotations = descriptor?.annotations, !annotations.isEmpty {
                Text("Annotations")
                    .font(.subheadline.weight(.medium))
                InspectionKeyValueList(annotations)
            }
        }
    }
}

private struct ImageVariantSection: View {
    let variant: ImageInspectionVariant
    @State private var isExpanded = true

    var body: some View {
        DSCard {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: DSMetrics.spacing12) {
                    ImageVariantMetadata(variant: variant)
                    ImageLaunchDefaults(configuration: variant.configuration)
                    ImageFilesystemSection(rootFS: variant.rootFS, layers: variant.layers)
                    ImageHistorySection(history: variant.history)
                }
                .padding(.top, DSMetrics.spacing8)
            } label: {
                VStack(alignment: .leading, spacing: DSMetrics.spacing4) {
                    Text(platformDescription)
                        .font(.dsCardHeading)
                    if let digest = variant.digest {
                        MonoText(value: digest, dimmed: true, truncation: .middle, selectable: false)
                    }
                }
            }
        }
    }

    private var platformDescription: String {
        [variant.operatingSystem, variant.architecture, variant.variant]
            .compactMap { $0 }
            .joined(separator: " / ")
            .nonEmpty ?? "Unknown platform"
    }
}

private struct ImageVariantMetadata: View {
    let variant: ImageInspectionVariant

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Variant", systemImage: "cpu")
                .font(.subheadline.weight(.semibold))
            InspectionValueRow("Digest", value: variant.digest)
            InspectionValueRow("Size", value: variant.size.map(inspectionByteCount))
            InspectionValueRow("Operating system", value: variant.operatingSystem)
            InspectionValueRow("Architecture", value: variant.architecture)
            InspectionValueRow("Variant", value: variant.variant)
            InspectionValueRow("OS version", value: variant.osVersion)
            InspectionValueRow("Created", value: variant.createdAt?.formatted(date: .abbreviated, time: .standard))
            InspectionValueRow("Author", value: variant.author)
            if !variant.osFeatures.isEmpty {
                Text("Required OS features")
                    .font(.subheadline.weight(.medium))
                InspectionTokenList(variant.osFeatures)
            }
        }
    }
}

private struct ImageLaunchDefaults: View {
    let configuration: OCIImageConfigurationDTO?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label("Launch Defaults", systemImage: "terminal")
                .font(.subheadline.weight(.semibold))
            InspectionValueRow("User", value: configuration?.user)
            InspectionValueRow("Working directory", value: configuration?.workingDirectory)
            InspectionValueRow("Stop signal", value: configuration?.stopSignal)
            Text("Entrypoint")
                .font(.subheadline.weight(.medium))
            InspectionTokenList(configuration?.entrypoint ?? [], emptyText: "No entrypoint")
            Text("Command")
                .font(.subheadline.weight(.medium))
            InspectionTokenList(configuration?.command ?? [], emptyText: "No command")
            Text("Environment")
                .font(.subheadline.weight(.medium))
            InspectionEnvironmentList(values: configuration?.environment ?? [])
            Text("Labels")
                .font(.subheadline.weight(.medium))
            InspectionKeyValueList(configuration?.labels ?? [:])
        }
    }
}

private struct ImageFilesystemSection: View {
    let rootFS: OCIRootFSDTO?
    let layers: [ImageLayerDigest]
    @State private var showsLayers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label("Filesystem", systemImage: "externaldrive")
                .font(.subheadline.weight(.semibold))
            InspectionValueRow("Type", value: rootFS?.type)
            InspectionValueRow("Layers", value: String(layers.count))
            if !layers.isEmpty {
                DisclosureGroup("Layer digests", isExpanded: $showsLayers) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(layers) { layer in
                            MonoText(value: layer.digest, dimmed: true, truncation: .middle)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }
}

private struct ImageHistorySection: View {
    let history: [ImageHistoryEntry]
    @State private var showsHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            DisclosureGroup(isExpanded: $showsHistory) {
                if history.isEmpty {
                    Text("No build history")
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(history) { entry in
                            ImageHistoryRow(entry: entry)
                        }
                    }
                    .padding(.top, 8)
                }
            } label: {
                Label("Build History (\(history.count))", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

private struct ImageHistoryRow: View {
    let entry: ImageHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            MonoText(
                value: entry.createdBy ?? entry.comment ?? "Image metadata change",
                truncation: .middle
            )
            HStack(spacing: 8) {
                if let createdAt = entry.createdAt {
                    Text(createdAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                }
                if let author = entry.author {
                    Text(author)
                }
                if entry.emptyLayer {
                    Label("Metadata only", systemImage: "doc")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let comment = entry.comment, comment != entry.createdBy {
                Text(comment)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
