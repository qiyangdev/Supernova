//
//  SupernovaApp.swift
//  Supernova
//
//  Created by qiyang on 2026/11/20.
//

import SwiftData
import SwiftUI

@main
struct SupernovaApp: App {
    private let conversations = Result {
        #if DEBUG
            if let storeID = ProcessInfo.processInfo.environment["SUPERNOVA_UI_TEST_STORE"],
                let id = UUID(uuidString: storeID)
            {
                let url = URL.temporaryDirectory
                    .appending(path: "SupernovaUITests-\(id.uuidString).store")
                return try ModelContainer(
                    for: ConversationThread.self,
                    configurations: ModelConfiguration(url: url)
                )
            }
        #endif
        return try ModelContainer(for: ConversationThread.self)
    }

    var body: some Scene {
        WindowGroup {
            switch conversations {
            case .success(let container):
                MainView()
                    .modelContainer(container)
            case .failure:
                ContentUnavailableView(
                    "Couldn’t Open Conversations",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("Check available storage and reopen Supernova.")
                )
            }
        }
    }
}
