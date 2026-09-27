[CmdletBinding()]
param(
    [ValidateSet('Validate', 'Plan', 'Apply', 'Verify')]
    [string]$Mode = 'Plan',

    [Parameter(Mandatory)]
    [string]$Domain,

    [Parameter(Mandatory)]
    [string]$RecordsFile,

    [string]$EnvironmentFile = (Join-Path (Get-Location).Path '.enviroment'),

    [string]$SnapshotDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ApiBase = 'https://api.cloudflare.com/client/v4'
$OldSpf = 'v=spf1 include:_spf.mx.cloudflare.net ~all'
$CloudflareMxPattern = '^route[123]\.mx\.cloudflare\.net\.?$'
$ApiEmail = $null
$GlobalApiKey = $null

$Domain = $Domain.Trim().TrimEnd('.').ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($Domain) -or $Domain -notmatch '^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$') {
    throw "Invalid domain: '$Domain'."
}

function Get-JsonPropertyValue {
    param(
        [Parameter(Mandatory)] [object]$Object,
        [Parameter(Mandatory)] [string]$Name,
        [switch]$Required
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        if ($Required) { throw "Records file is missing required property '$Name'." }
        return $null
    }
    return $property.Value
}

$resolvedRecordsFile = (Resolve-Path -LiteralPath $RecordsFile -ErrorAction Stop).Path
$targetDefinition = Get-Content -LiteralPath $resolvedRecordsFile -Raw -ErrorAction Stop | ConvertFrom-Json
$definitionDomainValue = Get-JsonPropertyValue -Object $targetDefinition -Name 'domain' -Required
if ([string]::IsNullOrWhiteSpace([string]$definitionDomainValue)) {
    throw 'Records file must contain a domain property.'
}
$definitionDomain = ([string]$definitionDomainValue).Trim().TrimEnd('.').ToLowerInvariant()
if ($definitionDomain -cne $Domain) {
    throw "Records file domain '$definitionDomain' does not match requested domain '$Domain'."
}
$recordDefinitions = Get-JsonPropertyValue -Object $targetDefinition -Name 'records' -Required

$TargetRecords = @(
    foreach ($record in @($recordDefinitions)) {
        $type = ([string](Get-JsonPropertyValue -Object $record -Name 'type' -Required)).Trim().ToUpperInvariant()
        if ($type -notin @('TXT', 'MX', 'CNAME')) {
            throw "Unsupported target DNS record type '$type'. Allowed: TXT, MX, CNAME."
        }

        $owner = ([string](Get-JsonPropertyValue -Object $record -Name 'name')).Trim().TrimEnd('.').ToLowerInvariant()
        if ($owner -eq '@' -or [string]::IsNullOrWhiteSpace($owner)) {
            $owner = $Domain
        }
        elseif ($owner -ne $Domain -and -not $owner.EndsWith(".$Domain", [StringComparison]::OrdinalIgnoreCase)) {
            $owner = "$owner.$Domain"
        }
        if ($owner -ne $Domain -and -not $owner.EndsWith(".$Domain", [StringComparison]::OrdinalIgnoreCase)) {
            throw "Target DNS owner '$owner' is outside '$Domain'."
        }

        $content = ([string](Get-JsonPropertyValue -Object $record -Name 'content' -Required)).Trim()
        if ([string]::IsNullOrWhiteSpace($content)) {
            throw "Target $type record at '$owner' has empty content."
        }
        $ttlValue = Get-JsonPropertyValue -Object $record -Name 'ttl'
        $ttl = if ($null -eq $ttlValue) { 600 } else { [int]$ttlValue }
        if ($ttl -ne 1 -and ($ttl -lt 60 -or $ttl -gt 86400)) {
            throw "Invalid TTL '$ttl' for target $type record at '$owner'."
        }

        $normalized = [ordered]@{
            type    = $type
            name    = $owner
            content = $content
            ttl     = $ttl
            comment = if ([string]::IsNullOrWhiteSpace([string](Get-JsonPropertyValue -Object $record -Name 'comment'))) { 'Feishu Mail cutover' } else { [string](Get-JsonPropertyValue -Object $record -Name 'comment') }
        }
        if ($type -eq 'MX') {
            $priorityValue = Get-JsonPropertyValue -Object $record -Name 'priority' -Required
            $normalized.priority = [int]$priorityValue
        }
        $normalized
    }
)

if ($TargetRecords.Count -eq 0) {
    throw 'Records file contains no target DNS records.'
}
$targetSpfRecords = @($TargetRecords | Where-Object { $_.type -eq 'TXT' -and $_.name -ieq $Domain -and $_.content -match '^v=spf1\s' })
if ($targetSpfRecords.Count -ne 1) {
    throw "Expected exactly one target apex SPF record; found $($targetSpfRecords.Count)."
}
$TargetSpf = [string]$targetSpfRecords[0].content
$targetMxRecords = @($TargetRecords | Where-Object { $_.type -eq 'MX' -and $_.name -ieq $Domain })
if ($targetMxRecords.Count -eq 0) {
    throw 'Expected at least one target apex MX record.'
}
$targetIdentities = @($TargetRecords | ForEach-Object {
    "$($_.type)|$(([string]$_.name).ToLowerInvariant())|$(([string]$_.content).TrimEnd('.').ToLowerInvariant())"
})
if (@($targetIdentities | Sort-Object -Unique).Count -ne $targetIdentities.Count) {
    throw 'Records file contains duplicate target DNS records.'
}

if ([string]::IsNullOrWhiteSpace($SnapshotDirectory)) {
    $SnapshotDirectory = Join-Path (Get-Location).Path '.feishu-mail-cutover'
}
elseif (-not [IO.Path]::IsPathRooted($SnapshotDirectory)) {
    $SnapshotDirectory = Join-Path (Get-Location).Path $SnapshotDirectory
}
$SnapshotDirectory = [IO.Path]::GetFullPath($SnapshotDirectory)

if ($Mode -eq 'Validate') {
    Write-Host "Target definition is valid for $Domain." -ForegroundColor Green
    Write-Host "Target records: $($TargetRecords.Count); MX: $($targetMxRecords.Count); SPF: 1"
    exit 0
}

function Read-EnvironmentConfiguration {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not [IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path (Get-Location).Path $Path
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $values = @{}

    foreach ($line in Get-Content -LiteralPath $resolvedPath -ErrorAction Stop) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }
        if ($trimmed -notmatch '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            throw "Invalid line in environment file '$resolvedPath'. Expected NAME=VALUE; content omitted to protect credentials."
        }

        $name = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and (
            ($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))
        )) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$name] = $value
    }

    foreach ($requiredName in @('CLOUDFLARE_API_EMAIL', 'CLOUDFLARE_GLOBAL_API_KEY')) {
        if (-not $values.ContainsKey($requiredName) -or [string]::IsNullOrWhiteSpace([string]$values[$requiredName])) {
            throw "Environment file '$resolvedPath' must define $requiredName."
        }
    }

    return [pscustomobject]@{
        Path  = $resolvedPath
        Email = ([string]$values['CLOUDFLARE_API_EMAIL']).Trim()
        Key   = [string]$values['CLOUDFLARE_GLOBAL_API_KEY']
    }
}

$credential = Read-EnvironmentConfiguration -Path $EnvironmentFile
$ApiEmail = $credential.Email
$GlobalApiKey = $credential.Key
Write-Host "Loaded Cloudflare credentials from: $($credential.Path)"
$credential = $null
if ([string]::IsNullOrWhiteSpace($ApiEmail) -or [string]::IsNullOrWhiteSpace($GlobalApiKey)) {
    throw 'Cloudflare account email and Global API Key are required.'
}

function Invoke-Cloudflare {
    param(
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,
        [object]$Body
    )

    $headers = @{ 'X-Auth-Email' = $ApiEmail; 'X-Auth-Key' = $GlobalApiKey }

    $request = @{
        Method      = $Method
        Uri         = "$ApiBase$Path"
        Headers     = $headers
        ContentType = 'application/json'
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }

    try {
        $response = Invoke-RestMethod @request
    }
    catch {
        $detail = $_.ErrorDetails.Message
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $_.Exception.Message }
        throw "Cloudflare API $Method $Path failed: $detail"
    }

    if (-not $response.success) {
        $errors = ($response.errors | ConvertTo-Json -Depth 10 -Compress)
        throw "Cloudflare API $Method $Path returned success=false: $errors"
    }
    return $response
}

function Get-Zone {
    $escapedDomain = [uri]::EscapeDataString($Domain)
    $response = Invoke-Cloudflare -Method GET -Path "/zones?name=$escapedDomain&status=active&per_page=50"
    $zones = @($response.result)
    if ($zones.Count -ne 1) {
        throw "Expected exactly one active Cloudflare zone for $Domain; found $($zones.Count)."
    }
    return $zones[0]
}

function Get-DnsRecords {
    param([Parameter(Mandatory)] [string]$ZoneId)
    $response = Invoke-Cloudflare -Method GET -Path "/zones/$ZoneId/dns_records?per_page=5000"
    return @($response.result)
}

function Get-EmailRoutingSettings {
    param([Parameter(Mandatory)] [string]$ZoneId)
    return (Invoke-Cloudflare -Method GET -Path "/zones/$ZoneId/email/routing").result
}

function Save-Backup {
    param(
        [Parameter(Mandatory)] [object]$Zone,
        [Parameter(Mandatory)] [object[]]$Records,
        [object]$EmailRouting
    )

    $backupDirectory = $SnapshotDirectory
    [void][System.IO.Directory]::CreateDirectory($backupDirectory)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $backupDirectory "$Domain-$stamp.json"
    [ordered]@{
        created_at    = (Get-Date).ToString('o')
        domain        = $Domain
        zone_id       = $Zone.id
        email_routing = $EmailRouting
        target_records = $TargetRecords
        dns_records   = $Records
    } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function Test-CurrentMailRecords {
    param([Parameter(Mandatory)] [object[]]$Records)

    $apexRecords = @($Records | Where-Object { $_.name -ieq $Domain })
    $mxRecords = @($apexRecords | Where-Object { $_.type -eq 'MX' })
    $spfRecords = @($apexRecords | Where-Object { $_.type -eq 'TXT' -and $_.content -match '^v=spf1\s' })
    $allowedMx = @($targetMxRecords | ForEach-Object { ([string]$_.content).TrimEnd('.') })

    $unexpectedMx = @($mxRecords | Where-Object {
        $_.content -notmatch $CloudflareMxPattern -and $allowedMx -inotcontains $_.content.TrimEnd('.')
    })
    if ($unexpectedMx.Count -gt 0) {
        throw "Unexpected apex MX record(s) found; refusing to modify: $($unexpectedMx.content -join ', ')"
    }

    $unexpectedSpf = @($spfRecords | Where-Object { $_.content -ne $OldSpf -and $_.content -ne $TargetSpf })
    if ($unexpectedSpf.Count -gt 0) {
        throw "Unexpected SPF record(s) found; refusing to modify: $($unexpectedSpf.content -join ', ')"
    }

    foreach ($target in $TargetRecords) {
        $ownerRecords = @($Records | Where-Object { $_.name -ieq $target.name })
        $targetIdentity = Get-RecordIdentity -Record $target
        $cnameConflicts = @($ownerRecords | Where-Object {
            (($_.type -eq 'CNAME') -or ($target.type -eq 'CNAME')) -and
            (Get-RecordIdentity -Record $_) -ne $targetIdentity
        })
        if ($cnameConflicts.Count -gt 0) {
            throw "CNAME conflict at '$($target.name)'; refusing to modify existing record(s): $($cnameConflicts.content -join ', ')"
        }
    }

    if ($spfRecords.Count -gt 1) {
        Write-Warning 'Multiple known SPF records exist at the apex; Apply mode will remove only the retired Cloudflare SPF.'
    }

    return [ordered]@{
        mx  = $mxRecords
        spf = $spfRecords
    }
}

function Get-RecordIdentity {
    param([Parameter(Mandatory)] [object]$Record)
    $content = ([string]$Record.content).TrimEnd('.').ToLowerInvariant()
    return "$($Record.type)|$(([string]$Record.name).ToLowerInvariant())|$content"
}

function Get-DnsBatch {
    param([Parameter(Mandatory)] [object[]]$Records)

    $deletes = [System.Collections.Generic.List[object]]::new()
    $patches = [System.Collections.Generic.List[object]]::new()
    $posts = [System.Collections.Generic.List[object]]::new()

    foreach ($record in $Records) {
        $isOldMx = $record.type -eq 'MX' -and $record.name -ieq $Domain -and $record.content -match $CloudflareMxPattern
        $isOldSpf = $record.type -eq 'TXT' -and $record.name -ieq $Domain -and $record.content -eq $OldSpf
        if ($isOldMx -or $isOldSpf) {
            $deletes.Add([ordered]@{ id = $record.id })
        }
    }

    foreach ($target in $TargetRecords) {
        $targetIdentity = Get-RecordIdentity -Record $target
        $matches = @($Records | Where-Object { (Get-RecordIdentity -Record $_) -eq $targetIdentity })

        if ($matches.Count -eq 0) {
            $posts.Add($target)
            continue
        }

        $primary = $matches[0]
        for ($i = 1; $i -lt $matches.Count; $i++) {
            $deletes.Add([ordered]@{ id = $matches[$i].id })
        }

        $priorityMismatch = $target.type -eq 'MX' -and [int]$primary.priority -ne [int]$target.priority
        if ([int]$primary.ttl -ne [int]$target.ttl -or $priorityMismatch) {
            $patch = [ordered]@{
                id      = $primary.id
                type    = $target.type
                name    = $target.name
                content = $target.content
                ttl     = $target.ttl
                comment = $target.comment
            }
            if ($target.type -eq 'MX') { $patch.priority = $target.priority }
            $patches.Add($patch)
        }
    }

    return [ordered]@{
        deletes = @($deletes)
        patches = @($patches)
        posts   = @($posts)
    }
}

function Show-Plan {
    param(
        [object]$Routing,
        [object]$Batch,
        [string]$BackupPath
    )

    Write-Host "Domain: $Domain"
    Write-Host "Backup: $BackupPath"
    if ($null -ne $Routing) {
        Write-Host "Email Routing: enabled=$($Routing.enabled), status=$($Routing.status)"
    }
    Write-Host "DNS deletes: $(@($Batch.deletes).Count)"
    Write-Host "DNS patches: $(@($Batch.patches).Count)"
    Write-Host "DNS creates: $(@($Batch.posts).Count)"
    Write-Host 'Target mail records:'
    $TargetRecords | ForEach-Object {
        if ($_.type -eq 'MX') {
            Write-Host "  MX  $($_.name)  priority=$($_.priority)  $($_.content)"
        }
        else {
            Write-Host "  TXT $($_.name)  $($_.content)"
        }
    }
}

function Test-ApiState {
    param([Parameter(Mandatory)] [object[]]$Records)

    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($target in $TargetRecords) {
        $targetIdentity = Get-RecordIdentity -Record $target
        $matches = @($Records | Where-Object { (Get-RecordIdentity -Record $_) -eq $targetIdentity })
        if ($matches.Count -ne 1) {
            $errors.Add("Expected exactly one $($target.type) record for '$($target.content)'; found $($matches.Count).")
            continue
        }
        if ($target.type -eq 'MX' -and [int]$matches[0].priority -ne [int]$target.priority) {
            $errors.Add("MX priority mismatch for $($target.content).")
        }
        if ([int]$matches[0].ttl -ne [int]$target.ttl) {
            $errors.Add("TTL mismatch for $($target.type) $($target.name) '$($target.content)'.")
        }
    }

    $oldRecords = @($Records | Where-Object {
        $_.name -ieq $Domain -and (
            ($_.type -eq 'MX' -and $_.content -match $CloudflareMxPattern) -or
            ($_.type -eq 'TXT' -and $_.content -eq $OldSpf)
        )
    })
    if ($oldRecords.Count -gt 0) {
        $errors.Add("$($oldRecords.Count) old Cloudflare mail DNS record(s) still exist.")
    }

    if ($errors.Count -gt 0) {
        throw "Cloudflare API verification failed:`n - $($errors -join "`n - ")"
    }
    Write-Host 'Cloudflare API state is correct.' -ForegroundColor Green
}

function Restore-CloudflareRouting {
    param(
        [Parameter(Mandatory)] [string]$ZoneId,
        [object]$RoutingBefore
    )

    if ($null -eq $RoutingBefore -or -not $RoutingBefore.enabled) {
        Write-Warning 'Automatic rollback skipped because Email Routing was not enabled in the pre-change snapshot.'
        return
    }

    Write-Warning 'Forward cutover failed. Re-enabling Cloudflare Email Routing DNS...'
    [void](Invoke-Cloudflare -Method POST -Path "/zones/$ZoneId/email/routing/dns")
    Write-Host 'Cloudflare Email Routing DNS was re-enabled. Verify the backup before retrying.' -ForegroundColor Yellow
}

$zone = Get-Zone
$recordsBefore = Get-DnsRecords -ZoneId $zone.id
$routingBefore = Get-EmailRoutingSettings -ZoneId $zone.id
[void](Test-CurrentMailRecords -Records $recordsBefore)

if ($Mode -eq 'Verify') {
    Test-ApiState -Records $recordsBefore
    exit 0
}

$backupPath = Save-Backup -Zone $zone -Records $recordsBefore -EmailRouting $routingBefore
$initialBatch = Get-DnsBatch -Records $recordsBefore
Show-Plan -Routing $routingBefore -Batch $initialBatch -BackupPath $backupPath

if ($Mode -eq 'Plan') {
    Write-Host 'Plan only. No Cloudflare settings were changed.' -ForegroundColor Yellow
    exit 0
}

try {
    if ($routingBefore.enabled) {
        Write-Host 'Disabling Cloudflare Email Routing DNS management...'
        [void](Invoke-Cloudflare -Method DELETE -Path "/zones/$($zone.id)/email/routing/dns")
    }
    else {
        Write-Host 'Cloudflare Email Routing is already disabled; continuing with DNS batch.'
    }

    $recordsAfterDisable = Get-DnsRecords -ZoneId $zone.id
    [void](Test-CurrentMailRecords -Records $recordsAfterDisable)
    $batch = Get-DnsBatch -Records $recordsAfterDisable

    if (@($batch.deletes).Count -gt 0 -or @($batch.patches).Count -gt 0 -or @($batch.posts).Count -gt 0) {
        Write-Host 'Applying Feishu DNS records...'
        [void](Invoke-Cloudflare -Method POST -Path "/zones/$($zone.id)/dns_records/batch" -Body $batch)
    }

    $recordsAfter = Get-DnsRecords -ZoneId $zone.id
    Test-ApiState -Records $recordsAfter
    Write-Host "Switch complete. Backup saved at: $backupPath" -ForegroundColor Green
}
catch {
    try {
        Restore-CloudflareRouting -ZoneId $zone.id -RoutingBefore $routingBefore
    }
    catch {
        Write-Error "Automatic rollback failed: $($_.Exception.Message)"
    }
    throw
}
finally {
    $GlobalApiKey = $null
}
