#!/bin/bash
# Capture a specific application window instead of full screen
# Skips if screenshot is similar to the previous one
# Usage: capture-window.sh <output_path> [app_name_keyword] [prev_screenshot_path]

OUTPUT="$1"
APP_KEYWORD="${2:-}"
PREV_SCREENSHOT="${3:-}"

# Check for dynamic focus target (set by Claude based on conversation context)
# .focus_target can contain either a window ID (numeric) or a keyword
SESSION_DIR="$(dirname "$(dirname "$OUTPUT")")"
FOCUS_FILE="${SESSION_DIR}/.focus_target"
FOCUS_WINDOW_ID=""
if [ -z "$APP_KEYWORD" ] && [ -f "$FOCUS_FILE" ]; then
    FOCUS_VAL="$(cat "$FOCUS_FILE" 2>/dev/null)"
    if [[ "$FOCUS_VAL" =~ ^[0-9]+$ ]]; then
        # It's a window ID - use directly
        FOCUS_WINDOW_ID="$FOCUS_VAL"
    else
        APP_KEYWORD="$FOCUS_VAL"
    fi
fi

# If we have a direct window ID, use it
if [ -n "$FOCUS_WINDOW_ID" ]; then
    WINDOW_ID="$FOCUS_WINDOW_ID"
else

# Get window ID using Python + Quartz
WINDOW_ID=$(python3.11 -c "
import Quartz

keyword = '$APP_KEYWORD'.lower()

# Meeting/video apps to auto-detect (priority order)
MEETING_APPS = ['zoom.us', 'microsoft teams', 'slack huddle', 'lark', 'feishu',
                'webex', 'skype', 'discord', 'facetime']
VIDEO_KEYWORDS = ['meet', 'meeting', 'zoom', 'teams', 'huddle', 'call']
BROWSER_VIDEO = ['google meet', 'zoom', 'youtube', 'bilibili', 'twitch', 'netflix']
SKIP_APPS = {'finder', 'window server', 'systemuiserver', 'control center',
             'notification center', 'dock', 'spotlight'}

windows = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID
)

candidates = []
for w in windows:
    owner = w.get('kCGWindowOwnerName', '')
    name = w.get('kCGWindowName', '')
    layer = w.get('kCGWindowLayer', 999)
    bounds = w.get('kCGWindowBounds', {})
    width = bounds.get('Width', 0)
    height = bounds.get('Height', 0)
    if width < 200 or height < 200 or layer != 0:
        continue
    if owner.lower() in SKIP_APPS:
        continue
    area = width * height
    candidates.append({'id': w['kCGWindowNumber'], 'owner': owner, 'name': name, 'area': area})

if not candidates:
    exit(1)

result = None

# 1. If user specified a keyword, use it (skip terminal windows)
TERMINAL_APPS = {'ghostty', 'terminal', 'iterm2', 'warp', 'alacritty', 'kitty'}
if keyword:
    # Prefer browser/app windows over terminals when matching keyword
    keyword_matches = [c for c in candidates
                       if (keyword in c['owner'].lower() or keyword in c['name'].lower())
                       and c['owner'].lower() not in TERMINAL_APPS]
    if not keyword_matches:
        # Fall back to any match including terminals
        keyword_matches = [c for c in candidates
                           if keyword in c['owner'].lower() or keyword in c['name'].lower()]
    if keyword_matches:
        result = keyword_matches[0]['id']

# 2. Auto-detect meeting apps
if not result:
    for c in candidates:
        owner_l = c['owner'].lower()
        if any(app in owner_l for app in MEETING_APPS):
            result = c['id']
            break

# 3. Auto-detect browser tabs with meeting/video content
if not result:
    for c in candidates:
        name_l = c['name'].lower()
        if any(v in name_l for v in BROWSER_VIDEO):
            result = c['id']
            break

# 4. Fallback: largest non-terminal window
if not result:
    skip_fallback = {'ghostty', 'terminal', 'iterm2', 'warp', 'alacritty', 'kitty'}
    non_term = [c for c in candidates if c['owner'].lower() not in skip_fallback]
    if non_term:
        result = max(non_term, key=lambda c: c['area'])['id']
    else:
        result = max(candidates, key=lambda c: c['area'])['id']

print(result)
" 2>/dev/null)

fi  # end of else block (no direct window ID)

TMP_OUTPUT="${OUTPUT}.tmp.png"

if [ -z "$WINDOW_ID" ]; then
    screencapture -x "$TMP_OUTPUT"
else
    screencapture -x -l "$WINDOW_ID" "$TMP_OUTPUT"
fi

# Compare with previous screenshot - skip if too similar
if [ -n "$PREV_SCREENSHOT" ] && [ -f "$PREV_SCREENSHOT" ] && [ -f "$TMP_OUTPUT" ]; then
    # Use sips to get basic file size comparison as a quick heuristic,
    # then use python for pixel-level diff if sizes are close
    DIFF=$(python3.11 -c "
from PIL import Image
import sys
try:
    img1 = Image.open('$PREV_SCREENSHOT').resize((160,90)).convert('L')
    img2 = Image.open('$TMP_OUTPUT').resize((160,90)).convert('L')
    pixels1 = list(img1.getdata())
    pixels2 = list(img2.getdata())
    diff = sum(abs(a-b) for a,b in zip(pixels1,pixels2)) / len(pixels1)
    print(f'{diff:.1f}')
except:
    print('999')
" 2>/dev/null)

    if [ "$(echo "$DIFF < 5.0" | bc 2>/dev/null)" = "1" ]; then
        # Too similar, skip
        rm -f "$TMP_OUTPUT"
        exit 1
    fi
fi

mv "$TMP_OUTPUT" "$OUTPUT"
