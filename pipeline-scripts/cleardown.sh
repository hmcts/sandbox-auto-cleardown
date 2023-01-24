#!/usr/bin/env bash
set -e
##################˜Variables˜##################
oldIFS=$IFS
IFS=$'\n'
slack_greendailycheck_channel=$2
slack_platopsbuildnotices_channel=$3
resources_to_be_deleted=()
expired_group_with_resources=()
extensions='[
          {
              "name": "account"
          }
        ]'

##################˜Functions˜##################

function usage() {
  echo 'Usage: ./cleardown.sh <--dry_run | --warn | --delete_resources>  <slack_webhook_for_green_daily_check_channel> <slack_webhook_for_platops_build_notices_channel>'
}

log() {
    date +"%H:%M:%S $(printf "%s "  "$@")"
}

install_extension() {
    # check required az extensions are installed
    printf "Adding required extensions "
    az config set extension.use_dynamic_install=yes_without_prompt
    for extension in $(echo "${extensions[@]}" | jq -r '.[].name'); do
        AZ_EXTENSION=$(az extension list --query "[?name=='${extension}']")
        if [ "$AZ_EXTENSION" = "[]" ]; then
            echo -e "\nInstalling azure cli extensions $extension..."
            az extension add --name $extension -y
        fi
    done

}

get_expired_resources() {
    current_date=${1:-$(date +"%Y-%m-%d")}
    echo $current_date 
    subscriptions=$(az account subscription list --query "[?(contains(displayName, 'SBOX')) || (contains(displayName, 'Sandbox')) || (contains(displayName, 'sbox'))]"  --only-show-errors | jq -r '.[].displayName')
    for subscription in $(echo "${subscriptions[@]}"); do
        az account set -s "${subscription}"
        printf "\n%s\n" "Checking  subscription: $subscription"
        resources=$(az resource list --tag expiresAfter --query "[?(tags.expiresAfter<'${current_date}')]" | jq -r '.[].id')
        resources_to_be_deleted+=($resources)
        # Working on groups
        groups=$(az group list --tag expiresAfter --query "[?(tags.expiresAfter<'${current_date}')]")
        for group in $(echo "${groups[@]}" | jq -c '.[]'); do
            # get list of expired resources in resource group
            rg_resources=$(az resource list --tag expiresAfter --query "[?(tags.expiresAfter>'${current_date}') && (resourceGroup=='$(echo $group | jq -r '.name')')]")
            if [[  $rg_resources = "[]" ]]; then
                resources_to_be_deleted+=($(echo $group | jq -r '.id'))
            elif [[ $rg_resources != "[]" ]]; then
                # RG contains non-expired resources
                echo "Resource group with id $(echo $group | jq -r '.id') in subscription $subscription still contains resources that are not expired"
                expired_group_with_resources+=($(echo $group | jq -r '.id'))
            fi
        done  #end of rg loop
    done
  }

##################˜End_of_Functions˜##################

if [[ "$1" ==  '--delete_resources' ]] && [[ $# -ne 3 ]] ||  [[ "$1" ==  '--warn' ]] && [[ $# -ne 3 ]] 
then
    usage
    exit 1
fi

# install extensions
install_extension

# dry-run to get the list of resources that can be deleted.
if [[ $1 == '--dry-run' ]]
then
  get_expired_resources
#   echo "${#resources_to_be_deleted[@]}"
  for resource in "${resources_to_be_deleted[@]}"
  do
    subscription=$(az account show -s $(echo $resource | cut -d/ -f3) | jq '.name')
    printf "Resourceid \"%s\" will be deleted from subscription %s\n"  $resource $subscription
  done
fi

# 
if [[ "$1" ==  '--delete_resources' ]]
then
  get_expired_resources
  for resource in "${resources_to_be_deleted[@]}"
  do
    subscription=$(az account show -s $(echo $resource | cut -d/ -f3) | jq -r '.name')
    log "Resourceid $resource will in deleted in subscription $subscription"
    printf "az resource delete --ids $resource --no-wait \n" # remove printf
    az resource delete --ids $resource --no-wait
  
    #modify slack channel 
    curl -X POST --data-urlencode "payload={\"channel\": \"#slack_msg_format_testing\", \"username\": \"sandbox-auto-cleardown\", \"text\": \"Deleted Resource: $resource  in subscription $subscription .\", \"icon_emoji\": \":tim-webster:\"}"   $slack_greendailycheck_channel

    #curl -X POST --data-urlencode "payload={\"channel\": \"#green-daily-checks\", \"username\": \"sandbox-auto-cleardown\", \"text\": \"Deleted Resource: $resource  in subscription $subscription .\", \"icon_emoji\": \":tim-webster:\"}"   $slack_greendailycheck_channel
    #curl -X POST --data-urlencode "payload={\"channel\": \"#platops-build-notices\", \"username\": \"sandbox-auto-cleardown\", \"text\": \"Deleted Resource: $resource  in subscription $subscription .\", \"icon_emoji\": \":tim-webster:\"}"   $slack_platopsbuildnotices_channel
  done
fi


if [[ "$1" ==  '--warn' ]]
then
    warning=$(date -v +5d +"%Y-%m-%d") # 5 days 
    get_expired_resources  $warning
    for resource in "${resources_to_be_deleted[@]}"
    do
        subscription=$(az account show -s $(echo $resource | cut -d/ -f3) | jq -r '.name')
        #modify slack channel 
        curl -X POST --data-urlencode "payload={\"channel\": \"#slack_msg_format_testing\", \"username\": \"sandbox-auto-cleardown\", \"text\": \" Resource: $resource  in subscription $subscription will be delete in next 5 days.\", \"icon_emoji\": \":sign-warning:\"}"  $slack_greendailycheck_channel
        #curl -X POST --data-urlencode "payload={\"channel\": \"#green-daily-checks\", \"username\": \"sandbox-auto-cleardown\", \"text\": \" Resource: $resource   in subscription $subscription will be delete in next 5 days.\", \"icon_emoji\": \":sign-warning:\"}"  $slack_greendailycheck_channel
        #curl -X POST --data-urlencode "payload={\"channel\": \"#platops-build-notices\", \"username\": \"sandbox-auto-cleardown\", \"text\": \" Resource: $resource   in subscription $subscription will be delete in next 5 days.\", \"icon_emoji\": \":sign-warning:\"}"  $slack_platopsbuildnotices_channel   
    done
    for group in "${expired_group_with_resources[@]}"
    do
        subscription=$(az account show -s $(echo $resource | cut -d/ -f3) | jq -r '.name')
        curl -X POST --data-urlencode "payload={\"channel\": \"#slack_msg_format_testing\", \"username\": \"sandbox-auto-cleardown\", \"text\": \" Resource Group: $resource in subscription $subscription has expired but still contains resources that are not expired.\", \"icon_emoji\": \":detective-pikachu:\"}"  $slack_greendailycheck_channel
    done
fi

