#!/bin/bash

# Period yyyy-mm-dd
startDate="2025-05-01"
endDate="2025-05-07"

# Log in to Azure
az login --only-show-errors

# Get access token
access_token=$(az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv)

# Get subscriptions
subscriptions=$(az account list --query '[].{id:id, name:name}' -o json)

# Initialize total cost
total=0
# Initialize associative array for subscription costs
declare -A sub_costs

# install required tools
#sudo apt install -y jq bc

# Loop through each subscription
while read -r sub; do
    subscriptionId=$(echo "$sub" | jq -r '.id')
    subscriptionName=$(echo "$sub" | jq -r '.name')

    echo "Processing subscription: $subscriptionName ($subscriptionId)" >&2

    # Define API URL
    apiVersion="2023-03-01"
    url="https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.CostManagement/query?api-version=$apiVersion"

    # Define request body
    body=$(jq -n --arg start "$startDate" --arg end "$endDate" '
    {
        type: "Usage",
        timeframe: "Custom",
        timePeriod: {
            from: $start,
            to: $end
        },
        dataset: {
            granularity: "Accumulated",
            aggregation: {
                totalCost: {
                    name: "CostUSD",
                    function: "Sum"
                }
            }
        }
    }')

     # Make API call
    response=$(curl -s -X POST "$url" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$body")

    cost=$(echo "$response" | jq '[.properties.rows[0][0]] | add // 0')
    sub_costs["$subscriptionName"]=$cost

    total=$(echo "$total + $cost" | bc)
done < <(echo "$subscriptions" | jq -c '.[]') 

# Print header
printf "Azure consumption report from $startDate to $endDate:\n"
printf "%-50s %10s\n" "Subscription" "Usage (USD)"
printf "%-50s %10s\n" "------------" "-----------"

for name in "${!sub_costs[@]}"; do
    echo -e "${sub_costs[$name]}\t$name"
done | sort -k1,1nr | while IFS=$'\t' read -r cost name; do
    printf "%-50s %10.2f\n" "$name" "$cost"
done

# Print total cost
echo ""
echo "Total Azure consumption across all subscriptions: $(printf "%.2f" "$total") USD"
