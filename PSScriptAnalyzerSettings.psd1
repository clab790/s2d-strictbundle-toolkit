@{
  Rules = @{
    # Internal orchestration script: allow descriptive function names
    PSUseApprovedVerbs = @{
      Severity = 'None'
    }

    # We deliberately use Write-Host for console-friendly transcripts
    PSAvoidUsingWriteHost = @{
      Severity = 'None'
    }

    # We intentionally keep some variables for readability / future stages
    PSUseDeclaredVarsMoreThanAssignments = @{
      Severity = 'None'
    }
  }
}
