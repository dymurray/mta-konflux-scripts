#!/bin/bash

# Cleanup script for MTA deployment created by deploy-mta-with-index.sh
# This script is idempotent -- it will not error if resources are already gone.
# Usage: ./cleanup-mta-deployment.sh

NAMESPACE="${MTA_NAMESPACE:-openshift-mta}"
CATALOG_SOURCE_NAME="${MTA_CATALOGSOURCE:-mta-konflux-catalog}"

FAILURES=0

fail() {
    echo "ERROR: $1"
    FAILURES=$((FAILURES + 1))
}

echo "=========================================="
echo "Cleaning up MTA deployment"
echo "=========================================="
echo "NAMESPACE: $NAMESPACE"
echo "CATALOG_SOURCE: $CATALOG_SOURCE_NAME"
echo "=========================================="

# Step 1: Delete Tackle CR (must go first so the operator can finalize managed resources)
echo ""
echo "Step 1: Deleting Tackle CR 'mta' in namespace $NAMESPACE..."
if oc get tackle mta -n "$NAMESPACE" &>/dev/null; then
    echo "  Tackle CR found, deleting..."
    if oc delete tackle mta -n "$NAMESPACE" --timeout=120s 2>&1; then
        echo "  Tackle CR deleted."
    else
        fail "Tackle CR deletion timed out or failed. Finalizers may be stuck."
    fi
else
    echo "  Tackle CR not found, skipping."
fi

# Step 2: Delete Subscription
echo ""
echo "Step 2: Deleting Subscription 'mta-operator' in namespace $NAMESPACE..."
if oc get subscription mta-operator -n "$NAMESPACE" &>/dev/null; then
    echo "  Subscription found, deleting..."
    if oc delete subscription mta-operator -n "$NAMESPACE" --ignore-not-found 2>&1; then
        echo "  Subscription deleted."
    else
        fail "Failed to delete Subscription."
    fi
else
    echo "  Subscription not found, skipping."
fi

# Step 3: Delete all mta-operator CSVs
echo ""
echo "Step 3: Deleting ClusterServiceVersions matching 'mta-operator' in namespace $NAMESPACE..."
CSV_NAMES=$(oc get csv -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep '^mta-operator' || true)
if [ -n "$CSV_NAMES" ]; then
    for csv in $CSV_NAMES; do
        echo "  Deleting CSV $csv..."
        if oc delete csv "$csv" -n "$NAMESPACE" --ignore-not-found 2>&1; then
            echo "  CSV $csv deleted."
        else
            fail "Failed to delete CSV $csv."
        fi
    done
else
    echo "  No mta-operator CSVs found, skipping."
fi

# Step 4: Delete OperatorGroup
echo ""
echo "Step 4: Deleting OperatorGroup 'mta-operator-group' in namespace $NAMESPACE..."
if oc get operatorgroup mta-operator-group -n "$NAMESPACE" &>/dev/null; then
    echo "  OperatorGroup found, deleting..."
    if oc delete operatorgroup mta-operator-group -n "$NAMESPACE" --ignore-not-found 2>&1; then
        echo "  OperatorGroup deleted."
    else
        fail "Failed to delete OperatorGroup."
    fi
else
    echo "  OperatorGroup not found, skipping."
fi

# Step 5: Delete CatalogSource
echo ""
echo "Step 5: Deleting CatalogSource '$CATALOG_SOURCE_NAME' in namespace openshift-marketplace..."
if oc get catalogsource "$CATALOG_SOURCE_NAME" -n openshift-marketplace &>/dev/null; then
    echo "  CatalogSource found, deleting..."
    if oc delete catalogsource "$CATALOG_SOURCE_NAME" -n openshift-marketplace --ignore-not-found 2>&1; then
        echo "  CatalogSource deleted."
    else
        fail "Failed to delete CatalogSource."
    fi
else
    echo "  CatalogSource not found, skipping."
fi

# Step 6: Delete IDMS and ITMS
echo ""
echo "Step 6: Deleting ImageDigestMirrorSet and ImageTagMirrorSet 'mta-registry-mirror'..."
MIRROR_EXISTED=false

if oc get imagedigestmirrorset mta-registry-mirror &>/dev/null; then
    echo "  ImageDigestMirrorSet found, deleting..."
    MIRROR_EXISTED=true
    if oc delete imagedigestmirrorset mta-registry-mirror --ignore-not-found 2>&1; then
        echo "  ImageDigestMirrorSet deleted."
    else
        fail "Failed to delete ImageDigestMirrorSet."
    fi
else
    echo "  ImageDigestMirrorSet not found, skipping."
fi

if oc get imagetagmirrorset mta-registry-mirror &>/dev/null; then
    echo "  ImageTagMirrorSet found, deleting..."
    MIRROR_EXISTED=true
    if oc delete imagetagmirrorset mta-registry-mirror --ignore-not-found 2>&1; then
        echo "  ImageTagMirrorSet deleted."
    else
        fail "Failed to delete ImageTagMirrorSet."
    fi
else
    echo "  ImageTagMirrorSet not found, skipping."
fi

# Wait for MCP to settle after mirror removal
if [ "$MIRROR_EXISTED" = true ]; then
    echo ""
    echo "  Waiting for MachineConfigPool to settle after mirror removal..."
    echo "  Sleeping 30s for MCO to detect mirror configuration change..."
    sleep 30

    TIMEOUT=1800  # 30 minutes
    ELAPSED=0
    INTERVAL=30
    while true; do
        DEGRADED=$(oc get mcp -o jsonpath='{range .items[*]}{.metadata.name}{" Degraded="}{range .status.conditions[?(@.type=="Degraded")]}{.status}{end}{"\n"}{end}')
        if echo "$DEGRADED" | grep -q "Degraded=True"; then
            echo "  WARNING: MachineConfigPool is degraded (continuing cleanup):"
            oc get mcp
            break
        fi

        UPDATING=$(oc get mcp -o jsonpath='{range .items[*]}{.metadata.name}{" Updating="}{range .status.conditions[?(@.type=="Updating")]}{.status}{end}{"\n"}{end}')
        if ! echo "$UPDATING" | grep -q "Updating=True"; then
            echo "  All MachineConfigPools are updated."
            break
        fi

        if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
            echo "  WARNING: Timed out waiting for MachineConfigPool update after ${TIMEOUT}s (continuing cleanup)."
            oc get mcp
            break
        fi

        echo "  MachineConfigPool still updating (${ELAPSED}s/${TIMEOUT}s)..."
        oc get mcp
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done
fi

# Step 7: Delete Namespace
echo ""
echo "Step 7: Deleting namespace $NAMESPACE..."
if oc get namespace "$NAMESPACE" &>/dev/null; then
    echo "  Namespace found, deleting..."
    if oc delete namespace "$NAMESPACE" --ignore-not-found --wait=false 2>&1; then
        echo "  Namespace deletion initiated (--wait=false). Waiting up to 120s..."
        if oc wait --for=delete namespace/"$NAMESPACE" --timeout=120s 2>&1; then
            echo "  Namespace deleted."
        else
            echo "  WARNING: Namespace $NAMESPACE still terminating after 120s. It may have stuck finalizers."
        fi
    else
        fail "Failed to delete namespace."
    fi
else
    echo "  Namespace not found, skipping."
fi

# Final summary
echo ""
echo "=========================================="
if [ "$FAILURES" -gt 0 ]; then
    echo "Cleanup finished with $FAILURES error(s). See above for details."
else
    echo "Cleanup complete."
fi
echo "=========================================="
echo ""
echo "NOTE: The global pull secret (openshift-config/pull-secret) was NOT modified."
echo "If the deploy script merged additional registry credentials, they remain in place."
echo "To review: oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq ."
