---
name: Sky macOS App Project
description: Native macOS AI agent app — hotkey-triggered floating command bar using AppKit + Anthropic API
type: project
---

Project is a native macOS app called Sky at `/Users/andrewwilson/my projects/sky`.

Built with AppKit (NSPanel floating bar), Swift concurrency, MVVM, SQLite.swift, xcodegen.

**Why:** Phase 0 foundation — full plumbing in place, all action handlers are stubs. Phase 1 = replace stubs with real implementations.

**How to apply:** When continuing work, preserve the MVVM boundary (PanelViewModel owns all state), keep ActionRouter stubs interface-compatible, and add real implementations per-action without changing method signatures.

Key architecture:
- `AppDelegate` — owns panel lifecycle, hotkey, menu bar, scheduler startup
- `PanelViewModel` — all panel state (PanelState enum: idle/loading/confirmation/error/awaitingAPIKey)
- `IntentParser` — Anthropic API via URLSession async/await → ParsedIntent
- `ActionRouter` — routes ParsedIntent to per-action stubs (Phase 0)
- `SchedulerService` — 60s timer polling SQLite for due actions
- `DatabaseManager` — SQLite.swift wrapper for scheduled_actions table
- `ConfigService` — ~/Library/Application Support/Sky/config.json (API key storage)
- `HotkeyManager` — CGEventTap for global ⌥Space hotkey

Hotkey default: Option+Space (keyCode 49, modifiers 2048).
Model: claude-sonnet-4-20250514
Min deployment: macOS 13. No Dock icon (LSUIElement=true).
