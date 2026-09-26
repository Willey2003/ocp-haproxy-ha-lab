#!/usr/bin/env bash
# Regenerates openshift/20-prometheusrule.yaml from rules/lb.rules.yml, so the
# in-cluster and standalone alerts never drift apart.
set -euo pipefail
cd "$(dirname "$0")"
{
  echo "# GENERATED from rules/lb.rules.yml by render-prometheusrule.sh. Do not edit."
  echo "apiVersion: monitoring.coreos.com/v1"
  echo "kind: PrometheusRule"
  echo "metadata:"
  echo "  name: lb-alerts"
  echo "  namespace: lb-monitoring"
  echo "spec:"
  grep -v '^#' rules/lb.rules.yml | sed 's/^/  /'
} > openshift/20-prometheusrule.yaml
echo "wrote openshift/20-prometheusrule.yaml"
