
![PowerShell](https://img.shields.io/badge/PowerShell-Automation-blue)
![Windows Server](https://img.shields.io/badge/Windows%20Server-2025-green)
![S2D](https://img.shields.io/badge/Storage%20Spaces%20Direct-Toolkit-orange)
# S2D Strict Bundle Toolkit for Windows Server

PowerShell toolkit for preparing Windows Server 2025 Hyper-V hosts for a specific S2D network design using a strict and repeatable configuration model.

Designed for Windows Server 2025 Hyper-V infrastructures where consistency, automation, and validation are critical for reliable S2D cluster deployments.

---

## Overview

Deploying Storage Spaces Direct clusters across multiple hosts can be complex and error-prone.  
Small inconsistencies in networking, RDMA configuration, firmware, or host settings often lead to difficult troubleshooting later.

The **S2D Strict Bundle Toolkit** was created to simplify and standardize this process by providing a repeatable configuration framework.

The toolkit focuses on:

- deterministic configuration
- infrastructure validation
- repeatable cluster preparation
- operational verification

This ensures every host is prepared identically before cluster creation.

---

## Key Features

- Automated Hyper-V host preparation
- Network configuration for S2D fabrics
- RDMA capability validation
- Read-only host preflight (features, adapter counts, time zone, switch presence, RDMA inventory)
- Existing SET switch topology checks before fabric changes
- Repeatable deployment model

The script does not run `Test-Cluster` or verify live SMB Multichannel, firmware symmetry, or S2D cluster health. Perform those checks separately before production use.

---

## Target Environment

The toolkit is designed for environments using:

- Windows Server 2025
- Hyper-V clusters
- Storage Spaces Direct
- Mellanox/NVIDIA ConnectX-6 Lx RDMA networking (RoCEv2)
- NVMe / SSD storage tiers
- Enterprise datacenter networking

The current manual adapter discovery expects exactly two active 10 GbE fabric ports and two active 25 GbE RDMA ports. Validate NIC descriptions, port order, and RSS/NUMA settings on the first Gen12 host before applying the configuration.

---

## Typical Use Case

A common workflow looks like this:

1. Prepare multiple Hyper-V hosts
2. Configure RDMA networking
3. Validate NIC and storage configuration
4. Ensure cluster prerequisites are satisfied
5. Deploy the S2D cluster

The toolkit ensures every node receives identical configuration before cluster deployment.

---

## Requirements

Minimum requirements:

- Windows Server 2025 (target platform)
- Administrator privileges
- PowerShell 5.1 or later
- Supported RDMA-capable network adapters
- Compatible firmware and drivers

Recommended:

- Mellanox / NVIDIA RDMA adapters
- Dedicated storage network
- Consistent BIOS and firmware configuration across nodes

---

## Usage

Clone the repository:

```powershell
git clone https://github.com/clab790/s2d-strictbundle-toolkit.git
cd s2d-strictbundle-toolkit
```


## What this gives you
- Strict JSON schema validation + autocomplete in VS Code
- A template JSON to copy for each environment
- An example JSON
- VS Code workspace settings to automatically bind schema to JSON files

## Folder layout
- `S2D-FabricConfig.schema.json`  -> strict schema (no unknown keys allowed)
- `S2D-FabricConfig.template.json` -> copy this to `S2D-FabricConfig.json` and fill in
- `Examples/S2D-FabricConfig.example.json` -> schema-valid example with documentation-only addresses
- `.vscode/settings.json` -> auto schema mapping

## Usage (team workflow)
1. Copy this whole folder to your environment-specific working directory.
2. Copy `S2D-FabricConfig.template.json` to `S2D-FabricConfig.json`.
3. Replace every documentation-only IP address and serial with actual environment values.
4. Validate: VS Code will underline issues immediately.
5. Run the PowerShell script with `-ConfigPath .\S2D-FabricConfig.json` and mode of choice.

## Example
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\S2D-FabricConfig_v1.0.40.ps1 -ConfigPath .\S2D-FabricConfig.json -Mode Preflight
powershell.exe -ExecutionPolicy Bypass -File .\S2D-FabricConfig_v1.0.40.ps1 -ConfigPath .\S2D-FabricConfig.json -Mode All
```


## Extra hard validation you should also enforce in PowerShell
JSON Schema is great for structure and types, but for cross-field rules enforce in `Test-Config` too:

```powershell
Require ($s.RDMA1IP -ne $s.RDMA2IP) "Servers['$serial'] RDMA1IP and RDMA2IP must be different."
Require ($s.FabricIP -ne $s.RDMA1IP) "Servers['$serial'] FabricIP must differ from RDMA1IP."
Require ($s.FabricIP -ne $s.RDMA2IP) "Servers['$serial'] FabricIP must differ from RDMA2IP."
```

## Notes
- If `Domain` exists, both `Name` and `OUPath` are required.
- The `DC=` labels in `OUPath` must match `Domain.Name` (case-insensitive).
- `Environment.TimeZoneId` is optional; the default is `W. Europe Standard Time`.
- An existing `Fabric_Uplink` must be an external SET with the expected uplinks and HyperVPort; mismatches stop the Cisco stage.
- `Preflight` currently checks switch presence only; the Cisco stage performs the detailed SET check.
- `FabricDNS` must contain unique IPv4 entries.
- Server names and Fabric/RDMA IPs must be unique across all configured nodes.
- Server serial keys must match: `^[A-Za-z0-9-]{3,32}$`.
- NetBIOS name must be `^[A-Za-z0-9-]{1,15}$`.
