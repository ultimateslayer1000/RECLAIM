# RECLAIM — submission note (process version)

*Alternative to SUBMISSION.md. This one discloses the AI-assisted workflow.*

---

**Process** — I wrote the spec as a detailed brief using ChatGPT, then had Claude
implement it in Swift/SwiftUI. I drove everything around the code: installing
Xcode, code signing, deploying to my iPhone, and testing against my real photo
library.

**Problems** — My Mac is Intel, so Xcode 26.3 was the newest version that runs on
it. Signing and GitHub authentication each took several attempts. The real bug
only appeared on device: the scan froze permanently on my 3,454-photo library.
`PHImageManager` never calls back for some iCloud-optimised assets, and the
continuation wrapping it had no timeout, so a single unresponsive photo stalled
the entire scan. Fixed by racing each request against a timeout and skipping.

**Missing** — Contact merge and delete are implemented but never executed. The
freeze fix isn't yet verified against the full library. No bonus features. Photo
sizes are estimates; iOS doesn't expose per-asset sizes.
