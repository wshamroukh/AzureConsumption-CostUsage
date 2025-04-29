#!/bin/bash

# Define period
startTime="2025-03-31"
endTime="2025-04-29"

# Log in to Azure
az login --only-show-errors

# Get access token
access_token=$(az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv) && echo $access_token

# Get subscriptions
subscriptions=$(az account list --query '[].{id:id, name:name}' -o json)

# Initialize total cost
total=0

# Print header
printf "%-50s %10s\n" "Subscription" "Usage (USD)"
printf "%-50s %10s\n" "------------" "-----------"
# install required tools
#sudo apt install -y jq bc
# Loop through each subscription
while read -r sub; do
    subscriptionId=$(echo "$sub" | jq -r '.id')
    subscriptionName=$(echo "$sub" | jq -r '.name')

    echo "Processing subscription: $subscriptionName ($subscriptionId)" >&2

    filter="properties/usageStart ge '$startTime' and properties/usageEnd le '$endTime'"
    encoded_filter=$(python3 -c "import urllib.parse; print(urllib.parse.quote(\"$filter\"))")
    url="https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Consumption/usageDetails?api-version=2024-08-01&%24filter=$encoded_filter"

    response=$(curl -s -X GET "$url" \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json")

    cost=$(echo "$response" | jq '[.value[].properties.costInUSD] | add // 0')
    printf "%-50s %10.2f\n" "$subscriptionName" "$cost"

    total=$(echo "$total + $cost" | bc)
done < <(echo "$subscriptions" | jq -c '.[]')

# Print total cost
echo ""
echo "Total Usage Across All Subscriptions: $(printf "%.2f" "$total") USD"
