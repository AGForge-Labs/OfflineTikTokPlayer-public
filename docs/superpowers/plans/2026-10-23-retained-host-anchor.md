# Retained Host Anchor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Root remains sole editor/executor; reuse only queued_start_review for read-only review.

**Goal:** Compare the native valid versus invalid host argument at the measured retained Previous stopped-clock boundary.

**Architecture:** Extend the existing request-scoped DEBUG start control and its actual native handoff receipt. Keep Release playback and CPP/audio anchoring unchanged; reuse the production benchmark with counterbalanced arms and original acceptance checks.

**Tech Stack:** Swift/AVFoundation/XCTest; existing Python/Bash exact-source validation on one unsigned standard Mac worker.

**Spec:** docs/superpowers/specs/2026-10-23-retained-host-anchor-design.md

## Global Constraints

- 250ms warm video,100ms warm audio,80ms alignment,5ms acquisition,two actual display ticks; original identity/progress/actual-stereo-zero/resource/cleanup guards unchanged.
- Root sole editor; one active CI/jobs1 and no local tests/builds while CI active; synthetic fixtures only.
- No Release behavior, merge/sign/upload/release/environment/credentials/private media changes.

## Review Focus

- Explicit seek must retain numeric item time and valid host fallback.
- Stale request must not alter a newer start's argument.
- Valid-host controls must still qualify finite actual host time.
- Invalid-host treatment must retain CPP/audio anchoring and visible-frame alignment.
- Missing treatment eligibility or incomplete arms must remain unqualified, not a performance pass.

---

### Task1: Isolate the actual native host argument

**Files:** PlaybackService.swift and PlaybackSelectionVideoRegressionTests.swift in their existing iOS paths.

**Interfaces:** Extend DebugInitialNativeStartControl with a default-preserving host policy; extend its scalar argument receipt. Benchmark accepts one optional host-policy argument only together with current-item-time control. Existing callers/defaults remain unchanged.

- [x]Baseline RED retained:40035741696 slow Previous868.490/504.320ms; original250ms guards failed on exact unchanged Release source. These failures do not prove a host cause.
- [ ]Add counterbalanced comparison and actual-host/fallback assertions before the DEBUG routing change.
- [ ]Route native host.invalid only when requested current-item-time and every original exact retained-zero guard qualifies; otherwise preserve production host anchor.
- [ ]Verify explicit-seek and stale-request fallback through actual handoff receipts; retain all existing benchmark assertions and callbacks.
- [ ]Run serial DEBUG/Release syntax, project/inventory/whitespace and Release-projection checks; obtain read-only source review; commit reviewed source with skip-ci.

### Task2: Execute one bounded source-pinned comparison

**Files:** Existing targeted workflow, check-native-playback-targeted.sh and its strict mocked harness selectors; ignored artifact readers/recovery/checkpoint notes.

- [ ]Select default benchmark, both counterbalanced orders and two focused fallback contracts in fresh owned hosts; preserve six SDK gates, budgets, exports and identity logic.
- [ ]Run17strict mocked harness checks/Bash/source binding/actionlint/whitespace, independent static review, freeze reviewed metadata and publish once after idle check.
- [ ]Recover exact structured counts, all arm guards, actual host arguments and stopped/positive/enqueue/readiness stages. Report missing evidence separately.
- [ ]Reject a failed or inconclusive optimization; make no production claim from clean audio. If supported, write the minimal production change against the retained RED and validate all applicable final-source gates before any completion claim.

Self-review: one native argument is isolated; every review-focus condition has an actual-receipt assertion. Existing user intent and execution constraints are already specified; no new product choice or approval flow is introduced.
