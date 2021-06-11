<#
 
Kind of simplfied version of the excellent https://github.com/MSEndpointMgr/ModernDriverManagement
 
Removed all functions and compiled into one script without functions in the hope it reads better and can help with future troubleshooting
There isn't much error checking, but the whole script is designed within a Try, Catch and Finally to assist with error handling

The script works with the following workflow

1. Sets up variables and environmental components
2. Gets computer details (Manufacturer, Model etc.)
3. Connects to ConfigMgr to retreive all packages which start with a specific string
4. Matches driver package to computer details
5. Downloads the driver package
6. Unzipps and then installs the drivers
 
#>

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Start of Try process
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Try{

    $LogTitleName = "DriverAction-InstallScript" # Use to easily identify write-hosts actions in smsts.log

    $CurrentScriptPosition = "Section: Begin" # Used for error message information if required

    Write-Host "$LogTitleName -  "
    Write-Host "$LogTitleName -  **************************************************************************************************************"
    Write-Host "$LogTitleName -  **************************************************************************************************************"
    Write-Host "$LogTitleName -   "
    Write-Host "$LogTitleName -  *************************      START OF $LogTitleName      **************************************"
    Write-Host "$LogTitleName -   "
    Write-Host "$LogTitleName -  **************************************************************************************************************"
    Write-Host "$LogTitleName -  **************************************************************************************************************"
    Write-Host "$LogTitleName -   "


    #================================================================================================================
    # 1. Set up variables and environmental components
    #================================================================================================================

    $ErrorExitCode = $false # Used within the finally section to determine on how to exit the script

    $CurrentScriptPosition = "Section: 1. Set up variables and environmental components" # Used for error message information if required

    #----------------------------------------------------------------------------------------------------------------
    #  Load Microsoft.SMS.TSEnvironment
    #----------------------------------------------------------------------------------------------------------------
    $DebugMode = $false # Used to bypass SMS.TSEnvironment if running outwith Task Sequence for testing purposes
    If(-not($DebugMode)){ 
        Write-Host "$LogTitleName -  Loading Microsoft.SMS.TSEnvironment"
        $TSEnvironment = New-Object -ComObject "Microsoft.SMS.TSEnvironment" -ErrorAction Stop
        If($TSEnvironment.Value("_SMSTSType")){Write-Host "$LogTitleName -  Microsoft.SMS.TSEnvironment loaded"}
        else {Throw "Could not load Microsoft.SMS.TSEnvironment"}
    }Else{Write-Host "$LogTitleName -  Bypassing loading of Microsoft.SMS.TSEnvironment"}


    #----------------------------------------------------------------------------------------------------------------
    # Enable TLS 1.2
    #----------------------------------------------------------------------------------------------------------------
    Write-Host "$LogTitleName -  Enable TLS 1.2 for Invoke-RestMethod"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    

    #----------------------------------------------------------------------------------------------------------------
    # Attempt to ignore self-signed certificate binding for AdminService
    #----------------------------------------------------------------------------------------------------------------
    Write-Host "$LogTitleName -  Setting up script to ignore self-signed certificate binding for AdminService"  
    if (-not ([System.Management.Automation.PSTypeName]'ServerCertificateValidationCallback').Type) {

        $CertificationValidationCallback= @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class ServerCertificateValidationCallback
{
    public static void Ignore()
    {
        if(ServicePointManager.ServerCertificateValidationCallback ==null)
        {
            ServicePointManager.ServerCertificateValidationCallback += 
                delegate
                (
                    Object obj, 
                    X509Certificate certificate, 
                    X509Chain chain, 
                    SslPolicyErrors errors
                )
                {
                    return true;
                };
        }
    }
}
"@
    }

    # Load required type definition to be able to ignore self-signed certificate to circumvent issues with AdminService running with ConfigMgr self-signed certificate binding
    Add-Type -TypeDefinition $CertificationValidationCallback
    [ServerCertificateValidationCallback]::Ignore()


    #----------------------------------------------------------------------------------------------------------------
    # Intialise variables
    #----------------------------------------------------------------------------------------------------------------
    Write-Host "$LogTitleName -  Intialising script varibles"

    $CMServer = $TSEnvironment.Value("DRV_CMServer")
    $DriverFilter = $TSEnvironment.Value("DRV_DriverFilter")
    $UserName = $TSEnvironment.Value("DRV_UserName")
    $UserPassword = $TSEnvironment.Value("DRV_UserPassword")
    $DriverPackageZipFileName = $TSEnvironment.Value("DRV_DriverPackageZipFileName")

    #Setting up credentials for connecting to admin service
    $UserPasswordSecureString = ConvertTo-SecureString -AsPlainText -Force -String  $UserPassword
    $UserCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $UserName, $UserPasswordSecureString


    #================================================================================================================
    # 2. Gets computer details (Manufacturer, Model etc.)
    #================================================================================================================

    $CurrentScriptPosition = "Section: 2. Gets computer details (Manufacturer, Model etc.)" # Used for error message information if required

    Write-Host "$LogTitleName -  Gathering computer details"

    $ComputerDetails = [PSCustomObject]@{
        Manufacturer = $null
        Model        = $null
    }

    # Gather computer details based upon specific computer manufacturer
    $ComputerManufacturer = (Get-WmiObject -Class "Win32_ComputerSystem" | Select-Object -ExpandProperty Manufacturer).Trim()
    switch -Wildcard ($ComputerManufacturer) {
        "*Microsoft*" {
            $ComputerDetails.Manufacturer = "Microsoft"
            $ComputerDetails.Model = (Get-WmiObject -Class "Win32_ComputerSystem" | Select-Object -ExpandProperty Model).Trim()
        }
        "*HP*" {
            $ComputerDetails.Manufacturer = "HP"
            $ComputerDetails.Model = (Get-WmiObject -Class "Win32_ComputerSystem" | Select-Object -ExpandProperty Model).Trim()
        }
        "*Hewlett-Packard*" {
            $ComputerDetails.Manufacturer = "HP"
            $ComputerDetails.Model = (Get-WmiObject -Class "Win32_ComputerSystem" | Select-Object -ExpandProperty Model).Trim()
        }
        "*Dell*" {
            $ComputerDetails.Manufacturer = "Dell"
            $ComputerDetails.Model = (Get-WmiObject -Class "Win32_ComputerSystem" | Select-Object -ExpandProperty Model).Trim()
        }
        "*Lenovo*" {
            $ComputerDetails.Manufacturer = "Lenovo"
            $ComputerDetails.Model = (Get-WmiObject -Class "Win32_ComputerSystemProduct" | Select-Object -ExpandProperty Version).Trim()
        }
    }

    If(-not($ComputerDetails.Manufacturer)){Throw "Could not gather Manufacturer"}
    If(-not($ComputerDetails.Model)){Throw "Could not gather Model"}

    Write-Host "$LogTitleName -  Computer Manufacturer : $($ComputerDetails.Manufacturer)"
    Write-Host "$LogTitleName -  Computer Model : $($ComputerDetails.Model)"


    #================================================================================================================
    # 3. Connects to ConfigMgr to retreive all packages which start with a specific string
    #================================================================================================================

    $CurrentScriptPosition = "Section: 3. Connects to ConfigMgr to retreive all packages which start with a specific string" # Used for error message information if required

    Write-Host "$LogTitleName -  Connect to ConfigMgr to retreive all packages which start with | $DriverFilter"
    
    # Construct array object to hold return value
    $PackageArray = New-Object -TypeName System.Collections.ArrayList

    $AdminServiceUri = "https://$CMServer/AdminService/wmi/SMS_Package?`$filter=contains(Name,'$DriverFilter')"
    $AdminServiceResponse = Invoke-RestMethod -Method Get -Uri $AdminServiceUri -Credential $UserCredential -ErrorAction Stop

    # Add returned driver package objects to array list
    if ($AdminServiceResponse.value) {
        Write-Host "$LogTitleName -  Success: Retreived drivers packages from $CMServer"
        foreach ($Package in $AdminServiceResponse.value) {$PackageArray.Add($Package) | Out-Null } 
     }
    else{Throw "Could not connect to Admin Service: $AdminServiceUri"}

    
    #================================================================================================================
    # 4. Matches driver package to computer details
    #================================================================================================================

    $CurrentScriptPosition = "Section: 4. Matches driver package to computer details" # Used for error message information if required

    $DriverMatched = $false

    Write-Host "$LogTitleName -  Matching local device to a driver package"
    # Sort all driver package objects by package name property
    $DriverPackages = $PackageArray | Sort-Object -Property PackageName

    # Filter out driver packages that does not match with the vendor
    Write-Host "$LogTitleName -  Filtering driver package results to detected computer manufacturer: $($ComputerDetails.Manufacturer)"
    $DriverPackages = $DriverPackages | Where-Object {$_.Manufacturer -like $ComputerDetails.Manufacturer}

    # Filter out driver packages that do not contain any value in the package description
    Write-Host "$LogTitleName -  Filtering driver package results to only include packages that have details added to the description field"
    $DriverPackages = $DriverPackages | Where-Object {$_.Description -ne ([string]::Empty)}

    If(($DriverPackages | Measure-Object).Count -eq 0){Throw "No drivers left to process after pre-filter checks"}

    Write-Host "$LogTitleName -  Construct custom object to hold values for current driver package properties used for matching with current computer details"

    foreach ($DriverPackageItem in $DriverPackages) {
        # Construct custom object to hold values for current driver package properties used for matching with current computer details
        $DriverPackageDetails = [PSCustomObject]@{
            PackageName    = $DriverPackageItem.Name
            PackageID      = $DriverPackageItem.PackageID
            PackageVersion = $DriverPackageItem.Version
            DateCreated    = $DriverPackageItem.SourceDate
            Manufacturer   = $DriverPackageItem.Manufacturer
            Model          = $null
            SystemSKU      = $DriverPackageItem.Description.Split(":").Replace("(", "").Replace(")", "")[1]
            OSName         = $null
            OSVersion      = $null
            Architecture   = $null
        }
    
        # Add driver package model details depending on manufacturer to custom driver package details object
        # - HP computer models require the manufacturer name to be a part of the model name, other manufacturers do not
        switch ($DriverPackageItem.Manufacturer) {
            "Hewlett-Packard" {
                $DriverPackageDetails.Model = $DriverPackageItem.Name.Replace("Hewlett-Packard", "HP").Replace(" - ", ":").Split(":").Trim()[1]
            }
            "HP" {
                $DriverPackageDetails.Model = $DriverPackageItem.Name.Replace(" - ", ":").Split(":").Trim()[1]
            }
            default {
                $DriverPackageDetails.Model = $DriverPackageItem.Name.Replace($DriverPackageItem.Manufacturer, "").Replace(" - ", ":").Split(":").Trim()[1]
            }
       }

        # Attempt to match against computer model
        
        if ($DriverPackageDetails.Model -like $ComputerDetails.Model) {
            # Computer model match found
            $DriverMatched = "Matched"
            Break
        }
    }

    If($DriverMatched -eq "Matched"){Write-Host "$LogTitleName -  Matched computer model: $($ComputerDetails.Model) to driver package: $($DriverPackageDetails.PackageName)"}
    Else{
        $DriverMatched = "NoMatch"
        Throw "Could match local device to a driver package"
    }


    If($TSEnvironment.Value("DRV_PreCheckCompleted") -eq "Complete"){
        #================================================================================================================
        # 5. Downloads the driver package
        #================================================================================================================

        $CurrentScriptPosition = "Section: 5. Downloads the driver package" # Used for error message information if required

        Write-Host "$LogTitleName -  Starting download driver process"

        $DestinationLocationType = "TSCache"
        $DestinationVariableName = "OSDDriverPackage"
        
        # Set OSDDownloadDownloadPackages
        Write-Host "$LogTitleName -  Setting task sequence variable OSDDownloadDownloadPackages to: $($DriverPackageDetails.PackageID)"
        $TSEnvironment.Value("OSDDownloadDownloadPackages") = "$($DriverPackageDetails.PackageID)"
            
        # Set OSDDownloadDestinationLocationType
        Write-Host "$LogTitleName -  Setting task sequence variable OSDDownloadDestinationLocationType to: $DestinationLocationType"
        $TSEnvironment.Value("OSDDownloadDestinationLocationType") = "$DestinationLocationType"
            
        # Set OSDDownloadDestinationVariable
        Write-Host "$LogTitleName -  Setting task sequence variable OSDDownloadDestinationVariable to: $DestinationVariableName"
        $TSEnvironment.Value("OSDDownloadDestinationVariable") = "$DestinationVariableName"
            
        # Set SMSTSDownloadRetryCount to 1000 to overcome potential BranchCache issue that will cause 'SendWinHttpRequest failed. 80072efe'
        $TSEnvironment.Value("SMSTSDownloadRetryCount") = 1000
            
        Write-Host "$LogTitleName -  Starting package content download process (WinPE), this might take some time"
        # Invoke download of package content
            $SplatArgs = @{
                FilePath    = "OSDDownloadContent.exe"
                NoNewWindow = $true
                Passthru    = $true
                Wait = $true
            }

        $process = Start-Process @SplatArgs
        if($process.ExitCode -eq 0){Write-Host "$LogTitleName -  Successfully downloaded content"}
        else{Throw "$($SplatArgs.FilePath) failed with exit code: $($process.ExitCode)"}
            
        # Reset SMSTSDownloadRetryCount to 5 after attempted download
        $TSEnvironment.Value("SMSTSDownloadRetryCount") = 5
        
        $DriverPackageContentLocation = $TSEnvironment.Value("OSDDriverPackage01")
  
        If (Test-Path "$($DriverPackageContentLocation)\$DriverPackageZipFileName"){
            Write-Host "$LogTitleName -  Driver package content files was successfully downloaded to: $($DriverPackageContentLocation)"
        }Else{Throw "There is something wrong with the driver package content, as the file $DriverPackageZipFileName was not located at $($DriverPackageContentLocation)"}


        #================================================================================================================
        # 6. Unzipps and then installs the drivers
        #================================================================================================================

        $CurrentScriptPosition = "Section: 6. Unzipps and then installs the drivers" # Used for error message information if required

        $DriverPackageCompressedFile = Get-ChildItem -Path $DriverPackageContentLocation -Filter "$DriverPackageZipFileName"

        Write-Host "$LogTitleName -  Expanding archive: $($DriverPackageCompressedFile.FullName)"
        Expand-Archive -Path $DriverPackageCompressedFile.FullName -DestinationPath $DriverPackageContentLocation -Force -ErrorAction Stop
        
        Write-Host "$LogTitleName -  Will now attempt to install the drivers using DISM"

        $SplatArgs = @{
            FilePath    = "dism.exe"
            NoNewWindow = $false
            Passthru    = $true
            Wait = $true
            ArgumentList = "/Image:$($TSEnvironment.Value('OSDTargetSystemDrive'))\ /Add-Driver /Driver:$($DriverPackageContentLocation) /LogPath:$($TSEnvironment.Value('OSDTargetSystemDrive'))\Windows\Logs\DISM\DISM_CMDriverInstall.log /Recurse"
        }
        
        $process = Start-Process @SplatArgs
        if($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010){Write-Host "$LogTitleName -  Successfully installed drivers"}
        else{Throw "$($SplatArgs.FilePath) failed with exit code: $($process.ExitCode)"}

    }Else{$TSEnvironment.Value("DRV_PreCheckCompleted") = "Complete"}

}
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# End of Try process
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Catch{

    Write-Host "$LogTitleName -   "
    Write-Host "$LogTitleName -   "
    Write-Host "$LogTitleName -  Caught failure | Error: $($_.Exception.Message) | at line number $($_.InvocationInfo.ScriptLineNumber)"
    Write-Host "$LogTitleName -   "
    Write-Host "$LogTitleName -  $($_.InvocationInfo.PositionMessage)"
    Write-Host "$LogTitleName -   "
    Write-Host "$LogTitleName -   "

    $ErrorExitCode = $true
    $ErrorMessageBoxText = "$CurrentScriptPosition `n`nThe driver install process of $LogTitleName encountered an error:`n`n$($_.Exception.Message)"

}
Finally{

    If($DriverMatched -eq "NoMatch"){
        Write-Host "$LogTitleName - Error: No driver matched. Will display message box and then shut down."
        $ErrorMessageBoxText = "This computer model of: $($ComputerDetails.Manufacturer) $($ComputerDetails.Model), is not supported in the Windows 10 build. `n`nIf you believe this is a supported model or need to add support, please raise a request with Modern Workplace for review."
    }
    ElseIf($ErrorExitCode){
        Write-Host "$LogTitleName -  Runtime error identified, exiting with a error value of 1"
        (new-object -ComObject Microsoft.SMS.TsProgressUI).CloseProgressDialog() 
        (new-object -ComObject wscript.shell).Popup("$ErrorMessageBoxText",0,'ERROR',0 + 16)
    }
    Else{
        Write-Host "$LogTitleName -  Successfully completed driver package install"
    }

    Write-Host "$LogTitleName -   "
    Write-Host "$LogTitleName -  **************************************************************************************************************"
    Write-Host "$LogTitleName -  **************************************************************************************************************"
    Write-Host "$LogTitleName -   "
    Write-Host "$LogTitleName -  ***************************       END OF $LogTitleName      *************************************"
    Write-Host "$LogTitleName -   "
    Write-Host "$LogTitleName -  **************************************************************************************************************"
    Write-Host "$LogTitleName -  **************************************************************************************************************"
    Write-Host "$LogTitleName -   "

    If($DriverMatched -eq "NoMatch"){
        #$Message = "This computer model of: $($ComputerDetails.Manufacturer) $($ComputerDetails.Model), is not supported in the Windows 10 build. `n`nIf you believe this is a supported model or need to add support, please raise a request with Modern Workplace for review."
        (new-object -ComObject Microsoft.SMS.TsProgressUI).CloseProgressDialog() 
        (new-object -ComObject wscript.shell).Popup("$ErrorMessageBoxText",0,'ERROR',0 + 16)
        Stop-Computer -Force}
    If($ErrorExitCode){exit 1}
}
