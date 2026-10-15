<div align="center">

# RightLayout SergeyZh

**Type freely.**

SergeyZh's build of [RightLayout](https://github.com/chernistry/RightLayout) — fixes your keyboard layout mistakes before you notice them.

[Download for Mac](https://github.com/SergeyZh/RightLayout/releases/latest) · [Original RightLayout](https://github.com/chernistry/RightLayout)

---

*English · Russian · Hebrew*

*macOS 13+ · Free · Open Source*

</div>

---

> **This is a fork.** RightLayout SergeyZh is maintained by [SergeyZh](https://github.com/SergeyZh) and is based on
> [RightLayout](https://github.com/chernistry/RightLayout) by [Alex Chernysh](https://alexchernysh.com).
> It is not the official RightLayout app. Report problems with this build
> [here](https://github.com/SergeyZh/RightLayout/issues), not to the original project.

## Changes in this fork

- Faster, more reliable switching: no Accessibility round trips on every keystroke, so cursor
  movement and scrolling are no longer slowed down; the layout switches right after the decision,
  and keeping on typing no longer cancels the correction.
- Accessibility permission: detected without restarting; "Reset Permission" for stale entries
  left by previous builds.
- Automatic correction in apps that don't expose their text: Electron/Chromium apps (Claude,
  Slack, VS Code…) and terminals (Terminal, iTerm2, Warp…).
- Apps that show their text over Accessibility but ignore edits made through it (Slack and
  other Chromium-based apps): words are retyped, and the result is checked.
- Words with punctuation stuck to them ("Вщту!" → "Done!") are corrected automatically.
- Short words corrected automatically; limits configurable in Settings.
- Manual correction by double-tapping Option or Shift.
- A short, quiet sound on each correction: five sounds to choose from, volume control, can be
  turned off (Settings → General → Sound).
- Enter after a word that needs fixing fixes the word and is held back, so a garbled message is
  not sent in chat apps.
- Working languages: only the languages you use (by default, the layouts enabled in macOS) are
  detected and switched between; fewer false conversions into Hebrew.

Full details are in the git history.

---

## How it works

You type in the wrong keyboard layout and RightLayout corrects it instantly using on-device AI (CoreML).

```
ghbdtn  →  привет
руддщ   →  hello  
akuo    →  שלום
```

No hotkeys. No notifications. Just correct text.

---

## Features

**Works invisibly**  
No popups, no interruptions. Corrections happen as you type.

**AI-powered language detection**  
A CoreML model trained on real multilingual typing data detects wrong-layout text with high accuracy.

**Learns you**  
Undo a correction twice — RightLayout remembers. It adapts to your writing style.

**Stays private**  
Everything runs on your Mac. Nothing leaves your device. Ever.

**Multilingual keyboard support**  
Supports English, Russian, and Hebrew layouts with extensible architecture for adding more languages.

---

## Install

1. Download the `.pkg` from [Releases](https://github.com/SergeyZh/RightLayout/releases/latest)
2. Run the installer
3. Grant Accessibility permission when prompted
4. Done — RightLayout works in the background

---

## Building from source

```bash
git clone https://github.com/SergeyZh/RightLayout.git
cd RightLayout
swift build
swift test
```

Requires macOS 13+, Xcode 15+, Swift 5.9+.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style, and how to add new languages.

---

## Contributing

Issues and pull requests for this build go to [SergeyZh/RightLayout](https://github.com/SergeyZh/RightLayout).
Changes that make sense for everyone are also offered upstream to
[chernistry/RightLayout](https://github.com/chernistry/RightLayout).

---

## Architecture

- `RightLayout/Sources/Engine/` — Core correction engine (language detection, layout mapping, confidence routing)
- `RightLayout/Sources/UI/` — SwiftUI settings and menu bar interface
- `RightLayout/Sources/Settings/` — User preferences and personalization
- `Tools/CoreMLTrainer/` — Python training pipeline for the CoreML language classifier

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on adding features and languages.

---

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). Use of the RightLayout name: [TRADEMARKS.md](TRADEMARKS.md).

---

<div align="center">

RightLayout created by [Alex Chernysh](https://alexchernysh.com) · RightLayout SergeyZh maintained by [SergeyZh](https://github.com/SergeyZh)

</div>
