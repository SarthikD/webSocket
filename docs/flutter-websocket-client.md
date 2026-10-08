# Flutter WebSocket client: live-location and live-chat

This guide covers the Flutter client for Socket.IO live-location and live-chat on the Haven backend. The working implementation lives in `lib/`, and this guide points to the relevant files instead of repeating the code.

Backend: NestJS Socket.IO namespace `/ws`. The transport is **websocket only**, and the JWT goes in `auth.token`.

Package: [`socket_io_client`](https://pub.dev/packages/socket_io_client) `^3.1.6`.

## Code map

| File | Responsibility |
|------|----------------|
| `lib/config.dart` | `BASE_URL` (via `--dart-define`), namespace, GPS send interval |
| `lib/core/api_client.dart` | REST calls, unwraps `{ data }`, Bearer header, retries once after refresh on 401 |
| `lib/core/session.dart` | Tokens in secure storage, JWT `exp` based refresh, pushes `auth:refresh` |
| `lib/socket/haven_socket.dart` | App-wide socket singleton, event streams, ack futures, auto re-join after reconnect |
| `lib/socket/live_location_socket.dart` | Share room: `subscribe`, `location:updated`, `share:stopped`, GPS emit |
| `lib/socket/live_chat_socket.dart` | Incident room: chat, typing, `location:update`, status events |
| `lib/services/location_tracker.dart` | `geolocator` stream throttled to one fix every 3 s |
| `lib/services/google_sign_in_service.dart` | google_sign_in 7.x wrapper, returns Google ID token for `POST /auth/google` |
| `lib/screens/*` | Login (OTP or Google), AddPhone (attach phone to Google account), Home (SOS / share / incoming), Incident (chat + live), Share |

---

## 1. Setup

```yaml
dependencies:
  socket_io_client: ^3.1.6
  http: ^1.6.0
  uuid: ^4.6.0
  geolocator: ^14.0.3
  flutter_secure_storage: ^11.2.0
```

A physical phone cannot reach `localhost`. Use your LAN IP or a tunnel:

```sh
flutter run --dart-define=BASE_URL=http://192.168.1.10:3300
```

The default is `http://10.0.2.2:3300`, which is the Android emulator's alias for the host machine.

Platform configuration already applied:

- Android: `INTERNET` and `ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION` permissions, and `usesCleartextTraffic="true"` for plain-HTTP dev servers.
- iOS: `NSLocationWhenInUseUsageDescription`, and ATS exceptions for local networking.
- macOS: the `network.client` and location entitlements.

Remove the cleartext and ATS exceptions before a production release.

---

## 2. Auth (REST first)

Every protected route needs `Authorization: Bearer <accessToken>`. You only get `accessToken` from **verify-otp**. Login alone does not return a token.

```text
1. POST /auth/login          { "phoneNumber": "+1555..." }   -> OTP sent (no token)
2. POST /auth/verify-otp     { "phoneNumber", "otp" }        -> data.accessToken, data.refreshToken, data.user
3. Store tokens securely (flutter_secure_storage)
4. GET /incident/active      (Bearer)                         -> data.id or data: null
```

Refresh: `POST /auth/refreshtoken { refreshToken }` returns `data.accessToken`. `Session` schedules the refresh 60 s before the JWT `exp`, then does two things:

- It uses the new token for REST calls.
- It emits `auth:refresh { token }` on the live socket. Reconnects read the token fresh through `setAuthFn`.

If the server rejects the handshake (the middleware emits `connect_error`) or kicks the socket (`io server disconnect`), the client library stops reconnecting. `HavenSocket` then refreshes the token and reconnects, up to 2 times.

Circle prerequisite: both features need an ACCEPTED contact.

- Owner: `POST /circle-contact`
- Invitee: `PATCH /circle-contact/:id/status { "status": "ACCEPTED" }`

### Where `incidentId` / `shareId` come from

The client never generates these IDs.

| Role | Source | Where |
|------|--------|-------|
| Owner (pressed SOS) | `POST /incident/sos` | `data.id` |
| Owner (app reopen) | `GET /incident/active` | `data.id` (or `null`) |
| Circle member (live) | WS `incident:triggered` | `payload.incidentId` |
| Circle member (missed WS) | `GET /incident/incoming` | each item's `id` |
| Anyone with an id | `GET /incident/:id` | confirm access / hydrate |
| Share owner | `POST /live-location/shares` | `data.id` |
| Share viewer | WS `share:started` / `GET /live-location/incoming` | `shareId` / item `id` |

---

## 3. Connect once (app-wide singleton)

`HavenSocket.instance.connect(baseUrl, '/ws', tokenProvider)` (see `lib/main.dart` `connectSocket()`):

```dart
io.io('$baseUrl/ws', io.OptionBuilder()
    .setTransports(['websocket'])                       // server rejects polling
    .setAuthFn((cb) => cb({'token': tokenProvider()}))  // fresh token on every reconnect
    .enableForceNew()
    .enableReconnection()
    .disableAutoConnect()
    .build());
```

Server events are exposed as broadcast streams: `HavenSocket.instance.on('event')`. The `socket.on` handlers are bound once and survive reconnects. Screens cancel their `StreamSubscription`s on dispose, which replaces manual `socket.off(...)` calls.

`HavenApp` registers the global listeners for `incident:triggered`, `share:started` and `exception` at app level.

---

## 4. Event cheat sheet

### Emit (client to server)

| Event | Payload | Ack |
|-------|---------|-----|
| `subscribe` | `{ shareId }` **or** `{ incidentId }` | share / incident snapshot |
| `unsubscribe` | same | `{ ok: true }` |
| `location:update` | `{ shareId\|incidentId, latitude, longitude, accuracy?, altitude?, capturedAt? }` | accepted / lastKnown |
| `chat:send` | `{ incidentId, body, clientMessageId? }` | message object |
| `chat:history` | `{ incidentId, before?, limit? }` | `{ messages: [...] }` (newest first) |
| `chat:typing` | `{ incidentId, isTyping }` | `{ ok: true }` |
| `auth:refresh` | `{ token }` | none |

### Listen (server to client)

| Event | Feature | Notes |
|-------|---------|-------|
| `exception` | always | `{ code, message }` |
| `share:started` | live-location | user room; before subscribe |
| `location:updated` | live-location | share room (**with d**) |
| `share:stopped` | live-location | end UI |
| `incident:triggered` | SOS | user room; then `subscribe { incidentId }` |
| `chat:message` | live-chat | after incident subscribe |
| `chat:typing` | live-chat | after incident subscribe |
| `location:update` | SOS map | incident room (**no d**) |
| `circle:status` | Active SOS roster | |
| `sos:status` | ESCALATED / DURESS / ENDED | |
| `incident:status` | CANCELLED / RESOLVED | |
| `document:status` | evidence progress | |

**Name trap:** the share room broadcasts `location:updated`, and the incident room broadcasts `location:update`.

---

## 5. Live-location flow

1. Owner: `POST /live-location/shares` returns `shareId`.
2. Recipient: gets `share:started`, or calls `GET /live-location/incoming`.
3. Both: `subscribeShare(shareId)`. The ack is `{ ok, shareId, share, lastKnown }`.
4. Owner: `LocationTracker` sends `location:update { shareId, ... }` every 3 s. The recipient renders `shareLocations(shareId)` (`location:updated`).
5. Owner: `POST /live-location/shares/:id/stop`. The server then emits `share:stopped`.

See `lib/screens/share_screen.dart`.

---

## 6. Live-chat and SOS flow

1. Owner: `POST /incident/sos { deviceId, latitude?, longitude? }` returns `incidentId = data.id`.
2. Circle: gets `incident:triggered`, or calls `GET /incident/incoming`.
3. Both: `subscribeIncident(incidentId)` must be acked **before** any send or typing. Otherwise the server emits `exception { code: "NOT_SUBSCRIBED" }`.
4. Call `loadHistory`, then send with `sendText` and listen with `chatMessages`.

Chat details in `lib/screens/incident_screen.dart`:

- **Optimistic send.** The message shows immediately as `sending`. The ack or `chat:message` echo replaces it, matched by `clientMessageId`.
- **Retry.** When a send fails, tap the message to resend with the **same** `clientMessageId`.
- **Typing.** The client sends `isTyping: true` on the first keystroke and `false` after 3 s idle or on send. Remote typing indicators expire after 6 s.
- **Older pages.** The client sends `chat:history` with `before` set to the oldest message's `createdAt` (ISO).
- **Reconnect.** The room is re-joined automatically. The `rejoined` stream triggers a history back-fill.
- **Owner location.** Location streaming is on by default for the owner. A switch in the Live panel controls it. Streaming stops when the incident is CANCELLED, RESOLVED or ENDED.

---

## 7. Screen wiring

| Screen | Listeners | Emit |
|--------|-----------|------|
| App (`HavenApp`) | `exception`, `incident:triggered`, `share:started` | `auth:refresh` on token renew |
| Live share (viewer) | `location:updated`, `share:stopped` | `subscribe` / `unsubscribe` |
| Live share (owner) | `share:stopped` | `subscribe`, `location:update` |
| Active SOS / Chat | `chat:message`, `chat:typing`, `location:update`, `circle:status`, `sos:status`, `incident:status`, `document:status` | `subscribe`, `chat:*`, `location:update` |

When a screen closes, it calls `unsubscribe` and cancels its stream subscriptions. The global invite listeners stay active.

---

## 8. Payload shapes

**`chat:message` / send ack**, parsed by `ChatMessage.fromJson`:

```json
{
  "id": "...",
  "incidentId": "...",
  "senderId": "...",
  "type": "TEXT",
  "body": "hello",
  "document": null,
  "clientMessageId": "uuid",
  "createdAt": "2026-09-24T..."
}
```

`type` is `DOCUMENT` when an evidence upload finishes. The client cannot send this type with `chat:send`.

**`location:updated` (share)**, parsed by `LocationPoint.fromJson`:

```json
{
  "shareId": "...",
  "ownerId": "...",
  "latitude": 12.34,
  "longitude": 56.78,
  "accuracy": 10.0,
  "altitude": null,
  "capturedAt": "..."
}
```

---

## 9. Checklist

- [x] `transports: ['websocket']` only
- [x] `auth: { token: accessToken }` on connect (via `setAuthFn`)
- [x] Physical device uses LAN/tunnel URL (`--dart-define=BASE_URL=...`)
- [ ] Circle ACCEPTED before share/SOS (backend prerequisite, no UI here)
- [x] Share: listen `location:updated`; Incident: listen `location:update`
- [x] `subscribe` before `chat:send` / `chat:typing`
- [x] Stable `clientMessageId` on resend
- [x] `auth:refresh` before access token expiry
- [x] Listeners cancelled when disposing screens
