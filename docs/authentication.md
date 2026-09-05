# Authentication

The app authenticates one way: **an app-password session against the user's own
Bluesky PDS**. Scrobbles are written as `app.rocksky.scrobble` records directly
to that PDS. There is no Rocksky API path — nothing is submitted to
`audioscrobbler.rocksky.app`, and no API key or shared secret is involved.

---

## Bluesky PDS Auth

### What the user provides

On the setup screen (`HomeScreen` → `_SetupView`), the user enters:

- **Bluesky handle** (e.g. `you.bsky.social`)
- **App password** (created at `bsky.app/settings/app-passwords`)

### Flow

```
User clicks Connect PDS
        │
        ▼
Dart: PdsService.login(handle, appPassword)
        │
        ▼
POST https://bsky.social/xrpc/com.atproto.server.createSession
     body: {"identifier": "...", "password": "..."}
        │
        ▼
Receive accessJwt + refreshJwt + did + didDoc
        │
        ▼
Resolve actual PDS from DID document service #atproto_pds
        │
        ▼
Re-authenticate at actual PDS if different from the one just used
        │
        ▼
Return PdsService instance with pdsUrl, accessJwt, refreshJwt, did
        │
        ▼
Persist session → start MediaWatcherService polling
```

### Key implementation

`lib/services/pds_service.dart`:

`login()` is a thin entry point — all the work happens in the private
`_createSession`, which calls itself once if the DID document points somewhere
other than where it just authenticated:

```dart
static Future<PdsService?> login({
  required String handle,
  required String appPassword,
  Future<void> Function(PdsService service)? onSessionRefreshed,
}) async {
  return _createSession(
    handle: handle,
    appPassword: appPassword,
    pdsUrl: 'https://bsky.social',
    onSessionRefreshed: onSessionRefreshed,
  );
}

static Future<PdsService?> _createSession({...}) async {
  // 1. Create a session at whichever host we were pointed at.
  final resp = await http.post(
    Uri.parse('$pdsUrl/xrpc/com.atproto.server.createSession'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'identifier': handle, 'password': appPassword}),
  ).timeout(const Duration(seconds: 15));
  if (resp.statusCode != 200) return null;

  // 2. Extract the DID and the DID document.
  final did = data['did'] as String;
  final didDoc = data['didDoc'] as Map<String, dynamic>?;

  // 3. Find the #atproto_pds service endpoint.
  var actualPds = pdsUrl;
  for (final svc in services) {
    if (svc is Map && svc['id'] == '#atproto_pds') {
      actualPds = svc['serviceEndpoint'] as String;
      break;
    }
  }

  // 4. If it is somewhere else, authenticate there instead.
  //    Compared against pdsUrl, not a hardcoded bsky.social — the recursive
  //    call would otherwise loop on a self-hosted PDS.
  if (actualPds != pdsUrl) {
    return _createSession(handle: ..., appPassword: ..., pdsUrl: actualPds, ...);
  }

  return PdsService._(
    pdsUrl: actualPds,
    accessJwt: jwt,
    refreshJwt: refreshJwt,
    did: did,
    onSessionRefreshed: onSessionRefreshed,
  );
}
```

Every failure path returns `null` rather than throwing — a bad password, a
non-200, a timeout and a socket error are indistinguishable to the caller, which
shows one generic *"PDS authorization failed — check your handle and app
password"*. Details go to the debug log.

### Session persistence

The app password itself is **never stored**. It is exchanged once for a session,
and only the session is persisted — encrypted — through
`lib/services/credential_store.dart`:

```dart
await CredentialStore.instance.save((
  pdsUrl: service.pdsUrl,
  accessJwt: service.accessJwt,
  refreshJwt: service.refreshJwt,
  did: service.did,
));
```

The four values are serialised to JSON, encrypted with the Windows Data
Protection API, and written base64-encoded to a single `pds_session` key. On
launch, `HomeScreen._loadCredentials()` calls `CredentialStore.instance.load()`
and, if a session comes back, restores it via `PdsService.fromSession()` and
checks it against the PDS before scrobbling resumes (see
[Revoked sessions](#revoked-sessions) below).

#### Why the session is encrypted at rest

`refreshJwt` is the value that matters. It mints access tokens indefinitely and
authorises `applyWrites#delete` against the user's repository, so a copy of it
can **erase a scrobble history**, not merely add to it. Until this was added the
four values sat in `shared_preferences.json` as readable strings, where a
backup, a synced folder, another account on the same PC or a USB stick would
have exposed them.

#### What DPAPI does and does not protect against

`CryptProtectData` derives its key from the signed-in user's credentials and
Windows keeps it; the app stores no key of its own, because a key it stored
would be a key it could leak. See `lib/services/dpapi.dart`.

It defends against the file being read somewhere it should not be. It does
**not** defend against code already running as the user — that code can call
`CryptUnprotectData` exactly as the app does. Nor is it absolute at rest: the
DPAPI master key is wrapped with the user's Windows password, so an attacker
holding both that password and a copy of the profile directory can decrypt
offline, and an account with no password gives it very little to work with.

Stronger options exist and all of them cost something this app cannot currently
spend. A TPM-sealed key (CNG's Platform Crypto Provider) would survive the
stolen-password case but needs a TPM. Windows Hello or a passphrase would beat
an offline attacker outright, but both require a person at the keyboard, and
this is a tray app expected to start with Windows and scrobble unattended —
DPAPI is the strongest option that never prompts.

The control that still works after a leak is revocation: an app password can be
revoked from Bluesky's settings, which invalidates every session derived from
it.

#### Failure modes

All three are deliberate, and all three end at the sign-in form rather than at
an error:

| Situation | Behaviour |
|---|---|
| Blob was encrypted by another Windows account or on another machine | `CryptUnprotectData` fails, the key is deleted, the user signs in again |
| Blob is damaged or truncated | Same — DPAPI's integrity check rejects it |
| Windows refuses to encrypt on save | Nothing is written. Scrobbling continues for the session; signing in is needed next launch |

That last one is why `CredentialStore.save()` returns a `bool` and never falls
back to writing plaintext: a silent fallback would undo the only thing the class
exists for.

A portable copy is affected by the first row. Settings travel with the folder,
but the session inside them is bound to the Windows account that created it, so
the same stick plugged into a different PC asks for a fresh sign-in. That is a
consequence of not asking for a passphrase, and it is also the behaviour you
would want from credentials on a stick that goes missing. See
[`portable-build.md`](portable-build.md).

#### Migration

Sessions written in the clear by earlier builds are read once, re-saved
encrypted, and the plaintext keys (`pds_url`, `pds_access_jwt`,
`pds_refresh_jwt`, `pds_did`) deleted. The user stays signed in across the
upgrade. The plaintext copies are removed even if re-encrypting fails —
otherwise a machine where DPAPI is unavailable would quietly keep storing
credentials exactly as before, which is the one outcome worth avoiding.

### Token refresh

`PdsService` decodes the `exp` claim of the access JWT. Every authenticated
request goes through `_postWithAuthRefresh` / `_getWithAuthRefresh`, which:

1. Refresh **pre-emptively** when the access JWT is within two minutes of expiry
   (or already past it).
2. Send the request.
3. If the response is a 400/401 whose body says `error: "ExpiredToken"`, refresh
   and replay the request **once**. A second `ExpiredToken` is returned to the
   caller as a failure rather than retried again.

Refreshing calls `com.atproto.server.refreshSession` with the *refresh* JWT as
the bearer token, and hands the new pair back through the `onSessionRefreshed`
callback, which re-persists them. A refresh JWT that has itself been revoked or
expired makes refreshSession return a 400/401 (`ExpiredToken`,
`InvalidToken`, …) — that is not treated as an ordinary failed write but as a
**revoked session**, handled as described next.

An expiry-unparseable token (`exp` missing or non-numeric) is treated as *not*
needing refresh, so a token the app cannot read still gets its one
`ExpiredToken`-triggered retry rather than being refreshed on every call.

### Revoked sessions

Revoking an app password in Bluesky's settings invalidates every session
derived from it. Because access tokens are stateless JWTs the PDS cannot
refuse individually, the breakage only becomes visible when a refresh is
attempted — and before this was handled, the app would sit in a loop of
failed refreshes and failed scrobbles until restarted, with nothing on
screen to say why. Now the session is treated as dead the moment the PDS
says so, in two places:

- **On launch.** `HomeScreen._loadCredentials()` calls
  `PdsService.checkSession()`, which runs `refreshSession` against the saved
  tokens. A rejection discards the saved session (it can never work again)
  and shows the dialog below. A network failure is *not* a rejection: the
  session is resumed unverified, and the first real write remains the test —
  a genuine rejection there lands in the same handler.
- **Mid-run.** `PdsService` fires its `onSessionInvalid` callback once when
  a `refreshSession` call is definitively rejected (400/401 with an auth
  error code; a 5xx or timeout is never one). `HomeScreen` responds by
  signing out without confirmation — the session is beyond saving — and
  showing the dialog. The in-flight scrobble's retry loop stops when it
  notices the session is gone.

Both paths end the same way: the app returns to the sign-in form with a
dialog explaining that the app password was revoked or expired, and a
**Open app passwords** button that opens
`https://bsky.app/settings/app-passwords` in the user's default browser
(`lib/services/browser.dart`, `ShellExecuteW` — no `url_launcher`
dependency). The user creates a new app password and signs in with it.

The distinction matters for self-hosted or momentarily-broken setups: only
the PDS saying *"this token is dead"* forces a sign-out. Anything else keeps
the session and retries.

### Signing out

The sign-out button in the top bar asks for confirmation first (`Sign out?`),
because the saved session is discarded and the user must re-enter their handle
and app password to reconnect. Confirming clears every `pds_*` key, stops the
media watcher, and returns to the setup screen.

### Legacy credential cleanup

Earlier builds supported an alternative Rocksky API path and stored
`rocksky_api_key`, `rocksky_shared_secret`, `rocksky_session_key`, and
`use_direct_pds_writes`. Those keys are now purged on every launch and on
sign-out, so stale credentials do not linger on disk after upgrading.
