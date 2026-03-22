# Troubleshooting: Liferay DXP on OpenShift

Common issues encountered during deployment, derived from 32 lessons across two full deployment runs.

## Pod Rejected by SCC

**Symptom**: `unable to validate against any security context constraint`

**Cause**: The Liferay ServiceAccount does not have permission to use the nonroot-v2 SCC.

**Fix**:
```bash
oc adm policy add-scc-to-user nonroot-v2 -z liferay-default -n <namespace>
```

## Values Silently Ignored

**Symptom**: Pod shows chart defaults (readOnlyRootFilesystem true, no license mount, no runAsGroup) despite values overlay containing overrides.

**Cause**: Values wrapped under `liferay-default:` key. The chart is deployed directly from OCI, not as a subchart. Helm ignores unknown top-level keys without error.

**Fix**: Use flat top-level keys in all values files. Remove any `liferay-default:` nesting.

## Database Connection Fails

**Symptom**: `this._db is null` or HikariCP connection error.

**Cause**: Crunchy PGO auto-generated password contains special characters (`@];>}/`) that break JDBC URL interpolation in portal properties.

**Fix**: Set `password.type: AlphaNumeric` in the PostgresCluster spec. Or override the password after creation: `ALTER USER liferay WITH PASSWORD 'SimplePassword123'`.

## LIFERAY_DB Environment Variable Collision

**Symptom**: `contextDestroyed`, `DBManagerUtil.getDBType() returned null`. Pod starts but Liferay fails to initialize.

**Cause**: PostgresCluster named `liferay-db` creates Kubernetes Services that inject `LIFERAY_DB_*` environment variables. Liferay decodes all `LIFERAY_*` env vars as portal property overrides.

**Fix**: Never name Kubernetes resources `liferay-*` in the same namespace as Liferay. Use `pgdb`, `search`, etc.

## Search Index Writer is Null

**Symptom**: `NullPointerException: Cannot invoke IndexWriterHelper.commit()`. Missing ResourcePermission entries. Page tree not visible.

**Cause**: Liferay started before OpenSearch was reachable. The search index writer initialized as null and never recovered.

**Fix**: Ensure OpenSearch returns `"status":"green"` before scaling Liferay up. If corrupted, full wipe required: scale Liferay to 0, drop database, delete PVC, wipe OpenSearch indices, then scale back to 1.

## Themes Fail to Deploy

**Symptom**: `Waiting on startup required bundles to activate: [/classic-theme, /cms-theme]`

**Cause**: `readOnlyRootFilesystem: true` prevents Liferay from writing to `/opt/liferay/osgi/portal-war/` and Tomcat temp directories.

**Fix**: Set `securityContext.readOnlyRootFilesystem: false` in the values overlay.

## Route Returns 503

**Symptom**: OpenShift Route returns `503 Service Unavailable`.

**Cause**: Liferay is still in startup. First boot with schema creation takes 10-15 minutes. The startup probe allows 30 minutes before failing.

**Fix**: Wait. Monitor with `oc logs liferay-default-0 -n <namespace> -f`.

## Virtual Host Error

**Symptom**: `NoSuchVirtualHostException` in logs. Blank page when accessing via Route.

**Cause**: The OpenShift Route hostname is not registered as a virtual host in Liferay.

**Fix**: Add to portalProperties:
```
company.default.web.id=<route-hostname>
virtual.hosts.default.site.name=Guest
```

## ArgoCD Cannot Deploy to Namespace

**Symptom**: `cannot create resource "serviceaccounts" in API group "" in the namespace`

**Cause**: The OpenShift GitOps Operator restricts its ArgoCD instance to namespaces with a specific label.

**Fix**:
```bash
oc label namespace <namespace> argocd.argoproj.io/managed-by=openshift-gitops
```

## Corrupted First Boot

**Symptom**: Login errors, permission checker exceptions, missing page tree. HTTP 200 but UI is broken.

**Cause**: Database schema was partially populated during a failed or interrupted first boot.

**Fix**: No partial recovery. Full wipe:
```bash
oc scale statefulset liferay-default -n <namespace> --replicas=0
# Drop and recreate database
oc delete pvc liferay-persistent-volume-liferay-default-0 -n <namespace>
oc exec opensearch-0 -n <namespace> -- curl -s -X DELETE "http://localhost:9200/*"
oc scale statefulset liferay-default -n <namespace> --replicas=1
```
