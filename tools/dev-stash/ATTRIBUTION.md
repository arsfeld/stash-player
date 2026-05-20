# Dev-stash clip attribution

The dev backend's library is populated by `populate.sh` from
`clips.json`. Most clips ultimately derive from the Blender
Foundation's open movies, which are released under **CC-BY 3.0** —
attribution is required.

This file is the attribution surface for every clip in `clips.json`.
Anything new added to the manifest should also be added here.

## Sources

### Blender Foundation open movies (CC-BY 3.0)

The Blender Open Movie Project. Big Buck Bunny, Sintel, and the
"peach" trailer are derivative samples of these films.

- Big Buck Bunny — © 2008, Blender Foundation / www.bigbuckbunny.org
- Sintel — © 2010, Blender Foundation / www.sintel.org
- Big Buck Bunny ("peach") trailer — © Blender Foundation / peach.blender.org

License: <https://creativecommons.org/licenses/by/3.0/>

### test-videos.co.uk

Re-encodes of the Blender open movies plus a synthetic "Jellyfish"
test pattern at multiple resolutions / codecs / sizes. Provided by
the site as free-to-use sample content; underlying material remains
CC-BY 3.0 (Blender) where applicable.

- <https://test-videos.co.uk/>

### media.w3.org

W3C-hosted HTML5 video test content. `movie_300.mp4` is W3C test
material; `sintel/trailer.mp4` and `bunny/trailer.mp4` are CC-BY 3.0
Blender Foundation trailers re-hosted by the W3C.

- <https://media.w3.org/2010/05/>

### download.blender.org

Official Blender Foundation trailer hosting.

- <https://download.blender.org/peach/trailer/>

## Notes

- These clips exist only on a developer's local machine; the bind
  mount is gitignored and the videos are never committed.
- The dev backend is **not** suitable for project screenshots that
  ship publicly — Blender's licence requires attribution and the
  README's screenshots policy is to use `tools/mock-stash/` (SFW
  gradient thumbnails, no real footage) instead.
- To replace these clips with content under a different licence,
  edit `clips.json` and update this file accordingly.
