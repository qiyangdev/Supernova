//
//  MainView.swift
//  Supernova
//
//  Created by qiyang on 2026/11/20.
//

import OpenAI
import SwiftData
import SwiftUI

struct MainView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ConversationThread.updatedAt, order: .reverse) private var threads: [ConversationThread]
    @State private var selectedThreadID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var editors: [UUID: ConversationEditor] = [:]
    @State private var threadToRename: ConversationThread?
    @State private var threadToDelete: ConversationThread?
    @State private var proposedTitle = ""
    @State private var isSaveErrorPresented = false

    @State private var currentModel: Model = .gpt6_sol
    @State private var currentFastModeEnabled = false
    @State private var currentThinkingEffort: ModelSpec.ReasoningEffort = .low
    @State private var isSettingsPresented = false

    private var selectedThread: ConversationThread? {
        threads.first { $0.id == selectedThreadID }
    }

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            List(selection: $selectedThreadID) {
                Section("Threads") {
                    ForEach(threads, id: \.id) { thread in
                        NavigationLink(value: thread.id) {
                            Text(thread.title)
                                .lineLimit(1)
                        }
                        .contextMenu { threadActions(for: thread) }
                    }
                }
            }
            .navigationTitle("Epsilon")
            .toolbar {
                ToolbarItem {
                    Button("New Thread", systemImage: "square.and.pencil", action: createThread)
                        .accessibilityIdentifier("newThread")
                        .keyboardShortcut("n", modifiers: .command)
                }
            }
        } detail: {
            if let thread = selectedThread, let editor = editors[thread.id] {
                ConversationDetailView(
                    editor: editor,
                    currentModel: $currentModel,
                    currentFastModeEnabled: $currentFastModeEnabled,
                    currentThinkingEffort: $currentThinkingEffort,
                    isSettingsPresented: $isSettingsPresented
                )
                .id(thread.id)
                .navigationTitle(Text(verbatim: thread.title))
                .toolbar {
                    ToolbarItem {
                        Menu("Thread Actions", systemImage: "ellipsis.circle") {
                            Button("Show Threads", systemImage: "sidebar.leading") {
                                selectThread(nil)
                                columnVisibility = .all
                                preferredCompactColumn = .sidebar
                            }
                            threadActions(for: thread)
                        }
                        .accessibilityIdentifier("threadActions")
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Select a Thread", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    Button("New Thread", action: createThread)
                        .accessibilityIdentifier("newThreadFromEmptyState")
                }
                .toolbar {
                    ToolbarItem {
                        Button("Config", systemImage: "gearshape") {
                            isSettingsPresented = true
                        }
                        .accessibilityIdentifier("configButton")
                    }
                }
            }
        }
        .onChange(of: selectedThreadID) { _, id in
            if let thread = threads.first(where: { $0.id == id }) {
                prepareEditor(for: thread)
            } else if id == nil {
                prepareEditor(for: nil)
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
        .alert(
            "Rename Thread",
            isPresented: Binding(
                get: { threadToRename != nil },
                set: { if !$0 { threadToRename = nil } }
            ),
            presenting: threadToRename
        ) { thread in
            TextField("Title", text: $proposedTitle)
                .accessibilityIdentifier("threadTitle")
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                thread.title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                thread.updatedAt = .now
                saveConversations()
            }
            .disabled(proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            "Delete Thread?",
            isPresented: Binding(
                get: { threadToDelete != nil },
                set: { if !$0 { threadToDelete = nil } }
            ),
            presenting: threadToDelete
        ) { thread in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteThread(thread) }
        } message: { thread in
            Text("This will delete “\(thread.title)” and its messages.")
        }
        .alert("Couldn’t Save Conversations", isPresented: $isSaveErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check available storage and try again.")
        }
    }

    @ViewBuilder
    private func threadActions(for thread: ConversationThread) -> some View {
        Button("Rename", systemImage: "pencil") {
            proposedTitle = thread.title
            threadToRename = thread
        }
        Button("Delete", systemImage: "trash", role: .destructive) {
            threadToDelete = thread
        }
    }

    private func selectThread(_ thread: ConversationThread?) {
        selectedThreadID = thread?.id
        prepareEditor(for: thread)
    }

    private func prepareEditor(for thread: ConversationThread?) {
        let id = thread?.id
        editors = editors.filter { $0.key == id || $0.value.isResponding }
        guard let thread, editors[thread.id] == nil else { return }

        let save = { [modelContext, error = $isSaveErrorPresented] in
            Self.saveConversations(in: modelContext, reportingErrorsTo: error)
        }
        editors[thread.id] = ConversationEditor(
            messages: thread.transcript,
            draft: thread.draft,
            onDraftChange: { draft in
                guard thread.modelContext != nil, !thread.isDeleted else { return }
                thread.draft = draft
                save()
            },
            onTurnCommitted: { prompt, reply in
                guard thread.modelContext != nil, !thread.isDeleted else { return }
                thread.appendTurn(prompt: prompt, reply: reply)
                save()
            }
        )
    }

    private func createThread() {
        let thread = ConversationThread()
        modelContext.insert(thread)
        saveConversations()
        selectThread(thread)
        preferredCompactColumn = .detail
    }

    private func deleteThread(_ thread: ConversationThread) {
        let id = thread.id
        let wasSelected = selectedThreadID == id
        let nextThread = wasSelected ? threads.first { $0.id != id } : nil
        threadToDelete = nil
        editors.removeValue(forKey: id)?.stop()
        modelContext.delete(thread)
        saveConversations()
        if wasSelected {
            selectThread(nextThread)
            if nextThread == nil {
                preferredCompactColumn = .sidebar
            }
        }
    }

    private func saveConversations() {
        Self.saveConversations(in: modelContext, reportingErrorsTo: $isSaveErrorPresented)
    }

    private static func saveConversations(in modelContext: ModelContext, reportingErrorsTo alert: Binding<Bool>) {
        do {
            try modelContext.save()
        } catch {
            alert.wrappedValue = true
        }
    }
}

#Preview {
    MainView()
        .modelContainer(for: ConversationThread.self, inMemory: true)
}
