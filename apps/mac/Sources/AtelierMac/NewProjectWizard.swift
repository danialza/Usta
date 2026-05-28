import SwiftUI
import AppKit
import AtelierProto

struct NewProjectWizard: View {
    @EnvironmentObject var client: AtelierClientModel
    @Environment(\.dismiss) private var dismiss

    enum Step { case describe, review, scaffolding, done }

    @State private var step: Step = .describe
    @State private var idea: String = ""
    @State private var provider: String = "anthropic"
    @State private var model: String = "claude-sonnet-4-6"
    @State private var providers: [Atelier_V1_ProviderInfo] = []
    @State private var proposal: Atelier_V1_ProjectProposal? = nil
    @State private var working: Bool = false
    @State private var errorMsg: String? = nil
    @State private var openedWS: Atelier_V1_Workspace? = nil

    var onOpened: (Atelier_V1_Workspace) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AtelierTheme.border)
            content
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(AtelierTheme.panel)
        .task { providers = await client.listProviders() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text("New Project").font(.headline)
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.borderless)
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .describe:    describeStep
        case .review:      reviewStep
        case .scaffolding: scaffoldingStep
        case .done:        doneStep
        }
    }

    // MARK: describe

    private var describeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What do you want to build?")
                .font(.title3.bold())
            Text("Describe the project in 1–3 sentences. The PM agent will pick a stack and assemble a team of specialist assistants.")
                .font(.callout).foregroundStyle(AtelierTheme.dim)
            TextEditor(text: $idea)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(AtelierTheme.cell)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(AtelierTheme.border))
                .frame(minHeight: 140)
                .font(.system(size: 13))

            HStack(spacing: 12) {
                providerPicker
                modelPicker
                Spacer()
                if working { ProgressView().scaleEffect(0.7) }
                Button {
                    Task { await propose() }
                } label: {
                    Label("Propose Team", systemImage: "wand.and.stars")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(working || idea.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
            if let e = errorMsg {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(18)
    }

    private var providerPicker: some View {
        Menu {
            ForEach(providers, id: \.name) { p in
                Button {
                    provider = p.name
                    if !p.defaultModels.contains(model) {
                        model = p.defaultModels.first ?? model
                    }
                } label: {
                    HStack {
                        Image(systemName: p.available ? "checkmark.circle.fill" : "circle.slash")
                            .foregroundStyle(p.available ? .green : .secondary)
                        Text(p.name)
                    }
                }
            }
        } label: {
            Label(provider, systemImage: "server.rack")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var modelPicker: some View {
        let models = providers.first(where: { $0.name == provider })?.defaultModels ?? [model]
        return Menu {
            ForEach(models, id: \.self) { m in
                Button(m) { model = m }
            }
        } label: {
            Label(model, systemImage: "cpu")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: review

    @ViewBuilder
    private var reviewStep: some View {
        if let p = proposal {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading) {
                            Text(p.projectName).font(.title2.bold())
                            Text(p.projectSlug).font(.caption).foregroundStyle(AtelierTheme.dim)
                        }
                        Spacer()
                    }
                    Text(p.summary).foregroundStyle(.primary)

                    if !p.stack.isEmpty {
                        sectionLabel("Stack")
                        wrappingTags(p.stack.map { tag in (tag.name, tag.category) })
                    }
                    if !p.firstSteps.isEmpty {
                        sectionLabel("First steps")
                        Text(p.firstSteps).foregroundStyle(.primary).font(.callout)
                    }

                    sectionLabel("Team")
                    VStack(spacing: 8) {
                        ForEach(p.team, id: \.name) { m in
                            ProposedRoleCard(role: m)
                        }
                    }
                }
                .padding(18)
            }
            Divider().overlay(AtelierTheme.border)
            HStack {
                Button("Back") { step = .describe }
                Spacer()
                Button("Create Project…") { Task { await scaffold() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        } else {
            Text("(no proposal)").padding()
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AtelierTheme.dim2)
            .tracking(1)
    }

    private func wrappingTags(_ tags: [(String, String)]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, t in
                HStack(spacing: 4) {
                    Text(t.0).font(.caption)
                    if !t.1.isEmpty {
                        Text(t.1).font(.system(size: 9)).foregroundStyle(AtelierTheme.dim)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(AtelierTheme.cell)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(AtelierTheme.border))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    // MARK: scaffolding / done

    private var scaffoldingStep: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Creating project + writing roles…").foregroundStyle(AtelierTheme.dim)
            if let e = errorMsg { Text(e).font(.caption).foregroundStyle(.red) }
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var doneStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
            if let ws = openedWS {
                Text("Created \(ws.name)").font(.title3.bold())
                Text(ws.path).font(.caption).foregroundStyle(AtelierTheme.dim).textSelection(.enabled)
            }
            Button("Open Workspace") {
                if let ws = openedWS { onOpened(ws); dismiss() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: actions

    private func propose() async {
        working = true; errorMsg = nil
        defer { working = false }
        if let p = await client.proposeProject(idea: idea, provider: provider, model: model) {
            proposal = p
            step = .review
        } else {
            errorMsg = client.lastError ?? "no proposal"
        }
    }

    private func scaffold() async {
        guard let p = proposal else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Parent Folder"
        panel.message = "Project '\(p.projectSlug)' will be created inside the folder you pick."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        step = .scaffolding
        errorMsg = nil
        if let resp = await client.scaffoldProject(proposal: p, parentDir: url.path) {
            openedWS = resp.workspace
            step = .done
        } else {
            errorMsg = client.lastError ?? "scaffold failed"
            step = .review
        }
    }
}

struct ProposedRoleCard: View {
    let role: Atelier_V1_ProposedRole
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(role.emoji.isEmpty ? AtelierTheme.roleEmoji(for: role.name, fallback: "•") : role.emoji)
                Text(role.name).font(.body.bold())
                Spacer()
                Text(role.recommendedModel)
                    .font(.caption2).foregroundStyle(AtelierTheme.dim)
            }
            Text(role.why).font(.caption).foregroundStyle(AtelierTheme.dim)
            if !role.tools.isEmpty {
                Text("tools: \(role.tools.joined(separator: ", "))")
                    .font(.system(size: 10)).foregroundStyle(AtelierTheme.dim2)
            }
            if !role.claudeSkills.isEmpty {
                Text("skills: \(role.claudeSkills.joined(separator: ", "))")
                    .font(.system(size: 10)).foregroundStyle(AtelierTheme.dim2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AtelierTheme.cell)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AtelierTheme.roleColor(for: role.name).opacity(0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Minimal flow layout (SwiftUI 16+).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW {
                x = 0; y += rowH + spacing; rowH = 0
            }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW.isFinite ? maxW : x, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.minX + maxW {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: .init(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
