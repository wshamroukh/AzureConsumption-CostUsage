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

# ==============================
# OUTPUT FILE
# ==============================
$outputFile = "C:\temp\DailyUsagePerResource.csv"

if (Test-Path $outputFile) { Remove-Item $outputFile }

Write-Host "`nGenerating daily usage per resource..." -ForegroundColor Cyan

# ==============================
# GET TOKEN
# ==============================
$secureToken = (Get-AzAccessToken -AsSecureString -ResourceUrl "https://management.azure.com/").Token
$ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# ==============================
# GET ALL SUBSCRIPTIONS
# ==============================
$subscriptions = Get-AzSubscription
$rows = @()

# ==============================
# LOOP THROUGH SUBSCRIPTIONS
# ==============================
foreach ($sub in $subscriptions) {

    Write-Host "`nProcessing subscription: $($sub.Name)" -ForegroundColor Yellow

    $queryUrl = "https://management.azure.com/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement/query?api-version=2023-03-01"

    # DAILY USAGE QUERY
    $body = @{
        type = "Usage"
        timeframe = "Custom"
        timePeriod = @{
            from = $startDate
            to   = $endDate
        }
        dataset = @{
            granularity = "Daily"
            aggregation = @{
                CostUSD = @{
                    name     = "Cost"
                    function = "Sum"
                }
            }
            grouping = @(
                @{ type = "Dimension"; name = "ResourceId" },
                @{ type = "Dimension"; name = "ResourceType" },
                @{ type = "Dimension"; name = "ResourceLocation" },
                @{ type = "Dimension"; name = "ResourceGroupName" },
                @{ type = "Dimension"; name = "ServiceName" },
                @{ type = "Dimension"; name = "Meter" }
            )
        }
    } | ConvertTo-Json -Depth 12


    # EXECUTE REQUEST
    $response = Invoke-RestMethod -Uri $queryUrl -Method Post -Headers $headers -Body $body

    if (-not $response.properties.rows) {
        Write-Host "  → No usage found." -ForegroundColor DarkGray
        continue
    }

    # BUILD COLUMN MAP
    $colIndex = @{}
    for ($i = 0; $i -lt $response.properties.columns.Count; $i++) {
        $colIndex[$response.properties.columns[$i].name] = $i
    }

    # ==============================
    # Add Subscription Name into each row
    # ==============================
    foreach ($r in $response.properties.rows) {

        $rows += [PSCustomObject]@{
            SubscriptionName   = $sub.Name
            UsageDate          = $r[$colIndex["UsageDate"]]
            ResourceId         = $r[$colIndex["ResourceId"]]
            ResourceType       = $r[$colIndex["ResourceType"]]
            ResourceLocation   = $r[$colIndex["ResourceLocation"]]
            ResourceGroupName  = $r[$colIndex["ResourceGroupName"]]
            ServiceName        = $r[$colIndex["ServiceName"]]
            Meter              = $r[$colIndex["Meter"]]
            CostUSD            = [math]::Round([double]$r[$colIndex["Cost"]], 4)
        }
    }
}

# ==============================
# EXPORT TO CSV
# ==============================
$rows |
    Sort-Object SubscriptionName, UsageDate, ResourceId |
    Export-Csv -Path $outputFile -NoTypeInformation

Write-Host "`nCSV generated successfully:" -ForegroundColor Green
Write-Host $outputFile -ForegroundColor Cyan

