# Friction log — submitting Rune to Devfolio via MCP

Written 2026-08-06, submitting to the "Fake Push to Prod" hackathon through the
Devfolio MCP server. Ordered roughly by how much time each one cost.

## Blockers

### 1. Screenshots could not be captured at all

`screencapture` failed with `could not create image from display`. The terminal
hosting the agent had no **Screen Recording** permission, and nothing in the
flow surfaced that until the command failed. There is no way for the agent to
request the permission itself — it needs a human in System Settings, followed
by a restart of the terminal app.

Worked around it by pulling frames out of `build/rune-promo.mp4` with ffmpeg.
That was luck: the file happened to exist. Without it the submission would have
stopped dead.

### 2. `pictures` is required even to save a draft

The first update call was rejected outright:

```
400: Pictures: between 1 and 6 image URLs required.
```

Every other field — name, tagline, all four organizer questions, links,
platforms — was ready and valid, and none of it could be persisted. The
submission guide does warn that "platform APIs apply the same submission rules
regardless of draft or publish status", so this is documented, but it means a
draft cannot be used to stage work in progress. Text has to wait on images.

The practical effect: a long writeup sits in agent context with no way to park
it server-side. If the session had been lost there, the work would have been
lost with it.

## Sharp edges

### 3. Signed upload URLs expire in 60 seconds

`getSignedUploadUrl` returns `X-Amz-Expires=60`. With four images that means
fetching all four URLs and PUTting all four files inside one minute, so the
uploads have to be batched into a single shell invocation. A per-image
fetch-then-upload loop with any thinking in between will start failing partway.

### 4. No upload purpose for logos or cover images

`getSignedUploadUrl` accepts only `project_field`, `hackathon_project_pic`, and
`side_project_pic`. There is no `favicon` or `cover_img` purpose, even though
both are real fields on the project. The tool docs resolve it — upload under
some other purpose and reuse the returned path — but the enum and the field
list disagree, and the correct move is guessable rather than obvious.

Uploaded the logo as `project_field` and pointed `favicon` at that path. It was
accepted.

### 5. No way to preview rendering before publishing

The `long` fields take Markdown, and there is no preview endpoint. Tables,
blockquotes, and inline code all went in unverified — whether Devfolio's
renderer produces a real table or a row of literal pipes is unknown until the
published page is opened in a browser. Formatting fixes are therefore
publish-then-look-then-fix, on a live submission.

### 6. The slug freezes on creation and cannot be changed

The project was auto-created as `Draft Project` / `draft-project-3295`. Setting
`name` to `Rune` renamed the project but left the slug untouched, and
`updateHackathonProject` exposes no slug field. The public URL keeps the
placeholder unless someone renames it in the web dashboard.

### 7. Two competing description structures

`getMyHackathonProject` returns a `description` array with Devfolio's stock
blocks — "The problem it solves", "Challenges we ran into" — while the
organizer's own questions live in `projectFieldAnswers`. When custom `long`
fields exist the stock blocks are ignored, and anything written to
`problemSolved` / `challengesSurmounted` is silently discarded. Both structures
stay in the response, permanently empty, which reads like missing data on every
subsequent fetch.

## Minor

### 8. `.icns` needs converting before upload

Uploads accept `png` / `jpg` / `jpeg` only, and the app icon ships as
`Resources/AppIcon.icns`. `iconutil -c iconset` failed on the file; `sips -s
format png -Z 1024` worked and preserved alpha.

### 9. Video could not be attached

`video_url` wants a URL. `build/rune-promo.mp4` is a local file, and there is no
upload purpose for video, so the field stays empty until the file is hosted
somewhere else.

### 10. Frames carry burnt-in promo captions

Because the screenshots came from the promo video rather than a live capture,
each one has its caption overlay baked in ("split the pane", "zoom one pane
full"). Legitimate footage of the running app, but not clean product shots.

### 11. `getMyHackathonProject` duplicates its whole payload

The response contains the full project object twice — once at the top level and
again nested under `project`, byte-for-byte identical. Roughly doubles the size
of an already large response, which matters when it has to be read repeatedly to
verify state.

## What would have helped most

1. Let drafts save without images. Everything else follows from that.
2. Longer expiry on signed upload URLs, or a batch endpoint.
3. A `renderPreview` call that returns the HTML a `long` field will produce.
4. `favicon` and `cover_img` purposes on `getSignedUploadUrl`.
5. A slug field on update, or auto-slug from `name` while still a draft.
