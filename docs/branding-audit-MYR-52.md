# MYR-52 Branding Audit

## Current Values

- App/repository name: `MyRAM`
- Debug display name: `MyRAM Dev`
- Release app target bundle identifier: `com.apexcoretechs.MyRAM`
- Debug app target bundle identifier: `com.apexcoretechs.MyRAM.dev`
- Unit test bundle identifier: `com.apexcoretechs.MyRAMTests`
- UI test bundle identifier: `com.apexcoretechs.MyRAMUITests`
- Note intelligence schema domains:
  - `https://apexcoretechs.com/schemas/note_intelligence_input.schema.v1.json`
  - `https://apexcoretechs.com/schemas/note_intelligence_output.schema.v1.json`
- Internal attributed string key namespace: `com.apexcoretechs.myram.checklist-auto-strikethrough`
- User-facing export naming:
  - `MyRAM Notes Export`
  - `MyRAM-<Note>-<timestamp>.json`
  - `MyRAM-Notes-<timestamp>.json`
  - `MyRAMExports`

## Values to Decide Before App Store Submission

- Final publisher/developer account name for store listings.
- Final production bundle identifier for the App Store app.
- Whether `apexcoretechs.com` is the final public domain for schema IDs, support, privacy, and app metadata.
- Public support URL.
- Public privacy policy URL.
- Public terms URL, if needed.
- Final store-facing app name and subtitle.
- Final release display name if it should differ from `MyRAM`.

## Hardcoded Project Locations

- Bundle identifiers and debug display name are set in `MyRAM.xcodeproj/project.pbxproj`.
- The debug bundle identifier expectation is asserted in `MyRAMTests/MyRAMTests.swift`.
- Note intelligence schema IDs are hardcoded in:
  - `docs/note-intelligence/contracts/note_intelligence_input.schema.v1.json`
  - `docs/note-intelligence/contracts/note_intelligence_output.schema.v1.json`
- The internal attributed string key namespace is hardcoded in `MyRAM/Views/NoteEditorView.swift`.
- Export titles, filenames, and export directory names are hardcoded in `MyRAM/ViewModels/NotesViewModel.swift`.

## Notes

- No support URL, privacy policy URL, terms URL, or publisher name was found in the iOS project.
- No placeholder support or store URLs were found.
- No final branding values were invented for this audit.
