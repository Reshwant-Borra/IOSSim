# Experiment Queue

Queue entries contain an experiment, repeat count, Reset GPS choice, and delay after the run. Entries can be reordered, duplicated, or removed before validation.

Predefined queue selectors cover speed, distance, and method comparisons when matching experiments already exist. Review the estimated total duration and explicitly start the queue.

The default is stop on the first failure and require confirmation. A failed entry is never silently skipped. Stop Queue cancels the current run. Physical driving is never initiated or automated by IOSSim.
