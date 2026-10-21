# Noosphere public operation feed

The public operation feed lets members of a shared wallet receive a generic
notification when a signing or key-setup request needs attention. It is a hint
to open Sygnature; the request itself is still reviewed inside the unlocked
wallet.

## How it works

The coordinator publishes a small event whenever a shared-wallet operation is
created or changes state. Enrolled members subscribe to that wallet's feed and
poll it periodically.

Publishing is enabled by default for a new shared wallet. Member notifications
are also enabled by default after enrollment. Both can be changed from the
wallet's public-feed settings:

- The host controls **Publish this group's public feed**. A coordinator restart
  is required after changing this setting.
- Each member controls **Receive background notifications** locally. Disabling
  notifications does not change publication for other members.

Members do not need a separate invitation or approval for the feed. The feed ID
is derived from information already exchanged during the authenticated wallet
enrollment.

The coordinator retains up to 10,000 events for 30 days. A member that was
offline resumes from its last saved position while retained events are still
available.

## What the feed reveals

Feed entries contain only:

- the operation category;
- its public lifecycle state;
- the observation time; and
- a random event ID used to match later status changes.

The feed does not contain transaction details, messages, signer identities,
approval counts, wallet addresses, or private key material. It cannot approve
or reject an operation.

Anyone who obtains a feed ID can read that feed's public metadata. The feed ID
is therefore treated as a credential even though the published events are
deliberately limited. Sygnature does not log feed IDs or transport error details.

## Polling and notifications

While Sygnature is open, it polls immediately and then about once per minute.
Android also schedules background polling through WorkManager. Android decides
when that work runs; the 15-minute interval is a minimum, not a delivery
guarantee. Doze mode, battery restrictions, and vendor policies can delay it.
Force-stopping the app prevents background work until the user opens it again.

Other platforms poll only while the app is running. There is currently no iOS
background task.

Notifications are intentionally generic. Opening one takes the user to
Sygnature, where the wallet must be unlocked before the actual request can be
reviewed. Background polling does not unlock the vault, start a signer or
coordinator, request biometrics, or play wallet event sounds.

Sygnature stays quiet when a feed is first enabled so retained history does not
produce a burst of old notifications. Later requests notify only if they are
still active and fall within the user's notification window, which defaults to
one hour and can be set from 15 minutes to 24 hours.

## Local state and recovery

Public-feed state is stored separately from the encrypted wallet vault. It
contains subscriptions, saved positions, recent public events, retry state, and
pending notification delivery. It contains no wallet seed, participant key, or
signing share.

Foreground and Android background polling share this state. Updates are written
atomically so concurrent polling cannot skip events or move a saved position
backward. Notification IDs are also saved, preventing duplicate notifications
if the app stops between displaying and recording one.

Network failures keep the last saved position and retry with increasing delays.
Identity failures, invalid signatures, and coordinator rollback stop automatic
polling for that feed until the user retries. Retrying preserves the saved
position.

The recent-events screen is a cache of observations, not a complete audit log.
A history gap is shown if the coordinator no longer retains events needed after
a long offline period.

Wallet backups do not include the coordinator journal or the local public-feed
database. They are therefore not a coordinator migration mechanism. When moving
a coordinator, keep its configuration, identity, and complete persisted state
together.

## Implementation boundary

The coordinator remains responsible for signing and DKG behavior. Sygnature
uses Noosphere's public-feed client and protocol rather than implementing its own
HTTP route, event verifier, or signing logic.

The Android worker initializes only the public-feed transport, local store, and
notification service. Its input contains no subscription credentials. Expected
offline or unavailable-feed results are recorded locally without asking
WorkManager to create a second retry loop; initialization and storage failures
use WorkManager's normal retry behavior.

Tests cover feed storage and polling, concurrent foreground/background access,
transport identity checks, notification behavior, wallet enrollment, and the
existing signing and DKG flows.
