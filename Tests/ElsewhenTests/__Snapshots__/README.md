Reference images for `SnapshotTests`: the panel's fixed scene (`Snapshots.model()`),
rendered at 1x on the CI image. Re-record after a deliberate visual change:

    RECORD_SNAPSHOTS=1 swift test --filter SnapshotTests

Text rendering differs between macOS releases, so record on the macOS version CI runs.
