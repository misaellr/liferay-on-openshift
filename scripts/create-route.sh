#!/bin/bash
# Create an OpenShift Route for Liferay DXP.
# The Helm chart uses Gateway API (not Ingress/Routes), so this is created externally.
# Usage: bash create-route.sh <namespace>

NAMESPACE=${1:-liferay-dev}

oc create route edge liferay-default \
  --service=liferay-default \
  --port=http \
  -n $NAMESPACE

HOSTNAME=$(oc get route liferay-default -n $NAMESPACE -o jsonpath='{.spec.host}')

echo ""
echo "Route created: https://$HOSTNAME"
echo ""
echo "Update your values overlay with:"
echo "  company.default.web.id=$HOSTNAME"
echo "  virtual.hosts.default.site.name=Guest"
echo ""
echo "And update OpenSearch networkHostAddresses to use namespace: $NAMESPACE"
