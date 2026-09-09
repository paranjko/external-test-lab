@devshard_v5 @residual
Feature: DevShard v5 residual behaviour
  Warm recovery, host-ping observation, and join-path protocol behaviour remain
  available without turning diagnostics into routing decisions.

  @upstream_testenv @etl_safe
  Scenario: Solo boot serves before session recovery is complete
    Given a v5 child starts with a session journal
    When the child becomes ready
    Then its public health endpoint succeeds within seconds
    And chat succeeds before the recovery backlog is fully drained

  @upstream_testenv @defer_isolated_rig
  Scenario: An overlap SHA swap waits for the new child to warm
    Given an HA pair serves a healthy old generation
    When a new SHA is published for the same version
    Then the new child completes recovery before routing swaps
    And chat remains available

  @upstream_unit @defer_isolated_rig
  Scenario: A warm-recovery timeout keeps the old child serving
    Given recovery exceeds the configured warm-recovery timeout
    When an overlap swap waits for the new child
    Then the old child keeps serving
    And chat remains available

  @upstream_testenv @defer_isolated_rig
  Scenario: A solo restart does not wait for warm recovery
    Given a single host has no healthy old generation
    When it restarts
    Then it rejoins the pool when ready
    And it does not wait for the full recovery backlog before serving

  @upstream_unit @defer_isolated_rig
  Scenario: Snapshot restore retains sealed inference state
    Given a host restores from a snapshot
    When chat continues
    Then sealed inferences remain queryable
    And a duplicate sealed mutation is rejected

  @upstream_unit @defer_isolated_rig
  Scenario: Epoch pruning removes in-memory hosts
    Given an escrow is pruned at an epoch change
    Then it stops serving
    And no in-memory host continues to answer for it

  @upstream_testenv @etl_safe
  Scenario: Unused hosts are not pinged
    Given a registered escrow has not served inference
    Then no host-ping target is recorded for that host

  @upstream_testenv @etl_safe
  Scenario: A used host becomes visible in ping metrics
    Given a chat completion has succeeded for a host
    When one ping interval elapses
    Then the host-ping metric reports the host as up

  @upstream_testenv @etl_safe
  Scenario: Disabling host ping does not disable chat
    Given host ping is disabled
    When a user sends a chat completion
    Then the completion succeeds
    And no host-ping series is emitted

  @upstream_testenv @defer_isolated_rig
  Scenario: A probe failure does not quarantine a host
    Given a used host fails its observation probe
    When the ping job runs
    Then chat to that host remains available
    And the host is not quarantined by the probe

  @upstream_e2e @etl_safe
  Scenario: DAPI MLNode ping remains independent
    Given DAPI MLNode ping is enabled
    Then DAPI metrics expose MLNode ping observations

  @upstream_e2e @defer_isolated_rig
  Scenario: TLS certificate installation is crash-consistent
    Given a proxy serves a complete certificate
    When a certificate installation is interrupted
    Then the next TLS handshake presents either the previous or new complete certificate
    And it never presents a truncated certificate

  @upstream_e2e @etl_safe
  Scenario: A v5 route records protocol stamp 5
    Given governance names the version v5
    When an escrow is created or rotated through the v5 route
    Then its protocol stamp is 5
    And its v5 health endpoint succeeds
    And binding to that escrow succeeds
