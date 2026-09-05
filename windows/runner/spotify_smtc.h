#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

struct SpotifyTrack {
  std::wstring title;
  std::wstring artist;
  std::wstring album;
  std::vector<uint8_t> art;
  bool is_playing = false;
  int64_t position_ms = 0;
  // Track length from the SMTC timeline (EndTime - StartTime). 0 when the
  // session does not report one. Used as the scrobble `duration` when
  // MusicBrainz enrichment is unavailable.
  int64_t duration_ms = 0;
};

// Returns the current track from any of the watched players via Windows SMTC
// (see kWatchedApps in the .cpp), or std::nullopt when none has a session.
// Names keep the Spotify prefix for history; watching is not Spotify-specific.
std::optional<SpotifyTrack> GetSpotifyCurrentTrack();

// Controls playback of the watched player via SMTC.
// action: "toggle", "next", "previous"
bool SpotifyControl(const std::string& action);
