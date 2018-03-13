##########################################################################
# Purpose : This script can only add additional volumes to a profile 
#           that already contains an existing volume
##########################################################################

param(
    [Parameter(Mandatory = $true, HelpMessage = "-ApplianceIP 'IP or FQDN'")]
    $ApplianceIP,
    [Parameter(Mandatory = $true, HelpMessage = "-datafile '.\datafile.csv'")]
	$datafile    
)

$global:StartupVars = [System.Collections.ArrayList]@()
$global:StartupVars = Get-Variable | Select-Object -ExpandProperty Name

# Import PowerShell module
if (-not (get-module HPOneview.400)) 
{
    Import-Module HPOneView.400
}

# Parse the datafile
$csv_file = Import-Csv $datafile

$global:out_file = ".\send_profile.json" 

# Hashtables
$global:volumes = @{}
$global:prof_volumes = @{}

$global:volumeid = [int]0

# Support for multiple profiles
$global:profiles = [System.Collections.ArrayList]@()
$global:volumesNotAdded = [System.Collections.ArrayList]@()
$global:volumeids = [System.Collections.ArrayList]@()
$global:san_conn_ids = [System.Collections.ArrayList]@()
$global:attachments = [System.Collections.ArrayList]@()
$global:storagePaths = [System.Collections.ArrayList]@()

function initialize()
{ 
    Write-Output "Start of log" | Out-file -FilePath $global:out_file
    Get-Date | Out-file -Append -FilePath $global:out_file

    # Find out how many unique profiles will need to be updated
    $global:profiles = $csv_file.profile | Where-Object {$_ -ne "" } | Get-Unique

    Write-Host "Number of profiles to be edited : " $global:profiles.count
    $value = $global:profiles.count
    Write-Output "Number of profiles to be edited :  ${value}" | Out-file -Append -FilePath $global:out_file

    foreach($profile in $global:profiles)
    {
        $rows = $csv_file.profile -eq $profile  | Measure-Object 
        $global:prof_volumes.Add($profile, $rows.Count)
    }

    foreach($id in $global:prof_volumes.Keys)
    {
        Write-Host "Server profile : " $id " will add " $global:prof_volumes[$id] " Volumes"                
        $value = $global:prof_volumes[$id]
        Write-Output "Server profile :  ${id}  will add  ${value}  Volumes" | Out-file -Append -FilePath $global:out_file
    }

    Write-Host
}

function set-storagePaths()
{
    # reset the storagepaths
    $global:storagePaths = [System.Collections.ArrayList]@()

    foreach($id in $global:san_conn_ids)
    {
        $storagePath = @{
                targetSelector = "Auto";        
                connectionId = $id;
                isEnabled = $true
        }
        $global:storagePaths.Add($storagePath)
    }
}

function add_storage_volumes([string]$storage_system, [string]$storage_pool, [string]$volume_name, [string]$volume_size, [int]$lunid)
{
    
    $vol_name = Get-HPOVStorageVolume -name $volume_name -ErrorAction:SilentlyContinue
    if($vol_name)
    {
        # Volume is created or now exists we retrieve the URI for the volume        
        $global:volumes.Add($volume_name, $vol_name.uri)
        Write-Host "${volume_name} exists ..."
        Write-Output "${volume_name} exists ..." | Out-file -Append -FilePath $global:out_file
    }
    else
    {
        Get-HPOVStoragePool -NAme $storage_pool -StorageSystem $storage_system | New-HPOVStorageVolume -name $volume_name -Size $volume_size -Shared | Wait-HPOVTaskComplete
        Write-Host "Create volume : " $volume_name " with LUN id ${lunid} ..."
        Write-Output "Create volume : ${volume_name} with LUN id ${lunid} ..." | Out-file -Append -FilePath $global:out_file
    }

    $vol_name = Get-HPOVStorageVolume -name $volume_name -ErrorAction:SilentlyContinue

    if($vol_name -eq $null)
    {
        Write-Output "ERROR : Volume with LUN ID : ${lunid} named  ${volume_name} NOT found : #### " | Out-file -Append -FilePath $global:out_file
        $global:volumesNotAdded.Add($volume_name)
        Write-Output $global:volumesNotAdded | Out-file -Append -FilePath $global:out_file
        return 
    }
    else
    {
            $attachment = @{
            id = $global:volumeid;
            lunType = "Manual";
            volumeUri = $vol_name.uri;
            lun = $lunid;      
            storagePaths = $global:storagePaths;
            isBootVolume = $false
        }
        $global:attachments.Add($attachment)   
        $global:volumeid++
    }
}

function Get-SanConnection-IdS([object]$spile)
{
    # Reset the san_conn_ids array
    $global:san_conn_ids = [System.Collections.ArrayList]@()

    foreach($connection in $spile.connectionSettings.connections)
    {
        if ($connection.functionType -eq "FibreChannel" )
        {
            $san_conn_id = $connection.id
            $global:san_conn_ids.add($san_conn_id)            
        }        
    }    
}

function attach_volumes_to_profile([string]$spile_name)
{
    # Get the profile associated
    $sp = Get-HPOVProfile -name $spile_name

    $cnt = $sp.sanStorage.volumeAttachments.Count

    if ($cnt -lt 1)
    {
        Write-Host "Profile " $spile_name " does not contain any volumes"
        Write-Output "Profile ${spile_name} does not contain any volumes" | Out-file -Append -FilePath $global:out_file
        return -1
    }

    # Obtain hostOSType
    $host_type = $sp.sanStorage.hostOSType
    
    #find out the connection ids for sanA and sanB
    Get-SanConnection-Ids $sp
    Write-Host "Fibre Channel connections within the profile : " $global:san_conn_ids.Count
    Write-Output "Fibre Channel connections within the profile : $(${global:san_conn_ids}.Count)" | Out-file -Append -FilePath $global:out_file

    if($global:san_conn_ids.Count -lt 1)
    {
        Write-Host "Profile " $spile_name " does not have any FibreChannel connections"
        Write-Output "Profile ${spile_name} does not have any FibreChannel connections" | Out-file -Append -FilePath $global:out_file
        return -2
    }

    # Build the json to contain storage paths    
    set-storagepaths 

    # Reset the attachments object
    $global:attachments = [System.Collections.ArrayList]@()

    #reset the volumeids object
    $global:volumeids = [System.Collections.ArrayList]@()
    $global:volumeid = 0

    # Add existing volumes to the attachments object
    foreach($volume in $sp.sanStorage.volumeAttachments){
        $global:attachments.Add($volume)
        $global:volumeids.Add($volume.id)
    }

    $global:volumeid = $global:volumeids | Sort-Object -Descending | Select-Object -First 1
    $global:volumeid++
    
    # Create volumes if volumes do not exist
    $cnt = [int]0

    $rows = $csv_file | Where-Object { $_.profile -eq $spile_name }
    $global:volumesNotAdded = [System.Collections.ArrayList]@()

    foreach($row in $rows)
    {
        if($row.profile -eq $spile_name)
        {  
            $storage_system = $($row.storage_system)
            $storage_pool = $row.storage_pool
            $volume_name = $row.volume_name
            $volume_size = $row.volume_size
            $lun_no = $row.LUN_ID

            add_storage_volumes $storage_system $storage_pool $volume_name $volume_size $lun_no

            $noVolumes = $global:volumesNotAdded.count
            Write-Output "Volumes not added count : ${noVolumes}" | Out-file -Append -FilePath $global:out_file                   

            if($noVolumes -gt 0)
            {
                # Give the index a breather
                Write-Host "Trying to add ${volume_name} again "
                Write-Output "Trying to add ${volume_name} again " | Out-file -Append -FilePath $global:out_file

                Start-Sleep 15

                $global:volumesNotAdded.Remove($volume_name)
                add_storage_volumes $storage_system $storage_pool $volume_name $volume_size $lun_no

                $vol_name = Get-HPOVStorageVolume -name $volume_name -ErrorAction:SilentlyContinue

                if ($vol_name -eq $null)                
                {
                    Write-Host "ERROR : Could not find ${volume_name} after a retry -- Will try again"                    
                    Write-Output "ERROR : Could not find ${volume_name} after a retry -- Will try again" | Out-file -Append -FilePath $global:out_file
                    Start-Sleep 25         

                    $global:volumesNotAdded.Remove($volume_name)
                    add_storage_volumes $storage_system $storage_pool $volume_name $volume_size $lun_no

                    $vol_name = Get-HPOVStorageVolume -name $volume_name -ErrorAction:SilentlyContinue
                    if ($vol_name -eq $null)                
                    {
                        Write-Host "ERROR : Could not find ${volume_name} after a retry -- ABORTING to attach volume"                    
                        Write-Output "ERROR : Could not find ${volume_name} after a retry -- ABORTING to attach volume" | Out-file -Append -FilePath $global:out_file
                        $cnt--
                        continue
                    }
                }
            }            
            $cnt++
        }
        elseif($row -eq "")
        {
            continue
        }
    }

    # Validate if the number of attachment objects are accurate
    if($cnt -eq $global:prof_volumes[$spile_name])
    {
        Write-Host "Attachment objects " $cnt "Created for profile : " $spile_name
        Write-Output "Attachment objects ${cnt} Created for profile :  ${spile_name} " | Out-file -Append -FilePath $global:out_file
    }
    else {
        Write-Host "ERROR: Attachment objects " $cnt "Created for profile : " $spile_name
        Write-Output "ERROR: Reduced number of attachment objects ${cnt} Created for profile :  ${spile_name}" | Out-file -Append -FilePath $global:out_file
    }

    Start-Sleep -Seconds 20
    
    $sanStorage = @{
        volumeAttachments = $global:attachments
        manageSanStorage = $true   
        hostOSType = $host_type
    }

    $send_profile = @{
        type = $sp.type;
        uri = $sp.uri;
        name = $sp.name;
        description = $sp.description;
        serialNumber = $sp.serialNumber;
        uuid = $sp.uuid
        iscsiInitiatorName = $sp.iscsiInitiatorName;
        iscsiInitiatorNameType = $sp.iscsiInitiatorNameType;
        serverProfileTemplateUri = $sp.serverProfileTemplateUri;
        templateCompliance = $sp.templateCompliance;
        serverHardwareUri = $sp.serverHardwareUri;
        serverHardwareTypeUri = $sp.serverHardwareTypeUri;
        enclosureGroupUri = $sp.enclosureGroupUri;
        enclosureUri = $sp.enclosureUri;
        enclosureBay = $sp.enclosureBay;
        affinity = $sp.affinity;
        associatedServer = $sp.associatedServer;
        hideUnusedFlexNics = $sp.hideUnusedFlexNics;
        firmware = $sp.firmware;
        macType =$sp.macType;
        wwnType = $sp.wwnType;
        serialNumberType = $sp.serialNumberType;
        connectionSettings = $sp.connectionSettings;
        bootMode = $sp.bootMode;
        boot = $sp.boot;
        bios = $sp.bios;
        localStorage = $sp.localStorage;
        sanStorage = $sanStorage;
        osDeploymentSettings = $sp.osDeploymentSettings;
        scopesUri = $sp.scopesUri ;
        eTag = $sp.eTag    
    }
        
    $send_profile | ConvertTo-Json -Depth 99 | Out-file -Append -FilePath $global:out_file

    ## Send the payload to edit an existing profile
    Write-Host "Initiating Edit of Server Profile " $sp.name " to attach volumes ..."
    Write-Output "Initiating Edit of Server Profile ${spile_name}  to attach volumes ..." | Out-file -Append -FilePath $global:out_file
    $task = Send-HPOVRequest -uri $sp.uri -body $send_profile -method PUT
    
    Start-Sleep 10    

    $task | Wait-HPOVTaskComplete

    # Added this line for identifying the error
    Write-Output "Task status - Before" | Out-file -Append -FilePath $global:out_file
    $task | ConvertTo-Json -Depth 99 | Out-file -Append -FilePath $global:out_file

    Write-Host "Task URI : ${task.uri}"
    $uri = $task.uri
    Write-Output "Task URI :  ${uri}"  | Out-file -Append -FilePath $global:out_file
    
    $resp = Send-HPOVRequest -uri $task.uri -method Get

    Write-Output "Task response status - After" | Out-file -Append -FilePath $global:out_file
    $resp | ConvertTo-Json -Depth 99 | Out-file -Append -FilePath $global:out_file

    Write-Host "Task state  : " $resp.taskState
    $taskState = $resp.taskState
    Write-Output "Task state  : ${taskState}" | Out-file -Append -FilePath $global:out_file

    if($taskState -eq "Error")
    {
        Write-Host "ERROR message : " $resp.taskErrors.message
        $resp.taskErrors.message | Out-file -Append -FilePath $global:out_file
        Write-Host "ERROR action  : " $resp.taskErrors.recommendedActions
        $resp.taskErrors.recommendedActions | Out-file -Append -FilePath $global:out_file
    }

    Write-Host "Task status : " $resp.taskStatus
    $taskStatus = $resp.taskStatus
    Write-Output "Task status :  ${taskStatus}" | Out-file -Append -FilePath $global:out_file
}

##################### Main Program ####################################

# Connect to OV
if (-not $ConnectedSessions) 
{
    # Uncomment these lines	
	$UserName  = Read-Host 'Appliance Username '
	$Password  = Read-Host 'Appliance Password ' -AsSecureString

    Connect-HPOVMgmt -Hostname $ApplianceIP -Username $UserName -Password $Password    
    
    if (-not $ConnectedSessions)
    {
        Write-Host "Login to Synergy Appliance failed.  Exiting."
        Write-Output "Login to Synergy Appliance failed.  Exiting." | Out-file -Append $global:out_file
        Exit
    } 
    else {
        Import-HPOVSslCertificate
    }
}

#init
Write-Host "Initialize ..."
initialize

# attach
foreach($profile in $global:profiles)
{
    attach_volumes_to_profile $profile
}

Write-Host "Script complete ..."
Write-Output "Script complete ..." | Out-file -Append -FilePath $global:out_file

Disconnect-HPOVMgmt 

# Remove all variables
$UserVars = Get-Variable -Exclude $global:StartupVars -Scope Global

foreach($var in $UserVars)
{
    Remove-Variable -Name $var.Name -Force -Scope Global -ErrorAction SilentlyContinue
}