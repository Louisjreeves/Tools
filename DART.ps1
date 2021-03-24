    <#
    .Synopsis
       Get-DellUpdates
    .DESCRIPTION
       This script will install Windows updates and Dell Drivers and Firmware on a single node
    .EXAMPLE
       Install-DellUpdates
    #>
    
Function Invoke-DART {
[CmdletBinding(
    SupportsShouldProcess = $true,
    ConfirmImpact = 'High')]
    param($param)
CLS
# Dell Server Check
IF((Get-WmiObject -Class Win32_ComputerSystem).Manufacturer -imatch "Dell" -and (Get-WmiObject -Class Win32_ComputerSystem).PCSystemType -imatch "4"){
# Fix 8.3 temp paths
    $MyTemp=(Get-Item $env:temp).fullname
$text=@"
v1.0
 __        __  ___ 
|  \  /\  |__)  |  
|__/ /~~\ |  \  |  
                   
       By: Jim Gandy
"@
Write-Host $text
$Title=@()
    Write-host $Title
    Write-host "   Dell eAsy seRver updaTer"
    Write-host "   This tool will automatically download and"
    Write-host "   install Windows Updates, Drivers/Firmware on Dell Servers"
    Write-host " "
if ($PSCmdlet.ShouldProcess($param)) { 

        Function EndScript{  
            break
        }

        Function Download-File{
            Param($URL)
            $DLFileName=$URL.Split('\/')[-1]
            Write-Host "    Downloading $URL..."
            $OutFile=$MyTemp+"\"+$DLFileName
            # Use TLS 1.2
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            # Download file
            Try{Invoke-WebRequest $URL -OutFile $OutFile -UseDefaultCredentials}
            Catch{
                Write-Host "        ERROR: Downloading $URL" -ForegroundColor Red
                EndScript
            }
            Finally{
                IF([System.IO.File]::Exists($OutFile)){
                    Write-Host "        SUCCESS: File downloaded successfully" -ForegroundColor Green
                }
            }
            Return $OutFile
        }

        Function Expand-Gz{
            Param($InFile)
            $outFile = $infile.Substring(0, $infile.LastIndexOfAny('.'))
            $input = New-Object System.IO.FileStream $inFile, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
            $output = New-Object System.IO.FileStream $outFile, ([IO.FileMode]::Create), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
            $gzipStream = New-Object System.IO.Compression.GzipStream $input, ([IO.Compression.CompressionMode]::Decompress)
            $buffer = New-Object byte[](1024)
                While($true){
                    $read = $gzipstream.Read($buffer, 0, 1024)
                    if ($read -le 0){break}
                        $output.Write($buffer, 0, $read)
                }
            $gzipStream.Close()
            $output.Close()
            $input.Close()
        }

        Function Run-ASHCIPre{
            # Check for any outstanding Storage Jobs
            Write-Host "Executing Azure Stack HCI Pre-Checks..."
            Write-Host "    Checking for Running storage jobs..."
            do {
                Start-Sleep 5
            }until(
                # Running Repair Jobs are less than 1
                ((Get-StorageJob | Where-Object {$_.Name -imatch 'Repair' -and $_.JobState -ne 'Completed'}) | Measure-Object).Count -lt 1
            )

            # Suspend Cluster Host to prevent chicken-egg scenario
                Write-Host "    Suspending $env:COMPUTERNAME..."
                Try{
                    Suspend-ClusterNode -Name $env:COMPUTERNAME -Drain -ForceDrain -Wait  -ErrorVariable $ClusPreERR >$null
                }Catch{
                    Write-Host "        ERROR: Failed to suspend cluster node. Exiting..." -ForegroundColor Red
                    EndScript
                }Finally{ 
                    IF((Get-ClusterNode -Name $env:COMPUTERNAME).State -eq "Paused"){
                        Write-Host "        SUCCESS: Cluster node is suspended" -ForegroundColor Green
                    }
                }


            # Enter Storage Maintenance Mode
                Write-Host "    Enabling Storage Maintenance Mode on $env:COMPUTERNAME..."
                try {
                    Get-StorageFaultDomain -type StorageScaleUnit | Where-Object {$_.FriendlyName -eq "$($Env:ComputerName)"} | Enable-StorageMaintenanceMode
                    $Maint="Success"
                }
                catch {
                    $Maint="Failed"
                    Resume-ClusterNode -Name $Env:COMPUTERNAME -Failback
                    Write-Host "        ERROR: Failed to enter storage maintenance mode. Node resumed" -ForegroundColor Red
                    endscript
                }Finally{
                    IF($Maint -eq "Success"){
                        Write-Host "        SUCCESS: Storage Scale Unit entered Storage Maintenance Mode" -ForegroundColor Green
                }
            }
        }

    Function Run-ClusterPre{
        Write-Host "Executing Cluster Pre-Checks..."
        Try{
            # Suspend Cluster Host to prevent chicken-egg scenario
                Write-Host "    Suspending $env:COMPUTERNAME..."
                Suspend-ClusterNode -Name $env:COMPUTERNAME -Drain -ForceDrain -Wait -ErrorVariable $ClusPreERR
        }Catch{
            Write-Host "    ERROR: Failed to suspend cluster node. Exiting..." -ForegroundColor Red
            EndScript
        }Finally{
            IF(-not $ClusPreERR){
                Write-Host "    SUCCESS: Cluster node suspended." -ForegroundColor Green
            }
        }
    }

        Function Run-DSU{
            # CD to DSU dir
                cd 'C:\Program Files\Dell\DELL EMC System Update'
            # Check if HCI and run DSU install needed updates
                IF($ASHCI -eq "YES"){
                    # We create an ans.txt with a and c on seperate lines to answer DSU (a - Select All, c to Commit) and then pipe into dsu.exe the ans.txt when it runs
                        cmd /c "echo a>c:\ans.txt&&echo c>>c:\ans.txt&&DSU.exe --catalog-location=$MyTemp\ASHCI-Catalog.xml <c:\ans.txt&&del c:\ans.txt"
                }Else{
                    # We create an ans.txt with a and c on seperate lines to answer DSU (a - Select All, c to Commit) and then pipe into dsu.exe the ans.txt when it runs
                        cmd /c "echo a>c:\ans.txt&&echo c>>c:\ans.txt&&DSU.exe --apply-upgrades <c:\ans.txt&&del c:\ans.txt"
                }
            # Check Status
                $DupsStatus=Get-Content 'C:\ProgramData\Dell\DELL EMC System Update\dell_dup\DSU_STATUS.json'| ConvertFrom-Json | select -ExpandProperty SystemUpdateStatus 
                Switch($DupsStatus){
                    {$DupsStatus.InvokerInfo.statusMessage -imatch 'No Applicable Update'}{
                        Write-Host "`n`n"
                        Write-Host "Installation Report"
                        "-"*100
                        $DupsStatus.InvokerInfo | FL *
                        }
                    {$DupsStatus.UpdateableComponent}{$DupsStatus = $DupsStatus.UpdateableComponent
                        # Check reboot required
                            Write-Host "`n`n"
                            Write-Host "Installation Report"
                            "-"*100
                            Switch($DupsStatus){
                                {$DupsStatus | Where-Object{$_.updateStatus -ne "SUCCESS"}}
                                    {
                                        $DupsStatus | FL *
                                        Write-Host "ERROR: Some updates failed to install. Please review logs for further information. C:\ProgramData\Dell\UpdatePackage\log" -ForegroundColor Red
                                        EndScript
                                    }
                                {$DupsStatus | Where-Object{$_.rebootRequired -eq "True"}}
                                                                                                                                                                                                                                                                                    {
                            $DupsStatus | FL *
                            Write-Host "Please reboot to complete installation" -ForegroundColor Yellow
                            $Reboot = Read-Host "Ready to reboot? [y/n]"
                            Switch ($Reboot){
                                "y"{
                                    $Script='CLS;Write-Host "Resuming Cluster Node $ENV:COMPUTERNAME...";Resume-ClusterNode -Name $Env:COMPUTERNAME -Failback Immediate -ErrorAction SilentlyContinue;Write-Host "Exiting Storage Maintenance Mode...";Get-StorageFaultDomain -type StorageScaleUnit | Where-Object {$_.FriendlyName -eq "$($Env:ComputerName)"} | Disable-StorageMaintenanceMode -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName "Exit Maintenance Mode" -Confirm:$false;Remove-Item -Path c:\dell\exit-maintenancemode.ps1 -Force;Pause'
                                    IF(-not(Test-Path c:\dell)){
                                        New-Item -Path "c:\" -Name "Dell" -ItemType "directory"
                                    }
                                    $Script | Out-File -FilePath c:\dell\exit-maintenancemode.ps1 -Force
                                    Register-ScheduledTask -TaskName "Exit Maintenance Mode" -Trigger (New-ScheduledTaskTrigger -AtLogon) -Action (New-ScheduledTaskAction -Execute "${Env:WinDir}\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-WindowStyle Hidden -Command `"& 'c:\dell\exit-maintenancemode.ps1'`"") -RunLevel Highest -Force;
                                    Restart-Computer -Force
                                    EndScript
                                    }
                                "n"{
                                    EndScript
                                    }
                            }
                            EndScript
                        }
                                Default{
                                    Write-Host "No reboot required"
                                    $DupsStatus | FL *
                                    EndScript
                                }
                            }
                    }
                }
                IF(($IsClusterMemeber -eq "YES") -or ($ASHCI -eq "YES")){
                    Write-Host "Resuming Cluster Node $ENV:COMPUTERNAME..."
                    Resume-ClusterNode -Name $Env:COMPUTERNAME -Failback Immediate -ErrorAction SilentlyContinue >$null
                }
                IF($ASHCI -eq "YES"){
                    Write-Host "Exiting Storage Maintenance Mode..."
                    Get-StorageFaultDomain -type StorageScaleUnit | Where-Object {$_.FriendlyName -eq "$($Env:ComputerName)"} | Disable-StorageMaintenanceMode -ErrorAction SilentlyContinue
                }
        }
   # Find latest DSU version on dl.dell.com
       Try{
           # Use TLS 1.2
           [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
           Write-Host "Finding Latest Dell EMC System Update(DSU) version..."
           $URL="https://dl.dell.com/omimswac/dsu/"
           $Results=Invoke-WebRequest $URL -UseDefaultCredentials
           $DellDownloadsColumns=@()
           $DellDownloadsColumns=(($Results.ParsedHtml.body.innerhtml -split '<br><br>')[-1] -split '<br>')|Select @{L='Date';E={($_ -split '\s{2}')[0]}},@{L='Time';E={($_ -split '\s{2}')[1]}},@{L='DTNum';E={((($_ -split '\s{5}')[1]) -split '\s\<')[0]}},@{L='Link';E={((($_ -split 'href\=\"')[1]) -split '\"\>')[0]}},@{L='Version';E={$DSUVer=(((($_ -split '\"\>')[1] -split 'WN64')[1]) -replace '\.EXE\<\/A\>',"");($DSUVer -split '_')[1]}}
           $LatestDSULink="https://dl.dell.com"+($DellDownloadsColumns | Sort DTNum -Descending | Select -First 1).link
           $LatestDSUVersion=($DellDownloadsColumns | Sort DTNum -Descending | Select -First 1).version
           Write-Host "    Found:"$LatestDSUVersion -ForegroundColor Green
       }
       Catch{
           Write-Host "    ERROR: Failed to find DSU version. Exiting..." -ForegroundColor Red
           EndScript
       }
   # Check if DSU is already installed
        Write-Host "Checking if DSU is installed..."
        Set-Location 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        $RegKeyPaths=Get-ChildItem | Select PSPath -ErrorAction SilentlyContinue 
        ForEach($Key in $RegKeyPaths){
            IF(Get-ItemProperty -Path $Key.PSPath | ?{$_.DisplayName -imatch 'DELL EMC System Update'}){
                IF(Get-ItemProperty -Path $Key.PSPath | ?{[version]$_.DisplayVersion -ge [version]$LatestDSUVersion}){
                    Write-Host "    FOUND: DSU already installed" -ForegroundColor Green
                    $IsDSUInstalled="YES"
                    Set-Location c:\
                }
            }
        }
        IF(-not ($IsDSUInstalled -eq "YES")){
            Write-Host "Downloading Dell EMC System Update(DSU)..."
            $DSUInstallerLocation=Download-File $LatestDSULink
            Write-Host "Installing DSU..."
            Start-Process $DSUInstallerLocation -ArgumentList '/s' -NoNewWindow -Wait
            $DSUInstallStatus=$DSUInstallerLocation.Split('\\')[-1] -replace ".exe",""
            IF(((Get-Content "C:\ProgramData\Dell\UpdatePackage\log\$DSUInstallStatus.txt" | select-string -Pattern 'Exit code ' -SimpleMatch | Select-Object -Last 1) -split "= ")[-1] -eq 1){
                Write-Host "    ERROR: Failed to install DSU." -ForegroundColor Red
                EndScript
            }Else{Write-Host "    SUCCESS: DSU Installed Successfully." -ForegroundColor Green }
        }
        Write-Host "Gather Server Model Info..."
        # Find Storage Spaces Direct RN or AX info
            $Model=(Get-WmiObject -Class Win32_ComputerSystem).model
            IF($Model -imatch 'Storage Spaces Direct' -or $Model -imatch 'AX'){
                $ASHCI="YES"
                $URL="https://dl.dell.com/catalog/ASHCI-Catalog.xml.gz"
                $InFile="$MyTemp\ASHCI-Catalog.xml.gz"
            }Else{
                $ASHCI="NO"
                # Check if node is a Cluster memeber
                IF(Get-Service clussvc -ErrorAction SilentlyContinue){$IsClusterMember = "YES"}Else{$IsClusterMember = "NO"}
                $URL="https://dl.dell.com/catalog/Catalog.xml.gz"
                $InFile="$MyTemp\Catalog.xml.gz"
            }
        Write-Host "    SUCCESS: $Model" -ForegroundColor Green
        IF($ASHCI -eq "YES"){
            Write-Host "Downloading Catalog..."
            $CatalogLocation=Download-File $URL
            Write-Host "Expanding Catalog for use..."
            Try{Expand-Gz $InFile}
            Catch{Write-Host "    ERROR: Failed to expand catalog" -ForegroundColor Red}
            Finally{
                IF([System.IO.File]::Exists(($InFile -replace ".gz",""))){
                    Write-Host "    SUCCESS: Catalog expanded" -ForegroundColor Green
                }
            }
            Run-ASHCIPre
        }
        If($IsClusterMember -eq "YES"){
            Run-ClusterPre
        }
        # Check if Windows
        IF([System.Environment]::OSVersion.VersionString -imatch 'Windows'){
            Write-Host "Executing Windows Updates..."
            Start-Process -FilePath "$env:comspec" -ArgumentList "/c echo A>c:\ans.txt&&echo A>>c:\ans.txt&&cscript C:\Windows\System32\en-US\WUA_SearchDownloadInstall.vbs <c:\ans.txt&&del c:\ans.txt"
        }        
        Write-Host "Executing DSU..."
        Run-DSU
    }
}Else{Write-Host "ERROR: Non-Dell Server Detected!" -ForegroundColor Red}
}               
                