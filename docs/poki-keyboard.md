# Poki typing panel (pre-alpha)

Poki bundles an automation-only keyboard extension. It occupies a keyboard-sized
panel saying **Poki is typing**. There are no manual typing keys or candidate buttons. A system globe control remains
available where iOS requires it, so the user can switch keyboards and take over.
The extension is preferred for eligible native agent typing; the existing native
Pinyin/HID engine remains the fallback, and XCTest remains selectable.

## Enable it

After installing a build containing this change, enable **Poki** under iOS Settings
→ General → Keyboard → Keyboards → Add New Keyboard, then enable **Allow Full Access**.
Keep your usual English/Pinyin keyboards enabled. Full Access allows the extension
and Poki to exchange commands in their local App Group. The extension contains no
network client and never reads or writes the pasteboard.

Poki offers a short-lived transaction before selecting the named Poki row in an
observable system keyboard picker. It does not change keyboard settings, reorder
sources, or cycle blindly. Unknown picker labels/layouts use the native fallback.
Only a live extension acknowledgment and unchanged focused field authorize typing.
Current extension eligibility is append/end-of-field editing with readable surrounding
context. Clear and selection/mid-field edits use the existing native implementation.

If accidentally selected while idle, the extension immediately calls
`advanceToNextInputMode()`. It also advances when typing finishes or fails. That API
asks iOS for the next source; it does not guarantee restoration of the previous
source or preservation of iOS's recency ordering. Those behaviors need device checks.
The panel uses an adaptive-width panel with a 260-point phone / 350-point iPad preferred height; floating/split keyboard
behavior and orientation changes are unverified.

## IME behavior and humanization

The receiving app is edited using `UITextDocumentProxy`, without clipboard insertion.
Chinese groups use native marked text: incremental Pinyin, optional corrected typo,
then replacement with the intended Chinese characters and `unmarkText()`. Groups
follow lexical boundaries and never exceed six Chinese characters. The requested
characters are known, so missing system dictionary candidates cannot substitute a
wrong word. English uses direct character insertion and occasional corrected marked
text. Punctuation, newline, and exact Backspace counts retain their order.

Cadence variation, word-boundary pauses, and rare corrected composition errors run
inside the extension. No screenshot round trip is required per keystroke. The app
still checks the entire resulting field before reporting `textVerified`.

This uses public IME APIs; it does not impersonate Apple's keyboard or guarantee
identical composition events in every host app. Chinese transliteration still has
polyphonic-word limitations, even though the committed target text is exact.

## Takeover and early learning

Changing keyboards or leaving the field during an active session stops the worker.
Poki does not switch back, invoke fallback, replay unfinished text, or send the next
action. A user-only handoff waits for **Done**; the agent cannot dismiss or replace
it. After Done, queued actions are refused once while a fresh screen is returned,
so the agent must replan from the user's current state.

Learning samples the ordinary screen reads while paused, then compares the final
state. It records a bounded summary of observed apps and changed identifiable fields
in Poki's local memory. It does not log touches or save screenshots or raw field
values in that summary. The agent is instructed to distinguish corrections,
manual progress, and unrelated activity, and not invent intent or unseen gestures.
This is observation-based learning, not continuous detection of every manual touch.
Secure fields and fields without stable identifiers are excluded from text learning.

**Hidden experiment:** hold the **Poki keyboard** heading in Poki Settings for three
seconds to reveal **Create routines from user demonstrations** (off by default).
When enabled, an unambiguous final field replacement can be included in a saved
routine as a parameterized user-demonstrated checkpoint. Ambiguous navigation becomes
an explicit manual checkpoint. Replay stops for the owner at either kind; the early
version does not replay inferred user actions unattended. Turning the option off
prevents saving traces with manual gaps as though they were fully automated successes.

## Validation status and tomorrow's checks

**The extension, takeover integration, and learning changes have not been built or
executed. Local computer and physical-device testing were paused at the owner's
request.** Prior native-engine experiments are documented separately in
[native-ime-testing.md](native-ime-testing.md); they do not validate this extension.
No throughput claim is made for the extension yet.

| Language / input | Implemented path | Device checks still required |
| --- | --- | --- |
| English | Paced insertion, corrected marked typo, ASCII punctuation | Notes, Safari input/contenteditable, selection, Return/Send behavior |
| Simplified Chinese Pinyin | Marked Pinyin → exact requested Han groups | Long fresh text, uncommon names, polyphonic words, repeated 4–6-character choices |
| Mixed Chinese/English | Per-piece language hint and ordered composition | Multiple switches, punctuation, backspaces, no duplicate commits |
| Traditional Chinese | Han conversion planner exists; not a distinct Traditional IME | Script-specific output and phonetic behavior; not certified supported |
| Japanese | No Japanese IME implementation | Romaji → kana → kanji, marked ranges, cancellation; currently unsupported |
| Korean | No Korean IME implementation | Jamo assembly and syllable deletion; currently unsupported |
| French / Spanish / German | ASCII subset only | Accents, dead keys, composed/decomposed Unicode; currently rejected outside ASCII |
| Arabic / Hebrew | Not implemented | RTL caret, punctuation, bidirectional context |
| Emoji / combining sequences | Not implemented | Grapheme-safe insertion and deletion; currently rejected before input |

For iPhone and iPad separately: enable/disable Full Access, blocked third-party
keyboards, accidental idle selection, source ordering before/after use, floating
keyboard, orientation, background suspension, cancellation, stale leases, and extension
termination. Switch to the normal keyboard halfway through Pinyin and English,
correct a word, navigate to another screen, then tap Done. Confirm no further agent
action occurs before Done, no partial input is replayed, and the next response reads
the user's actual state. Repeat with the hidden learning switch on and off.

Measure fresh long passages and repeat passages separately, including activation,
completion/read-back, and at least 180 correctly committed characters per minute.
Do not count a dispatched request or extension receipt as successful text entry.

## Packaging

Both external-connection and local-connection editions embed `PokiKeyboard.appex`.
Signing exports include the keyboard's App Group entitlement. Poki Setup's existing
extension enumeration and bundle/group rewriting cover the new `.keyboard` bundle.
Provisioning and install compatibility remain unverified until the next device run.
A PR alone does not publish a pre-alpha: the normal main-merge workflow builds it.
