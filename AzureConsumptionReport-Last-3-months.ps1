# Connect to Azure (uncomment if not already connected)
# Connect-AzAccount

# Get access token for Azure REST API
$secureToken = (Get-AzAccessToken -AsSecureString -ResourceUrl "https://management.azure.com/").Token
$ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# Get all subscriptions
$subscriptions = Get-AzSubscription
$apiVersion = "2023-03-01"

# Generate the last three full months (relative to today)
$months = @()
for ($i = 3; $i -ge 1; $i--) {
    $monthStart = (Get-Date -Day 1).AddMonths(-$i)
    $monthEnd = $monthStart.AddMonths(1).AddDays(-1)
    $months += [PSCustomObject]@{
        Name = $monthStart.ToString("MMM yyyy")
        StartDate = $monthStart.ToString("yyyy-MM-dd")
        EndDate = $monthEnd.ToString("yyyy-MM-dd")
    }
}

Write-Host "Generating Azure usage report for the last three months..." -ForegroundColor Cyan
Write-Host ($months | Format-Table | Out-String)

$results = @()

foreach ($subscription in $subscriptions) {
    $subscriptionId = $subscription.Id
    $subscriptionName = $subscription.Name
    Write-Host "`nProcessing subscription: $subscriptionName ($subscriptionId)" -ForegroundColor Blue

    $monthCosts = @{}

    foreach ($month in $months) {
        $body = @{
            type = "Usage"
            timeframe = "Custom"
            timePeriod = @{
                from = $month.StartDate
                to   = $month.EndDate
            }
            dataset = @{
                granularity = "None"
                aggregation = @{
                    totalCost = @{
                        name = "CostUSD"
                        function = "Sum"
                    }
                }
            }
        }

        $bodyJson = $body | ConvertTo-Json -Depth 10
        $queryUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.CostManagement/query?api-version=$apiVersion"

        try {
            $usageResponse = Invoke-RestMethod -Uri $queryUrl -Method Post -Body $bodyJson -Headers $headers
            if ($usageResponse.properties.rows -and $usageResponse.properties.rows.Count -gt 0) {
                $totalCost = [math]::Round($usageResponse.properties.rows[0][0], 2)
            } else {
                $totalCost = 0
            }
        } catch {
            Write-Host "Failed to retrieve usage for $($month.Name): $_" -ForegroundColor Red
            $totalCost = "Error"
        }

        $monthCosts[$month.Name] = $totalCost
        Write-Host "  $($month.Name): $totalCost USD" -ForegroundColor Yellow
    }

    # Build a row with all 3 months' data
    $results += [PSCustomObject]@{
        Subscription = $subscriptionName
        ($months[0].Name) = $monthCosts[$months[0].Name]
        ($months[1].Name) = $monthCosts[$months[1].Name]
        ($months[2].Name) = $monthCosts[$months[2].Name]
    }
}

Write-Host "`nAzure consumption trend for the last 3 months:" -ForegroundColor Green
$results | Format-Table -AutoSize

# Optional: Calculate total usage across all subscriptions for each month
$totalRow = [PSCustomObject]@{
    Subscription = "TOTAL"
}
foreach ($month in $months) {
    $totalRow | Add-Member -NotePropertyName $month.Name -NotePropertyValue (
        ($results | Where-Object { $_.$($month.Name) -is [double] } |
         Measure-Object -Property $($month.Name) -Sum).Sum
    )
}
$results += $totalRow

Write-Host "`nOverall total usage (USD):" -ForegroundColor Cyan
$results | Format-Table -AutoSize
