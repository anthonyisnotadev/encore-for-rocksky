# Spotify History Import

This feature lets users backfill their listening history by uploading Spotify's **extended streaming history** JSON files directly to their Bluesky PDS as `app.rocksky.scrobble` records.

> **Experimental — not in default builds.** This feature is gated behind the
> compile-time flag `kSpotifyImportEnabled` (`lib/feature_flags.dart`). Release
> builds constant-fold it away, so the dialog and its services are absent from
> the shipped binary. Build with it on:
>
> ```
> flutter run -d windows --dart-define=ENABLE_SPOTIFY_IMPORT=true
> ```
>
> It stays in `lib/` (rather than on a branch) so `flutter analyze` keeps
> type-checking it against `PdsService` as that evolves.

## Where the data comes from

Users download their extended streaming history from:

```
https://www.spotify.com/account/privacy/
```

This produces one or more JSON files (e.g. `Streaming_History_Audio_2023.json`).

## Import pipeline

```
Spotify JSON files
        │
        ▼
SpotifyImportService.parseFiles()
   - Read JSON
   - Filter: msPlayed >= 30 s
   - Filter: skipped == false (unless user opts in)
   - Deduplicate by (artist, track, timestamp)
   - Sort chronologically
        │
        ▼
SpotifyImportDialog (_Step.select)
   - File picker (multi-select .json)
   - Show count after filtering
   - Collect Bluesky handle + app password
   - Optional: Spotify Web API credentials
   - (MusicBrainz enrichment is not optional — see below)
        │
        ▼
PdsService.login()
   - Authenticate with PDS
        │
        ▼
Track enrichment
   ├─ Spotify API path: bulk fetch 50 tracks/request
   │     └─ MusicBrainz ISRC → MBID lookup
   └─ MusicBrainz-only path: inline lookup per track
        │
        ▼
PdsService.writeScrobbles()
   - If overwrite: delete existing records with matching timestamps
   - Per entry: fall back to a built-in MusicBrainz lookup if still unenriched
   - Skip (and count as failed) records missing a required field
   - Create one `app.rocksky.scrobble` record per surviving entry
        │
        ▼
Result screen (_Step.done)
```

## Parsing & filtering

`SpotifyImportService.parseFiles()` (`lib/services/spotify_import_service.dart`):

```dart
static const _minPlayMs = 30000;  // 30 seconds

// Filter out podcasts and entries missing track/artist
final entry = SpotifyHistoryEntry.fromJson(item);
if (entry == null) continue;

// Filter by minimum play time
if (entry.msPlayed < _minPlayMs) continue;

// Filter skipped tracks (unless user checks "Include skipped")
if (!includeSkipped && item['skipped'] == true) continue;
```

Deduplication uses a composite key:

```dart
final key = '${e.artistName}|${e.trackName}|${e.timestamp.millisecondsSinceEpoch}';
```

## Enrichment strategies

Enrichment always happens. The dialog's only enrichment control is the
**"Also use the Spotify Web API"** checkbox (**off by default**), which selects
between the paths below; it cannot turn enrichment off. `SpotifyImportDialog`
passes its choice to `writeScrobbles` as either a pre-built `enrichment` map or
an inline `enrichFn`.

Because the box starts off, **path 3 is what a default import does**: a
MusicBrainz lookup per entry, run by `PdsService` itself. Paths 1 and 2 are
opt-in.

### 1. Spotify Web API (fastest, requires credentials)

Chosen when the box is ticked *and* a Client ID and Secret are supplied *and*
the client-credentials auth succeeds:

1. Authenticate via the client-credentials flow.
2. Batch-fetch track metadata from `api.spotify.com/v1/tracks?ids=...` (50 per request).
3. Extract: duration, track number, disc number, album art, release date, artist list, Spotify URL, ISRC.
4. For each ISRC, look up the MusicBrainz recording MBID via `musicbrainz.org/ws/2/isrc/{isrc}`, spaced 1.1 s apart.

The result is a `Map<spotifyTrackUri, EnrichedTrackMeta>`, so entries whose JSON
has no `spotify_track_uri` are not covered by it.

### 2. MusicBrainz-only (no credentials needed)

Used when the box is ticked but Spotify credentials are absent or their auth
failed. The dialog builds its own `MusicBrainzEnrichmentService` and passes it
as `enrichFn`. For each track, `lookupTrack`:

1. Searches `ws/2/recording?query=recording:"..." AND artist:"..." AND release:"..."` with `limit=5`.
2. Takes the first hit, then re-fetches it in full via
   `ws/2/recording/{mbid}?inc=artist-credits+releases+media` — the search result
   alone does not carry release media.
3. Extracts recording MBID, length, and artist credits with MBIDs.
4. Picks the release whose title matches the album case-insensitively, else the first.
5. Reads track/disc number off that release's media, and cover art from
   `coverartarchive.org/release/{mbid}`.

Caching is deliberately split in two: successful results and confirmed
"MusicBrainz has no such recording" answers are cached by `(artist, title,
album)`, but **transient** failures (503, timeout) are not — otherwise one blip
would mark a song unenrichable for the rest of the process. Cover art is cached
separately by release MBID.

### 3. The unconditional fallback

Whatever the dialog decides, `PdsService.writeScrobbles` runs its **own**
MusicBrainz lookup for any entry it still has no metadata for. That covers two
cases: entries the Spotify map did not include (no `spotify_track_uri`, or not
found), and the box being unticked, which sends neither an `enrichment` map nor
an `enrichFn`.

So leaving the box off does not disable MusicBrainz — it is behaviourally
identical to path 2, just using `PdsService`'s enricher instead of the dialog's.
That is why defaulting the box off costs nothing: the default import is already
fully enriched.
This is deliberate: direct PDS writes should never produce metadata-poor
records, and enrichment is the only source of `duration` on the import path, so
a control that genuinely disabled it would make every record fail the
required-field check and import nothing. The checkbox is named for the one
thing it does decide — see the doc comment on `_useSpotifyApi`.

Rate limiting: MusicBrainz requests are spaced at least **1.1 seconds** apart,
Cover Art Archive requests **0.5 seconds**. `_mbGet` retries a failed request up
to 3 times with a `2s × attempt` backoff. Both enrichment paths send the
`EncoreForRocksky/1.0.0 ( … )` User-Agent that MusicBrainz requires; anonymous
clients get throttled harder and 503 sooner.

## Writing to PDS

`PdsService.writeScrobbles()` creates AT Protocol records:

```dart
final duration = meta?.durationMs ?? durationMsFallback;
final record = {
  '\$type': 'app.rocksky.scrobble',
  'title': e.trackName,
  'artist': e.artistName,
  'album': e.albumName,
  'albumArtist': e.artistName,
  // Falls back only when enrichment returned an *empty* list, not just null.
  'artists': meta?.artists.isNotEmpty == true
      ? meta!.artists
      : [{'name': e.artistName}],
  'createdAt': e.timestamp.toUtc().toIso8601String(),
  'tags': [],
  // Prefer the enriched URL; otherwise derive one from the Spotify URI that
  // was already in the history JSON.
  if (meta?.spotifyUrl != null)
    'spotifyLink': meta!.spotifyUrl
  else if (e.spotifyTrackUri != null)
    'spotifyLink': _spotifyUriToUrl(e.spotifyTrackUri),
  if (meta?.mbid != null) 'mbid': meta!.mbid,
  if (meta?.year != null) 'year': meta!.year,
  if (meta?.releaseDate != null) 'releaseDate': meta!.releaseDate,
  if (duration != null && duration > 0) 'duration': duration,
  if (meta?.trackNumber != null) 'trackNumber': meta!.trackNumber,
  if (meta?.discNumber != null) 'discNumber': meta!.discNumber,
  if (meta?.albumArtUrl != null) 'albumArtUrl': meta!.albumArtUrl,
};
```

`_scrobbleRecord` is shared with the live scrobble path, which passes a
`durationMsFallback` read off the SMTC timeline. **Import has no such
fallback** — there is no SMTC session for a play that happened last year — so
an imported entry's `duration` comes from enrichment or not at all.

### The required-field gate

Every record is checked locally before it is sent, against the fields
`app.rocksky.scrobble` marks required: `title`, `artist`, `album`,
`albumArtist`, and a `duration` of at least 1 ms. Entries that fail are
**skipped and counted as `failed`**, not written.

`duration` is the field this turns on in practice, and the only source for an
imported entry is enrichment. The service deliberately does **not** fall back to
`msPlayed`: that is how long the track played, which equals its length only on a
complete play, and a wrong duration would be baked into a permanent record. So
tracks that enrichment cannot resolve are the ones that show up in the `failed`
count.

The check is client-side because a PDS cannot resolve a third-party NSID: it
stores malformed records happily and returns 200, and Rocksky's firehose
consumer drops them at ingest. See [`data-models.md`](data-models.md#required-scrobble-fields).

Records that pass are POSTed one at a time to `com.atproto.repo.createRecord`.
There is no batching on the write path — only on the delete path below.

### Overwrite mode

If `overwrite = true`, the service first scans existing records and deletes any whose `createdAt` matches an incoming entry, preventing duplicates on re-import.

**This is destructive and irreversible.** The deletes go to the user's own PDS
and there is no undo. It is therefore opt-in: `_overwrite` in
`SpotifyImportDialog` defaults to `false`, is surfaced as an unchecked box
labelled "Replace existing scrobbles at these times", and warns in-line when
ticked. Leaving it off makes the import purely additive. Do not restore a
hardcoded `overwrite: true` at the call site.

```dart
// 1. List existing records (com.atproto.repo.listRecords, 100 at a time,
//    reverse=true, following the cursor; stops early once as many matches
//    have been found as there are incoming timestamps)
// 2. Collect the rkeys of records whose createdAt is in the incoming set
// 3. Delete in batches of 200 via com.atproto.repo.applyWrites#delete
```

Matching is on the exact `createdAt` string, and records with no `createdAt` are
skipped rather than deleted — so only records written at exactly those instants
are touched. A batch the PDS rejects is not counted as deleted.

If the scan fails, the loop breaks and deletes whatever it has matched *so far*:
a failure on the first page therefore deletes nothing, while one partway through
pagination still deletes the earlier pages' matches. That is a narrower guarantee
than "all or nothing", and it is why cancelling mid-import cannot be made safe
(see below).

Selectivity is what `test/pds_delete_scrobbles_test.dart` covers — this is the
only code in the app that destroys user data.

> **Deletes happen before any writing, and cancelling does not undo them.**
> `writeScrobbles` runs the whole delete pass up front, then writes entries one
> at a time checking `isCancelled()` between each. Cancelling an overwrite
> import partway through therefore leaves the old records gone and only some of
> the new ones written. There is no rollback.

## UI flow

`SpotifyImportDialog` uses a 3-state enum:

```dart
enum _Step { select, importing, done }
```

- **select** — File picker (multi-select `.json`), parsed stats, "Include
  skipped tracks", Bluesky handle + app password, the overwrite checkbox with
  its inline warning, and the Spotify Web API checkbox with its credential
  fields.
- **importing** — Progress bar, status text, Cancel button. Cancel sets
  `_cancelled`, which is polled between entries — it stops the next write rather
  than aborting the one in flight.
- **done** — Success/failure counts, Close button.

The dialog collects its own handle and app password and calls `PdsService.login`
itself; it does not reuse the session `HomeScreen` already holds.
