# Noosphere public operation feed

The wallet pins Noosphere tag `0.2.0`, resolved in the lockfile to commit
`470f2e66c2e6a6f1e4951ba8cabbefff9653f12d`. See the upstream
`docs/architecture/public-feed.md`. The coordinator remains responsible for all
ROAST/DKG business logic. This integration uses the existing protobuf public
client and `noosphere/public-feed/1` ALPN; the wallet does not implement a
protocol, HTTP route, or signature verifier.

## Enable and subscribe

1. Open **Public operation feed** on the host, or **Receive background
   notifications** on a member wallet.
2. On the host, **Publish this group's public feed** is enabled by default. The
   wallet derives an opaque 256-bit feed ID from the room's random group ID and
   flushes it to local configuration before the coordinator uses it. Restart
   Sygnature after changing publication. The ID remains stable when disabling
   and re-enabling publication.
3. Member notifications are also enabled by default. Enrolled members derive
   the same feed ID and save the subscription when the signer connects to its
   already authenticated coordinator. There is no public feed invitation,
   clipboard import or second coordinator approval. The member can disable or
   re-enable notifications locally in the dialog.

Anyone who learns the feed ID can read operation type, timing and outcome. An
unlisted feed is not private to readers who know the ID. The random group ID is
distributed by the participant-bound enrollment flow and is never exposed by
the public feed protocol.

Ordinary embedded coordinators receive `ServerConfig.publicFeed`. Frozen
room groups receive their own explicit `IrohConfig.roomPublicFeeds[groupId]`.
The synthetic enrollment bootstrap group stays disabled. Retention is 10,000
entries / 30 days. Existing atomic coordinator snapshot persistence is unchanged
and already includes the journal. Stopping local polling is independent of
publication and persists across restarts. Publishing changes apply at the next
coordinator startup, so disabling in settings does not stop a running feed until
restart.

## Locked-wallet polling

`PublicFeedStore` keeps the existing app-private Hive CE box,
`sygnature_public_feed_v1`, in the application support directory. The existing
JSON state remains readable and writable in place; no migration or second
database is introduced. Only a shared owner isolate opens the box. Foreground
and headless Flutter engines discover it through `IsolateNameServer` and send
whole mutations to its serialized mailbox. It has no vault encryption key, signer storage,
participant key, wallet seed, or FROST dependency to initialize. The subscription
credentials are only postcard `EndpointAddr`, the enrollment-pinned EndpointId,
and derived feed ID. Bookkeeping includes a cursor scoped to `(pin, feedId)`, a
bounded recent event cache, sticky gap/error information, retry time and durable outbox.
Local group bindings connect settings to the wallet UI; no group identifier is
sent to the public API. Feed IDs and transport error details are never logged or
sent to analytics by this integration.

`PublicFeedPoller.run()` needs only this store and a notification delivery
callback. `connectPublicFeed` initializes Iroh directly in the calling isolate,
uses an ephemeral public client and always closes it. It does not invoke wallet
bootstrap, signer login/session, a participant key callback, private storage or
participant actions. The native initializer accepts an explicit library path
for standalone deployments and resolves the bundled Iroh framework on macOS.
The existing `iroh_flutter` dependency supplies application native binaries.

The application starts polling separately from vault/controller creation. It
uses the existing in-process timer pattern: immediately, then once per minute.
A run allows at most five pages total (100 entries each), a 45-second network /
notification budget and up to three seconds for final transport close. Local
durable commits are allowed to finish. Runs share a durable global lease; feed order rotates
to avoid starving other subscriptions during catch-up. A connection completing
after its deadline is closed without fetching.

## Android background execution

Before `runApp`, Android initializes Workmanager and updates one unique periodic
work request, `network.noosphere.sygnature.public-feed` / `publicFeedPoll`, with
`ExistingPeriodicWorkPolicy.update`. Its minimum interval is 15 minutes and its
only constraint is a connected network. This is **best-effort periodic work, not
an exact timer**. No expedited work, foreground service, custom receiver, or iOS
background scheduling is configured. Other platforms retain foreground polling.

The retained top-level dispatcher initializes Flutter/plugin registration,
coinlib for verification, and only `initializePublicFeedNative()` for Iroh. It
opens the public store, initializes `AppNotifications` with
`requestPermission: false`, calls exactly one bounded `PublicFeedPoller.run()`,
and closes resources in `finally`. It never constructs the wallet controller or
ROAST runtime, opens the vault, reads wallet/signer keys, requests biometrics,
starts a signer/coordinator, invokes `NoosphereFlutter.initialize()`, or plays UI
sounds. WorkManager inputData contains no subscription credentials. Notification
permissions are requested only by the foreground app. Public notifications stay
generic; opening the app and unlocking are required to review actual requests.

Foreground and headless engines share one Hive owner. Each queued mutation reads
the latest state, applies the complete change, and writes and flushes one JSON
record before replying. Cursor, lifecycle state and outbox creation are one
mutation; concurrent settings/subscription changes are retained. Connections
are reference counted, and isolate exit listeners clean up killed clients. An
independent monitor removes a killed owner's registration so the next open can
recover persisted data. Standalone Dart callers reuse a local owner; concurrent
Flutter engines use the process-wide name server.
The global polling lease is acquired by the same serialized mailbox with a random owner
and expiry (the run budget plus two minutes, normally 165 seconds). Every page
commit, failure, outbox acknowledgement and pre-delivery check is fenced by the
current owner, expiry and active subscription. A killed worker becomes recoverable
after expiry; a late old owner cannot commit or release a replacement lease.
Stable OS notification IDs cover interruption after display but before outbox ack.
The local `_running` guard remains a cheap optimization, not synchronization.

No subscriptions or a busy lease is success. Offline coordinators and expected
feed/security failures persist the existing per-feed state and return success,
so WorkManager does not add another retry loop. Plugin/native/store failures
return false to request the plugin's ordinary WorkManager retry.

Swiping the app from Recents normally leaves scheduled work intact. Android
**force-stop** prevents background execution until the user opens the app again;
Doze, battery restrictions and vendor policies may delay work. Retained events
are caught up by cursor when execution resumes, subject to coordinator retention.
Expired requests and requests older than the configured notification-age window
remain silent, so a deferred run can update status without showing a
notification. The window is configurable from 15 minutes to 24 hours and
defaults to one hour. It limits how far a delayed best-effort run may look back;
it does not define or guarantee a delivery deadline. Keep the coordinator
running independently if the wallet hosting it is also stopped.

## Processing and presentation

- Fetch is exclusive after the saved cursor. Page processing, event lifecycle
  updates and outbox intent commit in one atomic Hive state mutation with the new
  cursor. Committed cursors deduplicate `(pin, feedId, cursor)`.
- The initial page fixes a retained-history baseline. All entries through that
  baseline remain silent even if catch-up spans multiple runs. Later requests
  notify only when observed within the Android notification-history setting
  (15 minutes to 24 hours, one hour by default), not expired and not more than
  one minute in the future. Public completion/rejection/cancellation/expiry
  updates public status; it is not an approval action.
- Notification IDs are allocated durably from a separate range and reused on
  retries, including a crash after showing but before outbox acknowledgement.
  Delivery does not replay wallet event sounds. Disabled notifications consume
  the intent. Old/expired pending notifications are dropped rather than flooded.
- Empty pages use `nextCursor`. A history gap remains visible. The event cache
  is explicitly presented as recent observations, never complete history.
- Network failures retain the last committed cursor and back off from 30 seconds
  to one hour. Unknown/disabled feeds share the same unavailable message.
- Signature/identity errors and coordinator rollback retain the cursor and block
  subsequent polling until the user explicitly retries. Retry never resets the
  cursor or changes the pin. Changing pin or feed ID uses a separate cursor;
  re-subscribing to the old pair resumes its saved cursor.

The UI displays only category, lifecycle, observation time and opaque public
`eventId`. Lifecycle entries correlate by that ID within their feed. It never
maps them to protocol request IDs, transactions or messages, including by time.
There are no signer counts, threshold progress or public approval actions.
Notifications direct users to the ordinary application; users unlock and review current
requests in the existing authenticated wallet flow.

## Validation and dependency availability

Tests cover pure polling/storage/crash handling, real Iroh polling from a fresh
standalone Dart process, identity rejection, opt-in UI, onboarding feed binding
and existing signing/DKG/controller/storage flows. On Linux the
subprocess also checks that neither FROST nor coinlib native libraries were
loaded and that no signer sessions, challenges, presence or coordinator snapshot
changed.

All Noosphere Git dependencies and overrides use the published `0.2.0` tag.
The lockfile records its resolved commit, and `flutter pub get` resolves it
without local path overrides.

Keep the host configuration, coordinator identity and complete existing atomic
snapshot together. Do not downgrade an enabled coordinator or replace its live
journal with an old backup. Wallet recovery exports do not currently export the
coordinator journal or this notification database; they are not a coordinator
migration mechanism.
