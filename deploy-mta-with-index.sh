#!/bin/bash
set -e

# Simple script to deploy MTA using INDEX_IMAGE
# Usage: ./deploy-mta-with-index.sh <INDEX_IMAGE> [MTA_VERSION] [PULL_SECRET_FILE]
# Example: ./deploy-mta-with-index.sh quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:v4.21__operator_nvr__mta-operator-container-8.1.0-202602100135.p2.ga1f4b61.assembly.stream.el9 8.1.0

INDEX_IMAGE="${1:-$INDEX_IMAGE}"
MTA_VERSION="${2:-$MTA_VERSION}"
PULL_SECRET_FILE="${3:-$PULL_SECRET_FILE}"
SOURCE_REGISTRY="${SOURCE_REGISTRY:-registry.redhat.io}"
MIRROR_REGISTRY="${MIRROR_REGISTRY:-registry.stage.redhat.com}"
NAMESPACE="${MTA_NAMESPACE:-openshift-mta}"
CATALOG_SOURCE_NAME="${MTA_CATALOGSOURCE:-mta-konflux-catalog}"
CHANNEL="${MTA_CHANNEL:-stable-v8.1}"

if [ -z "$INDEX_IMAGE" ]; then
    echo "Error: INDEX_IMAGE is required"
    echo "Usage: $0 <INDEX_IMAGE> [MTA_VERSION] [PULL_SECRET_FILE]"
    exit 1
fi

if [ -n "$PULL_SECRET_FILE" ]; then
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required for pull secret merging but is not installed"
        exit 1
    fi
    if [ ! -f "$PULL_SECRET_FILE" ]; then
        echo "Error: PULL_SECRET_FILE '$PULL_SECRET_FILE' does not exist"
        exit 1
    fi
    if ! jq empty "$PULL_SECRET_FILE" 2>/dev/null; then
        echo "Error: PULL_SECRET_FILE '$PULL_SECRET_FILE' is not valid JSON"
        exit 1
    fi
fi

echo "=========================================="
echo "Deploying MTA with INDEX_IMAGE"
echo "=========================================="
echo "INDEX_IMAGE: $INDEX_IMAGE"
echo "MTA_VERSION: $MTA_VERSION"
echo "NAMESPACE: $NAMESPACE"
echo "CATALOG_SOURCE: $CATALOG_SOURCE_NAME"
echo "CHANNEL: $CHANNEL"
echo "PULL_SECRET_FILE: ${PULL_SECRET_FILE:-<not set>}"
echo "SOURCE_REGISTRY: $SOURCE_REGISTRY"
echo "MIRROR_REGISTRY: $MIRROR_REGISTRY"
echo "=========================================="

# Step 1: Create namespace
echo "Step 1: Creating namespace $NAMESPACE..."
oc create namespace $NAMESPACE --dry-run=client -o yaml | oc apply -f -

if [ -n "$PULL_SECRET_FILE" ]; then

# Step 2: Update global cluster pull secret
echo "Step 2: Updating global cluster pull secret..."
EXISTING_SECRET=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
MERGED_SECRET=$(jq -s '.[0] * .[1]' <(echo "$EXISTING_SECRET") "$PULL_SECRET_FILE")
TMPFILE=$(mktemp)
echo "$MERGED_SECRET" > "$TMPFILE"
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="$TMPFILE"
rm -f "$TMPFILE"
echo "Global pull secret updated."

# Step 3: Create ImageDigestMirrorSet (IDMS)
echo "Step 3: Creating ImageDigestMirrorSet..."
cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: mta-registry-mirror
spec:
  imageDigestMirrors:
  - source: $SOURCE_REGISTRY
    mirrors:
    - $MIRROR_REGISTRY
    mirrorSourcePolicy: AllowContactingSource
EOF

# Step 4: Create ImageTagMirrorSet (ITMS)
echo "Step 4: Creating ImageTagMirrorSet..."
cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: mta-registry-mirror
spec:
  imageTagMirrors:
  - source: $SOURCE_REGISTRY
    mirrors:
    - $MIRROR_REGISTRY
    mirrorSourcePolicy: AllowContactingSource
EOF

# Step 5: Wait for MachineConfigPool update
echo "Step 5: Waiting for MachineConfigPool to finish updating..."
echo "Sleeping 30s for MCO to detect new mirror configuration..."
sleep 30

TIMEOUT=1800  # 30 minutes
ELAPSED=0
INTERVAL=30
while true; do
    DEGRADED=$(oc get mcp -o jsonpath='{range .items[*]}{.metadata.name}{" Degraded="}{range .status.conditions[?(@.type=="Degraded")]}{.status}{end}{"\n"}{end}')
    if echo "$DEGRADED" | grep -q "Degraded=True"; then
        echo "Error: MachineConfigPool is degraded:"
        oc get mcp
        exit 1
    fi

    UPDATING=$(oc get mcp -o jsonpath='{range .items[*]}{.metadata.name}{" Updating="}{range .status.conditions[?(@.type=="Updating")]}{.status}{end}{"\n"}{end}')
    if ! echo "$UPDATING" | grep -q "Updating=True"; then
        echo "All MachineConfigPools are updated."
        break
    fi

    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "Error: Timed out waiting for MachineConfigPool update after ${TIMEOUT}s"
        oc get mcp
        exit 1
    fi

    echo "MachineConfigPool still updating (${ELAPSED}s/${TIMEOUT}s)..."
    oc get mcp
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

fi

# Step 6: Create CatalogSource
echo "Step 6: Creating CatalogSource from INDEX_IMAGE..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOG_SOURCE_NAME
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: $INDEX_IMAGE
  displayName: MTA Konflux Catalog
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

# Step 7: Wait for CatalogSource to be ready
echo "Step 7: Waiting for CatalogSource to be ready..."
timeout 300 bash -c "until oc get catalogsource $CATALOG_SOURCE_NAME -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null | grep -q READY; do echo 'Waiting...'; sleep 5; done"
echo "CatalogSource is READY"

# Step 8: Create OperatorGroup
echo "Step 8: Creating OperatorGroup..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: mta-operator-group
  namespace: $NAMESPACE
spec:
  targetNamespaces:
  - $NAMESPACE
EOF

# Step 9: Create Subscription
echo "Step 9: Creating Subscription for MTA operator..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: mta-operator
  namespace: $NAMESPACE
spec:
  channel: $CHANNEL
  installPlanApproval: Automatic
  name: mta-operator
  source: $CATALOG_SOURCE_NAME
  sourceNamespace: openshift-marketplace
EOF

# Step 10: Wait for CSV to be installed
echo "Step 10: Waiting for ClusterServiceVersion to be ready..."
timeout 600 bash -c '
  until oc get csv -n '"$NAMESPACE"' -o jsonpath="{.items[?(@.metadata.name~=\"mta-operator.*\")].status.phase}" 2>/dev/null | grep -q Succeeded; do
    echo "Waiting for CSV... Current CSVs:"
    oc get csv -n '"$NAMESPACE"' 2>/dev/null || true
    sleep 10
  done
'

CSV_NAME=$(oc get csv -n $NAMESPACE -o jsonpath="{.items[?(@.metadata.name~='mta-operator.*')].metadata.name}")
echo "ClusterServiceVersion $CSV_NAME is ready!"

# Step 11: Wait for operator deployment to be ready
echo "Step 11: Waiting for MTA operator deployment..."
oc wait --for=condition=available --timeout=300s deployment/mta-operator -n $NAMESPACE

# Step 12: Create MTA CR (Custom Resource)
echo "Step 12: Creating MTA Custom Resource..."
cat <<EOF | oc apply -f -
apiVersion: tackle.konveyor.io/v1alpha1
kind: Tackle
metadata:
  name: mta
  namespace: $NAMESPACE
spec:
  hub_bucket_volume_size: "25Gi"
  cache_data_volume_size: "25Gi"
EOF

# Step 13: Wait for MTA pods to be ready
echo "Step 13: Waiting for MTA pods to be ready..."
oc wait --for=condition=ready --timeout=600s pods -l app.kubernetes.io/name=mta-ui -n $NAMESPACE

# Step 14: Get MTA route
echo "Step 14: Getting MTA route..."
MTA_ROUTE=$(oc get route mta -n $NAMESPACE -o jsonpath='{.spec.host}')
MTA_URL="https://$MTA_ROUTE"

echo ""
echo "=========================================="
echo "✅ MTA Deployment Complete!"
echo "=========================================="
echo "Namespace: $NAMESPACE"
echo "CatalogSource: $CATALOG_SOURCE_NAME"
echo "CSV: $CSV_NAME"
echo "MTA URL: $MTA_URL"
echo "Source Registry: $SOURCE_REGISTRY"
echo "Mirror Registry: $MIRROR_REGISTRY"
echo "=========================================="
echo ""
echo "Login with: admin / Dog8code"
echo ""
