import SwiftUI
import AtelierProto

/// Form to compose a new role (manual). Caller receives the populated
/// ProposedRole on Save and decides where to send it.
struct RoleEditor: View {
    @Environment(\.dismiss) private var dismiss
    var existing: Atelier_V1_Role? = nil
    var onSave: (Atelier_V1_ProposedRole) -> Void

    @State private var name: String = ""
    @State private var emoji: String = "🧩"
    @State private var why: String = ""
    @State private var provider: String = "anthropic"
    @State private var modelId: String = "claude-sonnet-4-6"
    @State private var tools: String = "shell, fs_read, fs_write"
    @State private var skills: String = ""
    @State private var publishes: String = ""
    @State private var subscribes: String = ""
    @State private var systemPrompt: String = ""
    @State private var cliCommand: String = ""

    init(existing: Atelier_V1_Role? = nil,
         onSave: @escaping (Atelier_V1_ProposedRole) -> Void) {
        self.existing = existing
        self.onSave = onSave
        if let r = existing {
            _name = State(initialValue: r.name)
            _emoji = State(initialValue: r.emoji.isEmpty ? "🧩" : r.emoji)
            _why = State(initialValue: r.description_p)
            _provider = State(initialValue: r.defaultProvider)
            _modelId = State(initialValue: r.defaultModel)
            _tools = State(initialValue: r.allowedTools.joined(separator: ", "))
            _skills = State(initialValue: r.claudeSkills.joined(separator: ", "))
            _publishes = State(initialValue: r.handoffPublishes.joined(separator: ", "))
            _subscribes = State(initialValue: r.handoffSubscribes.joined(separator: ", "))
            _cliCommand = State(initialValue: r.cliCommand)
            // systemPrompt not exposed in Atelier_V1_Role; leave blank — editing
            // it would require a GetRoleDetail RPC. For now keep blank and
            // append edits via the wizard pass.
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(existing == nil ? "Add Role" : "Edit Role").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    pair("Name (kebab-case)", "qa", $name)
                    pair("Emoji", "🧪", $emoji)
                    pair("Why this role", "writes + runs end-to-end tests", $why)
                    HStack {
                        labeled("Provider", picker(["anthropic","gemini","ollama"], $provider))
                        labeled("Model", TextField("claude-sonnet-4-6", text: $modelId).textFieldStyle(.roundedBorder))
                    }
                    pair("Tools (comma)", "shell, fs_read, playwright", $tools)
                    pair("Skills (comma)", "pdf, docx", $skills)
                    pair("Publishes (comma)", "tests.passed", $publishes)
                    pair("Subscribes (comma)", "api.added", $subscribes)
                    pair("CLI command (empty = native chat)", "claude  /  gemini  /  aider --model ...", $cliCommand)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("System prompt").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $systemPrompt)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(AtelierTheme.cell)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AtelierTheme.border))
                            .frame(minHeight: 120)
                            .font(.system(size: 12))
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520, height: 600)
        .background(AtelierTheme.panel)
    }

    private func pair(_ label: String, _ placeholder: String, _ bind: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: bind).textFieldStyle(.roundedBorder)
        }
    }

    private func labeled<V: View>(_ label: String, _ v: V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            v
        }
    }

    private func picker(_ options: [String], _ bind: Binding<String>) -> some View {
        Menu(bind.wrappedValue.isEmpty ? "choose" : bind.wrappedValue) {
            ForEach(options, id: \.self) { o in Button(o) { bind.wrappedValue = o } }
        }
        .fixedSize()
    }

    private func split(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() {
        var r = Atelier_V1_ProposedRole()
        r.name = name.trimmingCharacters(in: .whitespaces)
        r.emoji = emoji
        r.why = why
        r.recommendedProvider = provider
        r.recommendedModel = modelId
        r.tools = split(tools)
        r.claudeSkills = split(skills)
        r.publishes = split(publishes)
        r.subscribes = split(subscribes)
        r.systemPrompt = systemPrompt
        r.cliCommand = cliCommand
        onSave(r)
        dismiss()
    }
}
