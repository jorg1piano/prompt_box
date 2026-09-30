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
| `⌘⇧A` | Transcript tab, or back to the tab before it |
| `⌘R` | Rewrite the suggested prompt from the transcript |
| `⌘O` | Open the suggested prompt in a tab |
| `⌘⇧L` | Pause or resume listening |
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

## Transcript

PromptBox listens to the microphone from launch and writes down everything it hears, on this
Mac, with the `SpeechAnalyzer` transcriber that macOS 26 added. The pinned tab at the left of
the tab bar (`⌘⇧A`) shows it as a thread, one message per stretch of speech with a gap of
under 10 seconds, with the words still being recognised at the bottom. The tab's icon is a
waveform while the microphone is on and a crossed-out mic while it's paused.

The top of the tab is a suggested prompt: opening the tab sends the last 5 minutes of speech
(counted back from the last thing you said) to `claude -p` (Sonnet, no tools, no session),
which writes the prompt you'd type from it. It leaves out talk that isn't meant for an agent,
keeps remarks about the same task together even when other talk came between them, and makes
a numbered list when there are several tasks. The thread marks the messages it used with a bar.

The suggestion is plain text you edit like any tab. It's only rewritten when you open the tab
after saying something new, and never over your edits.

- `⌘↩` sends it to the terminal, `⌘⇧↩` copies it; both file it in history (`⌘Y`). `⌘O`
  opens it in a new tab instead.
- Sending, copying or opening it, or deleting all its text, starts a new prompt: from then on
  the suggestion only reads speech that began after that moment, so the last prompt's words
  don't leak into the next one. Undoing the delete brings the text back but not the old
  speech.
- `⌘R` rewrites it from the last 5 minutes of the current prompt, or from the thread messages
  you selected, which can be from before it. It replaces your edits; `⌘Z` brings them back.
- ⇥ moves to the thread. Return there opens the selected messages' raw text in a tab.

### Videos and calls

The microphone also picks up whatever the Mac plays. So PromptBox records the Mac's own output
too (every app but PromptBox, through a Core Audio process tap) and transcribes it with a
second transcriber. A microphone segment whose word pairs the speakers played within 3 seconds
of it is marked: half or more matching means it was the speakers, a quarter or more means it
mixes your words with theirs (`Sources/PromptBoxCore/EchoMatch.swift`). The thread fades those
words and shows a speaker icon, and the suggestion sees them labelled `(speakers)` or
`(partly speakers)` and leaves them out. Nothing is removed from the transcript. With
headphones on, the microphone doesn't hear the video, so there's nothing to mark.

macOS asks once for System Audio Recording. Without it the speakers record as silence and
nothing gets marked. The two transcribers together use about 9% of one core.

Transcripts are kept forever as one JSON line per segment in
`~/Library/Application Support/PromptBox/transcripts/<date>.jsonl`, with `"source"` either
`mic` or `speakers`; the suggestion and its edits are in `suggestion.json` next to them.

To keep it listening, add PromptBox to System Settings › General › Login Items.
`promptbox://pause` and `promptbox://listen` switch the microphone from Hammerspoon.
`defaults write no.devda.PromptBox transcriptLocale en-GB` picks the language,
`suggestionModel haiku` a different model, `suggestionMinutes 10` a longer stretch of speech,
and `claudePath` the claude binary if PromptBox can't find it.

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

Requires macOS 26.

`PROMPTBOX_SELFTEST=/some/dir build/PromptBox.app/Contents/MacOS/PromptBox` types, pastes
three images, deletes a word, a line and an image, writes what it would send to
`report.txt`, opens two more tabs and runs a misspelled `⌘K` search, then shows the window for
three seconds (for `screencapture -l`) and quits. Set `PROMPTBOX_SELFTEST_SIDEBAR=1` to show
the deleted list instead of the search. It never touches your saved tabs or lists.

`PROMPTBOX_SELFTEST_TRANSCRIPT=1` instead fills the transcript with made-up speech, opens the
transcript tab (a real `claude -p` call) and writes the suggested prompt to `transcript.txt`.
It then copies it (checking the clipboard and history, then putting your clipboard back), says
something new, and deletes the suggestion and says something else, printing the prompt
written after each, to show that neither reads speech from before.
`PROMPTBOX_SELFTEST_AUDIO=<file>` plays an audio file through the transcriber in real time and
prints each segment.
