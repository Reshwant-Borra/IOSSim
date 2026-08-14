# Exports and Reports

Each experiment directory can contain:

```text
manifest.json
route.json
planned_profile.json
events.jsonl
observations.json
summary.json
summary.csv
qc_report.json
qc_report.md
report.md
```

JSON export contains the redacted combined record. CSV export contains raw host-observable location-write rows. Full UDID, RSD address/credentials, command details, and address fields are redacted.

Reports include repository commit, configuration, planned and actual host metrics, write performance, QC, manual conditions, observed result, interpretation, uncertainty, next-test guidance, and a constrained verdict.
