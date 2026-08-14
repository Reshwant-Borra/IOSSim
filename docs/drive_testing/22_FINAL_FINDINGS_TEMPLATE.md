# Final Findings Template

## Scope

Authorized device/test account, repository commit, IOSSim version, dates, route family, and comparison question.

## Completed Runs

List experiment/run IDs, methods, profiles, repetitions, host metrics, write failures, phone conditions, observations, and QC.

## Observed Pattern

State raw counts first. Use a percentage only for at least three completed comparable runs and label it exploratory.

## Example Run Finding

```text
Observed result:
Trip observed.

IOSSim observations:
The experiment emitted 0.61 mile of coordinates over 111.3 seconds.
Host-calculated average apparent speed was 19.7 mph.
All location writes completed successfully.

Interpretation:
The selected IOSSim profile was associated with a Trip observation under
the recorded conditions.

This run does not reveal which Life360 or Arity signals caused that result.

Verdict:
TRIP OBSERVED
```

## Uncertainty

Describe unmeasured device sensors, permissions, physical motion, network/application delay, GPX opacity, and other uncontrolled conditions.

## Recommended Next Test

Change one variable, repeat at least three times, and define the comparison before running.
