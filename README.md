# Publish All Pending (Lightroom Classic)

Lightroom Classic plug-in that publishes **all pending items** across every publish service and published collection (including nested collection sets).

It calls `publishNow()` on each collection sequentially. Lightroom only uploads what it already considers pending (new / modified / deleted-to-remove). It does **not** force-republish unchanged photos.

## Install

1. Download or clone this repository.
2. In Lightroom Classic: **File → Plug-in Manager… → Add**
3. Select the `PublishAll.lrplugin` folder from this repo (or copy it into `%APPDATA%\Adobe\Lightroom\Modules\`).

## Use

**Library → Plug-in Extras → Publish All Pending Collections**

A progress bar shows `Publishing N/M: Service > Collection`. Failures are collected so one broken publisher does not stop the rest.

## Requirements

- Adobe Lightroom Classic (SDK 4+)
- One or more publish services configured in the catalog

## License

MIT