# FreeDisplay-en — English-only fork + auto-arrange left

## Base

- Base: **Akuwatoga/FreeDisplay, commit `a58e485`** (release **v1.0.5-tahoe.1**),
  itself a fork of huberdf/FreeDisplay. All Tahoe/DCP fixes are kept
  (EDID-matched DDC, brightness-slider crash fix, menu-panel `minHeight`).
- Local git history: first commit is the untranslated Akuwatoga import, so
  `git diff HEAD~1` / `git log` shows exactly what changed here.
- **Not pushed anywhere yet.** No remote is configured. See
  [Pushing to your repo](#pushing-to-your-repo).

## Why English-only

On a Mac whose system language is neither English nor Chinese, the app fell
back to the string catalog's **source language (`zh-Hans`)** and showed a
Chinese UI, even though a full English translation existed in the catalog.
Rather than fixing the fallback, this fork removes Chinese from the app
entirely: every user-visible string is now an English literal in Swift.

## Translation method

1. Parsed `FreeDisplay/Resources/Localizable.xcstrings` (165 keys, **all** had
   an `en` value) into a zh → en dictionary.
2. Applied it as substring replacements over all `FreeDisplay/**/*.swift`,
   longest strings first so full strings win over their fragments.
3. Two catalog keys were **skipped deliberately**: they are truncated
   fragments of interpolated Swift strings
   (`亮度控制模式：\(ddcStatus == true ? …`, `显示器：\(display.name)…`) —
   replacing them would have deleted the interpolation and broken the code.
   Their prefixes were translated with the manual fragments below instead.
4. Manual fragments for strings the catalog only had as format strings or
   not at all (cross-checked against the angkasa27 fork's English wording,
   catalog wording wins on conflicts):
   `内建显示屏` → "Built-in Display", `DDC 硬件` → "DDC hardware",
   `，主显示器` → ", main display", `设 … 为主显示器` → "Set … as main display",
   preset names `原生模式` → "Native mode", `HiDPI 模式` → "HiDPI mode",
   `我的预设` → "My presets", plus comment translations.
5. One catalog bug found and fixed by hand: the English value for the DDC
   help text contains a JSON `\n`, which decodes to a **real newline** —
   inserting it verbatim split a Swift `"…"` string literal across two lines
   (syntax error). It is now the two-character escape `\n` in
   `Views/BrightnessSliderView.swift`.

## What changed for English-only

- `Localizable.xcstrings` **deleted** (option (a) in the plan: rely on the
  English literals, no catalog at all). Removed from
  `FreeDisplay.xcodeproj/project.pbxproj` (build file, file reference,
  Resources group, Resources build phase).
- In-app language picker **removed**: `SettingsService.PreferredLanguage`
  enum, the `fd.preferredLanguage` key/property, the picker in
  `Views/MenuBarView.swift` (SettingsView), and the
  `.environment(\.locale, …)` override in `FreeDisplayApp.swift` are gone.
  There is no `zh-Hans` fallback left anywhere in the app target.
- `project.yml`: `developmentLanguage: zh-Hans` → `en`,
  `KNOWN_REGIONS: "en zh-Hans Base"` → `"en"`.
- `project.pbxproj`: `developmentRegion = "zh-Hans"` → `"en"`, `zh-Hans`
  removed from `knownRegions`, `KNOWN_REGIONS` → `"en"` (Debug + Release).
- `INFOPLIST_KEY_NSScreenCaptureUsageDescription` translated to English
  (in `project.yml` and both `project.pbxproj` configs): "FreeDisplay needs
  screen recording permission to show live previews of each display."
- `README.zh-CN.md` deleted; the Chinese README link removed from
  `.github/workflows/release.yml`.
- `DEVELOPMENT_TEAM` left as `29W56PHWJR` (the fork author's team) and
  bundle ID `com.freedisplay.app` unchanged — see
  [Build](#build-on-your-mac).

## Verification (translation)

- Before: **1,177 CJK chars in 23 Swift files**. After: **0 CJK chars in
  any `FreeDisplay/**/*.swift`** (216 substring replacements).
- `grep -r "zh-Hans"` over the app target (all Swift, `project.yml`,
  `.xcodeproj`): no matches. The string `zh-Hans` still appears only as a
  historical mention in this file and in `README.md` ("was `zh-Hans` → `en`").
  No `简体中文` remains anywhere outside `.git`.
- Files with the most strings changed: `Views/MenuBarView.swift` (47),
  `Views/ImageAdjustmentView.swift` (31), `Views/VirtualDisplayView.swift`
  (27), `Views/SavePresetView.swift` (16), `Views/BrightnessSliderView.swift`
  (13), `Views/DisplayModeListView.swift` (12).
- Still contains Chinese (deliberately left): `docs/` (internal dev notes,
  roadmap, lessons), `CLAUDE.md` / `AGENTS.md` / `FreeDisplay/*/CLAUDE.md`
  (agent harness notes). None of it is user-visible in the app.
- Quote-balance sanity check run over all Swift files after translation
  (no multi-line `"…"` literals left). **UNTESTED: there is no Xcode/Swift
  on this Linux VM, so the project has not been compiled.** First build must
  happen in Xcode 16 on the MacBook Air (see below).

## Auto-arrange on connect

### Root cause (verified in the Akuwatoga base)

The app already auto-arranged on plug-in — but to the wrong place.
`FreeDisplayApp` set `fd.arrangement.externalAbove=true` on first launch and
`DisplayManager.scheduleAutoArrange()` (debounced 500 ms after the
`CGDisplayRegisterReconfigurationCallback` add/remove callback) called
`arrangeExternalAboveBuiltin()`, which put every external centered **above**
the built-in. That is why the Arrange Displays panel always showed the
external on top and the MacBook below, even after a manual drag: the app
re-applied it on the next reconfiguration event.

### New behaviour

- New preference key **`fd.arrangement.externalPosition`**, values
  `"left"` (default for new installs), `"right"`, `"above"`, `"off"`.
- **Migration:** if the new key is absent but the old
  `fd.arrangement.externalAbove` boolean exists, `true` → `"above"`,
  `false` → `"off"`, then the old key is deleted. Otherwise the default is
  `"left"`.
- `DisplayManager.arrangeExternalAboveBuiltin()` is replaced by
  `arrangeExternalDisplay(force: Bool = false)` (all callers updated; no
  wrapper kept — nothing else called the old name). Layout maths lives in
  the pure function `arrangementTargets(position:builtin:externals:)`.
- `ArrangementService.setPositions([(id, x, y)])` moves **all** displays in
  **one** `CGBeginDisplayConfiguration` → `CGConfigureDisplayOrigin` × N →
  `CGCompleteDisplayConfiguration` transaction (10 s `CGHelpers.runWithTimeout`
  guard, same as the existing single-display methods). The old per-display
  `setPosition` loop is gone from auto-arrange.
- **Manual drags are left alone:** auto-arrange only runs when the online
  display-ID set changed since the last auto-arrange (plug/unplug). A drag
  in System Settings or in the app's own canvas changes positions but not
  the ID set, so it is not re-applied. Changing the preference in the UI
  calls `arrangeExternalDisplay(force: true)` to apply immediately.
- **No self-loop:** after our own transaction the reconfiguration callback
  fires again and re-schedules, but the 1 px guard skips when current
  origins already match the target.
- Only runs with a built-in display + at least one external; otherwise no-op.
  The 500 ms debounce in `scheduleAutoArrange()` and the 2 s delay on launch
  are unchanged. The wake-from-sleep path does not call arrange (it only
  refreshes displays/brightness/resolution, as before).

### Layout maths (logical points, top-aligned, y = 0)

| Position | External(s) | Built-in |
|----------|-------------|----------|
| `left` (default) | externals stacked left→right from x = 0, in displayID order | at x = sum of external widths |
| `right` | stacked from x = built-in width | at (0, 0) |
| `above` | each centered above the built-in: x = builtinX + (builtinW − extW) / 2, y = builtinY − extH (previous behaviour, unchanged) | stays put |
| `off` | — | — |

**User's setup, verified by simulating the Swift maths in Python:**
external ARZOPA logical **1440×810**, built-in **1440×900**:

| Position | External | Built-in | Main display |
|----------|----------|----------|--------------|
| `left` | (0, 0) | (1440, 0) | external (it contains the origin) — stays main, as now |
| `right` | (1440, 0) | (0, 0) | built-in |
| `above` | (0, −810) | (0, 0) | built-in |

Multiple externals stack left-to-right, e.g. left with 1920 + 1280 wide
externals: (0, 0), (1920, 0), built-in at (3200, 0).

### UI (ArrangementView, all English)

New "Auto-arrange on connect" section under the arrangement canvas: a
toggle (off = `"off"`, on = restores the last non-off position, kept in
memory) and a segmented Left / Right / Above picker (disabled while off),
plus the note "Applies when an external display is plugged in". Changing
either applies immediately to the current displays. The apply goes through
a single `onChange` handler, so one preference change is one transaction
(the toggle only flips the value).

### Files changed (auto-arrange)

- `FreeDisplay/Services/SettingsService.swift` — `ExternalPosition` enum,
  `externalPosition` (+ `lastNonOffPosition`), migration in `loadAll()`.
- `FreeDisplay/Services/DisplayManager.swift` — `arrangeExternalDisplay()`,
  `arrangementTargets()`, `lastAutoArrangedDisplayIDs` guard.
- `FreeDisplay/Services/ArrangementService.swift` — `setPositions()`.
- `FreeDisplay/App/FreeDisplayApp.swift` — first-launch default `"left"`.
- `FreeDisplay/Views/ArrangementView.swift` — UI section.

## Build on your Mac

```bash
brew install xcodegen
git clone https://github.com/<your-username>/<your-repo>.git
cd <your-repo>
xcodegen generate
# Unsigned local build (no Apple Developer account needed):
xcodebuild -scheme FreeDisplay -configuration Release \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build
# Then copy build/Build/Products/Release/FreeDisplay.app to /Applications
# (or open FreeDisplay.xcodeproj in Xcode and press Cmd+R).
```

Notes:

- `project.yml` still says `DEVELOPMENT_TEAM: 29W56PHWJR` and
  `CODE_SIGN_IDENTITY: "Apple Development"`. For a signed build, replace
  the team with your own; for an unsigned local build, the
  `CODE_SIGN_IDENTITY="-"` override above is enough. `build.sh` archives
  with the project's signing settings, so it needs your team set first.
- `xcodegen generate` is required after any `project.yml` change (it was
  **not** run here — no xcodegen/Xcode on this VM; the committed
  `.xcodeproj` was edited by hand to match `project.yml`).
- First launch: right-click → Open (unsigned app, one-time Gatekeeper
  approval), or `sudo xattr -rd com.apple.quarantine /Applications/FreeDisplay.app`.
- The in-app update check is disabled until you set `repoOwner`/`repoName`
  in `FreeDisplay/Services/UpdateService.swift` (currently `"OWNER"`).

## Pushing to your repo

Repo name is still to be confirmed by the user. When it is:

```bash
cd ~/workspace/FreeDisplay-en
git remote add origin https://github.com/hieupeek/DisplayKit.git
git branch -M main
git push -u origin main
```

Done before pushing (commit `Point repo at hieupeek/DisplayKit`): `README.md` (Download / Report an Issue), `.github/workflows/release.yml` (release-body README link) and `FreeDisplay/Services/UpdateService.swift` (`repoOwner = "hieupeek"`, `repoName = "DisplayKit"`) now point at hieupeek/DisplayKit. Attribution to Akuwatoga/huberdf remains in README/TRANSLATION.

## Manual test checklist (on the MacBook Air, macOS 27.2.1, ARZOPA external)

1. Build & launch: menu bar shows in English, no Chinese anywhere.
2. Plug in the ARZOPA: external goes **left** of the built-in, built-in
   moves right, external stays the main display.
3. Drag the external manually in System Settings → Displays (e.g. below the
   built-in): it **stays** where you put it (no re-apply after 500 ms).
4. In the app → Arrange Displays → "Auto-arrange on connect": switch to
   Right → built-in jumps left, external right, immediately. Switch to
   Above → external goes above, centered. Switch off → plug/unplug does
   nothing.
5. Brightness slider on the ARZOPA: DDC (hardware) vs software fallback —
   the Tahoe/DCP behaviour is unchanged by this fork.
