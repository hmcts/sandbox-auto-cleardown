oldIFS=$IFS
IFS=$'\n'

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
        echo "\nInstalling azure cli extensions..."
        az extension add --name $extension
    fi
done

subscriptions=$(az account subscription list --query "[?(contains(displayName, 'SBOX')) || (contains(displayName, 'Sandbox')) || (contains(displayName, 'sbox'))]"  --only-show-errors | jq -r '.[].displayName')

for subscription in $(echo "${subscriptions[@]}"); do

az account set -s $subscription

# get list of resources with expiresAfter tags with values dated in the past
resources=$(az resource list --tag expiresAfter --query "[?(tags.expiresAfter<'$(date +"%Y-%m-%d")') && (tags.expiresAfter!='0000-00-00') && (tags.expiresAfter!='never')]")

# used in dry-run
if [ "$resources" = "[]" ]; then
    echo "No resources are expired. Nothing to delete in $subscription"
fi

    for resource in $(echo "${resources[@]}" | jq -c '.[]'); do
        if [ "$1" = "--delete-expired" ]; then
            echo "Now deleting resource with id $(echo $resource | jq -r '.id')"
            # az resource delete $(echo $resource | jq -r '.id')
        else
            # show resources that are expired output during dry-run
            echo $(jq -n \
                    --arg subscription "$subscription" \
                    --arg resourceGroup "$(echo $resource | jq -r '.resourceGroup')" \
                    --arg name "$(echo $resource | jq -r '.name')" \
                    --arg resourceType "$(echo $resource | jq -r '.type')" \
                    '{subscription: $subscription, resourceGroup: $resourceGroup, resourceType: $resourceType, name: $name}' )
        fi
    done
done