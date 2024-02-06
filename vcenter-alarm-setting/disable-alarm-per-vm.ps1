##### Your environment section
$vcsa = "vcsa.vsphere.local" #vCenter's IP/fqdn
$vcsaUser = "administrator@vsphere.local" # vCenter's sso user name
$vcsaPassword = "VMware1!" # vCenter's sso password
$vmNames = @('Virtual machine 1', 'Virtual machine 2') # Target VM Name
$alarmName = 'Virtual machine CPU usage' # Target Alarm Name
#####

Connect-VIServer -Server $vcsa -User $vcsaUser -Password $vcsaPassword -Force

# Definition of object for alarm ID search and setting modification
$alarmId = (Get-AlarmDefinition -Name $alarmName).Id
$alarm = New-Object VMware.Vim.ManagedObjectReference
$alarm.Type = 'Alarm'
$alarm.Value = $alarmId -replace '^Alarm-', ''

foreach ($vmName in $vmNames) {
    # Retrieve VM ID
    $vmId = (Get-VM -Name $vmName).Id -replace '^VirtualMachine-', ''
    # Definition of object for alarm setting modification
    $entity = New-Object VMware.Vim.ManagedObjectReference
    $entity.Type = 'VirtualMachine'
    $entity.Value = $vmId
    # Execute alarm deactivation
    $_this = Get-View -Id 'AlarmManager-AlarmManager'
    $_this.DisableAlarm($alarm, $entity)
    # Output VM settings (OK if Disabled is True)
    (get-vm -Name $vmName).ExtensionData.DeclaredAlarmState | Where-Object { $_.Alarm -eq $alarmId }
}

Disconnect-VIServer -Server $vcsa -Confirm:$false