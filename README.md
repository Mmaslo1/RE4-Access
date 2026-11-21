# RE4 Access

A blind accessibility mod for **Resident Evil 4 (2023 remake)**, Steam PC version.
Made by a totally blind player, built with Claude Code.

## How to install (the easy way)
1. Download the installer: [RE4Access_Setup_0.28.0.exe](https://github.com/Mmaslo1/RE4-Access/releases/latest/download/RE4Access_Setup_0.28.0.exe).
   If your browser asks whether to keep the file, choose Keep.
2. Close the game if it is running. Press Enter on the downloaded file.
3. If Windows says "Windows protected your PC": press Tab to "More info", Enter, then Tab to "Run anyway", Enter.
   (This appears because the file is not from a big company.)
4. Windows asks for permission: choose Yes.
5. The installer finds Resident Evil 4 by itself. Press Enter on Next, Install, then Finish.
6. Start the game from Steam with your screen reader running. You should hear "RE4 Access loaded".
7. First time only: in the game, Options, Controls, Key Bindings: set "Ready Weapon / Aim" to L and "Attack / Fire" to K.

To remove the mod: Windows Settings, Apps, Installed apps, "RE4 Access", Uninstall.

Prefer copying files by hand? Download [RE4Access_Share_0.28.0.zip](https://github.com/Mmaslo1/RE4-Access/releases/latest/download/RE4Access_Share_0.28.0.zip)
and follow the file "01 START HERE - HOW TO INSTALL.txt" inside it.
All downloads: the [Releases page](https://github.com/Mmaslo1/RE4-Access/releases).

- Speaks through your screen reader (NVDA, JAWS, Narrator and others) using [Prism](https://github.com/ethindp/prism). With no screen reader it uses the Windows voice.
- Reads menus, shops, the case, files and cutscenes.
- Guides you to objectives (N), items and places, with aim lock and danger warnings.
- Puzzle and boss guides are spoken in the game.

Runs on [REFramework](https://github.com/praydog/REFramework) (Lua scripts in `lua/`, speech plugin in `plugin/`).

## Files
- `lua/` - the mod scripts (copy into the game's `reframework/autorun` folder)
- `plugin/` - speech plugin source (`REAccessSpeech.cpp`, `build.bat`) and Prism 0.18.2 (`plugin/prism/`: `prism.dll`, headers, MPL-2.0 licence)
- `README_KEYS_AND_HELP.txt` - all keys
- `INSTALL_TEMPLATE.txt` - how to install by hand
- `installer/` - Inno Setup script for the one-click installer (`RE4Access_Setup.iss`)
- `*_GUIDE.txt` - chapter and boss guides

## Want to help?
Thank you! Please send changes as a **pull request** and say what it fixes and how you tested it.
The player makes the final call on every change, so explain it in plain words.
Never add mouse-only or look-at-the-screen steps: everything must work by keyboard and speech.
