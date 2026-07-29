# Keychange

## Releases

Tagging `vX.Y.Z` and pushing the tag is the whole release process — `.github/workflows/release.yml`
archives, signs, notarizes, staples, publishes the GitHub release and uploads the Sparkle appcast.

**Every tagged release needs release notes.** `RELEASE_NOTES.md` holds the notes for the release
being cut — rewrite it in the same commit that bumps to the tag, describing that version only. The
workflow passes it to `gh release create --notes-file`, and the appcast's `<description>` is that
body converted to HTML, so it is literally what users read in Sparkle's "A new version is available"
panel before deciding to install.

Write it for the person deciding whether to install, not for the person who wrote the code: what
changed for them, in their words. Not a list of commit subjects — that is why the workflow no longer
uses `--generate-notes`. Never tag a release without updating the file first.
