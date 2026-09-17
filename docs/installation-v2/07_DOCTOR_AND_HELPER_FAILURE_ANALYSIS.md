# Doctor and helper failure analysis

## Current behavior

`doctor` is a JSON subcommand of `IOSSimProvisioner` in packaged operation. Historical development operation invoked `iossim doctor --json` through Python. There is no independent doctor binary. `CONFIRMED_LOCAL_IOSSIM_CODE`

```text
GUI Check Setup
  -> IOSSimSetupEngine.doctor()
  -> BundledProvisioningEngine.run(["doctor", "--json"])
  -> Contents/MacOS/IOSSimProvisioner
  -> DoctorStatus JSON
```

When the helper is absent, `IOSSimMacApp` can construct `UnavailableIOSSimSetupEngine`. Its doctor call throws `ProcessFailure(commandName: "doctor")`. `SetupStore.friendlyError` still contains repository/development-helper guidance and generic command wording. Thus “could not find doctor” can mean missing helper, damaged app, wrong schema, launch denial, or a failed doctor domain check. That collapses five layers into one misleading message.

## V2 handshake

Before invoking a domain command, the bundled engine validates:

1. helper exists at the manifest path and is a regular executable inside the app;
2. helper SHA-256 matches the signed release manifest;
3. helper code signature/team/designated requirement matches the containing app;
4. `IOSSimProvisioner protocol-info --json` returns compatible helper, setup, artifact, and wire schemas;
5. bridge and payload identities match the same release manifest.

Failures map to stable codes:

| Condition | Code | User message |
| --- | --- | --- |
| Missing helper | `VEYA-INTEGRITY-001` | “Veya is incomplete. Reinstall this release.” |
| Signature/hash mismatch | `VEYA-INTEGRITY-002` | “Veya’s installed files failed verification.” |
| Helper cannot launch | `VEYA-INTEGRITY-003` | “macOS could not start Veya’s setup service.” |
| Schema incompatible | `VEYA-UPDATE-001` | “This app and setup service are from different releases.” |
| Valid helper, doctor domain failure | Domain-specific code | Exact device/account/prerequisite action |

No root message mentions “doctor.” Developer detail may include the subcommand after redaction. Helper stdout is parsed only after a successful protocol envelope; unstructured stderr cannot choose user remediation.

## Repair

Integrity faults do not trigger Apple auth, signing, state deletion, or device mutation. The only repair is reinstalling the same or newer canonical artifact. Domain doctor faults remain read-only and route to their owning state-machine step.
