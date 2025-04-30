# Period
$startTime = "2025-03-31"
$endTime = "2025-04-29"

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

    $simpleQueryUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Consumption/usageDetails?api-version=2024-08-01&`$filter=properties/usageStart ge '$startTime' and properties/usageEnd le '$endTime'"

    try {
        $usageResponse = Invoke-RestMethod -Uri $simpleQueryUrl -Method Get -Headers $headers
        if ($usageResponse.value -and $usageResponse.value.Count -gt 0) {
            $totalCost = ($usageResponse.value | ForEach-Object { $_.properties.costInUSD } | Measure-Object -Sum).Sum
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

# Output the results in a table
$results | Format-Table -AutoSize

# Calculate and display total cost
$totalUsage = ($results | Where-Object { $_.UsageUSD -is [double] } | Measure-Object -Property UsageUSD -Sum).Sum
$totalUsageRounded = [math]::Round($totalUsage, 2)
Write-Output "Total Usage Across All Subscriptions under tenant ($tenantId): $totalUsageRounded USD"