# reference script: https://github.com/yannickdils/TheFinOpsXFiles/blob/a82a9829915c9ae50fb60c3c089f2c8d73f29599/Budget%20vs%20Cost/Script/RetrieveConsumptionUpdate.ps1

# Period yyyy-mm-dd
$startDate = "2025-04-01"
$endDate = "2025-05-07"

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
    
    # Modified request body to group by ServiceFamily
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
                    name = "PreTaxCost"
                    function = "Sum"
                }
            }
            grouping = @(
                @{
                    type = "Dimension"
                    name = "ServiceFamily"
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
            $serviceFamilyIndex = $usageResponse.properties.columns.name.IndexOf("ServiceFamily")
            $costIndex = $usageResponse.properties.columns.name.IndexOf("PreTaxCost")
            
            $serviceCosts = @{}
            foreach ($row in $usageResponse.properties.rows) {
                $serviceFamily = $row[$serviceFamilyIndex]
                $cost = $row[$costIndex]
                $totalCost += $cost
                if ($serviceFamily) {
                    $serviceCosts[$serviceFamily] += $cost
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

Write-Output "`nAzure consumption report from $startDate to $($endDate):"
$results | Sort-Object UsageUSD -Descending | Format-Table -AutoSize -Property Subscription, UsageUSD, TopServices

$totalUsage = ($results | Where-Object { $_.UsageUSD -is [double] } | Measure-Object -Property UsageUSD -Sum).Sum
$totalUsageRounded = [math]::Round($totalUsage, 2)
Write-Output "Total Azure consumption across all subscriptions: $totalUsageRounded USD"
