#!/usr/bin/env bash
set -euo pipefail

: "${AZURE_RESOURCE_GROUP:?}" "${FIELD_KEYSTORE:?}" "${FIELD_KEYSTORE_PASSWORD:?}"
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
repo_subject=$(gh api "repos/$repo" --jq '"\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"')
branch=feature/live-litter-map
environment=ploggr-field-android

base=$(az deployment group show -g "$AZURE_RESOURCE_GROUP" -n ploggr-field-base --query properties.outputs -o json)
apps=$(az deployment group show -g "$AZURE_RESOURCE_GROUP" -n ploggr-field-apps --query properties.outputs -o json)
registry=$(jq -r .registryName.value <<<"$base")
registry_id=$(jq -r .registryId.value <<<"$base")
app_id=$(jq -r .apiId.value <<<"$apps")
job_id=$(jq -r .migrationId.value <<<"$apps")
url=$(jq -r .apiUrl.value <<<"$apps")
location=$(az resource show --ids "$app_id" --query location -o tsv)
account=$(az account show -o json)
subscription=$(jq -r .id <<<"$account")
tenant=$(jq -r .tenantId <<<"$account")
identity=$(az identity create -g "$AZURE_RESOURCE_GROUP" -n ploggr-field-github -l "$location" -o json)
principal=$(jq -r .principalId <<<"$identity")
client=$(jq -r .clientId <<<"$identity")

az identity federated-credential create -g "$AZURE_RESOURCE_GROUP" --identity-name ploggr-field-github \
  -n github-field-branch --issuer https://token.actions.githubusercontent.com \
  --subject "repo:$repo_subject:ref:refs/heads/$branch" --audiences api://AzureADTokenExchange -o none
az role assignment create --assignee-object-id "$principal" --assignee-principal-type ServicePrincipal \
  --role AcrPush --scope "$registry_id" -o none
az role assignment create --assignee-object-id "$principal" --assignee-principal-type ServicePrincipal \
  --role Reader --scope "$registry_id" -o none
for scope in "$app_id" "$job_id"; do
  az role assignment create --assignee-object-id "$principal" --assignee-principal-type ServicePrincipal \
    --role 'Container Apps Contributor' --scope "$scope" -o none
done

gh variable set FIELD_AZURE_CLIENT_ID --body "$client" -R "$repo"
gh variable set FIELD_AZURE_TENANT_ID --body "$tenant" -R "$repo"
gh variable set FIELD_AZURE_SUBSCRIPTION_ID --body "$subscription" -R "$repo"
gh variable set FIELD_AZURE_RESOURCE_GROUP --body "$AZURE_RESOURCE_GROUP" -R "$repo"
gh variable set FIELD_REGISTRY --body "$registry" -R "$repo"
gh variable set FIELD_API_URL --body "$url" -R "$repo"

jq -n '{deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}' |
  gh api --method PUT "repos/$repo/environments/$environment" --input - >/dev/null
if ! gh api "repos/$repo/environments/$environment/deployment-branch-policies" \
  --jq '.branch_policies[].name' | grep -Fxq "$branch"; then
  gh api --method POST "repos/$repo/environments/$environment/deployment-branch-policies" \
    -f "name=$branch" -f type=branch >/dev/null
fi

base64 -w 0 "$FIELD_KEYSTORE" | gh secret set FIELD_KEYSTORE_BASE64 --env "$environment" -R "$repo"
printf '%s' "$FIELD_KEYSTORE_PASSWORD" | gh secret set FIELD_KEYSTORE_PASSWORD --env "$environment" -R "$repo"
