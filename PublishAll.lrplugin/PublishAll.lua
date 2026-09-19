--[[
  Publish All Pending Collections

  Walks every publish service and published collection (including nested
  sets). Collections with nothing pending are skipped. Remaining collections
  get publishNow() sequentially. Lightroom only publishes what it already
  considers pending (new / modified / deleted-to-remove).
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

-- True when Lightroom would have work to do: new, modified, or to-remove.
-- If status cannot be read, returns true so we still call publishNow().
local function collectionHasPending(collection)
  local ok, pending = pcall(function()
    local members = collection:getPhotos() or {}
    local publishedPhotos = collection:getPublishedPhotos() or {}

    local memberIds = {}
    for _, photo in ipairs(members) do
      local id = photo.localIdentifier
      if id then
        memberIds[id] = true
      end
    end

    local publishedIds = {}
    for _, publishedPhoto in ipairs(publishedPhotos) do
      local photoOk, photo = pcall(function()
        return publishedPhoto:getPhoto()
      end)
      local id = (photoOk and photo) and photo.localIdentifier or nil
      if id then
        publishedIds[id] = true
      end

      if publishedPhoto:getEditedFlag() then
        return true
      end

      local count = publishedPhoto:getPublishCount()
      if type(count) == "number" and count == 0 then
        return true
      end

      local remoteId = publishedPhoto:getRemoteId()
      if remoteId == nil or remoteId == "" then
        return true
      end

      -- Still on the service, but no longer in the collection.
      if not id or not memberIds[id] then
        return true
      end
    end

    for _, photo in ipairs(members) do
      local id = photo.localIdentifier
      if id and not publishedIds[id] then
        return true
      end
    end

    return false
  end)

  if not ok then
    return true
  end
  return pending
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

    local pending = {}
    local skippedEmpty = 0

    for i, collection in ipairs(collections) do
      if progress:isCanceled() then
        progress:done()
        LrDialogs.message("Publish All Pending", "Cancelled while checking collections.")
        return
      end

      local label = collectionLabel(collection)
      progress:setCaption(
        string.format("Checking %d/%d: %s", i, #collections, label)
      )
      progress:setPortionComplete(i - 1, #collections)

      if collectionHasPending(collection) then
        table.insert(pending, collection)
      else
        skippedEmpty = skippedEmpty + 1
      end
    end

    if #pending == 0 then
      progress:done()
      LrDialogs.message(
        "Publish All Pending",
        string.format(
          "Nothing to publish.\nChecked %d collection(s); none have pending items.",
          #collections
        )
      )
      return
    end

    local index = 1
    local published = 0
    local skippedCancelled = 0
    local failed = 0
    local failures = {}

    local function finish()
      progress:done()
      local summary = string.format(
        "Checked %d collection(s).\nSkipped (nothing pending): %d\nPublished/attempted: %d\nSkipped (cancelled): %d\nFailed: %d",
        #collections,
        skippedEmpty,
        published,
        skippedCancelled,
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
        skippedCancelled = skippedCancelled + (#pending - index + 1)
        finish()
        return
      end

      if index > #pending then
        finish()
        return
      end

      local collection = pending[index]
      local label = collectionLabel(collection)
      progress:setCaption(
        string.format("Publishing %d/%d: %s", index, #pending, label)
      )
      progress:setPortionComplete(index - 1, #pending)

      index = index + 1

      local ok, err = pcall(function()
        collection:publishNow(function()
          published = published + 1
          publishNext()
        end)
      end)

      if not ok then
        failed = failed + 1
        table.insert(failures, label .. " -- " .. tostring(err))
        publishNext()
      end
    end

    publishNext()
  end)
end)
