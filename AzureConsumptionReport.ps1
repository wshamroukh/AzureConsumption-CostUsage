# Period yyyy-mm-dd
$startDate = "2025-04-01"
$endDate = "2025-04-30"

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
$tenantId = $subscriptions.TenantId[0]

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
Write-Output "\nUsage report from $startDate to $endDate for tenant ($tenantId):"
# Output the results in a table
$results | Format-Table -AutoSize

# Calculate and display total cost
$totalUsage = ($results | Where-Object { $_.UsageUSD -is [double] } | Measure-Object -Property UsageUSD -Sum).Sum
$totalUsageRounded = [math]::Round($totalUsage, 2)
Write-Output "Total Usage Across All Subscriptions under tenant ($tenantId): $totalUsageRounded USD"