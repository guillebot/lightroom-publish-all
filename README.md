# Publish All Pending (Lightroom Classic)

Lightroom Classic plug-in that publishes **pending items** across every publish service and published collection (including nested collection sets).

Collections with nothing pending (no new, modified, or to-remove photos) are skipped. Remaining collections are published sequentially via `publishNow()`. Lightroom only uploads what it already considers pending. It does **not** force-republish unchanged photos.

## Install

1. Download or clone this repository.
2. In Lightroom Classic: **File → Plug-in Manager… → Add**
3. Select the `PublishAll.lrplugin` folder from this repo (or copy it into `%APPDATA%\Adobe\Lightroom\Modules\`).

## Use

**Library → Plug-in Extras → Publish All Pending Collections**

Progress shows a check pass (`Checking N/M`), then `Publishing N/M: Service > Collection` for collections that have work. Failures are collected so one broken publisher does not stop the rest.

## Requirements

- Adobe Lightroom Classic (SDK 4+)
- One or more publish services configured in the catalog

## License

MIT
