#include "spotify_smtc.h"

#include <algorithm>
#include <cwctype>
#include <future>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Storage.Streams.h>

using namespace winrt;
using namespace Windows::Media::Control;

namespace {

// Substrings (lowercase; matched case-insensitively) of the
// SourceAppUserModelId of players this app watches. Any app that integrates
// with the Windows media controls shows up in SMTC — including browsers
// playing video — so the list keeps non-music sources out of the scrobble
// stream. Keep in sync with the "Supported players" list in README.md.
const wchar_t* kWatchedApps[] = {
    L"spotify",                  // Spotify desktop and Microsoft Store builds
    L"applemusic",               // Apple Music (Microsoft Store)
    L"itunes",                   // iTunes
    L"deezer",
    L"tidal",
    L"amazonmusic",              // Amazon Music
    L"youtubemusic",             // YouTube Music desktop clients
    L"qobuz",
    L"vlc",                      // VideoLAN VLC
    L"foobar2000",
    L"musicbee",
    L"winamp",
    L"mediamonkey",
    L"aimp",
    L"dopamine",
    L"cider",                    // third-party Apple Music client
    L"zunemusic",               // Groove Music
    L"microsoft.media.player",  // Windows 11 Media Player
};

bool IsWatchedApp(const std::wstring& appId) {
  std::wstring lower;
  lower.reserve(appId.size());
  std::transform(appId.begin(), appId.end(), std::back_inserter(lower),
                 [](wchar_t c) {
                   return static_cast<wchar_t>(std::towlower(c));
                 });
  for (const wchar_t* name : kWatchedApps) {
    if (lower.find(name) != std::wstring::npos) return true;
  }
  return false;
}

// Picks the session to watch among the matched players: a playing one when
// any is playing (so a paused player does not shadow it), otherwise the
// first match in SMTC's most-recently-used ordering. Returns a null session
// when no watched app has an SMTC session.
GlobalSystemMediaTransportControlsSession FindWatchedSession(
    const GlobalSystemMediaTransportControlsSessionManager& manager) {
  GlobalSystemMediaTransportControlsSession fallback{nullptr};
  for (auto const& session : manager.GetSessions()) {
    if (!IsWatchedApp(std::wstring(session.SourceAppUserModelId()))) continue;
    if (fallback == nullptr) fallback = session;
    try {
      auto playback = session.GetPlaybackInfo();
      if (playback &&
          playback.PlaybackStatus() ==
              GlobalSystemMediaTransportControlsSessionPlaybackStatus::
                  Playing) {
        return session;
      }
    } catch (...) {
    }
  }
  return fallback;
}

}  // namespace

std::optional<SpotifyTrack> GetSpotifyCurrentTrack() {
  // WinRT async .get() must not be called from an STA thread (the Flutter
  // platform thread).  Dispatch to a background MTA thread instead.
  return std::async(std::launch::async, []() -> std::optional<SpotifyTrack> {
    winrt::init_apartment();
    std::optional<SpotifyTrack> result;
    try {
      auto manager =
          GlobalSystemMediaTransportControlsSessionManager::RequestAsync()
              .get();
      auto session = FindWatchedSession(manager);
      if (session != nullptr) {
        auto props = session.TryGetMediaPropertiesAsync().get();
        if (props) {
          SpotifyTrack track{
              .title = std::wstring(props.Title()),
              .artist = std::wstring(props.Artist()),
              .album = std::wstring(props.AlbumTitle()),
          };

          // Playback status.
          try {
            auto playback = session.GetPlaybackInfo();
            if (playback) {
              track.is_playing =
                  playback.PlaybackStatus() ==
                  GlobalSystemMediaTransportControlsSessionPlaybackStatus::
                      Playing;
            }
          } catch (...) {
          }

          // Playback position (for repeat detection) and track length.
          try {
            auto timeline = session.GetTimelineProperties();
            if (timeline) {
              track.position_ms =
                  timeline.Position().count() / 10000;  // 100ns → ms
              // Rocksky's lexicon requires a positive `duration` on every
              // scrobble, so read it here rather than depending on the
              // MusicBrainz lookup succeeding.
              int64_t span = timeline.EndTime().count() -
                             timeline.StartTime().count();
              if (span > 0) track.duration_ms = span / 10000;  // 100ns → ms
            }
          } catch (...) {
          }

          // Album art thumbnail.
          try {
            auto thumbnail = props.Thumbnail();
            if (thumbnail) {
              auto stream = thumbnail.OpenReadAsync().get();
              uint64_t streamSize = stream.Size();
              if (streamSize > 0 && streamSize < 5'000'000) {
                uint32_t size = static_cast<uint32_t>(streamSize);
                auto inputStream = stream.GetInputStreamAt(0);
                Windows::Storage::Streams::DataReader reader(inputStream);
                uint32_t loaded = reader.LoadAsync(size).get();
                if (loaded > 0) {
                  std::vector<uint8_t> bytes(loaded);
                  reader.ReadBytes(bytes);
                  track.art = std::move(bytes);
                }
              }
            }
          } catch (...) {
          }

          result = std::move(track);
        }
      }
    } catch (...) {
      // SMTC may be unavailable in some environments
    }
    winrt::uninit_apartment();
    return result;
  }).get();
}

bool SpotifyControl(const std::string& action) {
  return std::async(std::launch::async, [action]() -> bool {
    winrt::init_apartment();
    bool ok = false;
    try {
      auto manager =
          GlobalSystemMediaTransportControlsSessionManager::RequestAsync()
              .get();
      auto session = FindWatchedSession(manager);
      if (session != nullptr) {
        if (action == "toggle")
          ok = session.TryTogglePlayPauseAsync().get();
        else if (action == "next")
          ok = session.TrySkipNextAsync().get();
        else if (action == "previous")
          ok = session.TrySkipPreviousAsync().get();
      }
    } catch (...) {
    }
    winrt::uninit_apartment();
    return ok;
  }).get();
}
