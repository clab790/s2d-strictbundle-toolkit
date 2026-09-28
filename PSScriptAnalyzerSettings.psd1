@{
  # Keep errors and actionable warnings. Parser errors are checked explicitly
  # by the workflow, and informational formatting hints do not fail the build.
  Severity = @('Error', 'Warning')

  # These are existing conventions in the v1.0.39/v1.0.40 orchestration scripts.
  # Revisit them when restructuring the implementation for v1.1.
  ExcludeRules = @(
    'PSUseApprovedVerbs'                          # Internal helper names
    'PSUseSingularNouns'                          # Internal helper names
    'PSAvoidUsingWriteHost'                       # Console output is transcribed
    'PSUseDeclaredVarsMoreThanAssignments'        # Retained for script readability
    'PSAvoidUsingEmptyCatchBlock'                 # Best-effort hardware probes
    'PSUseShouldProcessForStateChangingFunctions' # No -WhatIf interface in v1.0
  )
}
