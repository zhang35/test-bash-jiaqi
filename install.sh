#!/usr/bin/env bash
set -o errexit
set -o pipefail

yell() { echo "$0: $*" >&2; }
die() { yell "$*"; exit 111; }

function stackSetOperationWait {
  local cmd="aws cloudformation describe-stack-set-operation --region ${1?} --stack-set-name ${2?} --operation-id ${3?}"
  $cmd
  printf "Waiting for the above operation to finish..."
  while true; do
    sleep 5
    local end_timestamp="$($cmd --query "StackSetOperation.EndTimestamp" --output text)"
    if [ "${end_timestamp}" != "None" ]; then
      printf "\nOperation finished:\n"
      break
    fi
    printf '.'
  done
  $cmd
  local status="$($cmd --query "StackSetOperation.Status" --output text)"
  if [ "${status?}" != "SUCCEEDED" ]; then
    echo "StackSet operation did not succeed. Stack instances:"
    aws cloudformation list-stack-instances --stack-set-name "${1?}"
    exit 1
  fi
}

FULL_ORGANIZATION=false
CW_ROLE_EXISTS=false

while getopts ":i:r:oc" option; do
  case "$option" in
    i)
      FORMACLOUD_ID="$OPTARG"
      ;;
    r)
      REGIONS="$OPTARG"
      ;;
    o)
      FULL_ORGANIZATION=true
      ;;
    c)
      CW_ROLE_EXISTS=true
      ;;
    \?)
      echo "Usage: $0 [-i FORMACLOUD_ID] [-p FORMACLOUD_PRINCIPAL] [-t FORMACLOUD_EXTERNALID] [-e FORMACLOUD_EVENT_BUS_ARN] [-r REGIONS] [-o] [-c]"
      exit 1
      ;;
  esac
done

test -n "$FORMACLOUD_ID" || die "FORMACLOUD_ID must be provided. Please contact FormaCloud support."
test -n "$FORMACLOUD_PRINCIPAL" || die "FORMACLOUD_PRINCIPAL must be provided. Please contact FormaCloud support."
test -n "$FORMACLOUD_EXTERNALID" || die "FORMACLOUD_EXTERNALID must be provided. Please contact FormaCloud support."
test -n "$FORMACLOUD_EVENT_BUS_ARN" || die "FORMACLOUD_EVENT_BUS_ARN must be provided. Please contact FormaCloud support."
test -n "$FORMACLOUD_SERVICE" || die "FORMACLOUD_SERVICE must be provided. Please contact FormaCloud support."
test -n "$REGIONS" || die "REGIONS must be provided. e.g. us-west-2 us-east-1"

regions_arr=($REGIONS)
regions_str=${REGIONS// /;}
main_region=${regions_arr[0]}
formacloud_pingback_arn=arn:aws:sns:${main_region}:${FORMACLOUD_PRINCIPAL}:formacloud-pingback-topic

if $FULL_ORGANIZATION; then
  root_account_id=$(aws organizations describe-organization | jq -r .Organization.MasterAccountId)
else
  root_account_id=$(aws sts get-caller-identity --query "Account" --output text)
fi

tmp_dir=$(mktemp -d)
tmp_file="$tmp_dir"/formacloud_optima.yaml
curl -fsSL -o "$tmp_file" https://raw.githubusercontent.com/forma-cloud/FormaCloud/main/optima/formacloud_optima.yaml

stack_name=FormaCloudOptima

for region in "${regions_arr[@]}"; do
  echo "Creating a Stack in ${region}..."
  aws cloudformation create-stack \
  --region ${region} \
  --stack-name ${stack_name} \
  --capabilities CAPABILITY_NAMED_IAM \
  --template-body file://${tmp_file} \
  --parameters ParameterKey=FormaCloudID,ParameterValue=${FORMACLOUD_ID} \
  ParameterKey=FormaCloudPrincipal,ParameterValue=${FORMACLOUD_PRINCIPAL} \
  ParameterKey=FormaCloudExternalID,ParameterValue=${FORMACLOUD_EXTERNALID} \
  ParameterKey=FormaCloudService,ParameterValue=${FORMACLOUD_SERVICE} \
  ParameterKey=FormaCloudEventBusArn,ParameterValue=${FORMACLOUD_EVENT_BUS_ARN} \
  ParameterKey=CWCrossAccountSharingRoleExists,ParameterValue=${CW_ROLE_EXISTS} \
  ParameterKey=MainRegion,ParameterValue=${main_region} \
  ParameterKey=Regions,ParameterValue=${regions_str} \
  ParameterKey=RootAccountID,ParameterValue=${root_account_id} \
  ParameterKey=FormaCloudPingbackArn,ParameterValue=${formacloud_pingback_arn}
done
echo "${stack_name} Stacks created!"

if ! $FULL_ORGANIZATION; then
  echo "Installation completed."
  exit 0
fi

org_id=$(aws organizations list-roots | jq -r .Roots[0].Id)

echo "Creating a StackSet..."
aws cloudformation create-stack-set \
--region ${main_region} \
--stack-set-name ${stack_name} \
--capabilities CAPABILITY_NAMED_IAM \
--auto-deployment Enabled=true,RetainStacksOnAccountRemoval=true \
--permission-mode SERVICE_MANAGED \
--template-body file://${tmp_file} \
--parameters ParameterKey=FormaCloudID,ParameterValue=${FORMACLOUD_ID} \
ParameterKey=FormaCloudPrincipal,ParameterValue=${FORMACLOUD_PRINCIPAL} \
ParameterKey=FormaCloudExternalID,ParameterValue=${FORMACLOUD_EXTERNALID} \
ParameterKey=FormaCloudService,ParameterValue=${FORMACLOUD_SERVICE} \
ParameterKey=FormaCloudEventBusArn,ParameterValue=${FORMACLOUD_EVENT_BUS_ARN} \
ParameterKey=CWCrossAccountSharingRoleExists,ParameterValue=${CW_ROLE_EXISTS} \
ParameterKey=RootAccountID,ParameterValue=${root_account_id} \
ParameterKey=MainRegion,ParameterValue=${main_region} \
ParameterKey=Regions,ParameterValue=${regions_str} \
ParameterKey=FormaCloudPingbackArn,ParameterValue=${formacloud_pingback_arn}
echo "${stack_name} StackSet created!"

echo "Creating StackSet instances for the member accounts..."
operation_id="$(aws cloudformation create-stack-instances \
--region ${main_region} \
--stack-set-name ${stack_name} \
--regions ${REGIONS} \
--deployment-targets OrganizationalUnitIds=${org_id} \
--operation-preferences RegionConcurrencyType=PARALLEL,MaxConcurrentPercentage=100,FailureTolerancePercentage=100 \
--output text)"
stackSetOperationWait "$main_region" "$stack_name" "$operation_id"
echo "${stack_name} StackSet instances created!"

trap 'rm -rf -- "$tmp_dir"' EXIT
echo "Installation completed."