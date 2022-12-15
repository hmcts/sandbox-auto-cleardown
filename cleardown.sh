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

if [ "$resources" = "[]" ]; then
    echo "No resources are expired. Nothing to delete in $subscription"
fi

    for resource in $(echo "${resources[@]}" | jq -c '.[]'); do
        if [ "$1" = "--delete-expired" ]; then
            echo "Now deleting resource with id $(echo $resource | jq -r '.id')"
            az resource delete --ids $(echo $resource | jq -r '.id')
        else
            # show resources that are expired during dry-run
            echo "The resource $(echo $resource | jq -r '.id') will be deleted from the $subscription subscription"
        fi
    done

# get list of resource groups with expiresAfter tags with values dated in the past
groups=$(az group list --tag expiresAfter --query "[?(tags.expiresAfter<'$(date +"%Y-%m-%d")') && (tags.expiresAfter!='never')]")

if [ "$groups" = "[]" ]; then
    echo "No resource groups are expired. Nothing to delete in $subscription"
fi

    for group in $(echo "${groups[@]}" | jq -c '.[]'); do
        
        # get list of expired resources in resource group
        rg_resources=$(az resource list --tag expiresAfter --query "[?(tags.expiresAfter>'$(date +"%Y-%m-%d")') && (tags.expiresAfter!='never') && (resourceGroup=='$(echo $group | jq -r '.name')')]")
        
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