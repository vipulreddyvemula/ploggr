#!/usr/bin/env bash
set -euo pipefail

: "${AZURE_RESOURCE_GROUP:?}" "${FIELD_REGISTRY:?}" "${FIELD_API_URL:?}" "${GITHUB_SHA:?}"

image="$FIELD_REGISTRY.azurecr.io/ploggr-api:$GITHUB_SHA"
api=ploggr-field-api
job=ploggr-field-migrate
revision="r${GITHUB_RUN_ID:-$(date +%s)}a${GITHUB_RUN_ATTEMPT:-1}"
backend_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../backend" && pwd)

az acr login --name "$FIELD_REGISTRY" --only-show-errors
docker build --platform linux/amd64 -t "$image" "$backend_dir"
docker push "$image"
# Deploy a digest so rollbacks remain reproducible even if a commit is rebuilt.
image=$(docker image inspect --format '{{index .RepoDigests 0}}' "$image")

execution=$(az containerapp job start -g "$AZURE_RESOURCE_GROUP" -n "$job" \
  --container-name migration --image "$image" --query name -o tsv)
for (( attempt=0; attempt<60; attempt++ )); do
  status=$(az containerapp job execution show -g "$AZURE_RESOURCE_GROUP" -n "$job" \
    --job-execution-name "$execution" --query properties.status -o tsv)
  case "$status" in
    Succeeded) break ;;
    Failed|Stopped|Degraded) echo "Migration $execution ended in $status" >&2; exit 1 ;;
  esac
  sleep 5
done
[[ "$status" == Succeeded ]] || { echo "Migration $execution timed out" >&2; exit 1; }

app=$(az containerapp show -g "$AZURE_RESOURCE_GROUP" -n "$api" -o json)
app_id=$(jq -r '.id' <<<"$app")
revision_url="https://management.azure.com$app_id?api-version=2025-07-01"
previous=$(jq -c '{properties: {template: .properties.template}}' <<<"$app")
query="SELECT public.ploggr_field_work_due()"
updated=$(jq -c --arg image "$image" --arg revision "$revision" --arg query "$query" '
  .properties.template as $template |
  {properties: {template: ($template |
    .revisionSuffix = $revision |
    .containers[0].image = $image |
    .containers[0].probes = [
      {type: "Startup", httpGet: {path: "/api/health", port: 8080}, periodSeconds: 2, failureThreshold: 30},
      {type: "Readiness", httpGet: {path: "/api/health/ready", port: 8080}, periodSeconds: 5, timeoutSeconds: 4, failureThreshold: 3},
      {type: "Liveness", httpGet: {path: "/api/health", port: 8080}, periodSeconds: 10}
    ] |
    .scale = { minReplicas: 0, maxReplicas: 1, cooldownPeriod: 300, pollingInterval: 30, rules: [
      {name: "http", http: {metadata: {concurrentRequests: "10"}}},
      {name: "photo-analysis", custom: {type: "postgresql", metadata: {query: $query, targetQueryValue: "1"},
        auth: [{secretRef: "scaler-connection", triggerParameter: "connection"}]}}
    ] }
  )}}
' <<<"$app")

# Warm the current revision so Azure requires a ready replacement before routing traffic.
curl --silent --show-error --max-time 60 --output /dev/null "${FIELD_API_URL%/api/}/"
az rest --method patch --uri "$revision_url" --body "$updated" --output none

for (( attempt=0; attempt<30; attempt++ )); do
  ready=$(az containerapp show -g "$AZURE_RESOURCE_GROUP" -n "$api" \
    --query properties.latestReadyRevisionName -o tsv)
  if [[ "$ready" == "$api--$revision" ]] && curl --fail --silent --max-time 45 "${FIELD_API_URL}health/ready"; then
    printf '\nDeployed %s\n' "$ready"
    exit 0
  fi
  sleep 5
done

# Reapply the previous revision template as a fresh revision, preserving its digest and scaling rules.
rollback=$(jq -c --arg suffix "$revision-rollback" '.properties.template.revisionSuffix = $suffix' <<<"$previous")
az rest --method patch --uri "$revision_url" --body "$rollback" --output none
echo "Readiness check failed for $api--$revision. Submitted rollback to the previous template." >&2
exit 1
