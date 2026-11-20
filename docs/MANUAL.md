# Transcript Tab for Final Cut Pro — User Manual

Transcript Tab: text-based editing inside Final Cut Pro. A fifth tab in the inspector shows what people said, as text. Read it, search it, fix it, click a word to jump there, select words to mark or cut them, and export it.

Transcript Tab is a tab in Final Cut's inspector, next to Video, Audio and Info. It shows the transcript of whatever you have selected: one clip in the browser, or the whole project when you select a clip in the timeline. Click a word and the playhead goes there. Select words and press Delete and they are cut out of the timeline.

This manual doubles as a walkthrough. Follow it top to bottom with any interview clip. Sections marked "(not yet tried by hand)" describe features that were tested by script but not yet used by a person on real footage.

---

## The panel at a glance

@figure manual-panel.png 696 1294
@badge 1 470 28
@badge 2 470 53
@badge 3 470 78
@badge 4 470 130
@badge 5 470 155
@badge 6 440 207
@badge 7 470 232
@badge 8 470 282
@badge 9 105 359
@badge 10 105 384
@badge 11 130 412
@badge 12 35 1250
@badge 13 78 1250
@endfigure

1. **Fillers: Delete.** Removes every um / uh in one go (section 6).
2. **Pauses: Delete.** Shortens every long pause, keeping 0.1 s on each side (section 6).
3. **Pauses longer than.** Sets how long a silence has to be to count as a pause: 0.3, 0.5, 1.0 or 2.0 s.
4. **Show.** Show all speakers, or only one (section 7).
5. **Detection: Detect / Re-detect.** Finds who is speaking and tightens word timing (sections 7 and 9).
6. **Timecode.** Short, Min:Sec:Frames, Project Timecode or Hidden (section 8).
7. **Text size.** Three **A** buttons make the transcript bigger. The controls stay the same size.
8. **Color bars, Dark background, Precise word timing.** Three checkboxes (sections 7 to 9).
9. **Find.** Search the transcript; the arrows step through matches (section 10). Cmd-F jumps here.
10. **Replace / All.** Replace one match or every match (section 10).
11. **The transcript.** Click a word to move the playhead; drag to select; Delete to cut. Orange words are fillers, grey capsules are pauses, the tinted word is where the playhead is.
12. **? (help).** Opens this manual in your browser.
13. **Export.** Timecoded transcript, transcript by speaker, plain text or SRT (section 11).

Every section header (Cleanup, Speakers, View, Find & Replace, Transcript) folds when you click it.

---

## Before you start

- Final Cut must be the SpliceKit copy (`~/Applications/SpliceKit/Final Cut Pro.app`), and Transcript Tab must be installed in SpliceKit's plugin folder (see the README). To remove it, delete the plugin folder and restart Final Cut.
- **Clips need a transcript.** The tab shows Final Cut's own transcripts. A clip that has none shows a **Transcribe** button (section 2). Nothing is transcribed until you click it, because transcribing saves a transcript into your library.
- **Your edits stay out of the library.** Speaker labels, speaker names and word corrections are saved in a separate file, `~/Library/Application Support/SpliceKit/transcript-tab-speakers.json`. Correcting a word changes only the text in this panel, never your media.
- **Speaker detection needs an Apple-silicon Mac** (it uses SpliceKit's Parakeet speech tools).

---

## 1. Find the tab

1. Select a clip in the browser, or in the timeline.
2. Open the inspector (**Cmd-4**) and click the tab with the little quote-lines icon. It sits right after **Info**.

For a browser clip the tabs read Video, Audio, Info, **Transcript**, Share. For a clip in the timeline they read Video, Color, Audio, Info, **Transcript**.

Titles and generators (Motion effects) get no Transcript tab. They have no speech, and adding a tab would hide their own Title / Text tabs.

**What the panel contains**, top to bottom. Each section has a header; click the header (or the "Hide" that appears when you hover) to fold it away. Folded sections are remembered.

| Section | What it holds |
|---|---|
| **Cleanup** | Delete all fillers; delete all long pauses; "Pauses longer than" sets what counts as long |
| **Speakers** | Show (one speaker or all); Detection (Detect / Re-detect) |
| **View** | Timecode style, text size, colour bars, dark background, precise word timing |
| **Find & Replace** | Search box, previous / next, Replace, All (folded until you press Cmd-F) |
| **Transcript** | The transcript itself (on Final Cut Pro 13 also a Language pop-up for Transcribe) |
| footer bar (Final Cut's own, at the bottom of the inspector) | **?** (this manual) and the **Export** menu |

---

## 2. A clip with no transcript

A clip Final Cut has not transcribed shows "This clip has no transcript yet." with a **Transcribe** button.

1. Click **Transcribe**. This does the same as **Modify > Analyze and Fix > Transcribe**.
2. The status line reads "Transcribing 1 clip…". A short clip takes a few seconds, a long one longer.
3. When Final Cut has stored the transcript, the words appear by themselves.

If it can't ("Couldn't transcribe: no audio", or Final Cut finishes without a transcript) the button comes back as **Try again**.

**Language.** On Final Cut Pro 13, choose the language in **Transcript > Language** *before* you click Transcribe. The list is Final Cut's own list of transcription languages (shown as `fr-FR`, `en-US`…). The default is the language set in Final Cut's own Analyze and Fix options (normally `en-US`). A clip that is already transcribed keeps the language it was transcribed in; changing the pop-up does not redo it.

Notes:
- Transcribing a clip in a project (timeline) transcribes its browser clip.
- Transcribing writes into the library, exactly as Analyze and Fix does. If you don't want that for a client library, don't click.

---

## 3. Source view: a clip in the browser

Select a clip in the browser. The panel shows that clip's transcript, a blank line above it, then the words in paragraphs.

- **Click a word** to put the browser playhead there. Space plays from it.
- **Playback follows along.** The word being spoken is tinted FCP-blue as the clip plays.
- **Drag across words** to mark them. The clip gets Final Cut's own In and Out range around exactly those words. Then use Final Cut's normal edit keys on the marked range:

| Key | Edit |
|---|---|
| **E** | Append to the timeline |
| **W** | Insert |
| **D** | Overwrite |
| **Q** | Connect |

Pick a sound bite by reading it, drag across it, press **E**. That is the whole workflow.

Synchronized clips (camera plus a separate recorder file) show the transcript of the audio file and line up with it, in the browser and in the timeline.

(The browser's list view works too, but drag-select with real E / W / D keys there is not yet tried by hand.)

---

## 4. Timeline view: the whole project

Select any clip in the primary storyline, or put the playhead on one. The panel shows the transcript of the **whole timeline**, in timeline order.

- Words you have trimmed away are **left out**. What you read is what plays.
- Each line carries a timecode (section 8).
- **Click a word** to move the playhead there and give the timeline focus.
- The current word is tinted while the timeline plays or you scrub, and the text redraws when you edit the timeline.
- **Drag across words** to set the timeline's In and Out around them (focus stays in the panel, so Delete still cuts).
- **Connected clips** (B-roll with sound, a voice-over, a second storyline): their speech appears **only where the primary storyline has a gap**. Over real primary dialogue, connected clips are left out so the text stays readable.

---

## 5. Cut from the text

In timeline view:

1. Drag across the words you want to remove. They highlight.
2. Press **Delete** to **ripple delete**: the words are cut out and the timeline closes up.
3. Press **Shift-Delete** to **lift** instead: the words are cut out and a gap stays.

One undo step per contiguous range. **Cmd-Z** in Final Cut undoes it (click in the timeline first if the focus is elsewhere).

Rules to know:
- A selection that covers words from **two different clips** in different lanes (a primary clip plus a connected one, or two connected clips) is refused with a beep. Select one clip's words at a time.
- Deleting words on a **connected** clip cuts only that connected clip.
- Every key other than Delete and Return is handed to Final Cut, so your usual shortcuts still work with the panel focused.

---

## 6. Clean up: fillers and pauses

**Fillers** (um, uh, er, ah, hmm…) are tinted orange. The **Delete** button next to Fillers in the Cleanup section removes all of them in one go. The number on the button is how many there are; if it reads 0 there is nothing to delete.

- Final Cut's own transcript leaves most fillers out. After you press **Speakers > Detect** (section 7), fillers that the speech model heard are put back into the text, in orange, with their real times, so they can be deleted.

**Pauses** longer than a threshold are shown as a small rounded capsule: `1.7s pause` on its own line, or `0.1s` inline.

1. Next to **Pauses longer than**, choose the shortest silence that counts as a pause: **≥ 0.3s, 0.5s, 1.0s or 2.0s**.
2. Click the **Delete** button next to Pauses (its number is how many pauses qualify). Each pause is shortened, not removed: **0.1 s of air is kept on each side**.

Bulk deletes are one undo step per range, so a long interview makes many steps. Safety: a pause over a gap that connected clips are covering is never offered for deletion, because deleting it would take the connected clips with it. Fillers inside connected clips are not counted or deleted in bulk.

---

## 7. Speakers

**Detect.**

1. Click **Detect** in the Speakers section (the Detection row). It becomes **Detecting…**, then **Re-detect**.
2. The panel gets speaker names (Speaker 1, Speaker 2…) at the start of each turn.

Detect extracts the audio (from Final Cut's **proxy** when there is one, which is much faster) and runs SpliceKit's Parakeet speech model. Rough times: about 2 s per minute of audio for the model, a few minutes for an 80-minute interview. It also **tightens the word timing** (section 9), so it is worth running even if you don't care about speaker names.

Detection is good on clean recordings. On real interviews it sometimes gives the interviewer's questions to the main speaker. Fix those by hand (below).

**Name a speaker.** **Double-click a speaker's name** to rename them everywhere in that clip. Or right-click the name and choose **Rename “Name” everywhere…**. A new name gets the first unused colour, and a rename keeps the colour.

**Fix a wrong line.** Right-click a line (or select words and right-click inside the selection) and choose the right speaker from the menu, or **New speaker…**. Right-clicking inside a selection relabels exactly that selection.

**Show one speaker.** The **Show** pop-up (All Speakers, then each name) hides everyone else. Handy for reading one person's answers.

**Colours.**
- Each speaker gets one of eight colours (amber, teal, orchid, sky, coral, lime, aqua, pink) and keeps it everywhere. They are kept apart from Final Cut's **role colours**, which mean Dialogue, Music and Effects elsewhere in Final Cut.
- **View > Color bars** (on by default) draws a thin bar beside each speaker's run of lines.
- Hover a speaker's name and a dot in their colour appears beside it. Click it to open a picker of the eight colours. Click a swatch to set the colour. Escape or a click elsewhere closes it.

**Re-detect** is safe. It keeps your speaker names, colours, corrections and line relabelling.

---

## 8. View options

| Control | Choices |
|---|---|
| **Timecode** | **Short** `0:10`; **Min:Sec:Frames** `0:10:12` (the default); **Project Timecode** `00:00:10:12` (the project's timecode in timeline view, the clip's own in source view); **Hidden** |
| **Text size** | Three **A** buttons: 100%, 125%, 150%. Scales only the transcript (text, names, timecodes, editors), not the controls |
| **Color bars** | The speaker bars described above |
| **Dark background** | Switches the transcript area from the gray of the control rows to Final Cut's darker inspector colour |
| **Precise word timing** | Use the tightened times from Detect: see below |

Timecodes sit in their own right-aligned column, and words start at a fixed indent.

---

## 9. Word timing (why it matters)

Final Cut's stored word times are approximate: a word inside a phrase is often 0.1 to 0.6 s early. That doesn't matter for reading, but it does at a **cut**: a word you have cut off can still show, or a word you can still hear can be missing.

After **Detect**, English transcripts use the **precise** times. Words are lined up with the audio itself, and an edge word shows only if enough of its main sound is inside the clip. Switch **View > Precise word timing** off to go back to Final Cut's own times.

Good to know:
- Precise timing applies to English text only. A transcript in another language (for example French) keeps Final Cut's times.
- A short "um" the speech model never heard can't show at all.
- A file detected with an older version keeps rough times until you press **Re-detect** once.

---

## 10. Find, replace and correct

**Find.** Press **Cmd-F** with the panel focused (or open **Find & Replace**) and type. Matches are highlighted, the counter shows "3 of 18", and **›** / **‹** step through them. Find matches inside words ("the" also finds "they").

**Replace.** Type in the replace box, then **Replace** (this match) or **All**.

**Correct one word.**
1. Double-click the word, or select it and press **Return**.
2. Type the right spelling.
3. **Return** saves, **Tab** saves and moves to the next word, **Escape** cancels. Saving an empty box reverts to the original.

Corrections change only the text in this panel. They are not written back into Final Cut's transcript, and there is no undo for them: to revert, clear the word.

Because corrections are keyed to the original word, they survive Re-detect.

---

## 11. Export

**Export** in the footer bar offers four formats:

| Choice | What you get |
|---|---|
| **Transcript with timecodes…** | Premiere Pro's layout: a `00;00;02;15 - 00;00;04;24` line, the speaker's name, the text, a blank line. Silences are empty blocks. Blocks break at phrase boundaries, speaker changes and pauses. Frame-accurate, so blocks never overlap. Uses `;` and drop-frame numbering on drop-frame projects, `:` otherwise |
| **Transcript by speaker…** | A title, then one block per speaker turn: `00:00:05.880 — 00:00:20.760 · Name` and the text. A new block starts when the speaker changes or after 4 s of silence; a new paragraph starts at a cut or a 1.5 s silence, only after a sentence ends. Unlabelled speakers become "Unknown". With several clips selected in the browser, each file gets its own heading and its own blocks |
| **Plain text (no timecodes)…** | Just the words, with speaker names |
| **Subtitles (SRT)…** | An .srt file |


Exports from timeline view use timeline times; from source view they use the clip's own times.

---

## Keys at a glance

| Key | What it does |
|---|---|
| Click a word | Move the playhead (browser or timeline) |
| Drag across words | Mark In / Out on the browser clip or the timeline |
| **E / W / D / Q** | Append / Insert / Overwrite / Connect the marked range (source view) |
| **Delete** | Ripple delete the selected words (timeline view) |
| **Shift-Delete** | Lift the selected words, leaving a gap |
| **Cmd-F** | Find |
| **Return** / double-click | Correct a word |
| **Tab** (editing) | Save and go to the next word |
| **Escape** | Cancel an edit, close the colour picker |
| **Cmd-Z** | Undo (Final Cut's own undo) |
| Right-click a line | Relabel as another speaker, New speaker…, Rename, Copy |
| Double-click a speaker name | Rename everywhere |

---

## Known limits

- Built for **Final Cut Pro 12.4 / 13** with **SpliceKit 3.3.9**. A Final Cut or SpliceKit update can break it.
- Not yet tried: multicam and compound clips, projects that start at a timecode other than 00:00:00:00, and retimed *connected* clips. Retimed and rate-conformed primary clips are handled.
- Final Cut's transcript decides the words. If it misheard, correct the word by hand (section 10).
- Speaker detection is partial on real interviews (see section 7).
- Find matches inside words; there is no whole-word option.
- Bulk deletes make one undo step per range.
- The tab's accessibility label reads "(null) Inspector".

If something goes wrong, the log is at `/tmp/splicekit-transcript-tab-spike.log` (`/tmp/transcript-tab.log` in the public release). Mention what you were doing and the last few lines of it.
