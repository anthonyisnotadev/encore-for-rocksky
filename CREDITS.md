# Credits and third-party licenses

encore for rocksky is licensed under the **GNU Affero General Public License
v3.0 or later** (see [`LICENSE`](LICENSE)). The components below keep their own
licenses and are **not** relicensed under the AGPL — they are redistributed
alongside this program under the terms granted by their respective authors.

## Application icon

The app icon is the guitar emoji (U+1F3B8) from **OpenMoji**.

> All emojis designed by [OpenMoji](https://openmoji.org) — the open-source
> emoji and icon project. License: [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)

Source file: `assets/openmoji/1F3B8_color.ico` (unmodified OpenMoji export).
The shipped icons — `assets/app_icon.ico` and
`windows/runner/resources/app_icon.ico` — are multi-resolution ICO renderings of
that same artwork.

The artwork remains under CC BY-SA 4.0. It is aggregated with this program, not
adapted into it, so the ShareAlike term applies to the artwork alone and does not
extend to the source code of this application.

## Vendored source

| Component | Copyright | License |
| --- | --- | --- |
| [`local_notifier`](https://github.com/leanflutter/local_notifier) 0.1.6 — vendored fork, see [`third_party/local_notifier/FORK.md`](third_party/local_notifier/FORK.md) | 2022-present LiJianying | MIT |
| [WinToast](https://github.com/mohabouje/WinToast) (`third_party/local_notifier/windows/wintoastlib.*`) | 2016-2019 Mohammed Boujemaoui | MIT |

Full license text: [`third_party/local_notifier/LICENSE`](third_party/local_notifier/LICENSE).

## Dependencies

Direct dependencies from `pubspec.yaml`; each is fetched from pub.dev at build
time rather than vendored here.

| Package | License |
| --- | --- |
| `fluent_ui` | BSD-3-Clause |
| `http` | BSD-3-Clause |
| `shared_preferences` | BSD-3-Clause |
| `system_theme` | BSD-3-Clause |
| `flutter_acrylic` | MIT |
| `file_picker` | MIT |
| `tray_manager` | MIT |
| `window_manager` | MIT |
| Flutter SDK | BSD-3-Clause |

`local_notifier` is also a direct dependency, but it resolves to the vendored
fork above rather than to pub.dev — see the `dependency_overrides` block in
`pubspec.yaml`.

Transitive dependencies keep their own licenses too; `pubspec.lock` is the full
list. One worth naming because it arrives through the vendored fork rather than
through pub.dev resolution of this app's own manifest:

| Package | Pulled in by | License |
| --- | --- | --- |
| `uuid` | `third_party/local_notifier` | MIT |

## Services

This app talks to third-party services it is not affiliated with. Their data is
subject to their own terms:

- **MusicBrainz** — metadata enrichment on every scrobble. Data is licensed
  CC0 / CC BY-NC-SA depending on the field; see
  [musicbrainz.org/doc/About/Data_License](https://musicbrainz.org/doc/About/Data_License).
  Requests identify the app with a `User-Agent` carrying a contact address, as
  [their rate-limiting policy requires](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting).
- **Cover Art Archive** — album art URLs for enriched records. A joint
  MusicBrainz / Internet Archive project; artwork is contributed under the
  terms at [coverartarchive.org](https://coverartarchive.org).
- **iTunes Search API** — cover art shown in the mini-player when Windows SMTC
  supplies none. Display only; nothing from it is written into a record.
  Subject to Apple's API terms.
- **Spotify Web API** — optional metadata enrichment on the experimental import
  path, using credentials the user supplies. Subject to the Spotify Developer
  Terms.
- **Bluesky / AT Protocol** — scrobbles are written to the user's own PDS.
