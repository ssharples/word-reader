# Word Reader

A Mac app for reading EPUB books one word at a time, in the centre of the screen,
at a speed you choose.

It finds the books you've added to Apple Books by itself, and you can open any other
EPUB with **Open EPUB…** (⌘O) or by dropping it on the window.

## Build and run

Needs macOS 14 or later and Xcode's command-line tools (Swift 6).

```bash
Scripts/build-app.sh --install
```

This builds `build/Word Reader.app` and copies it to `~/Applications`. Without
`--install` it only builds.

The first time it opens, macOS asks whether Word Reader may use files in iCloud Drive.
Say **Allow**: Apple Books keeps your books there. If you say no, you can still open
books with **Open EPUB…**.

The script signs the app with your Apple Development certificate if you have one, so
macOS remembers that answer after a rebuild. Set `SIGN_IDENTITY` to pick a certificate.

## Reading

- **Space** plays and pauses. While paused, the sentence around the word shows below it.
- **← →** step one word; **⌥← ⌥→** one sentence.
- **↑ ↓** change the speed by 25 words a minute (100 to 1,000).
- **[ ]** jump to the previous or next chapter, or pick one from the chapter menu.
- **⌘+ ⌘−** change the text size. The **Aa** button has the rest: font, the red focus
  letter, and pauses at punctuation.
- **Esc** pauses, then goes back to the library.

Each word is placed so its focus letter (shown in red) stays in the same spot, just
left of the word's middle, so your eyes don't move between words. Longer words and
punctuation get a little more time, as they would if you read aloud.

The app remembers where you are in each book, and opens new books at the first page
of the text rather than the cover or copyright page.

## How it works

`ReaderCore` reads EPUBs the way Apple Books does. Apple Books keeps imported books
as unzipped `.epub` folders in `~/Library/Mobile Documents/iCloud~com~apple~iBooks/Documents`;
other EPUBs are zip files. Both go through the same steps: `META-INF/container.xml`
names the package file, the package lists the reading order (the *spine*), and each
chapter's HTML becomes a list of words. Pages the book marks as outside the main
reading order, such as pop-up notes, are left out, as are footnote markers and page
numbers. Books with copy protection (from the Apple Books Store) can't be read.

| Folder                 | What's in it                                          |
| ---------------------- | ----------------------------------------------------- |
| `Sources/ReaderCore`   | EPUB reading, word splitting and timing               |
| `Sources/WordReader`   | The SwiftUI app                                       |
| `Sources/epub-check`   | A command-line check that opens every book            |
| `Tests/ReaderCoreTests`| Tests for the above                                   |
| `Scripts`              | App build script and icon drawing                     |

## Checks

```bash
swift test
swift run -c release epub-check            # every book in Apple Books
swift run -c release epub-check --sample path/to/book.epub
```
