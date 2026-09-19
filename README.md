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
pending      Hard Drive  >  Web exports                3 new, 1 modified
up to date   Hard Drive  >  Archive                    nothing pending
waiting      SmugMug  >  Family                        
```

The run has two phases. First every collection is inspected and labelled with what is pending, then the queued collections are published one at a time with an elapsed timer. The window stays open when the run ends so you can read the results.

- **Stop after current** — stops queueing new collections; the one in progress is allowed to finish.
- **Close** — closes the window and stops the run.

Failures are recorded per row, so one broken publish service does not stop the rest.

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
