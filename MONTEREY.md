# Monterey compatibility

This update modifies the owner's working upload for macOS Monterey 12.7.6, a 1.6 GHz Intel Core i5 and 8 GB memory. Swift tools 5.7, Swift 5 language mode and macOS deployment 12.0 are unchanged.

Preserved compatibility fixes:

- Qualified HungrySpotCore.Category references in the UI.
- Small MenuManagementView subviews and simple Table columns.
- Main-actor reporting tests with straightforward loops.
- Password content type `.password`.
- Monterey NSPrintInfo/PaginationMode handling.
- Darwin.lockf plus an NSLock-protected in-process store registry.
- SQLite backup API, standalone DELETE journal, explicit close and sidecar cleanup.
- One-job SwiftPM testing/building and manual `.app` packaging.

The sidebar has a 64-point collapsed mode. Payment details scroll within a 570-point sheet with confirmation buttons always visible. Native appearance and interaction still need checking on the actual screen.

Run the preserved workflow in the extracted project:

```sh
bash scripts/build-macos.sh
```

The application output is `build/The Hungry Spot.app`. The source ZIP contains source/resources/tests and build tools; it excludes the uploaded stale executable, local SwiftPM caches and personal IDE state.

The user verified the previous 74-test baseline on the Mac. This modified revision has passed the portable checks listed in VERIFICATION.md, but its 106 XCTest cases and native app build have not run here because this host is Windows. No Monterey compile or runtime success is claimed for the changes until that Mac verification runs.
