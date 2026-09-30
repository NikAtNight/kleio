# Imports, automatic exports, and cloud settings

Owner: main implementation agent. Requirement source: the September 30, 2026 review and user authorization to fix prioritized bugs and improve imports and recording-start checks. Live answer suggestions are excluded.

## Behavior and failure handling

File selection, drops, Open With, and watched folders share the app-owned `Importer`. It copies security-scoped media and inspects duration outside the main actor, then saves each manifest and queues transcription on the main actor. A failed file leaves an error and removes its incomplete document folder. Other files in a batch can succeed. Podcast tracks form one document, so a failed track removes the entire incomplete import.

`ContentView` displays progress and import errors. Backup and restore wait for imports; imports refuse admission during backup or restore. Normal quit waits for accepted imports before preparing the transcription queue. Failed quit restores import admission.

`WatchFolderManager` requires an unchanged signature on two scans and marks a file seen only after successful import. It retains signatures for all existing media instead of truncating an unordered set at 5,000. Successful directory reads prune obsolete signatures. Missing or unreadable folders retain their configuration and history until they return.

`Exporter.exportAutomaticallyIfNeeded` exclusively creates each output file. A collision adds the document UUID, then a version number. Existing outputs and sidecars survive repeated, concurrent, and same-title exports. A failure leaves the saved transcript available. `TranscriptionQueue` exposes Retry Export independently of transcription and speaker inference. A partial export can leave completed formats; retry creates new versions of those formats.

`SummarySettings` supplies the Settings view and summary generation with one provider/model/key configuration. `SummaryCredentialStore` is the replaceable storage boundary; the app uses `KeychainSummaryCredentialStore`. Anthropic and OpenAI have separate Keychain accounts and model preferences. Migration pins the old provider before changing selection, retains plaintext after a failed Keychain read or write, and requires explicit assignment when ownership is unknown. Local and subscription CLI generation do not read Keychain.

Backups exclude both keys and the legacy ownership marker. Restore pins credentials retained on this Mac before changing provider preferences. An older backup's shared cloud model migrates to the backup's provider; legacy model values with no cloud provider are ignored. Restoring never reads or writes Keychain.

## Acceptance and evidence

The checkout is macOS on Apple silicon, based on `956c50f7ff48b0ff69949a58677cd0ccf4efb1b9` with uncommitted changes. Tests use generated media, temporary files, private preference suites, and injected credential storage.

- `ImporterTests` covers partial batches, cleanup, rejected backup-time admission, and quit waiting for an accepted import.
- `WatchFolderManagerTests` covers failed-import retry, 5,001 existing files across reload, unavailable folders returning, obsolete-signature pruning, and independent histories for nested watched folders.
- `ExporterTests` covers existing outputs, sidecars, repeated exports, concurrent writers, symlinks, empty titles, duplicate formats, and directory errors.
- `DocumentJobTests.testAutomaticExportFailureKeepsSavedTranscriptAndRetriesWithoutInference` verifies persisted readiness and export-only retry.
- `SummaryCredentialTests`, `SummaryProviderTests`, and `LibraryBackupTests` cover vendor separation, migration failures, explicit ownership assignment, configuration capture, excluded secrets, and restore across providers.

Commands and current results:

```sh
swift test --disable-automatic-resolution
swift build -c release --disable-automatic-resolution
git diff --check
```

PASS: the full suite ran 392 tests with zero failures. The release build and `git diff --check` passed. A fresh reviewer found two issues, both repaired and rechecked, with no remaining code findings. The reviewer stayed read-only by instruction; its tools did not enforce that restriction. Logs, review notes, and the final diff are retained under ignored `build/workflow-fixes-review/`. An existing weak-capture warning remains in `ModelManager.swift`.

NOT RUN: actual Keychain interaction, live call capture, permission transitions, and native UI acceptance for this patch. The reviewer and tests do not read user credentials, change permissions, or record calls. Existing native acceptance remains in `docs/meeting-recorder-validation.md`.
