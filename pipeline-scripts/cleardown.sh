oldIFS=$IFS
IFS=$'\n'

slack_bot_token=$2
# slack_channel=green_daily_checks
slack_channel=test-notification


# Send a notification to a slack channel informing users of resources that are close to 
# or have been deleted. The function expects a single argument of the id of the resource being deleted.

send_notification() {
    resource_ids=$1
    subscription=$2
    
    resource_list=$resource_ids[]
    echo "resources to be deleted=${resource_ids[@]}"
    printf -v message_data "{\"channel\":\"%s\",\"blocks\":[{\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":\"Subscription %s\nResources with the Resource IDs of \`%s\` are going to be deleted.\"}}]}" "${slack_channel}" "${subscription_id}" "${resource_ids}"

    curl -H "Content-type: application/json" \
    --data "$message_data" \
    -H "Authorization: Bearer ${slack_bot_token}" \
    -X POST https://slack.com/api/chat.postMessage

}




# by default the script will assume you want a dry-run to see what resources will be deleted
# pass the `--delete-expired` argument to initiate terraform import

if [ "$1" != "--delete-expired" ]; then
echo "This is a dry-run\nAppend --delete-expired to delete resources that are expired\nResources to be deleted will show in the JSON output below"
fi

if [ "$1" = "--delete-expired" ]; then
    echo "You have specified the --delete-expired flag. This will delete all resources whose expiresAfter tag has a value dated in the past\nRemove this flag to perform a dry-run"
    read -n1 -p "Do you wish to delete the expired resources? [y,n]" input 

    if [[ $input == "Y" || $input == "y" ]]; then
        echo "\nDeleting expired resources"
    else
        echo "\nYou have selected no. Exiting..."
        exit 1
    fi
fi

# check required az extensions are installed
extensions='[
        {
            "name": "account"
        }
    ]'

for extension in $(echo "${extensions[@]}" | jq -r '.[].name'); do
    AZ_EXTENSION=$(az extension list --query "[?name=='${extension}']")
    if [ "$AZ_EXTENSION" = "[]" ]; then
        echo -e "\nInstalling azure cli extensions $extension..."
        az extension add --name $extension
    fi
done

az account subscription list --query "[?(contains(displayName, 'SBOX')) || (contains(displayName, 'Sandbox')) || (contains(displayName, 'sbox'))]"  --only-show-errors | jq -r '.[].displayName'
echo subscriptions=$(az account subscription list --query "[?(contains(displayName, 'SBOX')) || (contains(displayName, 'Sandbox')) || (contains(displayName, 'sbox'))]"  --only-show-errors | jq -r '.[].displayName')
subscriptions=$(az account subscription list --query "[?(contains(displayName, 'SBOX')) || (contains(displayName, 'Sandbox')) || (contains(displayName, 'sbox'))]"  --only-show-errors | jq -r '.[].displayName')

for subscription in $(echo "${subscriptions[@]}"); do

resources_to_be_deleted=()


az account set -s "${subscription}"

# get list of resources with expiresAfter tags with values dated in the past
resources=$(az resource list --tag expiresAfter --query "[?(tags.expiresAfter<'$(date +"%Y-%m-%d")')]")

if [ "$resources" = "[]" ]; then
    echo "No resources are expired. Nothing to delete in $subscription"
fi

    for resource in $(echo "${resources[@]}" | jq -c '.[]'); do
        resource_id=$(echo "${resource}" | jq -r '.id')
        
        if [ "$1" = "--delete-expired" ]; then
            echo "Now deleting resource with id ${resource_id}"
            az resource delete --ids "${resource_id}"

            resources_to_be_deleted+=("${resource_id}")
        else
            # show resources that are expired during dry-run
            echo "The resource $(echo $resource | jq -r '.id') will be deleted from the $subscription subscription"
            resources_to_be_deleted+=("${resource_id}")
        fi
    done

    if [[ ${#resources_to_be_deleted[@]} -gt 0 ]]; then
        echo "number of resources to be be delete is: ${#resources_to_be_deleted[@]}"
        send_notification "${resources_to_be_deleted[@]}" "${subscription}"
    fi
# get list of resource groups with expiresAfter tags with values dated in the past
groups=$(az group list --tag expiresAfter --query "[?(tags.expiresAfter<'$(date +"%Y-%m-%d")')]")

if [ "$groups" = "[]" ]; then
    echo "No resource groups are expired. Nothing to delete in $subscription"
fi

    for group in $(echo "${groups[@]}" | jq -c '.[]'); do
        
        # get list of expired resources in resource group
        rg_resources=$(az resource list --tag expiresAfter --query "[?(tags.expiresAfter>'$(date +"%Y-%m-%d")') && (resourceGroup=='$(echo $group | jq -r '.name')')]")
        
        if [[ "$1" = "--delete-expired" && $rg_resources = "[]" ]]; then
        
            # delete resource group if no non-expired resources remain
            echo "Now deleting resource group with id $(echo $group | jq -r '.id')"
            az group delete --name $(echo $group | jq -r '.name') --yes
        
        elif [[ "$1" = "--delete-expired" && $rg_resources != "[]" ]]; then
        
            # show message saying resource group cannot be deleted because it contains non-expired resources
            echo "Cannot delete resource group with id $(echo $group | jq -r '.id') as it is still contains resources that are not expired"
        
        elif [[ "$1" != "--delete-expired" && $rg_resources = "[]" ]]; then
        
            # show expired resource groups that contain no non-expired resources during dry-run
            echo "The resource group $(echo $group | jq -r '.name') is expired and contains no non-expired resources. It will be deleted from the $subscription subscription"
        
        elif [[ "$1" != "--delete-expired" && $rg_resources != "[]" ]]; then
        
            # show expired resource groups that contain non-expired resources during dry-run
            echo "The resource group $(echo $group | jq -r '.name') is expired but it contains non-expired resources. This resource group will not be deleted until all resources have expired"
        fi
    done
done
