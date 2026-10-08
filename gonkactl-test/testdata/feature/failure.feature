Feature: A rejected precondition does not create PASS
  Scenario: Given stops assertions
    Given the precondition is rejected
    Then the result is "ok"
