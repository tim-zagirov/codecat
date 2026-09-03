# Manual verification checklist

Everything here needs a human. CodeCat is an `LSUIElement` app: it has no window,
screen-control tools cannot see it, and half of these items are about motion or
about a password prompt. What *is* checked automatically is listed in the
[README](../README.md#what-is-and-is-not-verified).

Run this on a fresh build before tagging a release.

## The basics

1. Launch `dist/CodeCat.app` — the cat and the menu-bar icon appear.
2. Install the hooks from the menu → `cat ~/.claude/settings.json` contains
   `codecat-hook` under all **five** events: `SessionStart`, `UserPromptSubmit`,
   `Stop`, `Notification`, `SessionEnd`.
3. Open a `claude` session and start nothing → the cat sleeps, no badge. An open
   tab is not a working agent.
4. Give it a task → the cat works, the badge reads "1", and an assertion shows up
   in `pmset -g assertions`.
5. Wait for the agent to ask a question or for permission → the cat waves a paw,
   the badge turns red.
6. Answer and let it finish → the cat settles, and about two minutes later the
   assertion is released.
7. Lock the screen while an agent is working, unlock after it finishes → the
   panel shows a "While you were away" block.
8. Turn on closed-lid mode (password) → with an agent working,
   `pmset -g | grep SleepDisabled` is 1; after it finishes plus the grace period,
   0.
9. Quit the app → the hooks can stay installed; `codecat-hook` exits quietly and
   Claude Code is unaffected.

## Jumping to a session

10. Open the panel, hover a session row → the row highlights and the cursor
    becomes a pointer.
11. Click a row for a session running in Terminal.app → the automation permission
    is requested once, then you land in exactly that tab and the panel closes.
12. Click a row for a desktop Claude session → the app comes forward, the panel
    closes.
13. Deny the automation permission → the app still comes forward, and the message
    about the permission is **visible**, not hidden behind a window.

## Skins

14. Open the panel → a 4×2 grid of skins, every preview animated, no horizontal
    scrolling. (Seven tiles if the optional Elthen sheet was not downloaded —
    that is correct, not a bug.)
15. Click a preview → the cat on screen changes immediately, the panel stays
    open, the selected tile has a border.
16. Restart the app → the chosen skin survived.
17. Expand *About the assets* → the packs are listed, and mxmaze shows both
    "CC BY 4.0" and the author's name.

## The island

18. The island matches the notch's height, and the seam between the black slab
    and the notch is invisible on a light wallpaper.
19. The cat in the wing animates, its pixels are square (the sprite is not
    blurred), and it is not clipped top or bottom. The tallest skins (mxmaze,
    cat-4, cat-5) fill the menu bar completely — if that reads as cramped, the
    fallback is in the spec: raise the island to `safeAreaInsets.top + 4`.
20. The counter on the right: a dot at rest, a number when sessions exist, a red
    number when an agent is waiting.
21. Hovering opens the short menu; moving the mouse from the island onto the menu
    does not close it; moving away closes it after roughly a third of a second.
22. Clicking opens the full menu; its toggles, skin grid and hooks button all
    work; clicking outside closes it; clicking the island again closes it.
23. Turn on "Hide the cat when nothing is running" with zero sessions → the
    mascot disappears; start a session → it comes back on its own, without
    touching the menu. Check this in **both** display modes: before 0.2.0 only
    the island read this setting and the toggle was dead in floating mode.
24. Clicking a session row jumps to the terminal and closes the menu.
25. Switch display mode both ways: the floating cat returns to its saved
    position, the island disappears completely, and the floating panel looks and
    behaves as it did before the two were split apart.
26. On a Mac where the built-in display is neither the main one nor at the origin
    in System Settings → Displays → Arrangement, the island is still in place —
    not shifted, not clipped. The whole calculation assumes the notch's auxiliary
    areas arrive in the same global coordinates as `NSScreen.frame`; on the
    development machine the built-in display sits at the origin, so the two
    readings are indistinguishable and no test separates them.
27. Choose "Island" on a display with no notch (external monitor, closed lid) →
    a hint appears under the mode switch saying the island won't appear, rather
    than the mascot silently vanishing.

## Diagnostics and lifecycle

28. The menu bar shows the version — "CodeCat &lt;version&gt; (&lt;build&gt;)" — and the
    number in brackets matches `git rev-list --count HEAD` for the build that is
    installed.
29. `tail -f` the log while an agent works: each event produces a pair of lines,
    `[app] event …` and `[hook] sent …`, in that order. The app receives the
    datagram and writes first because `sendto` returns before the receiver has
    read it. A lone `[hook]` with no matching `[app]` means the event was lost
    between the two processes.
30. "Remove Claude Code hooks…" → asks for confirmation; after you agree the menu
    item becomes "Install Claude Code hooks…", no `codecat` remains in
    `~/.claude/settings.json`, and every other key (`enabledPlugins`,
    `statusLine`, `tui`, …) is untouched. Install again — all five events return.
31. "Hide the cat when nothing is running" exists in the menu-bar menu too, not
    only in the settings panel. This is not a convenience: turning it on from the
    panel with zero sessions removes both the mascot and the menu that lives
    inside it, and the menu bar is the only place left to turn it off.
32. **Restart while an agent is working.** Quit the app mid-task and relaunch
    immediately → the mascot shows work within a fraction of a second, not tens
    of seconds later. Before 0.2.0 the app had no way to learn about live
    sessions until an agent wrote to a transcript: measured blindness ranged from
    4 to 89 seconds, during which "hide when idle" left no mascot on screen at
    all.
33. **Quit with closed-lid mode on.** Confirm `pmset -g | grep SleepDisabled` is
    1, then quit → the screen does **not** go dark instantly and the Mac behaves
    normally. `pmset -a disablesleep 0` from `resetOnExit()` used to drop the Mac
    into sleep after 37 ms: the kernel re-read the settings and saw all the idle
    time accumulated while the flag was up. Also confirm `SleepDisabled` did
    become 0.

## Release builds only

34. After `make release`, on a **different** Mac: download the `.dmg`, open it
    with a plain double-click — no right-click, no "Open anyway" — move the app
    to `/Applications` and launch it. Then click a session row for a Terminal.app
    session: the jump must work. This is the only real check of the Apple-events
    entitlement; ad-hoc builds have no hardened runtime, so the failure it guards
    against cannot be reproduced there.

## Localisation

35. Set the system language to Russian (System Settings → General → Language &
    Region), restart CodeCat → the menu, the panel, the session statuses and the
    activity lines are all Russian. Switch back to English and confirm the same.
    The log stays English in both cases; that is deliberate.
