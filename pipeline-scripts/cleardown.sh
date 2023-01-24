#!/usr/bin/env bash
set -e
##################˜Variables˜##################
oldIFS=$IFS
IFS=$'\n'
slack_greendailycheck_channel=$2
slack_platopsbuildnotices_channel=$3
resources_to_be_deleted=() 
extensions='˜
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
    for extension in $(echo "${extensions[@]}" | jq -r '.[].name'); do
        AZ_EXTENSION=$(az extension list --query "[?name=='${extension}']")
        if [ "$AZ_EXTENSION" = "[]" ]; then
            echo -e "\nInstalling azure cli extensions $extension..."
            az extension add --name $extension
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
        groups=$(az group list --tag expiresAfter --query "[?(tags.expiresAfter<'$(date +"%Y-%m-%d")')]")
        for group in $(echo "${groups[@]}" | jq -c '.[]'); do
            # get list of expired resources in resource group
            rg_resources=$(az resource list --tag expiresAfter --query "[?(tags.expiresAfter>'$(date +"%Y-%m-%d")') && (resourceGroup=='$(echo $group | jq -r '.name')')]")
            if [[  $rg_resources = "[]" ]]; then
                resources_to_be_deleted+=($(echo $group | jq -r '.id'))
            elif [[ $rg_resources != "[]" ]]; then
                # RG contains non-expired resources
                echo "Resource group with id $(echo $group | jq -r '.id')in subscription $subscription as it is still contains resources that are not expired"
            fi
        done  #end of rg loop
    done
  }

##################˜End_of_Functions˜##################

# install extensions
# install_extension


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
if [[ "$1" ==  '--delete_resources' ]] && [[ $# -eq 3 ]]
then
  get_expired_resources
  for resource in "${resources_to_be_deleted[@]}"
  do
    subscription=$(az account show -s $(echo $resource | cut -d/ -f3) | jq -r '.name')
    log "Resourceid $resource will in deleted in subscription $subscription"
    printf "az resource delete --ids $resource --no-wait \n" # remove printf
    #modify slack channel 
    curl -X POST --data-urlencode "payload={\"channel\": \"#slack_msg_format_testing\", \"username\": \"sandbox-auto-cleardown\", \"text\": \"Deleted Resource: $resource  in subscription $subscription .\", \"icon_emoji\": \":tim-webster:\"}"  "https://hooks.slack.com/services/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" 
    curl -X POST --data-urlencode "payload={\"channel\": \"#slack_msg_format_testing\", \"username\": \"sandbox-auto-cleardown\", \"text\": \"Deleted Resource: $resource  in subscription $subscription .\", \"icon_emoji\": \":tim-webster:\"}" "https://hooks.slack.com/services/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"  
  done
fi

echo "$#"
if [[ "$1" ==  '--warn' ]] && [[ $# -eq 3 ]]
then
    warn_date=$(date -v +5d +"%Y-%m-%d") # 5 days 
    get_expired_resources  $warn_date
    for resource in "${resources_to_be_deleted[@]}"
    do
        subscription=$(az account show -s $(echo $resource | cut -d/ -f3) | jq -r '.name')
        #modify slack channel 
        curl -X POST --data-urlencode "payload={\"channel\": \"#slack_msg_format_testing\", \"username\": \"sandbox-auto-cleardown\", \"text\": \" Resource: $resource  in subscription $subscription will be delete in next 5 days.\", \"icon_emoji\": \":sign-warning:\"}"  "https://hooks.slack.com/services/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" 
        curl -X POST --data-urlencode "payload={\"channel\": \"#slack_msg_format_testing\", \"username\": \"sandbox-auto-cleardown\", \"text\": \" Resource: $resource  in subscription $subscription will be delete in next 5 days .\", \"icon_emoji\": \":sign-warning:\"}" "https://hooks.slack.com/services/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"  
    done
fi


