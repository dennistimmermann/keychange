# Keychange

## Releases

Tagging `vX.Y.Z` and pushing the tag is the whole release process — `.github/workflows/release.yml`
archives, signs, notarizes, staples, publishes the GitHub release and uploads the Sparkle appcast.

**Every tagged release needs release notes.** The appcast's `<description>` is the release body
converted to HTML, and that body is what users read in Sparkle's "A new version is available" panel
before deciding to install. A release with an empty body ships an empty update panel.

The workflow creates the release with `--generate-notes`, which builds the body from commits and PRs
since the previous tag — so the notes are only as good as the commit subjects. Check the generated
body after tagging, and edit the release (or write the notes by hand) if it reads poorly. Never tag
a release whose notes you have not looked at.
