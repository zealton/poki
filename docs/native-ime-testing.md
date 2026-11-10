# Native keyboard typing

The native-services `/wda/keys` route uses `NativeIME.swift` for a single agent
input transaction. It attaches the simulated keyboard, verifies the selected
source, selects exact Chinese candidates, verifies the committed text, explicitly
removes the keyboard, and reads the field again after removal. There is no
pasteboard fallback. The XCTest alternative remains available.

Chinese text is grouped at lexical word boundaries, with at most six characters
per composition. For append-only text, selecting a candidate and starting the
next composition are pipelined. The next observation must prove the preceding
committed prefix and complete new Pinyin before another candidate is selected.
An unavailable group is cancelled and its cancellation verified before falling
back to shorter words or characters. Corrections use separate exact read-back.
Uncertain input is never automatically replayed.

## Fast observations and source selection

`ax_direct.rs` keeps a native accessibility connection and requests fresh
parameterized snapshots, without starting XCTest. It preserves received live
application tokens, uses the actual first responder, and performs a read-only
screen hit-test to check that the typing app remains visible. This matters:
Notes can still report its first responder after the user goes Home.

Source selection follows changed, colored selection evidence and recognized
source names. It does not assume an iPad caret position, a fixed screen size,
or an order of installed keyboards. It recognizes compact Pinyin/English
badges and longer source names. An unreadable transition is observed again
before cycling further. Merely recognizing an unselected language name does
not authorize typing; unknown or ambiguous presentations stop the action.

Synthetic image tests cover a caret badge, a bottom picker outside the field,
a wide selected language row, and rejection of handwriting. These are layout
regressions, not physical iPhone validation. Checkmark-only or otherwise
unrecognized presentations still need an observed adapter and device tests.

## Local checks without Xcode

The macOS Command Line Tools and Rust build the same worker and Swift engine
without building or installing an iOS app. Prepare the pinned dependencies with
`native/launcher/fetch-idevice.sh`, then:

```sh
CARGO_INCREMENTAL=0 cargo build --release --locked --manifest-path native/launcher/Cargo.toml --example native_usb --target-dir build/native-target
swiftc -O -parse-as-library native/ios-app/Poki/Runtime/NativeIME.swift native/ios-app/scripts/native-ime-usb.swift -o /tmp/poki-native-ime
/tmp/poki-native-ime --self-test
/tmp/poki-native-ime --source-layout-tests
/tmp/poki-native-ime build/native-target/release/examples/native_usb DEVICE_UDID 'Hello 你好，世界! 123'
```

Use a disposable focused note. `--clear` replaces that field. The helper uses
existing local USB pairing internally, refuses pasteboard operations, and
explicitly resets on EOF, interrupt, or idle. Diagnostics include supplied test
text. Optional `--source-images` saves uncertain source frames under `/tmp`;
those frames can include other visible content and must not be committed.

## Physical evidence

Tests used local USB, a disposable Notes document, and the attached iPad running
iPadOS 27. No relay or pasteboard was used.

| Chinese test | Verified choices | Active typing | Including cold setup/source verification |
| --- | ---: | ---: | ---: |
| First successful 189-character direct-reader run, including shorter-word/character fallback | 44 | 49.14 s; 230 chars/min | 62.36 s; 181 chars/min |
| Optimized repeat of that passage | 36 | 31.93 s; 355 chars/min | 43.24 s; 262 chars/min |

The repeat needed fewer fallbacks; its entire improvement cannot be attributed
to compiler optimization. Both used groups no longer than six characters and
confirmed exact final text and explicit keyboard removal. Those timed runs
preceded the additional post-removal read and later source-recognition fixes;
re-measure the final implementation before presenting them as final-build rates.

Earlier checks also established:

- A 27-choice Chinese passage across multiple calls with an exact English suffix.
- A 301-character English paragraph, line breaks, and Backspaces changing `abc`
  to `aXY`, with exact read-back.
- Non-first choices for `事实`, `实施`, and `逝去`.
- Expanded-list selection of `诗` at observed position 16.
- Rejection after going Home, followed by restoration of Notes.
- Safe stops on missing focus, unavailable candidates, unverified sources, and
  read-back mismatches, with explicit keyboard removal.

## Remaining limits

This is not universal Unicode insertion. ASCII, Han text, and defined Chinese
punctuation are supported; unsupported Unicode is rejected before input.
Pinyin transliteration can be wrong for polyphonic words. Exact candidate
selection and confirmed shorter fallback remain necessary. Single-character
search checks a bounded number of pages, stopping on repeated content. On this
iPad, Page Down did not expose `噬`; it was not inserted or substituted.

Snapshots are not atomic with subsequent input. Missing responders can be
transient during text layout; only reads are retried. Changed targets and
uncertain edits stop further input. AX does not expose the caret range here,
so edit verification requires a contiguous insertion/replacement preserving
surrounding content, or one real Backspace. Tab is not a verified text edit.
Apps that transform text or submit on Return can fail verification after input.

The source classifier has not been physically validated on an iPhone. Full iOS
app compilation and XCTest execution were not available on this Mac. The shared
engine/worker tests do not establish that the changed iOS app has been built,
installed, or tested. No PR, release, or workflow was published/dispatched.
