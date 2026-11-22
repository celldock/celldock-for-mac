# Local call API

Enable **Settings → Cellular & Communications → Local call API**, then choose
**Copy API token**. The API is off by default, listens only on `127.0.0.1:7576`,
and runs while CellDock is running (closing the window does not quit the app).
If shutdown cleanup fails or times out and quitting is cancelled, the API resumes
automatically if it is still enabled in Settings. A timeout invalidates deferred
cleanup callbacks, so a late recording completion cannot close a newer call.
If module shutdown has already started, call actions and API startup stay paused
until all module shutdown callbacks finish. CellDock then restarts the module
services and USB discovery before reopening the listener; the modules may still
need time to reconnect and initialize their SIMs. Additional quit requests are
cancelled while this in-flight cleanup is settling.

The random bearer token is stored in the macOS Keychain. Treat it as a password:
any local program holding it can control calls and read the current phone number.
Disabling the API stops accepting requests. It does not hang up an existing call
or cancel an operation already handed to the modem. To revoke a leaked token,
disable the API, delete the `bearer-token` item for service
`app.celldock.mac.local-call-api` in Keychain Access, and enable it again.

## Requests

All requests require `Authorization: Bearer <token>`. POST requests also require
`Content-Type: application/json` and a JSON object body. Use the literal loopback
address below, not `localhost` or a LAN address. Browser-origin requests and CORS
are not supported.

Set `CELLDOCK_API_TOKEN` in your program's environment to the copied token. Avoid
committing it to source control or placing it in shared logs.

```sh
# Read the current call state.
curl --noproxy '*' \
  -H "Authorization: Bearer $CELLDOCK_API_TOKEN" \
  http://127.0.0.1:7576/api/calls/status

# Dial using the communication SIM currently selected in CellDock.
# Replace the example number with the intended recipient.
curl --noproxy '*' --max-time 100 \
  -H "Authorization: Bearer $CELLDOCK_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"number":"+8613800000000"}' \
  http://127.0.0.1:7576/api/calls/dial

# Answer an incoming call.
curl --noproxy '*' --max-time 100 \
  -H "Authorization: Bearer $CELLDOCK_API_TOKEN" \
  -H 'Content-Type: application/json' -d '{}' \
  http://127.0.0.1:7576/api/calls/answer

# Hang up the current call (or reject an incoming call).
curl --noproxy '*' --max-time 100 \
  -H "Authorization: Bearer $CELLDOCK_API_TOKEN" \
  -H 'Content-Type: application/json' -d '{}' \
  http://127.0.0.1:7576/api/calls/hangup
```

| Method | Path | Body |
| --- | --- | --- |
| GET | `/api/calls/status` | No body |
| POST | `/api/calls/dial` | `{"number":"+8613800000000"}` |
| POST | `/api/calls/answer` | `{}` |
| POST | `/api/calls/hangup` | `{}` |

Numbers follow CellDock's existing dialer rules: digits with an optional leading
`+`, up to 32 characters after stripping spaces, hyphens and parentheses. AT
commands, USSD strings, and post-dial sequences are not accepted. Module selection
stays in the app; answer/hangup always use the module owning the current call.

## Responses and audio

Status returns HTTP 200 and a snapshot, for example:

```json
{"phase":"idle","audioActive":false,"muted":false,"isChangingCall":false}
```

Optional `moduleID`, `number`, and `lastError` fields are omitted when absent.
`phase` is one of `unavailable`, `idle`, `incoming`, `dialing`, `alerting`,
`active`, `ending`, `recovering`, or `error`.

### End reasons and evidence

Status and successful action snapshots also expose optional `lastEndReason` and
`lastEndEvidence`. For example, a generic modem release is reported as:

```json
{
  "phase": "idle",
  "audioActive": false,
  "muted": false,
  "isChangingCall": false,
  "lastEndReason": "unknown",
  "lastEndEvidence": {"source": "modemResultCode", "code": "NO CARRIER"}
}
```

| `lastEndReason` | Evidence | Meaning |
| --- | --- | --- |
| `localHangup` | `localAction` | CellDock requested hangup and confirmed the call list empty. |
| `busy` | `modemResultCode`, code `BUSY` | The modem explicitly reported busy. |
| `noAnswer` | `modemResultCode`, code `NO ANSWER` | The modem explicitly reported no answer. |
| `noDialTone` | `modemResultCode`, code `NO DIALTONE` or `NO DIAL TONE` | The modem reported no dial tone. |
| `unknown` | `modemResultCode`, code `NO CARRIER` | The call ended without a specific release cause. |
| `unknown` | `callListEmpty` | Polling/recovery found the voice call gone without a specific release cause. |
| `deviceDisconnected` | `deviceDisconnected` | The local module/connection was reset or disconnected. |
| `failed` | `internalFailure` | CellDock's call setup, media setup, or recovery failed. |

`code` is included only for modem result codes (trimmed and uppercased). A generic
`NO CARRIER` or empty CLCC list cannot distinguish remote hangup, rejection, a
powered-off phone, loss of signal, or a network release. The API does not invent
those distinctions or query vendor-specific release-cause commands. `remoteHangup`
remains a legacy value for reading existing call history; new generic releases
are recorded as `unknown` instead.

Late generic release indications do not overwrite a confirmed local hangup or a
specific modem result such as `NO ANSWER`. Evidence is cleared when a new call
starts. These fields may appear during cleanup/recovery before the call is
confirmed ended; check `phase` as well. They describe the current snapshot, not
an event stream or a persistent per-call result endpoint.
Reinitializing the module after cleanup, including voice-runtime initialization
retries, preserves the last end reason and evidence.

### Action results

Actions return HTTP 200 with `{"accepted":true,"call":{...}}` after the existing
CellDock operation completes. Dial success means the module accepted the dial
operation, **not that the recipient answered**. Poll status for `phase: active`
and `audioActive: true`. HTTP 409 with `{"error":"..."}` reports the original
call-operation failure, including busy state, absent SIM/module, or microphone
permission denial. Error messages from the call layer follow the app language.

The API calls the same `AppState` and `ModemService` methods as the UI. Microphone
permission, the single-call guard, eSIM-operation guards, voice-runtime setup,
audio routing, and media cleanup all remain in that path. Grant microphone access
in Settings before unattended use; an initial permission prompt can hold an action
open. Audio continues through CellDock's Mac microphone and speakers. This is a
control API; it does not stream PCM, inject TTS, or expose a SIP endpoint.

Other HTTP errors: 400 invalid JSON/framing/parameters, 401 missing or incorrect
token, 403 invalid Host or browser Origin, 404 unknown endpoint, 405 wrong method,
408 timeout, 413 oversized request, 415 incorrect content type, and 503 API stopped.
There is one request per connection, no HTTP chunking or pipelining, at most
8 KiB of headers and 4 KiB of body, 16 concurrent connections, a 5-second upload
deadline, and a 90-second operation deadline.

Do not automatically retry an action after a timeout or broken connection: the
modem may already have accepted it. Query status and reconcile with the app first.
If port 7576 is occupied, Settings shows the listener error; stop the conflicting
service and toggle the API off and on to retry.
