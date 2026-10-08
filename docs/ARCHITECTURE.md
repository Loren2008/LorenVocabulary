# Architecture

LorenVocabulary is a Swift Package that produces a native macOS executable. SwiftUI owns the main app lifecycle and views; AppKit handles global keyboard events, menu-bar integration, the floating lookup panel, and clipboard-based text selection.

## Runtime flow

```text
NSEvent global/local monitors
        │ double-Control
        ▼
TextSelectionService
        │ synthesize Cmd+C; deep-copy and restore every pasteboard item/type
        ▼
PopupWindowController
        ├─ DatabaseService (optional SQLite direct entry / alias)
        ├─ LocalCacheService (JSON cache)
        ├─ MacDictionaryService (DictionaryServices)
        └─ DictionaryService
              ├─ Free Dictionary API
              └─ DeepSeekService (optional)
```

The main window deliberately uses a richer lookup path than the compact panel. It prefers the macOS system dictionary for detailed definitions and augments results with locally stored IELTS-style context when available.

## Components

| Area | Main files | Responsibility |
| --- | --- | --- |
| App lifecycle | `Sources/AppEntry.swift`, `Sources/App/AppDelegate.swift` | Window scene, status menu, shortcut startup, permission prompt |
| Input | `KeyMonitorService.swift`, `TextSelectionService.swift` | Double-Control detection and selected-text capture |
| Lookup | `DictionaryService.swift`, `DatabaseService.swift`, `MacDictionaryService.swift` | Source selection, SQLite lookup, parsing, fallbacks |
| Persistence | `StorageService.swift`, `LocalCacheService.swift` | Saved words and cache under `~/.ielts-vocab` |
| Configuration | `SettingsView.swift`, `KeychainService.swift`, `Config.swift` | Keychain-backed API key and user defaults |
| UI | `Sources/Views` | Main search, popup, word list, details, and review |
| Data pipeline | `BatchBuilder`, `Analysis` | Candidate generation, guarded AI enrichment, validation, and QA |

## Safety-sensitive invariants

- Selected text is obtained by synthesizing Copy because many apps expose selection inconsistently.
- Pasteboard items must be copied by value for every item and declared type, then restored asynchronously after the target app has completed Copy.
- The floating window remains at `.popUpMenu` level so it is visible above other applications.
- Local development builds reuse one signing identity and bundle identifier. Do not add `tccutil reset` to build scripts.
- Dictionary publication uses staging, schema checks, backups, and compare-and-swap checks instead of writing model output directly into the canonical database.

## Local files

All mutable user data stays outside the repository:

```text
~/.ielts-vocab/
├── Config.plist       # optional legacy/headless configuration
├── words.db           # optional user-supplied dictionary
├── saved_words.json
├── cache/
├── backups/
├── expansion-runs/
└── signing/           # local development identity
```

The API key entered in the Settings window is stored in macOS Keychain rather than this directory.
