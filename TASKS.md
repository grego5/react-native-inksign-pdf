# Restore native file picking through the document API

Status: Implementation complete (01–04); Task 05 dispatched, results pending

## Goal

Restore native PDF/image selection, cache staging, and cleanup without a mounted
`InkSignView` or an Expo picker dependency. `createDocument` synchronously returns
the owner; `document.addPages` owns native selection and subsequent imports.

## Contract

```ts
const document = createDocument({ sources: [uri] });
const images = createDocument();
await document.addPages();
await images.addPages({ type: 'image' });
await document.addPages({ sources: [uri] });
```

- Creation with omitted/empty sources returns an empty owner. Initial sources
  load in the FIFO before dependent commands and establish clean base content.
  Loading failure reaches viewer state and rejects dependent operations; close remains valid.
- `addPages()` with omitted sources invokes native selection; explicit inputs bypass UI.
  `sources: []` remains a no-op. `type` limits PDF/image inputs; omission accepts both.
- Pickers permit ordered multiple selection; imports publish the complete selection atomically.
- User cancellation returns zero added pages with unchanged state. Lifecycle cancellation rejects.
- Native input coordination owns presentation, provider access, and staged files.
  The core owns FIFO admission, mutation, publication, and terminal cleanup.
- Picker waiting preserves document command order without starting a structural
  write or ending a text transaction. Close cancels waiting/queued selection;
  admitted noninteractive import work drains normally.
- Viewer attachment, mode, viewport, history policy, fonts, and export remain
  independent of picker UI. Imports preserve selected page identity.

## Task order

1. [Public contract and generated bindings](Tasks/01-public-picker-contract.md) — complete
2. [Android native selection and staging](Tasks/02-android-native-picker.md) — implemented; verification pending
3. [iOS native selection and staging](Tasks/03-ios-native-picker.md) — implemented; verification pending
4. [Example and current-state documentation](Tasks/04-example-and-docs.md) — complete
5. [Focused regression verification](Tasks/05-verification.md) — dispatched to authorized chat; results pending

Tasks 02 and 03 depend on 01; 04 follows both. Native implementations now match
the optional-input generated signatures.

## Constraints and completion

- Implementation baseline: `b517d895` (`reorganize source files`). Public bindings,
  native coordinators, example integration, and current-state docs are updated.
- Shared requirements govern both platforms. Reuse existing input encoding,
  artifact policies, PDFium assembly, and document publication.
- Put regression additions and execution in Task 05. Tests/builds remain deferred
  in the implementation chat. Use the authorized verification chat
  `01a12c88-60f1-7500-85a4-10ff730af7a2` when implementation is ready; results arrive
  asynchronously. Do not poll/read its chat or treat a dispatch as a passing run.
- Completion requires native picker lifecycle/resource checks, existing explicit
  imports preserved, example package removal, accurate docs, and recorded validation
  limits. A missing device/toolchain remains an explicit verification gap.
