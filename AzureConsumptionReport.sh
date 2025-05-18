#!/bin/bash
# Get today's date in seconds since epoch
today=$(date +%Y-%m-%d)
today_sec=$(date +%s)

# Function to validate date format, ensure it's not in the future, and convert to seconds
get_date_input() {
    local prompt="$1"
    local input date_seconds

    while true; do
        read -p "$prompt (yyyy-mm-dd): " input

        # Validate format using regex
        if [[ $input =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            # Try to parse the date
            if date_seconds=$(date -d "$input" +%s 2>/dev/null); then
                if (( date_seconds <= today_sec )); then
                    echo "$input|$date_seconds"
                    return
                else
                    echo -e "\e[1;31mDate cannot be in the future. Please enter a valid past or today's date.\e[0m" >&2
                fi
            else
                echo -e "\e[1;31mInvalid date. Please enter a valid calendar date.\e[0m" >&2
            fi
        else
            echo -e "\e[1;31mIncorrect format. Please use yyyy-mm-dd.\e[0m" >&2
        fi
    done
}

# Function to ask user if they want to use today's date as end date
get_end_date_input() {
    local choice
    while true; do
        read -p "Do you want to use today's date as the end date? (Y/N): " choice
        case "$choice" in
            [Yy])
                echo "$today|$today_sec"
                return
                ;;
            [Nn])
                get_date_input "Enter the end date"
                return
                ;;
            *)
                echo -e "\e[1;33mPlease enter Y or N.\e[0m" >&2
                ;;
        esac
    done
}

while true; do
    start_input=$(get_date_input "Enter the start date")
    end_input=$(get_end_date_input)

    startDate="${start_input%%|*}"
    start_sec="${start_input##*|}"

    endDate="${end_input%%|*}"
    end_sec="${end_input##*|}"

    if (( start_sec < end_sec )); then
        break
    else
        echo -e "\e[1;31mStart date must be earlier than end date. Please try again.\e[0m" >&2
    fi
done

echo -e "\e[1;34mAzure Consumption report will be generated from $startDate till $endDate\e[0m"

# Log in to Azure
#az login --only-show-errors

# Get access token
token=$(az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv)

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

    echo -e "\e[1;35mProcessing subscription: $subscriptionName ($subscriptionId)\e[0m" >&2

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
echo -e "\e[1;36mTotal Azure consumption across all subscriptions: $(printf "%.2f" "$total") USD\e[0m"
