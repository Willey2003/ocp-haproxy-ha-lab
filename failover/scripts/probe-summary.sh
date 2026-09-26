#!/usr/bin/env bash
# Summarize a probe.csv. Prints one "target longest_outage_seconds" line per
# target on stdout and a readable table on stderr.
#
# An outage is the time from the first failed request to the next successful
# one for the same target. An outage still open when the log ends is measured
# to the last request.

set -o errexit -o nounset -o pipefail
csv=${1:?usage: probe-summary.sh probe.csv}

sort -t, -k1,1n "$csv" | awk -F, '
  $1 == "epoch" { next }
  {
    t = $2; ts = $1 + 0
    total[t]++; last[t] = ts
    if ($3 == 1) {
      if (t in down) {
        d = ts - down[t]; if (d > worst[t]) worst[t] = d
        outages[t]++; delete down[t]
      }
    } else {
      failed[t]++
      if (!(t in down)) down[t] = ts
    }
  }
  END {
    printf "%-15s %8s %8s %8s %12s\n", "target", "requests", "failed", "outages", "longest(s)" > "/dev/stderr"
    for (t in total) {
      if (t in down) {
        printf "%-15s %8d %8d %8d %12s\n", t, total[t], failed[t], outages[t] + 1, "UNRECOVERED" > "/dev/stderr"
        printf "%s 9999\n", t
        continue
      }
      printf "%-15s %8d %8d %8d %12.1f\n", t, total[t], failed[t] + 0, outages[t] + 0, worst[t] + 0 > "/dev/stderr"
      printf "%s %.1f\n", t, worst[t] + 0
    }
  }'
