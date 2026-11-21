import OpenAI
import SwiftUI
import SwiftUIIntrospect

struct ConversationDetailView: View {
    private static let availableModels = Model.allModels(
        satisfying: .init(supportedEndpoints: [.chatCompletions, .responses])
    ).sorted(by: >)

    let editor: ConversationEditor
    @Binding var currentModel: Model
    @Binding var currentFastModeEnabled: Bool
    @Binding var currentThinkingEffort: ModelSpec.ReasoningEffort
    @Binding var isSettingsPresented: Bool

    @State private var editorSelection = AttributedTextSelection()
    @State private var conversationTextView = ConversationTextView()
    @State private var shouldRestoreInputFocus = false

    @FocusState private var isInputFocused: Bool

    private var sessionConfigButtonsPlacement: ToolbarItemPlacement {
        #if os(macOS)
            .automatic
        #else
            .bottomBar
        #endif
    }

    var body: some View {
        TextEditor(
            text: Binding(
                get: { editor.document },
                set: { editor.updateText(String($0.characters)) }
            ),
            selection: $editorSelection
        )
        .attributedTextFormattingDefinition(AttributeScopes.ConversationFormatting.self)
        #if os(iOS)
            .contentMargins(
                .all,
                EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12),
                for: .scrollContent
            )
        #endif
        #if os(iOS) || os(visionOS)
            .introspect(.textEditor, on: .iOS(.v27), .visionOS(.v27)) {
                textView in
                #if os(iOS)
                    textView.textContainer.lineFragmentPadding = 0
                #endif
                conversationTextView.attach(to: textView) {
                    editor.draftStartUTF16Offset
                }
            }
        #elseif os(macOS)
            .introspect(.textEditor, on: .macOS(.v27)) { textView in
                conversationTextView.attach(to: textView) {
                    editor.draftStartUTF16Offset
                }
            }
        #endif
        .focused($isInputFocused)
        .accessibilityIdentifier("conversationEditor")
        .task {
            guard !editor.isResponding else { return }
            editorSelection = AttributedTextSelection(
                insertionPoint: editor.document.endIndex,
                typingAttributes: AttributeContainer()
            )
            isInputFocused = true
        }
        .onChange(of: editor.isWaitingForReply, initial: true) { _, isWaiting in
            conversationTextView.setWaitingForReply(isWaiting)
        }
        .onChange(of: editor.document) { _, _ in
            if editor.isResponding && !editor.isWaitingForReply {
                conversationTextView.followReply()
            }
        }
        .onChange(of: editor.isResponding, initial: true) { _, isResponding in
            if isResponding {
                shouldRestoreInputFocus = isInputFocused
                isInputFocused = false
            }
            conversationTextView.setResponding(isResponding)
            if !isResponding {
                editorSelection = AttributedTextSelection(
                    insertionPoint: editor.document.endIndex,
                    typingAttributes: AttributeContainer()
                )
                if shouldRestoreInputFocus, !isSettingsPresented,
                    editor.failure == nil
                {
                    isInputFocused = true
                }
                shouldRestoreInputFocus = false
            }
        }
        .alert(
            "Couldn’t send message",
            isPresented: Binding(
                get: { editor.failure != nil },
                set: { if !$0 { editor.failure = nil } }
            ),
            presenting: editor.failure
        ) { failure in
            if failure == .missingAPIKey {
                Button("Open Config") { isSettingsPresented = true }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { failure in
            switch failure {
            case .missingAPIKey:
                Text("Add your OpenAI API key in Config to send messages.")
            case .interrupted:
                Text("The response ended before it finished.")
            case .noReply:
                Text("OpenAI returned no text. Try sending the message again.")
            case .requestFailed:
                Text(
                    "OpenAI couldn’t complete the request. Check your connection and API settings."
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isSettingsPresented = true
                } label: {
                    Label("Config", systemImage: "gearshape")
                }
                .accessibilityIdentifier("configButton")
            }

            ToolbarItemGroup(placement: sessionConfigButtonsPlacement) {
                ContextWindowUsageRing(usage: 0.2)

                Toggle(isOn: $currentFastModeEnabled) {
                    Label("Fast Mode", systemImage: "hare")
                }
                .accessibilityIdentifier("fastMode")

                Menu {
                    Picker(
                        "Select Thinking Effort",
                        selection: $currentThinkingEffort
                    ) {
                        ForEach(
                            ModelSpec.ReasoningEffort.allCases,
                            id: \.self
                        ) {
                            effort in
                            Text(effort.rawValue)
                                .tag(effort)
                        }
                    }
                } label: {
                    let isThinkingEnabled =
                        currentThinkingEffort != .none
                    Toggle(
                        "Thinking Effort",
                        systemImage: "brain",
                        isOn: .constant(isThinkingEnabled)
                    )
                    .allowsHitTesting(false)
                }
                .accessibilityIdentifier("thinkingEffortMenu")

                Menu {
                    Picker("Select Model", selection: $currentModel) {
                        ForEach(Self.availableModels, id: \.self) {
                            model in
                            Text(model)
                                .tag(model)
                        }
                    }
                } label: {
                    Label("Select Model", systemImage: "cpu")
                    Text(currentModel)
                }
                .accessibilityValue(Text(currentModel))
                .accessibilityIdentifier("modelPicker")

                sendButton
            }
            #if os(iOS)
                .axisBehavior(.verticalPreferred)
            #endif
        }
    }

    private var sendButton: some View {
        let isResponding = editor.isResponding

        return ZStack {
            Button(role: .confirm) {
                if isResponding {
                    editor.stop()
                } else {
                    editor.send(
                        model: currentModel,
                        effort: currentThinkingEffort
                    )
                }
            } label: {
                Image(systemName: isResponding ? "stop.fill" : "paperplane")
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.default, value: isResponding)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(isResponding ? .red : nil)
            .disabled(!isResponding && !editor.canSend)
            .accessibilityLabel(isResponding ? "Stop" : "Send")
            .accessibilityIdentifier("sendConversationMessage")
        }
    }
}

private struct ContextWindowUsageRing: View {
    let usage: Double

    var body: some View {
        let fraction = min(max(usage, 0), 1)

        ZStack {
            Circle()
                .strokeBorder(.secondary, lineWidth: 1.5)

            Circle()
                .inset(by: 0.75)
                .trim(from: 0, to: fraction)
                .stroke(
                    .primary,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context window used")
        .accessibilityValue(
            fraction.formatted(.percent.precision(.fractionLength(0)))
        )
        .accessibilityIdentifier("contextWindowUsage")
    }
}
