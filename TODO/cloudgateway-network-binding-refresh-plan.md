# CloudGateway Network Binding Refresh Plan

Research and implementation plan only. This document does not change
WireGuardKit behavior.

## Goal

Expose the smallest product-neutral WireGuardKit operation that lets a packet
tunnel provider request the same lightweight UDP binding refresh already used
when Apple reports a satisfiable network-path change.

CloudGateway will use this operation as a recovery attempt before presenting a
raw tunnel-health failure to the user. All thresholds, retry policy,
verification, notification behavior, and UI remain outside this repository.

Companion product/state-machine plan:

```text
/Users/alexbrodsky/GitHub/CloudGateway/TODO/apple-tunnel-recovery-before-notification-plan.md
```

## Current fork state

CloudGateway consumes branch `cloudgateway/xcode-26` from
`https://github.com/Albro3459/wireguard-apple`, currently at revision
`ba0929fb7fc63ec604d69c35abf47688d17a6252`.

The fork currently carries Xcode 26 build compatibility changes. This would be
its first CloudGateway-specific runtime behavior/API change, so the patch must
remain narrow and easy to compare with upstream.

CloudGateway pins the exact fork revision through its submodule, Xcode project,
and `Package.resolved`. The fork must be reviewed and published before those
three references move together.

## Existing recovery behavior

`Sources/WireGuardKit/WireGuardAdapter.swift` has three private states:

* `.stopped`
* `.started(handle, settingsGenerator)`
* `.temporaryShutdown(settingsGenerator)`

All public operations and `NWPathMonitor` callbacks serialize through the
private `workQueue`.

For a satisfiable iOS path update, `didReceivePathUpdate` currently:

1. Builds endpoint-only UAPI configuration through
   `PacketTunnelSettingsGenerator.endpointUapiConfiguration()`.
2. Applies it with `wgSetConfig`.
3. Calls `wgDisableSomeRoamingForBrokenMobileSemantics`.
4. Calls `wgBumpSockets`.

For an unsatisfied path it transitions to `.temporaryShutdown` and turns off
the backend. When a satisfiable path returns, it rebuilds the backend with the
saved settings generator.

The explicit CloudGateway operation must not interfere with that lifecycle.

## What `wgBumpSockets` does

`Sources/WireGuardKitGo/api-apple.go` implements `wgBumpSockets` by launching a
Go goroutine that:

* Calls `BindUpdate()` to close and reopen the UDP binding.
* Retries up to ten times.
* Waits 500 ms between failures.
* Sends keepalives to peers with a current valid keypair after a successful bind
  update.
* Logs and gives up after roughly five seconds if every bind update fails.

The Swift call returns immediately. It cannot report eventual bind success and
must not be presented as an awaitable end-to-end recovery result.

A binding refresh is not equivalent to toggling the VPN. It does not recreate
the utun interface, Network Extension settings, backend handle, key state, or
saved configuration.

## Important endpoint limitation

`PacketTunnelSettingsGenerator` stores endpoints that were resolved during
adapter startup. Later `endpointUapiConfiguration()` calls
`withReresolvedIP()` on those stored IPs. On iOS this primarily remaps the
existing IP for DNS64/NAT64; it does not look up the original endpoint hostname
again.

The API in this plan deliberately preserves that existing behavior:

* It can repair a stale local UDP binding.
* It preserves normal DNS64 path mapping.
* It does not learn a deployment's new A record.
* It does not promise to eliminate the existing post-deployment toggle.

Original-hostname refresh is a separate design because active full-tunnel DNS,
last-known-endpoint fallback, DNS failure, late asynchronous results, and
deployment TTL behavior require broader lifecycle decisions.

## Public API

Add to `WireGuardAdapter`:

```swift
public func refreshNetworkBinding(
    completionHandler: @escaping (WireGuardAdapterError?) -> Void
)
```

### Completion contract

* `nil`: the adapter was started and the refresh sequence was handed to
  wireguard-go.
* `.invalidState`: the adapter was stopped or temporarily shut down.
* Completion is invoked on the adapter's private `workQueue`, matching the
  current implementation of its other callback APIs. Callers must redispatch
  to their own queue and must not treat that private queue as a public API
  guarantee.
* Completion does not mean the bind update succeeded.
* Completion does not mean a handshake completed or traffic recovered.

The caller must observe later runtime handshake/RX progress. This contract must
be present in the API documentation comment.

## State behavior

| Adapter state | Required behavior |
| --- | --- |
| `.started` | Reuse the satisfiable-path endpoint mapping and roaming sequence, schedule `wgBumpSockets`, then complete with `nil`. |
| `.temporaryShutdown` | Complete with `.invalidState`. Do not start or rebuild the backend; the existing path observer owns resume. |
| `.stopped` | Complete with `.invalidState`. Do not create a backend or path observer. |

## Implementation design

### 1. Extract one private helper

Factor the current satisfiable iOS path sequence out of
`didReceivePathUpdate` into a private method that receives the started handle and
settings generator.

Conceptual shape:

```swift
private func refreshNetworkBinding(
    handle: Int32,
    settingsGenerator: PacketTunnelSettingsGenerator
) {
    #if os(iOS)
    let (wgConfig, resolutionResults) = settingsGenerator.endpointUapiConfiguration()
    logEndpointResolutionResults(resolutionResults)
    wgSetConfig(handle, wgConfig)
    wgDisableSomeRoamingForBrokenMobileSemantics(handle)
    #endif
    wgBumpSockets(handle)
}
```

Use the repository's exact style and platform guards during implementation.
The helper name can differ to avoid overload ambiguity, but the logic must not
be duplicated.

### 2. Preserve automatic path handling

`didReceivePathUpdate` must call the extracted helper for a satisfiable started
path. Unsatisfied and temporary-shutdown behavior must remain unchanged.

This refactor must be behavior-neutral for ordinary Apple-driven transitions.

### 3. Add the public queued operation

The public method must enqueue on `workQueue`, inspect private adapter state, and
call the helper only for `.started`.

It must not:

* Call the private path-update method with a fabricated `NWPath`.
* Create or replace an `NWPathMonitor`.
* Set `packetTunnelProvider.reasserting`.
* Reapply `NEPacketTunnelNetworkSettings`.
* Stop/start the backend.
* Mutate the saved tunnel configuration.
* Add retry timing or CloudGateway policy.

### 4. Keep concurrency ownership clear

`workQueue` serializes the Swift-side state check and refresh scheduling, but
`wgBumpSockets` launches asynchronous Go work. Multiple public calls could
therefore schedule redundant Go binding updates.

CloudGateway's recovery policy must ensure only one request is in flight and a
10-second verification window separates attempts. Do not add CloudGateway
cooldowns to the generic adapter.

An Apple path update can still occur near an explicit refresh. That is safe at
the state-machine level because both enter through `workQueue`, and wireguard-go
serializes bind changes internally. Device validation must still cover this
race.

## Platform behavior

iOS is the required consumer.

The public API must continue compiling for macOS. The existing macOS path-update
behavior only bumps sockets; use the corresponding platform-appropriate helper
behavior rather than introducing iOS-only symbols into a shared build.

No new dependency, package product, target, framework, or bridge symbol is
required.

## Error handling

Keep the first patch aligned with existing path-update behavior:

* Endpoint remapping failures are logged through the existing private logging
  path.
* The old endpoint remains in the backend when no new endpoint line can be
  generated.
* The socket bump is still requested.
* `.invalidState` is the only synchronous adapter-state failure required by the
  new public API.

Do not claim that the existing ignored `wgSetConfig` return code is validated by
this patch. If return-code handling is strengthened later, it should be done
consistently for `update`, automatic path refresh, and explicit binding refresh
instead of only one call path.

## Repository work items

- [x] Update `Sources/WireGuardKit/WireGuardAdapter.swift` only.
- [x] Extract the shared private binding-refresh helper.
- [x] Route the existing satisfiable path callback through it.
- [x] Add and document `refreshNetworkBinding(completionHandler:)`.
- [x] Manually review stopped, temporary-shutdown, start/stop, deinit, and path
  callback ordering.
- [x] Create the local fork implementation commit.
- [x] User published the fork commit; Codex must never push.
- [x] Update CloudGateway's three exact revision references to the local commit.
- [x] Compile the fork through CloudGateway's unsigned iOS build after the
  revision was published.
- [ ] Device-test automatic and explicit refresh behavior.

## Validation

The fork currently has no Swift test target. Adding injectable wrappers around
the global Go bridge and a fake `NEPacketTunnelProvider` would be a much larger
change than this API. Keep deterministic timing/retry tests in CloudGateway's
pure recovery policy.

### Build validation

From CloudGateway after the dependency pin is updated:

```sh
./scripts/test.sh apple
```

Expected:

* WireGuardKit and its C/Go bridge compile under Xcode 26.
* The iOS packet tunnel sees the new public method.
* Existing unsigned Apple builds continue passing.

### Real-device validation

* Healthy startup remains unchanged.
* Apple-reported Wi-Fi/cellular transitions still execute the same helper.
* An explicit refresh while started is accepted without changing visible VPN
  status or Network Extension routes.
* Runtime RX or handshake progress can recover after a stale NAT/UDP binding.
* `.temporaryShutdown` returns `.invalidState` and leaves resume to Apple path
  handling.
* `.stopped` returns `.invalidState` and does not start anything.
* A stop/toggle racing the queued request does not act on a stale handle.
* Two CloudGateway attempts do not overlap.
* A genuine stopped server remains unavailable; the API does not create a false
  success signal.
* A changed deployment IP remains unchanged by this API and still follows the
  separately documented behavior.

## Acceptance criteria

* One new public operation exists on the existing WireGuardKit product.
* Automatic path updates and explicit recovery share one private implementation.
* The operation is serialized through `workQueue`.
* Only `.started` accepts a refresh.
* Completion is documented as scheduling-only.
* No CloudGateway policy enters the fork.
* No C/Go bridge, backend lifecycle, route, key, config, package, or dependency
  change is introduced.
* The fork compiles through CloudGateway and passes real-device recovery tests.
* The eventual fork revision is pinned consistently by CloudGateway.

## Rejected alternatives for this stage

### Public bare `bumpSockets`

Rejected because it leaks a bridge implementation detail and can diverge from
the endpoint mapping/roaming sequence already used for path changes.

### Awaitable Go bind callback

Rejected because it requires a new C callback ABI, handle synchronization, and
Go concurrency work. Bind success would still not prove end-to-end tunnel
recovery; CloudGateway already has runtime evidence for that purpose.

### Automatic full backend restart

Rejected for the first stage. It is closer to a Settings toggle but has harder
failure and lifecycle semantics involving backend handles, counters, key state,
network settings, concurrent stop, and health-monitor reset. Consider only if
device evidence proves binding refresh insufficient.

### Original-hostname/deployment-IP refresh

Rejected for this stage. It broadens the API from local binding recovery into
dynamic endpoint management and changes the original deployment-warning
behavior. Design it independently if automatic post-deployment recovery becomes
a product requirement.

### Adopt `NEProvider.defaultPath` KVO simultaneously

Rejected as bundled scope. Upstream branch `upstream/am/default-path` contains
commit `3149c50`, which replaces `NWPathMonitor` with `NEProvider.defaultPath`
KVO. It is not merged into upstream master and still cannot prove or repair a
degraded path that remains satisfied. Evaluate it as a separate experiment.

## Privacy and logging

Add no new log statements or fields containing endpoints, resolved IP
addresses, interface names, runtime counters, peer identifiers, keys,
configurations, or per-user recovery history. The extracted helper reuses the
existing endpoint-resolution messages, and CloudGateway's adapter log bridge
continues marking those messages private.
