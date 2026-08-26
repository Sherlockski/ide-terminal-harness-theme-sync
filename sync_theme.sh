#!/bin/bash

SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF_PATH")"

# ── Platform detection ─────────────────────────────────────────────────────
# SYNC_OS overrides the detected OS. This exists so the remote receiver
# (--apply-remote) can be tested on a machine of the other platform, e.g.:
#   HOME=/tmp/fakehome SYNC_OS=Linux bash payload.sh --apply-remote
REMOTE_OS="${SYNC_OS:-$(uname -s)}"
case "$REMOTE_OS" in
    Darwin)
        IS_MACOS=1
        APP_SUPPORT_DIR="$HOME/Library/Application Support"
        ;;
    *)
        IS_MACOS=0
        APP_SUPPORT_DIR="$HOME/.config"
        ;;
esac

# Portable in-place edit — BSD and GNU sed disagree about `-i`
sed_inplace() {
    local script="$1" file="$2"
    [ -f "$file" ] || return 0
    sed "$script" "$file" > "$file.st-tmp.$$" && mv -f "$file.st-tmp.$$" "$file"
}

GHOSTTY_CONFIG="$HOME/.config/ghostty/config"

VSCODE_SETTINGS="$APP_SUPPORT_DIR/Code/User/settings.json"

# Fork editors that share the VS Code marketplace
# Each entry: "name|settings_path|extensions_dir|cli_binary"
if [ "$IS_MACOS" = 1 ]; then
    FORKS=(
        "Antigravity|$APP_SUPPORT_DIR/Antigravity/User/settings.json||"
        "Antigravity IDE|$APP_SUPPORT_DIR/Antigravity IDE/User/settings.json|$HOME/.antigravity-ide/extensions|/Applications/Antigravity IDE.app/Contents/Resources/app/bin/antigravity-ide"
        "Cursor|$APP_SUPPORT_DIR/Cursor/User/settings.json|$HOME/.cursor/extensions|cursor"
        "OpenCode|$APP_SUPPORT_DIR/OpenCode/User/settings.json|$HOME/.opencode/extensions|"
    )
else
    FORKS=(
        "Antigravity|$APP_SUPPORT_DIR/Antigravity/User/settings.json||"
        "Antigravity IDE|$APP_SUPPORT_DIR/Antigravity IDE/User/settings.json|$HOME/.antigravity-ide/extensions|antigravity-ide"
        "Cursor|$APP_SUPPORT_DIR/Cursor/User/settings.json|$HOME/.cursor/extensions|cursor"
        "OpenCode|$APP_SUPPORT_DIR/OpenCode/User/settings.json|$HOME/.opencode/extensions|"
    )
fi

# Extension directories to search for theme files
EXTENSION_DIRS=(
    "$HOME/.vscode/extensions"
    "$HOME/.vscode-insiders/extensions"
    "$HOME/.vscode-oss/extensions"
    "$HOME/.vscode-server/extensions"
    "$HOME/.cursor/extensions"
    "$HOME/.antigravity/extensions"
    "$HOME/.codex/extensions"
    "$HOME/.opencode/extensions"
)
if [ "$IS_MACOS" = 1 ]; then
    # VS Code built-in themes (Quiet Light, Default Dark Modern, etc.)
    EXTENSION_DIRS+=(
        "/Applications/Visual Studio Code.app/Contents/Resources/app/extensions"
        "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/extensions"
    )
else
    EXTENSION_DIRS+=(
        "/usr/share/code/resources/app/extensions"
        "/usr/share/code-insiders/resources/app/extensions"
    )
fi

# ── Helpers ────────────────────────────────────────────────────────────────
strip_alpha() { sed 's/^\(#[0-9a-fA-F]\{6\}\).*/\1/'; }

# Returns WCAG contrast ratio (e.g. "4.50") between two hex colours.
check_contrast() {
    python3 -c "
fg = '$1'
bg = '$2'
def rel_lum(h):
    h = h.lstrip('#')
    r, g, b = int(h[0:2], 16)/255, int(h[2:4], 16)/255, int(h[4:6], 16)/255
    def lin(c):
        return c/12.92 if c <= 0.04045 else ((c+0.055)/1.055)**2.4
    return 0.2126*lin(r) + 0.7152*lin(g) + 0.0722*lin(b)
l1, l2 = rel_lum(fg), rel_lum(bg)
if l1 < l2: l1, l2 = l2, l1
print(f'{(l1+0.05)/(l2+0.05):.2f}')
" 2>/dev/null
}

_clean_json() {
    python3 -c "
import sys, re

t = sys.stdin.read()

# 1. Remove // comments (full-line and inline) outside quoted strings
result = []
for line in t.split('\n'):
    in_string = False
    escape = False
    for i, ch in enumerate(line):
        if escape:
            escape = False
            continue
        if ch == '\\\\':
            escape = True
            continue
        if ch == '\"':
            in_string = not in_string
            continue
        if ch == '/' and i + 1 < len(line) and line[i + 1] == '/' and not in_string:
            line = line[:i]
            break
    result.append(line)
t = '\n'.join(result)

# 2. Remove trailing commas before ] or }
t = re.sub(r',\s*([\]}])', r'\1', t)

# 3. Remove trailing commas after } before ] or }  (e.g.  },\n    ]  ->  }\n    ])
t = re.sub(r'}\s*,\s*([\]}])', r'}\n\1', t)
# Also handle ] before ]  (e.g.  ],\n    ]  ->  ]\n    ])
t = re.sub(r'\]\s*,\s*\]', r']]', t)

sys.stdout.write(t)
" 2>/dev/null
}

ensure_dependencies() {
    local missing=()
    local cmd pkg

    for cmd in python3 jq bc; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi

    echo "Missing required dependencies: ${missing[*]}"

    if command -v brew >/dev/null 2>&1; then
        echo "Attempting to install them with Homebrew..."
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                python3) pkg="python@3" ;;
                jq) pkg="jq" ;;
                bc) pkg="bc" ;;
                *) pkg="$cmd" ;;
            esac

            if ! brew install "$pkg"; then
                echo "Failed to install $pkg. Please install it manually and rerun the script."
                exit 1
            fi
        done

        echo "Dependencies installed successfully."
        return 0
    fi

    echo "Homebrew is not available. Please install the missing dependencies manually and rerun the script."
    exit 1
}

# ── Resolved theme globals ─────────────────────────────────────────────────
# resolve_theme() fills these in; apply_targets() consumes them. In
# --apply-remote (receiver) mode they come from the SSH payload instead.
#
#   ACTIVE_THEME               theme label, e.g. "Default Dark Modern"
#   THEME_MODE                 THEME_MODE_DARK | THEME_MODE_LIGHT
#   BG FG CURSOR               core colours (#rrggbb)
#   SELECTION_BG SELECTION_FG LINE_HIGHLIGHT FIND_MATCH_BG FIND_MATCH_FG
#   ANSI_*                     16 terminal palette colours
#   ACCENT                     single accent colour
#   COLORS                     compact JSON of the theme's .colors map
#   EXTENSION_ID EXTENSION_DIR marketplace id + source dir of theme extension
VSCODE_AUTO_DETECT=""
VSCODE_PREFERRED_LIGHT=""
VSCODE_PREFERRED_DARK=""

# Assigned dynamically in resolve_theme()/load_payload_vars()
ANSI_Black="" ANSI_Red="" ANSI_Green="" ANSI_Yellow=""
ANSI_Blue="" ANSI_Magenta="" ANSI_Cyan="" ANSI_White=""
ANSI_BrightBlack="" ANSI_BrightRed="" ANSI_BrightGreen="" ANSI_BrightYellow=""
ANSI_BrightBlue="" ANSI_BrightMagenta="" ANSI_BrightCyan="" ANSI_BrightWhite=""

resolve_theme() {

    # ── 1. Detect active theme and theme preferences from VS Code ────────────
    VSCODE_AUTO_DETECT=$(grep -oE '"window\.autoDetectColorScheme"[[:space:]]*:[[:space:]]*true' "$VSCODE_SETTINGS" | head -1)
    VSCODE_PREFERRED_LIGHT=$(grep -oE '"workbench\.preferredLightColorTheme"[[:space:]]*:[[:space:]]*"[^"]*"' "$VSCODE_SETTINGS" | head -1 | cut -d'"' -f4 | tr -d '\r')
    VSCODE_PREFERRED_DARK=$(grep -oE '"workbench\.preferredDarkColorTheme"[[:space:]]*:[[:space:]]*"[^"]*"' "$VSCODE_SETTINGS" | head -1 | cut -d'"' -f4 | tr -d '\r')
    VSCODE_COLOR_THEME=$(grep -oE '"workbench\.colorTheme"[[:space:]]*:[[:space:]]*"[^"]*"' "$VSCODE_SETTINGS" | head -1 | cut -d'"' -f4 | tr -d '\r')

    DETECTED_THEME=""
    MACOS_MODE=""
    if [ "$IS_MACOS" = 1 ]; then
        MACOS_MODE=$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo "Light")
    fi

    if [ -n "$VSCODE_AUTO_DETECT" ] && [ -n "$MACOS_MODE" ]; then
        if [ "$MACOS_MODE" = "Dark" ]; then
            DETECTED_THEME="$VSCODE_PREFERRED_DARK"
        else
            DETECTED_THEME="$VSCODE_PREFERRED_LIGHT"
        fi
        echo "macOS appearance: $MACOS_MODE → preferred theme: [$DETECTED_THEME]"
    fi

    if [ -z "$DETECTED_THEME" ]; then
        DETECTED_THEME="$VSCODE_COLOR_THEME"
    fi

    ACTIVE_THEME="${DETECTED_THEME:-Default Dark Modern}"

    SOURCE_SETTINGS="$VSCODE_SETTINGS"

    # ── 2. Locate the theme JSON file ──────────────────────────────────────────
    FOUND_FILE=""
    for ext_dir in "${EXTENSION_DIRS[@]}"; do
        [ -d "$ext_dir" ] || continue
        for pkg in "$ext_dir"/*/package.json; do
            [ -f "$pkg" ] || continue
            REL_PATH=$(jq -r --arg label "$ACTIVE_THEME" '
                .contributes.themes[]? | select(.label == $label or .id == $label) | .path
            ' "$pkg" 2>/dev/null)
            if [ -n "$REL_PATH" ] && [ "$REL_PATH" != "null" ]; then
                REL_PATH="${REL_PATH#./}"
                FOUND_FILE="$(dirname "$pkg")/$REL_PATH"
                break 2
            fi
        done
    done

    # Fallback: scan local theme files by "name"
    if [ -z "$FOUND_FILE" ]; then
        search_dirs=(
            "$HOME/.config/Code/User"
            "$HOME/.config/Antigravity/User"
            "$HOME/.config/Cursor/User"
            "$HOME/.config/Codex/User"
            "$HOME/.config/OpenCode/User"
            "$HOME/.vscode"
            "$HOME/.vscode-insiders"
        )
        for dir in "${search_dirs[@]}"; do
            for file in "$dir"/*.json "$dir"/themes/*.json "$dir"/colors/*.json; do
                [ -f "$file" ] || continue
                if _clean_json < "$file" | jq -e --arg label "$ACTIVE_THEME" '.name == $label' &>/dev/null; then
                    FOUND_FILE="$file"
                    break 2
                fi
            done
        done
    fi

    # ── 3. Extract colours ─────────────────────────────────────────────────
    if [ -z "$FOUND_FILE" ]; then
        echo "Could not find theme file for [$ACTIVE_THEME]; using fallback colours."
        BG="#1e1e1e"; FG="#cccccc"; CURSOR="#cccccc"
        SELECTION_BG="#264f78"; SELECTION_FG=""; LINE_HIGHLIGHT=""
        FIND_MATCH_BG=""; FIND_MATCH_FG=""
        COLORS="{}"
    else
        echo "Source theme: $FOUND_FILE"
        COLORS=$(_clean_json < "$FOUND_FILE" | jq -c '.colors // {}' 2>/dev/null)

        BG=$(echo "$COLORS" | jq -r '.["editor.background"] // .["background"] // empty' | strip_alpha)
        FG=$(echo "$COLORS" | jq -r '.["terminal.foreground"] // .["editor.foreground"] // .["foreground"] // empty' | strip_alpha)
        CURSOR=$(echo "$COLORS" | jq -r '.["editorCursor.foreground"] // empty' | strip_alpha)
        SELECTION_BG=$(echo "$COLORS" | jq -r '.["editor.selectionBackground"] // empty' | strip_alpha)
        SELECTION_FG=$(echo "$COLORS" | jq -r '.["editor.selectionForeground"] // empty' | strip_alpha)
        LINE_HIGHLIGHT=$(echo "$COLORS" | jq -r '.["editor.lineHighlightBackground"] // empty' | strip_alpha)
        FIND_MATCH_BG=$(echo "$COLORS" | jq -r '.["editor.findMatchHighlightBackground"] // empty' | strip_alpha)
        FIND_MATCH_FG=$(echo "$COLORS" | jq -r '.["editor.findMatchHighlightForeground"] // empty' | strip_alpha)

        for name in Black Red Green Yellow Blue Magenta Cyan White \
                    BrightBlack BrightRed BrightGreen BrightYellow \
                    BrightBlue BrightMagenta BrightCyan BrightWhite; do
            key="terminal.ansi${name}"
            val=$(echo "$COLORS" | jq -r --arg k "$key" '.[$k] // empty' | strip_alpha)
            # NOTE: printf -v assigns globally; plain `declare` here would
            # create a variable local to resolve_theme()
            printf -v "ANSI_${name}" '%s' "$val"
        done
    fi

    # Diagnostic output
    echo "  background          = $BG"
    echo "  foreground          = $FG"
    echo "  chrome surface     = $(echo "$COLORS" | jq -r '.["titleBar.activeBackground"] // .["sideBar.background"] // .["activityBar.background"] // "N/A"' 2>/dev/null | strip_alpha)"
    echo "  chrome ink         = $(echo "$COLORS" | jq -r '.["titleBar.activeForeground"] // .["sideBar.foreground"] // .["activityBar.foreground"] // "N/A"' 2>/dev/null | strip_alpha)"

    # ── 4. Apply workbench.colorCustomizations overrides from source ───────
    if [ -n "$SOURCE_SETTINGS" ]; then
        OVERRIDES=$(_clean_json < "$SOURCE_SETTINGS" | jq -r '.["workbench.colorCustomizations"] // empty' 2>/dev/null)
        if [ -n "$OVERRIDES" ] && [ "$OVERRIDES" != "null" ]; then
            echo "Applying workbench.colorCustomizations overrides …"
            # Map override keys → the variable names used by the script
            bg_val=$(echo "$OVERRIDES" | jq -r '.["editor.background"] // empty' | strip_alpha)
            fg_val=$(echo "$OVERRIDES" | jq -r '.["terminal.foreground"] // .["editor.foreground"] // empty' | strip_alpha)
            cursor_val=$(echo "$OVERRIDES" | jq -r '.["editorCursor.foreground"] // empty' | strip_alpha)
            sel_bg_val=$(echo "$OVERRIDES" | jq -r '.["editor.selectionBackground"] // empty' | strip_alpha)
            sel_fg_val=$(echo "$OVERRIDES" | jq -r '.["editor.selectionForeground"] // empty' | strip_alpha)
            lh_val=$(echo "$OVERRIDES" | jq -r '.["editor.lineHighlightBackground"] // empty' | strip_alpha)
            fmbg_val=$(echo "$OVERRIDES" | jq -r '.["editor.findMatchHighlightBackground"] // empty' | strip_alpha)
            fmfg_val=$(echo "$OVERRIDES" | jq -r '.["editor.findMatchHighlightForeground"] // empty' | strip_alpha)
            [ -n "$bg_val" ]   && BG="$bg_val"
            [ -n "$fg_val" ]   && FG="$fg_val"
            [ -n "$cursor_val" ] && CURSOR="$cursor_val"
            [ -n "$sel_bg_val" ] && SELECTION_BG="$sel_bg_val"
            [ -n "$sel_fg_val" ] && SELECTION_FG="$sel_fg_val"
            [ -n "$lh_val" ]    && LINE_HIGHLIGHT="$lh_val"
            [ -n "$fmbg_val" ]  && FIND_MATCH_BG="$fmbg_val"
            [ -n "$fmfg_val" ]  && FIND_MATCH_FG="$fmfg_val"
        fi
    fi

    # ── 5. Safe defaults ─────────────────────────────────────────────────────
    [ -z "$BG" ]             && BG="#1e1e1e"
    [ -z "$FG" ]             && FG="#cccccc"
    [ -z "$CURSOR" ]         && CURSOR="$FG"
    [ -z "$SELECTION_BG" ]   && SELECTION_BG="#264f78"
    [ -z "$SELECTION_FG" ]   && SELECTION_FG=""
    [ -z "$LINE_HIGHLIGHT" ] && LINE_HIGHLIGHT=""

    # ── 6. Contrast check: ensure foreground is readable against background ──
    CURRENT_CONTRAST=$(check_contrast "$FG" "$BG")
    MIN_CONTRAST="4.5"
    if [ -n "$CURRENT_CONTRAST" ] && [ "$(echo "$CURRENT_CONTRAST < $MIN_CONTRAST" | bc 2>/dev/null)" = "1" ] 2>/dev/null; then
        echo "  Warning: foreground $FG has insufficient contrast ($CURRENT_CONTRAST:1) against background $BG"
        # Try ANSI white (index 7) — often matches the intended terminal foreground
        if [ -n "${ANSI_White:-}" ]; then
            ALT_CONTRAST=$(check_contrast "$ANSI_White" "$BG")
            if [ -n "$ALT_CONTRAST" ] && [ "$(echo "$ALT_CONTRAST >= $MIN_CONTRAST" | bc 2>/dev/null)" = "1" ] 2>/dev/null; then
                echo "  Using terminal.ansiWhite ($ANSI_White) instead (contrast $ALT_CONTRAST:1)"
                FG="$ANSI_White"
                CURRENT_CONTRAST="$ALT_CONTRAST"
            fi
        fi
        # If still insufficient, compute black or white (whichever contrasts better)
        if [ -n "$CURRENT_CONTRAST" ] && [ "$(echo "$CURRENT_CONTRAST < $MIN_CONTRAST" | bc 2>/dev/null)" = "1" ] 2>/dev/null; then
            WHITE_CONTRAST=$(check_contrast "#ffffff" "$BG")
            BLACK_CONTRAST=$(check_contrast "#000000" "$BG")
            if [ -n "$WHITE_CONTRAST" ] && [ -n "$BLACK_CONTRAST" ]; then
                if [ "$(echo "$WHITE_CONTRAST > $BLACK_CONTRAST" | bc 2>/dev/null)" = "1" ] 2>/dev/null; then
                    FG="#ffffff"
                    CURRENT_CONTRAST="$WHITE_CONTRAST"
                else
                    FG="#000000"
                    CURRENT_CONTRAST="$BLACK_CONTRAST"
                fi
                echo "  Using $FG instead (contrast $CURRENT_CONTRAST:1)"
            fi
        fi
    fi

    # ── 6b. Locate the theme extension (id + dir) for fork installs ────────
    EXTENSION_ID=""
    EXTENSION_DIR=""
    if [ -n "$FOUND_FILE" ]; then
        # Walk up to the extension root (contains package.json)
        PKG_DIR="$(dirname "$FOUND_FILE")"
        while [ "$PKG_DIR" != "/" ] && [ ! -f "$PKG_DIR/package.json" ]; do
            PKG_DIR="$(dirname "$PKG_DIR")"
        done
        if [ -f "$PKG_DIR/package.json" ]; then
            EXTENSION_DIR="$PKG_DIR"
            EXTENSION_ID=$(jq -r '(.publisher // "") + "." + (.name // "")' "$PKG_DIR/package.json" 2>/dev/null)
            [ "$EXTENSION_ID" = "." ] && EXTENSION_ID=""
        fi
    fi

    # ── 6c. Accent colour (OpenCode Desktop + Gemini seeds) ────────────────
    ACCENT=""
    for key in charts.orange editorBracketHighlight.foreground2 tab.activeBorder activityBarBadge.background textLink.foreground focusBorder button.background; do
        ACCENT=$(echo "$COLORS" | jq -r --arg k "$key" '.[$k] // empty' | strip_alpha)
        [ -n "$ACCENT" ] && break
    done
    [ -z "$ACCENT" ] && ACCENT="#007acc"

    # ── 6d. Theme mode ────────────────────────────────────────────────────────
    # On macOS this follows the system appearance (source of truth). Elsewhere
    # there is no reliable equivalent across DEs, so infer from the background.
    if [ "$IS_MACOS" = 1 ]; then
        if [ "$MACOS_MODE" = "Dark" ]; then THEME_MODE="THEME_MODE_DARK"; else THEME_MODE="THEME_MODE_LIGHT"; fi
    else
        if [ "$(python3 -c "
bg = '$BG'.lstrip('#')
r, g, b = int(bg[0:2],16), int(bg[2:4],16), int(bg[4:6],16)
lum = r*0.299 + g*0.587 + b*0.114
print('dark' if lum < 128 else 'light')
" 2>/dev/null)" = "dark" ]; then
            THEME_MODE="THEME_MODE_DARK"
        else
            THEME_MODE="THEME_MODE_LIGHT"
        fi
    fi
}

reload_ghostty() {
    echo "  Ghostty theme → $ACTIVE_THEME (background $BG)"
    local GHOSTTY_PID=""
    if command -v pgrep &>/dev/null; then
        GHOSTTY_PID=$(pgrep -x ghostty 2>/dev/null || true)
    fi
    if [ -z "$GHOSTTY_PID" ] && command -v pgrep &>/dev/null; then
        GHOSTTY_PID=$(pgrep -i ghostty 2>/dev/null | head -1 || true)
    fi
    if [ -z "$GHOSTTY_PID" ]; then
        GHOSTTY_PID=$(ps aux | grep -i '[g]hostty' | awk '{print $2}' | head -1)
    fi
    if [ -n "$GHOSTTY_PID" ]; then
        kill -USR2 "$GHOSTTY_PID" 2>/dev/null && echo "  Ghostty config reloaded (SIGUSR2)" || echo "  [debug] kill failed on PID $GHOSTTY_PID"
    else
        echo "  [debug] could not find Ghostty process"
    fi
}

install_via_cli() {
    local CLI="$1" ID="$2"
    echo "  Installing $ID via $CLI …"
    "$CLI" --install-extension "$ID" --force 2>/dev/null
    return 0
}

install_via_copy() {
    local EXT_DIR="$1" SRC="$2"
    mkdir -p "$EXT_DIR"
    local FOLDER
    FOLDER=$(basename "$SRC")
    if [ ! -d "$EXT_DIR/$FOLDER" ]; then
        echo "  Copying $(basename "$SRC") → $EXT_DIR"
        cp -R "$SRC" "$EXT_DIR/$FOLDER"
    fi
}

ensure_settings() {
    local SETTINGS="$1"
    mkdir -p "$(dirname "$SETTINGS")"
    if [ ! -f "$SETTINGS" ]; then
        echo '{}' > "$SETTINGS"
    fi
}

set_theme_name() {
    local SETTINGS="$1"
    TMP=$(mktemp)
    JQ_SCRIPT='del(.["workbench.colorCustomizations"])'
    JQ_SCRIPT+=' | .["workbench.colorTheme"] = "'"$ACTIVE_THEME"'"'
    if [ -n "$VSCODE_AUTO_DETECT" ]; then
        JQ_SCRIPT+=' | .["window.autoDetectColorScheme"] = true'
        [ -n "$VSCODE_PREFERRED_LIGHT" ] && JQ_SCRIPT+=' | .["workbench.preferredLightColorTheme"] = "'"$VSCODE_PREFERRED_LIGHT"'"'
        [ -n "$VSCODE_PREFERRED_DARK" ]  && JQ_SCRIPT+=' | .["workbench.preferredDarkColorTheme"] = "'"$VSCODE_PREFERRED_DARK"'"'
    else
        JQ_SCRIPT+=' | del(.["window.autoDetectColorScheme"])'
        JQ_SCRIPT+=' | del(.["workbench.preferredLightColorTheme"])'
        JQ_SCRIPT+=' | del(.["workbench.preferredDarkColorTheme"])'
    fi
    _clean_json < "$SETTINGS" | jq "$JQ_SCRIPT" > "$TMP" 2>/dev/null && mv "$TMP" "$SETTINGS" || rm -f "$TMP"
}

apply_targets() {

    # OPENCODE_PY points at opencode_theme.py — bundled on this machine,
    # staged to a temp file when running as the SSH receiver.
    : "${OPENCODE_PY:=$SCRIPT_DIR/opencode_theme.py}"

    # ── 7. Write Ghostty config ──────────────────────────────────────────────
    # Remove old inline sync block, stale config-file directive, and theme lines
    sed_inplace '/^[[:space:]]*# BEGIN SYNC_THEME/,/^[[:space:]]*# END SYNC_THEME/d' "$GHOSTTY_CONFIG"
    sed_inplace '/^[[:space:]]*config-file[[:space:]]*=.*sync-theme/d' "$GHOSTTY_CONFIG"
    sed_inplace '/^[[:space:]]*theme[[:space:]]*=/d' "$GHOSTTY_CONFIG"
    # Clean up any old separate theme file
    rm -f "$HOME/.config/ghostty/themes/sync-theme"

    if [ "$IS_MACOS" = 1 ]; then
        # The macOS-specific config file is loaded AFTER the XDG config and
        # overrides it. Delete it so our XDG config takes full effect.
        rm -f "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
    fi

    # Write colors inline in the main config (no separate theme file needed)
    {
        echo ""
        echo "# BEGIN SYNC_THEME"
        echo "background = $BG"
        echo "foreground = $FG"
        [ -n "$SELECTION_FG" ] && echo "selection-foreground = $SELECTION_FG"
        echo "selection-background = $SELECTION_BG"
        for pair in \
            "0=$ANSI_Black" "1=$ANSI_Red" "2=$ANSI_Green" "3=$ANSI_Yellow" \
            "4=$ANSI_Blue" "5=$ANSI_Magenta" "6=$ANSI_Cyan" "7=$ANSI_White" \
            "8=$ANSI_BrightBlack" "9=$ANSI_BrightRed" "10=$ANSI_BrightGreen" \
            "11=$ANSI_BrightYellow" "12=$ANSI_BrightBlue" "13=$ANSI_BrightMagenta" \
            "14=$ANSI_BrightCyan" "15=$ANSI_BrightWhite"; do
            idx=${pair%%=*}
            val=${pair#*=}
            [ -n "$val" ] && echo "palette = $idx=$val"
        done
        echo "# END SYNC_THEME"
    } >> "$GHOSTTY_CONFIG"

    reload_ghostty

    # ── 8. Install theme extension + sync to fork editors ───────────────────
    # Forks share the VS Code marketplace, so install the extension and set the
    # theme name rather than extracting colours as colorCustomizations.
    for fork in "${FORKS[@]}"; do
        IFS='|' read -r NAME SETTINGS EXT_DIR CLI <<< "$fork"

        # Ensure the settings file and extensions dir exist
        ensure_settings "$SETTINGS"
        [ -n "$EXT_DIR" ] && mkdir -p "$EXT_DIR"

        if [ -n "$EXTENSION_ID" ]; then
            INSTALLED=false
            # Prefer CLI (it handles platform detection, marketplace, etc.)
            if [ -n "$CLI" ] && command -v "$CLI" &>/dev/null; then
                install_via_cli "$CLI" "$EXTENSION_ID" && INSTALLED=true
            fi
            # Fallback: copy the extension directory from VS Code
            if [ "$INSTALLED" = false ] && [ -n "$EXTENSION_DIR" ] && [ -n "$EXT_DIR" ]; then
                install_via_copy "$EXT_DIR" "$EXTENSION_DIR"
            fi
        fi

        if [ "$NAME" = "OpenCode" ]; then
            # OpenCode Desktop reads both settings.json AND LevelDB (below).
            # Set workbench.colorTheme for the native theme engine, then
            # overlay custom CSS via LevelDB for colour-precise accent control.
            set_theme_name "$SETTINGS"
            echo "Synced theme name to OpenCode (workbench.colorTheme + LevelDB overlay)"
        else
            # Other forks (VS Code, Cursor, etc.) use settings.json theme
            set_theme_name "$SETTINGS"
            echo "Synced theme name to $SETTINGS"
        fi
    done

    # ── 9. OpenCode Desktop LevelDB (colour-precise CSS injection) ─────────
    # The Desktop app's oc-theme-preload.js reads:
    #   opencode-theme-id       → any non-"oc-2" value activates custom CSS
    #   opencode-theme-css-dark → CSS variables injected on dark mode
    #   opencode-theme-css-light→ CSS variables injected on light mode
    # We write these directly into Chromium's LevelDB journal.
    OPENCODE_LDB="$APP_SUPPORT_DIR/ai.opencode.desktop/Local Storage/leveldb"

    if [ -d "$OPENCODE_LDB" ] && [ -n "$BG" ] && [ -n "$FG" ] && [ -n "$COLORS" ] && [ -f "$OPENCODE_PY" ]; then
        ANSI_LIST=(
            "${ANSI_Black:-#000000}"   "${ANSI_Red:-#cc0000}"   "${ANSI_Green:-#4e9a06}"   "${ANSI_Yellow:-#c4a000}"
            "${ANSI_Blue:-#3465a4}"   "${ANSI_Magenta:-#75507b}" "${ANSI_Cyan:-#06989a}"   "${ANSI_White:-#d3d7cf}"
            "${ANSI_BrightBlack:-#555753}" "${ANSI_BrightRed:-#ef2929}" "${ANSI_BrightGreen:-#8ae234}" "${ANSI_BrightYellow:-#fce94f}"
            "${ANSI_BrightBlue:-#729fcf}" "${ANSI_BrightMagenta:-#ad7fa8}" "${ANSI_BrightCyan:-#34e2e2}" "${ANSI_BrightWhite:-#eeeeee}"
        )

        OPENCODE_LEVELDB_DIR="$OPENCODE_LDB" \
        python3 "$OPENCODE_PY" \
            "$BG" "$FG" "$ACCENT" \
            "${SELECTION_BG:-}" "${SELECTION_FG:-}" "${LINE_HIGHLIGHT:-}" "${FIND_MATCH_BG:-}" "${FIND_MATCH_FG:-}" \
            "${ANSI_LIST[@]}" && \
        echo "  OpenCode Desktop LevelDB journal written (takes effect on restart)"
    fi

    # ── 10. Antigravity.app (agent app, not editor fork) ────────────────────
    # Antigravity.app reads theme from ~/.gemini/config/config.json, not
    # from its VS Code-style settings.json. It supports custom theme seeds
    # for light and dark modes with background, foreground, and primary colors.
    GEMINI_CONFIG="$HOME/.gemini/config/config.json"
    mkdir -p "$(dirname "$GEMINI_CONFIG")"

    python3 <<PYEOF
import json, os

path = "$GEMINI_CONFIG"
config = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            config = json.load(f)
    except json.JSONDecodeError:
        pass

us = config.setdefault("userSettings", {})
us["themeMode"] = "$THEME_MODE"
us["customThemeSeedsLight"] = {
    "background": "$BG",
    "foregroundOverride": "$FG",
    "primary": "$ACCENT"
}
us["customThemeSeedsDark"] = {
    "background": "$BG",
    "foregroundOverride": "$FG",
    "primary": "$ACCENT"
}

with open(path, "w") as f:
    json.dump(config, f, indent=2)
PYEOF
    echo "Synced theme to $GEMINI_CONFIG (mode=$THEME_MODE)"

    # ── 11. Codex ─────────────────────────────────────────────────────────────
    # Codex has its own built-in syntax theme IDs — we always use "codex" and
    # map the VS Code chrome colours to Codex's chrome theme so the chrome
    # (sidebar, title bar, etc.) matches the editor.
    CODEX_CONFIG="$HOME/.codex/config.toml"
    if [ -f "$CODEX_CONFIG" ]; then
        SURFACE=$(echo "$COLORS" | jq -r '.["titleBar.activeBackground"] // .["sideBar.background"] // .["activityBar.background"] // empty' | strip_alpha)
        INK=$(echo "$COLORS" | jq -r '.["titleBar.activeForeground"] // .["sideBar.foreground"] // .["activityBar.foreground"] // empty' | strip_alpha)
        [ -z "$SURFACE" ] && SURFACE="$BG"
        [ -z "$INK" ]     && INK="$FG"

        CODEX_PID=$(pgrep -f "codex app-server" 2>/dev/null)
        [ -n "$CODEX_PID" ] && kill "$CODEX_PID" 2>/dev/null && sleep 1

        python3 -c "
import re
with open('$CODEX_CONFIG') as f:
    text = f.read()
chrome_block = '''[desktop.appearanceDarkChromeTheme]
accent = \"$ACCENT\"
contrast = 60
ink = \"$INK\"
opaqueWindows = false
surface = \"$SURFACE\"

[desktop.appearanceDarkChromeTheme.semanticColors]
diffAdded = \"${ANSI_Green:-#00a240}\"
diffRemoved = \"${ANSI_Red:-#e02e2a}\"
skill = \"${ANSI_Magenta:-#b06dff}\"
'''
text = re.sub(r'(?:\n|\A)\[desktop\].*', '', text, flags=re.DOTALL)
text = text.rstrip() + '\n\n[desktop]\nappearanceDarkCodeThemeId = \"codex\"\n' + chrome_block
with open('$CODEX_CONFIG', 'w') as f:
    f.write(text)
"
        echo "Synced theme to $CODEX_CONFIG"
        [ -n "$CODEX_PID" ] && echo "  (Codex daemon was stopped; restart it for the theme to apply)"
    fi

    echo "Sync complete"
}

# ── SSH sync ─────────────────────────────────────────────────────────────────
# The resolved colour set is pushed to each remote host as %q-quoted shell
# assignments followed by this script itself, which re-executes in
# --apply-remote mode on the far side. One ssh connection per host; nothing
# needs to be pre-installed beyond python3 + jq.

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)

PAYLOAD_VARS=(
    ACTIVE_THEME THEME_MODE BG FG CURSOR
    SELECTION_BG SELECTION_FG LINE_HIGHLIGHT FIND_MATCH_BG FIND_MATCH_FG
    ACCENT COLORS EXTENSION_ID
    VSCODE_AUTO_DETECT VSCODE_PREFERRED_LIGHT VSCODE_PREFERRED_DARK
    ANSI_Black ANSI_Red ANSI_Green ANSI_Yellow
    ANSI_Blue ANSI_Magenta ANSI_Cyan ANSI_White
    ANSI_BrightBlack ANSI_BrightRed ANSI_BrightGreen ANSI_BrightYellow
    ANSI_BrightBlue ANSI_BrightMagenta ANSI_BrightCyan ANSI_BrightWhite
)

_b64decode() {
    python3 -c 'import sys, base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read().strip()))'
}

# Bundle the theme extension itself (so forks without a CLI can copy it),
# unless it is too large to be worth shipping over the wire.
build_extension_bundle() {
    BUNDLE_TGZ_B64=""
    BUNDLE_EXT_NAME=""
    if [ -n "${EXTENSION_DIR:-}" ] && [ -d "$EXTENSION_DIR" ]; then
        local size_kb
        size_kb=$(du -sk "$EXTENSION_DIR" 2>/dev/null | cut -f1)
        if [ "${size_kb:-0}" -le 15360 ]; then
            BUNDLE_EXT_NAME=$(basename "$EXTENSION_DIR")
            BUNDLE_TGZ_B64=$(tar -C "$(dirname "$EXTENSION_DIR")" -cz "$BUNDLE_EXT_NAME" | base64 | tr -d '\n')
        else
            echo "  (theme extension exceeds 15 MB — remotes will use CLI install only)"
        fi
    fi
}

emit_payload_prelude() {
    local tgz_b64="$1" ext_name="$2" v val
    echo "# ---- sync_theme payload (generated; do not edit) ----"
    for v in "${PAYLOAD_VARS[@]}"; do
        val="${!v:-}"
        printf 'SYNC_%s=%q\n' "$v" "$val"
    done
    printf 'SYNC_OPENCODE_PY_B64=%s\n' "$(base64 < "$SCRIPT_DIR/opencode_theme.py" | tr -d '\n')"
    printf 'SYNC_EXTENSION_TGZ_B64=%s\n' "$tgz_b64"
    printf 'SYNC_EXTENSION_NAME=%q\n' "$ext_name"
}

load_payload_vars() {
    local v ref
    for v in "${PAYLOAD_VARS[@]}"; do
        ref="SYNC_$v"
        printf -v "$v" '%s' "${!ref:-}"
    done
}

RECEIVER_TMP=""
cleanup_receiver_tmp() { [ -n "$RECEIVER_TMP" ] && rm -rf "$RECEIVER_TMP"; }
trap cleanup_receiver_tmp EXIT

stage_remote_extras() {
    RECEIVER_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sync-theme-receiver.XXXXXX")

    OPENCODE_PY="$RECEIVER_TMP/opencode_theme.py"
    printf '%s' "${SYNC_OPENCODE_PY_B64:-}" | _b64decode > "$OPENCODE_PY" 2>/dev/null

    EXTENSION_DIR=""
    if [ -n "${SYNC_EXTENSION_TGZ_B64:-}" ] && [ -n "${SYNC_EXTENSION_NAME:-}" ]; then
        printf '%s' "$SYNC_EXTENSION_TGZ_B64" | _b64decode > "$RECEIVER_TMP/ext.tgz" 2>/dev/null
        if tar -C "$RECEIVER_TMP" -xzf "$RECEIVER_TMP/ext.tgz" 2>/dev/null &&
           [ -d "$RECEIVER_TMP/$SYNC_EXTENSION_NAME" ]; then
            EXTENSION_DIR="$RECEIVER_TMP/$SYNC_EXTENSION_NAME"
        fi
    fi
}

push_to_remote() {
    local host="$1"

    # Preflight: reachable + receiver dependencies present
    if ! ssh "${SSH_OPTS[@]}" "$host" 'command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1'; then
        echo "  [warn] $host: unreachable or missing python3/jq — skipped"
        return 1
    fi

    build_extension_bundle

    echo "→ Pushing theme to $host …"
    if { emit_payload_prelude "$BUNDLE_TGZ_B64" "$BUNDLE_EXT_NAME"; cat "$SELF_PATH"; } |
        ssh "${SSH_OPTS[@]}" "$host" 'bash -s -- --apply-remote'; then
        echo "  ✓ $host synced"
    else
        echo "  [warn] $host: sync failed — skipped"
        return 1
    fi
}

push_remotes() {
    local host rc=0
    for host in "${REMOTES[@]}"; do
        push_to_remote "$host" || rc=1
    done
    return $rc
}

sync_once() {
    resolve_theme
    apply_targets
    if [ "${#REMOTES[@]}" -gt 0 ]; then
        push_remotes || true
    fi
}

# ── Watch mode ───────────────────────────────────────────────────────────────
# Returns a stable fingerprint of the theme-related settings AND the current
# OS appearance so we can detect when VS Code switches theme (either manually
# or via auto-detect) or when the system toggles light/dark.
get_theme_fingerprint() {
    local fp
    fp=$(_clean_json < "$VSCODE_SETTINGS" | jq -c '{
        auto: .["window.autoDetectColorScheme"],
        light: .["workbench.preferredLightColorTheme"],
        dark: .["workbench.preferredDarkColorTheme"],
        theme: .["workbench.colorTheme"]
    }' 2>/dev/null) || fp=""
    if [ -z "$fp" ]; then
        echo ""
        return
    fi
    if [ "$IS_MACOS" = 1 ]; then
        MACOS_MODE=$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo "Light")
    fi
    printf '%s|%s\n' "$fp" "$MACOS_MODE"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--watch] [--remote user@host]...

  (no flags)     Resolve the active theme from VS Code and sync all local targets.
  --watch        Keep running; poll VS Code settings + OS appearance every 2s
                 and re-sync (locally and to all remotes) on every change.
  --remote HOST  Additionally push the resolved theme to HOST over SSH.
                 Repeatable. Requires key-based SSH auth (BatchMode); the host
                 only needs python3 and jq preinstalled.
  --help         Show this help.
EOF
}

main() {
    MODE="run"
    REMOTES=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --watch)
                MODE="watch" ;;
            --remote)
                [ -n "${2:-}" ] || { echo "error: --remote requires a host argument" >&2; exit 1; }
                REMOTES+=("$2")
                shift ;;
            --apply-remote)
                MODE="apply-remote" ;;
            --emit-payload)
                MODE="emit-payload" ;;
            --help|-h)
                usage
                exit 0 ;;
            *)
                echo "error: unknown option: $1" >&2
                usage >&2
                exit 1 ;;
        esac
        shift
    done

    case "$MODE" in
        apply-remote)
            # Receiver side of an SSH push: colours arrive via the payload
            # prelude; never touch the network or local detection here.
            for cmd in python3 jq; do
                command -v "$cmd" >/dev/null 2>&1 || {
                    echo "sync_theme receiver: missing dependency: $cmd" >&2
                    exit 1
                }
            done
            load_payload_vars
            stage_remote_extras
            apply_targets
            ;;
        emit-payload)
            # Debug helper: prints exactly what would be piped to a remote host.
            ensure_dependencies
            resolve_theme >&2
            build_extension_bundle
            emit_payload_prelude "$BUNDLE_TGZ_B64" "$BUNDLE_EXT_NAME"
            cat "$SELF_PATH"
            ;;
        run)
            ensure_dependencies
            resolve_theme
            apply_targets
            if [ "${#REMOTES[@]}" -gt 0 ]; then
                push_remotes || true
            fi
            ;;
        watch)
            ensure_dependencies
            echo "Watching VS Code settings for theme changes (poll every 2s)..."
            if [ "${#REMOTES[@]}" -gt 0 ]; then
                echo "Remotes: ${REMOTES[*]}"
            fi
            echo "Press Ctrl+C to stop."
            echo ""
            # Run synchronously the first time so the user sees output
            sync_once
            LAST_FINGERPRINT=$(get_theme_fingerprint)
            while true; do
                sleep 2
                CURRENT_FINGERPRINT=$(get_theme_fingerprint)
                if [ -z "$CURRENT_FINGERPRINT" ]; then
                    echo "  (settings file vanished — waiting for it to reappear)"
                    LAST_FINGERPRINT=""
                    continue
                fi
                if [ "$CURRENT_FINGERPRINT" != "$LAST_FINGERPRINT" ]; then
                    echo ""
                    echo "== Theme changed, re-syncing... =="
                    sync_once
                    echo "== Watch resumed =="
                    LAST_FINGERPRINT=$(get_theme_fingerprint)
                fi
            done
            ;;
    esac
}

main "$@"
