#!/usr/bin/env python3
"""
OpenCode Desktop Theme Inserter.

Takes VS Code theme colors, generates OpenCode CSS variables,
and writes them into Chromium LevelDB so the Desktop app picks them up.

Usage:
  opencode_theme.py <theme-id> <bg> <fg> <ansi_0..15> [--accent ACCENT]
                     [--selection-bg SEL] [--selection-fg SEL_FG]
                     [--line-highlight LH] [--find-match-bg FM_BG]
                     [--find-match-fg FM_FG]
"""

import struct, os, sys, re, json


# ── LevelDB CRC32C (Castagnoli) with masking ─────────────────────────────────

CRC32C_TABLE = None

def _ensure_crc32c_table():
    global CRC32C_TABLE
    if CRC32C_TABLE is None:
        POLY = 0x82F63B78
        table = []
        for i in range(256):
            crc = i
            for _ in range(8):
                if crc & 1:
                    crc = (crc >> 1) ^ POLY
                else:
                    crc >>= 1
            table.append(crc)
        CRC32C_TABLE = table

def crc32c(data):
    _ensure_crc32c_table()
    crc = 0xFFFFFFFF
    for byte in data:
        crc = CRC32C_TABLE[(crc ^ byte) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF

def leveldb_crc(data):
    """Compute LevelDB's masked CRC32C."""
    raw = crc32c(data)
    return (((raw >> 15) | (raw << 17)) + 0xA282EAD8) & 0xFFFFFFFF

LEVELDB_DIR = os.environ.get("OPENCODE_LEVELDB_DIR") or os.path.expanduser(
    "~/Library/Application Support/ai.opencode.desktop/Local Storage/leveldb"
)

ORIGIN_PREFIX = b"_oc://renderer\x00\x01"
METAACCESS_KEY = b"METAACCESS:oc://renderer"
META_KEY = b"META:oc://renderer"
METAACCESS_BASE = bytes.fromhex("08e9b4d483eea0ec17")


# ── LevelDB helpers ──────────────────────────────────────────────────────────

def varint_encode(n):
    buf = bytearray()
    while n > 0x7F:
        buf.append((n & 0x7F) | 0x80)
        n >>= 7
    buf.append(n & 0x7F)
    return bytes(buf)


def make_write_batch(entries, seq):
    data = struct.pack("<Q", seq)
    data += struct.pack("<I", len(entries))
    for op_type, key, val in entries:
        data += bytes([op_type])
        data += varint_encode(len(key))
        data += key
        if op_type == 1:
            data += varint_encode(len(val))
            data += val
    return data


def make_log_record(data):
    payload = bytes([1]) + data
    checksum = leveldb_crc(payload)
    header = struct.pack("<I", checksum)
    header += struct.pack("<H", len(data))
    header += bytes([1])
    return header + data


def find_next_log_number():
    if not os.path.isdir(LEVELDB_DIR):
        print(f"LevelDB directory not found: {LEVELDB_DIR}", file=sys.stderr)
        sys.exit(1)

    # Highest file number on disk
    file_max = 0
    for fname in os.listdir(LEVELDB_DIR):
        m = re.match(r"^(\d{6})\.(log|ldb)$", fname)
        if m:
            num = int(m.group(1))
            if num > file_max:
                file_max = num

    # Highest log number referenced in MANIFEST
    manifest_max = 0
    try:
        current_path = os.path.join(LEVELDB_DIR, "CURRENT")
        with open(current_path) as f:
            manifest_name = f.read().strip()
        manifest_path = os.path.join(LEVELDB_DIR, manifest_name)
        if os.path.exists(manifest_path):
            with open(manifest_path, "rb") as f:
                mdata = f.read()
            pos = 0
            while pos + 7 <= len(mdata):
                length = struct.unpack('<H', mdata[pos+4:pos+6])[0]
                rectype = mdata[pos+6]
                record_data = mdata[pos+7:pos+7+length]
                if rectype == 1:
                    off = 0
                    while off < len(record_data):
                        tag = record_data[off]
                        off += 1
                        if tag == 0x02:  # Log number
                            log_num = 0; shift = 0
                            while off < len(record_data):
                                byte = record_data[off]; off += 1
                                log_num |= (byte & 0x7f) << shift
                                shift += 7
                                if not (byte & 0x80): break
                            if log_num > manifest_max:
                                manifest_max = log_num
                        elif tag == 0x03:  # Next file number
                            next_num = 0; shift = 0
                            while off < len(record_data):
                                byte = record_data[off]; off += 1
                                next_num |= (byte & 0x7f) << shift
                                shift += 7
                                if not (byte & 0x80): break
                            if next_num > manifest_max:
                                manifest_max = next_num
                        else:
                            # Skip unknown tags — need to skip their data too
                            if tag == 0x01:  # Comparator: varint len + string
                                skip_len = 0; shift = 0
                                while off < len(record_data):
                                    byte = record_data[off]; off += 1
                                    skip_len |= (byte & 0x7f) << shift
                                    shift += 7
                                    if not (byte & 0x80): break
                                off += skip_len
                            elif tag == 0x05:  # Compact pointer: varint level + varint len + key
                                _ = 0; shift = 0
                                while off < len(record_data):
                                    byte = record_data[off]; off += 1
                                    _ |= (byte & 0x7f) << shift
                                    shift += 7
                                    if not (byte & 0x80): break
                                skip_len = 0; shift = 0
                                while off < len(record_data):
                                    byte = record_data[off]; off += 1
                                    skip_len |= (byte & 0x7f) << shift
                                    shift += 7
                                    if not (byte & 0x80): break
                                off += skip_len
                            elif tag == 0x06:  # Deleted file: varint level + varint file
                                _ = 0; shift = 0
                                while off < len(record_data):
                                    byte = record_data[off]; off += 1
                                    _ |= (byte & 0x7f) << shift
                                    shift += 7
                                    if not (byte & 0x80): break
                                _ = 0; shift = 0
                                while off < len(record_data):
                                    byte = record_data[off]; off += 1
                                    _ |= (byte & 0x7f) << shift
                                    shift += 7
                                    if not (byte & 0x80): break
                            elif tag == 0x07 or tag == 0x09:  # New file/V2: varint level + file + size + (smallest key) + (largest key)
                                for _ in range(3):
                                    _skip = 0; shift = 0
                                    while off < len(record_data):
                                        byte = record_data[off]; off += 1
                                        _skip |= (byte & 0x7f) << shift
                                        shift += 7
                                        if not (byte & 0x80): break
                                # Two internal keys (each: varint len + data + seq)
                                for _ in range(2):
                                    skip_len = 0; shift = 0
                                    while off < len(record_data):
                                        byte = record_data[off]; off += 1
                                        skip_len |= (byte & 0x7f) << shift
                                        shift += 7
                                        if not (byte & 0x80): break
                                    off += skip_len + 8  # key data + sequence number
                            elif tag == 0x08:  # Prev log number: varint
                                _ = 0; shift = 0
                                while off < len(record_data):
                                    byte = record_data[off]; off += 1
                                    _ |= (byte & 0x7f) << shift
                                    shift += 7
                                    if not (byte & 0x80): break
                            else:
                                break  # Unknown — stop parsing this record
                pos += 7 + length
    except Exception:
        pass  # If MANIFEST parsing fails, use file_max only

    return max(file_max, manifest_max) + 1


def make_meta(css_len):
    """Build correct META bytes reflecting actual stored data."""
    # Chromium protobuf: message LocalStorageMeta {
    #   optional int64 last_modified = 1;
    #   optional int64 total_length = 2;  // sum of all value lengths (incl \x01 prefix)
    # }
    # Value sizes: theme-id (7 bytes) + css-dark (1 + css_len) + css-light (1 + css_len)
    total_len = 7 + (1 + css_len) + (1 + css_len)
    # Keep field 1 (last_modified) from default; update field 2 (total_length)
    return bytes([0x08]) + bytes.fromhex("fcd5e99deea0ec17") + bytes([0x10]) + varint_encode(total_len)

def write_leveldb_reset():
    """Reset LevelDB to default state — preload sees oc-2 and exits.
    
    Deletes ALL custom keys we may have written. After reset, only
    settings.json (workbench.colorTheme) controls the theme via the
    native VS Code theme engine (editor) and default oc-2 desktop shell.
    """
    entries = [
        # Delete ALL keys we or the app may have set for our origin
        (0, ORIGIN_PREFIX + b"opencode-theme-id", b""),
        (0, ORIGIN_PREFIX + b"opencode-theme-css-dark", b""),
        (0, ORIGIN_PREFIX + b"opencode-theme-css-light", b""),
        (0, ORIGIN_PREFIX + b"opencode-color-scheme", b""),
        # Set theme-id to oc-2 (default) — preload exits immediately
        (1, ORIGIN_PREFIX + b"opencode-theme-id", b"\x01oc-2"),
        (1, METAACCESS_KEY, METAACCESS_BASE),
        # After reset: only "theme-id" = "oc-2" (5 bytes with \x01) exists
        (1, META_KEY, bytes([0x08]) + bytes.fromhex("fcd5e99deea0ec17") + bytes([0x10]) + varint_encode(5)),
    ]
    log_num = find_next_log_number()
    log_path = os.path.join(LEVELDB_DIR, f"{log_num:06d}.log")
    batch = make_write_batch(entries, seq=999)  # high seq to win
    record = make_log_record(batch)
    with open(log_path, "wb") as f:
        f.write(record)
    print(f"  LevelDB reset journal: {os.path.basename(log_path)}")
    print(f"  Theme reset to oc-2 (default) — preload will not inject custom CSS")

def write_leveldb(theme_id, css_dark, css_light):
    # Build META that reflects actual data sizes
    css_len = len(css_dark)
    meta = make_meta(css_len)
    entries = [
        (0, ORIGIN_PREFIX + b"opencode-theme-id", b""),
        (0, ORIGIN_PREFIX + b"opencode-theme-css-dark", b""),
        (0, ORIGIN_PREFIX + b"opencode-theme-css-light", b""),
        (0, ORIGIN_PREFIX + b"opencode-color-scheme", b""),
        (1, ORIGIN_PREFIX + b"opencode-theme-id", b"\x01" + theme_id.encode()),
        (1, ORIGIN_PREFIX + b"opencode-theme-css-dark", b"\x01" + css_dark.encode()),
        (1, ORIGIN_PREFIX + b"opencode-theme-css-light", b"\x01" + css_light.encode()),
        (1, ORIGIN_PREFIX + b"opencode-color-scheme", b"\x01system"),
        (1, METAACCESS_KEY, METAACCESS_BASE),
        (1, META_KEY, meta),
    ]
    log_num = find_next_log_number()
    log_path = os.path.join(LEVELDB_DIR, f"{log_num:06d}.log")
    batch = make_write_batch(entries, seq=116)
    record = make_log_record(batch)
    with open(log_path, "wb") as f:
        f.write(record)
    print(f"  LevelDB journal: {os.path.basename(log_path)}")


# ── Color helpers ────────────────────────────────────────────────────────────

def hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))


def rgb_to_hex(r, g, b):
    return f"#{max(0,min(255,round(r))):02x}{max(0,min(255,round(g))):02x}{max(0,min(255,round(b))):02x}"


def blend(hex1, hex2, t):
    r1, g1, b1 = hex_to_rgb(hex1)
    r2, g2, b2 = hex_to_rgb(hex2)
    return rgb_to_hex(r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t)


def darken(hex_color, amount):
    r, g, b = hex_to_rgb(hex_color)
    return rgb_to_hex(r * (1 - amount), g * (1 - amount), b * (1 - amount))


def lighten(hex_color, amount):
    return blend(hex_color, "#ffffff", amount)


def is_dark(hex_color):
    r, g, b = hex_to_rgb(hex_color)
    return (r * 0.299 + g * 0.587 + b * 0.114) < 128


def with_alpha(hex_color, alpha):
    r, g, b = hex_to_rgb(hex_color)
    return f"rgba({r}, {g}, {b}, {alpha})"


# ── Contrast + purpose-based harmonization ───────────────────────────────────
# Ensures every foreground color (FG, ANSI 0-15, accent, cursor) meets WCAG
# contrast against BG by substituting a same-hue theme color or, failing that,
# shifting lightness while preserving hue/saturation. Never snaps to pure
# white/black; the closest passing lightness is used instead.

MIN_CONTRAST = 4.5

def _rel_lum(h):
    h = h.lstrip("#")[:6]
    r, g, b = int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255

    def lin(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def contrast_ratio(fg, bg):
    try:
        l1, l2 = _rel_lum(fg), _rel_lum(bg)
    except (ValueError, IndexError):
        return 0.0
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


def _valid_hex(h):
    return isinstance(h, str) and bool(re.match(r"^#[0-9a-fA-F]{6}$", h or ""))


def _hue_bucket(h):
    """Classify a hex color into a hue family (or 'neutral' if desaturated)."""
    import colorsys
    try:
        r, g, b = hex_to_rgb(h)
    except (ValueError, IndexError):
        return "neutral"
    rn, gn, bn = r / 255, g / 255, b / 255
    hl, li, sa = colorsys.rgb_to_hls(rn, gn, bn)
    if sa < 0.15:
        return "neutral"
    # Near-white / near-black are functionally neutral text colors even when
    # slightly warm (e.g. Dracula #f8f8f2 reads yellow in HLS at li=0.96).
    if li > 0.90 or li < 0.10:
        return "neutral"
    deg = hl * 360
    if deg >= 340 or deg < 20:
        return "red"
    if deg < 45:
        return "orange"
    if deg < 75:
        return "yellow"
    if deg < 170:
        return "green"
    if deg < 200:
        return "cyan"
    if deg < 260:
        return "blue"
    if deg < 295:
        return "purple"
    return "magenta"


# ANSI slot -> acceptable hue families (purpose mapping)
_SLOT_BUCKETS = {
    0: {"neutral"}, 8: {"neutral"},
    1: {"red"}, 9: {"red"},
    2: {"green"}, 10: {"green"},
    3: {"orange", "yellow"}, 11: {"orange", "yellow"},
    4: {"blue"}, 12: {"blue"},
    5: {"purple", "magenta"}, 13: {"purple", "magenta"},
    6: {"cyan"}, 14: {"cyan"},
    7: {"neutral"}, 15: {"neutral"},
}


def _adjust_lightness_to_pass(color, bg, min_contrast=MIN_CONTRAST):
    """Sweep HLS lightness to find the closest passing color, hue preserved."""
    import colorsys
    if contrast_ratio(color, bg) >= min_contrast:
        return color
    try:
        r, g, b = hex_to_rgb(color)
    except (ValueError, IndexError):
        return color
    rn, gn, bn = r / 255, g / 255, b / 255
    h, _, s = colorsys.rgb_to_hls(rn, gn, bn)
    try:
        _, orig_l, _ = colorsys.rgb_to_hls(rn, gn, bn)
    except Exception:
        orig_l = 0.5
    best = None
    best_dist = None
    for i in range(0, 101):
        li = i / 100
        rr, gg, bb = colorsys.hls_to_rgb(h, li, s)
        cand = rgb_to_hex(rr * 255, gg * 255, bb * 255)
        if contrast_ratio(cand, bg) >= min_contrast:
            dist = abs(li - orig_l)
            if best_dist is None or dist < best_dist:
                best_dist = dist
                best = cand
    return best or color


def _pick_readable(original, hue_pool, bg, min_contrast=MIN_CONTRAST, want=None):
    """Return original if readable *and* purpose-correct, else substitute.

    want: set of acceptable hue buckets (e.g. {'neutral'} for FG). A passing
    original of the wrong hue (purple FG, ...) is replaced, not kept.
    """
    if (_valid_hex(original) and contrast_ratio(original, bg) >= min_contrast
            and (want is None or _hue_bucket(original) in want)):
        return original
    passing = [c for c in dict.fromkeys(hue_pool) if _valid_hex(c)
               and contrast_ratio(c, bg) >= min_contrast
               and (want is None or _hue_bucket(c) in want)]
    if passing:
        return max(passing, key=lambda c: contrast_ratio(c, bg))
    # Nothing in-pool passes: shift the strongest purpose-correct candidate.
    cands = [c for c in hue_pool if _valid_hex(c)
             and (want is None or _hue_bucket(c) in want)]
    if cands:
        return _adjust_lightness_to_pass(
            max(cands, key=lambda c: contrast_ratio(c, bg)), bg, min_contrast)
    if _valid_hex(original):
        return _adjust_lightness_to_pass(original, bg, min_contrast)
    return original


def harmonize_palette(bg, fg, ansi, accent=None, theme_pool=None):
    """Harmonize FG + 16 ANSI + accent against BG. Returns (fg, ansi, accent).

    theme_pool: extra theme colors (tokenColors, .colors values) used as
    same-hue substitution candidates. Never invents pure white/black; the
    lightness sweep preserves the source hue instead.
    """
    ansi = list(ansi or [])
    while len(ansi) < 16:
        ansi.append("")
    pool = [c for c in (theme_pool or []) if _valid_hex(c)]
    pool += [c for c in ansi if _valid_hex(c)]
    if _valid_hex(accent):
        pool.append(accent)

    bucketed = {}
    for c in pool:
        bucketed.setdefault(_hue_bucket(c), []).append(c)

    # Foreground: neutral-purpose only (never keep a passing accent hue).
    fg_pool = bucketed.get("neutral", []) + ([fg] if _valid_hex(fg) else [])
    new_fg = _pick_readable(fg, fg_pool, bg, want={"neutral"}) if _valid_hex(fg) else fg

    new_ansi = []
    for i in range(16):
        orig = ansi[i] if i < len(ansi) and _valid_hex(ansi[i]) else ""
        if not orig:
            # Empty slot (e.g. theme defines no terminal.ansi*): seed from the
            # same-hue theme pool, else fall back to FG so Ghostty always gets
            # a readable entry instead of an inherited default.
            same = []
            for b in _SLOT_BUCKETS.get(i, {"neutral"}):
                same += bucketed.get(b, [])
            if same:
                orig = max(same, key=lambda c: contrast_ratio(c, bg))
            else:
                orig = new_fg if _valid_hex(new_fg) else bg
        want = _SLOT_BUCKETS.get(i, {"neutral"})
        hue_pool = []
        for b in want:
            hue_pool += bucketed.get(b, [])
        # Bright variants (8-15) may also borrow from their normal counterpart.
        if i >= 8 and i - 8 < len(ansi) and _valid_hex(ansi[i - 8]):
            hue_pool.append(ansi[i - 8])
        new_ansi.append(_pick_readable(orig, hue_pool, bg, want=want))

    new_accent = accent
    if _valid_hex(accent):
        want = {_hue_bucket(accent)}
        hue_pool = []
        for b in want:
            hue_pool += bucketed.get(b, [])
        new_accent = _pick_readable(accent, hue_pool, bg)

    return new_fg, new_ansi, new_accent


# ── CSS generation ───────────────────────────────────────────────────────────

def generate_css(bg, fg, ansi, accent=None, selection_bg=None, selection_fg=None,
                 line_highlight=None, find_match_bg=None, find_match_fg=None):
    dark = is_dark(bg)

    a_black, a_red, a_green, a_yellow, a_blue, a_magenta, a_cyan, a_white = ansi[:8]
    a_bblack, a_bred, a_bgreen, a_byellow, a_bblue, a_bmagenta, a_bcyan, a_bwhite = ansi[8:16] if len(ansi) >= 16 else (["#000000"] * 8) + (["#ffffff"] * 8)

    if not accent:
        accent = a_blue or a_bblue or "#3b7dd8"

    surface = lighten(bg, 0.08) if dark else darken(bg, 0.04)
    surface_hover = lighten(bg, 0.14) if dark else darken(bg, 0.08)
    surface_raised = lighten(bg, 0.04) if dark else bg
    surface_inset = surface

    text_weak = blend(fg, bg, 0.4)
    text_weaker = blend(fg, bg, 0.25)
    text_strong = a_white if dark else "#000000"

    border_base = with_alpha(fg if dark else bg, 0.15) if dark else with_alpha(fg if not dark else bg, 0.12)
    border_hover = with_alpha(fg if dark else bg, 0.25) if dark else with_alpha(fg if not dark else bg, 0.2)

    interactive = accent
    success = a_green or a_bgreen or "#3d9a57"
    warning = a_yellow or a_byellow or "#d68c27"
    error_c = a_red or a_bred or "#d1383d"
    info = a_cyan or a_bcyan or "#318795"

    def syn(c):
        return c or blend(fg, bg, 0.6)

    return f"""--background-base: {bg};
  --background-weak: {lighten(bg, 0.04) if dark else darken(bg, 0.02)};
  --background-strong: {bg};
  --background-stronger: {darken(bg, 0.04) if dark else "#fcfcfc"};
  --surface-base: {surface};
  --base: {surface};
  --surface-base-hover: {surface_hover};
  --surface-base-active: {surface_hover};
  --surface-base-interactive-active: {with_alpha(interactive, 0.3)};
  --base2: {surface};
  --base3: {surface};
  --surface-inset-base: {surface};
  --surface-inset-base-hover: {surface_hover};
  --surface-inset-strong: {with_alpha(bg, 0.5) if dark else with_alpha(surface_hover, 0.09)};
  --surface-raised-base: {surface_raised};
  --surface-float-base: {darken(bg, 0.05) if dark else "#ffffff"};
  --surface-float-base-hover: {lighten(bg, 0.02) if dark else "#f5f5f5"};
  --surface-raised-base-hover: {surface};
  --surface-raised-base-active: {surface_hover};
  --surface-weak: {with_alpha(fg, 0.06) if dark else with_alpha(fg, 0.04)};
  --surface-weaker: {with_alpha(fg, 0.04) if dark else with_alpha(fg, 0.03)};
  --surface-strong: {with_alpha(fg, 0.12) if dark else "#ffffff"};
  --surface-raised-stronger-non-alpha: {lighten(bg, 0.08) if dark else "#ffffff"};
  --surface-interactive-base: {interactive};
  --surface-interactive-hover: {lighten(interactive, 0.1) if dark else darken(interactive, 0.1)};
  --surface-interactive-weak: {with_alpha(interactive, 0.15)};
  --input-base: {lighten(bg, 0.06) if dark else bg};
  --input-hover: {lighten(bg, 0.1) if dark else lighten(bg, 0.02)};
  --input-active: {lighten(interactive, 0.15) if dark else darken(interactive, 0.05)};
  --text-base: {fg};
  --text-weak: {text_weak};
  --text-weaker: {text_weaker};
  --text-strong: {text_strong};
  --text-invert-base: {darken(fg, 0.8) if dark else lighten(fg, 0.8)};
  --text-interactive-base: {interactive};
  --border-base: {border_base};
  --border-hover: {border_hover};
  --border-weak-base: {with_alpha(fg, 0.08) if dark else with_alpha(fg, 0.06)};
  --border-strong-base: {border_hover};
  --border-interactive-base: {interactive};
  --icon-base: {text_weak};
  --icon-hover: {fg};
  --icon-weak-base: {text_weaker};
  --button-primary-base: {text_strong};
  --color-primary: {interactive};
  --color-background-base: {bg};
  --color-background-weak: {lighten(bg, 0.04) if dark else darken(bg, 0.02)};
  --color-background-strong: {bg};
  --color-background-stronger: {darken(bg, 0.04) if dark else "#fcfcfc"};
  --color-text-base: {fg};
  --color-text-weak: {text_weak};
  --color-text-strong: {text_strong};
  --color-surface-base: {surface};
  --color-surface-raised-base: {surface_raised};
  --color-surface-weak: {with_alpha(fg, 0.06) if dark else with_alpha(fg, 0.04)};
  --syntax-comment: {syn(a_black or a_bblack)};
  --syntax-keyword: {syn(a_magenta or a_bmagenta)};
  --syntax-string: {syn(a_green or a_bgreen)};
  --syntax-primitive: {accent};
  --syntax-variable: {syn(a_red or a_bred)};
  --syntax-property: {syn(a_cyan or a_bcyan)};
  --syntax-type: {syn(a_yellow or a_byellow)};
  --syntax-constant: {syn(a_magenta or a_bmagenta)};
  --syntax-operator: {text_weak};
  --syntax-punctuation: {fg};
  --syntax-object: {fg};
  --syntax-function: {accent};
  --syntax-regexp: {syn(a_red or a_bred)};
  --syntax-diff-add: {syn(a_green or a_bgreen)};
  --syntax-diff-delete: {syn(a_red or a_bred)};
  --syntax-success: {success};
  --syntax-warning: {warning};
  --syntax-critical: {error_c};
  --syntax-info: {info};
  --markdown-heading: {accent};
  --markdown-text: {fg};
  --markdown-link: {interactive};
  --markdown-link-text: {info};
  --markdown-code: {success};
  --markdown-block-quote: {warning};
  --markdown-emph: {warning};
  --markdown-strong: {syn(a_magenta or a_bmagenta)};
  --markdown-horizontal-rule: {border_base};
  --markdown-list-item: {interactive};
  --markdown-list-enumeration: {info};
  --markdown-image: {interactive};
  --markdown-image-text: {info};
  --markdown-code-block: {fg};
  --text-diff-add-base: {success};
  --text-diff-delete-base: {error_c};
  --icon-diff-add-base: {success};
  --icon-diff-delete-base: {error_c};
  --surface-diff-add-base: {with_alpha(success, 0.15)};
  --surface-diff-delete-base: {with_alpha(error_c, 0.15)};
  --color-syntax-property: {syn(a_cyan or a_bcyan)};
  --color-syntax-type: {syn(a_yellow or a_byellow)};"""


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    args = sys.argv[1:]

    # --reset: reset LevelDB to default state (no custom CSS)
    if "--reset" in args:
        write_leveldb_reset()
        print("  Reset complete — restart OpenCode Desktop for default theme.")
        return

    if len(args) < 18:
        print(f"Usage: {sys.argv[0]} <bg> <fg> <accent> <sel_bg> <sel_fg> <line_hl> <find_bg> <find_fg> <ansi_0..15...>", file=sys.stderr)
        print(f"  Provide at least 16 ANSI color values (0-15).", file=sys.stderr)
        sys.exit(1)

    bg = args[0]
    fg = args[1]
    accent = args[2]
    selection_bg = args[3]
    selection_fg = args[4]
    line_highlight = args[5]
    find_match_bg = args[6]
    find_match_fg = args[7]
    ansi = args[8:24]  # 16 ANSI colors

    # Purpose-based + contrast-based substitution: keep theme intent by
    # preferring same-hue theme colors, else shift lightness (never snap to
    # pure white/black). Theme pool here is limited to what was passed in.
    fg, ansi, accent = harmonize_palette(bg, fg, ansi, accent,
                                         theme_pool=list(ansi) + [fg, accent])

    # Pick a built-in theme ID that matches the BG luminosity.
    # The app's oc-theme-preload.js needs a KNOWN theme to provide a
    # complete base CSS variable set; we then override specific variables.
    import zlib
    is_bg_dark = is_dark(bg)
    # Light built-in themes (that look reasonable as base)
    LIGHT_BUILTINS = ["github", "mercury", "solarized", "vercel"]
    # Dark built-in themes
    DARK_BUILTINS = ["nord", "monokai", "dracula", "tokyonight", "one-dark", "material"]
    pool = LIGHT_BUILTINS if not is_bg_dark else DARK_BUILTINS
    theme_index = zlib.crc32((bg + fg).encode()) % len(pool)
    theme_id = pool[theme_index]

    css_dark = generate_css(bg, fg, ansi, accent, selection_bg, selection_fg,
                           line_highlight, find_match_bg, find_match_fg)
    css_light = generate_css(bg, fg, ansi, accent, selection_bg, selection_fg,
                            line_highlight, find_match_bg, find_match_fg)

    write_leveldb(theme_id, css_dark, css_light)
    print(f"  Theme ID: {theme_id} (overwritten)")
    print(f"  Done — opencode-theme-id set to '{theme_id}'")
    print(f"  Restart OpenCode Desktop to see the new theme.")


if __name__ == "__main__":
    main()
