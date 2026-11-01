# NekoChat v1

UTF-8 JSON text WebSockets at `/nekochat/v1/ws`. Every event has `protocol: "nekochat"`, integer `version: 1`, `kind`, and ASCII correlation `id` (1–64 letters/digits/underscore/hyphen). The committed client/server JSON Schemas are generated from the Relay models with `python -m nekochat.relay.protocol`; tests reject schema drift. Unknown fields, event kinds and versions fail closed. No Office, Agent, paste, shell, attachment, or remote-control events exist in this protocol.

Authenticate the upgrade with `Authorization: Bearer <user-id>:<individual-token>`. Tokens must not appear in URLs or events. Server chooses sender identity. User IDs: lowercase ASCII letters/digits/underscore/hyphen, 1–32 chars, first char alphanumeric. `ready` confirms the authenticated user.

| Direction | kind | Additional required fields |
|---|---|---|
| client → server | `chat.send` | `to`, `text` (1–2000 Unicode code points, nonblank) |
| client → server | `ping` | none |
| server → client | `ready` | `user` |
| server → client | `chat.message` | `sender`, `text` |
| server → client | `chat.ack` | `status`: `delivered` or `duplicate` |
| server → client | `error` | `code`: `invalid_event`, `forbidden`, `offline`, `rate_limited` |
| server → client | `pong` | none |

Example send:

```json
{"protocol":"nekochat","version":1,"kind":"chat.send","id":"c947d268","to":"bob","text":"下課見！"}
```

`chat.message` uses the same `id`; errors/acks correlate to that send. Unparseable input uses ID `invalid`. Delivery means a write to the online peer's socket completed, **not** read receipt or durable delivery. No offline queue/history. Duplicate suppression is the last 256 successful sends per sender connection; IDs must be fresh for each send. No automatic retries after ambiguous disconnects. Reconnect explicitly; drafts remain local in memory. One active connection per identity (4409 on duplicate). Idle timeout 90s; clients send application ping every 25s. Maximum frame JSON payload 16 KiB; binary closes 1009. At most 30 incoming events per 10s per authenticated connection, then close 4429. Before upgrade reject wrong auth (4401), browser Origin, query parameters, or plaintext VPS connections (4403).

Friend grants are mutual server policy entries; clients cannot self-authorize. Authorization occurs on every send. Configuration changes/revocation require Relay restart, disconnecting all sessions. LAN and VPS use the same protocol and authentication; LAN may explicitly use plaintext `ws://` on a trusted private network. VPS requires `wss://` with trusted certificate and correctly restricted reverse proxy forwarding. No end-to-end encryption: the Relay can read transient chat text; it does not log/store it.
