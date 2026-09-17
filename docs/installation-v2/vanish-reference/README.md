# Vanish-referenced Veya installation plan

This directory answers one bounded product question: how Veya can reproduce the consumer setup behavior observed in Vanish 3.2.1 while retaining Veya's Swift/Rust device stack, Personal Team provisioning, secure pairing delivery, LocalDevVPN integration, and XCTest/XCUILocation runtime.

The documents are an implementation specification, not permission to copy Vanish code. Vanish evidence is limited to static inspection of the official local DMG. Confidence labels follow the parent Installation V2 evidence model.

Read in order: 00–09 establish the behavioral reference; 10–12 map it to Veya and identify gaps; 13–15 freeze the target design; 16–20 specify implementation and acceptance. The controlling plan is [20_VANISH_INFORMED_MASTER_IMPLEMENTATION_PLAN.md](20_VANISH_INFORMED_MASTER_IMPLEMENTATION_PLAN.md).

The decisive new finding is that Vanish does not avoid developer support. On macOS it runs bundled `pymobiledevice3 mounter auto-mount`, which obtains personalized DDI inputs from the doronz88 `DeveloperDiskImage` GitHub repository when its cache is absent, then uses Apple TSS personalization and mounts the image before establishing RSD. This proves a technical pattern, but it does not approve that asset source for Veya.

**Architecture status: `ARCHITECTURE_NOT_READY`.** Implementation may begin on independent milestones, but a shipping zero-Xcode release remains blocked on an approved DDI acquisition/distribution decision.
