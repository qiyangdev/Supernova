import SwiftUI
import SwiftUIIntrospect

struct SettingsView: View {
    private static let formCoordinateSpace = "settingsForm"

    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var savedKey: String?
    @State private var apiKeyFrame: CGRect = .null
    @State private var isSaving = false
    @State private var isCancelling = false
    @State private var isDiscardConfirmationPresented = false
    @State private var errorMessage: LocalizedStringResource?

    @FocusState private var isAPIKeyFocused: Bool

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasUnsavedChanges: Bool {
        guard let savedKey else { return false }
        return trimmedKey != savedKey
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenAI") {
                    SecureField("API Key", text: $apiKey)
                        #if os(iOS) || os(visionOS)
                            .textInputAutocapitalization(.never)
                            .introspect(
                                .secureField,
                                on: .iOS(.v26, .v27),
                                .visionOS(.v27)
                            ) { textField in
                                textField.clearButtonMode = .always
                            }
                        #endif
                        .autocorrectionDisabled()
                        .focused($isAPIKeyFocused)
                        .onSubmit { isAPIKeyFocused = false }
                        .disabled(savedKey == nil || isSaving)
                        .accessibilityIdentifier("openAIAPIKey")
                        .onGeometryChange(for: CGRect.self) { geometry in
                            geometry.frame(in: .named(Self.formCoordinateSpace))
                        } action: { frame in
                            apiKeyFrame = frame
                        }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .coordinateSpace(.named(Self.formCoordinateSpace))
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture(
                    coordinateSpace: .named(Self.formCoordinateSpace)
                )
                .onEnded { tap in
                    if !apiKeyFrame.contains(tap.location) {
                        isAPIKeyFocused = false
                    }
                }
            )
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel, action: cancel)
                        .disabled(isSaving)
                        .accessibilityIdentifier("cancelSettings")
                }
            }
            .task {
                do {
                    let key = try await OpenAIKeyStore.shared.load() ?? ""
                    apiKey = key
                    savedKey = key
                } catch {
                    errorMessage = "Unable to load the API key from Keychain."
                }
            }
        }
        .onChange(of: isAPIKeyFocused) { _, isFocused in
            if !isFocused { saveKeyIfNeeded() }
        }
        .onChange(of: apiKey) {
            if !isAPIKeyFocused { saveKeyIfNeeded() }
        }
        .alert("Discard changes?", isPresented: $isDiscardConfirmationPresented)
        {
            Button("Keep Editing", role: .cancel) {
                isAPIKeyFocused = true
                isCancelling = false
            }
            Button("Discard", role: .destructive) { dismiss() }
        } message: {
            Text("Your unsaved change to the OpenAI API key will be lost.")
        }
        .onDisappear(perform: saveKeyIfNeeded)
        .interactiveDismissDisabled(isSaving || isCancelling)
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 240)
            .onExitCommand(perform: cancel)
        #endif
    }

    private func cancel() {
        guard !isSaving, !isCancelling else { return }
        isCancelling = true
        if hasUnsavedChanges {
            isDiscardConfirmationPresented = true
        } else {
            dismiss()
        }
    }

    private func saveKeyIfNeeded() {
        guard hasUnsavedChanges, !isSaving, !isCancelling else { return }
        let key = trimmedKey
        isSaving = true

        Task {
            defer { isSaving = false }

            do {
                try await OpenAIKeyStore.shared.save(key)
                self.savedKey = key
                errorMessage = nil
            } catch {
                errorMessage = "Unable to save the API key to Keychain."
            }
        }
    }
}
