Designed for macos. Fork it for compatibility with other operating systems.

This script assumes file paths are standard macos installation file paths.

Supported:

- Cursor GUI
- Visual Studio Code
- Antigravity (the Codex clone one)
- Ghostty
- maybe more, I forget.

Note: OpenCode and Codex theme syncs don't actually work.
Note: This script might require fork for it to work properly if you're missing any of the things it expects to be installed, like Ghostty.

## Multi-device sync over SSH

The resolved theme can be pushed to other machines (macOS or Linux):

```sh
./sync_theme.sh --remote user@host --remote user@other-host
./sync_theme.sh --watch --remote user@host   # watch mode pushes to remotes too
```

How it works: colors are resolved once from local VS Code, then piped over a
single `ssh` connection along with the script itself, which re-runs in
receiver mode on the remote and applies the theme using that machine's
platform-appropriate paths (`~/.config` vs `~/Library/Application Support`).

Requirements on each remote host:

- Key-based SSH auth (the script uses `BatchMode=yes`, so password prompts
  would fail — especially important in `--watch` mode)
- `python3` and `jq` installed

Notes:

- Remotes only apply targets that exist there; anything missing is skipped.
- Theme extensions under 15 MB are bundled with the push so editors without a
  CLI can still get the theme via copy.
- Debugging: `--emit-payload` prints exactly what would be sent to a remote.
