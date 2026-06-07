import SwiftUI
import AppKit
import AtelierProto

struct NewProjectWizard: View {
    @EnvironmentObject var client: AtelierClientModel
    @Environment(\.dismiss) private var dismiss

    enum Step { case describe, review, grill, scaffolding, done }

    @State private var step: Step = .describe
    @State private var idea: String = ""
    @State private var provider: String = "anthropic"
    @State private var model: String = "claude-sonnet-4-6"
    @State private var providers: [Atelier_V1_ProviderInfo] = []
    @State private var proposal: Atelier_V1_ProjectProposal? = nil
    @State private var showAddRole: Bool = false
    @State private var working: Bool = false
    @State private var errorMsg: String? = nil
    @State private var openedWS: Atelier_V1_Workspace? = nil
    // Grill flow
    @State private var grillQuestions: [Atelier_V1_GrillQuestion] = []
    @State private var grillAnswers: [String: String] = [:]
    @State private var grillStatus: String = ""

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
        case .grill:       grillStep
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

                    HStack {
                        sectionLabel("Team")
                        Spacer()
                        Button {
                            showAddRole = true
                        } label: { Label("Add Role", systemImage: "plus") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    VStack(spacing: 8) {
                        ForEach(p.team.indices, id: \.self) { i in
                            ProposedRoleCard(
                                role: Binding(
                                    get: { proposal?.team[i] ?? p.team[i] },
                                    set: { newVal in proposal?.team[i] = newVal }
                                ),
                                onDelete: {
                                    let name = p.team[i].name
                                    proposal?.team.removeAll { $0.name == name }
                                }
                            )
                        }
                    }
                }
                .padding(18)
            }
            Divider().overlay(AtelierTheme.border)
            HStack {
                Button("Back") { step = .describe }
                Spacer()
                if working { ProgressView().scaleEffect(0.7).padding(.trailing, 6) }
                Button {
                    Task { await startGrill() }
                } label: {
                    Label("Refine with Grill", systemImage: "questionmark.bubble")
                }
                .buttonStyle(.bordered)
                .disabled(working)
                .help("PM asks 6-8 targeted questions to fill gaps before scaffolding")
                Button("Create Project…") { Task { await scaffold() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
            }
            .padding(14)
            .sheet(isPresented: $showAddRole) {
                RoleEditor(onSave: { newRole in
                    proposal?.team.append(newRole)
                })
            }
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

    // MARK: grill

    private var grillStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.bubble.fill").foregroundStyle(.tint)
                        Text("Refine the plan").font(.title3.bold())
                    }
                    Text("PM has a few targeted questions before we scaffold. Tap an option or type your own. Skip questions you don't care about.")
                        .font(.callout).foregroundStyle(AtelierTheme.dim)
                    if grillQuestions.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().scaleEffect(0.7)
                            Text(grillStatus.isEmpty ? "Generating questions…" : grillStatus)
                                .foregroundStyle(AtelierTheme.dim)
                        }
                        .padding(.vertical, 24)
                    } else {
                        ForEach(Array(grillQuestions.enumerated()), id: \.offset) { idx, q in
                            grillQuestionCard(index: idx, q: q)
                        }
                    }
                    if let e = errorMsg {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(18)
            }
            Divider().overlay(AtelierTheme.border)
            HStack {
                Button("Cancel") { step = .review; errorMsg = nil }
                Spacer()
                if working { ProgressView().scaleEffect(0.7).padding(.trailing, 6) }
                Button {
                    Task { await applyGrill() }
                } label: {
                    Label("Apply Answers & Re-propose", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || grillQuestions.isEmpty || grillAnswers.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
            .padding(14)
        }
    }

    private func grillQuestionCard(index: Int, q: Atelier_V1_GrillQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text("\(index + 1).").font(.body.bold()).foregroundStyle(AtelierTheme.dim)
                Text(q.question).font(.body.bold())
            }
            if !q.rationale.isEmpty {
                Text(q.rationale).font(.caption).foregroundStyle(AtelierTheme.dim)
            }
            if !q.options.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(q.options, id: \.self) { opt in
                        let selected = grillAnswers[q.id] == opt
                        Button {
                            grillAnswers[q.id] = selected ? "" : opt
                        } label: {
                            Text(opt).font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(selected ? Color.accentColor.opacity(0.25) : AtelierTheme.cell)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : AtelierTheme.border))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if q.allowFreeText {
                TextField("Or type your own answer…",
                          text: Binding(
                            get: { grillAnswers[q.id] ?? "" },
                            set: { grillAnswers[q.id] = $0 }
                          ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(8)
                    .background(AtelierTheme.cell)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(AtelierTheme.border))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AtelierTheme.cell.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AtelierTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private func startGrill() async {
        guard let p = proposal else { return }
        step = .grill
        grillQuestions = []
        grillAnswers = [:]
        grillStatus = "Generating questions…"
        working = true; errorMsg = nil
        defer { working = false }
        let qs = await client.generateGrillQuestions(idea: idea, proposal: p, provider: provider)
        grillQuestions = qs
        if qs.isEmpty {
            errorMsg = client.lastError ?? "no questions returned"
        }
    }

    private func applyGrill() async {
        guard let p = proposal else { return }
        let answers: [(String, String)] = grillQuestions.compactMap { q in
            let a = (grillAnswers[q.id] ?? "").trimmingCharacters(in: .whitespaces)
            return a.isEmpty ? nil : (q.id, a)
        }
        guard !answers.isEmpty else { return }
        working = true; errorMsg = nil
        defer { working = false }
        if let refined = await client.refineProposal(idea: idea, current: p,
                                                     questions: grillQuestions,
                                                     answers: answers,
                                                     provider: provider, model: model) {
            proposal = refined
            step = .review
        } else {
            errorMsg = client.lastError ?? "refine failed"
        }
    }

    private func scaffold() async {
        guard let p = proposal else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
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
    @Binding var role: Atelier_V1_ProposedRole
    var providers: [String] = ["anthropic", "gemini", "ollama"]
    var modelsByProvider: [String: [String]] = [
        "anthropic": ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"],
        "gemini":    ["gemini-2.5-flash", "gemini-2.0-flash", "gemini-2.0-flash-lite",
                      "gemini-1.5-flash-002", "gemini-2.5-pro", "gemini-1.5-pro-002"],
        "ollama":    ["qwen2.5-coder:1.5b", "qwen2.5-coder:3b", "llama3.2:3b",
                      "qwen2.5-coder:7b", "llama3.1:8b", "qwen3-coder"],
    ]
    var onDelete: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(role.emoji.isEmpty ? AtelierTheme.roleEmoji(for: role.name, fallback: "•") : role.emoji)
                Text(role.name).font(.body.bold())
                Spacer()
                providerMenu
                modelMenu
                if let onDelete {
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.red)
                }
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

    private var providerMenu: some View {
        Menu(role.recommendedProvider.isEmpty ? "provider" : role.recommendedProvider) {
            ForEach(providers, id: \.self) { p in
                Button(p) {
                    role.recommendedProvider = p
                    let models = modelsByProvider[p] ?? []
                    if !models.contains(role.recommendedModel), let first = models.first {
                        role.recommendedModel = first
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption2)
    }

    private var modelMenu: some View {
        let models = modelsByProvider[role.recommendedProvider] ?? [role.recommendedModel]
        return Menu(role.recommendedModel.isEmpty ? "model" : role.recommendedModel) {
            ForEach(models, id: \.self) { m in
                Button(m) { role.recommendedModel = m }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption2)
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
