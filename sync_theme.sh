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

    for cmd in python3 jq; do
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
#   TOKEN_FGS                  comma-separated tokenColors/semantic foregrounds
#   EXTENSION_ID EXTENSION_DIR marketplace id + source dir of theme extension
VSCODE_AUTO_DETECT=""
VSCODE_PREFERRED_LIGHT=""
VSCODE_PREFERRED_DARK=""
TOKEN_FGS=""

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
        COLORS="{}"; TOKEN_FGS=""
        for _n in Black Red Green Yellow Blue Magenta Cyan White \
                 BrightBlack BrightRed BrightGreen BrightYellow \
                 BrightBlue BrightMagenta BrightCyan BrightWhite; do
            printf -v "ANSI_${_n}" '%s' ""
        done
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
        # Token foregrounds (syntax colors) for purpose-based substitution.
        # Quiet Light et al. define no terminal.ansi* but carry usable hues here.
        TOKEN_FGS=$(_clean_json < "$FOUND_FILE" | python3 -c "
import sys, json, re
try:
    t = json.load(sys.stdin)
except Exception:
    print('')
    sys.exit(0)
outs = []
for tc in (t.get('tokenColors') or []):
    try:
        f = (tc.get('settings') or {}).get('foreground')
        if isinstance(f, str) and re.match(r'^#[0-9a-fA-F]{6}', f):
            outs.append(f[:7])
    except Exception:
        pass
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == 'foreground' and isinstance(v, str) and re.match(r'^#[0-9a-fA-F]{6}', v):
                outs.append(v[:7])
            else:
                walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(t.get('semanticTokenColors'))
seen = set(); uniq = []
for c in outs:
    cl = c.lower()
    if cl not in seen:
        seen.add(cl); uniq.append(c)
print(','.join(uniq))
" 2>/dev/null)
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

    # ── 5. Safe defaults (theme-aware, no white/black snap) ────────────────
    # BG: BG stays as theme intent; only fill when missing via background-ish
    # keys, then theme-name heuristic (Quiet Light -> light).
    if [ -z "$BG" ]; then
        BG=$(echo "$COLORS" | jq -r '.["editor.background"] // .["background"] // .["sideBar.background"] // .["activityBar.background"] // .["panel.background"] // empty' 2>/dev/null | strip_alpha)
    fi
    if [ -z "$BG" ]; then
        case "${ACTIVE_THEME,,}" in
            *light*|*quiet*) BG="#F5F5F5" ;;
            *) BG="#1e1e1e" ;;
        esac
    fi
    # FG: prefer theme text colors / most common token foreground over a
    # hardcoded gray, so light themes don't inherit dark-theme "#cccccc".
    # FG: body text must stay neutral (dark grey on light BG). Prefer editor
    # text keys, then the token base foreground (#333333 in Quiet Light),
    # and only then chrome ink (activityBar etc., often an accent hue).
    if [ -z "$FG" ]; then
        FG=$(echo "$COLORS" | jq -r '.["terminal.foreground"] // .["editor.foreground"] // .["foreground"] // empty' 2>/dev/null | strip_alpha)
    fi
    if [ -z "$FG" ] && [ -n "$TOKEN_FGS" ]; then
        FG=$(echo "$TOKEN_FGS" | tr ',' '\n' | grep -m1 -E '^#[0-9a-fA-F]{6}$' || true)
    fi
    if [ -z "$FG" ]; then
        FG=$(echo "$COLORS" | jq -r '.["sideBar.foreground"] // .["activityBar.foreground"] // .["tab.activeForeground"] // empty' 2>/dev/null | strip_alpha)
    fi
    if [ -z "$FG" ]; then
        if [ "$(python3 -c "
bg = '$BG'.lstrip('#')
r, g, b = int(bg[0:2],16), int(bg[2:4],16), int(bg[4:6],16)
print('dark' if r*0.299+g*0.587+b*0.114 < 128 else 'light')
" 2>/dev/null)" = "dark" ]; then FG="#cccccc"; else FG="#333333"; fi
    fi
    [ -z "$CURSOR" ]         && CURSOR="$FG"
    [ -z "$SELECTION_BG" ]   && SELECTION_BG="#264f78"
    [ -z "$SELECTION_FG" ]   && SELECTION_FG=""
    [ -z "$LINE_HIGHLIGHT" ] && LINE_HIGHLIGHT=""

    # ── 6. Purpose-based + contrast-based harmonization ──────────────────────
    # Every FG/ANSI/accent/cursor color must reach 4.5:1 vs BG. Same-hue theme
    # colors (tokenColors + .colors) win; else lightness is shifted with hue
    # preserved. No pure white/black snapping.
    _harmonized=$(BG="$BG" FG="$FG" CURSOR="$CURSOR" ACCENT_PLACEHOLDER="${ACCENT:-}" COLORS="$COLORS" TOKEN_FGS="$TOKEN_FGS" \
        ANSI_Black="$ANSI_Black" ANSI_Red="$ANSI_Red" ANSI_Green="$ANSI_Green" ANSI_Yellow="$ANSI_Yellow" \
        ANSI_Blue="$ANSI_Blue" ANSI_Magenta="$ANSI_Magenta" ANSI_Cyan="$ANSI_Cyan" ANSI_White="$ANSI_White" \
        ANSI_BrightBlack="$ANSI_BrightBlack" ANSI_BrightRed="$ANSI_BrightRed" ANSI_BrightGreen="$ANSI_BrightGreen" ANSI_BrightYellow="$ANSI_BrightYellow" \
        ANSI_BrightBlue="$ANSI_BrightBlue" ANSI_BrightMagenta="$ANSI_BrightMagenta" ANSI_BrightCyan="$ANSI_BrightCyan" ANSI_BrightWhite="$ANSI_BrightWhite" \
        python3 -c "
import os, json, re, colorsys
MIN=4.5
def valid(h): return isinstance(h,str) and bool(re.match(r'^#[0-9a-fA-F]{6}\$', h or ''))
def rgb(h):
    h=h.lstrip('#'); return tuple(int(h[i:i+2],16) for i in (0,2,4))
def lum(h):
    h=h.lstrip('#')[:6]
    r,g,b=int(h[0:2],16)/255,int(h[2:4],16)/255,int(h[4:6],16)/255
    lin=lambda c: c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4
    return 0.2126*lin(r)+0.7152*lin(g)+0.0722*lin(b)
def cr(a,b):
    try: l1,l2=lum(a),lum(b)
    except Exception: return 0.0
    hi,lo=max(l1,l2),min(l1,l2); return (hi+0.05)/(lo+0.05)
def bucket(h):
    try: r,g,b=rgb(h)
    except Exception: return 'neutral'
    hl,li,sa=colorsys.rgb_to_hls(r/255,g/255,b/255)
    if sa<0.15: return 'neutral'
    if li>0.90 or li<0.10: return 'neutral'
    d=hl*360
    if d>=340 or d<20: return 'red'
    if d<45: return 'orange'
    if d<75: return 'yellow'
    if d<170: return 'green'
    if d<200: return 'cyan'
    if d<260: return 'blue'
    if d<295: return 'purple'
    return 'magenta'
def tohex(r,g,b): return f'#{max(0,min(255,round(r))):02x}{max(0,min(255,round(g))):02x}{max(0,min(255,round(b))):02x}'
def adjust(c,bg):
    if cr(c,bg)>=MIN: return c
    try: r,g,b=rgb(c)
    except Exception: return c
    h,ol,s=colorsys.rgb_to_hls(r/255,g/255,b/255)
    best=None; bd=None
    for i in range(101):
        li=i/100
        rr,gg,bb=colorsys.hls_to_rgb(h,li,s)
        cand=tohex(rr*255,gg*255,bb*255)
        if cr(cand,bg)>=MIN:
            d=abs(li-ol)
            if bd is None or d<bd: bd=d; best=cand
    return best or c
def pick(orig,pool,bg,want=None):
    if valid(orig) and cr(orig,bg)>=MIN and (want is None or bucket(orig) in want): return orig
    passing=[c for c in dict.fromkeys(pool) if valid(c) and cr(c,bg)>=MIN and (want is None or bucket(c) in want)]
    if passing: return max(passing,key=lambda c: cr(c,bg))
    cands=[c for c in pool if valid(c) and (want is None or bucket(c) in want)]
    if cands: return adjust(max(cands,key=lambda c: cr(c,bg)),bg)
    if valid(orig): return adjust(orig,bg)
    return orig
bg=os.environ.get('BG',''); g=lambda k: os.environ.get(k,'') or ''
names=['Black','Red','Green','Yellow','Blue','Magenta','Cyan','White','BrightBlack','BrightRed','BrightGreen','BrightYellow','BrightBlue','BrightMagenta','BrightCyan','BrightWhite']
ansi=[g('ANSI_'+n) for n in names]
try: colors=json.loads(os.environ.get('COLORS') or '{}')
except Exception: colors={}
pool=[]
for v in colors.values():
    if isinstance(v,str) and re.match(r'^#[0-9a-fA-F]{6}',v): pool.append(v[:7])
for c in (os.environ.get('TOKEN_FGS') or '').split(','):
    if re.match(r'^#[0-9a-fA-F]{6}\$',c.strip()): pool.append(c.strip())
pool+=[c for c in ansi if valid(c)]
acc=os.environ.get('ACCENT_PLACEHOLDER') or ''
if valid(acc): pool.append(acc)
fg0=g('FG'); cur0=g('CURSOR')
if valid(fg0): pool.append(fg0)
bmap={}
for c in pool: bmap.setdefault(bucket(c),[]).append(c)
slots={0:{'neutral'},8:{'neutral'},1:{'red'},9:{'red'},2:{'green'},10:{'green'},3:{'orange','yellow'},11:{'orange','yellow'},4:{'blue'},12:{'blue'},5:{'purple','magenta'},13:{'purple','magenta'},6:{'cyan'},14:{'cyan'},7:{'neutral'},15:{'neutral'}}
fg=pick(fg0,bmap.get('neutral',[])+([fg0] if valid(fg0) else []),bg,{'neutral'})
cur=pick(cur0 if valid(cur0) else fg,bmap.get('neutral',[])+[fg],bg,{'neutral'})
out=[]
for i in range(16):
    orig=ansi[i] if valid(ansi[i]) else ''
    if not orig:
        same=[]
        for b in slots[i]: same+=bmap.get(b,[])
        orig=max(same,key=lambda c: cr(c,bg)) if same else (fg if valid(fg) else bg)
    hp=[]
    for b in slots[i]: hp+=bmap.get(b,[])
    if i>=8 and valid(ansi[i-8]): hp.append(ansi[i-8])
    out.append(pick(orig,hp,bg,slots[i]))
for n,v in zip(names,out): print(f'ANSI_{n}={v}')
print(f'FG={fg}')
print(f'CURSOR={cur}')
" 2>/dev/null)
    if [ -n "$_harmonized" ]; then
        while IFS='=' read -r _k _v; do
            case "$_k" in
                ANSI_*|FG|CURSOR) printf -v "$_k" '%s' "$_v" ;;
            esac
        done <<< "$_harmonized"
        echo "  Harmonized FG + ANSI palette vs $BG (purpose-aware, min 4.5:1)"
        echo "  foreground          = $FG (harmonized)"
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

    # Harmonize accent vs BG the same way (same-hue pool, else lightness shift).
    _acc_h=$(BG="$BG" ACCENT="$ACCENT" COLORS="$COLORS" TOKEN_FGS="$TOKEN_FGS" \
        ANSI_Black="$ANSI_Black" ANSI_Red="$ANSI_Red" ANSI_Green="$ANSI_Green" ANSI_Yellow="$ANSI_Yellow" \
        ANSI_Blue="$ANSI_Blue" ANSI_Magenta="$ANSI_Magenta" ANSI_Cyan="$ANSI_Cyan" ANSI_White="$ANSI_White" \
        ANSI_BrightBlack="$ANSI_BrightBlack" ANSI_BrightRed="$ANSI_BrightRed" ANSI_BrightGreen="$ANSI_BrightGreen" ANSI_BrightYellow="$ANSI_BrightYellow" \
        ANSI_BrightBlue="$ANSI_BrightBlue" ANSI_BrightMagenta="$ANSI_BrightMagenta" ANSI_BrightCyan="$ANSI_BrightCyan" ANSI_BrightWhite="$ANSI_BrightWhite" \
        python3 -c "
import os, json, re, colorsys
MIN=4.5
def valid(h): return isinstance(h,str) and bool(re.match(r'^#[0-9a-fA-F]{6}\$', h or ''))
def lum(h):
    h=h.lstrip('#')[:6]
    r,g,b=int(h[0:2],16)/255,int(h[2:4],16)/255,int(h[4:6],16)/255
    lin=lambda c: c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4
    return 0.2126*lin(r)+0.7152*lin(g)+0.0722*lin(b)
def cr(a,b):
    try: l1,l2=lum(a),lum(b)
    except Exception: return 0.0
    hi,lo=max(l1,l2),min(l1,l2); return (hi+0.05)/(lo+0.05)
def bucket(h):
    try:
        hh=h.lstrip('#'); r,g,b=int(hh[0:2],16),int(hh[2:4],16),int(hh[4:6],16)
    except Exception: return 'neutral'
    hl,li,sa=colorsys.rgb_to_hls(r/255,g/255,b/255)
    if sa<0.15: return 'neutral'
    if li>0.90 or li<0.10: return 'neutral'
    d=hl*360
    if d>=340 or d<20: return 'red'
    if d<45: return 'orange'
    if d<75: return 'yellow'
    if d<170: return 'green'
    if d<200: return 'cyan'
    if d<260: return 'blue'
    if d<295: return 'purple'
    return 'magenta'
def tohex(r,g,b): return f'#{max(0,min(255,round(r))):02x}{max(0,min(255,round(g))):02x}{max(0,min(255,round(b))):02x}'
def adjust(c,bg):
    if cr(c,bg)>=MIN: return c
    hh=c.lstrip('#'); r,g,b=int(hh[0:2],16),int(hh[2:4],16),int(hh[4:6],16)
    h,ol,s=colorsys.rgb_to_hls(r/255,g/255,b/255)
    best=None; bd=None
    for i in range(101):
        li=i/100
        rr,gg,bb=colorsys.hls_to_rgb(h,li,s)
        cand=tohex(rr*255,gg*255,bb*255)
        if cr(cand,bg)>=MIN:
            d=abs(li-ol)
            if bd is None or d<bd: bd=d; best=cand
    return best or c
bg=os.environ.get('BG',''); acc=os.environ.get('ACCENT','')
pool=[]
try: colors=json.loads(os.environ.get('COLORS') or '{}')
except Exception: colors={}
for v in colors.values():
    if isinstance(v,str) and re.match(r'^#[0-9a-fA-F]{6}',v): pool.append(v[:7])
for c in (os.environ.get('TOKEN_FGS') or '').split(','):
    c=c.strip()
    if re.match(r'^#[0-9a-fA-F]{6}\$',c): pool.append(c)
for k in ['ANSI_Black','ANSI_Red','ANSI_Green','ANSI_Yellow','ANSI_Blue','ANSI_Magenta','ANSI_Cyan','ANSI_White','ANSI_BrightBlack','ANSI_BrightRed','ANSI_BrightGreen','ANSI_BrightYellow','ANSI_BrightBlue','ANSI_BrightMagenta','ANSI_BrightCyan','ANSI_BrightWhite']:
    v=os.environ.get(k,'')
    if valid(v): pool.append(v)
want=bucket(acc) if valid(acc) else 'blue'
same=[c for c in pool if bucket(c)==want]
passing=[c for c in dict.fromkeys(same) if valid(c) and cr(c,bg)>=MIN]
if valid(acc) and cr(acc,bg)>=MIN:
    print(acc)
elif passing:
    print(max(passing,key=lambda c: cr(c,bg)))
elif valid(acc):
    cands=[acc]+same
    print(adjust(max(cands,key=lambda c: cr(c,bg)),bg))
else:
    print(acc)
" 2>/dev/null)
    if [ -n "$_acc_h" ]; then
        [ "$_acc_h" != "$ACCENT" ] && echo "  Harmonized accent $ACCENT → $_acc_h"
        ACCENT="$_acc_h"
    fi

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

apply_herdr() {
    # Sync Herdr's UI chrome ([theme.custom] in config.toml) from the same
    # resolved VS Code palette, then hot-reload the server so the current
    # theme changes immediately (no restart, panes keep running).
    # Respects HERDR_CONFIG_PATH; skips gracefully when herdr is absent
    # (e.g. an SSH receiver without herdr installed).
    if ! command -v herdr &>/dev/null; then
        echo "  [debug] herdr not on PATH — skipping herdr theme sync"
        return 0
    fi
    local HERDR_CONFIG="${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
    mkdir -p "$(dirname "$HERDR_CONFIG")"
    if [ -f "$HERDR_CONFIG" ]; then
        cp -p "$HERDR_CONFIG" "$HERDR_CONFIG.bak-$(date +%Y%m%d)" 2>/dev/null || true
    fi

    # NOTE: do NOT write COLORS="${COLORS:-{}}" here. POSIX shells end the
    # expansion at the first } (default "{" plus a literal "}"), so a
    # non-empty COLORS would gain a trailing brace and fail to parse.
    if [ -z "$COLORS" ]; then COLORS="{}"; fi

    BG="$BG" FG="$FG" ACCENT="$ACCENT" \
    SELECTION_BG="${SELECTION_BG:-}" SELECTION_FG="${SELECTION_FG:-}" LINE_HIGHLIGHT="${LINE_HIGHLIGHT:-}" \
    COLORS="$COLORS" THEME_MODE="${THEME_MODE:-THEME_MODE_DARK}" HERDR_CONFIG="$HERDR_CONFIG" \
    ANSI_Black="$ANSI_Black" ANSI_Red="$ANSI_Red" ANSI_Green="$ANSI_Green" ANSI_Yellow="$ANSI_Yellow" \
    ANSI_Blue="$ANSI_Blue" ANSI_Magenta="$ANSI_Magenta" ANSI_Cyan="$ANSI_Cyan" ANSI_White="$ANSI_White" \
    ANSI_BrightBlack="$ANSI_BrightBlack" ANSI_BrightRed="$ANSI_BrightRed" ANSI_BrightGreen="$ANSI_BrightGreen" ANSI_BrightYellow="$ANSI_BrightYellow" \
    ANSI_BrightBlue="$ANSI_BrightBlue" ANSI_BrightMagenta="$ANSI_BrightMagenta" ANSI_BrightCyan="$ANSI_BrightCyan" ANSI_BrightWhite="$ANSI_BrightWhite" \
    python3 - <<'PYEOF'
import json, os, re

path = os.environ["HERDR_CONFIG"]
def g(k): return (os.environ.get(k) or "").strip()
def valid(h): return isinstance(h, str) and bool(re.match(r'^#[0-9a-fA-F]{6}$', h or ''))
def first(*vals):
    for v in vals:
        if valid(v): return v
    return ""

try: colors = json.loads(os.environ.get("COLORS") or "{}")
except Exception: colors = {}
def ckey(*keys):
    for k in keys:
        v = (colors.get(k) or "")[:7]
        if valid(v): return v
    return ""

bg, fg, accent = g("BG"), g("FG"), g("ACCENT")
sel_bg, sel_fg, line_hl = g("SELECTION_BG"), g("SELECTION_FG"), g("LINE_HIGHLIGHT")
surface = ckey("titleBar.activeBackground", "sideBar.background", "activityBar.background", "panel.background")

tokens = {
    "panel_bg":      first(bg),
    "sidebar_bg":    first(surface, bg),
    "active_row_bg": first(sel_bg, line_hl, surface),
    "selection_bg":  first(sel_bg, line_hl),
    "surface0":      first(surface, bg),
    "surface1":      first(sel_bg, surface),
    "surface_dim":   first(bg),
    "overlay0":      first(g("ANSI_BrightBlack"), sel_fg, fg),
    "overlay1":      first(fg),
    "text":          first(fg),
    "subtext0":      first(sel_fg, g("ANSI_BrightBlack"), fg),
    "mauve":         first(g("ANSI_BrightMagenta"), g("ANSI_Magenta")),
    "green":         first(g("ANSI_BrightGreen"), g("ANSI_Green")),
    "yellow":        first(g("ANSI_BrightYellow"), g("ANSI_Yellow")),
    "red":           first(g("ANSI_BrightRed"), g("ANSI_Red")),
    "blue":          first(g("ANSI_BrightBlue"), g("ANSI_Blue")),
    "teal":          first(g("ANSI_BrightCyan"), g("ANSI_Cyan")),
    "peach":         first(g("ANSI_BrightYellow"), g("ANSI_Yellow")),
    "accent":        first(accent),
}
tokens = {k: v for k, v in tokens.items() if valid(v)}
dark = os.environ.get("THEME_MODE", "THEME_MODE_DARK") != "THEME_MODE_LIGHT"
base = "catppuccin" if dark else "catppuccin-latte"

text = ""
if os.path.exists(path):
    with open(path) as f: text = f.read()
if not text.endswith("\n") and text: text += "\n"

# Drop previously synced [theme.custom] blocks (plus light/dark subtables).
lines = text.splitlines(keepends=True)
out, skipping = [], False
for line in lines:
    s = line.strip()
    if re.match(r'^\[theme\.custom(\.\w+)?\s*\]', s):
        skipping = True
        continue
    if skipping and re.match(r'^\[.*\]', s):
        skipping = False
    if not skipping: out.append(line)
text = "".join(out)

# Ensure [theme] exists with a mode-matching base; manual selection stays
# off so the synced palette wins (auto_switch = false).
if re.search(r'(?m)^\[theme\]\s*$', text):
    def fix_section(m):
        body = m.group(0)
        body = re.sub(r'(?m)^name\s*=.*$', f'name = "{base}"', body)
        body = re.sub(r'(?m)^auto_switch\s*=.*$', 'auto_switch = false', body)
        if not re.search(r'(?m)^name\s*=', body): body += f'\nname = "{base}"'
        if not re.search(r'(?m)^auto_switch\s*=', body): body += '\nauto_switch = false'
        return body
    text = re.sub(r'(?m)^\[theme\]\s*$\n(?:^(?!\s*\[).*\n?)*', fix_section, text, count=1)
else:
    if text and not text.endswith("\n\n"): text += "\n"
    text += f'[theme]\nname = "{base}"\nauto_switch = false\n'

text = text.rstrip() + "\n\n[theme.custom]\n"
for k, v in tokens.items(): text += f'{k} = "{v}"\n'
with open(path, "w") as f: f.write(text)
print(f"  Herdr theme → {base} + {len(tokens)} synced tokens ({path})")
PYEOF

    if herdr server reload-config 2>/dev/null; then
        echo "  Herdr config reloaded (theme live, panes untouched)"
    else
        echo "  [debug] herdr server not running — theme applies on next start"
    fi
}

apply_hermes() {
    # Write a Hermes skin (skins/sync-theme.yaml) from the same resolved VS
    # Code palette and activate it. The gateway's skin watcher repaints every
    # surface live (~a second), so no restart is needed.
    # Respects HERMES_HOME (profile homes keep their own skins/). The skin file
    # is always written (pure python); only activation needs the hermes CLI,
    # so an SSH receiver without hermes still gets the file for next start.
    local HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
    local SKIN="$HERMES_HOME_DIR/skins/sync-theme.yaml"
    mkdir -p "$(dirname "$SKIN")"
    if [ -f "$SKIN" ]; then
        cp -p "$SKIN" "$SKIN.bak-$(date +%Y%m%d)" 2>/dev/null || true
    fi

    # NOTE: same shell-quirk guard as apply_herdr — never use ${VAR:-{}}.
    if [ -z "$COLORS" ]; then COLORS="{}"; fi

    ACTIVE_THEME="$ACTIVE_THEME" BG="$BG" FG="$FG" ACCENT="$ACCENT" \
    SELECTION_BG="${SELECTION_BG:-}" SELECTION_FG="${SELECTION_FG:-}" LINE_HIGHLIGHT="${LINE_HIGHLIGHT:-}" \
    COLORS="$COLORS" THEME_MODE="${THEME_MODE:-THEME_MODE_DARK}" SKIN="$SKIN" \
    ANSI_Black="$ANSI_Black" ANSI_Red="$ANSI_Red" ANSI_Green="$ANSI_Green" ANSI_Yellow="$ANSI_Yellow" \
    ANSI_Blue="$ANSI_Blue" ANSI_Magenta="$ANSI_Magenta" ANSI_Cyan="$ANSI_Cyan" ANSI_White="$ANSI_White" \
    ANSI_BrightBlack="$ANSI_BrightBlack" ANSI_BrightRed="$ANSI_BrightRed" ANSI_BrightGreen="$ANSI_BrightGreen" ANSI_BrightYellow="$ANSI_BrightYellow" \
    ANSI_BrightBlue="$ANSI_BrightBlue" ANSI_BrightMagenta="$ANSI_BrightMagenta" ANSI_BrightCyan="$ANSI_BrightCyan" ANSI_BrightWhite="$ANSI_BrightWhite" \
    python3 - <<'PYEOF'
import json, os, re

path = os.environ["SKIN"]
def g(k): return (os.environ.get(k) or "").strip()
def valid(h): return isinstance(h, str) and bool(re.match(r'^#[0-9a-fA-F]{6}$', h or ''))
def first(*vals):
    for v in vals:
        if valid(v): return v
    return ""

try: colors = json.loads(os.environ.get("COLORS") or "{}")
except Exception: colors = {}
def ckey(*keys):
    for k in keys:
        v = (colors.get(k) or "")[:7]
        if valid(v): return v
    return ""

bg, fg, accent = g("BG"), g("FG"), g("ACCENT")
sel_bg, sel_fg, line_hl = g("SELECTION_BG"), g("SELECTION_FG"), g("LINE_HIGHLIGHT")
subtext = first(sel_fg, g("ANSI_BrightBlack"), fg)
surface = ckey("titleBar.activeBackground", "sideBar.background", "activityBar.background", "panel.background")
border = surface if (valid(surface) and surface.lower() != bg.lower()) else first(g("ANSI_BrightBlack"), subtext, fg)
sel = first(sel_bg, line_hl, surface)
green = first(g("ANSI_BrightGreen"), g("ANSI_Green"))
yellow = first(g("ANSI_BrightYellow"), g("ANSI_Yellow"))
red = first(g("ANSI_BrightRed"), g("ANSI_Red"))
blue = first(g("ANSI_BrightBlue"), g("ANSI_Blue"))
magenta = first(g("ANSI_BrightMagenta"), g("ANSI_Magenta"))
cyan = first(g("ANSI_BrightCyan"), g("ANSI_Cyan"))
label = first(magenta, cyan, accent, fg)

# Key set mirrors hermes_cli/skin_engine.py built-ins; missing engine keys
# fall back to the default skin, unknown keys are ignored.
palette = {
    "background": bg,
    "banner_border": border, "banner_title": fg, "banner_accent": accent,
    "banner_dim": subtext, "banner_text": fg,
    "ui_accent": accent, "ui_label": label,
    "ui_ok": green, "ui_warn": yellow, "ui_error": red,
    "prompt": fg, "input_rule": accent, "response_border": first(blue, accent),
    "status_bar_bg": first(surface, bg), "status_bar_text": fg,
    "status_bar_strong": accent, "status_bar_dim": subtext,
    "status_bar_good": green, "status_bar_warn": yellow,
    "status_bar_bad": red, "status_bar_critical": first(g("ANSI_BrightRed"), red),
    "session_label": first(cyan, accent), "session_border": border,
    "completion_menu_bg": first(surface, bg),
    "completion_menu_current_bg": first(sel, surface),
    "completion_menu_meta_bg": first(surface, bg),
    "completion_menu_meta_current_bg": first(sel, surface),
    "selection_bg": first(sel, surface),
    "shell_dollar": first(green, accent), "voice_status_bg": first(surface, bg),
}
palette = {k: v for k, v in palette.items() if valid(v)}
src = re.sub(r'[\r\n"]+', ' ', g("ACTIVE_THEME")).strip() or "unknown theme"
lines = ["name: sync-theme",
         f'description: "Auto-synced from {src} by sync_theme.sh"',
         "colors:"]
for k, v in palette.items(): lines.append(f'  {k}: "{v}"')
text = "\n".join(lines) + "\n"
with open(path, "w") as f: f.write(text)

# Structural check (pyyaml is not a script dependency): every color line
# must be `  key: "#rrggbb"`.
bad = [ln for ln in text.splitlines()[3:] if not re.match(r'^  [a-z_]+: "#[0-9a-fA-F]{6}"$', ln)]
if bad:
    print(f"  [warn] hermes skin failed validation: {bad[:3]}")
else:
    print(f"  Hermes skin → sync-theme + {len(palette)} tokens ({path})")
try:
    import yaml  # optional, when present
    d = yaml.safe_load(text)
    assert isinstance(d.get("colors"), dict) and d.get("name") == "sync-theme"
except ImportError:
    pass
except Exception as e:
    print(f"  [warn] hermes skin YAML did not parse: {e}")
PYEOF

    # Activate only when needed; the writer path above is the safe one
    # (never hand-edit config.yaml).
    if ! command -v hermes &>/dev/null; then
        echo "  [debug] hermes not on PATH — skin file written; activate with: hermes config set display.skin sync-theme"
    elif hermes config get display.skin 2>/dev/null | grep -q 'sync-theme'; then
        echo "  Hermes skin already active (sync-theme)"
    elif hermes config set display.skin sync-theme 2>/dev/null; then
        echo "  Hermes skin activated (sync-theme — surfaces repaint live)"
    else
        echo "  [debug] hermes config set failed — skin file written; activate with: hermes config set display.skin sync-theme"
    fi
}

apply_opencode() {
    # OpenCode CLI/TUI v2 native themes (opencode.ai/docs/cli/theme): generate
    # a sync-theme.json in the global themes dir and select it in cli.json.
    # Replaces the old Chromium-LevelDB CSS hack. Restart opencode to pick up
    # a newly added theme file.
    local THEMES_DIR="$HOME/.config/opencode/themes"
    local CLI_JSON="$HOME/.config/opencode/cli.json"
    mkdir -p "$THEMES_DIR" "$(dirname "$CLI_JSON")"
    local THEME_JSON="$THEMES_DIR/sync-theme.json"
    [ -f "$THEME_JSON" ] && cp -p "$THEME_JSON" "$THEME_JSON.bak-$(date +%Y%m%d)" 2>/dev/null || true
    [ -f "$CLI_JSON" ] && cp -p "$CLI_JSON" "$CLI_JSON.bak-$(date +%Y%m%d)" 2>/dev/null || true

    # NOTE: same shell-quirk guard as apply_herdr — never use ${VAR:-{}}.
    if [ -z "$COLORS" ]; then COLORS="{}"; fi

    # Pre-strip // comments + trailing commas (cli.json may be jsonc); the
    # python below parses this preferentially so no existing key is lost.
    CLI_JSON_CLEAN=""
    if [ -f "$CLI_JSON" ]; then CLI_JSON_CLEAN=$(_clean_json < "$CLI_JSON" 2>/dev/null); fi

    ACTIVE_THEME="$ACTIVE_THEME" BG="$BG" FG="$FG" ACCENT="$ACCENT" \
    SELECTION_BG="${SELECTION_BG:-}" SELECTION_FG="${SELECTION_FG:-}" LINE_HIGHLIGHT="${LINE_HIGHLIGHT:-}" \
    COLORS="$COLORS" THEME_MODE="${THEME_MODE:-THEME_MODE_DARK}" \
    THEME_JSON="$THEME_JSON" CLI_JSON="$CLI_JSON" CLI_JSON_CLEAN="$CLI_JSON_CLEAN" \
    ANSI_Black="$ANSI_Black" ANSI_Red="$ANSI_Red" ANSI_Green="$ANSI_Green" ANSI_Yellow="$ANSI_Yellow" \
    ANSI_Blue="$ANSI_Blue" ANSI_Magenta="$ANSI_Magenta" ANSI_Cyan="$ANSI_Cyan" ANSI_White="$ANSI_White" \
    ANSI_BrightBlack="$ANSI_BrightBlack" ANSI_BrightRed="$ANSI_BrightRed" ANSI_BrightGreen="$ANSI_BrightGreen" ANSI_BrightYellow="$ANSI_BrightYellow" \
    ANSI_BrightBlue="$ANSI_BrightBlue" ANSI_BrightMagenta="$ANSI_BrightMagenta" ANSI_BrightCyan="$ANSI_BrightCyan" ANSI_BrightWhite="$ANSI_BrightWhite" \
    python3 - <<'PYEOF'
import colorsys, json, os, re, sys

def g(k): return (os.environ.get(k) or "").strip()
def valid(h): return isinstance(h, str) and bool(re.match(r'^#[0-9a-fA-F]{6}$', h or ''))
def first(*vals):
    for v in vals:
        if valid(v): return v
    return ""
def rgb(h):
    h = h.lstrip('#'); return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

try: colors = json.loads(os.environ.get("COLORS") or "{}")
except Exception: colors = {}
def ckey(*keys):
    for k in keys:
        v = (colors.get(k) or "")[:7]
        if valid(v): return v
    return ""

bg, fg, accent = g("BG"), g("FG"), g("ACCENT")
if not (valid(bg) and valid(fg)):
    print("  [debug] opencode skipped: no resolved background/foreground")
    sys.exit(0)
dark = os.environ.get("THEME_MODE", "THEME_MODE_DARK") != "THEME_MODE_LIGHT"
mode = "dark" if dark else "light"
sel_bg, sel_fg, line_hl = g("SELECTION_BG"), g("SELECTION_FG"), g("LINE_HIGHLIGHT")
subtext = first(sel_fg, g("ANSI_BrightBlack"), fg)
surface = ckey("titleBar.activeBackground", "sideBar.background", "activityBar.background", "panel.background")
border = surface if (valid(surface) and surface.lower() != bg.lower()) else first(g("ANSI_BrightBlack"), subtext, fg)
sel = first(sel_bg, line_hl, surface)

# Seeds: bright variants read better on dark, normal variants on light.
if dark:
    R, Y, G, B, M, C = (first(g("ANSI_BrightRed"), g("ANSI_Red")),
        first(g("ANSI_BrightYellow"), g("ANSI_Yellow")),
        first(g("ANSI_BrightGreen"), g("ANSI_Green")),
        first(g("ANSI_BrightBlue"), g("ANSI_Blue")),
        first(g("ANSI_BrightMagenta"), g("ANSI_Magenta")),
        first(g("ANSI_BrightCyan"), g("ANSI_Cyan")))
else:
    R, Y, G, B, M, C = (first(g("ANSI_Red"), g("ANSI_BrightRed")),
        first(g("ANSI_Yellow"), g("ANSI_BrightYellow")),
        first(g("ANSI_Green"), g("ANSI_BrightGreen")),
        first(g("ANSI_Blue"), g("ANSI_BrightBlue")),
        first(g("ANSI_Magenta"), g("ANSI_BrightMagenta")),
        first(g("ANSI_Cyan"), g("ANSI_BrightCyan")))

def tohex(r, gg, b): return f'#{max(0, min(255, round(r))):02x}{max(0, min(255, round(gg))):02x}{max(0, min(255, round(b))):02x}'
def scale(seed, achromatic=False):
    if valid(seed) and not achromatic:
        r, gg, b = rgb(seed)
        h, _, s = colorsys.rgb_to_hls(r / 255, gg / 255, b / 255)
    else:
        h, s = 0.0, 0.0
    ls = [0.87, 0.77, 0.67, 0.57, 0.47, 0.39, 0.31, 0.23, 0.15]
    if not dark: ls = ls[::-1]
    out = {}
    for step, li in zip(["100", "200", "300", "400", "500", "600", "700", "800", "900"], ls):
        rr, gg2, bb = colorsys.hls_to_rgb(h, li, s)
        out[step] = tohex(rr * 255, gg2 * 255, bb * 255)
    return out

def blend(a, b):
    if not (valid(a) and valid(b)): return first(a, b)
    ra, ga, ba = rgb(a); rb, gb, bb = rgb(b)
    return tohex((ra + rb) / 2, (ga + gb) / 2, (ba + bb) / 2)

def accent_hue_name(h):
    if not valid(h): return "blue"
    r, gg, b = rgb(h)
    d, _, _ = colorsys.rgb_to_hls(r / 255, gg / 255, b / 255)
    d *= 360
    if d >= 340 or d < 20: return "red"
    if d < 45: return "orange"
    if d < 75: return "yellow"
    if d < 170: return "green"
    if d < 200: return "cyan"
    if d < 260: return "blue"
    return "purple"

hue = {
    "gray": scale("", achromatic=True),
    "red": scale(R), "orange": scale(blend(R, Y)), "yellow": scale(Y),
    "green": scale(G), "cyan": scale(C), "blue": scale(B), "purple": scale(M),
    "accent": f"$hue.{accent_hue_name(accent)}",
    "interactive": "$hue.blue", "neutral": "$hue.gray",
}
base = {
    "categorical": ["accent", "blue", "green", "purple"],
    "text": {"base": fg, "muted": subtext},
    "background": {"base": bg, "raised": {"base": first(surface, bg)}},
    "border": {"base": border},
    "diff": {"added": {"base": first(G, fg)}, "removed": {"base": first(R, fg)}},
    "syntax": {
        "comment": subtext, "keyword": first(M, fg), "function": first(B, fg),
        "variable": fg, "string": first(G, fg), "number": first(Y, fg),
        "type": first(C, fg), "operator": fg, "punctuation": subtext,
    },
    "markdown": {
        "text": fg, "heading": fg, "link": first(B, accent),
        "code": first(G, fg),
    },
}
theme = {
    "$schema": "https://opencode.ai/theme.json",
    "base": base,
    mode: {"hue": hue},
}
tj = os.environ["THEME_JSON"]
with open(tj, "w") as f: json.dump(theme, f, indent=2) ; f.write("\n")

# Structural check: reload and require a complete hue table.
d = json.load(open(tj))
hh = d.get(mode, {}).get("hue", {})
need = {"gray", "red", "orange", "yellow", "green", "cyan", "blue", "purple"}
ok = need.issubset(hh) and all(isinstance(hh[h], dict) and len(hh[h]) == 9 for h in need)
if not ok:
    print("  [warn] opencode theme failed validation")
else:
    print(f"  OpenCode theme → sync-theme ({mode}) + {len(base)} token groups ({tj})")

# Select it in cli.json, preserving every other key (pre-cleaned of
# // comments / trailing commas by _clean_json).
cj = os.environ["CLI_JSON"]
cfg = {}
raw = (os.environ.get("CLI_JSON_CLEAN") or "").strip()
if raw:
    try:
        cfg = json.loads(raw)
    except Exception:
        cfg = {}
if not isinstance(cfg, dict): cfg = {}
cfg["theme"] = {"name": "sync-theme", "mode": mode}
with open(cj, "w") as f: json.dump(cfg, f, indent=2); f.write("\n")
print("  OpenCode cli.json → theme sync-theme (restart opencode to apply)")
PYEOF
}

apply_codex() {
    # Codex TUI native themes: a sync-theme.tmTheme under $CODEX_HOME/themes,
    # selected via [tui] theme in config.toml. Replaces the dead
    # [desktop.appearanceDarkChromeTheme] block (nothing reads those keys) and
    # the daemon kill that went with it. Restart codex to apply.
    local CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
    local CODEX_CONFIG="$CODEX_HOME_DIR/config.toml"
    local THEMES_DIR="$CODEX_HOME_DIR/themes"
    mkdir -p "$THEMES_DIR"
    local TMTHEME="$THEMES_DIR/sync-theme.tmTheme"
    [ -f "$TMTHEME" ] && cp -p "$TMTHEME" "$TMTHEME.bak-$(date +%Y%m%d)" 2>/dev/null || true
    [ -f "$CODEX_CONFIG" ] && cp -p "$CODEX_CONFIG" "$CODEX_CONFIG.bak-$(date +%Y%m%d)" 2>/dev/null || true

    if [ -z "$COLORS" ]; then COLORS="{}"; fi

    ACTIVE_THEME="$ACTIVE_THEME" BG="$BG" FG="$FG" ACCENT="$ACCENT" CURSOR="${CURSOR:-}" \
    SELECTION_BG="${SELECTION_BG:-}" SELECTION_FG="${SELECTION_FG:-}" LINE_HIGHLIGHT="${LINE_HIGHLIGHT:-}" \
    COLORS="$COLORS" CODEX_CONFIG="$CODEX_CONFIG" TMTHEME="$TMTHEME" \
    ANSI_Black="$ANSI_Black" ANSI_Red="$ANSI_Red" ANSI_Green="$ANSI_Green" ANSI_Yellow="$ANSI_Yellow" \
    ANSI_Blue="$ANSI_Blue" ANSI_Magenta="$ANSI_Magenta" ANSI_Cyan="$ANSI_Cyan" ANSI_White="$ANSI_White" \
    ANSI_BrightBlack="$ANSI_BrightBlack" ANSI_BrightRed="$ANSI_BrightRed" ANSI_BrightGreen="$ANSI_BrightGreen" ANSI_BrightYellow="$ANSI_BrightYellow" \
    ANSI_BrightBlue="$ANSI_BrightBlue" ANSI_BrightMagenta="$ANSI_BrightMagenta" ANSI_BrightCyan="$ANSI_BrightCyan" ANSI_BrightWhite="$ANSI_BrightWhite" \
    python3 - <<'PYEOF'
import json, os, re, sys

def g(k): return (os.environ.get(k) or "").strip()
def valid(h): return isinstance(h, str) and bool(re.match(r'^#[0-9a-fA-F]{6}$', h or ''))
def first(*vals):
    for v in vals:
        if valid(v): return v
    return ""

bg, fg, accent = g("BG"), g("FG"), g("ACCENT")
if not (valid(bg) and valid(fg)):
    print("  [debug] codex skipped: no resolved background/foreground")
    sys.exit(0)
sel_bg, sel_fg = g("SELECTION_BG"), g("SELECTION_FG")
subtext = first(sel_fg, g("ANSI_BrightBlack"), fg)
caret = first(g("CURSOR"), fg)
green = first(g("ANSI_BrightGreen"), g("ANSI_Green"), fg)
yellow = first(g("ANSI_BrightYellow"), g("ANSI_Yellow"), fg)
red = first(g("ANSI_BrightRed"), g("ANSI_Red"), fg)
blue = first(g("ANSI_BrightBlue"), g("ANSI_Blue"), fg)
magenta = first(g("ANSI_BrightMagenta"), g("ANSI_Magenta"), fg)
cyann = first(g("ANSI_BrightCyan"), g("ANSI_Cyan"), fg)

def rule(scope, color, font_style=None):
    style = f"<key>fontStyle</key><string>{font_style}</string>" if font_style else ""
    return (f"<dict><key>name</key><string>{scope}</string>"
            f"<key>scope</key><string>{scope}</string>"
            f"<key>settings</key><dict><key>foreground</key><string>{color}</string>{style}</dict></dict>")

lh = f"<key>lineHighlight</key><string>{g('LINE_HIGHLIGHT')}</string>" if valid(g("LINE_HIGHLIGHT")) else ""
tm = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>name</key><string>Sync Theme</string>
<key>settings</key><array><dict>
<key>settings</key><dict>
<key>foreground</key><string>{fg}</string>
<key>background</key><string>{bg}</string>
<key>caret</key><string>{caret}</string>
<key>selection</key><string>{first(sel_bg, bg)}</string>
{lh}
<key>invisibles</key><string>{subtext}</string>
</dict></dict>
{rule("comment", subtext, "italic")}
{rule("keyword", magenta)}
{rule("string", green)}
{rule("constant.numeric", yellow)}
{rule("entity.name.function", blue)}
{rule("entity.name.type", cyann)}
{rule("variable", fg)}
{rule("punctuation", subtext)}
</array></dict></plist>
"""
tp = os.environ["TMTHEME"]
with open(tp, "w") as f: f.write(tm)
print(f"  Codex theme → sync-theme.tmTheme ({tp})")

# Select it via [tui] theme (config_toml.tui.theme); drop the dead
# [desktop.appearanceDarkChromeTheme] blocks this script used to write.
cp = os.environ["CODEX_CONFIG"]
if not os.path.exists(cp):
    print("  [debug] no codex config.toml — theme file written; add [tui] theme = \"sync-theme\" after onboarding")
    sys.exit(0)
with open(cp) as f: text = f.read()
if not text.endswith("\n") and text: text += "\n"
lines, out, skipping = text.splitlines(keepends=True), [], False
for line in lines:
    s = line.strip()
    if re.match(r'^\[desktop\.appearanceDarkChromeTheme(\.\w+)?\s*\]', s):
        skipping = True
        continue
    if skipping and re.match(r'^\[.*\]', s):
        skipping = False
    if skipping: continue
    if re.match(r'^appearanceDarkCodeThemeId\s*=\s*"codex"\s*$', s):
        continue
    out.append(line)
text = "".join(out)
if re.search(r'(?m)^\[tui\]\s*$', text):
    def fix_section(m):
        body = m.group(0)
        body = re.sub(r'(?m)^theme\s*=.*$', 'theme = "sync-theme"', body)
        if not re.search(r'(?m)^theme\s*=', body): body += '\ntheme = "sync-theme"'
        return body
    text = re.sub(r'(?m)^\[tui\]\s*$\n(?:^(?!\s*\[).*\n?)*', fix_section, text, count=1)
else:
    text = text.rstrip() + '\n\n[tui]\ntheme = "sync-theme"\n'
with open(cp, "w") as f: f.write(text)
print("  Codex config.toml → [tui] theme sync-theme (restart codex to apply)")
PYEOF
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

    # ── 7b. Herdr TUI (config-file driven, hot-reloaded) ───────────────────
    apply_herdr

    # ── 7c. Hermes TUI/CLI/desktop (skins/sync-theme.yaml, live repaint) ──
    apply_hermes

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
            # OpenCode editor fork: set workbench.colorTheme for its native
            # theme engine (CLI/TUI theming is handled by apply_opencode).
            set_theme_name "$SETTINGS"
            echo "Synced theme name to OpenCode (workbench.colorTheme)"
        else
            # Other forks (VS Code, Cursor, etc.) use settings.json theme
            set_theme_name "$SETTINGS"
            echo "Synced theme name to $SETTINGS"
        fi
    done

    # ── 9. OpenCode CLI/TUI v2 native theme ────────────────────────────────
    apply_opencode

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

    # ── 11. Codex TUI native theme ─────────────────────────────────────────
    apply_codex

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
    ACCENT COLORS TOKEN_FGS EXTENSION_ID
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
