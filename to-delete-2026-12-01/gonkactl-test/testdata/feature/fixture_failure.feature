Feature: A changed fixture changes an assertion
  Scenario: Fixture response does not match
    When request "broken" is executed
    Then the result is "ok"
