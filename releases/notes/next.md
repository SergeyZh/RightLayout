RightLayout SergeyZh is now signed with a Developer ID, notarized by Apple, and shipped as a DMG.

Install or update:
- Download the `.dmg`, open it, and drag RightLayout SergeyZh to Applications (replace the old copy).
- macOS opens it without the "Open Anyway" step.
- Coming from a `.pkg` build: the old Accessibility entry no longer applies. If the app asks for access again, press "Reset Permission" in its permission window, then grant access once. Later updates keep the permission.

Versions are now the UTC build time (this one is in the release title), so every build has its own, always growing number.

What changed since 1.3:
- Correction sound, a single Accessibility prompt.
- Word frequency lists are loaded, which improves decisions on short and rare words.
- Only enabled keyboard layouts are used; edge punctuation maps to the Russian PC layout («Lf?» → «Да,»).
- Fixed lost spaces in Slack after a correction; a correction pending when Enter is held is applied; Double Shift on a selection reverts the whole previous switch.

Requires macOS 13.0 or later.
