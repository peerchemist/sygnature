# TODO

## Before release

- [ ] Support multiple concurrent outgoing ROAST message-signature requests
      within the same signer group. Track progress, timeout, errors and results
      by `setupId:requestId` throughout the controller and UI; remove the
      single-request guard and setup-only `firstOrNull` progress lookup so each
      request remains independently identifiable and resumable.
