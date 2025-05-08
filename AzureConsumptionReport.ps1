# reference script: https://github.com/yannickdils/TheFinOpsXFiles/blob/a82a9829915c9ae50fb60c3c089f2c8d73f29599/Budget%20vs%20Cost/Script/RetrieveConsumptionUpdate.ps1

function Get-DateInput($prompt) {
    while ($true) {
        $inputDate = Read-Host $prompt

        # Check if the input matches the pattern yyyy-mm-dd
        if ($inputDate -match '^\d{4}-\d{2}-\d{2}$') {
            try {
                # Try to parse the date to ensure it's valid
                $parsedDate = [datetime]::ParseExact($inputDate, 'yyyy-MM-dd', $null)
                return $parsedDate
            } catch {
                Write-Host "Invalid date. Please enter a valid date in yyyy-mm-dd format." -ForegroundColor Red
            }
        } else {
            Write-Host "Date format is incorrect. Use yyyy-mm-dd." -ForegroundColor Red
        }
    }
}

do {
    $startDate = Get-DateInput "Enter the start date (yyyy-mm-dd)"
    $endDate = Get-DateInput "Enter the end date (yyyy-mm-dd)"

    if ($startDate -ge $endDate) {
        Write-Host "Start date must be earlier than end date. Please try again." -ForegroundColor Yellow
    }
} while ($startDate -ge $endDate)

Write-Host "Valid date range selected:"
Write-Host "Start Date: $startDate"
Write-Host "End Date: $endDate"


# Connect to Azure account
#Connect-AzAccount

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
    Write-Output "Processing subscription: $subscriptionName ($subscriptionId)"

    $apiVersion = "2023-03-01"
    $simpleQueryUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.CostManagement/query?api-version=$apiVersion"
    
    # Build the request body
    $body = @{
        type = "Usage"
        timeframe = "Custom"
        timePeriod = @{
            from = $startDate
            to = $endDate
        }
        dataset = @{
            granularity = "Accumelated"
            aggregation = @{
                totalCost = @{
                    name = "CostUSD"
                    function = "Sum"
                }
            }
        }
    }

    # Convert body to JSON
    $bodyJson = $body | ConvertTo-Json -Depth 10

    try {
        $usageResponse = Invoke-RestMethod -Uri $simpleQueryUrl -Method Post -Body $bodyJson -Headers $headers
        if ($usageResponse.properties.rows -and $usageResponse.properties.rows.Count -gt 0) {
            $totalCost = $usageResponse.properties.rows[0][0]
            $roundedCost = [math]::Round($totalCost, 2)
        } else {
            $roundedCost = 0
        }
    } catch {
            Write-Output "Failed to retrieve usage for subscription $subscriptionName : $_"
            $roundedCost = "Error"
    }

    # Add result to array
    $results += [PSCustomObject]@{
        Subscription = $subscriptionName
        UsageUSD     = $roundedCost
    }
}
Write-Output "`nAzure consumption report from $startDate to $($endDate):"
# Output the results in a table
$results | Sort-Object UsageUSD -Descending | Format-Table -AutoSize

# Calculate and display total cost
$totalUsage = ($results | Where-Object { $_.UsageUSD -is [double] } | Measure-Object -Property UsageUSD -Sum).Sum
$totalUsageRounded = [math]::Round($totalUsage, 2)
Write-Output "Total Azure consumption across all subscriptions: $totalUsageRounded USD"