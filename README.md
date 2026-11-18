# RE4 Access

A blind accessibility mod for **Resident Evil 4 (2023 remake)**, Steam PC version.
Made by a totally blind player, built with Claude Code.

- Speaks through your screen reader (NVDA, JAWS, Narrator and others) using [Prism](https://github.com/ethindp/prism). With no screen reader it uses the Windows voice.
- Reads menus, shops, the case, files and cutscenes.
- Guides you to objectives (N), items and places, with aim lock and danger warnings.
- Puzzle and boss guides are spoken in the game.

Runs on [REFramework](https://github.com/praydog/REFramework) (Lua scripts in `lua/`, speech plugin in `plugin/`).

## Files
- `lua/` - the mod scripts (copy into the game's `reframework/autorun` folder)
- `plugin/` - speech plugin source (`REAccessSpeech.cpp`, `build.bat`) and Prism 0.18.2 (`plugin/prism/`: `prism.dll`, headers, MPL-2.0 licence)
- `README_KEYS_AND_HELP.txt` - all keys
- `INSTALL_TEMPLATE.txt` - how to install
- `*_GUIDE.txt` - chapter and boss guides

## Want to help?
Thank you! Please send changes as a **pull request** and say what it fixes and how you tested it.
The player makes the final call on every change, so explain it in plain words.
Never add mouse-only or look-at-the-screen steps: everything must work by keyboard and speech.
