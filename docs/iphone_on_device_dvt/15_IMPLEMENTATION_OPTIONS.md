# Implementation Options

## Option A - Reuse/Fork MIT Components

Candidate: idevice FFI or pinned subset.

STATUS: RECOMMENDED FOR POC

Pros:

- Already implements RPPairing, tunnel, RSD, DVT, LocationSimulation, and pairable-host.
- MIT license.
- Proven by Locus source.

Cons:

- Rust/Swift FFI integration.
- API is still evolving.
- Binary size and build pipeline need management.

## Option B - Wrap Existing Library As A Binary/Framework

STATUS: PLAUSIBLE

Wrap idevice as a static library/XCFramework with a minimal C ABI:

- read/import pairing file;
- connect raw RPPairing tunnel;
- open LocationSimulation;
- set/clear;
- diagnostic probes.

This is safer than exposing IOSSim to broad protocol internals.

## Option C - Port Minimum Protocol Implementation

STATUS: NOT FIRST

Port only RPPairing, TLS-PSK tunnel, RSD, DVT, and LocationSimulation to Swift.

Pros: smaller dependency surface and native integration.

Cons: high protocol risk, crypto mistakes, slower path to evidence.

## Option D - Implement Independently From Public Evidence

STATUS: NOT RECOMMENDED FOR POC

There is no Apple public spec for the full RPPairing/RSD/DVT stack. Independent implementation should come only after the architecture is experimentally proven and protocol boundaries are clear.

## Option E - Use pymobiledevice3

STATUS: NOT SUITABLE FOR IOS APP

GPL-3.0, Python runtime, host-side assumptions, and in-process PyTCP make it useful as evidence and current host tooling, not as the on-device iOS POC dependency.

## Option F - Use WLOC Code

STATUS: NOT FOR PRIMARY POC

WLOC projects are AGPL and implement a different engine. Use only for fallback research.
