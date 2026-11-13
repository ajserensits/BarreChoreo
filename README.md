# Barre Choreography

A native SwiftUI iPhone + Apple Watch MVP for importing and using choreography scripts without a backend.

## What it does

- Imports actual `.pdf` files through the iPhone Files picker.
- Builds a new sanitized PDF from one or more files containing broad Stamp highlights: extracted portions can be previewed, excluded, and reordered before generation, with an option to keep or remove the visible highlighting.
- Extracts selectable PDF text with PDFKit.
- Keeps the original extracted text and every nonblank cue line, including wording and counts.
- Detects Classic, Define, Engage, Align, Reform, and Empower class plans.
- Organizes numbered blocks or named sections, combinations, short/full cues, songs, equipment, options, setup notes, transitions, repeats, and music/lighting instructions.
- Saves multiple scripts locally as JSON in Application Support.
- Builds new study/class plans from selected sections across one or more saved imports. Sections start unselected, can be previewed and edited for the new plan, and can be reordered before saving without changing their source PDFs.
- Keeps built plans editable on iPhone and optionally makes them available offline on Apple Watch.
- Includes an offline iPhone Study Mode with combination-title flash cards, selectable sections, optional shuffle, cue-by-cue reveal, and Study Again/Got It progress tracking.
- Lets the instructor choose which plans are available on Apple Watch and shows when the selected payload is small enough for simulator-friendly context sync.
- Syncs the selected offline library using WatchConnectivity file transfers, with application context for small immediate updates.
- Supports Focus mode (one crown-stepped cue at a time) and Continuous mode (smooth crown scrolling), section paging, readable watch text, and per-section position restoration.
- Starts each class with an elapsed timer in the upper-right; the timer survives app restarts and continues across reading-mode changes, with pause/resume and confirmed end-class reset controls.
- Optionally uses the paired iPhone microphone for Audio Follow. The Watch can request a location suggestion based on recent speech plus elapsed class time, and can enable conservative automatic cue advancement separately.

## Open and run

1. Open `BarreChoreography.xcodeproj` in Xcode 16.0 or newer.
2. Select the `BarreChoreography` target and choose your Apple Developer Team under Signing & Capabilities.
3. If Xcode asks, give the watch target the same team.
4. Choose an iPhone simulator/device paired with an Apple Watch simulator/device.
5. Run the `BarreChoreography` scheme.
6. On iPhone, tap **Import PDF**, choose a PDF from Files, verify the detected class type and sections, choose whether it should be available on Watch, and tap **Save**.
7. Swipe right on a saved class or open its detail screen to add or remove it from the Watch library. Tap **Sync Watch** to resend the current selection.

## Build a class plan from multiple imports

1. On iPhone, tap **+**, then **Build Class Plan**.
2. Choose the saved imports you want to use and tap **Next**.
3. Use the eye button to preview any section. Choose **Edit for This Plan** to edit, add, delete, or reorder its combinations and cues; **Restore from Source** discards those draft edits.
4. Explicitly select each section to include. Every section starts unselected, and edited sections are marked with a pencil.
5. Name the plan, drag its sections into teaching order, and optionally enable **Available on Apple Watch**.
6. Tap **Save**. The result appears alphabetically in the library as a **Built Plan** and can be edited later without changing its sources.

## Build a PDF from highlighted portions

1. On iPhone, tap **+**, then **Build Highlighted PDF**.
2. Choose one or multiple PDFs containing broad Apple Markup highlights saved as Stamp annotations. `SampleDocuments/Barre-Stamp-Sample.pdf` is included for testing this flow.
3. Preview the detected portions, deselect anything to omit, and drag the rows into the desired output order.
4. Name the PDF and choose whether the visible highlighting should remain.
5. Tap **Generate**, review the flattened result, then tap **Save or Share PDF** to save it in Files or share it. Extracted portions are scaled to a consistent width and stitched continuously onto standard white PDF pages.

Generation happens locally. Disconnected highlighted areas are extracted as separate portions so unhighlighted material between them is not included. Each selected crop is rasterized into the output so page content outside the visible crop is not retained as hidden PDF data.

## Audio Follow and Locate Me

1. On iPhone, open the upper-left Watch menu and tap **Set Up Audio Follow**. Allow Microphone and Speech Recognition when asked.
2. Start a class on Watch, open the section-list button, and turn on **Listen on iPhone** under Audio Follow. It is off by default.
3. Leave **Auto Advance** off for suggestions/manual positioning, or enable it separately for high-confidence forward cue changes.
4. Tap **Locate Me** when you lose your place. The app compares the rolling 90 seconds of recognized speech with the full script and uses elapsed class time as supporting evidence. The Watch shows the proposed section and cue for confirmation before jumping.

The microphone audio is processed by Apple's speech recognizer and is not saved by this app. Recent transcript evidence is held in memory only and is cleared when Audio Follow stops or the class ends. On-device recognition is requested when the current iPhone supports it. The iPhone needs to remain paired, nearby, and available during class.

The bundle IDs use the placeholder prefix `com.example.barre`; change them in the project settings before installing on physical devices.

## Parsing rules

The parser recognizes quarterly master documents plus Classic, Define, Engage, Align, Reform, and Empower individual plans. It handles both `BLOCK 1 | WARMUP`-style plans and named sections such as `FLOOR CORE WORK`, `CARDIO CENTRIC #2`, `SEAT`, and `COOL DOWN`. Overview-table furniture is omitted from the teaching feed; inline song, equipment, option, and direction fields become section metadata. Define and Engage lines separated by `|` retain the short prompt for Focus mode and the complete instruction for Continuous mode. Operational instructions are classified separately so the Watch can visually distinguish setup, equipment, options, repeats, transitions, and music/lighting notes. The complete original PDF extraction remains available on iPhone.

## MVP limitations

- PDFKit only extracts embedded/selectable text. Image-only scans require OCR, which is intentionally not part of this MVP.
- Highlighted-PDF generation currently recognizes sufficiently large Stamp annotations. Standard Highlight/Ink annotations and color markings baked into scanned images are not yet treated as extractable portions.
- PDF layout extraction is reading-order dependent. Multi-column or unusually designed PDFs may need a review/editing workflow in a future version.
- Watch sync is Apple-managed and may be delayed when the counterpart app is inactive; the latest received library remains available offline.
- Apple does not support WatchConnectivity `transferFile` delivery in Simulator. Selected libraries up to the app's 60 KB context threshold can use the simulator-friendly context path; final queued-file testing requires paired physical devices.
- The app stores imported text, not the original PDF binary.
- Audio matching is a teaching aid, not a guaranteed transcription of a live class. Music, room noise, paraphrasing, and microphone placement affect confidence; validate it on physical paired devices before relying on Auto Advance.
- The simulator can validate the matcher, controls, and WatchConnectivity messages, but classroom microphone/background behavior and accuracy must be tested on a physical iPhone and Watch.

## Regenerate the project

The checked-in `.xcodeproj` is generated from `project.yml` in the Xcode 16 project format:

```sh
xcodegen generate
```

## Tests

Run the `BarreChoreographyTests` test target in Xcode, or use:

```sh
xcodebuild test -project BarreChoreography.xcodeproj -scheme BarreChoreography -destination 'platform=iOS Simulator,name=iPhone 15'
```
