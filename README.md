# PromptBox

A floating macOS editor for writing prompts to terminal agents like Claude Code. Terminal prompts
are hard to edit: you can't select a block with the mouse, images show up as `[Image #1]`, and
text you delete is gone. PromptBox is a normal macOS text view (every ⌥/⌘ arrow, selection and
deletion shortcut works) that sends its contents to the terminal when you're done.

Each prompt is a tab, as in a browser. Hammerspoon opens the window with hyper+p, on the screen
of the focused window, at a third of the screen's width and half its height, or larger if
you've resized it before.

| Key | Action |
| --- | --- |
| `⌘↩` | Send: copy the prompt, hide, and paste it into the window that was focused before |
| `⌘⇧↩` | Copy the prompt and hide, without pasting |
| `Esc` / hyper+p | Hide; the draft stays |
| `⌘T` / `⌘N` | New tab |
| `⌘W` | Close the tab (it goes to history) |
| `⌘⇧T` | Reopen the last closed tab |
| `⌃Tab` / `⌃⇧Tab` | Next / previous tab (also `⌘⇧]` / `⌘⇧[`) |
| `⌘1`–`⌘8`, `⌘9` | That tab, the last tab |
| `⌘K` | Search tabs |
| `⌘D` | Deleted text and images |
| `⌘Y` | History of sent prompts |
| `⌘⇧K` | Delete the lines the selection touches |
| `⌘F`, `⌘G`, `⌥⌘F` | Find, find next, find and replace |
| `⌘=` / `⌘-` / `⌘0` | Font size |

## Tabs

Each tab keeps its own text, images, cursor, scroll position and undo history. The title is its
first line. Sending a prompt closes its tab; closing the last tab leaves an empty one.

`⌘K` searches the open tabs by title and text. It forgives partial words ("auth" finds
"authentication"), typos ("sidbar", "promtp") and letters in order ("rspns"), and shows the
line that matched. The best match is highlighted: ↑/↓ or ⌃P/⌃N move, Return switches, Esc
closes. With nothing typed, the list starts with the tab you used before this one, so `⌘K`
then Return flips between two tabs. Matching lives in `Sources/PromptBoxCore/FuzzyMatch.swift`.

## Images

Paste or drop images (screenshots, image files, images copied from a browser) and they go in a
strip of numbered thumbnails under the text. × removes one; double-click opens it in Preview.
Sending writes each image to `~/Library/Caches/no.devda.PromptBox/images/<hash>.png` and adds a
line per image after the text:

```
Compare the header in image 1 with image 2.

Image 1: /Users/you/Library/Caches/no.devda.PromptBox/images/9b3f12402f08b1ca.png
Image 2: /Users/you/Library/Caches/no.devda.PromptBox/images/29d4d49cb779dbff.png
```

The numbers match the thumbnails, so the text can refer to them. Dropping a file that isn't an
image inserts its path.

## Getting things back

- `⌘Z` undoes text edits and image removals, all the way back.
- Everything removed from the editor goes to the deleted list (`⌘D`): backspaced words, cut
  text, text typed over, deleted lines and removed images. Holding backspace over a word gives
  one entry, not one per letter. Return on an entry puts it back at the cursor.
- Every sent prompt and every closed tab goes to history (`⌘Y`). Return opens it in a new
  tab.
- Tabs are saved a second after each change, so quitting or a crash doesn't lose them.

All of it lives in `~/Library/Application Support/PromptBox`. History keeps the last 500
prompts and the deleted list the last 1000 entries.

## Hammerspoon

PromptBox has no hotkey of its own. It answers `promptbox://show`, `promptbox://hide` and
`promptbox://toggle`, and when it hides it opens `hammerspoon://promptbox-closed` or, after a
send, `hammerspoon://promptbox-paste`. The binding in `~/dotfiles/hammerspoon/init.lua`
remembers the focused window on hyper+p, gives it focus back on `promptbox-closed`, and presses
⌘V in it on `promptbox-paste`. Without Hammerspoon the prompt is still on the clipboard.

## Build

```sh
./scripts/build-app.sh      # builds, signs and registers build/PromptBox.app
swift test                  # core logic: deletion joining, fuzzy search, export, storage
```

Requires macOS 15.

`PROMPTBOX_SELFTEST=/some/dir build/PromptBox.app/Contents/MacOS/PromptBox` types, pastes
three images, deletes a word, a line and an image, writes what it would send to
`report.txt`, opens two more tabs and runs a misspelled `⌘K` search, then shows the window for
three seconds (for `screencapture -l`) and quits. Set `PROMPTBOX_SELFTEST_SIDEBAR=1` to show
the deleted list instead of the search. It never touches your saved tabs or lists.
