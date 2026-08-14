# Feature Flags

Drive Testing is disabled by default. Both flags on each side are required:

```text
IOS_SIM_ENABLE_EXPERIMENTAL=1
IOS_SIM_ENABLE_DRIVE_TESTING=1
VITE_ENABLE_EXPERIMENTAL_FEATURES=1
VITE_ENABLE_DRIVE_TESTING=1
```

The frontend launcher is rendered only when both Vite flags equal `1`. Every Drive Testing backend endpoint independently checks both backend flags and returns structured HTTP 403 with code `drive_testing_disabled` when disabled.

Stable Drive Mode does not require any experimental flag.
