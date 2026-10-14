# iOS delivery policy alignment (unreleased)

Baseline: iOS Producer 2.0.1 (`8b8a142`), Android Producer 2.1.4
(`da3173f645f56a9592e470e350d64c2aea1dad44`), shared Core
`1d41ec4edb850ee7dd0b7f63c49738d6a9669c21`. SLS iOS 4.3.4 is a
reference implementation; the affected application's SLS version is unknown.

The deployed TLS image was reported as `tls.epic_v6.6.2.f1c078a.2026_09_11_10_50`.
`f1c078a` is not present in the local `log-service` checkout, so the service
mapping below is evidence from the available `origin/epic_v6.6.2` source at
`456ce7b505b08f87175f16dc33a890ddc02a6f9a`, not proof of the deployed image.
Keep this version boundary explicit when comparing server observations.

## Contract

- `RetryConfiguration` defaults are `maxAttempts=0` (unlimited count while the
  budget remains), `totalTimeout=90`, `initialInterval=0.5`,
  `maxInterval=10`, and `retryTransientHTTPResponses=true`. The Core applies
  its multiplier and jitter to the nominal backoff ceiling. Attempt count
  includes the first request, and the configuration is frozen at open.
- A URLSession request has a separate 50 s idle timeout. `requestTimeout`
  remains a whole-attempt safety deadline, default 90 s. Each attempt is further
  limited by the remaining retry-cycle budget. No new attempt starts after the
  budget expires. NSURLSession cannot enforce a portable independent 10 s TCP
  connect timer; `connectTimeout` is retained for source compatibility and must
  not override the idle timeout. Caller resource timeouts may impose a shorter
  deadline. OS suspension can delay local timers; these are not background
  delivery guarantees. `automaticLifecycleHandling` defaults to `true` in an
  iOS app process and `false` in app extensions and macOS; it only wires
  lifecycle notifications, background flush and foreground retry.
- Default memory delivery remains bounded: exhaustion is a terminal result.
  `memoryRetryRetention=0` disables memory-only retention. A positive value
  enables transient-failure retention across cycles, measured from the first
  attempt; `86400` s is the suggested opt-in value. It consumes the same finite
  buffer and cannot survive process exit. `Persistence.memory` is the explicit
  memory-only mode. Persistent batches already retain retryable failures in the
  WAL; `.buffered` has crash/power-loss boundaries, while `.sync` waits for WAL
  sync on admission. Retained attempts are diagnostic events, not terminal send
  results. At most one terminal callback is delivered for a live batch.
- Network recovery is an explicit hint to advance retained retry tasks. It must
  not cancel in-flight requests or bypass authentication, breakers or limits.
- HTTP classification uses status plus the exact structured service `ErrorCode`;
  it never matches body strings. With
  `retryTransientHTTPResponses=true`, a response with HTTP 408 or 499 is a
  bounded transient retry. HTTP 400 is retryable only when its exact
  `ErrorCode` is one of `ClientCanceled`, `Timeout`, `RequestTimeout`, or
  `ConnectionClosed`; other parameter, permission, and unknown 400 responses
  are terminal. A local cancellation already known to the SDK is never retried.
  With `retryTransientHTTPResponses=false`, use the Core HTTP set
  `429/500/502/503/504` and do not enable the 408/499 or 400 allowlist.
  Access-log status 499 is not proof that the client received HTTP 499; an
  accepted request may therefore be delivered more than once after replay.
  Applications should attach a stable event ID and verify deduplication.
- Diagnostic callbacks are opt-in, serial and asynchronous. Payloads contain
  only numeric counters, stable reason/kind values, and validated request/error
  identifiers. No log bodies, server messages, URLs or credentials are included.

## Acceptance

1. Swift and Objective-C defaults, validation and open-time snapshots agree.
2. The fourth attempt can recover after three transient failures; explicit
   `maxAttempts=3` retains the old bounded behavior.
3. A running attempt is limited by the remaining budget; no attempt begins
   after expiry. Idle and whole-attempt timeouts remain independent.
4. Received 400 retries only for the exact allowlist above; parameter and
   unknown 400 responses stay terminal. With
   `retryTransientHTTPResponses=false`, the legacy Core set is exactly
   `429/500/502/503/504`.
5. Memory retention recovers after a cycle, expires, and closes without waiting
   for its retention duration. Recovery does not revive a discarded batch.
6. Persistent failures do not ACK WAL prematurely; reopen recovery still works.
7. Diagnostics describe attempts, retention and final reasons without leaking
   secrets or producing a second terminal result.
8. Legacy/V1/V2 C config consumers keep their original layout and defaults.

No SDK release, publication or server-side change is part of this patch.

## Migration

- Swift callers can keep `RetryConfiguration()` for the new default policy, or
  set `retryTransientHTTPResponses=false` to preserve the previous Core HTTP
  set. Objective-C callers use the flattened equivalents
  `retryMaxAttempts`, `retryTotalTimeout`, `retryInitialInterval`,
  `retryMaxInterval`, and `retryTransientHTTPResponses`.
- All `TimeInterval` and `NSTimeInterval` retry/timeout values are seconds.
  Do not pass milliseconds. `connectTimeout=10` remains a compatibility hint;
  URLSession's `requestIdleTimeout=50` is the transport idle timer, and
  `requestTimeout=90` is the whole-attempt deadline clipped by the remaining
  retry budget.
- Persistent delivery continues through WAL recovery. To retain transient
  failures in memory across retry cycles, set `memoryRetryRetention` to a
  positive value such as `86400`; the finite buffer still applies and process
  exit loses memory-only batches.
- `notifyNetworkRecovered` is only a recovery hint. It cannot revive a batch
  already discarded and does not turn background execution into a delivery
  guarantee.
- `onDiagnostic` is optional in both Swift and Objective-C. Record only the
  public diagnostic fields (`kind`, `reason`, counters, HTTP/transport codes,
  `retryable`, `requestID`, and `errorCode`); do not add log bodies, URLs,
  server messages, or credentials. Initialization validation failures expose
  only the stable `errorCode`, including the `openFailed` diagnostic event.
