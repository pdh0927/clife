# clife

[한국어](README.md)

A macOS menu bar app that shows your Claude Code plan usage limits as a small ring gauge. Built because checking whether the 5-hour limit was about to run out meant going and looking, every time.

It calls **the same API, the same way, as the usage popup you get from Claude's own menu bar icon** — so the numbers always agree with it: the 5-hour limit, the weekly all-models limit, and the weekly per-model limit (Fable, etc.).

**Not an official Anthropic product.** A personal side project, no affiliation. "Claude"/"Claude Code" appear only to describe where the data comes from.

**Needs a Claude Pro or Max subscription** — other plans come back with the limits list empty.

## How it works

One call: `GET https://api.anthropic.com/api/oauth/usage`. The `limits` array in the response *is* the dropdown:

```json
{"limits":[
  {"kind":"session",      "group":"session","percent":17,"resets_at":"..."},
  {"kind":"weekly_all",   "group":"weekly", "percent":36,"resets_at":"..."},
  {"kind":"weekly_scoped","group":"weekly", "percent":39,"resets_at":"...",
   "scope":{"model":{"display_name":"Fable"}}}
]}
```

The app renders that array **verbatim** rather than cherry-picking two known fields, so when Anthropic adds a new limit — per-model, per-surface, whatever — it shows up here the same day, with no code change.

The auth token is read from the `Claude Code-credentials` login-keychain item that Claude Code maintains. **Read only** — refreshing is left to Claude Code. Rotating the token ourselves and writing it back would race with whatever Claude Code process is doing the same thing, and losing that race invalidates the refresh token outright. The token is cached in memory until just before it expires; spawning `security` costs ~25ms and there's no reason to pay that on every poll.

### Call frequency

**This endpoint is rate limited hard.** A handful of calls within a few seconds gets a `429` with `Retry-After: 296`, and once the budget is drained, **two calls sixteen seconds apart** are enough to be refused. So the budget has to be spent deliberately.

The priority is not subtle: **if someone is looking, fetch; save the budget for when nobody is.**

| Trigger | Condition |
|---|---|
| **Pointer enters the menu bar** | after 0.3s of dwell, then **immediately** (past cache and backoff) |
| Dropdown opens | **immediately** (past cache and backoff) |
| "Refresh" menu item | **immediately** (past cache and backoff) |
| Wake from sleep | immediately |
| Timer (idle) | 10 minutes, and takes a cached response under 30s old |

On-demand fetches have only a five-second floor. A pointer wandering in and out of the menu bar crosses the band several times a second, and that is mouse travel, not a question. Any real look is further apart than that, so in practice **looking at the rings always fetches**.

Going past the backoff too is deliberate. A 429 is refused in about 30ms and does not observably extend the block — its `Retry-After` counts down whether or not you keep asking. The cost of trying is one round trip; the cost of not trying is a stale number in front of the person who came to read it.

The background poll sits at ten minutes for the same reason. There is one budget, and spending it on ticks nobody is watching means the request that fires because a human just moved the pointer is the one that gets refused. The background exists to keep the threshold notifications alive, nothing more.

The prefetch triggers on **entering the menu bar**, not on hovering the icon. What people actually read is the ring, and a ring is glanced at, not aimed at — waiting for the pointer to land on a 20pt target would miss nearly every look. Under a fullscreen app it's starker still: the menu bar stays hidden until the pointer is pushed to the top edge, and **that push is the moment the icon starts to become visible**. Starting the request there means the ring has caught up by the time the bar finishes animating in.

It's a global mouse monitor rather than a tracking area on the status item: mouse-move monitors need no accessibility permission, and this has to work while the menu bar — and therefore the button — is still hidden, which a tracking area on that button cannot do. The band crossing is edge-triggered, so it doesn't re-arm on every one of the ~100 events a second a moving mouse produces.

Background failures do back off. A 429 treats the server's `Retry-After` as a **floor** — the endpoint really does hand out `Retry-After: 0` while still refusing everything, and believing that number as a ceiling means hammering a wall every 30 seconds — and layers 30s → 60 → 120 → 240 → 480 → 900 on top. Other failures (network, 5xx) stop at the poll interval. While waiting, the line under the rows says when it will try again (`요청 제한 · 3분 후 재시도`). None of this applies to a fetch a person asked for.

One call takes ~0.3s, almost entirely time-to-first-byte (URLSession reuses the connection). Idle background cost is 6 calls/hour × 2.4KB ≈ **15KB/hour**.

### Why the statusline approach was dropped

v1 injected a snippet into `statusline.sh` to write `~/.claude/usage-status.json`, and the app watched that file. The file watching worked fine; the **data source was wrong**:

- `rate_limits` in the statusLine hook JSON is an echo of the previous API response, so it drifted a percentage point off the real value.
- The per-model weekly limit isn't in the hook JSON at all — only two rows were ever possible.
- It updated only when an interactive Claude Code session drew its prompt. Close the terminal and the number froze; usage burned by `claude -p` cron jobs never showed up at all.
- On a fresh session, `rate_limits` was absent entirely until the first API response, so the app kept showing values from days ago with no indication.

Calling the API directly removes all four. `install.sh` and `statusline-snippet.sh` are gone with it — there is nothing left to wire into statusline.

## Install

```sh
git clone <this-repo> clife
cd clife
./setup.sh
```

Builds, installs into `/Applications`, and launches. Two things get in the way on first run:

1. **Gatekeeper warning** — right-click the app in `/Applications` → Open → Open, once. See below.
2. **Keychain access prompt** — it asks whether the app may read `Claude Code-credentials`. Choose "Always Allow" and it won't ask again.

If you only changed Swift code, `./build.sh` on its own is enough.

To install/reinstall into `/Applications` by hand:

```sh
pkill -f Clife.app/Contents/MacOS/Clife 2>/dev/null
rm -r -f /Applications/Clife.app
ditto Clife.app /Applications/Clife.app   # not cp -R, see below
open /Applications/Clife.app
```

Don't use `cp -R` here — if `/Applications/Clife.app` already exists it copies *into* it, nesting the bundle, and the app looks updated while nothing actually changed. Learned that one the hard way. `ditto` handles both cases correctly.

### Gatekeeper warning

The app is signed locally (ad-hoc, or with a free Apple Development certificate if Xcode has one) but not notarized by Apple, so the first double-click is refused. Right-click the app in `/Applications` → Open → Open, once. macOS remembers after that, including for launch-at-login.

### Why the keychain prompt doesn't come back on every build

Keychain ACL grants are remembered **per code signature**. This app is ad-hoc signed, so its signature changes on every `./build.sh` — calling `SecItemCopyMatching` in-process would re-prompt after each rebuild. Reading the token is therefore delegated to `/usr/bin/security`, an Apple-signed binary with a stable signature, so one "Always Allow" survives rebuilds.

## Uninstall

```sh
pkill -f Clife.app/Contents/MacOS/Clife
rm -r -f /Applications/Clife.app
```

The app leaves `~/Library/Preferences/com.example.clife.plist` (display mode, widget state, widget position) and `~/Library/Caches/com.example.clife/` (the last response, plus the dog art attached to notifications). Delete the directory to be rid of both. If you're upgrading from v1, also delete the `# >>> clife` … `# <<< clife` block in `~/.claude/statusline.sh` and `~/.claude/usage-status.json` — the new version uses neither.

## Display mode

The dropdown offers "icon" and "text" (e.g. `54%/29%`, which is what the first prototype looked like). The choice is persisted across launches. Icon is the default.

## Raycast hotkey (optional)

Under a fullscreen app the menu bar isn't visible at all. `raycast/claude-usage.py` puts the numbers on screen from a hotkey, without reaching for the top edge:

```
5시간 29%  ·  주간 38%  ·  Fable 40%  ·  34분 후 초기화
```

Setup: Raycast → Extensions → Scripts → **Add Script Directory**, point it at this repo's `raycast/` folder, then assign a hotkey to "Claude 사용량". Standard library only — no `pip`, no `jq`.

If you keep all your Raycast scripts in one place, register only that folder and symlink this one into it — the script stays versioned with this repo, and Raycast only has to know one path:

```sh
ln -sf "$PWD/raycast/claude-usage.py" ~/workspace/raycast/claude-usage.py
```

Pressing the hotkey means "tell me now", so the script follows the same rule as the app — **it fetches every time.** The five-second floor is anti-double-tap and nothing else. A failed lookup falls back to the last value, tagged with its age and the reason (`334초 전 값 · 요청 제한`).

The cache file (`~/Library/Caches/com.example.clife/usage.json`) is **shared with the app**: pressing the hotkey brings the rings up to date too, and vice versa. There is one rate limit between them, so there is no reason to ask twice. Both write to a temp file and swap it in atomically, so neither ever reads a half-written one.

## The dog

Numbers alone leave "is that fine?" for the reader to work out, every time, from three percentages with different windows and different caps. So **a dog runs along a track** — distance covered is usage, the finish line is the limit. Position says how much is gone; the expression says whether that is worth worrying about.

| Usage | The dog | What it says |
|---|---|---|
| 0–50% | all four legs off the ground, ear flying | 아직 쌩쌩해요! |
| 50–70% | stride shortening, ear coming down | 반 넘게 달렸어요 |
| 70–90% | tongue out, eyes drooping | 조금 지쳐가요… |
| 90%+ | sits down short of the line | 잠깐 쉬어야 할 것 같아요 |

The dog at the top of the dropdown speaks for **whichever limit is closest to stopping you**, not the first one. Three dogs would make you pick which to believe, which is the opposite of glanceable. The other rows just mark their position with a paw print.

The silhouette is the one candidate out of five in `design/dog/variants.html` still legible as a dog at 46pt — a hanging ear and a muzzle outside the head circle are the two features that survive being shrunk. The art is `design/dog/states.html` ported into `src/dog.swift`. The SVG there is deliberately restricted to ellipses, round-capped strokes and quadratic curves — each with a direct `NSBezierPath` equivalent — so the two cannot quietly drift apart. A hand port is exactly the kind of work that compiles cleanly while drawing the wrong thing, so the means to look at it ships too:

```sh
./Clife.app/Contents/MacOS/Clife --dogsheet /tmp/dog.png
```

That writes the four moods across six stride frames, plus the assembled dropdown layout, as PNGs. Custom views inside an `NSMenuItem` cannot be captured while running — the menu closes the moment you try — so rendering the same views offscreen is the only way to see what was actually built.

### Running

The dog actually runs: two keyed frames (extended and gathered) blended with an ease, the body bouncing with the stride, dust puffing behind the rear paw and fading. No sprite sheet, because a sheet is one more thing to keep in step every time a pose is retouched. Cadence is per mood, so a tired dog genuinely runs slower.

**It only runs while it can be seen.** The menu's dog animates while the menu is open; the widget's while the widget is up. Close either and the timer goes away and the app returns to 0% idle.

The cost was measured. It started at **3.6%** of a core — every frame redrew the whole view, labels included, and re-stroked twenty-odd paths. Three fixes brought it to **1.0%**:

1. **Invalidate only the dog's rect** — the bubble and two text fields have no reason to redraw each frame
2. **Rasterise one stride once** — the drawing is identical every cycle, so after the first pass a frame is a bitmap blit
3. **Cap the frame rate at 12fps** — past that, at this size, it costs battery without reading as smoother

Of that 1.0%, the animation itself accounts for 0.2% (measured with the widget open). If you'd still rather have it back, turn off **강아지 달리기** in the dropdown.

## Desktop widget

Dropdown → **바탕화면 위젯**. The same dog and the same limits, parked on the desktop. Drag to move it; the position is saved, and it comes back on next launch if it was open.

It is **not** a WidgetKit extension. That would need a second bundle, real provisioning and a notarised parent app, and this project signs ad-hoc on purpose (see `build.sh`) — an unsigned widget extension simply never loads. A borderless `NSPanel` pinned to the desktop window level reaches the same place: visible when the desktop is, covered when something is over it, with no signing story at all.

The content reuses the dropdown's own views. Two copies would drift the first time either was touched, and then the widget and the menu would disagree about the same numbers, which is worse than having no widget.

## Notifications

Each limit fires a desktop notification the first time it crosses 30%, 50%, 60%, 70%, 80%, 90%, and 95%. The same dog delivers it, in the same mood — a bare `주간 · Fable 50%` leaves you to judge whether that is good news inside a banner that is already sliding away, whereas the art lands the tone before the text is read. One per threshold per window; a window reset lets them fire again. Thresholds already passed when the app starts are marked as fired silently — otherwise launching at 80% would fire all three at once.

## Design notes

The icon is a colored dual ring — outer is the current 5-hour session, inner is weekly. The inner ring uses the **highest** of the weekly limits, not their average, because the tightest one is what actually stops you. Colors follow the same 70%/90% green/yellow/red thresholds as statusline's own context bar. Chosen by eyeballing renders at real menu bar size (20pt, 1x/2x, light/dark), where the two rings stayed distinguishable.

Color instead of a monochrome template icon, because two values judged on separate scales are hard to tell apart in greyscale at that size. The tradeoff is losing automatic dark-mode tinting, which seems worth it. Either way you never have to guess an exact number from a ring — the tooltip and dropdown always spell it out.

A failed request keeps the last numbers on screen and writes the reason (`token expired`, `connection failed`, …) plus "showing last value" into the status line under the rows. Blanking on one failed poll would make a five-second wifi hiccup look like a logged-out account. The last successful response is kept on disk, so a relaunch already has rings drawn before the first request goes out — restarting during a cooldown is no reason to throw away numbers that were fine a second earlier. The question-mark icon appears only when there has never been a success, so "no data" is never mistaken for "0% used".

Once the numbers are more than fifteen minutes old, **the rings lose their color.** The ring exists to be judged at a glance, without opening anything — so numbers that have stopped being current must not keep presenting themselves in confident green. Grey says "this is the last thing I knew" in the one place the user is actually looking; the dropdown says why. The threshold isn't tied to the poll interval: what counts as "too old to trust at a glance" is a property of the data, not of how lazily we happen to be polling it.

The exact age goes in the tooltip too. A number with no age on it is what makes a stale reading look like a wrong one, so the answer to "is this current?" costs a hover, not a click.

Assigning a new image or title doesn't always trigger a repaint — notably right after the display wakes from sleep, or when an external monitor is connected or disconnected. Both `needsDisplay` and a direct layer invalidation are forced so the icon can't go visibly stale while the underlying data is fine.

## Verifying

```sh
./build.sh
./Clife.app/Contents/MacOS/Clife --selftest
```

Runs the parsing path against a captured real API payload: six-digit fractional timestamps, dropping rows missing required fields, row title mapping, reset phrasing. It uses `precondition` rather than `assert` because `build.sh` builds with `-O`, which strips `assert` entirely.

## Security notes

- The OAuth token is **read only**, never stored or logged. It lives in memory and leaves only as a request header to `api.anthropic.com`.
- The single network destination is hardcoded to `api.anthropic.com/api/oauth/usage`. No telemetry, no analytics.
- Nothing in this repo hardcodes a personal path, username, or team ID. Code signing picks up whatever local certificate exists and falls back to ad-hoc (see `build.sh`).
- This is not a publicly documented API. Anthropic may change or remove it at any time, in which case the app shows a response-format error.

## License

MIT — see `LICENSE`.
