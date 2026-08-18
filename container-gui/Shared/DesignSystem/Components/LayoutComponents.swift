import SwiftUI

struct DSCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(DSMetrics.spacing16)
            .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: DSMetrics.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DSMetrics.cardRadius)
                    .stroke(Color.dsHairline)
            }
    }
}

struct SectionLabel: View {
    private let text: Text
    private let systemImage: String?

    init(title: LocalizedStringResource) {
        text = Text(title)
        systemImage = nil
    }

    init(_ title: LocalizedStringKey, systemImage: String? = nil) {
        text = Text(title)
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: DSMetrics.spacing4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            text
        }
        .font(.dsSectionLabel)
        .tracking(0.8)
        .textCase(.uppercase)
        .foregroundStyle(Color.dsTextSecondary)
    }
}

struct SidebarRow: View {
    let icon: String
    let title: LocalizedStringResource
    var count: Int?
    var showsAttention = false

    var body: some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if let count {
                    Text(count, format: .number)
                        .font(.cliMonoTabular)
                        .foregroundStyle(Color.dsTextSecondary)
                }
                if showsAttention {
                    Circle().fill(Color.dsStateAttention).frame(width: 6, height: 6)
                        .accessibilityLabel("Needs attention")
                }
            }
        } icon: {
            Image(systemName: icon)
        }
        .accessibilityElement(children: .combine)
    }
}

struct EmptyState<Actions: View>: View {
    private let title: LocalizedStringResource
    private let systemImage: String
    private let descriptionText: Text?
    private let actions: Actions

    private init(
        title: LocalizedStringResource,
        systemImage: String,
        descriptionText: Text?,
        actions: Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.descriptionText = descriptionText
        self.actions = actions
    }

    init(
        _ title: LocalizedStringResource,
        systemImage: String,
        description: LocalizedStringResource,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            descriptionText: Text(description),
            actions: actions()
        )
    }

    /// For descriptions that carry a runtime value — a CLI error, a sanitized
    /// diagnostic — which must not be looked up in the string catalog.
    init(
        _ title: LocalizedStringResource,
        systemImage: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            descriptionText: Text(verbatim: message),
            actions: actions()
        )
    }

    init(
        _ title: LocalizedStringResource,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            descriptionText: nil,
            actions: actions()
        )
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let descriptionText {
                descriptionText.textSelection(.enabled)
            }
        } actions: {
            actions
        }
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: LocalizedStringResource, systemImage: String) {
        self.init(title, systemImage: systemImage) { EmptyView() }
    }

    init(
        _ title: LocalizedStringResource,
        systemImage: String,
        description: LocalizedStringResource
    ) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }

    init(
        _ title: LocalizedStringResource,
        systemImage: String,
        message: String
    ) {
        self.init(title, systemImage: systemImage, message: message) { EmptyView() }
    }
}
