@devshard_v5 @height_sync
Feature: DevShard v5 height-sync
  The gateway carries host-signed height anchors without minting a height from
  its own chain read. Chat must remain available while operators can observe
  lagging, future, and fabricated height claims.

  Background:
    Given a v5 gateway with host-signed height anchors
    And the gateway chain oracle is unset unless a scenario explicitly provides an observation oracle

  @upstream_testenv @etl_safe
  Scenario: First chat seeds height-sync and chat keeps working
    When a user sends a chat completion
    Then the completion succeeds
    And every live host has a height tip
    And the observed height spread is small on an honest roster

  @upstream_unit @upstream_testenv @defer_isolated_rig
  Scenario: A lagging host lifts to the roster floor
    Given one host reports a height lower than the other honest hosts
    When a chat is routed to the lagging host after the higher floor is known
    Then the completion succeeds
    And the higher host-signed height remains the floor
    And the lagging host reports catching up
    And a stamp below that floor is rejected

  @upstream_testenv @defer_isolated_rig
  Scenario: A future unknown hash beyond the delta is observed without stopping chat
    Given one host reports a future height beyond the configured delta
    And its hash is not known by the honest oracle
    When a chat continues
    Then the completion succeeds
    And the future claim is marked as untrusted
    And the admission mark is observable
    And no Strong slash is required

  @upstream_unit @upstream_testenv @defer_isolated_rig
  Scenario: A slightly future fabricated hash is deferred until reconciliation
    Given one host reports a slightly future height with a fabricated hash
    When an honest follower reaches that height
    Then the fabricated hash is recorded as a deferred failure
    And the completion was not blocked

  @upstream_testenv @etl_safe
  Scenario: A quiet escrow sends heartbeats after a floor is seeded
    Given a session has a host-signed floor from completed chats
    When no further inference is sent for one heartbeat interval
    Then the heartbeat counter increases

  @upstream_testenv @etl_safe
  Scenario: A busy escrow discharges heartbeat work through inference
    Given a session continuously receives chat completions
    Then no idle heartbeat is opened

  @upstream_unit @upstream_testenv @defer_isolated_rig
  Scenario: A height floor survives a versiond snapshot restore
    Given a live session with a known height floor
    When versiond restarts from its snapshot
    Then the next completion succeeds
    And the restored session does not lose its floor
