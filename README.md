# Word Reader

A Mac app that shows your books one word at a time, in the middle of the screen,
at the speed you choose.

![Word Reader showing the first sentence of Pride and Prejudice one word at a time](docs/demo.gif)

If you find it hard to stay focused on a page, this may help. Your eyes stay in one
place and the book comes to you.

- It finds the books in your Apple Books library by itself. Open any other EPUB with
  **Open EPUB…** (⌘O) or by dropping it on the window.
- Pick a speed from 100 to 1,000 words a minute. Long words and the ends of sentences
  get a little more time, as they would if you read aloud.
- Each word lines up on its focus letter, shown in red, so your eyes don't move.
- Pause to see the sentence around the word. Step back or forward by word, sentence
  or chapter.
- It remembers where you are in every book, and opens new books at the first page of
  the text rather than the cover.
- It works offline. Your books stay on your Mac and nothing is sent anywhere.

Books bought from the Apple Books Store have copy protection, so Word Reader can't
open them. Books you added yourself, and DRM-free EPUBs from anywhere, work.

## Install

You need macOS 14 (Sonoma) or later, and Swift 6 or later, which comes with Apple's
free Command Line Tools or Xcode 16. The installer tells you if anything is missing.

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/ssharples/word-reader/main/Scripts/install.sh | bash
```

It downloads the source, builds the app on your Mac, puts it in `~/Applications` and
opens it. Run it again to update. If you'd rather read the script before running it,
it's [`Scripts/install.sh`](Scripts/install.sh).

The first time the app opens, macOS asks whether Word Reader may use files in iCloud
Drive. Click **Allow**: Apple Books keeps your books there. If you say no, you can
still open books with **Open EPUB…**.

### Install with an AI agent

Give your coding agent (Claude Code, Codex, Cursor and so on) the link to this page
and ask it to install the app:

> Install this Mac app for me: https://github.com/ssharples/word-reader

#### Steps for AI agents

If you're an agent asked to install Word Reader, follow these steps and change
nothing else on the person's Mac.

1. Check that this is a Mac running macOS 14 or later: `sw_vers -productVersion`.
2. Run the installer. It takes a minute or two, needs no `sudo`, builds from source
   in a temporary folder, installs `~/Applications/Word Reader.app` and opens it.

   ```bash
   curl -fsSL https://raw.githubusercontent.com/ssharples/word-reader/main/Scripts/install.sh | bash
   ```

3. If it stops with "Swift isn't installed", a window has opened to install Apple's
   Command Line Tools. Ask the person to finish that install, then run step 2 again.
   If it says Swift is too old, ask them to update Xcode or the Command Line Tools in
   Software Update.
4. When the app opens, macOS asks whether Word Reader may use files in iCloud Drive.
   Ask the person to click **Allow**. Don't click it for them.
5. You're done when `~/Applications/Word Reader.app` exists and its window lists the
   person's books. If they have no books in Apple Books, tell them they can drop EPUB
   files on the window or use **Open EPUB…** (⌘O).

### Uninstall

```bash
rm -rf ~/Applications/Word\ Reader.app && defaults delete com.ssharples.WordReader
```

The second command forgets your place in each book and your settings.

## Reading

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/reader-dark.png">
  <img alt="Word Reader paused on the word 'universally', with the sentence around it shown below" src="docs/reader-light.png">
</picture>

- **Space** plays and pauses. While paused, the sentence around the word shows below it.
- **← →** step one word; **⌥← ⌥→** one sentence.
- **↑ ↓** change the speed by 25 words a minute.
- **[ ]** jump to the previous or next chapter, or pick one from the chapter menu.
- **⌘+ ⌘−** change the text size. The **Aa** button has the rest: font, the red focus
  letter, and pauses at punctuation.
- **Esc** pauses, then goes back to the library.

## Build from source

```bash
git clone https://github.com/ssharples/word-reader.git
cd word-reader
Scripts/build-app.sh --install
```

This builds `build/Word Reader.app` and copies it to `~/Applications`. Without
`--install` it only builds.

The script signs the app with your Apple Development certificate if you have one, so
macOS remembers your iCloud Drive answer after a rebuild. Without one, it signs the
app for your Mac only, and macOS may ask again after each rebuild. Set
`SIGN_IDENTITY` to pick a certificate.

## How it works

`ReaderCore` reads EPUBs the way Apple Books does. Apple Books keeps imported books
as unzipped `.epub` folders in `~/Library/Mobile Documents/iCloud~com~apple~iBooks/Documents`;
other EPUBs are zip files. Both go through the same steps: `META-INF/container.xml`
names the package file, the package lists the reading order (the *spine*), and each
chapter's HTML becomes a list of words. Pages the book marks as outside the main
reading order, such as pop-up notes, are left out, as are footnote markers and page
numbers.

| Folder                  | What's in it                                |
| ----------------------- | ------------------------------------------- |
| `Sources/ReaderCore`    | EPUB reading, word splitting and timing     |
| `Sources/WordReader`    | The SwiftUI app                             |
| `Sources/epub-check`    | A command-line check that opens every book  |
| `Tests/ReaderCoreTests` | Tests for the above                         |
| `Scripts`               | Install and build scripts, icon drawing     |

## Checks

```bash
swift test
swift run -c release epub-check            # every book in Apple Books
swift run -c release epub-check --sample path/to/book.epub
```

## Licence

[MIT](LICENSE)
