#!/bin/bash
# Setup an OpenShift namespace for Liferay DXP deployment.
# Usage: bash setup-namespace.sh <namespace>

NAMESPACE=${1:-liferay-dev}

echo "=== Creating namespace $NAMESPACE ==="
oc new-project $NAMESPACE 2>/dev/null || echo "Namespace $NAMESPACE already exists"

echo "=== Granting nonroot-v2 SCC to Liferay ServiceAccount ==="
oc adm policy add-scc-to-user nonroot-v2 -z liferay-default -n $NAMESPACE

echo "=== Granting anyuid SCC for OpenSearch ==="
oc adm policy add-scc-to-user anyuid -z default -n $NAMESPACE

echo "=== Labeling namespace for ArgoCD ==="
oc label namespace $NAMESPACE argocd.argoproj.io/managed-by=openshift-gitops --overwrite

echo ""
echo "Namespace $NAMESPACE is ready. Next: deploy operators and data layer."
