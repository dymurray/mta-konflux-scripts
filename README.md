# MTA Konflux Deployment Scripts

Scripts for deploying and cleaning up Migration Toolkit for Applications (MTA) on OpenShift using a Konflux-built index image.

## Prerequisites

- `oc` CLI authenticated to an OpenShift cluster
- `jq` (only required if using `PULL_SECRET_FILE`)

## Deploy

```bash
./deploy-mta-with-index.sh <INDEX_IMAGE> [MTA_VERSION] [PULL_SECRET_FILE]
```

**Positional arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `INDEX_IMAGE` | Yes | The FBC index image to use as a CatalogSource |
| `MTA_VERSION` | No | MTA version (informational) |
| `PULL_SECRET_FILE` | No | Path to a Docker config JSON to merge into the cluster pull secret |

**Example:**

```bash
./deploy-mta-with-index.sh \
  quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:v4.21__operator_nvr__mta-operator-container-8.1.0-202602100135.p2.ga1f4b61.assembly.stream.el9 \
  8.1.0 \
  pull-secrets.json
```

### What the deploy script does

1. Creates the MTA namespace
2. Merges pull secret into the cluster global pull secret (if `PULL_SECRET_FILE` is set)
3. Creates an ImageDigestMirrorSet for registry mirroring
4. Creates an ImageTagMirrorSet for registry mirroring
5. Waits for MachineConfigPool to finish rolling out mirror config
6. Creates a CatalogSource from the index image
7. Waits for the CatalogSource to be READY
8. Creates an OperatorGroup
9. Creates a Subscription for the MTA operator
10. Waits for the ClusterServiceVersion to succeed
11. Waits for the operator deployment to be available
12. Creates the MTA Tackle custom resource
13. Waits for MTA UI pods to be ready
14. Prints the MTA route URL

### Environment variables

All arguments can also be passed as environment variables. Environment variables are also used for settings that don't have positional arguments:

| Variable | Default | Description |
|----------|---------|-------------|
| `INDEX_IMAGE` | *(none)* | FBC index image (alternative to positional arg) |
| `MTA_VERSION` | *(none)* | MTA version (alternative to positional arg) |
| `PULL_SECRET_FILE` | *(none)* | Pull secret file path (alternative to positional arg) |
| `MTA_NAMESPACE` | `openshift-mta` | Namespace for MTA resources |
| `MTA_CATALOGSOURCE` | `mta-konflux-catalog` | Name of the CatalogSource to create |
| `MTA_CHANNEL` | `stable-v8.1` | OLM subscription channel |
| `SOURCE_REGISTRY` | `registry.redhat.io` | Source registry for image mirroring |
| `MIRROR_REGISTRY` | `registry.stage.redhat.io` | Mirror registry for image mirroring |
| `SKIP_SETUP` | *(unset)* | Set to `1` to skip steps 1-5 (see below) |

### Skipping infrastructure setup

If the cluster already has the namespace, pull secret, and registry mirrors configured (e.g., from a previous run), you can skip straight to CatalogSource creation:

```bash
SKIP_SETUP=1 ./deploy-mta-with-index.sh <INDEX_IMAGE>
```

This skips namespace creation, pull secret merging, IDMS/ITMS creation, and the MachineConfigPool wait (steps 1-5). The namespace is still verified to exist.

## Cleanup

```bash
./cleanup-mta-deployment.sh
```

The cleanup script is idempotent -- it can be run repeatedly without errors, even if some or all resources are already gone.

### What the cleanup script does

Resources are removed in reverse order of creation:

1. Deletes the Tackle CR (`mta`) and waits for finalizers (up to 120s)
2. Deletes the Subscription (`mta-operator`)
3. Deletes all `mta-operator` ClusterServiceVersions
4. Deletes the OperatorGroup (`mta-operator-group`)
5. Deletes the CatalogSource
6. Deletes the ImageDigestMirrorSet and ImageTagMirrorSet, then waits for MachineConfigPool to settle (only if mirrors existed)
7. Deletes the namespace

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MTA_NAMESPACE` | `openshift-mta` | Namespace to clean up |
| `MTA_CATALOGSOURCE` | `mta-konflux-catalog` | CatalogSource name to delete |

### What is NOT cleaned up

The global pull secret (`openshift-config/pull-secret`) is not modified during cleanup. The deploy script merges credentials into this secret, but there is no safe way to reverse a merge without knowing the original state. To inspect it:

```bash
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq .
```
