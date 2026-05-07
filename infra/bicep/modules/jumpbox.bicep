// Windows jumpbox VM for operator access over Azure Bastion (RDP).
// - No public IP.
// - UAMI attached with AcrPush/AcrPull and Contributor (scoped RG) so scripts
//   1-3 can run end-to-end from inside the VNet.
// - PowerShell post-deploy script installs: Azure CLI, Git, Bicep, and Docker
//   (Docker EE on Windows Server) so the operator can run scripts 2 and 3
//   directly from the jumpbox. Image build and push from the jumpbox uses
//   `az acr build` by default (no local Docker required) — Docker is installed
//   only as a convenience for ad-hoc work.

@description('Location for the VM')
param location string = resourceGroup().location

@description('VM name')
param name string

@description('Subnet id for the VM NIC')
param subnetId string

@description('VM size. Default sized for az cli + dev tooling.')
param vmSize string = 'Standard_D2s_v5'

@description('Admin username for RDP (accessed via Bastion)')
param adminUsername string = 'azureuser'

@description('Admin password used to log in (via Bastion RDP). Must satisfy Azure Windows VM password complexity rules.')
@secure()
param adminPassword string

@description('User-assigned managed identity resource id to attach to the VM')
param userAssignedIdentityId string

@description('Tags for resources')
param tags object = {}

// PowerShell that installs operator tooling on first boot.
// Runs as SYSTEM via the CustomScriptExtension, so it installs machine-wide.
var bootstrapScript = '''
$ErrorActionPreference = "Continue"
$ProgressPreference     = "SilentlyContinue"
Start-Transcript -Path "C:\\Windows\\Temp\\jumpbox-bootstrap.log" -Append

# Trust PSGallery + ensure TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1) Install Chocolatey (used to install az cli, git, bicep)
if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
  Set-ExecutionPolicy Bypass -Scope Process -Force
  iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

$env:Path = "$env:Path;C:\\ProgramData\\chocolatey\\bin"

# 2) Operator tools
choco install -y --no-progress azure-cli
choco install -y --no-progress git
choco install -y --no-progress bicep
choco install -y --no-progress microsoft-edge

# 3) Docker EE on Windows Server (best-effort; safe to fail — `az acr build`
#    is the recommended path for image builds from the jumpbox).
try {
  Install-WindowsFeature -Name Containers -IncludeManagementTools -ErrorAction SilentlyContinue
  Install-Module -Name DockerMsftProvider -Repository PSGallery -Force -ErrorAction SilentlyContinue
  Install-Package -Name docker -ProviderName DockerMsftProvider -Force -ErrorAction SilentlyContinue
} catch {
  Write-Host "Docker install skipped: $_"
}

# 4) Clone the sample repo to the operator desktop for convenience
$repoDir = "C:\\Users\\Public\\Desktop\\Agentic-AI-Investment-Analysis-Sample"
if (-not (Test-Path $repoDir)) {
  & "C:\\Program Files\\Git\\bin\\git.exe" clone https://github.com/Azure-Samples/Agentic-AI-Investment-Analysis-Sample.git $repoDir 2>&1 | Out-Null
}

Stop-Transcript
'''

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${name}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    osProfile: {
      computerName: take(replace(name, '-', ''), 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
  }
}

// Run the operator-tooling bootstrap script on first boot.
resource bootstrap 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'bootstrap'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      // CustomScriptExtension (Windows) decodes `script` (base64 UTF-8),
      // saves it to disk and runs it with PowerShell.
      script: base64(bootstrapScript)
    }
  }
}

output vmId string = vm.id
output vmName string = vm.name
output nicPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
