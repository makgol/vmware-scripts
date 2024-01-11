##### Your environment section
$VC = "vcsa.vsphere.local" #vCenter's IP/fqdn
$VC_USERNAME = "administrator@vSphere.local" #vCenter's sso user name
$VC_PASSWORD = "VMware1!" #vCenter's sso password
$VMNAME = "l2bridge-nsxt-edge01" # NSX-T Edge VM name
$PORTGROUP = "vxw-dvs-71-virtualwire-33-sid-5031-migration-net100" #VXLAN port group name
$VDSNAME = "nsx-dvs" #VXLAN VDS name
#####

Connect-VIServer -Server $VC -User $VC_USERNAME -Password $VC_PASSWORD -Force

$dvpg = Get-VDPortgroup -Name $PORTGROUP
foreach ($p in $dvpg.ExtensionData.PortKeys){
$a = Get-VDSwitch | Get-VDPort -Key $p
if ($a.ConnectedEntity.Parent.Name -eq $VMNAME){
$PORTID = $p
break
}
}


#### Allow override settings to VXLAN port group
$policy = $dvpg.ExtensionData.Config.Policy

if ($policy.MacManagementOverrideAllowed -ne $true -or $policy.UplinkTeamingOverrideAllowed -ne $true){
$pgspec = New-Object VMware.Vim.DVPortgroupConfigSpec
$pgspec.ConfigVersion = $dvpg.ExtensionData.Config.ConfigVersion
$pgspec.Policy = New-Object VMware.Vim.VMwareDVSPortgroupPolicy

if ($policy.MacManagementOverrideAllowed -ne $true) {
$pgspec.Policy.MacManagementOverrideAllowed = $true
}
if ($policy.UplinkTeamingOverrideAllowed -ne $true){
$pgspec.Policy.UplinkTeamingOverrideAllowed = $true
}
$pgspec.Policy
$task = $dvpg.ExtensionData.ReconfigureDVPortgroup_Task($pgspec)
$task1 = Get-Task -Id ("Task-$($task.value)")
$task1 | Wait-Task | Out-Null
}else{
Write-Host("Policies already allowed. Skip dpg settings.")
}

#### Allow Mac learning && Forged transmits
$port = Get-VDPort -VDSwitch $VDSNAME -Key $PORTID

$pspec = New-Object VMware.Vim.DVPortConfigSpec
$pspec.Key = $PORTID
$pspec.Operation = "edit"
$pspec.ConfigVersion = $port.ExtensionData.Config.ConfigVersion

$dvPortSetting = New-Object VMware.Vim.VMwareDVSPortSetting
$pspec.Setting = $dvPortSetting

$pspec.Setting.SecurityPolicy = New-Object VMware.Vim.DVSSecurityPolicy
$pspec.Setting.SecurityPolicy.AllowPromiscuous = New-Object VMware.Vim.BoolPolicy
$pspec.Setting.SecurityPolicy.AllowPromiscuous.Inherited = $false
$pspec.Setting.SecurityPolicy.AllowPromiscuous.Value = $false

$pspec.Setting.SecurityPolicy.ForgedTransmits = New-Object VMware.Vim.BoolPolicy
$pspec.Setting.SecurityPolicy.ForgedTransmits.Inherited = $false
$pspec.Setting.SecurityPolicy.ForgedTransmits.Value = $true

$pspec.Setting.SecurityPolicy.MacChanges = New-Object VMware.Vim.BoolPolicy
$pspec.Setting.SecurityPolicy.MacChanges.Inherited = $false
$pspec.Setting.SecurityPolicy.MacChanges.Value = $false

$macManagementPolicy = New-Object VMware.Vim.DVSMacManagementPolicy
$pspec.Setting.MacManagementPolicy = $macManagementPolicy

$macLearningPolicy = New-Object VMware.Vim.DVSMacLearningPolicy
$pspec.Setting.MacManagementPolicy.MacLearningPolicy = $macLearningPolicy

$macManagementPolicy.AllowPromiscuous = $false
$macManagementPolicy.ForgedTransmits = $true
$macManagementPolicy.MacChanges = $false
$macLearningPolicy.Enabled = $true
$macLearningPolicy.AllowUnicastFlooding =$true
$macLearningPolicy.LimitPolicy = "ALLOW"
$macLearningPolicy.Limit =4096

##### Teaming policy settings
$uplinkTeamingPolicy = New-Object VMware.Vim.VmwareUplinkPortTeamingPolicy
$pspec.Setting.UplinkTeamingPolicy = $uplinkTeamingPolicy
$uplinkPortOrder = New-Object VMware.Vim.VMwareUplinkPortOrderPolicy
$pspec.Setting.UplinkTeamingPolicy.UplinkPortOrder = $uplinkPortOrder
$uplinkPortOrder.Inherited = $false
$teamingPolicy = $port.ExtensionData.Config.Setting.UplinkTeamingPolicy.UplinkPortOrder
$uplinkCount = $teamingPolicy.ActiveUplinkPort.Count
$stbCount = $teamingPolicy.StandbyUplinkPort.Count

if ($uplinkCount -gt 1) {
$uplinkPortOrder.ActiveUplinkPort = $teamingPolicy.ActiveUplinkPort[0]
$toStandby = $uplinkCount-1
$standbyArray = $teamingPolicy.ActiveUplinkPort[1..$toStandby]
if ($stbCount -gt 0) {
$standbyArray += $teamingPolicy.StandbyUplinkPort
}
$uplinkPortOrder.StandbyUplinkPort = $standbyArray
}else{
$uplinkPortOrder.ActiveUplinkPort = $teamingPolicy.ActiveUplinkPort
$uplinkPortOrder.StandbyUplinkPort = $teamingPolicy.StandbyUplinkPort
}


##### Applying spec

$vds = Get-VDSwitch -Name $VDSNAME
$task = $vds.ExtensionData.ReconfigureDVPort_Task($pspec)
$task1 = Get-Task -Id ("Task-$($task.value)")
$task1 | Wait-Task | Out-Null


##### Display results
$port = Get-VDPort -VDSwitch $VDSNAME -Key $PORTID
$secSettings = $port.ExtensionData.Config.Setting.SecurityPolicy
$macSettings = $port.ExtensionData.Config.Setting.MacManagementPolicy.MacLearningPolicy
$results = [pscustomobject] @{
LegacyAllowPromiscuous = $secSettings.AllowPromiscuous.Value;
LegacyMacChanges = $secSettings.MacChanges.Value;
LegacyForgedTransmits = $secSettings.ForgedTransmits.Value;
MacLearningEnabled = $macSettings.Enabled;
AllowUnicastFlooding = $macSettings.AllowUnicastFlooding;
Limit = $macSettings.Limit;
LimitPolicy = $macSettings.LimitPolicy;
}


$results

##### Logout from vCenter
Disconnect-VIServer -Server $VC -Confirm:$false