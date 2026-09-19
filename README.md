# Publish All Pending (Lightroom Classic)

Lightroom Classic plug-in that publishes **pending items** across every publish service and published collection (including nested collection sets), and shows what it is doing in a live status window.

Collections with nothing pending (no new, modified, or to-remove photos) are skipped. The rest are published sequentially via `publishNow()`. Lightroom only uploads what it already considers pending. It does **not** force-republish unchanged photos.

## Install

1. Download or clone this repository.
2. In Lightroom Classic: **File → Plug-in Manager… → Add**
3. Select the `PublishAll.lrplugin` folder from this repo (or copy it into `%APPDATA%\Adobe\Lightroom\Modules\`).

## Use

**Library → Plug-in Extras → Publish All Pending Collections**

A floating window opens with one row per published collection:

```
Publishing 2 of 5: Flickr  >  Travel / Iceland
[==============----------------]  47%  (2/5)
Pending: 5      Nothing pending: 18      Published: 1      Failed: 0

published    Flickr  >  Portfolio                      done in 41s
publishing   Flickr  >  Travel / Iceland               publishing... 1m 12s
incomplete   Hard Drive  >  Web exports                still 2 new
timed out    SmugMug  >  Family                        no result after 30m 00s; moved on
pending      Hard Drive  >  Archive                    3 new, 1 modified
up to date   Zenfolio  >  Prints                       nothing pending
waiting      SmugMug  >  Events
```

The run has two phases. First every collection is inspected and labelled with what is pending, then the queued collections are published one at a time with an elapsed timer. The window stays open when the run ends so you can read the results.

- **Skip current** — gives up on the collection in progress and moves to the next one.
- **Stop after current** — stops queueing new collections; the one in progress is allowed to finish.
- **Close window** — closes the window. The run keeps going.
- **Reveal log** — opens the folder containing the run log.
- **Give up if nothing happens for** — stall limit (default 15 minutes, remembered between runs).

Lightroom's floating windows have no minimize button, so the run is also reported in Lightroom's own progress area at the top left. That stays visible after the window is closed and carries the cancel control for the whole run.

### Resilience

A publish service that fails usually puts up its own error dialog — for example `Can't update this collection. An internal error has occurred: bad argument #1 to '?' (string expected, got nil)`. That message comes from the service's own code, not from this plug-in, and cannot be suppressed from here. What this plug-in can do is refuse to get stuck behind one:

- An error raised by `publishNow` is recorded against that row and the run continues.
- While a collection publishes, its remaining count is re-checked every 20 seconds. If nothing has completed within the stall limit, the collection is marked `stalled` and the run moves on. Watching for progress rather than total elapsed time means a slow but healthy upload is left alone.
- After each publish the collection is re-checked. If items are still pending, the row is marked `incomplete` rather than `published`, so a partial failure is visible instead of silently counted as success.
- Any unexpected error in the run itself is reported in the window instead of killing the task.

Collections needing attention are listed in the footer at the end of the run.

### Run log

Every run appends to `PublishAllPending.log` in your Documents folder, recording which collection was being published when something went wrong:

```
2026-09-19 17:52:04  publish  SmugMug  >  Family
2026-09-19 17:58:31  PARTIAL  SmugMug  >  Family -- finished in 6m 27s but still 4 new (the publish service probably reported an error)
```

This is the fastest way to find out which service raised an error dialog, since Lightroom's dialog does not name the collection.

### How "pending" is detected

Lightroom exposes no direct "has pending items" API. The plug-in compares collection membership against `getPublishedPhotos()` records:

| Condition | Counted as |
|---|---|
| In collection, no publication record | new |
| Record with no remote id / publish count 0 | new |
| Record with the edited flag set | modified |
| Published record no longer in the collection | to remove |

If a collection's status cannot be read, it is queued and published anyway rather than skipped.

## Development

`tools/check_lua_blocks.py` does a structural check of the Lua sources (UTF-8 encoding, block and bracket balance) — useful because Lightroom only reports load errors once the plug-in is added:

```bash
python tools/check_lua_blocks.py
```

## Requirements

- Adobe Lightroom Classic (SDK 5+, for the floating window)
- One or more publish services configured in the catalog

## License

MIT
