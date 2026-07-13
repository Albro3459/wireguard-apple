# CloudGateway Backend Restart Plan

Research and implementation plan only. This document does not change
WireGuardKit behavior.

## Goal

Expose one product-neutral WireGuardKit operation that lets a packet tunnel
provider request a full in-place backend restart: tear down the running
wireguard-go device, re-apply `NEPacketTunnelNetworkSettings`, and start a
fresh backend on the existing tunnel session.

This is the deep-recovery escalation for blackholes that
`refreshNetworkBinding` cannot repair. CloudGateway owns all policy: when to
escalate, verification, notification, and retry limits stay outside this
repository.

Companion product plan:

```text
/Users/alexbrodsky/GitHub/CloudGateway/TODO/apple-tunnel-backend-restart-recovery-plan.md
```

Prior stage (implemented, published, pinned):

```text
TODO/cloudgateway-network-binding-refresh-plan.md
```

## Motivating evidence

2026-07-12 device evidence (CloudGateway iOS v1.0.0 build 10): on weak indoor
cellular, the tunnel blackholed while `NWPath` stayed `.satisfied`. Two
`refreshNetworkBinding` attempts did not restore traffic; the health policy
correctly confirmed the outage and notified. A user Control Center toggle
recovered the tunnel immediately.

Mechanism (well-evidenced community reports; not an Apple-confirmed bug): on
marginal signal the carrier-side PDP context / CGNAT mapping dies while iOS
keeps reporting the path satisfied. `wgBumpSockets` recreates the UDP socket,
but iOS reattaches it to the same stale route state, so the rebind lands on
the same dead path. Only rebuilding the tunnel's network settings and backend
forces iOS to re-evaluate the flow/route state.

Supporting ecosystem behavior: Tailscale documents socket rebind as necessary
but not sufficient (rebind must be followed by a fresh STUN round); Mullvad
ships reconnect-style workarounds for the same dead-tunnel class.

## The sequence already exists in this fork

`didReceivePathUpdate`'s `.temporaryShutdown` resume path already performs the
needed sequence when a path returns to satisfiable:

1. `setNetworkSettings(settingsGenerator.generateNetworkSettings())` -
   re-applies `NEPacketTunnelNetworkSettings`, which Apple documents as
   re-appliable while running and which rebuilds the tunnel's routes/flows.
2. `settingsGenerator.uapiConfiguration()` with the startup-resolved
   endpoints.
3. `startWireGuardBackend(wgConfig:)` - `wgTurnOn` a brand-new wireguard-go
   device (fresh sockets, handshake state, timers), plus the iOS roaming
   workaround.

It is only reachable when iOS reports the path unsatisfied and then
satisfiable again. In the motivating incident the path never left
`.satisfied`, so this machinery never ran. The new API makes the same
sequence explicitly callable from the `.started` state.

## Known limitation preserved

Like `refreshNetworkBinding`, this operation uses the endpoints resolved at
adapter startup (`uapiConfiguration` on the stored `resolvedEndpoints`). It
does not re-resolve the original endpoint hostname: with the tunnel's network
settings still applied, DNS would route into the dead tunnel. A deployment
that changes the server IP therefore still requires the documented user
toggle. Original-hostname refresh remains a separately designed follow-up.

## Public API

Add to `WireGuardAdapter`:

```swift
public func restartBackend(
    completionHandler: @escaping (WireGuardAdapterError?) -> Void
)
```

### Completion contract

* `nil`: the old backend was stopped, network settings were re-applied, and a
  new backend handle is running.
* `.invalidState`: the adapter was `.stopped` or `.temporaryShutdown`.
* `.setNetworkSettings` / `.startWireGuardBackend` /
  `.cannotLocateTunnelFileDescriptor`: the restart failed mid-sequence; see
  failure semantics below.
* Completion is invoked on the adapter's private `workQueue`, matching the
  other callback APIs. Callers must redispatch.
* Unlike `refreshNetworkBinding`, a `nil` completion means a new backend is
  actually running - but it does not mean a handshake completed or traffic
  recovered. Callers must still verify via runtime handshake/RX progress.

## State behavior

| Adapter state | Required behavior |
| --- | --- |
| `.started` | `wgTurnOff` the old handle, re-apply network settings, start a new backend, transition to `.started(newHandle, settingsGenerator)`, complete `nil`. |
| `.temporaryShutdown` | Complete `.invalidState`. The path observer owns resume. |
| `.stopped` | Complete `.invalidState`. Do not create anything. |

## Failure semantics (the hard part)

Once `wgTurnOff` has run, the old backend is gone. If a later step throws:

* Transition to `.temporaryShutdown(settingsGenerator)` and complete with the
  error. This is deliberate: `.temporaryShutdown` is the fork's existing
  "backend off, settings generator saved" state, and the existing path
  observer already knows how to resume from it on the next satisfiable path
  update. No new recovery state is invented.
* Fail-closed is preserved throughout: the tunnel session and its network
  settings remain in place (a `setNetworkSettings` failure still leaves the
  previous settings active), so device traffic keeps routing into utun and
  drops. Nothing ever fails open.
* Callers must treat a restart failure as "runtime unavailable" and lean on
  their existing missing-runtime policy; they must not retry in a tight loop.

Known quirks to preserve, not fix, in this patch:

* `setNetworkSettings` waits at most 5 seconds for the system callback and
  proceeds on timeout (existing upstream workaround). The restart can
  therefore block `workQueue` for up to ~5 seconds; callers' completions on
  other APIs queue behind it. Document this; do not redesign it here.
* `wgTurnOn` failure returns a negative handle and throws
  `.startWireGuardBackend`; there is no partial-backend state to clean up.

## Concurrency

* The entire restart is one synchronous block on `workQueue`, so it cannot
  interleave with `start`, `stop`, `update`, `refreshNetworkBinding`, or path
  callbacks.
* A path update arriving after the restart operates on the new `.started`
  state normally.
* A concurrent `stop()` enqueued behind a restart stops the new backend
  normally.
* CloudGateway policy must keep at most one recovery request in flight; the
  adapter does not add cooldowns or dedupe.

## Platform behavior

iOS is the required consumer. The sequence must continue compiling for macOS:
`setNetworkSettings`, `uapiConfiguration`, and `startWireGuardBackend` are not
platform-gated, and the roaming workaround is already `#if os(iOS)` inside
`startWireGuardBackend`. No iOS-only symbols may leak into shared build paths.

No new dependency, target, framework, or Go/C bridge change is required.

## Implementation design

1. Extract the `.temporaryShutdown` resume body of `didReceivePathUpdate`
   into one private helper (settings re-apply + uapi config + backend start)
   that both the path observer and the new API call. Do not duplicate the
   logic.
2. `restartBackend` enqueues on `workQueue`, guards `.started`, calls
   `wgTurnOff`, then the shared helper; on helper failure transitions to
   `.temporaryShutdown` and completes with the error.
3. Keep the patch Swift-only in `WireGuardAdapter.swift`.
4. Preserve existing logging; add no new fields containing endpoints,
   counters, or identifiers.

## Repository work items

- [ ] Extract the shared restart helper from the path-update resume case.
- [ ] Route the existing `.temporaryShutdown` resume through it (behavior
  neutral).
- [ ] Add and document `restartBackend(completionHandler:)`.
- [ ] Manually review start/stop/deinit/path-callback ordering and the
  mid-restart failure transition.
- [ ] Local fork commit; user reviews and publishes. Never push.
- [ ] CloudGateway advances its three pinned references together.
- [ ] Compile through CloudGateway's unsigned iOS build.
- [ ] Device-test explicit restart behavior (see product plan matrix).

## Validation

No Swift test target exists in the fork; deterministic policy tests live in
CloudGateway. Fork validation is build + review + device:

* `./scripts/test.sh apple` from CloudGateway after the pin moves.
* Device: explicit restart while started recovers a weak-cellular blackhole
  that binding refresh does not; `.temporaryShutdown` and `.stopped` return
  `.invalidState`; a mid-restart failure lands in `.temporaryShutdown` and the
  next real path flap resumes it; rapid user stop during restart does not act
  on a stale handle; a genuinely stopped server remains unavailable after a
  restart (no false success signal); a changed deployment IP still requires
  the user toggle.

## Rejected alternatives

### Reuse `refreshNetworkBinding` with a "deep" flag

Rejected: the two operations have different completion semantics (scheduled
vs. running) and different failure states. A flag would blur the contract.

### Tear down and rebuild the whole NE session from inside the provider

Rejected: `stopTunnel`-equivalent teardown from inside the extension is
user-visible, races the system VPN state machine, and is not needed - settings
re-apply plus backend restart is Apple's documented in-provider rebuild
pattern.

### Re-resolve the endpoint hostname during restart

Rejected for this stage (see Known limitation preserved).

### Adopt `am/default-path` (`3149c50`) in the same change

Rejected as bundled scope, same reasoning as the binding-refresh stage. It
changes when path updates are delivered; it does not repair a path that stays
satisfied while dead.

## Privacy and logging

Add no new log statements or fields containing endpoints, resolved IPs,
interface names, runtime counters, peer identifiers, keys, configurations, or
per-user recovery history. The helper reuses existing log lines only.
