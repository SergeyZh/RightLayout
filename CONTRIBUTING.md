# Contributing to RightLayout

## Development Setup

### Prerequisites

```bash
# Verify Xcode installation
xcodebuild -version

# Verify Swift version
swift --version  # Should be 5.10+
```

### Clone & Build

```bash
git clone <repository-url>
cd rightlayout
swift build
swift test
```

## Code Style

### Swift Style Guide

- Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Use SwiftLint for consistency (optional)
- 4 spaces for indentation
- Max line length: 120 characters

### Naming Conventions

- **Types**: PascalCase (`LanguageDetector`, `CorrectionEngine`)
- **Functions**: camelCase (`detectLanguage`, `correctText`)
- **Constants**: camelCase (`preferredLanguage`, `isEnabled`)
- **Actors**: Suffix with `Actor` if ambiguous

### Concurrency

- Use `actor` for mutable shared state
- Use `@MainActor` for UI-related code
- Avoid `@unchecked Sendable` unless absolutely necessary
- Document thread safety assumptions

## Adding New Features

### Adding a New Language

1. **Update Language enum** (`Core/LanguageDetector.swift`):
```swift
enum Language: String, CaseIterable {
    case russian = "ru"
    case english = "en"
    case hebrew = "he"
    case german = "de"  // New language
}
```

2. **Add character mappings** (`Core/LayoutMapper.swift`):
```swift
private static let deToEn: [Character: Character] = [
    "ä": "a", "ö": "o", "ü": "u", // etc.
]
```

3. **Update language hints** (`Core/LanguageDetector.swift`):
```swift
recognizer.languageHints = [
    .russian: 0.25,
    .english: 0.25,
    .hebrew: 0.25,
    .german: 0.25
]
```

4. **Add tests** (`Tests/LayoutMapperTests.swift`):
```swift
func testGermanToEnglish() {
    let result = LayoutMapper.convert("äöü", from: .german, to: .english)
    XCTAssertEqual(result, "aou")
}
```

### Adding a New UI Feature

1. Create SwiftUI view in `Sources/UI/`
2. Use `@StateObject` for `SettingsManager`
3. Follow existing view patterns
4. Test on macOS Sonoma and Sequoia

### Adding a New Setting

1. **Add property** (`Settings/SettingsManager.swift`):
```swift
@Published var newSetting: Bool {
    didSet { UserDefaults.standard.set(newSetting, forKey: "newSetting") }
}
```

2. **Initialize in init**:
```swift
self.newSetting = UserDefaults.standard.object(forKey: "newSetting") as? Bool ?? false
```

3. **Add UI** (`UI/SettingsView.swift`):
```swift
Toggle("New Setting", isOn: $settings.newSetting)
```

### Changing How Words Are Decided

Settings → Algorithm draws the word check as a diagram, and its test field shows what
every block did with a typed word. The diagram is only right while it follows the code,
so **every change to the algorithm must be checked against it**: whether a word is
corrected, suggested or left alone, and how the correction is put into the text.

That covers, among others, `Core/ConfidenceRouter.swift`, `Core/WordValidator.swift`,
`Core/WordFrequencyModel.swift`, `Core/NgramLanguageModel.swift`, `Core/LayoutMapper.swift`,
`Core/WrongLayoutShorthand.swift`, `Engine/CorrectionEngine*.swift`,
`Engine/CorrectionDecisionPolicy.swift`, `Personalization/RiskController.swift`, the
replacement path of `Engine/EventMonitor.swift`, `Services/SelectionReplacementService.swift`,
`Engine/RuntimeProfiles.swift`, and `Resources/thresholds.json` and `language_data.json`.

When you change one of them, check and update as needed:

1. **The blocks** (`UI/AlgorithmDiagram.swift`): a new step gets a block in its stage, a
   removed one loses it, and the titles, summaries and descriptions say what the code does
   now. Mark a block `decidesAlone` if it can end the check.
2. **Its switch** (`Core/DecisionPipeline.swift`): a new part of the decision gets a
   `DecisionComponent` and is skipped when that is off; a part with a setting of its own
   uses `AlgorithmNode.SettingSwitch`.
3. **Its parameters**: a threshold or margin worth tuning becomes a `DecisionParameter`
   with the value the code had as its default; nothing changes until someone moves it.
4. **The trace** (`Core/DecisionProbe.swift`): the new or changed step reports what it did
   with `DecisionProbe.record`, under its `DecisionStep`. Steps of the replacement are
   walked through in `Engine/DecisionPlayground.swift`, with the same rules as the monitor.
5. **Translations**: every new text of the diagram and every `ProbeNote` in `en`, `ru` and
   `he` `Localizable.strings`, with the same `%@` placeholders.
6. **The description** in `docs/word-check-algorithm.ru.md`.
7. **The tests**: `DecisionPipelineTests` and `DecisionPlaygroundTests` check that every
   component, parameter and step has its block and its translations; add a test that the
   test field reports the change.

Then type a few words into the test field and see that the diagram tells the story the
code does. If a change needs none of this, say why in the pull request's "Algorithm page"
section, on a line starting with "Not needed:".

The "Algorithm page" check (`.github/workflows/algorithm-page.yml`,
`scripts/check_algorithm_page.py`) fails a pull request that changes one of these files
without changing the page or giving that reason; the script's `ALGORITHM` list is the
authoritative list of files.

## Testing

### Running Tests

```bash
# All tests
swift test

# Specific test suite
swift test --filter LanguageDetectorTests

# With coverage
swift test --enable-code-coverage
```

### Writing Tests

```swift
import XCTest
@testable import RightLayout

final class MyTests: XCTestCase {
    func testFeature() async throws {
        // Arrange
        let detector = LanguageDetector()
        
        // Act
        let result = await detector.detect("test")
        
        // Assert
        XCTAssertEqual(result, .english)
    }
}
```

### Test Coverage Goals

- Core logic: >90%
- UI: Manual testing
- Integration: Manual scenarios

## Debugging

### Enable Debug Logging

```bash
# Stream logs in real-time
log stream --predicate 'subsystem == "com.sergeyzh.rightlayout"' --level debug
```

### Xcode Debugging

1. Open `Package.swift` in Xcode
2. Set breakpoints
3. Run with ⌘R
4. Use Instruments for profiling

### Common Issues

**Event tap not working**:
- Check Accessibility permissions
- Verify app is not sandboxed
- Check Console.app for errors

**Language detection inaccurate**:
- Add logging in `LanguageDetector.detect()`
- Test with longer text samples
- Adjust language hints

**High CPU usage**:
- Profile with Instruments
- Check event processing frequency
- Optimize buffer management

## Performance Guidelines

### Latency Requirements

- Event capture: <5ms
- Language detection: <10ms
- Total correction: <50ms

### Memory Guidelines

- Keep history limited (50 records)
- Clear buffers after processing
- Avoid retaining event objects

### Profiling

```bash
# Build for profiling
swift build -c release

# Profile with Instruments
instruments -t "Time Profiler" .build/release/RightLayout
```

## Pull Request Process

1. **Fork** the repository
2. **Create branch**: `git checkout -b feature/my-feature`
3. **Make changes**: Follow code style
4. **Add tests**: Ensure coverage
5. **Run tests**: `swift test`
6. **Commit**: Use descriptive messages
7. **Push**: `git push origin feature/my-feature`
8. **Create PR**: Describe changes clearly

### Release Notes

Release notes are made from the pull requests merged since the last release
(`scripts/release_notes.py`). Say in the PR's "Release notes" section what users get,
in English and Russian, one pair per item:

```
## Release notes

EN: Show when secure input hides typing, and which app holds it.
RU: Показывать, когда защищённый ввод скрывает набор текста и какая программа его держит.
```

`EN: none` or the `skip-release-notes` label leaves a PR out (CI, refactoring); without
the section, the PR title stands in. The header above the changes is in
`releases/notes/header.en.md` and `header.ru.md`.

### PR Checklist

- [ ] Code follows style guide
- [ ] Tests added/updated
- [ ] All tests pass
- [ ] Documentation updated
- [ ] Algorithm changes reflected in Settings → Algorithm (see "Changing How Words Are Decided")
- [ ] No new warnings
- [ ] Performance impact considered

## Code Review Guidelines

### What to Look For

- **Correctness**: Does it work as intended?
- **Performance**: Any latency impact?
- **Security**: Any privacy concerns?
- **Concurrency**: Thread-safe?
- **Tests**: Adequate coverage?

### Review Process

1. Check code style
2. Run tests locally
3. Test manually if UI changes
4. Provide constructive feedback
5. Approve or request changes

## Release Process

### Version Numbering

- Major: Breaking changes (2.0.0)
- Minor: New features (1.1.0)
- Patch: Bug fixes (1.0.1)

### Release Checklist

1. Update version in `Info.plist`
2. Update `CHANGELOG.md`
3. Run full test suite
4. Build release: `swift build -c release`
5. Test on clean macOS install
6. Create git tag: `git tag v1.0.0`
7. Push tag: `git push --tags`

## Documentation

### Code Documentation

```swift
/// Detects the language of the given text.
///
/// Uses NLLanguageRecognizer for text with 3+ words,
/// falls back to character set heuristics for shorter text.
///
/// - Parameter text: The text to analyze
/// - Returns: Detected language or nil if uncertain
func detect(_ text: String) async -> Language?
```

### Architecture Documentation

- Update `ARCHITECTURE.md` for major changes
- Document design decisions
- Explain trade-offs

## Community

### Getting Help

- Open an issue for bugs
- Discussions for questions
- Pull requests for contributions

### Code of Conduct

- Be respectful
- Be constructive
- Be inclusive
- Focus on the code, not the person

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.

Copyright © 2025 Chernistry. All rights reserved.
