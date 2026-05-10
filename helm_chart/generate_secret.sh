#!/bin/bash
# Usage: ./seal.sh <KEY1=value1> [KEY2=value2] ...
# Output: indented "KEY: encrypted" lines ready to paste under encryptedData:

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <KEY=value> [KEY=value ...]" >&2
  exit 1
fi

for pair in "$@"; do
  KEY="${pair%%=*}"
  VALUE="${pair#*=}"

  ENCRYPTED=$(echo -n "$VALUE" | kubeseal \
    --raw \
    --scope cluster-wide \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
    --from-file=/dev/stdin)

  echo "    $KEY: $ENCRYPTED"
done