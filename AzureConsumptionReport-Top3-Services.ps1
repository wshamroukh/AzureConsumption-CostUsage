# reference script: https://github.com/yannickdils/TheFinOpsXFiles/blob/a82a9829915c9ae50fb60c3c089f2c8d73f29599/Budget%20vs%20Cost/Script/RetrieveConsumptionUpdate.ps1

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
    $datePicker.MaxDate = [datetime]::Today  # ✅ Prevent future dates
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


function Get-EndDate {
    while ($true) {
        $useToday = Read-Host "Do you want to use today's date as the end date? (Y/N)"
        if ($useToday -match '^[Yy]$') {
            return [datetime]::Today
        } elseif ($useToday -match '^[Nn]$') {
            return Get-DateInputGUI
        } else {
            Write-Host "Please enter Y for yes or N for no." -ForegroundColor Yellow
        }
    }
}

do {
    $startDate = Show-DatePicker -Title "Start Date Selection" -Message "Please select the start date"
    $endDate   = Show-DatePicker -Title "End Date Selection" -Message "Please select the end date"

    if ($startDate -ge $endDate) {
        Write-Host "Start date must be earlier than end date. Please try again." -ForegroundColor Red
    }
} while ($startDate -ge $endDate)

Write-Host "Azure Consumption report will be generated from $startDate till $endDate" -ForegroundColor Cyan

# Connect to Azure account
Connect-AzAccount

# Get token for ARM
$secureToken = (Get-AzAccessToken -AsSecureString -ResourceUrl "https://management.azure.com/").Token
$ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)

# Set headers
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

# Get all subscriptions
$subscriptions = Get-AzSubscription

# Prepare an array to store the results
$results = @()

foreach ($subscription in $subscriptions) {
    $subscriptionId = $subscription.Id
    $subscriptionName = $subscription.Name
    Write-Host "Processing subscription: $subscriptionName ($subscriptionId)" -ForegroundColor Magenta

    $apiVersion = "2023-03-01"
    $simpleQueryUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.CostManagement/query?api-version=$apiVersion"
    
    # Modified request body to group by serviceName
    $body = @{
        type = "Usage"
        timeframe = "Custom"
        timePeriod = @{
            from = $startDate
            to = $endDate
        }
        dataset = @{
            granularity = "None"
            aggregation = @{
                totalCost = @{
                    name = "CostUSD"
                    function = "Sum"
                }
            }
            grouping = @(
                @{
                    type = "Dimension"
                    name = "ServiceName"
                }
            )
        }
    }

    $bodyJson = $body | ConvertTo-Json -Depth 10

    try {
        $usageResponse = Invoke-RestMethod -Uri $simpleQueryUrl -Method Post -Body $bodyJson -Headers $headers
        $totalCost = 0
        $topServices = @()
        
        if ($usageResponse.properties.rows -and $usageResponse.properties.rows.Count -gt 0) {
            $serviceNameIndex = $usageResponse.properties.columns.name.IndexOf("ServiceName")
            $costIndex = $usageResponse.properties.columns.name.IndexOf("CostUSD")
            
            $serviceCosts = @{}
            foreach ($row in $usageResponse.properties.rows) {
                $serviceName = $row[$serviceNameIndex]
                $cost = $row[$costIndex]
                $totalCost += $cost
                if ($serviceName) {
                    $serviceCosts[$serviceName] += $cost
                }
            }
            
            $topServices = $serviceCosts.GetEnumerator() | 
                Sort-Object Value -Descending | 
                Select-Object -First 3 | 
                ForEach-Object { 
                    "$($_.Key): $([math]::Round($_.Value, 2)) USD" 
                }
        }
        
        $roundedCost = [math]::Round($totalCost, 2)
        $topServicesString = if ($topServices.Count -gt 0) { $topServices -join ", " } else { "No data" }

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
$results | Sort-Object UsageUSD -Descending | Format-Table -AutoSize -Property Subscription, UsageUSD, TopServices

$totalUsage = ($results | Where-Object { $_.UsageUSD -is [double] } | Measure-Object -Property UsageUSD -Sum).Sum
$totalUsageRounded = [math]::Round($totalUsage, 2)
Write-Host "Total Azure consumption across all subscriptions: $totalUsageRounded USD" -ForegroundColor Green
