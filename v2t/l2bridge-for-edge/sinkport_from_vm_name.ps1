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


#### Allow Forged transmits
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




##### Sinkport settings
$fetch_uri = "https://$VC/mob/?moid=DVSManager&method=fetchOpaqueDataEx&vmodl=1"
$update_uri = "https://$VC/mob/?moid=DVSManager&method=updateOpaqueDataEx&vmodl=1"

$secpasswd = ConvertTo-SecureString $VC_PASSWORD -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($VC_USERNAME, $secpasswd)

##### Ignore warning messages related to SSL certificate error
add-type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
public bool CheckValidationResult(
ServicePoint srvPoint, X509Certificate certificate,
WebRequest request, int certificateProblem) {
return true;
}
}
"@

[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

$results = Invoke-WebRequest -Uri $fetch_uri -SessionVariable vmware -Credential $credential -Method GET


if($results.StatusCode -eq 200) {
$null = $results -match 'name="vmware-session-nonce" type="hidden" value="?([^\s^"]+)"'
$sessionnonce = $matches[1]
} else {
$results
Write-host "Failed to login to vSphere MOB"
exit 1
}

$vds_uuid = Get-VDSwitch -Name $VDSNAME | select-object -ExpandProperty Key

Add-Type -AssemblyName System.Web

$sectionSet = [System.Web.HttpUtility]::UrlEncode('
<selectionSet xsi:type="DVPortSelection">
<dvsUuid>' + $vds_uuid + '</dvsUuid>
<portKey>' + $PORTID + '</portKey>
</selectionSet>')


$fetch_body = @"
vmware-session-nonce=$sessionnonce&selectionSet=$sectionSet&isRuntime=false
"@

$header = @{"Content-Type"="application/x-www-form-urlencoded"}

$fetch_results = Invoke-WebRequest -Uri $fetch_uri -WebSession $vmware -Credential $credential -Method POST -Body $fetch_body -Headers $header
Clear-Variable matches
$null = $fetch_results -match 'com.vmware.etherswitch.port.extraEthFRP.*vmodl.Binary</td><td>.*'

if ($matches){
$param = $Matches[0].Substring( $Matches[0].Length -35,35)
if ($param -eq "00000000 00000000 00000000 00000000"){
$sinkportEnabled = $false
$operation = "edit"
$opaqueDataSpec = [System.Web.HttpUtility]::UrlEncode('
<opaqueDataSpec>
<operation>edit</operation>
<opaqueData>
<key>com.vmware.etherswitch.port.extraEthFRP</key>
<opaqueData xsi:type="vmodl.Binary">AAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=</opaqueData>
</opaqueData>
</opaqueDataSpec>
')
}elseif ($param -eq "00000100 00000000 00000000 00000000"){
$sinkportEnabled = $true
}else{
Write-host "Failed to fetch data"
exit 1
}
}else{
$operation = "add"
$sinkportEnabled = $false
$opaqueDataSpec = [System.Web.HttpUtility]::UrlEncode('
<opaqueDataSpec>
<operation>add</operation>
<opaqueData>
<key>com.vmware.etherswitch.port.extraEthFRP</key>
<opaqueData xsi:type="vmodl.Binary">AAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=</opaqueData>
</opaqueData>
</opaqueDataSpec>
')
}

if ($sinkportEnabled -eq $true){
Write-host "Sinkport is already configured. skip setting."
}else{
$update_body = @"
vmware-session-nonce=$sessionnonce&selectionSet=$sectionSet&opaqueDataSpec=$opaqueDataSpec&isRuntime=false
"@
$update_results = Invoke-WebRequest -Uri $update_uri -WebSession $vmware -Credential $credential -Method POST -Body $update_body -Headers $header
}

##### Display results
$fetch_results = Invoke-WebRequest -Uri $fetch_uri -WebSession $vmware -Credential $credential -Method POST -Body $fetch_body -Headers $header
Clear-Variable matches
$null = $fetch_results -match 'com.vmware.etherswitch.port.extraEthFRP.*vmodl.Binary</td><td>.*'
if ($matches){
$param = $Matches[0].Substring( $Matches[0].Length -35,35)
if ($param -eq "00000000 00000000 00000000 00000000"){
$sinkportEnabled = $false
}elseif ($param -eq "00000100 00000000 00000000 00000000"){
$sinkportEnabled = $true
}else{
Write-host "Failed to fetch data"
exit 1
}
}else{
Write-host "Failed to fetch data"
exit 1
}

$port = Get-VDPort -VDSwitch $VDSNAME -Key $PORTID
$secSettings = $port.ExtensionData.Config.Setting.SecurityPolicy

$results = [pscustomobject] @{
AllowPromiscuous = $secSettings.AllowPromiscuous.Value;
MacChanges = $secSettings.MacChanges.Value;
ForgedTransmits = $secSettings.ForgedTransmits.Value;
SinkportEnabled = $sinkportEnabled
}

$results

##### Logout from vCenter
$mob_logout_url = "https://$VC/mob/logout"
$logout = Invoke-WebRequest -Uri $mob_logout_url -WebSession $vmware -Method GET
Disconnect-VIServer -Server $VC -Confirm:$false