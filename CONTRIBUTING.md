# Contributing to Oficina

Thanks for helping make Oficina better. Oficina is the home of **Faísca**, an assistant that lives on your Mac. This guide covers how to contribute, where things live in the code and what we look for in a pull request.

## Ways to contribute

- **Report a bug** or **request a feature, Dock widget, outfit or house** with the [issue templates](https://github.com/AlanEdward19/oficina/issues/new/choose). Faísca can open these for you too, through the chat or the **Pedir melhoria…** menu item.
- **Pick up an issue.** Issues labelled [`good first issue`](https://github.com/AlanEdward19/oficina/labels/good%20first%20issue) are small and well scoped; [`help wanted`](https://github.com/AlanEdward19/oficina/labels/help%20wanted) ones are bigger.
- **Add to Faísca's world**: outfit pieces, beds and blankets, or new Dock widgets.
- **Improve the docs.**

For larger changes, please open an issue first so we can agree on the approach before you invest time in it.

Issues labelled [`agente`](https://github.com/AlanEdward19/oficina/labels/agente) are implemented by a Claude agent, which opens a pull request. Only people with write access can apply that label, so a maintainer decides what goes to the agent.

## Development setup

The core is Rust and the app is Swift, with no packages. You need macOS 14 or later, the [Rust toolchain](https://rustup.rs/) and Xcode or the Swift 6 command line tools.

1. Run the core tests: `cd core && cargo test`
2. Run the end-to-end tests: `cd core && cargo build --release && bash tests/e2e.sh`
3. Build the app: `cd app && swift build -c release`
4. Build and open the full app: `bash scripts/build.sh && open build/Oficina.app`

CI runs the first three on every pull request. The end-to-end script uses a fake `claude`, so it spends no tokens. Architecture and decisions are in [docs/ARQUITETURA.md](docs/ARQUITETURA.md).

## Code map

| To change… | Look at |
|---|---|
| Outfits (new pieces) | Vocabulary in `core/src/mind/outfit.rs` (`HEADS`, `FACES`, `NECKS`, `PROPS`); drawing in `app/Sources/Oficina/Pet.swift` (`wear`) |
| Houses (beds, blankets, decorations) | Vocabulary in `core/src/mind/decor.rs` (`BEDS`, `BLANKETS`, `EXTRAS`); drawing in `Pet.swift` (`setDecor`) |
| Dock widgets | `app/Sources/Oficina/Dock.swift`, in `DockView.widgets` |
| Faísca's behaviour and mood | Network and mind in `core/src/mind/` (`net.rs`, `mod.rs`); animations in `Pet.swift` (`PetFigure`) |
| Initiatives (what she suggests) | `core/src/mind/mod.rs`, function `best` |
| Conversation, agents and routing | `core/src/engine.rs` and `core/src/route.rs` |
| Notch and Claude usage | `app/Sources/Oficina/Notch.swift` and `core/src/usage.rs` |
| Chat | `app/Sources/Oficina/Chat.swift` |
| Agents, teams, missions and settings | `core/src/factory.rs` and `app/Sources/Oficina/Factory.swift` |
| Automatic model choice | `core/src/router.rs` |
| Shared screen pieces (pet preview, monogram, models) | `app/Sources/Oficina/Theme.swift` |
| Disk cleaning | `core/src/clean.rs` and `app/Sources/Oficina/Clean.swift` |
| Menu bar panel and tools | `app/Sources/Oficina/Tools.swift` |
| Text in the Mac's language | `app/Sources/Oficina/L10n.swift` |

A new outfit or house piece needs two changes: its name goes in the core vocabulary, so Claude can choose it, and its drawing goes in `Pet.swift`. Pieces outside the vocabulary are ignored, so the app never draws something it doesn't know.

## Branches and pull requests

1. Fork the repo and create a branch from `main`: `feat/…`, `fix/…`, `docs/…`, `chore/…`.
2. Don't push to `main` directly; changes land through pull requests.
3. Keep the change focused. Unrelated refactors make reviews slow.
4. Add or update tests for behaviour you change.
5. Run the same checks as CI before you push.
6. Describe how to verify the change in the app and link the issue (`Closes #123`).

### Code style

- Match the style of the surrounding code.
- Write interface text in Brazilian Portuguese, short and direct.
- Screens use standard macOS components: regular windows, sidebars, `Form`, toolbars and system alerts. No gradients, colored cards or rounded fonts.
- Continuous animation goes to Core Animation, never to per-frame timers in the app.
- Keep dependencies to a minimum; discuss new ones in the issue first.
- Never commit secrets, API keys or real user data. Test fixtures must be synthetic.

### Project rules

- Anything that spends the user's tokens asks for permission first.
- Faísca doesn't read screen content or window titles, only app names and usage time.
- Disk cleaning tests need their own `HOME`. Never run cleaning against a real home folder.

### Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`. Write the subject in the imperative ("add", not "added").

## Reporting security issues

Please don't open public issues for vulnerabilities. Use GitHub's [private vulnerability reporting](https://github.com/AlanEdward19/oficina/security/advisories/new).

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
