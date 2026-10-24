# Persistent Native Preload Owner Plan

> Root remains sole editor/executor. Reuse queued_start_review only for read-only review. Apply the already-read executing-plans workflow; existing task authorization covers routine source and free unsigned checks without a new approval question.

**Goal:** Resolve whether a distinct persistent native owner can actually prepare B while A continues, before designing a production owner pool.

**Spec:** docs/superpowers/specs/2026-10-23-retained-native-preload-owner-design.md

**Architecture:** Test-only native helper, independent B item/output/resource; keep queued B and selected A untouched. Compare native preroll OFF/ON in both orders with matched fixed dwell. Retain the helper through actual decoded B progress, then acknowledge cleanup. No Release/App/Core change.

## Constraints and review focus

- Preserve all original production benchmark/acceptance functions,250ms warm video,100ms audio,80ms alignment,5ms acquisition,two display ticks,actual-stereo-zero/progress/resource/cleanup guards.
- Capability B is not selected by the app; report that scope explicitly and retain original A audio/visible progress.
- No original queued item transfer; distinct clone identity and exact current helper owner must survive every await and SDK query/copy.
- At most two native players,three items/outputs,two copied images,one helper;unchanged PCM sources/storage.
- One-second matched warm window;only-ready rate-zero ON preroll;timely exactly-once callback versus zero OFF callbacks. Missing capability is failure,not qualified refusal.
- Native cancellation/detachment/resource retirement/callback ACK before fixture deletion or next arm;retain on uncertainty.
- One active CI/jobs1;no local tests/builds while active;public synthetic fixtures only;no release actions.

### Task1: Add the exact native ownership capability tests

- [x] Retain baseline REDs400094 queued unknown/no image and400389 four timing assertions;reject host invalid without repeating completed comparison.
- [x] Correct duplicate host wrapper emission with existing native receipt RED and serial syntax/project checks;commit50f3324,publication confirmed,native proof pending.
- [ ] Add two counterbalanced test entrypoints with one runtime-host emission each.
- [ ] Reuse existing cold/stream fixture setup via a nil-default test-only argument;all original operations/acceptance remain unchanged when absent.
- [ ] Implement distinct helper/item/output preparation,actual B image/progress and A continuity/resource ownership guards,with bounded common cleanup.
- [ ] Run serial DEBUG/Release syntax,project/test inventory,whitespace and byte-preservation checks;read-only review;freeze source with skip-ci.

### Task2: Validate the decision and corrected fallback wiring once

- [ ] Route default benchmark,two new counterbalanced capability cases,two corrected native fallback contracts;preserve harness proof/budgets/exports and all original limits.
- [ ] Run existing17strict mocked harness checks,Bash/source binding/actionlint/whitespace;freeze reviewed metadata and publish once after idle check.
- [ ] Recover exact structured results and actual ownership/preroll/pixel/progress/cleanup receipts. Distinguish native failures from missing controls,receipt faults and export faults.
- [ ] Reject unqualified capability. If supported,design the minimal bounded production pool and add actual app-handoff regressions before promotion;do not claim app readiness or a silence fix from helper capability.

Deliver the concrete decision,exact sources/diffs and verification evidence. No completion or release claim from partial,clean-nonrecurring or helper-only evidence.

### Task3: Attribute the unmeasured capability boundary without changing ownership

- [x] Reconcile40042486706:114Core,5native2pass/3fail,4assertions;all4helper arms decoded/advanced and ACK;no preroll benefit established;fallback host contracts GREEN. Preserve historical silence and all app acceptance failures.
- [ ] Add two matched tracingOFF/ON orders with prerollOFF throughout;retain original ownership SDK operations. Bound recording to4phases x9scalar aggregates,no RT work.
- [ ] Capture image-completed/deadline and cleanup/probe/A checkpoints before XCTest assertion reporting;preserve all actual frame/audio/progress/resource/callback limits.
- [ ] Serial syntax/project/inventory/preserved-source/whitespace checks and read-only review;freeze exact source. Route unchanged default plus only the two new attribution cases;do not repeat unchanged fallback contracts.
- [ ] Recover structured and exact span/deadline receipts. Require a failure joined to its actual operation or explicitly conclude no cause established. Compare OFF/ON timing for tracing effects. Select the smallest supported intervention;do not promote helper-only evidence into app acceptance.
