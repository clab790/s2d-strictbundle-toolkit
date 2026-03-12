<#
.AUTHOR
  Claes Abrahamsson

.VERSION
  1.0.39
.CREATED
  2026-02-21
.CHANGELOG
  1.0.39 - Always skip CPU0 in RSS CPU candidate selection (reduces CPU0 DPC/ISR hot spots); keep full NUMA list (Option B)
  1.0.38 - Fix HT CPU selection in Set-RssNumaAware so 8 queues is achievable on HT systems; set default PerfTune/AutoPerfTune queues to 8
  1.0.37 - Fix switch($Mode) dispatch syntax for BufferTune/AutoPerfTune (no combined case labels)
  1.0.36 - Add -Mode BufferTune: sets Receive/Send Buffers to 4096 and tunes RSS queues to 8 (NUMA-aware) without touching other stages
  1.0.32 - PerfTune: robust RssProcessorArray parsing across OS/driver variants + add -PerfTuneSummary (compact RSS diagnostics)
  1.0.30 - PerfTune/AutoPerfTune: robust BaseProcessorGroup/Number parsing (handles empty values) + safer legacy fallback
  1.0.25 - Fix BaseProcessor parsing for AutoPerfTune (Get-NetAdapterRss BaseProcessorGroup/Number)



.SYNOPSIS
  S2D Fabric + RDMA config (Cisco 10GbE SET vSwitch + Mellanox 25GbE DirectRDMA)
  Windows Server 2025 friendly, PowerShell 5.1, idempotent, debug-friendly.

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\S2D-FabricConfig.ps1 -Mode All -DebugMode
  powershell.exe -ExecutionPolicy Bypass -File .\S2D-FabricConfig.ps1 -Mode MellanoxOnly -DebugMode

.DESCRIPTION
  Configuration script for:
   - Cisco 10GbE Fabric (SET vSwitch)
   - Mellanox ConnectX-6 Lx 25GbE Direct RDMA (RoCEv2)
   - Windows Server 2025 S2D environments
   
.NOTES
  - No PolicyStore usage (Server 2025 changed/removed in some cmdlets).
  - QoS names are unique (avoid collisions): Policy "S2D-SMB-445", TrafficClass "S2D-SMB".
  - Default Traffic Class is NOT modified (by design).
  - Designed to be idempotent
  - Supports ConnectX-6 Lx (WinOF2 driver stack)
  - Tested on HPE Gen11 platform
  - Comments/output are English-only (ASCII) to avoid encoding issues

#>

param(
  [ValidateSet("All","MellanoxOnly","CiscoOnly","PrereqsOnly","RenameOnly","RdpOnly","RdmaOnly","Preflight","PerfTune","AutoPerfTune","BufferTune")]
  [string]$Mode = "All",

  [string]$ConfigPath = "$(Split-Path -Parent $PSCommandPath)\S2D-FabricConfig.json",

  [switch]$DebugMode,

  [switch]$PerfTuneSummary
)

# Global switches
$script:DebugMode = [bool]$DebugMode
$script:PerfTuneSummary = [bool]$PerfTuneSummary

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ----------------------------
# Generic helpers (must be defined before first use)
# ----------------------------
function Get-OptionalProp {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][object]$Obj,
    [Parameter(Mandatory=$true)][string]$Name
  )

  if ($null -eq $Obj) { return $null }

  $p = $Obj.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }

  return $p.Value
}


# ----------------------------
# Logging + summary
# ----------------------------
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$logDir = "C:\Temp"
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory | Out-Null }
$logPath = Join-Path $logDir "S2D-FabricConfig-$env:COMPUTERNAME-$ts.log"
Start-Transcript -Path $logPath -Force | Out-Null

$script:RebootRequired = $false
$script:Changes = New-Object System.Collections.Generic.List[string]

function Add-Change([string]$Text) { $script:Changes.Add($Text) | Out-Null }
function Mark-RebootRequired { $script:RebootRequired = $true }

function Finish-Script {
  Write-Host ""
  Write-Host "=== SUMMARY ===" -ForegroundColor Cyan
  if ($script:Changes.Count -eq 0) {
    Write-Host "No changes were required (already desired state)." -ForegroundColor Green
  } else {
    foreach ($c in $script:Changes) { Write-Host ("- {0}" -f $c) -ForegroundColor Green }
  }

  Write-Host ""
  if ($script:RebootRequired) {
    Write-Warning "Reboot required. Please reboot and re-run the script (same Mode) to continue."
  } else {
    Write-Host "No reboot required." -ForegroundColor Green
  }

  Stop-Transcript | Out-Null
  Write-Host ("Log saved to: {0}" -f $logPath) -ForegroundColor Cyan
}

# ----------------------------
# Debug helpers (block snapshots)
# ----------------------------
function Debug-Block {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Title,
    [scriptblock]$Script
  )
  if (-not $DebugMode) { return }
  Write-Host ""
  Write-Host ("[DEBUG] {0}" -f $Title) -ForegroundColor Yellow
  try { & $Script } catch { Write-Host ("[DEBUG] Failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }
}

function Debug-Adapters([string]$Title, [string[]]$Names) {
  Debug-Block -Title $Title -Script {
    Get-NetAdapter -Name $Names -ErrorAction SilentlyContinue |
      Select-Object Name, InterfaceDescription, ifIndex, Status, LinkSpeed, MacAddress |
      Format-Table -AutoSize | Out-Host
  }
}

function Debug-QosState([string]$Title) {
  Debug-Block -Title $Title -Script {
    Get-NetQosPolicy -ErrorAction SilentlyContinue |
      Select-Object Name, Owner, Template, Precedence, PriorityValue, NetDirectPort |
      Format-Table -AutoSize | Out-Host

    Get-NetQosTrafficClass -ErrorAction SilentlyContinue |
      Select-Object Name, Priority, BandwidthPercentage, Algorithm |
      Format-Table -AutoSize | Out-Host

    Get-NetQosFlowControl -ErrorAction SilentlyContinue |
      Select-Object Priority, Enabled |
      Format-Table -AutoSize | Out-Host

    Get-NetQosDcbxSetting -ErrorAction SilentlyContinue |
      Select-Object Willing |
      Format-Table -AutoSize | Out-Host
  }
}

# ----------------------------
# Config validation
# ----------------------------
function Test-IPv4([string]$Value) {
  try {
    $ip = [System.Net.IPAddress]::Parse($Value)
    return ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
  } catch { return $false }
}

function Test-Config {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Config)

  $errors = New-Object System.Collections.Generic.List[string]
  function Require($cond, [string]$msg) {
    if (-not $cond) {
      $m = ($msg -as [string]).Trim()
      if (-not $m.StartsWith("[CONFIG]")) { $m = "[CONFIG] " + $m }
      $errors.Add($m) | Out-Null
    }
  }


  function Assert-OnlyKeys {
    param(
      [Parameter(Mandatory)]$Obj,
      [Parameter(Mandatory)][string[]]$Allowed,
      [Parameter(Mandatory)][string]$Path
    )
    $names = @($Obj.PSObject.Properties.Name)
    $extra = $names | Where-Object { $_ -notin $Allowed }
    if ($extra) { Require $false ("{0} contains unknown key(s): {1}" -f $Path, ($extra -join ", ")) }
  }
  Require ($null -ne $Config.Environment) "Missing 'Environment' object."
  Require ($null -ne $Config.Servers)     "Missing 'Servers' object."

  if ($Config.Environment) {
    $env = $Config.Environment

    # Environment keys (strict schema)
    Assert-OnlyKeys -Obj $env -Allowed @(
      "FabricVLAN","FabricPrefixLength","FabricGateway","FabricDNS","RDMAVlan","RDMAPrefixLength","Domain","TimeZoneId"
    ) -Path "Environment"
    foreach ($k in @("FabricVLAN","FabricPrefixLength","FabricGateway","FabricDNS","RDMAVlan","RDMAPrefixLength")) {
      Require ($null -ne $env.$k) "Environment missing '$k'."
    }

    # Optional: TimeZoneId
    $tzProp = $env.PSObject.Properties["TimeZoneId"]
    if ($tzProp) {
      $tzId = [string]$tzProp.Value
      Require (-not [string]::IsNullOrWhiteSpace($tzId)) "Environment.TimeZoneId is present but empty."
    }

    # Optional: Domain join target
    $domProp = $env.PSObject.Properties["Domain"]
    if ($domProp) {
      $dom = $domProp.Value
      Require ($null -ne $dom) "Environment.Domain is present but null."
      if ($dom) {
        $dnProp = $dom.PSObject.Properties["Name"]
        Require ($dnProp -and -not [string]::IsNullOrWhiteSpace([string]$dnProp.Value)) "Environment.Domain.Name missing/empty."
        $ouProp = $dom.PSObject.Properties["OUPath"]
        if ($ouProp) {
          $ou = [string]$ouProp.Value
          Require (-not [string]::IsNullOrWhiteSpace($ou)) "Environment.Domain.OUPath is present but empty."
        }
      }
    }

    foreach ($vlanKey in @("FabricVLAN","RDMAVlan")) {
      if ($null -ne $env.$vlanKey) {
        $v = [int]$env.$vlanKey
        Require ($v -ge 1 -and $v -le 4094) "Environment.$vlanKey out of range (1-4094): $v"
      }
    }

    foreach ($p in @("FabricPrefixLength","RDMAPrefixLength")) {
      if ($null -ne $env.$p) {
        $pl = [int]$env.$p
        Require ($pl -ge 1 -and $pl -le 32) "Environment.$p out of range (1-32): $pl"
      }
    }

    Require (Test-IPv4 ([string]$env.FabricGateway)) "Environment.FabricGateway invalid IPv4: '$($env.FabricGateway)'"
    $dnsList = @($env.FabricDNS)
    Require ($dnsList.Count -ge 1) "Environment.FabricDNS must contain at least 1 DNS server."
    Require (($dnsList | Select-Object -Unique).Count -eq $dnsList.Count) "Environment.FabricDNS contains duplicates."
    foreach ($d in $dnsList) { Require (Test-IPv4 ([string]$d)) "Environment.FabricDNS invalid IPv4: '$d'" }
  }


    # Domain (strict schema): if present, require Name + OUPath
    if ($null -ne $env.Domain) {
      Assert-OnlyKeys -Obj $env.Domain -Allowed @("Name","OUPath") -Path "Environment.Domain"

      Require (-not [string]::IsNullOrWhiteSpace([string]$env.Domain.Name))   "Environment.Domain.Name is required."
      Require (-not [string]::IsNullOrWhiteSpace([string]$env.Domain.OUPath)) "Environment.Domain.OUPath is required."

      $dn = [string]$env.Domain.Name
      Require ($dn -match '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$') `
        "Environment.Domain.Name is not a valid FQDN: '$dn'"

      $ou = [string]$env.Domain.OUPath
      Require ($ou -match '^(?:OU=[^,=]+,)+DC=[^,=]+,DC=[^,=]+(?:,DC=[^,=]+)*$') `
        "Environment.Domain.OUPath is not a valid DN: '$ou'"
    }

  if ($Config.Servers) {
    $serverProps = @($Config.Servers.PSObject.Properties)
    Require ($serverProps.Count -ge 1) "Servers object is empty."
    foreach ($sp in $serverProps) {
      $serial = $sp.Name
      $s = $sp.Value
      Assert-OnlyKeys -Obj $s -Allowed @("ServerName","FabricIP","RDMA1IP","RDMA2IP") -Path ("Servers['$serial']")
      Require (-not [string]::IsNullOrWhiteSpace($serial)) "Servers contains an empty serial key."
      Require ($serial -match '^[A-Za-z0-9\-]{3,32}$') "Servers key '$serial' must match ^[A-Za-z0-9-]{3,32}$"
      foreach ($k in @("ServerName","FabricIP","RDMA1IP","RDMA2IP")) {
        Require ($null -ne $s.$k) "Servers['$serial'] missing '$k'."
      }

      $name = [string]$s.ServerName
      Require ($name -match '^[A-Za-z0-9\-]{1,15}$') "Servers['$serial'].ServerName invalid NetBIOS: '$name'"

      foreach ($k in @("FabricIP","RDMA1IP","RDMA2IP")) {
        $ip = [string]$s.$k
        Require (Test-IPv4 $ip) "Servers['$serial'].$k invalid IPv4: '$ip'"
      }

      # Logical sanity (not expressible in JSON schema)
      Require ($s.RDMA1IP -ne $s.RDMA2IP) "Servers['$serial'] RDMA1IP and RDMA2IP must be different."
      Require ($s.FabricIP -ne $s.RDMA1IP) "Servers['$serial'] FabricIP must differ from RDMA1IP."
      Require ($s.FabricIP -ne $s.RDMA2IP) "Servers['$serial'] FabricIP must differ from RDMA2IP."

    }
  }

  if ($errors.Count -gt 0) {
    throw ("Config validation failed (" + $errors.Count + " issue(s)):`n - " + ($errors -join "`n - ") + "`n`nTips:`n - Validate JSON against schema in VS Code (JSON language service) or jsonschema.net`n - Check missing commas/brackets and unknown keys (strict schema)")
  }
}

# ----------------------------
# Load config + identify node
# ----------------------------
if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }
$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
Test-Config -Config $config
Write-Host "Config validation OK." -ForegroundColor Green

if ($DebugMode) {
  $VerbosePreference = "Continue"
  $DebugPreference   = "Continue"
  $InformationPreference = "Continue"
}

$FabricVLAN         = [int]$config.Environment.FabricVLAN
$FabricPrefixLength = [int]$config.Environment.FabricPrefixLength
$FabricGateway      = [string]$config.Environment.FabricGateway
$FabricDNS          = @($config.Environment.FabricDNS | ForEach-Object { [string]$_ })

$RDMAVlan           = [int]$config.Environment.RDMAVlan
$RDMAPrefixLength   = [int]$config.Environment.RDMAPrefixLength

$SerialNumber = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber.Trim()
$serverCfg = $config.Servers.$SerialNumber
if (-not $serverCfg) { throw "SerialNumber '$SerialNumber' not found in config.Servers." }

$TargetName = [string]$serverCfg.ServerName
$FabricIP   = [string]$serverCfg.FabricIP
$RDMA1IP    = [string]$serverCfg.RDMA1IP
$RDMA2IP    = [string]$serverCfg.RDMA2IP

Write-Host ("PowerShell: {0}" -f $PSVersionTable.PSVersion) -ForegroundColor Cyan
Write-Host ("Mode: {0}" -f $Mode) -ForegroundColor Cyan
Write-Host "Node identity:" -ForegroundColor Cyan
Write-Host ("  SerialNumber: {0}" -f $SerialNumber) -ForegroundColor Cyan
Write-Host ("  TargetName  : {0}" -f $TargetName) -ForegroundColor Cyan
Write-Host ("  FabricIP    : {0}" -f $FabricIP) -ForegroundColor Cyan
Write-Host ("  RDMA1IP/2IP : {0} / {1}" -f $RDMA1IP, $RDMA2IP) -ForegroundColor Cyan
Write-Host ("  ConfigPath  : {0}" -f $ConfigPath) -ForegroundColor Cyan
Write-Host ("  DebugMode   : {0}" -f $DebugMode) -ForegroundColor Cyan

# ----------------------------
# Domain target + current state (info)
# ----------------------------
$targetDomain = $null
$targetOuPath = $null

$desiredTimeZoneId = Get-OptionalProp -Obj $config.Environment -Name "TimeZoneId"
if ([string]::IsNullOrWhiteSpace([string]$desiredTimeZoneId)) { $desiredTimeZoneId = "W. Europe Standard Time" }

if ([string]::IsNullOrWhiteSpace($desiredTimeZoneId)) { $desiredTimeZoneId = "W. Europe Standard Time" }

$domainObj = Get-OptionalProp -Obj $config.Environment -Name "Domain"
if ($domainObj) {
  $dn = Get-OptionalProp -Obj $domainObj -Name "Name"
  if (-not [string]::IsNullOrWhiteSpace($dn)) {
    $targetDomain = [string]$dn
    $targetOuPath = [string](Get-OptionalProp -Obj $domainObj -Name "OUPath")
  }
}

try {
  $cs = Get-CimInstance Win32_ComputerSystem
  $currentJoined = [bool]$cs.PartOfDomain
  $currentDomain = [string]$cs.Domain
} catch {
  $currentJoined = $false
  $currentDomain = ""
}

Write-Host ""
Write-Host "Domain status:" -ForegroundColor Cyan
if ($targetDomain) {
  Write-Host ("  Target domain : {0}" -f $targetDomain) -ForegroundColor Cyan
  if ([string]::IsNullOrWhiteSpace($targetOuPath)) {
    Write-Host "  Target OU     : (default container)" -ForegroundColor Cyan
  } else {
    Write-Host ("  Target OU     : {0}" -f $targetOuPath) -ForegroundColor Cyan
  }
} else {
  Write-Host "  Target domain : (not configured in JSON)" -ForegroundColor DarkYellow
}

if ($currentJoined) {
  Write-Host ("  Current state : Joined ({0})" -f $currentDomain) -ForegroundColor Green
} else {
  Write-Host "  Current state : Not joined (WORKGROUP)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Timezone status:" -ForegroundColor Cyan
try {
  $tz = Get-TimeZone
  Write-Host ("  Current TZ    : {0}" -f $tz.Id) -ForegroundColor Cyan
} catch {
  Write-Host "  Current TZ    : (unknown)" -ForegroundColor DarkYellow
}
Write-Host ("  Desired TZ    : {0}" -f $desiredTimeZoneId) -ForegroundColor Cyan



# ----------------------------
# Generic helpers
function Ensure-TimeZone {
  [CmdletBinding()]
  param(
    [Parameter()][string]$TimeZoneId = "W. Europe Standard Time"
  )

  try {
    $cur = (Get-TimeZone).Id
  } catch {
    $cur = ""
  }

  if ($cur -ieq $TimeZoneId) {
    Write-Host ("Timezone already desired: {0}" -f $TimeZoneId) -ForegroundColor Green
    return
  }

  Write-Host ("Setting timezone: '{0}' -> '{1}'" -f $cur, $TimeZoneId) -ForegroundColor Yellow
  try {
    Set-TimeZone -Id $TimeZoneId -ErrorAction Stop
    Add-Change ("Set timezone to {0}" -f $TimeZoneId)
  } catch {
    # Fallback for locked-down environments
    & tzutil.exe /s $TimeZoneId | Out-Null
    Add-Change ("Set timezone to {0} (tzutil fallback)" -f $TimeZoneId)
  }
}

# ----------------------------
function Get-AdaptersByLinkSpeed {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][int]$ExpectedLinkSpeedGbps,
    [Parameter(Mandatory)][int]$ExpectedCount
  )

  $adapters = @(Get-NetAdapter | Where-Object {
      $_.Status -eq 'Up' -and $_.PhysicalMediaType -eq '802.3' -and (
        $_.LinkSpeed -like "$ExpectedLinkSpeedGbps*Gbps" -or $_.LinkSpeed -eq "$ExpectedLinkSpeedGbps Gbps"
      )
    } | Sort-Object -Property ifIndex)

  Debug-Block -Title ("Adapters at {0}Gbps (Up)" -f $ExpectedLinkSpeedGbps) -Script {
    $adapters | Select-Object Name, InterfaceDescription, ifIndex, Status, LinkSpeed | Format-Table -AutoSize | Out-Host
  }

  if ($adapters.Count -ne $ExpectedCount) {
    $found = $adapters | Select-Object Name, InterfaceDescription, ifIndex, Status, LinkSpeed | Format-Table -AutoSize | Out-String
    throw "Expected exactly $ExpectedCount adapter(s) at ${ExpectedLinkSpeedGbps}Gbps (Up). Found $($adapters.Count).`n$found"
  }

  return $adapters
}

function Rename-NetAdapterSafe {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$OldName, [Parameter(Mandatory)][string]$NewName)

  if ($OldName -eq $NewName) { return }

  $exists = Get-NetAdapter -Name $NewName -ErrorAction SilentlyContinue
  if ($exists) {
    $tmp = "$NewName (TEMP-$([guid]::NewGuid().ToString('N').Substring(0,6)))"
    Rename-NetAdapter -Name $NewName -NewName $tmp -ErrorAction Stop
    Add-Change ("Renamed existing '{0}' -> '{1}' to free name" -f $NewName, $tmp)
  }

  Rename-NetAdapter -Name $OldName -NewName $NewName -ErrorAction Stop
  Add-Change ("Renamed NIC '{0}' -> '{1}'" -f $OldName, $NewName)
}

function Ensure-IPv4Address {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][int]$InterfaceIndex,
    [Parameter(Mandatory)][string]$IPAddress,
    [Parameter(Mandatory)][int]$PrefixLength,
    [string]$DefaultGateway,
    [string]$Context = "Ensure-IPv4Address"
  )

  Debug-Block -Title ("{0}: Pre-state ifIndex {1}" -f $Context, $InterfaceIndex) -Script {
    Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Select-Object InterfaceIndex, InterfaceAlias, IPAddress, PrefixLength, AddressState, Type |
      Format-Table -AutoSize | Out-Host
  }

  $globalHits = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $IPAddress })

  foreach ($hit in $globalHits) {
    if ($hit.InterfaceIndex -ne $InterfaceIndex) {
      Remove-NetIPAddress -InterfaceIndex $hit.InterfaceIndex -IPAddress $IPAddress -Confirm:$false -ErrorAction Stop
      Add-Change ("Removed IP {0} from ifIndex {1} (was on wrong interface)" -f $IPAddress, $hit.InterfaceIndex)
    }
  }

  $onTarget = @(Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $IPAddress })
  if ($onTarget.Count -eq 0) {
    New-NetIPAddress -InterfaceIndex $InterfaceIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -AddressFamily IPv4 -ErrorAction Stop | Out-Null
    Add-Change ("Added IP {0}/{1} to ifIndex {2}" -f $IPAddress, $PrefixLength, $InterfaceIndex)
  } else {
    # Ensure prefix best-effort
    try {
      Set-NetIPAddress -InterfaceIndex $InterfaceIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -ErrorAction Stop | Out-Null
    } catch { }
  }

  if ($DefaultGateway) {
    $route = @(Get-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
      Where-Object { $_.NextHop -eq $DefaultGateway })
    if ($route.Count -eq 0) {
      New-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix "0.0.0.0/0" -NextHop $DefaultGateway -ErrorAction Stop | Out-Null
      Add-Change ("Created default route via {0} on ifIndex {1}" -f $DefaultGateway, $InterfaceIndex)
    }
  }

  Debug-Block -Title ("{0}: Post-state ifIndex {1}" -f $Context, $InterfaceIndex) -Script {
    Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Select-Object InterfaceIndex, InterfaceAlias, IPAddress, PrefixLength, AddressState, Type |
      Format-Table -AutoSize | Out-Host
  }
}
function Ensure-AdapterAdvancedProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RegistryKeyword,
        [Parameter(Mandatory)][int]$RegistryValue,
        [string]$What = $RegistryKeyword,
        [switch]$QuietIfMissing
    )

    $p = Get-NetAdapterAdvancedProperty -Name $Name -ErrorAction Stop |
         Where-Object { $_.RegistryKeyword -eq $RegistryKeyword } |
         Select-Object -First 1

    if (-not $p) {
        if (-not $QuietIfMissing) {
            Write-Warning "[$Name] AdvancedProperty '$RegistryKeyword' not found. Skipping ($What)."
        }
        return
    }

    # Mellanox/NDIS kan returnera RegistryValue som array (t.ex. {0})
    $cur = $p.RegistryValue
    if ($cur -is [System.Array]) { $cur = $cur[0] }

    # Try to cast to int (driver sometimes returns string)
    $curInt = $null
    try { $curInt = [int]$cur } catch { $curInt = $null }

    if ($DebugMode) {
        Write-Host ("[DEBUG] {0} / {1} current raw: {2} (type {3}) -> int: {4}" -f `
            $Name, $RegistryKeyword, $p.RegistryValue, $p.RegistryValue.GetType().FullName, $curInt) -ForegroundColor Yellow
    }

    if ($curInt -ne $RegistryValue) {
        Write-Host ("[{0}] Setting {1} ({2}) {3} -> {4}" -f $Name, $What, $RegistryKeyword, $curInt, $RegistryValue) -ForegroundColor Yellow
        Set-NetAdapterAdvancedProperty -Name $Name -RegistryKeyword $RegistryKeyword -RegistryValue $RegistryValue -NoRestart -ErrorAction Stop | Out-Null
    } else {
        Write-Host ("[{0}] {1} already desired ({2}={3})" -f $Name, $What, $RegistryKeyword, $RegistryValue) -ForegroundColor Green
    }
}

function Ensure-JumboBytes {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$JumboBytes)

  $jp = Get-NetAdapterAdvancedProperty -Name $Name -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Jumbo' } | Select-Object -First 1

  if ($jp) {
    Ensure-AdapterAdvancedProperty -Name $Name -RegistryKeyword $jp.RegistryKeyword -RegistryValue $JumboBytes -What $jp.DisplayName
  } else {
    # best effort fallback
    try { Ensure-AdapterAdvancedProperty -Name $Name -RegistryKeyword "*JumboPacket" -RegistryValue $JumboBytes -What "JumboPacket" -QuietIfMissing } catch { }
  }
}

# RoCE mode v2 (adapter advanced property)
function Ensure-RoceV2 {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Name)

  # Prefer RegistryKeyword first (cleanest path)
  $p = Get-NetAdapterAdvancedProperty -Name $Name -ErrorAction Stop |
       Where-Object { $_.RegistryKeyword -eq "*NetworkDirectTechnology" } |
       Select-Object -First 1

  # Fallback: vissa drivrutiner exponerar bara DisplayName korrekt
  if (-not $p) {
    $p = Get-NetAdapterAdvancedProperty -Name $Name -ErrorAction Stop |
         Where-Object { $_.DisplayName -eq "NetworkDirect Technology" } |
         Select-Object -First 1
  }

  if (-not $p) {
    Write-Warning "[$Name] NetworkDirect Technology property not found (can't enforce RoCEv2)."
    return
  }

  # RegistryValue kan vara array
  $cur = $p.RegistryValue
  if ($cur -is [System.Array]) { $cur = $cur[0] }

  $curInt = $null
  try { $curInt = [int]$cur } catch {}

  # In this environment: value 4 = RoCEv2
  if ($curInt -ne 4) {
    Write-Host ("[{0}] Setting NetworkDirect Technology to RoCEv2 (4) (was {1})" -f $Name, $curInt) -ForegroundColor Yellow

    if ([string]::IsNullOrWhiteSpace($p.RegistryKeyword)) {
      throw "[$Name] Can\'t set RoCEv2: RegistryKeyword is empty for NetworkDirect Technology."
    }

    Set-NetAdapterAdvancedProperty `
      -Name $Name `
      -RegistryKeyword $p.RegistryKeyword `
      -RegistryValue 4 `
      -NoRestart `
      -ErrorAction Stop | Out-Null

    Add-Change ("Set RoCE mode to v2 on {0} (*NetworkDirectTechnology=4)" -f $Name)
    Mark-RebootRequired
  }
  else {
    Write-Host ("[{0}] RoCEv2 already set (*NetworkDirectTechnology=4)" -f $Name) -ForegroundColor Green
  }

  # Extra debug dump (only with -DebugMode)
  if ($DebugMode) {
    Write-Host ""
    Write-Host "[DEBUG] RoCE state for $Name" -ForegroundColor Yellow
    Get-NetAdapterAdvancedProperty -Name $Name |
      Where-Object { $_.DisplayName -like "*NetworkDirect*" } |
      Select-Object Name, DisplayName, DisplayValue, RegistryKeyword, RegistryValue |
      Format-Table -AutoSize | Out-Host
  }
}

# ----------------------------
# Core actions
# ----------------------------
function Ensure-ComputerName([string]$ServerName) {
  if ($env:COMPUTERNAME -ne $ServerName) {
    Rename-Computer -NewName $ServerName -Force
    Add-Change ("Renamed computer {0} -> {1}" -f $env:COMPUTERNAME, $ServerName)
    Mark-RebootRequired
  }
}

function Install-Prereqs {
  $features = @("Data-Center-Bridging","Failover-Clustering","Hyper-V","Windows-Server-Backup","FS-SMBBW")
  foreach ($f in $features) {
    $st = (Get-WindowsFeature -Name $f).InstallState
    if ($st -ne "Installed") {
      Install-WindowsFeature -Name $f -IncludeManagementTools | Out-Null
      Add-Change ("Installed Windows Feature: {0}" -f $f)
      Mark-RebootRequired
    }
  }
}

function Enable-RemoteDesktop {
  $cur = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections").fDenyTSConnections
  if ($cur -ne 0) {
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
    Add-Change "Enabled RDP (fDenyTSConnections=0)"
  }
  Enable-NetFirewallRule -DisplayGroup "Remote Desktop" | Out-Null
}

function Get-DomainState {
  try {
    $cs = Get-CimInstance Win32_ComputerSystem
    return [pscustomobject]@{
      PartOfDomain = [bool]$cs.PartOfDomain
      Domain       = [string]$cs.Domain
    }
  }
  catch {
    return [pscustomobject]@{
      PartOfDomain = $false
      Domain       = ""
    }
  }
}

function Ensure-DomainJoinInteractive {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$DomainName,
    [string]$OUPath
  )

  $st = Get-DomainState

  # Already correct domain
  if ($st.PartOfDomain -and ($st.Domain -ieq $DomainName)) {
    Write-Host ("Already joined to domain: {0}" -f $st.Domain) -ForegroundColor Green
    return
  }

  # Joined to wrong domain (we do nothing automatically)
  if ($st.PartOfDomain -and ($st.Domain -ine $DomainName)) {
    Write-Warning ("Machine is joined to domain '{0}', expected '{1}'." -f $st.Domain, $DomainName)
    Write-Warning "This script will not auto-switch domains. Handle manually."
    return
  }

  # Not domain joined
  Write-Warning "The machine is not domain joined."

  Write-Host ""
  Write-Host "Planned action:" -ForegroundColor Cyan
  Write-Host ("  Join domain : {0}" -f $DomainName) -ForegroundColor Cyan

  if ([string]::IsNullOrWhiteSpace($OUPath)) {
    Write-Host "  OU path     : default container" -ForegroundColor Cyan
  }
  else {
    Write-Host ("  OU path     : {0}" -f $OUPath) -ForegroundColor Cyan
  }

  Write-Host "  Reboot      : REQUIRED after join" -ForegroundColor Cyan
  Write-Host ""

  $ans = Read-Host "Proceed with domain join now? (Y/N)"
  if ($ans -notin @("Y","y","Yes","yes")) {
    Write-Host "Skipping domain join (user chose No)." -ForegroundColor Yellow
    return
  }

  $cred = Get-Credential -Message ("Enter credentials allowed to join domain '{0}'" -f $DomainName)

  if ([string]::IsNullOrWhiteSpace($OUPath)) {
    Add-Computer -DomainName $DomainName -Credential $cred -Force -ErrorAction Stop
    Add-Change ("Joined domain {0}" -f $DomainName)
  }
  else {
    Add-Computer -DomainName $DomainName -OUPath $OUPath -Credential $cred -Force -ErrorAction Stop
    Add-Change ("Joined domain {0} (OU: {1})" -f $DomainName, $OUPath)
  }

  Mark-RebootRequired
}


function Cisco-UpLinkTeam {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][int]$FabricVLAN,
    [Parameter(Mandatory)][int]$FabricPrefixLength,
    [Parameter(Mandatory)][string]$FabricGateway,
    [Parameter(Mandatory)][string[]]$FabricDNS,
    [Parameter(Mandatory)][string]$FabricIP,
    [string]$VSwitchName = "Fabric_Uplink",
    [int]$ExpectedLinkSpeedGbps = 10
  )

  Write-Host "=== Cisco Fabric uplink: SET vSwitch ===" -ForegroundColor Cyan

  $uplinks = Get-AdaptersByLinkSpeed -ExpectedLinkSpeedGbps $ExpectedLinkSpeedGbps -ExpectedCount 2
  Debug-Adapters -Title "Cisco uplinks" -Names @($uplinks[0].Name, $uplinks[1].Name)
  # Prevent Cluster Validation warning: "Unable to determine RDMA technology type" for SET uplinks.
  # In this build, Fabric_Uplink is a SET vSwitch for management/fabric traffic (no SMB Direct).
  $uNames = @($uplinks[0].Name, $uplinks[1].Name)
  try {
    $rdma = @(Get-NetAdapterRdma -ErrorAction SilentlyContinue | Where-Object { $uNames -contains $_.Name })
    if ($rdma.Count -gt 0 -and ($rdma | Where-Object { $_.Enabled -eq $true })) {
      Disable-NetAdapterRdma -Name $uNames -ErrorAction Stop | Out-Null
      Add-Change ("Disabled RDMA on SET uplinks: {0}" -f ($uNames -join ", "))
    }
  } catch {
    Write-Warning ("Failed to evaluate/disable RDMA on SET uplinks: {0}" -f $_.Exception.Message)
  }


  $sw = Get-VMSwitch -Name $VSwitchName -ErrorAction SilentlyContinue
  if (-not $sw) {
    New-VMSwitch -Name $VSwitchName -AllowManagementOS $true -NetAdapterName $uplinks[0].Name, $uplinks[1].Name `
      -EnableEmbeddedTeaming $true -MinimumBandwidthMode Weight | Out-Null
    Start-Sleep -Seconds 3
    Set-VMSwitchTeam -Name $VSwitchName -LoadBalancingAlgorithm HyperVPort | Out-Null
    Add-Change ("Created SET vSwitch '{0}' on uplinks {1}, {2}" -f $VSwitchName, $uplinks[0].Name, $uplinks[1].Name)
  }

  $mgmtVnicAlias = "vEthernet ($VSwitchName)"
  $vnic = Get-NetAdapter -InterfaceAlias $mgmtVnicAlias -ErrorAction SilentlyContinue
  if (-not $vnic) { throw "Host vNIC '$mgmtVnicAlias' not found after vSwitch '$VSwitchName'." }

  Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $VSwitchName -Access -VlanID $FabricVLAN -ErrorAction Stop
  Add-Change ("Set VLAN {0} on host vNIC '{1}'" -f $FabricVLAN, $mgmtVnicAlias)

  Ensure-IPv4Address -InterfaceIndex $vnic.ifIndex -IPAddress $FabricIP -PrefixLength $FabricPrefixLength -DefaultGateway $FabricGateway -Context "Fabric vNIC"
  Set-DnsClientServerAddress -InterfaceIndex $vnic.ifIndex -ServerAddresses $FabricDNS -ErrorAction Stop
  Add-Change ("Set DNS on '{0}' to {1}" -f $mgmtVnicAlias, ($FabricDNS -join ", "))
}

function Rdma-RenameOnly {
  [CmdletBinding()]
  param([int]$ExpectedLinkSpeedGbps = 25)

  Write-Host "=== Mellanox RDMA rename ===" -ForegroundColor Cyan

  $rdmaUplinks = Get-AdaptersByLinkSpeed -ExpectedLinkSpeedGbps $ExpectedLinkSpeedGbps -ExpectedCount 2
  Debug-Adapters -Title "RDMA uplinks (pre-rename)" -Names @($rdmaUplinks[0].Name, $rdmaUplinks[1].Name)

  $nic1 = $rdmaUplinks[0]
  $nic2 = $rdmaUplinks[1]

  $desiredName1 = "$($nic1.Name) (RDMA1)"
  $desiredName2 = "$($nic2.Name) (RDMA2)"

  # If they are already renamed, keep them stable:
  if ($nic1.Name -match '\(RDMA[12]\)$' -or $nic2.Name -match '\(RDMA[12]\)$') {
    # Try to detect the two RDMA NICs by existing naming
    $already = @(Get-NetAdapter | Where-Object { $_.Name -match '\(RDMA[12]\)$' } | Sort-Object ifIndex)
    if ($already.Count -eq 2) {
      Debug-Adapters -Title "RDMA uplinks already renamed" -Names @($already[0].Name, $already[1].Name)
      return $already
    }
  }

  Rename-NetAdapterSafe -OldName $nic1.Name -NewName $desiredName1
  Rename-NetAdapterSafe -OldName $nic2.Name -NewName $desiredName2

  $out = @(
    (Get-NetAdapter -Name $desiredName1 -ErrorAction Stop),
    (Get-NetAdapter -Name $desiredName2 -ErrorAction Stop)
  )
  Debug-Adapters -Title "RDMA uplinks (post-rename)" -Names @($out[0].Name, $out[1].Name)
  return $out
}

# QoS: Server 2025 friendly ensure functions (no PolicyStore)
function Ensure-NetQosPolicy445 {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Priority)

  $p = Get-NetQosPolicy -Name $Name -ErrorAction SilentlyContinue
  if (-not $p) {
    New-NetQosPolicy -Name $Name -NetDirectPortMatchCondition 445 -PriorityValue8021Action $Priority -ErrorAction Stop | Out-Null
    Add-Change ("Created NetQosPolicy '{0}' for port 445 priority {1}" -f $Name, $Priority)
    return
  }

  # Update to desired
  Set-NetQosPolicy -Name $Name -NetDirectPortMatchCondition 445 -PriorityValue8021Action $Priority -ErrorAction Stop | Out-Null
}
function Ensure-NetQosPolicy3343 {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][int]$Priority
  )

  # Cluster Validation looks specifically for a "Failover Clustering" QoS rule.
  # Prefer the built-in -Cluster switch when available (most reliable across OS builds).
  $cmd = Get-Command -Name New-NetQosPolicy -ErrorAction Stop
  $supportsCluster = $cmd.Parameters.ContainsKey('Cluster')

  $p = Get-NetQosPolicy -Name $Name -ErrorAction SilentlyContinue

  if ($supportsCluster) {
    if (-not $p) {
      New-NetQosPolicy -Name $Name -Cluster -PriorityValue8021Action $Priority -ErrorAction Stop | Out-Null
      Add-Change ("Created NetQosPolicy '{0}' for Failover Clustering (-Cluster) priority {1}" -f $Name, $Priority)
      return
    }

    # If policy exists but is not the expected template, recreate it to avoid Cluster Validation noise.
    $tmpl = [string]$p.Template
    if ($tmpl -and ($tmpl -notmatch 'Failover\s+Clustering')) {
      Remove-NetQosPolicy -Name $Name -Confirm:$false -ErrorAction SilentlyContinue
      New-NetQosPolicy -Name $Name -Cluster -PriorityValue8021Action $Priority -ErrorAction Stop | Out-Null
      Add-Change ("Recreated NetQosPolicy '{0}' as Failover Clustering (-Cluster) priority {1}" -f $Name, $Priority)
      return
    }

    # Best effort: enforce priority
    try { Set-NetQosPolicy -Name $Name -PriorityValue8021Action $Priority -ErrorAction Stop | Out-Null } catch { }
    return
  }

  # Fallback for older builds: match UDP/3343 (may not satisfy validator in all versions)
  if (-not $p) {
    New-NetQosPolicy -Name $Name -IPDstPortMatchCondition 3343 -IPProtocolMatchCondition UDP -PriorityValue8021Action $Priority -ErrorAction Stop | Out-Null
    Add-Change ("Created NetQosPolicy '{0}' for Failover Clustering (UDP/3343) priority {1}" -f $Name, $Priority)
    return
  }

  Set-NetQosPolicy -Name $Name -IPDstPortMatchCondition 3343 -IPProtocolMatchCondition UDP -PriorityValue8021Action $Priority -ErrorAction Stop | Out-Null
}


function Ensure-NetQosTrafficClass {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Priority, [Parameter(Mandatory)][int]$BandwidthPercentage)

  $tc = Get-NetQosTrafficClass -Name $Name -ErrorAction SilentlyContinue
  if (-not $tc) {
    New-NetQosTrafficClass -Name $Name -Priority $Priority -BandwidthPercentage $BandwidthPercentage -Algorithm ETS -ErrorAction Stop | Out-Null
    Add-Change ("Created TrafficClass '{0}' prio {1} bw {2}% (ETS)" -f $Name, ($Priority -join ","), $BandwidthPercentage)
    return
  }

  Set-NetQosTrafficClass -Name $Name -Priority $Priority -BandwidthPercentage $BandwidthPercentage -Algorithm ETS -ErrorAction Stop | Out-Null
}

function Mellanox-UpLinks {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][int]$RDMAVlan,
    [Parameter(Mandatory)][string]$RDMA1IP,
    [Parameter(Mandatory)][string]$RDMA2IP,
    [Parameter(Mandatory)][int]$RDMAPrefixLength,

    [int]$ExpectedLinkSpeedGbps = 25,
    [int]$PfcPriority = 3,
    [int]$SmbBandwidthPercent = 90,
    [int]$JumboBytes = 9000
  )

  Write-Host "=== Mellanox DirectRDMA (no vSwitch) ===" -ForegroundColor Cyan

  $nics = Rdma-RenameOnly -ExpectedLinkSpeedGbps $ExpectedLinkSpeedGbps
  $nic1 = $nics[0]
  $nic2 = $nics[1]

  # QoS names (avoid collisions)
  $QosPolicyName = "S2D-SMB-445"
  $QosTcName     = "S2D-SMB"

  Debug-QosState -Title "QoS pre-state"

  Ensure-NetQosPolicy445 -Name $QosPolicyName -Priority $PfcPriority

  # Cluster policy (prio 0) to satisfy Cluster Validation 'QoS Rule for Failover Clustering'
  $ClusterPolicyName = "S2D-Cluster-3343"
  Ensure-NetQosPolicy3343 -Name $ClusterPolicyName -Priority 0

  Enable-NetQosFlowControl  -Priority $PfcPriority -ErrorAction Stop
  Disable-NetQosFlowControl -Priority (0..7 | Where-Object { $_ -ne $PfcPriority }) -ErrorAction Stop

  Ensure-NetQosTrafficClass -Name $QosTcName -Priority $PfcPriority -BandwidthPercentage $SmbBandwidthPercent

  # Host-driven DCBX
  Set-NetQosDcbxSetting -Willing 0 -Confirm:$false | Out-Null

  Enable-NetAdapterQos -Name $nic1.Name -ErrorAction Stop
  Enable-NetAdapterQos -Name $nic2.Name -ErrorAction Stop

  # NIC advanced props: FlowControl OFF (best effort) + VLAN + Jumbo
  # NOTE: Your adapter shows RegistryKeyword '#FlowControl' and 'VlanID' / '*JumboPacket'
  # Try common driver keywords for Flow Control
  try { Ensure-AdapterAdvancedProperty -Name $nic1.Name -RegistryKeyword "*FlowControl" -RegistryValue 0 -What "Flow Control" -QuietIfMissing } catch {}
  try { Ensure-AdapterAdvancedProperty -Name $nic1.Name -RegistryKeyword "#FlowControl" -RegistryValue 0 -What "Flow Control" -QuietIfMissing } catch {}

  try { Ensure-AdapterAdvancedProperty -Name $nic2.Name -RegistryKeyword "*FlowControl" -RegistryValue 0 -What "Flow Control" -QuietIfMissing } catch {}
  try { Ensure-AdapterAdvancedProperty -Name $nic2.Name -RegistryKeyword "#FlowControl" -RegistryValue 0 -What "Flow Control" -QuietIfMissing } catch {}
  Ensure-AdapterAdvancedProperty -Name $nic1.Name -RegistryKeyword "VlanID" -RegistryValue $RDMAVlan -What "VLAN ID"
  Ensure-AdapterAdvancedProperty -Name $nic2.Name -RegistryKeyword "VlanID" -RegistryValue $RDMAVlan -What "VLAN ID"

  Ensure-JumboBytes -Name $nic1.Name -JumboBytes $JumboBytes
  Ensure-JumboBytes -Name $nic2.Name -JumboBytes $JumboBytes

  Debug-QosState -Title "QoS post-state"
  
  Ensure-RoceV2 -Name $nic1.Name
  Ensure-RoceV2 -Name $nic2.Name

  Enable-NetAdapterRdma -Name $nic1.Name, $nic2.Name -ErrorAction Stop

  $idx1 = (Get-NetAdapter -Name $nic1.Name -ErrorAction Stop).ifIndex
  $idx2 = (Get-NetAdapter -Name $nic2.Name -ErrorAction Stop).ifIndex

  Ensure-IPv4Address -InterfaceIndex $idx1 -IPAddress $RDMA1IP -PrefixLength $RDMAPrefixLength -Context "RDMA1"
  Ensure-IPv4Address -InterfaceIndex $idx2 -IPAddress $RDMA2IP -PrefixLength $RDMAPrefixLength -Context "RDMA2"

  Debug-Block -Title "RDMA state" -Script {
    Get-NetAdapterRdma | Format-Table -AutoSize | Out-Host
  }

  Debug-Adapters -Title "RDMA NICs final" -Names @($nic1.Name, $nic2.Name)
}

function Invoke-Preflight {
  [CmdletBinding()]
  param()

  Write-Host ""
  Write-Host "=== PREFLIGHT (read-only checks) ===" -ForegroundColor Cyan

  $issues = New-Object System.Collections.Generic.List[string]
  function Add-Issue([string]$msg) { $issues.Add($msg) | Out-Null }

  # Admin check
  try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
      IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Add-Issue "Not running elevated (Administrator)." }
  } catch { }

  # Timezone check
  try {
    $curTz = (Get-TimeZone).Id
    if ($curTz -ine $desiredTimeZoneId) {
      Add-Issue ("Timezone mismatch. Current='{0}', Desired='{1}'" -f $curTz, $desiredTimeZoneId)
    }
  } catch {
    Add-Issue "Unable to read timezone (Get-TimeZone failed)."
  }

  # Windows Features (prereqs)
  $features = @("Data-Center-Bridging","Failover-Clustering","Hyper-V","Windows-Server-Backup","FS-SMBBW")
  foreach ($f in $features) {
    try {
      $st = (Get-WindowsFeature -Name $f).InstallState
      Write-Host ("Feature {0,-22}: {1}" -f $f, $st) -ForegroundColor Gray
      if ($st -ne "Installed") { Add-Issue ("Feature not installed: {0}" -f $f) }
    } catch {
      Add-Issue ("Unable to query feature: {0}" -f $f)
    }
  }

  # Adapter inventory (do not throw)
  try {
    $ten = @(Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.PhysicalMediaType -eq "802.3" -and ($_.LinkSpeed -like "10*Gbps" -or $_.LinkSpeed -eq "10 Gbps") })
    if ($ten.Count -ne 2) { Add-Issue ("Expected 2x 10GbE adapters Up, found {0}" -f $ten.Count) }
  } catch { Add-Issue "Unable to enumerate 10GbE adapters." }

  try {
    $twf = @(Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.PhysicalMediaType -eq "802.3" -and ($_.LinkSpeed -like "25*Gbps" -or $_.LinkSpeed -eq "25 Gbps") })
    if ($twf.Count -ne 2) { Add-Issue ("Expected 2x 25GbE adapters Up, found {0}" -f $twf.Count) }
  } catch { Add-Issue "Unable to enumerate 25GbE adapters." }

  # vSwitch presence (informational)
  try {
    $sw = Get-VMSwitch -Name "Fabric_Uplink" -ErrorAction SilentlyContinue
    if (-not $sw) { Add-Issue "VMSwitch 'Fabric_Uplink' not found (will be created by Cisco stage)." }
  } catch { }

  # RDMA state (informational)
  try {
    $rd = @(Get-NetAdapterRdma -ErrorAction SilentlyContinue)
    if ($rd.Count -eq 0) { Add-Issue "Get-NetAdapterRdma returned no entries (RDMA stack not ready?)." }
  } catch { }

  Write-Host ""
  if ($issues.Count -eq 0) {
    Write-Host "Preflight OK (no issues detected)." -ForegroundColor Green
    Add-Change "Preflight OK"
  } else {
    Write-Warning ("Preflight found {0} issue(s):" -f $issues.Count)
    foreach ($i in $issues) { Write-Warning (" - {0}" -f $i) }
    Add-Change ("Preflight issues: {0}" -f $issues.Count)
  }
}

function Invoke-PerfTune {
  [CmdletBinding()]
  param()

  Write-Host "`n=== PerfTune: NUMA-aware RSS tuning ===" -ForegroundColor Cyan

  # Target physical RDMA adapters (exclude vEthernet / SET members)
  $rdmaAdapters = @(Get-NetAdapterRdma -ErrorAction SilentlyContinue | Where-Object {
      $_.Enabled -eq $true -and $_.Name -notlike "vEthernet*"
    })

  if (-not $rdmaAdapters -or $rdmaAdapters.Count -eq 0) {
    Write-Host "No RDMA-enabled physical adapters found. Nothing to tune." -ForegroundColor DarkYellow
    return
  }

  foreach ($a in $rdmaAdapters) {
    try {
      Set-RssNumaAware -Name $a.Name -DesiredQueues 8
    }
    catch {
      Write-Host ("[PerfTune] Failed RSS tune on '{0}': {1}" -f $a.Name, $_.Exception.Message) -ForegroundColor DarkYellow
    }
  }

  Write-Host "PerfTune complete." -ForegroundColor Green
}


function Invoke-BufferTune {
  [CmdletBinding()]
  param()

  Write-Host "`n=== BufferTune: NIC buffers + RSS queues (safe) ===" -ForegroundColor Cyan

  # Target physical RDMA adapters (exclude vEthernet / SET members)
  $rdmaAdapters = @(Get-NetAdapterRdma -ErrorAction SilentlyContinue | Where-Object {
      $_.Enabled -eq $true -and $_.Name -notlike "vEthernet*"
    })

  if (-not $rdmaAdapters -or $rdmaAdapters.Count -eq 0) {
    Write-Host "No RDMA-enabled physical adapters found. Nothing to tune." -ForegroundColor DarkYellow
    return
  }

  function Set-AdvIntIfLower {
    param(
      [Parameter(Mandatory=$true)][string]$Name,
      [Parameter(Mandatory=$true)][string]$DisplayName,
      [Parameter(Mandatory=$true)][int]$Desired
    )
    try {
      $p = Get-NetAdapterAdvancedProperty -Name $Name -ErrorAction Stop | Where-Object { $_.DisplayName -eq $DisplayName } | Select-Object -First 1
      if (-not $p) {
        Write-Host ("[BufferTune] '{0}': Advanced property '{1}' not found; skipping." -f $Name, $DisplayName) -ForegroundColor DarkYellow
        return
      }
      $cur = 0
      [void][int]::TryParse([string]$p.DisplayValue, [ref]$cur)

      if ($cur -ge $Desired) {
        Write-Host ("[BufferTune] '{0}': {1} already {2} (>= {3}); no change." -f $Name, $DisplayName, $cur, $Desired) -ForegroundColor DarkGray
        return
      }

      Set-NetAdapterAdvancedProperty -Name $Name -DisplayName $DisplayName -DisplayValue ([string]$Desired) -NoRestart -ErrorAction Stop
      Write-Host ("[BufferTune] '{0}': Set {1} {2} -> {3}" -f $Name, $DisplayName, $cur, $Desired) -ForegroundColor Green
    }
    catch {
      Write-Host ("[BufferTune] '{0}': Failed to set '{1}': {2}" -f $Name, $DisplayName, $_.Exception.Message) -ForegroundColor DarkYellow
    }
  }

  foreach ($a in $rdmaAdapters) {
    # 1) RSS queue target (NUMA-aware) - keep separate from PerfTune runs
    try {
      Set-RssNumaAware -Name $a.Name -DesiredQueues 8
    }
    catch {
      Write-Host ("[BufferTune] '{0}': RSS queue tune failed: {1}" -f $a.Name, $_.Exception.Message) -ForegroundColor DarkYellow
    }

    # 2) Buffers
    Set-AdvIntIfLower -Name $a.Name -DisplayName "Receive Buffers" -Desired 4096
    Set-AdvIntIfLower -Name $a.Name -DisplayName "Send Buffers"    -Desired 4096
  }

  Write-Host "BufferTune complete." -ForegroundColor Green
}

function Set-RssNumaAware {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][int]$DesiredQueues
  )

  try {
    $rss = Get-NetAdapterRss -Name $Name -ErrorAction Stop

    # BaseProcessor may be a formatted string OR structured fields depending on OS/driver
    $baseGroup = 0
    $baseNum   = 0

    # Preferred: structured properties (may be empty on some driver/OS combos)
    if ($rss.PSObject.Properties.Match('BaseProcessorGroup').Count -gt 0 -and $rss.PSObject.Properties.Match('BaseProcessorNumber').Count -gt 0) {
        $bg = $rss.BaseProcessorGroup
        $bn = $rss.BaseProcessorNumber
        if (-not [string]::IsNullOrWhiteSpace([string]$bg)) { $baseGroup = [int]$bg }
        if (-not [string]::IsNullOrWhiteSpace([string]$bn)) { $baseNum   = [int]$bn }
    } else {
        # Fallback: legacy formatted value (e.g. "0:0" or ":0") or object with Group/Number
        $bp = $null
        if ($rss.PSObject.Properties.Match('BaseProcessor').Count -gt 0) { $bp = $rss.BaseProcessor }
        if ($null -ne $bp) {
            if ($bp -is [string]) {
                if ($bp -match '^(?<g>\d+)\s*[:/]\s*(?<n>\d+)$') { $baseGroup=[int]$matches.g; $baseNum=[int]$matches.n }
                elseif ($bp -match ':(?<n>\d+)$') { $baseGroup=0; $baseNum=[int]$matches.n }  # e.g. ":0"
            } elseif ($bp.PSObject.Properties.Match('Group').Count -gt 0 -and $bp.PSObject.Properties.Match('Number').Count -gt 0) {
                if (-not [string]::IsNullOrWhiteSpace([string]$bp.Group))  { $baseGroup = [int]$bp.Group }
                if (-not [string]::IsNullOrWhiteSpace([string]$bp.Number)) { $baseNum   = [int]$bp.Number }
            } else {
                $bpStr = [string]$bp
                if ($bpStr -match '^(?<g>\d+)\s*[:/]\s*(?<n>\d+)$') { $baseGroup=[int]$matches.g; $baseNum=[int]$matches.n }
                elseif ($bpStr -match ':(?<n>\d+)$') { $baseGroup=0; $baseNum=[int]$matches.n }
            }
        }
    }

    # Additional fallback: some builds expose Base as a nested object (e.g. $rss.Base.ProcessorNumber / ProcessorGroup)
    if (($baseGroup -eq 0 -and $baseNum -eq 0) -and ($rss.PSObject.Properties.Name -contains 'Base') -and $rss.Base) {
        try {
            if ($rss.Base.PSObject.Properties.Name -contains 'ProcessorGroup')   { $baseGroup = [int]$rss.Base.ProcessorGroup }
            if ($rss.Base.PSObject.Properties.Name -contains 'ProcessorNumber')  { $baseNum   = [int]$rss.Base.ProcessorNumber }
        } catch { }
    }

    # Rich debug dump (helps when ISE truncates objects)
if ($script:PerfTuneSummary -or $DebugMode) {
    # Compact diagnostics (safe to use in transcripts; avoids huge JSON dumps)
    try {
        $sample = @()
        if ($null -ne $rss.RssProcessorArray) {
            $i = 0
            foreach ($e in @($rss.RssProcessorArray)) {
                if ($i -ge 10) { break }
                $g = $null; $n = $null; $d = $null
                if ($e -is [string]) { break } # handled separately below
                if ($e.PSObject.Properties.Match('Group').Count)         { $g = $e.Group }
                elseif ($e.PSObject.Properties.Match('ProcessorGroup').Count) { $g = $e.ProcessorGroup }
                if ($e.PSObject.Properties.Match('Number').Count)        { $n = $e.Number }
                elseif ($e.PSObject.Properties.Match('ProcessorNumber').Count) { $n = $e.ProcessorNumber }
                if ($e.PSObject.Properties.Match('Distance').Count)      { $d = $e.Distance }
                elseif ($e.PSObject.Properties.Match('PreferenceIndex').Count) { $d = $e.PreferenceIndex }
                else { $d = 0 }
                if ($null -ne $g -and $null -ne $n) {
                    $sample += ("{0}:{1}/{2}" -f $g, $n, $d)
                    $i++
                }
            }
        }
        $summary = [pscustomobject]@{
            Name                   = $Name
            Enabled                = $rss.Enabled
            NumaNode               = $rss.NumaNode
            BaseProcessorGroup     = $rss.BaseProcessorGroup
            BaseProcessorNumber    = $rss.BaseProcessorNumber
            NumberOfReceiveQueues  = $rss.NumberOfReceiveQueues
            MaxProcessors          = $rss.MaxProcessors
            MaxProcessorGroups     = $rss.MaxProcessorGroups
            Profile                = $rss.Profile
            RssProcessorArrayType  = if ($null -eq $rss.RssProcessorArray) { "<null>" } else { $rss.RssProcessorArray.GetType().FullName }
            RssProcessorArraySample = if ($sample.Count -gt 0) { ($sample -join ", ") } else { "" }
        }
        Write-Host ("[PerfTuneSummary] {0}" -f ($summary | ConvertTo-Json -Compress)) -ForegroundColor Cyan
    } catch { }
}

if ($DebugMode) {
    Write-Host ("[DEBUG] [PerfTune] '{0}' RSS raw object (JSON)" -f $Name) -ForegroundColor Yellow
    try { ($rss | ConvertTo-Json -Depth 8) | Out-Host } catch { }
}



    if ($baseGroup -lt 0 -or $baseNum -lt 0) {
      Write-Warning ("[PerfTune] '{0}': Invalid BaseProcessorGroup/BaseProcessorNumber parsed; skipping." -f $Name)
      return
    }

    # Build a candidate CPU list from RssProcessorArray (string or object), but never rely on formatting.
    $entries = @()

    if ($null -ne $rss.RssProcessorArray) {
      if ($rss.RssProcessorArray -is [string]) {
        $s = $rss.RssProcessorArray
        foreach ($m in ([regex]::Matches($s, '(\d+):(\d+)/(\d+)'))) {
          $entries += [pscustomobject]@{ Group=[int]$m.Groups[1].Value; Number=[int]$m.Groups[2].Value; Distance=[int]$m.Groups[3].Value }
        }
      }
      else {
        foreach ($e in @($rss.RssProcessorArray)) {
  try {
    # Different OS/driver combos expose different property names:
    #   - Group/Number/Distance
    #   - ProcessorGroup/ProcessorNumber/PreferenceIndex
    $g = $null
    $n = $null
    $d = $null

    if ($e.PSObject.Properties.Match('Group').Count -gt 0) { $g = $e.Group }
    elseif ($e.PSObject.Properties.Match('ProcessorGroup').Count -gt 0) { $g = $e.ProcessorGroup }

    if ($e.PSObject.Properties.Match('Number').Count -gt 0) { $n = $e.Number }
    elseif ($e.PSObject.Properties.Match('ProcessorNumber').Count -gt 0) { $n = $e.ProcessorNumber }

    if ($e.PSObject.Properties.Match('Distance').Count -gt 0) { $d = $e.Distance }
    elseif ($e.PSObject.Properties.Match('PreferenceIndex').Count -gt 0) { $d = $e.PreferenceIndex }
    else { $d = 0 }

    if ($null -ne $g -and $null -ne $n) {
      $entries += [pscustomobject]@{ Group=[int]$g; Number=[int]$n; Distance=[int]$d }
    }
  } catch { }
}
        }
      }

    if (-not $entries -or $entries.Count -eq 0) {
      # Some OS/driver combinations don't populate RssProcessorArray at all.
      # In that case we still can apply useful tuning using BaseProcessorGroup/Number + counts.
      Write-Host ("[PerfTune] '{0}': RssProcessorArray not populated on this OS/driver; using BaseProcessorGroup/Number + Profile Closest tuning." -f $Name)

      $effectiveDesiredQueues = [int]$DesiredQueues
      try {
        $procs = Get-CimInstance Win32_Processor -ErrorAction Stop
        $logicalTotal  = [int](($procs | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
        $physicalTotal = [int](($procs | Measure-Object -Property NumberOfCores -Sum).Sum)
        $socketCount   = [int](($procs | Measure-Object).Count)
        if ($socketCount -lt 1) { $socketCount = 1 }

        $htEnabled = $false
        if ($logicalTotal -gt 0 -and $physicalTotal -gt 0 -and $logicalTotal -gt $physicalTotal) { $htEnabled = $true }

        $coresPerSocket   = [int][math]::Floor($physicalTotal / $socketCount)
        $logicalPerSocket = [int][math]::Floor($logicalTotal  / $socketCount)

        $cap = if ($htEnabled -and $coresPerSocket -gt 0) { $coresPerSocket } elseif ($logicalPerSocket -gt 0) { $logicalPerSocket } else { $effectiveDesiredQueues }
        if ($cap -gt 0) { $effectiveDesiredQueues = [int][math]::Min($effectiveDesiredQueues, $cap) }
      } catch {
        # If WMI is locked down or fails, keep the requested queue count.
      }

      if ($effectiveDesiredQueues -lt 1) { $effectiveDesiredQueues = 1 }

      # Only change settings if needed
      $need = $false
      if ($rss.Profile -ne 'Closest') { $need = $true }
      if ($rss.NumberOfReceiveQueues -ne $effectiveDesiredQueues) { $need = $true }
      if ($rss.MaxProcessors -ne $effectiveDesiredQueues) { $need = $true }
      if ($baseGroup -ne $rss.BaseProcessorGroup) { $need = $true }
      if ($baseNum -ne $rss.BaseProcessorNumber) { $need = $true }

      if (-not $need) {
        Write-Host ("[PerfTune] '{0}': RSS already in desired state (fallback path)." -f $Name) -ForegroundColor DarkGray
        return
      }

      try {
        Set-NetAdapterRss -Name $Name `
          -Profile Closest `
          -BaseProcessorGroup $baseGroup -BaseProcessorNumber $baseNum `
          -MaxProcessors $effectiveDesiredQueues -NumberOfReceiveQueues $effectiveDesiredQueues `
          -ErrorAction Stop | Out-Null

        Write-Host ("[PerfTune] '{0}': Applied fallback RSS tune. Base={1}:{2} MaxProcs={3} Queues={3}" -f $Name, $baseGroup, $baseNum, $effectiveDesiredQueues) -ForegroundColor Green
      } catch {
        Write-Warning ("[PerfTune] '{0}': Fallback RSS tuning failed: {1}" -f $Name, $_.Exception.Message)
      }
      return
    }

    # Choose effective processor group for this NIC:
    # - Prefer the NIC's BaseProcessorGroup if it exists in the array
    # - Otherwise fall back to the most common group present
    $groups = $entries | Group-Object Group | Sort-Object Count -Descending
    $effectiveGroup = $baseGroup
    if (-not ($entries | Where-Object { $_.Group -eq $baseGroup })) {
      if ($groups -and $groups[0]) { $effectiveGroup = [int]$groups[0].Name }
    }

    # Pick the "closest" CPUs within the effective group:
    # Some drivers expose Distance=0, others expose PreferenceIndex (non-zero).
    $groupEntries = $entries | Where-Object { $_.Group -eq $effectiveGroup }
    if (-not $groupEntries -or $groupEntries.Count -eq 0) {
      Write-Warning ("[PerfTune] '{0}': No RSS processors found for effective Group {1}; skipping." -f $Name, $effectiveGroup)
      return
    }

    $minDist = ($groupEntries | Measure-Object -Minimum Distance).Minimum
    $local = $groupEntries | Where-Object { $_.Distance -eq $minDist } | Sort-Object Number -Unique

    if (-not $local -or $local.Count -eq 0) {
      # Absolute last resort: take the first N processors in the group ordered by Distance/Number
      $local = $groupEntries | Sort-Object Distance, Number -Unique
    }

    if (-not $local -or $local.Count -eq 0) {
      Write-Warning ("[PerfTune] '{0}': Unable to select candidate CPUs; skipping." -f $Name)
      return
    }

    # Detect Hyper-Threading by comparing cores vs logical processors.
    $cpu = Get-CimInstance Win32_Processor
    $cores   = ($cpu | Measure-Object -Sum NumberOfCores).Sum
    $logical = ($cpu | Measure-Object -Sum NumberOfLogicalProcessors).Sum
    $htOn = ($logical -gt $cores)

    # Pick one thread per core if HT is on; otherwise use all candidates.
    # NOTE: Some drivers already return one logical processor per physical core (e.g. only even CPU numbers).
    # In that case we should NOT halve again, or we will artificially cap queue count (e.g. 8 -> 6).
    $nums = @($local.Number)
    # Always avoid CPU0 (often overloaded with OS housekeeping / DPC/ISR)
    $numsNo0 = @($nums | Where-Object { $_ -ne 0 })
    if ($numsNo0.Count -gt 0) { $nums = $numsNo0 }
    if ($htOn -and $nums.Count -ge 2) {
      $hasEven = ($nums | Where-Object { ($_ % 2) -eq 0 } | Measure-Object).Count -gt 0
      $hasOdd  = ($nums | Where-Object { ($_ % 2) -ne 0 } | Measure-Object).Count -gt 0

      if ($hasEven -and $hasOdd) {
        # Prefer even (commonly maps to the first thread of each core on Windows), but keep the larger parity set if unsure.
        $even = @($nums | Where-Object { ($_ % 2) -eq 0 })
        $odd  = @($nums | Where-Object { ($_ % 2) -ne 0 })
        $nums = if ($even.Count -ge $odd.Count) { $even } else { $odd }
      } else {
        # Already core-only (single parity) -> keep as-is
      }
    }

    $want = [Math]::Min($DesiredQueues, $nums.Count)
    if ($want -lt 1) { $want = 1 }

    $baseNum = $nums[0]
    $maxNum  = $nums[$want-1]

    # Build a compatible splat for Set-NetAdapterRss (param names vary slightly across builds)
    $cmd = Get-Command Set-NetAdapterRss -ErrorAction Stop
    $splat = @{}

    if ($cmd.Parameters.ContainsKey('Name')) { $splat['Name'] = $Name }
    elseif ($cmd.Parameters.ContainsKey('InterfaceAlias')) { $splat['InterfaceAlias'] = $Name }
    elseif ($cmd.Parameters.ContainsKey('IfAlias')) { $splat['IfAlias'] = $Name }
    else { throw "Set-NetAdapterRss has no supported adapter name parameter on this build." }

    if ($cmd.Parameters.ContainsKey('BaseProcessorGroup'))  { $splat['BaseProcessorGroup']  = $baseGroup }
    if ($cmd.Parameters.ContainsKey('BaseProcessorNumber')) { $splat['BaseProcessorNumber'] = $baseNum }
    if ($cmd.Parameters.ContainsKey('MaxProcessorGroup'))   { $splat['MaxProcessorGroup']   = $baseGroup }
    if ($cmd.Parameters.ContainsKey('MaxProcessorNumber'))  { $splat['MaxProcessorNumber']  = $maxNum }
    if ($cmd.Parameters.ContainsKey('MaxProcessors'))       { $splat['MaxProcessors']       = $want }

    if ($cmd.Parameters.ContainsKey('NumberOfReceiveQueues')) { $splat['NumberOfReceiveQueues'] = $want }
    elseif ($cmd.Parameters.ContainsKey('ReceiveQueues'))     { $splat['ReceiveQueues'] = $want } # fallback

    if ($cmd.Parameters.ContainsKey('Profile')) { $splat['Profile'] = 'Closest' }

    Write-Host ("[PerfTune] '{0}': Group={1}, CPUs={2}-{3}, Queues={4}, HT={5} (cores={6}, logical={7}){8}" -f $Name,$effectiveGroup,$baseNum,$maxNum,$want,$htOn,$cores,$logical,($(if($effectiveGroup -ne $baseGroup){" (baseGroup=$baseGroup)"} else {""}))) -ForegroundColor Cyan

    if ($DebugMode) {
      Write-Host ("[PerfTune][Debug] Local CPUs (Distance=$minDist): {0}" -f (($local | Select-Object -Expand Number) -join ',')) -ForegroundColor DarkGray
      Write-Host ("[PerfTune][Debug] Picked CPUs: {0}" -f ($nums -join ',')) -ForegroundColor DarkGray
      Write-Host ("[PerfTune][Debug] Splat: {0}" -f (($splat.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ')) -ForegroundColor DarkGray
    }

    Set-NetAdapterRss @splat -ErrorAction Stop | Out-Null
  }
  catch {
    Write-Warning ("[PerfTune] Failed RSS tune on '{0}': {1}" -f $Name, $_.Exception.Message)
    if ($DebugMode) {
      Write-Host ("[PerfTune][Debug] ErrorRecord: {0}" -f ($_ | Out-String)) -ForegroundColor DarkGray
      if ($_.ScriptStackTrace) { Write-Host ("[PerfTune][Debug] Stack: {0}" -f $_.ScriptStackTrace) -ForegroundColor DarkGray }
    }
  }
}

# ----------------------------
# AutoPerfTune (RSS / queues, NUMA-friendly)
# ----------------------------
function Get-CpuTopology {
  try {
    $procs = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
    $physical = [int]($procs | Measure-Object -Property NumberOfCores -Sum).Sum
    $logical  = [int]($procs | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    if ($physical -lt 1) { $physical = 1 }
    if ($logical  -lt 1) { $logical  = $physical }
    return [pscustomobject]@{
      PhysicalCoresTotal = $physical
      LogicalTotal       = $logical
      HyperThreading     = ($logical -gt $physical)
      SocketCount        = ($procs.Count)
    }
  } catch {
    return [pscustomobject]@{
      PhysicalCoresTotal = 1
      LogicalTotal       = 1
      HyperThreading     = $false
      SocketCount        = 1
    }
  }
}

function Get-PerfTuneAdapters {
  [CmdletBinding()]
  param()

  # Identify the physical Mellanox/NVIDIA ConnectX uplinks (your RDMA-capable NICs).
  # We do NOT rely solely on the (RDMA1)/(RDMA2) suffix here, but we still include it as a strong hint.
  $nics = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
      $_.Status -eq 'Up' -and
      ($_.HardwareInterface -eq $true) -and
      ($_.InterfaceDescription -match 'Mellanox|NVIDIA|ConnectX') -and
      ($_.Name -notmatch '^vEthernet')
    } | Sort-Object ifIndex)

  # If your renaming logic already added (RDMA1)/(RDMA2), prefer those first (stable ordering across nodes)
  $rdmaNamed = @($nics | Where-Object { $_.Name -match '\(RDMA[12]\)$' } | Sort-Object ifIndex)
  if ($rdmaNamed.Count -gt 0) { return $rdmaNamed }

  return $nics
}

function Set-NicBuffersIfSupported {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$AdapterName,
    [int]$Receive = 1024,
    [int]$Send    = 4096
  )

  try {
    $rx = Get-NetAdapterAdvancedProperty -Name $AdapterName -DisplayName 'Receive Buffers' -ErrorAction SilentlyContinue
    if ($rx) {
      $min = [int]$rx.NumericParameterMinValue
      $max = [int]$rx.NumericParameterMaxValue
      $val = [int]([Math]::Min([Math]::Max($Receive,$min),$max))
      if ([int]$rx.DisplayValue -ne $val) {
        Write-Host ("[PerfTune] '{0}': Receive Buffers {1} -> {2} (min={3}, max={4})" -f $AdapterName,$rx.DisplayValue,$val,$min,$max) -ForegroundColor Cyan
        Set-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword $rx.RegistryKeyword -RegistryValue $val -NoRestart -ErrorAction Stop | Out-Null
      }
    }

    $tx = Get-NetAdapterAdvancedProperty -Name $AdapterName -DisplayName 'Send Buffers' -ErrorAction SilentlyContinue
    if ($tx) {
      $min = [int]$tx.NumericParameterMinValue
      $max = [int]$tx.NumericParameterMaxValue
      $val = [int]([Math]::Min([Math]::Max($Send,$min),$max))
      if ([int]$tx.DisplayValue -ne $val) {
        Write-Host ("[PerfTune] '{0}': Send Buffers {1} -> {2} (min={3}, max={4})" -f $AdapterName,$tx.DisplayValue,$val,$min,$max) -ForegroundColor Cyan
        Set-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword $tx.RegistryKeyword -RegistryValue $val -NoRestart -ErrorAction Stop | Out-Null
      }
    }
  }
  catch {
    Write-Warning ("[PerfTune] '{0}': Buffer tuning skipped/failed: {1}" -f $AdapterName, $_.Exception.Message)
  }
}

function Invoke-AutoPerfTune {
  [CmdletBinding()]
  param(
    [int]$DesiredMaxQueues = 8
  )

  Write-Host "=== AutoPerfTune: RSS/queues (NUMA-friendly) ===" -ForegroundColor Cyan

  function Get-RssCmdParamSet {
    $cmd = Get-Command Set-NetAdapterRss -ErrorAction SilentlyContinue
    if (-not $cmd) { return @{} }
    $set = @{}
    foreach ($p in $cmd.Parameters.Keys) { $set[$p] = $true }
    return $set
  }

  function Try-SetRss {
    param(
      [Parameter(Mandatory)][string]$AdapterName,
      [Parameter(Mandatory)][hashtable]$Splat,
      [string[]]$ProfilesToTry = @("Closest", "ClosestProcessor", "ClosestProcessorStatic", "NUMAStatic", "NUMAScaling")
    )

    $paramSet = Get-RssCmdParamSet

    if ($paramSet.ContainsKey("Profile")) {
      foreach ($prof in $ProfilesToTry) {
        try {
          $s = @{} + $Splat
          $s["Profile"] = $prof
          if ($DebugMode) {
            Write-Host ("[DEBUG] Set-NetAdapterRss for {0} with Profile='{1}' splat={2}" -f $AdapterName, $prof, ($s | ConvertTo-Json -Compress)) -ForegroundColor Yellow
          }
          Set-NetAdapterRss @s -ErrorAction Stop | Out-Null
          return $true
        } catch {
          # If profile is invalid, try next. If it's another failure, still bubble after the loop.
          $msg = $_.Exception.Message
          if ($DebugMode) { Write-Host ("[DEBUG] Profile '{0}' failed for {1}: {2}" -f $prof, $AdapterName, $msg) -ForegroundColor Yellow }
          continue
        }
      }
      return $false
    } else {
      # No -Profile support on this build; just try once
      try {
        if ($DebugMode) {
          Write-Host ("[DEBUG] Set-NetAdapterRss for {0} splat={1}" -f $AdapterName, ($Splat | ConvertTo-Json -Compress)) -ForegroundColor Yellow
        }
        Set-NetAdapterRss @Splat -ErrorAction Stop | Out-Null
        return $true
      } catch {
        return $false
      }
    }
  }

  $paramSet = Get-RssCmdParamSet
  if ($DebugMode) {
    Write-Host ("[DEBUG] Set-NetAdapterRss supports: {0}" -f (($paramSet.Keys | Sort-Object) -join ", ")) -ForegroundColor Yellow
  }

  # Determine target adapters (RDMA uplinks)
$targets = @(Get-PerfTuneAdapters)
if ($targets.Count -eq 0) {
  Write-Warning "AutoPerfTune: No Mellanox/NVIDIA ConnectX uplink adapters found in Up state. Skipping."
  return
}

if ($DebugMode) {
  Write-Host ("[DEBUG] AutoPerfTune targets: {0}" -f (($targets | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Yellow
}

# Adapter-level tuning (Option A: "lagom"): moderate buffer increase
foreach ($t in $targets) {
  Set-NicBuffersIfSupported -AdapterName $t.Name -Receive 1024 -Send 4096
}

  # CPU topology (best-effort)
  $numaNodes = @()
  try {
    $numaNodes = @(Get-NumaNode -ErrorAction Stop | Sort-Object NodeNumber)
  } catch {
    $numaNodes = @()
  }

  # Per NUMA node processor list (Group/Number)
  $nodeProcs = @{}
  if ($numaNodes.Count -gt 0) {
    foreach ($n in $numaNodes) {
      try {
        $procs = @(Get-NumaNodeProcessor -NodeNumber $n.NodeNumber -ErrorAction Stop | Sort-Object Group, Number)
        if ($procs.Count -gt 0) { $nodeProcs[[int]$n.NodeNumber] = $procs }
      } catch { }
    }
  }

  if ($DebugMode) {
    Write-Host "[DEBUG] NUMA nodes detected:" -ForegroundColor Yellow
    if ($numaNodes.Count -gt 0) {
      $numaNodes | Select-Object NodeNumber, ProcessorCount | Format-Table -AutoSize | Out-Host
    } else {
      Write-Host "[DEBUG] (none via Get-NumaNode; will use non-NUMA RSS settings)" -ForegroundColor Yellow
    }
  }

  foreach ($t in $targets) {
    Write-Host ("AutoPerfTune: {0}" -f $t.Name) -ForegroundColor Cyan

    # Always ensure RSS enabled
    try {
      Enable-NetAdapterRss -Name $t.Name -ErrorAction Stop | Out-Null
    } catch {
      Write-Warning ("AutoPerfTune: Failed to enable RSS on {0}: {1}" -f $t.Name, $_.Exception.Message)
      continue
    }

    $queues = [int]$DesiredMaxQueues

    # Build Set-NetAdapterRss splat using only supported params
    $splat = @{ Name = $t.Name }

    if ($paramSet.ContainsKey("NumberOfReceiveQueues")) { $splat.NumberOfReceiveQueues = $queues }
    if ($paramSet.ContainsKey("MaxProcessors")) { $splat.MaxProcessors = $queues } # good heuristic: queues ~= processors

    # NUMA-aware base/max processor (best effort). If we can't resolve, we won't set these.
    if ($nodeProcs.Count -gt 0) {
      $nodeKeys = @($nodeProcs.Keys | Sort-Object)
      $node = $nodeKeys[ ( [array]::IndexOf(@($targets.Name), $t.Name) ) % $nodeKeys.Count ]

      $plist = @($nodeProcs[[int]$node])
      if ($plist.Count -gt 0) {
        $take = [Math]::Min($queues, $plist.Count)
        $base = $plist[0]
        $max  = $plist[$take - 1]

        if ($paramSet.ContainsKey("BaseProcessorGroup"))  { $splat.BaseProcessorGroup  = [int]$base.Group }
        if ($paramSet.ContainsKey("BaseProcessorNumber")) { $splat.BaseProcessorNumber = [int]$base.Number }
        if ($paramSet.ContainsKey("MaxProcessorGroup"))   { $splat.MaxProcessorGroup   = [int]$max.Group }
        if ($paramSet.ContainsKey("MaxProcessorNumber"))  { $splat.MaxProcessorNumber  = [int]$max.Number }

        if ($DebugMode) {
          Write-Host ("[DEBUG] {0}: NUMA node {1}, processors selected {2} -> base {3}:{4}, max {5}:{6}" -f `
            $t.Name, $node, $take, $base.Group, $base.Number, $max.Group, $max.Number) -ForegroundColor Yellow
        }
      }
    }

    # Try applying (with profile retry)
    $ok = Try-SetRss -AdapterName $t.Name -Splat $splat
    if (-not $ok) {
      Write-Warning ("AutoPerfTune: Could not apply RSS tuning for {0}. Dumping current state for troubleshooting." -f $t.Name)
      try {
        Get-NetAdapterRss -Name $t.Name | Format-List * | Out-Host
      } catch { }
      continue
    }

    Add-Change ("AutoPerfTune: RSS tuned on {0} (queues={1})" -f $t.Name, $queues)
  }

  if ($DebugMode) {
    Write-Host ""
    Write-Host "[DEBUG] RSS post-state" -ForegroundColor Yellow
    foreach ($t in $targets) {
      try {
        Get-NetAdapterRss -Name $t.Name |
          Select-Object Name, Enabled, Profile, NumberOfReceiveQueues, MaxProcessors, BaseProcessorGroup, BaseProcessorNumber, MaxProcessorGroup, MaxProcessorNumber |
          Format-Table -AutoSize | Out-Host
      } catch { }
    }
  }
}

# ----------------------------
# EXECUTION
# ----------------------------
try {
  switch ($Mode) {
    "Preflight"   { Invoke-Preflight; Finish-Script; return }
    "PerfTune"    { Invoke-PerfTune; Finish-Script; return }
    "AutoPerfTune" { Invoke-AutoPerfTune; Finish-Script; return }
    "BufferTune"  { Invoke-BufferTune; Finish-Script; return }

    "RenameOnly"   { Ensure-ComputerName -ServerName $TargetName; Finish-Script; return }
    "PrereqsOnly"  { Install-Prereqs; Finish-Script; return }
    "RdpOnly"      { Enable-RemoteDesktop; Finish-Script; return }

    "CiscoOnly"    {
      Cisco-UpLinkTeam -FabricVLAN $FabricVLAN -FabricPrefixLength $FabricPrefixLength -FabricGateway $FabricGateway -FabricDNS $FabricDNS -FabricIP $FabricIP
      Finish-Script; return
    }

    "RdmaOnly"     { Rdma-RenameOnly | Out-Null; Finish-Script; return }

    "MellanoxOnly" {
      Mellanox-UpLinks -RDMAVlan $RDMAVlan -RDMA1IP $RDMA1IP -RDMA2IP $RDMA2IP -RDMAPrefixLength $RDMAPrefixLength
      Finish-Script; return
    }

    "All" {
      # ---------- STAGE 0: base OS: timezone + prereqs + rename (+ optional RDP) ----------
      Ensure-TimeZone -TimeZoneId $desiredTimeZoneId
      Install-Prereqs
      Ensure-ComputerName -ServerName $TargetName
      Enable-RemoteDesktop

      if ($script:RebootRequired) {
        Finish-Script
        return
      }

      # ---------- STAGE 1: networking / RDMA ----------
      Cisco-UpLinkTeam -FabricVLAN $FabricVLAN -FabricPrefixLength $FabricPrefixLength -FabricGateway $FabricGateway -FabricDNS $FabricDNS -FabricIP $FabricIP

      Mellanox-UpLinks -RDMAVlan $RDMAVlan -RDMA1IP $RDMA1IP -RDMA2IP $RDMA2IP -RDMAPrefixLength $RDMAPrefixLength

      Invoke-AutoPerfTune
	  
	  # ---------- STAGE 2: optional domain join ----------
      if ($config.Environment.Domain -and $config.Environment.Domain.Name) {
        Ensure-DomainJoinInteractive -DomainName $config.Environment.Domain.Name -OUPath $config.Environment.Domain.OUPath
        if ($script:RebootRequired) { Finish-Script; return }
      }

      Finish-Script
      return
    }
  }
}
catch {
  Write-Host "`n=== EXCEPTION ===" -ForegroundColor Red
  Write-Host ("Type    : {0}" -f $_.Exception.GetType().FullName) -ForegroundColor Yellow
  Write-Host ("Message : {0}" -f $_.Exception.Message) -ForegroundColor Yellow

  if ($_.InvocationInfo) {
    Write-Host "`n=== INVOCATION ===" -ForegroundColor Yellow
    Write-Host ("Script  : {0}:{1}" -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Yellow
    Write-Host ("Line    : {0}" -f $_.InvocationInfo.Line.Trim()) -ForegroundColor Yellow
  }

  Write-Host "`n=== ScriptStackTrace ===" -ForegroundColor Yellow
  Write-Host $_.ScriptStackTrace -ForegroundColor Yellow

  Finish-Script
  throw
}