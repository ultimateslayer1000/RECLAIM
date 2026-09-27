# RECLAIM

**Make space. Keep what matters.**

An iOS 17+ storage cleaner that finds duplicate photos, near-identical shots,
screenshots, oversized videos and repeated contacts — then removes only what you
explicitly approve. Everything runs on-device. Nothing is ever uploaded.

---

> ### Verification status — read this first
>
> Built and run with **Xcode 26.3** against the **iOS 26.2 SDK**.
>
> | Check | Result |
> |---|---|
> | App target compiles | ✅ **zero errors, zero warnings** |
> | Unit + integration tests | ✅ **89 executed, 0 failures, 1 skipped** |
> | Launches on simulator | ✅ no crashes |
> | Storage dashboard reads real volume | ✅ verified |
> | Info.plist permission strings | ✅ iOS displayed them verbatim |
> | **Exact duplicate detection** | ✅ **verified against planted fixtures** |
> | **No false-positive grouping** | ✅ **verified** |
> | Reclaimable byte maths | ✅ matches hand calculation |
> | Empty states | ✅ verified |
> | **Similar-photo detection (Vision)** | ⚠️ **cannot run in Simulator — needs a real iPhone** |
> | Screenshot detection | ⚠️ not testable in Simulator (see below) |
> | Contacts detection | ⚠️ Simulator address book is empty |
> | Deletion, merging, cleanup | ⚠️ **never executed — real-device only** |
>
> The one skipped test is the Vision clustering assertion, which skips
> deliberately rather than passing vacuously. See
> [Known limitations](#known-limitations).
>
> **Nothing has ever been deleted by this app.** The deletion path is written
> and reviewed but has not been executed even once, on any device. Treat the
> first real cleanup as the genuine test of it, and run it on items you are
> willing to lose.

---

## Product overview

The loop is **SCAN → REVIEW → CLEAN**.

1. **Scan** — RECLAIM reads the photos and contacts you've granted access to,
   fingerprints every image, groups duplicates and near-duplicates, isolates
   screenshots, measures video sizes and looks for repeated contacts.
2. **Review** — you choose what goes. Nothing is pre-selected for deletion.
3. **Clean** — a single confirmation gate, then deletion, then verification of
   what actually disappeared.

## Features

**Storage dashboard**
- Used / free / total device capacity from public `URLResourceValues` keys
- Estimated reclaimable space, shown as a separate claim from device storage
- Circular ring with two arcs: used (outer) and reclaimable (inner)
- Per-category cards with live counts, sizes and selection state

**Photos**
- Content-based duplicate detection via a 64-bit perceptual difference hash
  (dHash) — resilient to resizing and re-encoding, and not fooled by filenames
  or `localIdentifier`
- Near-identical grouping via Vision `VNGenerateImageFeaturePrintRequest`
  (revision 2), constrained to a temporal window so large libraries stay fast
- A **Suggested keep** per group, scored from resolution, sharpness (Laplacian
  variance), favourite status and exposure — with recency as a tie-break only
- The suggestion is always overridable; tap "Keep this" on any other frame
- Long-press any thumbnail for a full-screen preview before deciding

**Screenshots**
- Identified by the documented `.photoScreenshot` media subtype
- Grid with individual and bulk selection, live totals

**Videos**
- Sorted largest → smallest, with a bar showing relative size at a glance
- Real file sizes read through public API only (see
  [Hard problems](#hard-problems-and-how-they-were-solved))
- Estimated sizes are labelled as estimates rather than presented as fact

**Contacts**
- Duplicate detection on normalised phone numbers, emails and names
- Transitive grouping via union-find, so A↔B↔C becomes one group, not two pairs
- Every group states *why* it was grouped ("Same phone number")
- Merge / Delete / Ignore per group; merges show the exact resulting field set
  before anything is approved

**Safety**
- Selection and deletion are separate systems. `SelectionStore` has no access to
  `PHPhotoLibrary` or `CNContactStore` at all.
- One confirmation gate, then a second system-level confirmation from iOS
- Post-deletion verification: the library is re-read and anything still present
  is reported as a failure

## Architecture

```
RECLAIM/
├── App/            ReclaimApp, RootView (tabs + review bar), AppModel
├── Core/
│   ├── Models/     Sendable value types: PhotoCandidate, SimilarGroup,
│   │               ContactDuplicateGroup, CleanupPlan, CleanupOutcome, …
│   ├── Utilities/  Normalizers, Formatters, BoundedConcurrency
│   └── DesignSystem/  Theme: palette, spacing, typography, motion
├── Services/       PermissionService, StorageService, PhotoLibraryService,
│                   ThumbnailProvider, ImageFingerprint, PhotoAnalyzer,
│                   PhotoSimilarityService, VideoService, ContactService,
│                   ContactDuplicateEngine, ScanEngine, CleanupService
├── Selection/      SelectionStore — the single source of selection truth
├── Features/       Dashboard, Photos, Videos, Contacts, Review,
│                   CleanupComplete, Permissions
├── Components/     Card, buttons, StorageRing, MediaThumbnail, CategoryCard,
│                   ScanProgressView, EmptyState, SelectionBadge
└── Resources/      Assets.xcassets (10 colour sets + generated app icon)
```

### Key decisions

**`PHAsset` never crosses an isolation boundary.** `PHAsset` is a non-`Sendable`
reference type. The scan reads what it needs once into `PhotoCandidate`, a plain
`Sendable` struct, and everything downstream — grouping, selection, the plan —
works in value types. Live assets are re-fetched by identifier only at deletion
time. This keeps the concurrency model sound *and* guarantees the app can only
delete an identifier the user approved.

**One decode per asset.** Thumbnail decoding dominates scan cost, so
`PhotoAnalyzer` fetches each 128pt thumbnail exactly once and derives the
fingerprint, the Vision feature print and the sharpness/brightness metrics from
that single decode.

**Bounded concurrency everywhere.** `BoundedConcurrency` keeps a fixed number of
operations in flight (6 for images, 3 for video), starting a replacement only as
one finishes. A 10,000-photo library never spawns 10,000 tasks.

**Actors for scan state, `@MainActor` for UI.** `ScanEngine`, `PhotoAnalyzer`,
`PhotoSimilarityService`, `VideoService` and `CleanupService` are actors.
`AppModel` and `SelectionStore` are `@MainActor` `@Observable` classes. Views
hold no business logic.

## Privacy approach

- No network code exists in the project. No backend, no analytics, no SDKs.
- Photos and contacts are read, processed and discarded in-process.
- Only the contact keys actually needed are fetched — names, organisation,
  phones, emails, an image-available flag. Never notes, birthdays or addresses.
- Hidden photo assets are deliberately excluded from all scans.
- `NSPhotoLibraryAddUsageDescription` is **not** requested: the app never adds
  photos, so asking for it would be requesting permission it doesn't need.
- The app functions fully offline.

## Setup

**Requirements:** Xcode 16 or later, iOS 17+ device or simulator.

### Picking an Xcode version on an Intel Mac

**Xcode 26.3 is the last release that runs on an Intel Mac.** The macOS floor
rises mid-series, which is easy to miss:

| Xcode | Minimum macOS | Runs on Intel? |
|---|---|---|
| 27.x | Tahoe 26.6+ | no |
| 26.4.1 – 26.6 | Tahoe 26.2+ | no |
| **26.3** | **Sequoia 15.6 – Tahoe 26.x** | **yes** |
| 26.0 – 26.2 | Sequoia 15.6 – Tahoe 26.x | yes |

Anything requiring macOS Tahoe is Apple-silicon-only, because Tahoe dropped
Intel support entirely. Xcode 26.3 ships the iOS 26.2 SDK, which builds this
project's iOS 17 deployment target without trouble.

The Mac App Store only offers the newest release, so on Intel you must download
26.3 directly from
[developer.apple.com/download/all](https://developer.apple.com/download/all/)
(free Apple ID required). Take the release `.xip`, not a beta.

Apple ships **two** `.xip` variants per release. Choose **Universal** — the
Apple-silicon build will not launch on an Intel Mac. Verify after installing,
because this is a known failure mode:

```bash
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -version                                    # expect Xcode 26.3
lipo -archs /Applications/Xcode.app/Contents/MacOS/Xcode
```

The last command must include `x86_64`. If it prints only `arm64`, the
Apple-silicon variant was installed and Xcode will not run.

Note that Xcode 26 no longer bundles simulator runtimes — the iOS simulator is
a separate download on first launch. This project is best tested on a real
iPhone regardless; the simulator's photo library is synthetic and
`AVURLAsset`-backed file sizes behave differently there.

> The project pins `SWIFT_VERSION = 5.0`. Xcode 26 defaults new projects to
> Swift 6 language mode, where the concurrency rules this code relies on become
> hard errors rather than warnings. Staying in Swift 5 mode is deliberate; move
> to Swift 6 only after the first clean build.

```bash
git clone <your-repo-url>
cd RECLAIM
open RECLAIM.xcodeproj
```

Select the **RECLAIM** scheme, choose a destination, and run.

To regenerate the project after adding files:

```bash
python3 Scripts/generate_xcodeproj.py
```

To regenerate the asset catalog and app icon:

```bash
python3 Scripts/make_assets.py
```

### Running on a real iPhone

Photo and contact behaviour cannot be meaningfully tested in the simulator — the
simulator's library is synthetic and `AVURLAsset`-backed file sizes behave
differently. Use a real device.

1. Connect the iPhone and trust the Mac.
2. In Xcode: **Signing & Capabilities** → select your Team. The bundle
   identifier defaults to `com.reclaim.app`; change it if that's taken.
3. Select your iPhone as the destination and press Run.
4. On the device: **Settings → General → VPN & Device Management** → trust your
   developer certificate.
5. Grant Photos and Contacts access when prompted.

> **Not TestFlight-ready.** No Apple Developer Program signing, provisioning
> profile, archive or App Store Connect record has been created. Those steps
> have genuinely not been done, so the project is not ready for distribution.

## Permissions

| Key | Why |
|---|---|
| `NSPhotoLibraryUsageDescription` | Read the library to find duplicates, screenshots and large videos; delete what the user approves. |
| `NSContactsUsageDescription` | Read contacts to find likely duplicates; merge or delete what the user approves. |

All three states are handled as first-class:

- **Denied** — explains what's unavailable and why, offers a Settings link, and
  the rest of the app keeps working. Denying Contacts leaves every photo feature
  functional, and vice versa.
- **Limited** — treated as valid, not degraded. Scans the accessible subset,
  shows a persistent "Limited Photo Access" banner, and offers Apple's
  `presentLimitedLibraryPicker` flow to widen the selection.
- **Not determined** — explained before being requested, never on launch.

## Testing

```bash
xcodebuild test -scheme RECLAIM -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Verifying the scan against known data

The integration suite asserts against fixtures with deliberately planted
duplicate relationships, so results are pass/fail rather than impressionistic:

```bash
python3 Scripts/make_test_photos.py
xcrun simctl boot "iPhone 16e"
xcrun simctl addmedia booted /tmp/reclaim-fixtures/*.png
xcodebuild test -scheme RECLAIM \
  -destination 'platform=iOS Simulator,name=iPhone 16e' \
  -only-testing:RECLAIMTests
```

Grant photo access once by launching the app and tapping *Allow Full Access* —
a unit test cannot dismiss the system permission dialog, so the suite skips with
an explanatory message until you do.

Ground truth: 3 byte-identical copies must form one group, 2 more must form a
separate group, 4 re-framed shots should cluster via Vision, and 3 unrelated
scenes must not be grouped with anything.

**Unit tests** (`RECLAIMTests`, 89 cases) cover the pure logic:
storage calculations, perceptual fingerprinting and clustering, keep-suggestion
scoring, contact normalisation and duplicate scoring, selection and reclaimable
byte maths, scan-progress arithmetic, outcome reporting.

**UI tests** (`RECLAIMUITests`) cover onboarding, permission states, tab
navigation, selection, and the review gate — including that leaving Review and
cancelling the confirmation both delete nothing. They skip rather than fail when
the device library can't exercise a flow.

### Safety checklist for device testing

| # | Test | Expected |
|---|---|---|
| 1 | Select photos, don't open Review | Nothing deleted |
| 2 | Select, open Review, press Go back | Nothing deleted, selection intact |
| 3 | Select, Review, confirm | Only the selected assets are deleted |
| 4 | Force a partial failure | Reports actual count, lists failures |
| 5 | Limited Photos access | Scans subset, banner shown, no crash |
| 6 | Photos denied | App usable, recovery UI shown |
| 7 | Contacts denied | Photo features fully functional |
| 8–11 | No duplicates / screenshots / videos / contacts | Specific empty state each |
| 12 | 10,000+ photo library | UI stays responsive, results stream in |
| 13 | Cancel the iOS deletion sheet | Reported as cancelled, not as failure |
| 14 | Airplane mode | Full functionality |

## Hard problems and how they were solved

**Video file sizes without private API.** There is no public API returning a
`PHAsset`'s byte size. The common workaround —
`PHAssetResource.value(forKey: "fileSize")` — is KVC against an undocumented
property, i.e. a private API and a rejection risk. Instead RECLAIM requests the
`AVAsset`; when the video is local, Photos vends an `AVURLAsset` whose `url`
answers `URLResourceValues.fileSize` — public, exact, and a stat rather than a
read. Failing that it derives `estimatedDataRate × duration` from the video
track, and failing *that* falls back to a conservative bitrate estimate. Every
non-exact result is labelled as an estimate in the UI.
`isNetworkAccessAllowed` stays false throughout so iCloud videos are never
downloaded just to be weighed.

**O(n²) similarity on a 10,000-photo library.** Comparing every pair is 50
million Vision distance computations. Two constraints fix it: exact-hash
bucketing removes true duplicates in O(n) first, and Vision comparison is then
restricted to a 180-second temporal window with a hard cap of 40 comparisons per
photo. Burst-like sequences are inherently clustered in time, so this loses
almost nothing while making the pass near-linear.

**"Deleted" doesn't mean "freed".** iOS moves deleted photos to Recently Deleted
for 30 days, where they still occupy storage. Measuring free space before and
after a cleanup therefore shows roughly zero change. Rather than quietly
reporting a fabricated number, the app prefers a measured delta when it's
plausible, falls back to a proportional estimate otherwise, labels which one it
used, and tells the user on both the Review and Complete screens that space is
fully freed only once Recently Deleted is emptied.

**Verifying deletion instead of assuming it.** `performChanges` can report
success while leaving assets behind, and its batch semantics make per-item
attribution impossible from the result alone. After the write, `CleanupService`
re-fetches every requested identifier; whatever survives is reported as a
failure with a reason. A user who selected 10 photos and had one fail is told
nine were removed — never ten.

**Continuations resuming twice.** `PHImageManager` invokes its result handler
more than once (degraded placeholder, then final image). A continuation resumed
twice traps. A small lock-guarded latch ensures exactly one resume, and degraded
results are skipped unless they're terminal.

**A generated project file with dangling references.** The `pbxproj` generator's
ID function salted repeat calls for collision-avoidance, which silently made it
non-idempotent — build configurations were emitted with one ID and referenced
with another. Caught by a custom validator that walks the object graph checking
every 24-hex-char string resolves. Now memoised by key.

## Known limitations

Things that are genuinely unfinished or unverified, stated plainly:

- **Similar-photo detection has never successfully run.** In the Simulator,
  `VNGenerateImageFeaturePrintRequest` fails with *"Failed to create espresso
  context"* — the neural-network runtime behind Vision is unavailable there, on
  every architecture, and Apple documents this as expected. The request itself
  is correct (`supportedRevisions` lists both revisions; the default resolves to
  2), but it can only be verified on a physical device. The app now detects this
  and says so rather than implying the library is clean.
- **`SimilarityTuning.featureDistanceThreshold` is still uncalibrated.** Set to
  0.5 for feature-print revision 2. Apple doesn't document the distance scale,
  and because Vision cannot run in the Simulator, **no real distance value has
  ever been observed**. This is the first thing to tune on a device — run
  `ScanIntegrationTests` there and the clustering test will report actual
  distances. It is isolated in one struct so tuning is a one-line change.
- **The deletion path has never executed.** `CleanupService` is written to
  re-verify every removal by re-reading the library, and the Review gate is
  covered by unit tests at the selection level, but no photo or contact has ever
  actually been deleted by this code.
- **Screenshot detection is unverified.** `PHAssetMediaSubtype.photoScreenshot`
  is set by iOS when the OS captures a screenshot; images injected with
  `simctl addmedia` never carry it, so the Simulator cannot exercise this path.
- **Contact duplicate detection is unverified end-to-end.** The matching
  algorithm has thorough unit coverage, but the Simulator address book is empty
  and no real `CNContactStore` fetch has been exercised.
- **Still-image sizes are estimates.** Derived from pixel count at ~0.30
  bytes/pixel (0.20 for screenshots). Deliberately conservative. Reading true
  sizes would mean touching every backing file, which is far too slow mid-scan.
- **Contact merge writes a flattened label set.** Merged phone numbers get
  `mobile` labels and emails get `other`, rather than preserving each original
  label. The data survives; the labelling is lossy.
- **iOS 18 limited-contacts state is treated as denied.** The app targets iOS 17
  where `CNAuthorizationStatus.limited` doesn't exist; treating an unrecognised
  status as usable would be unsafe, so it degrades to the recovery UI.
- **No blurry-photo screen, swipe-to-decide, compression, vault or widget.**
  Bonus features were skipped in favour of core-loop reliability, as the brief
  directs.
- **Not localised.** English only, though Dynamic Type is fully supported.

## Future improvements

1. Calibrate the similarity threshold against a real library and add a
   sensitivity control
2. Persist scan results so relaunching doesn't trigger a full rescan
3. Incremental rescan driven by `PHChange` details instead of a full re-run
4. Preserve original labels through contact merges
5. Blurry-photo detection — the sharpness metric is already computed
6. A swipe-to-keep/delete review mode for large groups
7. Offer to open Recently Deleted directly after a cleanup

## License

Written as an internship selection assignment. Not for redistribution.
