---
name: tack
description: Save context as a Tack note pinned to what the user works in on this Mac (a document in any app, a browser page, a Terminal tab, an app window, a whole app, or a Finder folder) so they see it next time it is in front. Use when the user types /tack, or asks to leave a note, a summary or "what you did" on a file, page, app or folder.
---

# Tack notes

Tack is a macOS menu-bar app that shows a Markdown note on top of the window, tab or folder it belongs to. You write the note to Tack's store with `tack_note.py`; the running Tack picks it up from disk and shows it when that surface is in front. You never drive Tack's UI.

## Where notes live

- **A Finder folder:** `<folder>/.tack.json`, one note per folder.
- **Anything else:** one entry in `~/Library/Application Support/Tack/appnotes.json`, keyed `<bundle ID>|<identity>`. The identity depends on the app:

| What the note is on | Identity in the key | Script flag |
|---|---|---|
| A document (Preview, TextEdit, Pages, Xcode, Ghostty's folder…) | file URL | `--file PATH` |
| A page in Safari, Chrome or Arc | URL without query or fragment | `--url URL` |
| A Terminal tab | its tty, e.g. `/dev/ttys003` | `--tty TTY` |
| A window of an app with no document (Settings, Music…) | window title | `--title TITLE` |
| Every window of the app | nothing: the key is the bundle ID alone | `--whole-app` |

With no flag, the script asks the app what its front window shows right now and keys the note the way Tack would. The key must match Tack's character for character, or the note is saved but never shows: never build keys or edit the JSON by hand. The script uses Foundation's own URL encoding and Tack's write rules (backup, atomic replace, an empty note deletes).

## Steps

`T=~/.claude/skills/tack/tack_note.py`. `--app` takes a name (`"Preview"`) or a bundle ID (`com.apple.Preview`).

1. **Pick the target.** Prefer an explicit flag when you know it (the file you opened, the URL you visited). Use the front window (no flag) when the user means "this", and bring the app forward first. Open the target if needed so the user can watch the note appear: `open -a Preview "<file>"`, `open -a Safari "<url>"`.
2. **Read any existing note**, and extend it rather than replace it unless asked:
   ```
   python3 -I $T get --app Preview --file "<file>"
   python3 -I $T get --folder "<folder>"
   ```
3. **Write the note** from stdin with a quoted heredoc, so `$` and backticks stay literal. The script prints the key it wrote:
   ```
   python3 -I $T set --app Safari --url "https://example.com/docs" <<'EOF'
   # Title
   ...
   EOF
   ```
4. **Bring the app to the front** (`osascript -e 'tell application "Preview" to activate'`) and tell the user which note you left where.

To delete a note, `set` it with empty stdin: `printf '' | python3 -I $T set --app Preview --file "<file>"`.

## Writing the note

A note is something to read in ten seconds on top of a window, not a report.

- A `# Title`, then one line of source or context (authors, venue, date, what you did).
- Two to four `##` sections with short bullets; real numbers over adjectives.
- Under about 25 lines. Markdown supported: headings, bullets, **bold**, `code`, links.
- Write in the language the user is using.

## When it fails

- **"not running or shows no window"**: the app is closed, minimized or on another Space. Open or show it, or pass an explicit flag.
- **"not allowed assistive access"**: the terminal running you lacks Accessibility permission (System Settings → Privacy & Security → Accessibility). Flags other than the front-window default do not need it.
- A title-keyed note follows the title: if the window's title changes, the note stops showing. Prefer `--file` or `--url` when the app has one.
- Tack and the script both rewrite `appnotes.json`; a save in Tack at the same instant can drop one of the two writes. Do not write in a tight loop.
