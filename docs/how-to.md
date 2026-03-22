# How To: Deploy Liferay DXP on OpenShift

A step-by-step guide for platform engineers deploying Liferay DXP on OpenShift using the Kubernetes Ready Operating Kit. Validated on OpenShift 4.17 (self-managed on AWS). Applicable to any OpenShift 4.x cluster.

---

## 1. Prerequisites

Before starting, confirm the following:

| Requirement | Details |
|---|---|
| **OpenShift cluster** | 4.x with at least 3 nodes. Compact (control-plane schedulable) or standard topology. Minimum 4 vCPU and 16 GB RAM per node. |
| **Helm CLI** | Version 3.12 or later. The Liferay chart is published as an OCI artifact. |
| **oc CLI** | Authenticated to the target cluster with cluster-admin or project-admin privileges. |
| **GitHub repository** | A Git repository for GitOps values files. Public or private (ArgoCD must have read access). |
| **Liferay license** (optional) | DXP Development or Production license as `license.xml`. Without a license, Liferay runs in trial mode. |
| **Outbound internet** | Init containers download OpenSearch connector modules from `releases.liferay.com` at pod startup. |

---

## 2. Cluster Provisioning

If you already have an OpenShift cluster, skip to Section 3.

### Self-Managed on AWS

Provision a compact 3-node cluster via `openshift-install` IPI:

```yaml
# install-config.yaml
apiVersion: v1
baseDomain: yourdomain.com
metadata:
  name: openshift
controlPlane:
  replicas: 3
  platform:
    aws:
      type: m6i.xlarge
      rootVolume:
        size: 120
        type: gp3
compute:
  - replicas: 0          # Compact mode: workloads run on control plane
networking:
  networkType: OVNKubernetes
platform:
  aws:
    region: us-east-1
```

**DNS**: Create a Route 53 public hosted zone matching the `baseDomain`. Use a single zone (do not create child zones for the cluster subdomain).

**Credentials**: Use long-lived IAM credentials, not SSO session tokens. The installer runs for 40 minutes and validates credentials upfront.

**Container runtime**: If running on a host with glibc older than 2.34 (Ubuntu 20.04), run the installer inside a Fedora container with `--dns 8.8.8.8`.

**Estimated time**: 40 minutes. **Estimated cost**: $500-600 per month (3x m6i.xlarge on-demand plus EBS, NAT, and load balancer).

### Managed OpenShift

Azure Red Hat OpenShift (ARO), Red Hat OpenShift on AWS (ROSA), or Red Hat Developer Sandbox all work. Ensure your namespace has permission to create StatefulSets, Services, Secrets, and ConfigMaps.

---

## 3. Platform Setup

### Install Operators

Two operators required:

**OpenShift GitOps Operator** (provides ArgoCD):
```bash
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

**Crunchy Data PostgreSQL Operator** (provides managed PostgreSQL):
```bash
helm install pgo oci://registry.developers.crunchydata.com/crunchydata/pgo
```

### Create Namespace

```bash
oc new-project liferay-dev
```

### Configure Security Context Constraints

Liferay DXP runs as UID 1000. The default restricted-v2 SCC rejects this because it enforces namespace-range UIDs. Grant the nonroot-v2 SCC:

```bash
oc adm policy add-scc-to-user nonroot-v2 -z liferay-default -n liferay-dev
```

If deploying OpenSearch in the same namespace, grant anyuid to the default service account:

```bash
oc adm policy add-scc-to-user anyuid -z default -n liferay-dev
```

### Label Namespace for ArgoCD

The OpenShift GitOps Operator restricts its ArgoCD instance to labeled namespaces:

```bash
oc label namespace liferay-dev argocd.argoproj.io/managed-by=openshift-gitops
```

---

## 4. Data Layer

### PostgreSQL

Deploy a PostgreSQL cluster via Crunchy PGO. Use a name that does **not** start with `liferay-` (Kubernetes injects Service environment variables that Liferay misinterprets as portal property overrides):

```yaml
# postgres-cluster.yaml
apiVersion: postgres-operator.crunchydata.com/v1beta1
kind: PostgresCluster
metadata:
  name: pgdb                    # NOT liferay-db
spec:
  postgresVersion: 16
  instances:
    - replicas: 1
      resources:
        requests: { cpu: 100m, memory: 512Mi }
        limits: { cpu: "1", memory: 2Gi }
      dataVolumeClaimSpec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3-csi    # Adjust for your cluster
        resources:
          requests: { storage: 10Gi }
  users:
    - name: liferay
      databases: ["lportal"]
      options: "SUPERUSER"
      password:
        type: AlphaNumeric           # Avoids special chars that break JDBC URLs
  backups:
    pgbackrest:
      repos:
        - name: repo1
          volume:
            volumeClaimSpec:
              accessModes: ["ReadWriteOnce"]
              storageClassName: gp3-csi
              resources:
                requests: { storage: 5Gi }
```

```bash
oc apply -f postgres-cluster.yaml -n liferay-dev
```

Wait for the Secret `pgdb-pguser-liferay` to appear (contains `host`, `port`, `user`, `password`, `dbname`).

### OpenSearch

Deploy OpenSearch as a direct StatefulSet (the OpenSearch Kubernetes Operator does not support single-node clusters on OpenShift due to SCC and cluster manager election conflicts):

```yaml
# opensearch-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: opensearch
spec:
  serviceName: opensearch
  replicas: 1
  selector:
    matchLabels: { app: opensearch }
  template:
    metadata:
      labels: { app: opensearch }
    spec:
      securityContext:
        runAsUser: 1000
        fsGroup: 1000
      containers:
        - name: opensearch
          image: opensearchproject/opensearch:2.19.2
          env:
            - name: discovery.type
              value: single-node
            - name: DISABLE_SECURITY_PLUGIN
              value: "true"
            - name: OPENSEARCH_JAVA_OPTS
              value: "-Xms512m -Xmx512m"
          ports:
            - containerPort: 9200
              name: http
          resources:
            requests: { memory: 1Gi, cpu: 100m }
            limits: { memory: 2Gi, cpu: "1" }
          volumeMounts:
            - name: data
              mountPath: /usr/share/opensearch/data
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3-csi
        resources:
          requests: { storage: 10Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: opensearch
spec:
  selector: { app: opensearch }
  ports:
    - { name: http, port: 9200, targetPort: 9200 }
  type: ClusterIP
```

```bash
oc apply -f opensearch-statefulset.yaml -n liferay-dev
```

Verify OpenSearch is healthy before proceeding:

```bash
oc exec opensearch-0 -n liferay-dev -- curl -s http://localhost:9200/_cluster/health
# Expect: "status":"green"
```

**OpenSearch must be green before Liferay starts.** If Liferay boots without a reachable search engine, the index writer initializes as null and never recovers. A corrupted startup requires wiping the database, PVC, and search indices.

---

## 5. GitOps Configuration

### Repository Structure

Create a Git repository with this layout:

```
liferay/projects/default/
  base/liferay.yaml              # Shared configuration
  environments/
    dev/liferay.yaml             # Dev-specific overrides
    uat/liferay.yaml             # UAT-specific overrides
    prd/liferay.yaml             # Production-specific overrides
```

The base file contains probes, init containers, and shared portal properties. Each environment file contains only the delta (image tag, resources, endpoints).

### Values Overlay (OpenShift Dev)

The environment overlay configures Liferay for OpenShift. Key settings:

```yaml
image:
  tag: "2025.q1.12-lts"      # Or 2025.q4.12-slim (see Image Tag section)

podSecurityContext:
  runAsUser: 1000
  runAsGroup: 1000             # Required by nonroot-v2 SCC
  runAsNonRoot: true
  fsGroup: 1000
  fsGroupChangePolicy: Always  # Ensures PVC ownership matches on every mount

securityContext:
  runAsUser: 1000
  allowPrivilegeEscalation: false   # Required by nonroot-v2 SCC
  readOnlyRootFilesystem: false     # Chart volume mounts don't cover all writable paths
  capabilities:
    drop: ["ALL"]

# SCC RBAC binding via chart ServiceAccount Role
global:
  liferayServiceAccount:
    role:
      rules:
        - apiGroups: [""]
          resources: ["configmaps"]
          verbs: ["*"]
        - apiGroups: ["security.openshift.io"]
          resourceNames: ["nonroot-v2"]
          resources: ["securitycontextconstraints"]
          verbs: ["use"]

# Credential bridge: map PGO Secret keys to Liferay env vars
customEnv:
  x-openshift-db:
    - name: DATABASE_ENDPOINT
      valueFrom:
        secretKeyRef: { name: pgdb-pguser-liferay, key: host }
    - name: DATABASE_PORT
      valueFrom:
        secretKeyRef: { name: pgdb-pguser-liferay, key: port }
    - name: DATABASE_USERNAME
      valueFrom:
        secretKeyRef: { name: pgdb-pguser-liferay, key: user }
    - name: DATABASE_PASSWORD
      valueFrom:
        secretKeyRef: { name: pgdb-pguser-liferay, key: password }

portalProperties: |
  jdbc.default.driverClassName=org.postgresql.Driver
  jdbc.default.url=jdbc:postgresql://${env.DATABASE_ENDPOINT}:${env.DATABASE_PORT}/lportal?useUnicode=true&characterEncoding=UTF-8&useFastDateParsing=false
  jdbc.default.username=${env.DATABASE_USERNAME}
  jdbc.default.password=${env.DATABASE_PASSWORD}
  proxy.forwarded.for.header=X-Forwarded-For
  proxy.forwarded.host.header=X-Forwarded-Host
  proxy.forwarded.proto.header=X-Forwarded-Proto
  web.server.forwarded.port.enabled=true
  web.server.forwarded.protocol.enabled=true
  web.server.protocol=https
  web.server.https.port=443
  company.default.web.id=<your-route-hostname>
  virtual.hosts.default.site.name=Guest

portalBundleDenyList:
  - com.liferay.portal.search.elasticsearch.cross.cluster.replication.impl
  - com.liferay.portal.search.elasticsearch.monitoring.web
  - com.liferay.portal.search.elasticsearch8.api
  - com.liferay.portal.search.elasticsearch8.impl
  - com.liferay.portal.search.learning.to.rank.api
  - com.liferay.portal.search.learning.to.rank.impl
```

**Values must use flat top-level keys.** The chart is deployed directly from the OCI registry, not as a subchart. Nesting under `liferay-default:` causes all overrides to be silently ignored.

### ArgoCD ApplicationSet

Apply an AppProject and ApplicationSet that scan the Git repository for environment directories:

```yaml
# appproject.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: liferay-application
  namespace: openshift-gitops
spec:
  destinations:
    - namespace: "liferay-dev"
      server: "https://kubernetes.default.svc"
  sourceRepos:
    - "oci://us-central1-docker.pkg.dev/liferay-artifact-registry/liferay-helm-chart/liferay-default"
    - "oci://us-central1-docker.pkg.dev/liferay-artifact-registry/liferay-helm-chart/liferay-default/*"
    - "https://github.com/<your-org>/<your-gitops-repo>.git"
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
```

The ApplicationSet uses a Git file generator to discover environments and a multi-source pattern to layer base and environment values from the Git repository onto the Helm chart from the OCI registry.

```bash
oc apply -f appproject.yaml -f applicationset.yaml
```

ArgoCD auto-discovers every `liferay.yaml` in `environments/*/` and creates an Application per environment.

---

## 6. Deploy Liferay

### Create Route

The Liferay Helm chart uses Gateway API for networking, which OpenShift does not provide by default. Create an OpenShift Route manually:

```bash
oc create route edge liferay-default \
  --service=liferay-default \
  --port=http \
  -n liferay-dev
```

The Route hostname (e.g., `liferay-default-liferay-dev.apps.openshift.yourdomain.com`) must match the `company.default.web.id` portal property in the values overlay. OpenShift provisions a wildcard TLS certificate automatically.

### Trigger Deployment

If using ArgoCD: push the values files to the Git repository. ArgoCD syncs within 3 minutes (or force sync via the ArgoCD console).

If using Helm directly:

```bash
helm install liferay \
  oci://us-central1-docker.pkg.dev/liferay-artifact-registry/liferay-helm-chart/liferay-default \
  --values base/liferay.yaml \
  --values environments/dev/liferay.yaml \
  -n liferay-dev
```

### Monitor Startup

First boot creates the database schema and deploys all OSGi bundles (10-15 minutes):

```bash
oc logs liferay-default-0 -n liferay-dev -f
```

The pod transitions from `Init:0/4` through init containers, then to `Running 0/1` (startup probe waiting), then to `Running 1/1` (ready).

### Validate

```bash
# Pod is ready
oc get pod liferay-default-0 -n liferay-dev
# Expect: 1/1 Running

# HTTPS access
curl -skI https://<route-hostname>
# Expect: HTTP 200

# Admin password
oc get secret liferay-default -n liferay-dev \
  -o jsonpath='{.data.LIFERAY_DEFAULT_PERIOD_ADMIN_PERIOD_PASSWORD}' | base64 -d
```

Login: `test@liferay.com` with the password above. The portal prompts for a password change on first login.

---

## 7. Post-Deploy

### License

Create a Kubernetes Secret from the license file and add volume configuration to the values overlay:

```bash
oc create secret generic liferay-license \
  -n liferay-dev \
  --from-file=license.xml=license.xml
```

Add to the values overlay:

```yaml
customEnv:
  x-license:
    - name: LIFERAY_DISABLE_TRIAL_LICENSE
      value: "true"

customVolumeMounts:
  x-license:
    - mountPath: /etc/liferay/mount/files/deploy
      name: license

customVolumes:
  x-license:
    - name: license
      secret:
        secretName: liferay-license
        items:
          - key: license.xml
            path: license.xml
```

### Search Reindex

After first boot, trigger a full reindex from Control Panel, Search, Index Actions, Reindex All. This creates the Liferay search indices in OpenSearch.

### Scaling

Change `replicaCount` in the values overlay and push to Git. ArgoCD rolls the StatefulSet. Clustering activates automatically when replicas exceed one.

---

## 8. Troubleshooting

The ten most common issues from two full deployment runs (32 lessons documented):

| Issue | Symptom | Fix |
|---|---|---|
| **Values silently ignored** | Pod shows chart defaults (readOnlyRootFilesystem true, no license mount) | Values must use flat top-level keys when chart is deployed directly from OCI, not nested under `liferay-default:` |
| **Pod rejected by SCC** | `unable to validate against any security context constraint` | Run `oc adm policy add-scc-to-user nonroot-v2 -z liferay-default -n <namespace>` |
| **Database connection fails** | `this._db is null` or HikariCP connection error | Check that PGO password has no special characters (`@];>}/` break JDBC URL interpolation). Use `password.type: AlphaNumeric` in the PostgresCluster spec. |
| **LIFERAY_DB_* env var collision** | `contextDestroyed`, `DBManagerUtil.getDBType() returned null` | Never name Kubernetes resources `liferay-*` in the same namespace. Liferay decodes all `LIFERAY_*` env vars as portal property overrides. |
| **Search index writer is null** | `NullPointerException: IndexWriterHelper`, missing ResourcePermission entries, broken page tree | OpenSearch must be green before Liferay starts. Wipe database, PVC, and search indices for a clean restart. |
| **Themes fail to deploy** | `Waiting on startup required bundles to activate: [/classic-theme]` | Set `readOnlyRootFilesystem: false`. The chart volume mounts do not cover all writable paths. |
| **Route returns 503** | Pod is running but Route shows Service Unavailable | Liferay is still in startup (10-15 minutes for first boot). Wait for the startup probe to pass. |
| **Virtual host error** | `NoSuchVirtualHostException` in logs, blank page via Route | Add `company.default.web.id=<route-hostname>` to portalProperties. |
| **ArgoCD cannot deploy** | `cannot create resource in namespace` | Label the namespace: `oc label namespace <ns> argocd.argoproj.io/managed-by=openshift-gitops` |
| **Corrupted first boot** | Login errors, permission checker exceptions, missing page tree | No partial recovery. Scale to 0, drop database, delete PVC, wipe search indices, scale to 1. |

---

## Image Tag Reference

| Tag | Status | Notes |
|---|---|---|
| `2025.q1.12-lts` | Validated | Works with external OpenSearch via downloaded connector modules. Recommended for initial deployment. |
| `2025.q4.12-slim` | Requires investigation | Slim startup script needs specific environment variable configuration. Use `managed-service-details` Secret pattern (same as AWS). |
| `2025.q4.12` | Partial | Sidecar Elasticsearch blocks startup when no search engine is available. Use the slim variant instead. |

---

## Reference

| Resource | Location |
|---|---|
| Helm chart (OCI) | `oci://us-central1-docker.pkg.dev/liferay-artifact-registry/liferay-helm-chart/liferay-default` |
| Helm values reference | [CNE Helm Values Reference](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/cloud-native-experience) |
| Configuring externally managed services | [CNE External Services](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/cloud-native-experience/cne-cloud-provider-ready/cne-aws-ready/2025-q4-and-earlier/configuring-externally-managed-services) |
| Managing secrets and licenses | [CNE Secrets and Licenses](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/cloud-native-experience/cne-cloud-provider-ready/cne-aws-ready/configuring-the-cne/managing-secrets-and-licenses) |
| GitOps repo example | [github.com/misaellr/liferay-openshift-gitops](https://github.com/misaellr/liferay-openshift-gitops) |
| OpenSearch connector modules | `https://releases.liferay.com/opensearch2/dxp/<version>/` |
| OpenSearch Kubernetes Operator | [github.com/opensearch-project/opensearch-k8s-operator](https://github.com/opensearch-project/opensearch-k8s-operator) |
| OpenSearch Docker images | [hub.docker.com/r/opensearchproject/opensearch](https://hub.docker.com/r/opensearchproject/opensearch/tags) |
| Crunchy PGO documentation | [access.crunchydata.com/documentation](https://access.crunchydata.com/documentation/postgres-operator/latest/) |
| Crunchy PGO user management | [PGO User Management](https://access.crunchydata.com/documentation/postgres-operator/latest/architecture/user-management) |
| OpenShift SCC guide | [A Guide to OpenShift and UIDs](https://www.redhat.com/en/blog/a-guide-to-openshift-and-uids) |
| OpenShift GitOps Operator | [OpenShift GitOps docs](https://docs.openshift.com/gitops/latest/understanding_openshift_gitops/about-redhat-openshift-gitops.html) |
| ArgoCD ApplicationSet | [ArgoCD ApplicationSet docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/) |
