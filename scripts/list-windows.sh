#!/bin/bash
# List all visible windows with their IDs, app names, titles, and sizes
# Output: JSON array for Claude to pick the right window

python3.11 -c "
import Quartz, json

SKIP_APPS = {'window server', 'systemuiserver', 'control center',
             'notification center', 'dock', 'spotlight'}

windows = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID
)

result = []
for w in windows:
    owner = w.get('kCGWindowOwnerName', '')
    name = w.get('kCGWindowName', '')
    layer = w.get('kCGWindowLayer', 999)
    bounds = w.get('kCGWindowBounds', {})
    width = int(bounds.get('Width', 0))
    height = int(bounds.get('Height', 0))
    if width < 200 or height < 200 or layer != 0:
        continue
    if owner.lower() in SKIP_APPS:
        continue
    result.append({
        'id': w['kCGWindowNumber'],
        'app': owner,
        'title': name,
        'size': f'{width}x{height}'
    })

print(json.dumps(result, ensure_ascii=False, indent=2))
"
