--[[
  Publish All Pending Collections

  Walks every publish service and published collection (including nested
  sets), then calls publishNow() sequentially. Lightroom only publishes
  what it already considers pending (new / modified / deleted-to-remove).
]]

local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrTasks = import "LrTasks"
local LrFunctionContext = import "LrFunctionContext"
local LrProgressScope = import "LrProgressScope"

local catalog = LrApplication.activeCatalog()

local function collectionLabel(collection)
  local name = collection:getName() or "(unnamed)"
  local ok, service = pcall(function()
    return collection:getService()
  end)
  if ok and service then
    local serviceName = service:getName() or service:getPluginId() or "?"
    return serviceName .. " > " .. name
  end
  return name
end

local function collectFromSet(set, collections)
  for _, collection in ipairs(set:getChildCollections()) do
    table.insert(collections, collection)
  end
  for _, childSet in ipairs(set:getChildCollectionSets()) do
    collectFromSet(childSet, collections)
  end
end

local function collectAllPublishedCollections()
  local collections = {}
  for _, service in ipairs(catalog:getPublishServices()) do
    for _, collection in ipairs(service:getChildCollections()) do
      table.insert(collections, collection)
    end
    for _, set in ipairs(service:getChildCollectionSets()) do
      collectFromSet(set, collections)
    end
  end
  return collections
end

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext("PublishAllPending", function(context)
    local collections = collectAllPublishedCollections()

    if #collections == 0 then
      LrDialogs.message(
        "Publish All Pending",
        "No published collections were found."
      )
      return
    end

    local progress = LrProgressScope({
      title = "Publish All Pending",
      functionContext = context,
    })
    progress:setCancelable(true)

    local index = 1
    local published = 0
    local skipped = 0
    local failed = 0
    local failures = {}

    local function finish()
      progress:done()
      local summary = string.format(
        "Finished %d collection(s).\nPublished/attempted: %d\nSkipped (cancelled): %d\nFailed: %d",
        #collections,
        published,
        skipped,
        failed
      )
      if #failures > 0 then
        local detail = table.concat(failures, "\n")
        if #detail > 1200 then
          detail = detail:sub(1, 1200) .. "\n..."
        end
        summary = summary .. "\n\nFailures:\n" .. detail
      end
      LrDialogs.message("Publish All Pending", summary)
    end

    local function publishNext()
      if progress:isCanceled() then
        skipped = skipped + (#collections - index + 1)
        finish()
        return
      end

      if index > #collections then
        finish()
        return
      end

      local collection = collections[index]
      local label = collectionLabel(collection)
      progress:setCaption(
        string.format("Publishing %d/%d: %s", index, #collections, label)
      )
      progress:setPortionComplete(index - 1, #collections)

      index = index + 1

      -- Does NOT mark photos for republish; only processes pending items.
      local ok, err = pcall(function()
        collection:publishNow(function()
          published = published + 1
          publishNext()
        end)
      end)

      if not ok then
        failed = failed + 1
        table.insert(failures, label .. " -- " .. tostring(err))
        -- Continue with remaining collections.
        publishNext()
      end
    end

    publishNext()
  end)
end)