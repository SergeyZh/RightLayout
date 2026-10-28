# RightLayout

See `CONTRIBUTING.md` for building, testing and conventions. CI builds and tests on macOS
(`.github/workflows/ci.yml`); there is no Swift toolchain for this app on Linux.

## Keep the Algorithm page in step with the code

Settings → Algorithm (`Sources/UI/AlgorithmSettingsView.swift`) draws how a typed word is
decided and replaced, with a switch and parameters for every part and a test field that
traces a word through it. Whenever you change the algorithm — how a word is decided,
suggested or left alone, or how a correction is put into the text — check whether the
diagram needs to change too, and update it in the same change. Follow "Changing How Words
Are Decided" in `CONTRIBUTING.md`: blocks, switches (`DecisionComponent`), parameters
(`DecisionParameter`), the trace (`DecisionProbe`, `DecisionPlayground`), translations in
`en`/`ru`/`he`, `docs/word-check-algorithm.ru.md` and the tests. If nothing needs to change,
say so and why when you report the change.
