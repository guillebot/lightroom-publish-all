--[[
  Publish All Pending Collections

  Opens a floating window listing every published collection across all
  publish services, checks what is pending in each one, then publishes the
  collections that have work. Collections with nothing pending are skipped.

  Lightroom only uploads what it already considers pending (new / modified /
  to-remove); nothing is marked for republish here.
]]

local LrApplication = import "LrApplication"
local LrBinding = import "LrBinding"
local LrDate = import "LrDate"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks = import "LrTasks"
local LrView = import "LrView"

local PublishStatus = require "PublishStatus"

local bind = LrView.bind

local BAR_WIDTH = 30
local POLL_SECONDS = 0.25

local function progressBar(done, total)
  local fraction = 0
  if total and total > 0 then
    fraction = done / total
  end
  if fraction < 0 then
    fraction = 0
  elseif fraction > 1 then
    fraction = 1
  end

  local filled = math.floor(fraction * BAR_WIDTH + 0.5)
  return string.format(
    "[%s%s]  %d%%  (%d/%d)",
    string.rep("=", filled),
    string.rep("-", BAR_WIDTH - filled),
    math.floor(fraction * 100 + 0.5),
    done,
    total or 0
  )
end

local function elapsedText(seconds)
  if seconds < 60 then
    return string.format("%ds", math.floor(seconds))
  end
  return string.format("%dm %02ds", math.floor(seconds / 60), math.floor(seconds % 60))
end

local function collectTargets()
  local targets = {}
  local catalog = LrApplication.activeCatalog()

  local function addCollection(collection, serviceName, path)
    targets[#targets + 1] = {
      collection = collection,
      label = serviceName .. "  >  " .. path,
    }
  end

  local function walkSet(set, serviceName, prefix)
    local setName = set:getName() or "(set)"
    local nested = prefix .. setName .. " / "
    for _, collection in ipairs(set:getChildCollections()) do
      addCollection(collection, serviceName, nested .. (collection:getName() or "(unnamed)"))
    end
    for _, childSet in ipairs(set:getChildCollectionSets()) do
      walkSet(childSet, serviceName, nested)
    end
  end

  for _, service in ipairs(catalog:getPublishServices()) do
    local serviceName = service:getName() or service:getPluginId() or "(service)"
    for _, collection in ipairs(service:getChildCollections()) do
      addCollection(collection, serviceName, collection:getName() or "(unnamed)")
    end
    for _, set in ipairs(service:getChildCollectionSets()) do
      walkSet(set, serviceName, "")
    end
  end

  return targets
end

local function buildContents(props, targets, state)
  local f = LrView.osFactory()

  local listArgs = { spacing = 2 }
  for i, target in ipairs(targets) do
    listArgs[#listArgs + 1] = f:row {
      spacing = f:label_spacing(),
      f:static_text {
        title = bind("status_" .. i),
        width_in_chars = 11,
      },
      f:static_text {
        title = target.label,
        width_in_chars = 44,
        truncation = "middle",
      },
      f:static_text {
        title = bind("detail_" .. i),
        width_in_chars = 28,
        truncation = "tail",
      },
    }
  end

  return f:column {
    bind_to_object = props,
    spacing = f:control_spacing(),

    f:static_text {
      title = bind("headline"),
      font = "<system/bold>",
      width_in_chars = 88,
    },
    f:static_text {
      title = bind("bar"),
      width_in_chars = 88,
    },
    f:static_text {
      title = bind("counters"),
      width_in_chars = 88,
    },

    f:separator { fill_horizontal = 1 },

    f:scrolled_view {
      width = 780,
      height = 360,
      horizontal_scroller = false,
      f:column(listArgs),
    },

    f:row {
      spacing = f:control_spacing(),
      f:push_button {
        title = "Stop after current",
        enabled = bind("running"),
        action = function()
          props.stopRequested = true
          props.footer = "Stop requested - finishing the collection in progress."
        end,
      },
      f:push_button {
        title = "Close",
        action = function()
          if state.closeDialog then
            state.closeDialog()
          end
        end,
      },
      f:static_text {
        title = bind("footer"),
        width_in_chars = 56,
        truncation = "middle",
      },
    },
  }
end

-- Runs the check pass and then publishes queued collections, reporting each
-- step through the bound property table.
local function runPublishPass(props, targets, state)
  local function setProp(key, value)
    if state.closed then
      return
    end
    pcall(function()
      props[key] = value
    end)
  end

  local stats = { queued = 0, upToDate = 0, published = 0, failed = 0 }

  local function refreshCounters()
    setProp("counters", string.format(
      "Pending: %d      Nothing pending: %d      Published: %d      Failed: %d",
      stats.queued,
      stats.upToDate,
      stats.published,
      stats.failed
    ))
  end

  refreshCounters()

  local queue = {}

  for i, target in ipairs(targets) do
    if state.closed or props.stopRequested then
      break
    end

    setProp("headline", string.format("Checking %d of %d collections", i, #targets))
    setProp("bar", progressBar(i - 1, #targets))
    setProp("status_" .. i, "checking")

    local counts = PublishStatus.pendingCounts(target.collection)
    setProp("detail_" .. i, PublishStatus.describe(counts))

    if counts.unknown or counts.total > 0 then
      setProp("status_" .. i, "pending")
      stats.queued = stats.queued + 1
      queue[#queue + 1] = { index = i, target = target }
    else
      setProp("status_" .. i, "up to date")
      stats.upToDate = stats.upToDate + 1
    end

    refreshCounters()
    LrTasks.yield()
  end

  setProp("bar", progressBar(#targets, #targets))

  if state.closed then
    return
  end

  if #queue == 0 then
    setProp("headline", string.format("Nothing to publish - checked %d collection(s).", #targets))
    setProp("bar", progressBar(1, 1))
    setProp("footer", "")
    setProp("running", false)
    return
  end

  local failures = {}

  for position, entry in ipairs(queue) do
    if state.closed or props.stopRequested then
      break
    end

    local i = entry.index
    local target = entry.target

    setProp("headline", string.format(
      "Publishing %d of %d: %s", position, #queue, target.label
    ))
    setProp("bar", progressBar(position - 1, #queue))
    setProp("status_" .. i, "publishing")

    local startedAt = LrDate.currentTime()
    local finished = false

    local ok, err = pcall(function()
      target.collection:publishNow(function()
        finished = true
      end)
    end)

    if ok then
      -- publishNow reports completion through its callback, so poll until it
      -- fires. A stop request lets the current collection finish.
      while not finished and not state.closed do
        LrTasks.sleep(POLL_SECONDS)
        setProp("detail_" .. i, "publishing... " .. elapsedText(LrDate.currentTime() - startedAt))
      end

      if finished then
        stats.published = stats.published + 1
        setProp("status_" .. i, "published")
        setProp("detail_" .. i, "done in " .. elapsedText(LrDate.currentTime() - startedAt))
      end
    else
      stats.failed = stats.failed + 1
      failures[#failures + 1] = target.label .. " -- " .. tostring(err)
      setProp("status_" .. i, "FAILED")
      setProp("detail_" .. i, tostring(err))
    end

    refreshCounters()
  end

  if state.closed then
    return
  end

  setProp("bar", progressBar(#queue, #queue))
  setProp("running", false)

  if props.stopRequested then
    setProp("headline", string.format(
      "Stopped. Published %d of %d queued collection(s).", stats.published, #queue
    ))
  else
    setProp("headline", string.format(
      "Finished. Published %d of %d queued collection(s).", stats.published, #queue
    ))
  end

  if #failures > 0 then
    setProp("footer", string.format("%d failed - see the list above.", #failures))
  else
    setProp("footer", "No errors.")
  end
end

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext("PublishAllPending", function(context)
    local targets = collectTargets()

    if #targets == 0 then
      LrDialogs.message(
        "Publish All Pending",
        "No published collections were found in this catalog.",
        "info"
      )
      return
    end

    local props = LrBinding.makePropertyTable(context)
    props.headline = string.format("Found %d published collection(s).", #targets)
    props.bar = progressBar(0, #targets)
    props.counters = ""
    props.footer = ""
    props.running = true
    props.stopRequested = false

    for i = 1, #targets do
      props["status_" .. i] = "waiting"
      props["detail_" .. i] = ""
    end

    local state = { closed = false }
    local contents = buildContents(props, targets, state)

    LrTasks.startAsyncTask(function()
      runPublishPass(props, targets, state)
    end)

    -- blockTask keeps this function context (and the bindings) alive for as
    -- long as the window is open.
    LrDialogs.presentFloatingDialog(_PLUGIN, {
      title = "Publish All Pending",
      contents = contents,
      blockTask = true,
      save_frame = "publishAllWindowPosition",
      onShow = function(dialog)
        state.closeDialog = dialog.close
      end,
      windowWillClose = function()
        state.closed = true
        props.stopRequested = true
      end,
    })
  end)
end)
