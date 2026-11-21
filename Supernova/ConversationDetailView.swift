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

    private var fastModeHelp: Text {
        currentModel.supportsFastMode
            ? Text("Request faster responses at a higher per-token price.")
            : Text("Fast Mode is unavailable for this model.")
    }

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
            if editor.isResponding && !editor.isWaitingForReply && editor.followsReplyAtEnd {
                conversationTextView.followReply()
            }
        }
        .onChange(of: editor.retryRequest) { _, position in
            guard let position else { return }
            editor.retry(
                position: position,
                model: currentModel,
                effort: currentThinkingEffort,
                fastMode: currentFastModeEnabled
            )
        }
        .onChange(of: currentModel) { _, model in
            if !model.supportsFastMode { currentFastModeEnabled = false }
        }
        .onChange(of: editor.isResponding, initial: true) { _, isResponding in
            if isResponding {
                shouldRestoreInputFocus = isInputFocused
                isInputFocused = false
            }
            conversationTextView.setResponding(isResponding)
            if !isResponding {
                defer { shouldRestoreInputFocus = false }
                guard editor.followsReplyAtEnd else { return }
                editorSelection = AttributedTextSelection(
                    insertionPoint: editor.document.endIndex,
                    typingAttributes: AttributeContainer()
                )
                if shouldRestoreInputFocus, !isSettingsPresented,
                    editor.failure == nil
                {
                    isInputFocused = true
                }
            }
        }
        .alert(
            "Couldn’t send message",
            isPresented: Binding(
                get: { editor.failure != nil },
                set: { if !$0 { editor.failure = nil } }
            )
        ) {
            Button("Open Config") { isSettingsPresented = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add your OpenAI API key in Config to send messages.")
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
                ContextWindowUsageRing(usage: editor.lastContextUsage)

                Toggle(isOn: $currentFastModeEnabled) {
                    Label("Fast Mode", systemImage: "hare")
                }
                .disabled(!currentModel.supportsFastMode)
                .help(fastModeHelp)
                .accessibilityHint(fastModeHelp)
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
            }
            #if os(iOS)
                .axisBehavior(.verticalPreferred)
            #endif

            ToolbarItem(placement: sessionConfigButtonsPlacement) {
                sendButton
            }
            #if os(iOS)
                .visibilityPriority(.high)
                .axisBehavior(.verticalPreferred)
            #elseif os(macOS)
                .visibilityPriority(.high)
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
                        effort: currentThinkingEffort,
                        fastMode: currentFastModeEnabled
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
    let usage: ContextWindowUsage?

    private var usageDescription: Text {
        guard let usage else { return Text("No reported usage") }
        let tokens = usage.totalTokens.formatted()
        guard let limit = usage.model.contextWindowSize,
              let fraction = usage.fraction
        else {
            return Text("\(tokens) tokens, \(usage.model). Context window unavailable.")
        }
        let percent = fraction.formatted(.percent.precision(.fractionLength(0...2)))
        return Text("\(percent), \(tokens) of \(limit.formatted()) tokens, \(usage.model)")
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.secondary, lineWidth: 1.5)

            Circle()
                .inset(by: 0.75)
                .trim(from: 0, to: min(max(usage?.fraction ?? 0, 0), 1))
                .stroke(
                    .primary,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .accessibilityElement(children: .ignore)
        .help(Text("Last reported context usage\n\(usageDescription)"))
        .accessibilityLabel("Last reported context usage")
        .accessibilityValue(usageDescription)
        .accessibilityIdentifier("contextWindowUsage")
    }
}
