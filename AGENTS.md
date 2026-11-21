# Repository Guidelines

## Project Structure & Module Organization

`Supernova/` contains the SwiftUI application. `SupernovaApp.swift` is the app entry point, and `MainView.swift` defines the navigation split view and message composer. Put UI assets in `Supernova/Assets.xcassets/`. Keep unit tests in `SupernovaTests/` and UI automation in `SupernovaUITests/`. `Supernova.xcodeproj` defines the app and both test targets.

## Build, Test, and Development Commands

Use Xcode 27.2 to build for iOS 26.0, macOS 27.2, and visionOS 27.2. Run commands from the repository root.

```sh
xcodebuild -project Supernova.xcodeproj -scheme Supernova -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcrun simctl list devices available
xcodebuild -project Supernova.xcodeproj -scheme Supernova -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' test
```

The first command builds for the iOS Simulator without signing. Use the second command to find a compatible simulator and replace `SIMULATOR_UDID` in the third command to run both test targets. To launch locally, open `Supernova.xcodeproj` in Xcode, select the `Supernova` scheme and a destination, and choose Product → Run.

After each change, build the latest working tree, install the resulting `Supernova.app` on the **iPhone Duo** simulator, and launch it. Leave the app open in Simulator for review. Confirm the launch in your handoff, or report what blocked it.

## Coding Style & Naming Conventions

Use four spaces for indentation. Name Swift types and their files in `UpperCamelCase`, and use `lowerCamelCase` for properties and methods. Follow the existing SwiftUI style with one chained modifier per line and `private` view state. Use native SwiftUI controls where they fit. The repository has no configured formatter or linter.

## Testing Guidelines

Use Swift Testing (`@Test`) for unit tests and XCTest (`XCTestCase`) for UI tests. Name tests for the behavior they exercise and prefix XCTest methods with `test`, such as `testComposerGrowsWhenTextWraps`. Run the relevant tests before submitting. For layout changes, verify affected states on the relevant destination. The repository has no configured coverage threshold.

## Commit & Pull Request Guidelines

The Git history starts with `Initial Commit`. Use short, action-oriented commit subjects. In each pull request, describe the change and how you verified it, link any related issue, and include screenshots for visible UI changes.
