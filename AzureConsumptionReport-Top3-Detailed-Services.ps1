Add-Type -AssemblyName System.Windows.Forms

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

    # Add message label
    $label = New-Object Windows.Forms.Label
    $label.Text = $Message
    $label.AutoSize = $true
    $label.Location = New-Object Drawing.Point(15, 15)
    $form.Controls.Add($label)

    # Add date picker
    $datePicker = New-Object Windows.Forms.DateTimePicker
    $datePicker.Format = 'Short'
    $datePicker.Width = 220
    $datePicker.Value = [datetime]::Today
    $datePicker.MaxDate = [datetime]::Today  # prevent future dates
    $datePicker.Location = New-Object Drawing.Point(15, 45)
    $form.Controls.Add($datePicker)

    # Add OK button
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

function Get-DateInputGUI {
    while ($true) {
        $selectedDate = Show-DatePicker -Title "Select a date"
        if ($selectedDate -le [datetime]::Today) {
            return $selectedDate
        } else {
            [System.Windows.Forms.MessageBox]::Show("Date cannot be in the future. Please select again.", "Invalid Date", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }
}

do {
    # Determine default start date based on today's date
    $today = [datetime]::Today
    if ($today.Day -eq 1) {
        $defaultStartDate = Get-Date -Year $today.AddMonths(-1).Year -Month $today.AddMonths(-1).Month -Day 1
    } else {
        $defaultStartDate = Get-Date -Year $today.Year -Month $today.Month -Day 1
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

    $startDate = Show-DatePickerWithDefault -defaultDate $defaultStartDate -Title "Start Date Selection" -Message "Please select the start date"
    $endDate   = Show-DatePicker -Title "End Date Selection" -Message "Please select the end date"

    if ($startDate -ge $endDate) {
        Write-Host "Start date must be earlier than end date. Please try again." -ForegroundColor Red
    }
} while ($startDate -ge $endDate)

Write-Host "Azure Consumption report will be generated from $startDate till $endDate" -ForegroundColor Cyan

# Connect to Azure account if needed
# Connect-AzAccount

# Get token for ARM
$secureToken = (Get-AzAccessToken -AsSecureString -ResourceUrl "https://management.azure.com/").Token
$ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)

# Set headers
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# Get all subscriptions
$subscriptions = Get-AzSubscription

# Prepare an array to store the results
$results = @()

foreach ($subscription in $subscriptions) {
    $subscriptionId   = $subscription.Id
    $subscriptionName = $subscription.Name
    Write-Host "Processing subscription: $subscriptionName ($subscriptionId)" -ForegroundColor Magenta

    $apiVersion = "2023-03-01"
    $simpleQueryUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.CostManagement/query?api-version=$apiVersion"

    # Request body grouping by ServiceName and MeterSubcategory
    $body = @{
        type = "Usage"
        timeframe = "Custom"
        timePeriod = @{
            from = $startDate
            to   = $endDate
        }
        dataset = @{
            granularity = "None"
            aggregation = @{
                totalCost = @{
                    name     = "CostUSD"
                    function = "Sum"
                }
            }
            grouping = @(
                @{
                    type = "Dimension"
                    name = "ServiceName"
                },
                @{
                    type = "Dimension"
                    name = "MeterSubcategory"
                }
            )
        }
    }

    $bodyJson = $body | ConvertTo-Json -Depth 10

    try {
        $usageResponse = Invoke-RestMethod -Uri $simpleQueryUrl -Method Post -Body $bodyJson -Headers $headers

        # initialize accumulators
        $totalCost = 0.0
        $serviceTypeCosts = @{}
        $topServices = @()
        $topServicesString = "No data"

        if ($usageResponse.properties.rows -and $usageResponse.properties.rows.Count -gt 0) {
            # build a name->index map for columns (robust approach)
            $columnIndexMap = @{}
            for ($i = 0; $i -lt $usageResponse.properties.columns.Count; $i++) {
                $colName = $usageResponse.properties.columns[$i].name
                $columnIndexMap[$colName] = $i
            }

            $serviceNameIndex  = if ($columnIndexMap.ContainsKey("ServiceName")) { $columnIndexMap["ServiceName"] } else { -1 }
            $MeterSubcategoryIndex = if ($columnIndexMap.ContainsKey("MeterSubcategory")) { $columnIndexMap["MeterSubcategory"] } else { -1 }
            $costIndex         = if ($columnIndexMap.ContainsKey("CostUSD")) { $columnIndexMap["CostUSD"] } else { -1 }

            foreach ($row in $usageResponse.properties.rows) {
                $serviceName  = if ($serviceNameIndex -ge 0) { $row[$serviceNameIndex] } else { "" }
                $MeterSubcategory = if ($MeterSubcategoryIndex -ge 0) { $row[$MeterSubcategoryIndex] } else { "" }
                $cost         = if ($costIndex -ge 0) { [double]$row[$costIndex] } else { 0.0 }

                $totalCost += $cost

                # build a readable key: "ServiceName | MeterSubcategory"
                $svc = if ($serviceName) { $serviceName } else { "UnknownService" }
                $rt  = if ($MeterSubcategory) { $MeterSubcategory } else { "UnknownType" }
                $key = "$svc | $rt"

                if (-not $serviceTypeCosts.ContainsKey($key)) {
                    $serviceTypeCosts[$key] = 0.0
                }
                $serviceTypeCosts[$key] += $cost
            }

            # pick top 3 service|type combos
            $topServices = $serviceTypeCosts.GetEnumerator() |
                Sort-Object Value -Descending |
                Select-Object -First 3 |
                ForEach-Object { "$($_.Key): $([math]::Round($_.Value, 2)) USD" }

            if ($topServices -and $topServices.Count -gt 0) {
                $topServicesString = $topServices -join ", "
            } else {
                $topServicesString = "No data"
            }
        } else {
            $topServicesString = "No data"
        }

        $roundedCost = [math]::Round($totalCost, 2)

    } catch {
        Write-Output "Failed to retrieve usage for subscription $subscriptionName : $_"
        $roundedCost = "Error"
        $topServicesString = "Error"
    }

    $results += [PSCustomObject]@{
        Subscription = $subscriptionName
        UsageUSD     = $roundedCost
        TopServices  = $topServicesString
    }
}

Write-Host "`nAzure consumption report from $startDate to $($endDate):" -ForegroundColor Green

# sort: keep results with numeric usage on top by trying to convert; fallback to original order for non-numeric
$sortedResults = $results | Sort-Object @{Expression = { if ($_.UsageUSD -is [double]) { $_.UsageUSD } else { -1 } } } -Descending

foreach ($entry in $sortedResults) {
    # Format subscription usage
    $usageDisplay = if ($entry.UsageUSD -is [double]) { "{0:N2} USD" -f $entry.UsageUSD } else { $entry.UsageUSD }
    Write-Host ("{0,-66} {1,15}" -f $entry.Subscription, $usageDisplay) -ForegroundColor Cyan
    Write-Host "Top 3 Services:" -ForegroundColor DarkYellow

    if ($entry.TopServices -ne "No data" -and $entry.TopServices -ne "Error") {
        $entry.TopServices -split ', ' | ForEach-Object {
            $serviceName, $serviceUsage = $_ -split ': '
            $serviceUsageFormatted = if ($serviceUsage -and $serviceUsage -as [double]) { "{0:N2} USD" -f $serviceUsage } else { $serviceUsage }
            
            # Keep service name indented, align usage with subscription usage column
            Write-Host ("    {0,-62} {1,15}" -f $serviceName, $serviceUsageFormatted) -ForegroundColor Gray
        }
    } else {
        Write-Host ("    - $($entry.TopServices)") -ForegroundColor Yellow
    }
}


$totalUsage = ($results | Where-Object { $_.UsageUSD -is [double] } | Measure-Object -Property UsageUSD -Sum).Sum
if (-not $totalUsage) { $totalUsage = 0.0 }
$totalUsageRounded = [math]::Round($totalUsage, 2)
Write-Host "Total Azure consumption across all subscriptions: $totalUsageRounded USD" -ForegroundColor Green
