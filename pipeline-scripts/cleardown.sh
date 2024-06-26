#!/usr/bin/env bash
#set -x
##################˜Variables˜##################
oldIFS=$IFS
IFS=$'\n'
slack_channel=$2
resources_to_be_deleted=()
expired_group_with_resources=()
extensions='[
          {
              "name": "account"
          }
        ]'

##################˜Functions˜##################

function usage() {
  echo 'Usage: ./pipeline-scripts/cleardown.sh <--dry_run | --warn | --delete_resources>  <slack_webhook_for_sandbox-cleardown_channel> >'
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
        resources=$(az resource list --tag expiresAfter --query "[?(tags.expiresAfter<'${current_date}')]")
        while read resource 
        do
          if [[ -n $resource ]]
          then
            id=$(echo $resource | jq -r '.id' ) 
            name=$(echo $resource | jq -r '.name' ) 
            type=$(echo $resource | jq -r '.type' ) 
            rg=$(echo $resource | jq -r '.resourceGroup' )
            exp_date=$(echo $resource | jq -r '.tags.expiresAfter')
            temptext="${id}:${name}:${type}:${rg}:${subscription}:${exp_date}"
            deny_assignments=$(az rest --method get --uri ${id}/providers/Microsoft.Authorization/denyAssignments/8a45414b-28fb-554d-a376-977483ce694c/providers/Microsoft.Authorization/denyAssignments\?api-version\=2022-04-01  | jq -r '.value[]' )
            if [[ -z ${deny_assignments} ]]
            then
              resources_to_be_deleted+=($temptext)
            fi 
          fi
          
        done <<< $(jq -c '.[]' <<< $resources)

        # Working on groups
        groups=$(az group list --tag expiresAfter --query "[?(tags.expiresAfter<'${current_date}')]")
        for group in $(echo "${groups[@]}" | jq -c '.[]'); do
            # get list of expired resources in resource group
            rg_resources=$(az resource list --tag expiresAfter --query "[?(tags.expiresAfter>'${current_date}') && (resourceGroup=='$(echo $group | jq -r '.name')')]")
            if [[  $rg_resources = "[]" ]]; then
                exp_date=$(echo $group | jq -r '.tags.expiresAfter')
                temptext="$(echo $group | jq -r '.id'):$(echo $group | jq -r '.name'):'Microsoft.Resources/resourceGroups':$(echo $group | jq -r '.name'):$subscription:${exp_date}"
                deny_assignments=$(az rest --method get --uri $(echo $group | jq -r '.id')/providers/Microsoft.Authorization/denyAssignments/8a45414b-28fb-554d-a376-977483ce694c/providers/Microsoft.Authorization/denyAssignments\?api-version\=2022-04-01  | jq -r '.value[]' )
                if [[ -z ${deny_assignments} ]]
                then
                  resources_to_be_deleted+=($temptext)
                fi 
            elif [[ $rg_resources != "[]" ]]; then
                # RG contains non-expired resources
                echo "Resource group with id $(echo $group | jq -r '.id') in subscription $subscription still contains resources that are not expired"
                temptext="$(echo $group | jq -r '.id'):$(echo $group | jq -r '.name'):'Microsoft.Resources/resourceGroups':$(echo $group | jq -r '.name'):$subscription "
                expired_group_with_resources+=($temptext)
            fi
        done  #end of rg loop
    done
  }

##################˜End_of_Functions˜##################

if [[ "$1" ==  '--delete_resources' ]] && [[ $# -ne 2 ]] ||  [[ "$1" ==  '--warn' ]] && [[ $# -ne 2 ]] 
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
    resourcename=$(echo $resource | cut -d: -f2) 
    subscription=$(echo $resource | cut -d: -f5) 
    rg=$(echo $resource | cut -d: -f4) 
    type=$(echo $resource | cut -d: -f3)  
    id=$(echo $resource | cut -d: -f1)  
    log "Resourceid $resourcename of type $type in ResourceGroup $rg will be deleted from subscription $subscription " 
  done
fi

# 
if [[ "$1" ==  '--delete_resources' ]]
then
  get_expired_resources
  failed_to_delete=()
  messages=()
  for resource in "${resources_to_be_deleted[@]}"
  do
    resourcename=$(echo $resource | cut -d: -f2)
    subscription=$(echo $resource | cut -d: -f5)
    rg=$(echo $resource | cut -d: -f4)
    type=$(echo $resource | cut -d: -f3) 
    id=$(echo $resource | cut -d: -f1) 
    log "Resourceid $resourcename of type $type in ResourceGroup $rg will be deleted from subscription $subscription"
    #printf "az resource delete --ids $id \n" # remove printf
    sleep 30
    message=""
    message=$(az resource delete --ids $id --verbose 2>&1 && curl -X POST --data-urlencode "payload={\"channel\": \"#sandbox-cleardown\", \"username\": \"sandbox-auto-cleardown\", \"icon_emoji\": \":_ohmygod_:\",  \"blocks\": [{ \"type\": \"section\", \"text\": { \"type\": \"mrkdwn\", \"text\": \" *Deleted* Resource \`$resourcename\` of Type \`$type\` in ResourceGroup \`$rg\` from subscription \`$subscription\` \"}}]}"  ${slack_channel})
    if [[ $? -ne 0 ]]
    then
      failed_to_delete+=($resource)
      error_message=""
      error_message=$(echo "$message" | awk '/Message:/ {print substr($0, index($0,$2))}')
      messages+=("$error_message")
      echo ${#failed_to_delete[@]}
    fi
    
  done
  #List resources that failed to get deleted
  sleep 300
  count=0
  for resource in "${failed_to_delete[@]}"
  do
    resourcename=$(echo $resource | cut -d: -f2)
    subscription=$(echo $resource | cut -d: -f5)
    rg=$(echo $resource | cut -d: -f4)
    type=$(echo $resource | cut -d: -f3)
    log "Error: Unable to delete Resourcename $resourcename of type $type in ResourceGroup $rg from subscription $subscription \n" 
    curl -X POST --data-urlencode "payload={\"channel\": \"#sandbox-cleardown\", \"username\": \"sandbox-auto-cleardown\", \"icon_emoji\": \":danger_zone:\",  \"blocks\": [{ \"type\": \"section\", \"text\": { \"type\": \"mrkdwn\", \"text\": \" *Unable* to *Delete* Resource \`$resourcename\` of Type \`$type\` in ResourceGroup \`$rg\` from subscription \`$subscription\`. \n *Error Message:*   ${messages[$count]}  \"}}]}"  ${slack_channel}
    count=$((count + 1))
  done
fi


if [[ "$1" ==  '--warn' ]]
then
    warning=$(date -d "+5 days" +"%Y-%m-%d") # 5 days
    sec_current_date=$(date +%s -d $(date +"%Y-%m-%d"))  
    get_expired_resources  $warning
    sleep 300
    for resource in "${resources_to_be_deleted[@]}"
    do
        resourcename=$(echo $resource | cut -d: -f2)
        subscription=$(echo $resource | cut -d: -f5)
        rg=$(echo $resource | cut -d: -f4)
        type=$(echo $resource | cut -d: -f3)
        resource_exp_date=$(echo $resource | cut -d: -f6)
        sec_resource_date=$(date -d "$resource_exp_date" +%s)
        days=$(((sec_resource_date - sec_current_date)/86400)) 
        if [[ ${days} -ge  1 ]]
        then
          curl -X POST --data-urlencode "payload={\"channel\": \"#sandbox-cleardown\", \"username\": \"sandbox-auto-cleardown\", \"icon_emoji\": \":warning_triangle:\",  \"blocks\": [{ \"type\": \"section\", \"text\": { \"type\": \"mrkdwn\", \"text\": \" Resource \`$resourcename\` of Type \`$type\` in ResourceGroup \`$rg\` from subscription \`$subscription\` will be *deleted* in next * ${days} day(s)* \"}}]}"  ${slack_channel}
        fi
        
    done
    sleep 60 
    for group in "${expired_group_with_resources[@]}"
    do
        resourcename=$(echo $group | cut -d: -f2)
        subscription=$(echo $group | cut -d: -f5)
        rg=$(echo $group | cut -d: -f4)
        type=$(echo $group | cut -d: -f3)
        curl -X POST --data-urlencode "payload={\"channel\": \"#sandbox-cleardown\", \"username\": \"sandbox-auto-cleardown\", \"icon_emoji\": \":detective-pikachu:\",  \"blocks\": [{ \"type\": \"section\", \"text\": { \"type\": \"mrkdwn\", \"text\": \" ResourceGroup \`$rg\` from subscription \`$subscription\` has *expired* but still contains resources that are *not* expired. \"}}]}"  ${slack_channel}
    done
    
fi

