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

## Live Environment (AWS)

Deployed on self-managed OpenShift 4.17 (compact 3-node, us-east-1):

| Resource | URL |
|---|---|
| **OpenShift Console** | `https://console-openshift-console.apps.openshift.misaelneto.com` |
| **ArgoCD Console** | `https://openshift-gitops-server-openshift-gitops.apps.openshift.misaelneto.com` |
| **Liferay DXP (dev)** | `https://liferay-default-liferay-dev.apps.openshift.misaelneto.com` |

> Note: This environment is ephemeral. It may not be running when you access these URLs.

## Related Repositories

| Repository | Purpose |
|---|---|
| [misaellr/liferay-on-openshift](https://github.com/misaellr/liferay-on-openshift) | This repo: reference configs, scripts, docs |
| [misaellr/liferay-openshift-gitops](https://github.com/misaellr/liferay-openshift-gitops) | GitOps values repo (what ArgoCD watches) |

## References

### Liferay Cloud Native Experience
- [Kubernetes Ready Overview](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/cloud-native-experience/cne-kubernetes-ready)
- [Kubernetes Ready Quick Start (2025.Q4 and earlier)](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/cloud-native-experience/cne-kubernetes-ready/kubernetes-cluster-2025-q4-earlier)
- [Helm Values Reference](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/cloud-native-experience/cne-reference/cne-helm-values-reference)
- [Configuring Externally Managed Services](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/cloud-native-experience/cne-cloud-provider-ready/cne-aws-ready/2025-q4-and-earlier/configuring-externally-managed-services)
- [Managing Secrets and Licenses](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/cloud-native-experience/cne-cloud-provider-ready/cne-aws-ready/configuring-the-cne/managing-secrets-and-licenses)
- [Adding OSGi Modules with Overlays](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/cloud-native-experience/cne-cloud-provider-ready/cne-aws-ready/configuring-the-cne/adding-osgi-modules-or-cx-with-overlays)

### Liferay Helm Chart
- [OCI Artifact Registry](https://us-central1-docker.pkg.dev/liferay-artifact-registry/liferay-helm-chart/liferay-default)
- [Liferay DXP Docker Images](https://hub.docker.com/r/liferay/dxp/tags)
- [OpenSearch Connector Modules](https://releases.liferay.com/opensearch2/dxp/)

### OpenShift
- [OpenShift 4.17 Documentation](https://docs.openshift.com/container-platform/4.17/welcome/index.html)
- [OpenShift IPI on AWS](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/installing_on_aws/installer-provisioned-infrastructure)
- [Managing SCCs](https://docs.openshift.com/container-platform/4.17/authentication/managing-security-context-constraints.html)
- [OpenShift GitOps Operator](https://docs.openshift.com/gitops/latest/understanding_openshift_gitops/about-redhat-openshift-gitops.html)
- [A Guide to OpenShift and UIDs](https://www.redhat.com/en/blog/a-guide-to-openshift-and-uids)

### Operators
- [Crunchy Data PGO](https://access.crunchydata.com/documentation/postgres-operator/latest/)
- [Crunchy PGO User Management](https://access.crunchydata.com/documentation/postgres-operator/latest/architecture/user-management)
- [OpenSearch Kubernetes Operator](https://github.com/opensearch-project/opensearch-k8s-operator)
- [OpenSearch Docker Images](https://hub.docker.com/r/opensearchproject/opensearch/tags)

### ArgoCD
- [ArgoCD ApplicationSet Documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/)
- [ArgoCD Multi-Source Applications](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/)
