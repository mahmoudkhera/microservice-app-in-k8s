#!/usr/bin/env bash

set -e
set -u

helm install  stock . \
  -f values-frontend.yaml \
  -f values-inventory.yaml \
  -f values-notifactions.yaml \
  -f values.yaml