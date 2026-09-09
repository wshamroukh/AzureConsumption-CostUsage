Add-Type -AssemblyName System.Windows.Forms

# ── Date Picker Functions ─────────────────────────────────────────────────────
function Show-DatePicker {
    param (
        [string]$Title = "Select a Date",
        [string]$Message = "Choose a date:"
    )

    $form = New-Object Windows.Forms.Form
    $form.Text = $Title
    $form.Width = 280
    $form.Height = 180
    $form.StartPosition = "CenterScreen"

    $label = New-Object Windows.Forms.Label
    $label.Text = $Message
    $label.AutoSize = $true
    $label.Location = New-Object Drawing.Point(15, 15)
    $form.Controls.Add($label)

    $datePicker = New-Object Windows.Forms.DateTimePicker
    $datePicker.Format = 'Short'
    $datePicker.Width = 220
    $datePicker.Value = [datetime]::Today
    $datePicker.MaxDate = [datetime]::Today
    $datePicker.Location = New-Object Drawing.Point(15, 45)
    $form.Controls.Add($datePicker)

    $okButton = New-Object Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.Location = New-Object Drawing.Point(90, 85)
    $form.AcceptButton = $okButton
    $form.Controls.Add($okButton)

    $dialogResult = $form.ShowDialog()
    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return $datePicker.Value.Date
    } else {
        Write-Host "Date selection was cancelled. Exiting..." -ForegroundColor Yellow
        exit
    }
}

function Show-DatePickerWithDefault {
    param (
        [datetime]$defaultDate,
        [string]$Title = "Select a Date",
        [string]$Message = "Choose a date:"
    )

    $form = New-Object Windows.Forms.Form
    $form.Text = $Title
    $form.Width = 280
    $form.Height = 180
    $form.StartPosition = "CenterScreen"

    $label = New-Object Windows.Forms.Label
    $label.Text = $Message
    $label.AutoSize = $true
    $label.Location = New-Object Drawing.Point(15, 15)
    $form.Controls.Add($label)

    $datePicker = New-Object Windows.Forms.DateTimePicker
    $datePicker.Format = 'Short'
    $datePicker.Width = 220
    $datePicker.Value = $defaultDate
    $datePicker.MaxDate = [datetime]::Today
    $datePicker.Location = New-Object Drawing.Point(15, 45)
    $form.Controls.Add($datePicker)

    $okButton = New-Object Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.Location = New-Object Drawing.Point(90, 85)
    $form.AcceptButton = $okButton
    $form.Controls.Add($okButton)

    $dialogResult = $form.ShowDialog()
    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return $datePicker.Value.Date
    } else {
        Write-Host "Date selection was cancelled. Exiting..." -ForegroundColor Yellow
        exit
    }
}

# ── Helper: Execute Cost Management Query with quota-aware throttling ──────────
function Invoke-CostQuery {
    param(
        [string]$Uri,
        [string]$Body,
        [hashtable]$Headers,
        [int]$MaxRetries = 3
    )

    $retryCount = 0

    while ($retryCount -le $MaxRetries) {
        try {
            $webResponse = Invoke-WebRequest -Uri $Uri -Method Post -Body $Body -Headers $Headers -ContentType "application/json"
            $parsed      = $webResponse.Content | ConvertFrom-Json

            # Read quota headers from successful response
            $clientTypeRemaining = $webResponse.Headers["x-ms-ratelimit-remaining-microsoft.costmanagement-clienttype-requests"]
            $retryAfterHeader    = $webResponse.Headers["x-ms-ratelimit-microsoft.costmanagement-clienttype-retry-after"]

            $quotaMatch = [regex]::Match($clientTypeRemaining, 'DefaultQuota:(\d+)')
            $quotaLeft  = if ($quotaMatch.Success) { [int]$quotaMatch.Groups[1].Value } else { 99 }

            Write-Host "    ClientType quota remaining: $quotaLeft" -ForegroundColor DarkGray

            if ($quotaLeft -eq 0 -and $retryAfterHeader -and [int]$retryAfterHeader -gt 0) {
                $wait = [int]$retryAfterHeader + 2
                Write-Host "    Quota exhausted. Waiting ${wait}s for reset..." -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
            } elseif ($quotaLeft -le 2) {
                Write-Host "    Quota low. Waiting 15s..." -ForegroundColor Yellow
                Start-Sleep -Seconds 15
            } else {
                Start-Sleep -Seconds 2
            }

            return $parsed

        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__

            if ($statusCode -eq 429) {
                $retryAfter = $null
                try {
                    $retryAfter = $_.Exception.Response.Headers["x-ms-ratelimit-microsoft.costmanagement-clienttype-retry-after"]
                    if (-not $retryAfter) { $retryAfter = $_.Exception.Response.Headers["Retry-After"] }
                } catch {}

                $wait = if ($retryAfter) { [int]$retryAfter + 2 } else { 35 }

                if ($retryCount -eq $MaxRetries) {
                    throw "Max retries reached. Last 429 wait was ${wait}s."
                }

                Write-Host "    429 received. Waiting ${wait}s (retry $($retryCount+1)/$MaxRetries)..." -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
                $retryCount++
            } else {
                throw $_
            }
        }
    }
}

# ── Helper: Parse response rows into a hashtable keyed by "ResourceId|Date" ───
function ConvertTo-RowMap {
    param($Response, [string]$KeySuffix = "")

    $map = @{}
    if (-not $Response.properties.rows) { return $map }

    $cols = @{}
    for ($i = 0; $i -lt $Response.properties.columns.Count; $i++) {
        $cols[$Response.properties.columns[$i].name] = $i
    }

    foreach ($row in $Response.properties.rows) {
        $resourceId = $row[$cols["ResourceId"]]
        $rawDate    = $row[$cols["UsageDate"]].ToString()
        $date       = [datetime]::ParseExact($rawDate.Substring(0,8), "yyyyMMdd", $null).ToString("dd/MM/yyyy")
        $key        = "$resourceId|$date"
        $map[$key]  = @{ cols = $cols; row = $row }
    }

    return $map
}

# ── Date Selection ────────────────────────────────────────────────────────────
do {
    $today = [datetime]::Today
    if ($today.Day -eq 1) {
        $defaultStartDate = Get-Date -Year $today.AddMonths(-1).Year -Month $today.AddMonths(-1).Month -Day 1
    } else {
        $defaultStartDate = Get-Date -Year $today.Year -Month $today.Month -Day 1
    }

    $startDate = Show-DatePickerWithDefault -defaultDate $defaultStartDate -Title "Start Date Selection" -Message "Please select the start date"
    $endDate   = Show-DatePicker -Title "End Date Selection" -Message "Please select the end date"

    if ($startDate -ge $endDate) {
        Write-Host "Start date must be earlier than end date. Please try again." -ForegroundColor Red
    }
} while ($startDate -ge $endDate)

Write-Host "`nAzure Daily Consumption per resource report: $startDate to $endDate" -ForegroundColor Cyan

# ── Output File ───────────────────────────────────────────────────────────────
$date       = Get-Date -Format "yyyy-MM-dd"
$folder     = "C:\temp"
$outputFile = "$folder\DailyUsagePerResource_$date.csv"

if (!(Test-Path $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
if (Test-Path $outputFile) { Remove-Item $outputFile }

# ── Authenticate ──────────────────────────────────────────────────────────────
#Connect-AzAccount

$secureToken = (Get-AzAccessToken -AsSecureString -ResourceUrl "https://management.azure.com/").Token
$ssPtr       = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$token       = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)

$headers = @{
    "Authorization"     = "Bearer $token"
    "Content-Type"      = "application/json"
    "ClientType"        = "WaddahCostReport"
    "X-Ms-Command-Name" = "CostAnalysis"
}

# ── Get Subscriptions ─────────────────────────────────────────────────────────
$subscriptions = Get-AzSubscription
$total         = $subscriptions.Count
$index         = 0
$rows          = @()

Write-Host "Found $total subscription(s).`n" -ForegroundColor Blue

foreach ($sub in $subscriptions) {
    $index++
    Write-Host "[$index/$total] $($sub.Name) ($($sub.Id))" -ForegroundColor Blue

    $queryUrl = "https://management.azure.com/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement/query?api-version=2023-03-01"

    $timePeriod = @{
        from = $startDate.ToString("yyyy-MM-dd")
        to   = $endDate.ToString("yyyy-MM-dd")
    }

    # ── Call 1: Identity dimensions ───────────────────────────────────────────
    Write-Host "  [Call 1/2] Identity dimensions..." -ForegroundColor DarkCyan

    $body1 = @{
        type      = "Usage"
        timeframe = "Custom"
        timePeriod = $timePeriod
        dataset = @{
            granularity = "Daily"
            aggregation = @{
                CostUSD = @{ name = "Cost"; function = "Sum" }
            }
            grouping = @(
                @{ type = "Dimension"; name = "ResourceId" },
                @{ type = "Dimension"; name = "ResourceGroupName" },
                @{ type = "Dimension"; name = "ResourceType" },
                @{ type = "Dimension"; name = "ResourceLocation" }
            )
        }
    } | ConvertTo-Json -Depth 12

    # ── Call 2: Billing dimensions ────────────────────────────────────────────
    Write-Host "  [Call 2/2] Billing dimensions..." -ForegroundColor DarkCyan

    $body2 = @{
        type      = "Usage"
        timeframe = "Custom"
        timePeriod = $timePeriod
        dataset = @{
            granularity = "Daily"
            aggregation = @{
                CostUSD = @{ name = "Cost"; function = "Sum" }
            }
            grouping = @(
                @{ type = "Dimension"; name = "ResourceId" },
                @{ type = "Dimension"; name = "MeterCategory" },
                @{ type = "Dimension"; name = "MeterSubCategory" },
                @{ type = "Dimension"; name = "UnitOfMeasure" },
                @{ type = "Dimension"; name = "PricingModel" },
                @{ type = "Dimension"; name = "ChargeType" }
            )
        }
    } | ConvertTo-Json -Depth 12

    try {
        $response1 = Invoke-CostQuery -Uri $queryUrl -Body $body1 -Headers $headers
        $response2 = Invoke-CostQuery -Uri $queryUrl -Body $body2 -Headers $headers
    } catch {
        Write-Host "  Error querying $($sub.Name): $_" -ForegroundColor Red
        continue
    }

    if (-not $response1.properties.rows -or $response1.properties.rows.Count -eq 0) {
        Write-Host "  No usage data found." -ForegroundColor DarkGray
        continue
    }

    # ── Build column maps ─────────────────────────────────────────────────────
    $cols1 = @{}
    for ($i = 0; $i -lt $response1.properties.columns.Count; $i++) {
        $cols1[$response1.properties.columns[$i].name] = $i
    }

    $cols2 = @{}
    for ($i = 0; $i -lt $response2.properties.columns.Count; $i++) {
        $cols2[$response2.properties.columns[$i].name] = $i
    }

    # ── Index Call 2 rows by ResourceId|Date for fast lookup ─────────────────
    $map2 = @{}
    if ($response2.properties.rows) {
        foreach ($r in $response2.properties.rows) {
            $rid  = $r[$cols2["ResourceId"]]
            $rdat = $r[$cols2["UsageDate"]].ToString().Substring(0,8)
            $key  = "$rid|$rdat"
            $map2[$key] = $r
        }
    }

    # ── Merge and build output rows ───────────────────────────────────────────
    foreach ($r in $response1.properties.rows) {
        $resourceId  = $r[$cols1["ResourceId"]]
        $rawDate     = $r[$cols1["UsageDate"]].ToString().Substring(0,8)
        $usageDate   = [datetime]::ParseExact($rawDate, "yyyyMMdd", $null).ToString("dd/MM/yyyy")
        $cost        = [math]::Round([double]$r[$cols1["Cost"]], 4)
        $key         = "$resourceId|$rawDate"

        # Pull billing fields from Call 2 if matched, otherwise blank
        $r2           = $map2[$key]
        $meterCat     = if ($r2) { $r2[$cols2["MeterCategory"]]    } else { "" }
        $meterSubCat  = if ($r2) { $r2[$cols2["MeterSubCategory"]] } else { "" }
        $unit         = if ($r2) { $r2[$cols2["UnitOfMeasure"]]    } else { "" }
        $pricingModel = if ($r2) { $r2[$cols2["PricingModel"]]     } else { "" }
        $chargeType   = if ($r2) { $r2[$cols2["ChargeType"]]       } else { "" }

        $rows += [PSCustomObject]@{
            SubscriptionName  = $sub.Name
            UsageDate         = $usageDate
            ResourceId        = $resourceId
            ResourceGroupName = $r[$cols1["ResourceGroupName"]]
            ResourceType      = $r[$cols1["ResourceType"]]
            ResourceLocation  = $r[$cols1["ResourceLocation"]]
            MeterCategory     = $meterCat
            MeterSubCategory  = $meterSubCat
            UnitOfMeasure     = $unit
            PricingModel      = $pricingModel
            ChargeType        = $chargeType
            CostUSD           = $cost
        }
    }

    Write-Host "  Done. $($response1.properties.rows.Count) row(s) collected." -ForegroundColor Green
}

# ── Export ────────────────────────────────────────────────────────────────────
Write-Host "`nExporting to CSV..." -ForegroundColor Cyan

$rows |
    Sort-Object SubscriptionName, UsageDate, ResourceId |
    Export-Csv -Path $outputFile -NoTypeInformation

Write-Host "CSV generated successfully:" -ForegroundColor Green
Write-Host $outputFile -ForegroundColor Cyan
Write-Host "Total rows: $($rows.Count)" -ForegroundColor Green
