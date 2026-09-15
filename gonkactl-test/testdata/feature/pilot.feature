@id:PILOT-001
Feature: Real execution journal
  Background:
    Given the test stand is prepared

  Rule: Assertions retain values
    Scenario Outline: Assertions are not inferred from the renderer
      When request "<request>" is executed
      Then the result is "ok"
      And evidence contains "<evidence>"

      Examples:
        | request | evidence |
        | smoke   | receipt  |
        | status  | response |

  Scenario: DocString and table reach the executor
    When a document is supplied
      """
      raw execution evidence
      """
    Then the document contains "execution evidence"
    And a table is supplied
      | key | value |
      | id  | P-1   |
    And the table contains "P-1"
