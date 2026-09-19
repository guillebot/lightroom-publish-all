--[[
  Publish All Pending Collections

  Opens a floating window listing every published collection across all
  publish services, checks what is pending in each one, then publishes the
  collections that have work. Collections with nothing pending are skipped.

  Lightroom only uploads what it already considers pending (new / modified /
  to-remove); nothing is marked for republish here.

  The run is driven from a background task and reported through Lightroom's
  own progress area as well as the window, so closing the window does not
  stop it. A publish service that hangs or raises its own error dialog is
  skipped after a timeout instead of stalling the whole run.
]]

local LrApplication = import "LrApplication"
local LrBinding = import "LrBinding"
local LrDate = import "LrDate"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrPrefs = import "LrPrefs"
local LrProgressScope = import "LrProgressScope"
local LrTasks = import "LrTasks"
local LrView = import "LrView"

local PublishStatus = require "PublishStatus"

local bind = LrView.bind

local BAR_WIDTH = 30
local POLL_SECONDS = 0.25
local DEFAULT_TIMEOUT_MINUTES = 30

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
        width_in_chars = 30,
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
      width_in_chars = 92,
    },
    f:static_text {
      title = bind("bar"),
      width_in_chars = 92,
    },
    f:static_text {
      title = bind("counters"),
      width_in_chars = 92,
    },

    f:separator { fill_horizontal = 1 },

    f:scrolled_view {
      width = 800,
      height = 360,
      horizontal_scroller = false,
      f:column(listArgs),
    },

    f:row {
      spacing = f:control_spacing(),
      f:push_button {
        title = "Skip current",
        enabled = bind("running"),
        action = function()
          props.skipRequested = true
        end,
      },
      f:push_button {
        title = "Stop after current",
        enabled = bind("running"),
        action = function()
          props.stopRequested = true
          props.footer = "Stopping after the collection in progress."
        end,
      },
      f:push_button {
        title = "Close window",
        action = function()
          if state.closeDialog then
            state.closeDialog()
          end
        end,
      },
      f:static_text { title = "Give up on a collection after" },
      f:popup_menu {
        value = bind("timeoutMinutes"),
        width_in_chars = 12,
        items = {
          { title = "no limit", value = 0 },
          { title = "5 minutes", value = 5 },
          { title = "15 minutes", value = 15 },
          { title = "30 minutes", value = 30 },
          { title = "60 minutes", value = 60 },
        },
      },
    },

    f:static_text {
      title = bind("footer"),
      width_in_chars = 92,
      truncation = "middle",
    },
  }
end

-- Runs the check pass and then publishes queued collections, reporting each
-- step through the bound property table and the Lightroom progress area.
local function runPublishPass(props, targets, state, progress)
  local function setProp(key, value)
    pcall(function()
      props[key] = value
    end)
  end

  local stats = {
    queued = 0,
    upToDate = 0,
    published = 0,
    incomplete = 0,
    skipped = 0,
    failed = 0,
  }

  local issues = {}

  local function refreshCounters()
    setProp("counters", string.format(
      "Published %d   Incomplete %d   Skipped %d   Failed %d      |      Pending %d   Up to date %d",
      stats.published,
      stats.incomplete,
      stats.skipped,
      stats.failed,
      stats.queued,
      stats.upToDate
    ))
  end

  local function stopping()
    return props.stopRequested == true or progress:isCanceled()
  end

  refreshCounters()

  local queue = {}

  for i, target in ipairs(targets) do
    if stopping() then
      break
    end

    setProp("headline", string.format("Checking %d of %d collections", i, #targets))
    setProp("bar", progressBar(i - 1, #targets))
    setProp("status_" .. i, "checking")
    progress:setCaption(string.format("Checking %d of %d", i, #targets))
    progress:setPortionComplete(i - 1, #targets)

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

  if #queue == 0 then
    local headline
    if stopping() then
      headline = "Stopped before publishing."
    else
      headline = string.format("Nothing to publish - checked %d collection(s).", #targets)
    end
    setProp("headline", headline)
    setProp("bar", progressBar(1, 1))
    setProp("footer", "")
    setProp("running", false)
    return headline
  end

  for position, entry in ipairs(queue) do
    if stopping() then
      break
    end

    local i = entry.index
    local target = entry.target

    setProp("skipRequested", false)
    setProp("headline", string.format(
      "Publishing %d of %d: %s", position, #queue, target.label
    ))
    setProp("bar", progressBar(position - 1, #queue))
    setProp("status_" .. i, "publishing")
    progress:setCaption(string.format("Publishing %d of %d: %s", position, #queue, target.label))
    progress:setPortionComplete(position - 1, #queue)

    local startedAt = LrDate.currentTime()
    local finished = false
    local outcome

    -- publishNow can throw straight away, and a publish service that fails
    -- may never invoke the callback at all, so both paths are handled.
    local started, err = pcall(function()
      target.collection:publishNow(function()
        finished = true
      end)
    end)

    if not started then
      outcome = "failed"
      stats.failed = stats.failed + 1
      issues[#issues + 1] = target.label .. " -- " .. tostring(err)
      setProp("status_" .. i, "FAILED")
      setProp("detail_" .. i, tostring(err))
    else
      local timeoutSeconds = (tonumber(props.timeoutMinutes) or 0) * 60

      while not finished do
        if progress:isCanceled() then
          outcome = "cancelled"
          break
        end

        if props.skipRequested then
          outcome = "skipped"
          break
        end

        local elapsed = LrDate.currentTime() - startedAt
        if timeoutSeconds > 0 and elapsed > timeoutSeconds then
          outcome = "timeout"
          break
        end

        setProp("detail_" .. i, "publishing... " .. elapsedText(elapsed))
        LrTasks.sleep(POLL_SECONDS)
      end

      if finished then
        outcome = "done"
      end
    end

    local elapsed = LrDate.currentTime() - startedAt

    if outcome == "done" then
      -- Confirm the queue actually drained. A publish service that reported
      -- completion after its own error dialog will still have work left.
      local after = PublishStatus.pendingCounts(target.collection)
      if not after.unknown and after.total > 0 then
        stats.incomplete = stats.incomplete + 1
        issues[#issues + 1] = target.label .. " -- still " .. PublishStatus.describe(after)
        setProp("status_" .. i, "incomplete")
        setProp("detail_" .. i, "still " .. PublishStatus.describe(after))
      else
        stats.published = stats.published + 1
        setProp("status_" .. i, "published")
        setProp("detail_" .. i, "done in " .. elapsedText(elapsed))
      end
    elseif outcome == "skipped" then
      stats.skipped = stats.skipped + 1
      issues[#issues + 1] = target.label .. " -- skipped by user"
      setProp("status_" .. i, "skipped")
      setProp("detail_" .. i, "skipped after " .. elapsedText(elapsed))
    elseif outcome == "timeout" then
      stats.skipped = stats.skipped + 1
      issues[#issues + 1] = target.label .. " -- no result after " .. elapsedText(elapsed)
      setProp("status_" .. i, "timed out")
      setProp("detail_" .. i, "no result after " .. elapsedText(elapsed) .. "; moved on")
    elseif outcome == "cancelled" then
      setProp("status_" .. i, "cancelled")
      setProp("detail_" .. i, "cancelled after " .. elapsedText(elapsed))
    end

    refreshCounters()
  end

  setProp("bar", progressBar(#queue, #queue))
  setProp("running", false)

  local headline
  if progress:isCanceled() then
    headline = string.format("Cancelled. Published %d of %d queued collection(s).", stats.published, #queue)
  elseif props.stopRequested then
    headline = string.format("Stopped. Published %d of %d queued collection(s).", stats.published, #queue)
  else
    headline = string.format("Finished. Published %d of %d queued collection(s).", stats.published, #queue)
  end
  setProp("headline", headline)

  if #issues > 0 then
    setProp("footer", string.format(
      "%d collection(s) need attention: %s", #issues, table.concat(issues, " | ")
    ))
  else
    setProp("footer", "No errors.")
  end

  return headline
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

    local prefs = LrPrefs.prefsForPlugin()
    local props = LrBinding.makePropertyTable(context)
    props.headline = string.format("Found %d published collection(s).", #targets)
    props.bar = progressBar(0, #targets)
    props.counters = ""
    props.footer = "Closing this window does not stop the run; use Lightroom's progress bar to cancel."
    props.running = true
    props.stopRequested = false
    props.skipRequested = false
    props.timeoutMinutes = prefs.timeoutMinutes or DEFAULT_TIMEOUT_MINUTES

    props:addObserver("timeoutMinutes", function()
      prefs.timeoutMinutes = props.timeoutMinutes
    end)

    for i = 1, #targets do
      props["status_" .. i] = "waiting"
      props["detail_" .. i] = ""
    end

    local state = { closed = false, finished = false }
    local contents = buildContents(props, targets, state)

    -- Lightroom's progress area is the only part of this that survives the
    -- window being closed, and it carries the cancel control.
    local progress = LrProgressScope({
      title = "Publish All Pending",
      functionContext = context,
    })
    progress:setCancelable(true)

    LrTasks.startAsyncTask(function()
      local ok, result = pcall(runPublishPass, props, targets, state, progress)

      if not ok then
        pcall(function()
          props.running = false
          props.headline = "Stopped by an unexpected error."
          props.footer = tostring(result)
        end)
        result = "Publish All Pending stopped: " .. tostring(result)
      end

      state.finished = true
      progress:done()

      if state.closed then
        LrDialogs.showBezel(tostring(result), 4)
      end
    end)

    -- blockTask keeps this function context (and the bindings) alive while
    -- the window is open.
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
      end,
    })

    -- The window is gone but the run may not be: hold the context open so
    -- the worker keeps its progress scope and property table.
    while not state.finished do
      LrTasks.sleep(0.5)
    end
  end)
end)
