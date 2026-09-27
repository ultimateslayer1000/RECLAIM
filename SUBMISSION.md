# RECLAIM — submission note

*Draft for the "under 150 words" requirement. Word count checked below.*

---

**Tools** — SwiftUI, Xcode 26.3, Photos, Vision, Contacts, AVFoundation. No
third-party dependencies, no network code.

**What works** — Full scan → review → clean loop on device. Duplicates found by
a 64-bit perceptual hash, so re-encoded copies still match; similar photos by
Vision feature prints, compared only within a time window to stay near-linear on
large libraries. Storage dashboard, screenshots, largest-first videos, duplicate
contacts with merge/delete/ignore. 89 tests, including scans asserted against
fixtures with planted duplicates. ~30s on my library.

**What's missing** — No bonus features. Contact merges flatten phone and email
labels. Photo sizes are estimates; iOS doesn't expose per-asset sizes.

**Hardest problem** — Reading video sizes without private API. The usual trick,
`PHAssetResource.value(forKey:"fileSize")`, is undocumented KVC and a rejection
risk. Instead I request the AVAsset: local videos vend an `AVURLAsset` whose URL
answers `URLResourceValues.fileSize` — public and exact — falling back to
bitrate × duration, labelled as estimated.
