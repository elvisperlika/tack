#!/usr/bin/env python3
"""Read or write a Tack note from outside Tack, in any app. Mirrors the keys of
Sources/Model/Container/*.swift and the write rules of Sources/Model/NoteStore.swift.

  tack_note.py get|set --app APP [--file PATH | --url URL | --title TITLE | --tty TTY | --whole-app]
  tack_note.py get|set --folder PATH

APP is a name ("Preview") or a bundle ID ("com.apple.Preview"). With no target flag the note
goes on what the app's front window shows: the document, the browser tab, the Terminal tab,
or the window title. `set` reads the note from stdin; empty stdin deletes the note.
"""
import argparse, json, os, shutil, subprocess, sys
from urllib.parse import urlsplit, urlunsplit

STORE = os.path.expanduser("~/Library/Application Support/Tack/appnotes.json")
NEW = {"dx": 40, "dy": 80}  # offset from the window's top-left; size, colour, font use Tack's defaults
BROWSERS = {"com.google.Chrome", "company.thebrowser.Browser", "com.apple.Safari"}  # BrowserContainer.bundleIDs
TERMINAL = "com.apple.Terminal"  # TerminalContainer.bundleID


def osa(script, *args, lang="AppleScript"):
    out = subprocess.run(["osascript", "-l", lang, "-e", script, *args], capture_output=True, text=True)
    if out.returncode:
        sys.exit(f"osascript failed: {out.stderr.strip()}")
    return out.stdout.strip()


def bundle_id(app):
    # shortcut: a name containing a dot is taken as a bundle ID; pass the ID for such apps.
    return app if "." in app else osa(f'id of application "{app}"')


def file_url(path):
    # Foundation's own encoding, the same string apps report as AXDocument.
    return osa("function run(a){ObjC.import('Foundation');return $.NSURL.fileURLWithPath(a[0]).absoluteString.js}",
               os.path.abspath(os.path.expanduser(path)), lang="JavaScript")


def normalize(url):
    # BrowserContainer.normalize: scheme + host + path; query and fragment are session noise.
    parts = urlsplit(url)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, "", "")) if parts.netloc else url


def front_identity(bundle):
    """What Tack would key the app's front window by right now; "" when it has none."""
    # `is running` first: telling a closed app anything launches it.
    def ask(query):
        return osa(f'''if application id "{bundle}" is not running then return ""
        tell application id "{bundle}"
            if (count of windows) is 0 then return ""
            return {query}
        end tell''')
    if bundle == "com.apple.Safari":
        return normalize(ask("URL of current tab of front window"))
    if bundle in BROWSERS:
        return normalize(ask("URL of active tab of front window"))
    if bundle == TERMINAL:
        return ask("tty of selected tab of front window")
    # GenericAppContainer: AXDocument, else the window title.
    return osa(f'''tell application "System Events"
        set ps to processes whose bundle identifier is "{bundle}"
        if ps is {{}} then return ""
        tell item 1 of ps
            if (count of windows) is 0 then return ""
            set w to front window
            try
                set d to value of attribute "AXDocument" of w
                if d is not missing value and d is not "" then return d
            end try
            return name of w
        end tell
    end tell''')


def app_key(a):
    bundle = bundle_id(a.app)
    if a.whole_app:
        return bundle
    if a.file:
        ident = file_url(a.file)
    elif a.url:
        ident = normalize(a.url)
    elif a.title or a.tty:
        ident = a.title or a.tty
    else:
        ident = front_identity(bundle)
    if not ident:
        sys.exit(f"{a.app} is not running or shows no window here (closed, minimized or on another Space); "
                 "open it, or pass --file, --url, --title or --tty")
    return f"{bundle}|{ident}"


def load(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)  # malformed JSON stops here, like Tack: never overwrite it


def save(path, value):
    if os.path.exists(path):
        shutil.copy(path, path + ".backup")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(value, f)
    os.replace(tmp, path)  # atomic, so Tack never reads half a file


def main():
    p = argparse.ArgumentParser()
    p.add_argument("action", choices=["get", "set"])
    where = p.add_mutually_exclusive_group(required=True)
    where.add_argument("--app", help='name or bundle ID, e.g. "Preview" or com.apple.Preview')
    where.add_argument("--folder")
    target = p.add_mutually_exclusive_group()
    target.add_argument("--file", help="document open in the app")
    target.add_argument("--url", help="browser page")
    target.add_argument("--title", help="window title, for apps without a document")
    target.add_argument("--tty", help="Terminal tab, e.g. /dev/ttys003")
    target.add_argument("--whole-app", action="store_true", help="one note for every window of the app")
    a = p.parse_args()

    if a.folder:
        path = os.path.join(os.path.abspath(os.path.expanduser(a.folder)), ".tack.json")
        note = load(path)
        if a.action == "get":
            print(note["text"] if note else "")
            return
        text = sys.stdin.read()
        if text:
            save(path, {**(note or NEW), "text": text})
        elif note:
            os.remove(path)  # Tack's convention: an empty note is a deleted note
        print(path)
        return

    key = app_key(a)
    notes = load(STORE) or {}
    if a.action == "get":
        print(notes.get(key, {}).get("text", ""))
        return
    os.makedirs(os.path.dirname(STORE), exist_ok=True)
    text = sys.stdin.read()
    if text:
        notes[key] = {**notes.get(key, NEW), "text": text}  # keep its place, size and style
    else:
        notes.pop(key, None)  # Tack's convention: an empty note is a deleted note
    save(STORE, notes)
    print(key)


if __name__ == "__main__":
    main()
