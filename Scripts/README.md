# MyRAM Scripts

## Reset macOS local storage

`reset-myram-mac-local-storage.sh` resets exactly one MyRAMMac build configuration. It stops only the selected Debug or Release app, waits for that app to exit, then removes that configuration's SwiftData store, external blob storage, and widget snapshot.

Run from the repository root:

```bash
Scripts/reset-myram-mac-local-storage.sh debug
Scripts/reset-myram-mac-local-storage.sh release
```

Preview the selected paths without stopping the app or deleting anything:

```bash
Scripts/reset-myram-mac-local-storage.sh debug --dry-run
```

Skip the confirmation prompt:

```bash
Scripts/reset-myram-mac-local-storage.sh debug --yes
```

Without `--yes`, enter `RESET DEBUG` or `RESET RELEASE` when prompted.

The reset preserves the other build configuration and does not remove `~/Library/Application Support/MyRAM`, because that sync-state directory is shared between Debug and Release.

If the selected app cannot be stopped, the script aborts before deleting local data.

> Warning: A reset permanently deletes the selected configuration's local note data and widget snapshot.
