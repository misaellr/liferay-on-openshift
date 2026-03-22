#!/bin/bash
# Create a Kubernetes Secret from a Liferay license file.
# Usage: bash create-license-secret.sh <namespace> <path-to-license.xml>

NAMESPACE=${1:-liferay-dev}
LICENSE_FILE=${2:-license.xml}

if [ ! -f "$LICENSE_FILE" ]; then
  echo "Error: License file not found at $LICENSE_FILE"
  echo "Usage: bash create-license-secret.sh <namespace> <path-to-license.xml>"
  exit 1
fi

oc create secret generic liferay-license \
  -n $NAMESPACE \
  --from-file=license.xml=$LICENSE_FILE

echo ""
echo "License secret created in namespace $NAMESPACE."
echo ""
echo "Add to your values overlay:"
echo "  customEnv.x-license:"
echo "    - name: LIFERAY_DISABLE_TRIAL_LICENSE"
echo "      value: \"true\""
echo "  customVolumeMounts.x-license:"
echo "    - mountPath: /etc/liferay/mount/files/deploy"
echo "      name: license"
echo "  customVolumes.x-license:"
echo "    - name: license"
echo "      secret:"
echo "        secretName: liferay-license"
echo "        items:"
echo "          - key: license.xml"
echo "            path: license.xml"
