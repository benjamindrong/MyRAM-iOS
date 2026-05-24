# MyRAM iOS

MyRAM is a native iOS notes app for quickly capturing, editing, and returning to personal notes with as little friction as possible.

This repository contains the iOS implementation. The matching Android app lives in the MyRAM Android repository.

---

# Current Direction

MyRAM focuses on:
- fast note creation
- low-friction editing
- auto-save while typing
- reopening the last active note
- creating a new note without leaving the editor
- native text selection and editing controls

The app is designed around quick capture and continued editing rather than folder-heavy organization.

---

# Design Philosophy

The user should be able to:
- open the app and continue where they left off
- type without thinking about saving
- create a new note as soon as a new thought appears
- delete notes without leaving the current workflow
- select and edit text using native platform behavior

There are currently no:
- folder systems
- manual save flows
- sync requirements
- account requirements

Editing should feel immediate, local, and predictable.

---

# Technical Direction

MyRAM iOS is built using:
- Swift
- SwiftUI
- SwiftData
- UIKit text editing where native selection behavior is needed

The iOS and Android apps are native implementations of the same product direction. They are intentionally not a shared multiplatform codebase.

---

# Current App Goals

Current development focuses on:
- reliable editor behavior
- stable note switching
- predictable auto-save
- native platform editing controls
- simple local persistence

The current milestone is making note capture and editing feel dependable before expanding into encrypted export, recently deleted notes, desktop support, or cross-device workflows.

---

# Planned Structure

```text
MyRAM/
    Models/
    ViewModels/
    Views/
    Assets.xcassets/

MyRAMTests/
MyRAMUITests/
```

---

# Build

Open `MyRAM.xcodeproj` in Xcode, or build from the repository root:

```sh
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'generic/platform=iOS Simulator' build
```
