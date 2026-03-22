# Liferay DXP on OpenShift

Deploy Liferay DXP on any OpenShift 4.x cluster using the official [Kubernetes Ready](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/cloud-native-experience/cne-kubernetes-ready) Helm chart. Zero chart template modifications. Values-only configuration.

Validated on OpenShift 4.17 (self-managed on AWS). Applicable to ARO, ROSA, Developer Sandbox, or any OpenShift 4.x cluster.

## What This Repo Contains

```
liferay-on-openshift/
├── values/
│   ├── base/
│   │   └── liferay.yaml              # Shared config: probes, init containers, clustering
│   └── environments/
│       ├── dev/liferay.yaml           # Dev: low resources, single replica
│       ├── uat/liferay.yaml           # UAT: medium resources
│       └── prd/liferay.yaml           # PRD: production resources, 2 replicas
├── operators/
│   ├── postgres-cluster.yaml          # Crunchy PGO PostgresCluster
│   └── opensearch-statefulset.yaml    # OpenSearch direct StatefulSet
├── argocd/
│   ├── appproject.yaml                # ArgoCD AppProject
│   └── applicationset.yaml            # ArgoCD ApplicationSet (Git generator)
├── scripts/
│   ├── setup-namespace.sh             # Namespace + SCC + ArgoCD label
│   ├── create-route.sh                # OpenShift Route for Liferay
│   └── create-license-secret.sh       # License secret from file
└── docs/
    ├── how-to.md                      # Step-by-step deployment guide
    ├── troubleshooting.md             # Common issues and fixes
    └── architecture.md                # End-state architecture diagram
```

## Quick Start

```bash
# Prerequisites: oc CLI authenticated, Helm 3.12+, Crunchy PGO installed

# 1. Setup namespace
bash scripts/setup-namespace.sh liferay-dev

# 2. Deploy data layer
oc apply -f operators/postgres-cluster.yaml -n liferay-dev
oc apply -f operators/opensearch-statefulset.yaml -n liferay-dev

# 3. Wait for data layer to be ready
oc exec opensearch-0 -n liferay-dev -- curl -s http://localhost:9200/_cluster/health | grep green

# 4. Deploy Liferay
helm install liferay \
  oci://us-central1-docker.pkg.dev/liferay-artifact-registry/liferay-helm-chart/liferay-default \
  --values values/base/liferay.yaml \
  --values values/environments/dev/liferay.yaml \
  -n liferay-dev

# 5. Create Route
bash scripts/create-route.sh liferay-dev

# 6. Wait 10-15 minutes for first boot, then access via Route hostname
```

## Or Deploy via ArgoCD (GitOps)

```bash
# Apply ArgoCD resources (after OpenShift GitOps Operator is installed)
oc apply -f argocd/appproject.yaml
oc apply -f argocd/applicationset.yaml

# ArgoCD auto-discovers environments from values/environments/*/liferay.yaml
# Push changes to this repo, ArgoCD syncs to the cluster
```

## Key Configuration Decisions

| Decision | Value | Why |
|---|---|---|
| SCC | nonroot-v2 | Liferay image runs as UID 1000. restricted-v2 rejects it. |
| readOnlyRootFilesystem | false | Chart volume mounts don't cover all writable paths. |
| PostgresCluster name | `pgdb` (not `liferay-db`) | Kubernetes injects `LIFERAY_DB_*` env vars that Liferay misinterprets. |
| OpenSearch deployment | Direct StatefulSet | Operator doesn't support single-node on OpenShift. |
| Values nesting | Flat top-level keys | Chart deployed directly from OCI, not as subchart. |

## Customization

Edit `values/environments/dev/liferay.yaml`:

| Value | What to Change |
|---|---|
| `image.tag` | Your DXP version (`2025.q1.12-lts` validated) |
| `volumeClaimTemplates.storageClassName` | Your cluster's StorageClass (`gp3-csi` for AWS, `managed-csi` for Azure) |
| `company.default.web.id` | Your Route hostname |
| `resources` | CPU and memory for your node capacity |

## Documentation

- [How To: Deploy Liferay on OpenShift](docs/how-to.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Architecture](docs/architecture.md)

## References

- [Liferay Kubernetes Ready](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/cloud-native-experience/cne-kubernetes-ready)
- [Liferay Helm Chart (OCI)](https://us-central1-docker.pkg.dev/liferay-artifact-registry/liferay-helm-chart/liferay-default)
- [Crunchy PGO](https://access.crunchydata.com/documentation/postgres-operator/latest/)
- [OpenShift GitOps Operator](https://docs.openshift.com/gitops/latest/understanding_openshift_gitops/about-redhat-openshift-gitops.html)
