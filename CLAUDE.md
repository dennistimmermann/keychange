# Keychange

## Releases

Tagging `vX.Y.Z` and pushing the tag is the whole release process — `.github/workflows/release.yml`
archives, signs, notarizes, staples, publishes the GitHub release and uploads the Sparkle appcast.

**Every tagged release needs release notes.** `RELEASE_NOTES.md` holds the notes for the release
being cut — rewrite it in the same commit that bumps to the tag, describing that version only. The
workflow passes it to `gh release create --notes-file`, and the appcast's `<description>` is that
body converted to HTML, so it is literally what users read in Sparkle's "A new version is available"
panel before deciding to install.

Keep it brief: a plain list of what was added, what changed, and what was fixed — one line each, in
the user's terms, not the code's. No prose paragraphs, no narrating the reasoning, and not a dump of
commit subjects (which is why the workflow no longer uses `--generate-notes`). Never tag a release
without updating the file first.

Layout and visual polish — spacing, alignment, how a value is formatted — stays out of the notes
unless I ask for it. Features, behaviour changes and bug fixes go in.
