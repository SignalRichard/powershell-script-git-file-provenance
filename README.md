# Git file provenance

`Get-GitFileProvenance.ps1` exports the committed version of a file at `HEAD` as JSON. It compares file contents across the commit graph and attributes surviving Unicode code points to the commit that introduced them. Newline code points are included.

The script requires PowerShell 7 or later and Git on `PATH`.

```powershell
./Get-GitFileProvenance.ps1 -Path src/example.ps1 -OutputPath ./example.provenance.json
```

Run it from inside the repository, or pass `-RepositoryPath`. `-Path` can be repository-relative or an absolute path inside the repository. If `-OutputPath` is omitted, the JSON is written to `<repository-relative-path>.provenance.json`.

## JSON format

- `text` contains the committed file contents.
- `commits` contains the file's complete `git log --follow` history, with full SHA, author name/email, author timestamp, subject, and added/removed line counts. This includes commits that removed text no longer present in the file.
- `removalOnlyCommits` contains commits whose numstat reports removed lines and no added lines.
- `users` contains authors from the complete file history, including authors with no surviving lines.
- `lines` maps each one-based line to its zero-based Unicode code point `start` and `count`, with line-level blame commit and user indexes for summary purposes.
- `provenance` is a run-length encoded sequence. Each entry's `start` and `count` identify a contiguous range of Unicode code points, and `commit` indexes `commits`. Unlike `lines`, these ranges may start or end within a line.
- `attributionMethod`, `diffAlgorithm`, and `mergeAttribution` describe how the character mapping was calculated.

Indexes are zero-based. Matching uses a deterministic shortest edit script over Unicode code points. Repeated text can admit multiple equally short alignments; the selected alignment is deterministic, but the repository history cannot establish a unique origin in those cases. For merge commits, a surviving character keeps the first matching parent's attribution; if it matches no parent, the merge commit receives attribution. The history and removal-only sections preserve commits and authors whose text was later deleted. Binary and non-UTF-8 files are not supported.

## Static viewer

Open `index.html` in a browser and select a provenance JSON file. The page reads the selected file locally using the browser File API; it does not upload the file or require a server. Bootstrap 5.3.8 CSS and its tooltip bundle are loaded from jsDelivr, so an internet connection is needed for Bootstrap styling and interactive tooltips. Source and commit data stay in the browser.

Each author is assigned a distinct color in the current view. The curated palette starts with widely separated amber and blue colors, then uses blue/cyan, purple, and amber tones; red and green hues are skipped. Hover a character to see its author, full commit SHA, and commit subject. Line endings are shown with a small return-arrow marker so they can also be hovered. The history table includes removal-only commits and their line addition/removal counts.
