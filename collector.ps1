Function Log {
    param (
        [string]$Text, 
        [string]$Path = $PSScriptRoot)
    if (! (Test-Path "$Path/log.txt")) { New-Item -Path "$Path/log.txt" -ItemType File -Force | Out-Null }
    Write-Host "$(Get-Date) - $Text"
    ("$(Get-Date) - $Text") | Out-File "$Path/log.txt" -Append -Force
}

Function Setup-Collector {
    param ([string]$Path = $PSScriptRoot)

    If (-not [System.IO.File]::Exists("$Path\config")) {
        New-Item -Path "$Path\config" -ItemType File | Out-Null
        $Template = @"
WORKSPACE_ID:
WORKSPACE_KEY:
ARM_ENDPOINT:
TENANT_NAME:
CLIENT_ID:
CLIENT_SECRET:
"@
        Set-Content -Value $Template -Path "$Path\config"
        Log("input: please update the configuration file at $("$Path\config") and run the script again.")
        exit 1
    }

    $Output = @{
        ConfigPath = "$Path\config"
    }
    return $Output
}

Function Get-Config ($Path) {
    Get-Content $Path | Foreach-Object { 
        $var = $_.Split(':') 
        New-Variable -Name $var[0] -Value $var[1]
        $STORAGE_ACCOUNT = $ConnectionString.Split(';').Split('=')[3] 
    }
    $Output = @{
        WorkspaceId  = $WORKSPACE_ID
        WorkspaceKey = $WORKSPACE_KEY
        ArmEndpoint  = $ARM_ENDPOINT
        TenantName   = $TENANT_NAME
        ClientID     = $CLIENT_ID
        ClientSecret = $CLIENT_SECRET
    }
    Write-Output $Output
}

Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource) {
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
 
    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)
 
    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId, $encodedHash
    return $authorization
}

Function Post-LogAnalyticsData($customerId, $sharedKey, $body, $logType, $TimeStampField) {
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = Build-Signature `
        -customerId $customerId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
 
    $headers = @{
        "Authorization"        = $signature;
        "Log-Type"             = $logType;
        "x-ms-date"            = $rfc1123date;
        "time-generated-field" = $TimeStampField;
    }
 
    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    return $response.StatusCode
}

#setup config
$TimeStamp = Get-Date
$TimeStampField = "CreatedTimestamp"
$Files = Setup-Collector
$Config = Get-Config $Files.ConfigPath

#prepare az environment
Add-AzEnvironment -Name "AzureStackAdmin" -ArmEndpoint "https://$($Config.ArmEndpoint)"
$AuthEndpoint = (Get-AzEnvironment -Name "AzureStackAdmin").ActiveDirectoryAuthority.TrimEnd('/')
$AADTenantName = $Config.TenantName
$TenantId = (invoke-restmethod "$($AuthEndpoint)/$($AADTenantName)/.well-known/openid-configuration").issuer.TrimEnd('/').Split('/')[-1]

#login via service principal
$SecurePassword = ConvertTo-SecureString -String $Config.ClientSecret -AsPlainText -Force
$ApplicationId = $Config.ClientID
$Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $ApplicationId, $SecurePassword
Connect-AzAccount -EnvironmentName "AzureStackAdmin" -ServicePrincipal -TenantId $TenantId -Credential $Credential

#collect and send active alers
$Alerts = Get-AzsAlert | Where-Object { $_.State -eq "Active" }
foreach ($Alert in $Alerts) {
    $Body = $Alert | ConvertTo-Json
    if ([string]::IsNullOrEmpty($Body)) {
        Log "output: no alets detected in at $TimeStamp"
    }
    else {
        Log $(Post-LogAnalyticsData -customerId $Config.WorkspaceId -sharedKey $Config.WorkspaceKey -body ([System.Text.Encoding]::UTF8.GetBytes($Body)) -logType "AZSHAlerts" -TimeStampField $TimeStampField)
    }
} 
