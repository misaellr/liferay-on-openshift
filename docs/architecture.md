# Architecture: Liferay DXP on OpenShift

## End-State Components

```
OpenShift 4.x Cluster
├── Namespace: liferay-dev (or uat, prd)
│   ├── StatefulSet: liferay-default        (Liferay DXP)
│   │   ├── Init: prepopulate-data          (seeds PVC on first boot)
│   │   ├── Init: install-opensearch-modules (downloads connector JARs)
│   │   ├── Init: overlay                   (applies S3 overlays if enabled)
│   │   └── Init: wait-on-services          (waits for DB + search)
│   ├── Service: liferay-default            (ClusterIP :8080)
│   ├── Service: liferay-default-headless   (DNS clustering)
│   ├── Route: liferay-default              (edge TLS termination)
│   ├── ConfigMap: liferay-default          (portal properties, OSGi configs)
│   ├── Secret: liferay-default             (auto-generated admin password)
│   ├── Secret: liferay-license             (DXP license, optional)
│   ├── PVC: liferay-persistent-volume      (gp3-csi / managed-csi)
│   ├── PostgresCluster: pgdb              (Crunchy PGO managed)
│   │   ├── Pod: pgdb-pgha1-*              (PostgreSQL 16)
│   │   ├── Secret: pgdb-pguser-liferay    (auto-generated credentials)
│   │   └── PVC: pgdb-pgha1-*             (database storage)
│   └── StatefulSet: opensearch             (single-node, security disabled)
│       ├── Service: opensearch             (ClusterIP :9200)
│       └── PVC: data-opensearch-0          (search index storage)
├── Namespace: openshift-gitops
│   ├── ArgoCD Server                       (OpenShift GitOps Operator)
│   ├── AppProject: liferay-application
│   └── ApplicationSet: liferay-applicationset
└── Namespace: default (or operator namespace)
    └── Crunchy PGO Operator
```

## Data Flow

```
User (HTTPS) → OpenShift Route (TLS edge) → Service :8080 → Liferay Pod
                                                              ├── PostgreSQL (JDBC via Secret)
                                                              └── OpenSearch (HTTP :9200)
```

## GitOps Flow

```
Developer pushes liferay.yaml → GitHub → ArgoCD detects change → Syncs to cluster
```
