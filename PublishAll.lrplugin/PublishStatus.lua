--[[
  Pending-work detection for published collections.

  Lightroom has no API that reports "this collection has pending items", so
  the counts are reconstructed by comparing collection membership against the
  publication records returned by getPublishedPhotos().
]]

local PublishStatus = {}

-- Photos that were published but no longer carry a remote id (or were never
-- uploaded) are treated as new rather than as published.
local function wasPublished(publishedPhoto)
  local remoteId = publishedPhoto:getRemoteId()
  if remoteId == nil or remoteId == "" then
    return false
  end

  local publishCount = publishedPhoto:getPublishCount()
  if type(publishCount) == "number" and publishCount == 0 then
    return false
  end

  return true
end

-- Returns { newCount, modifiedCount, removedCount, total, unknown, message }.
-- On any SDK error the collection is reported as unknown so the caller can
-- still publish it instead of silently skipping work.
function PublishStatus.pendingCounts(collection)
  local counts = {
    newCount = 0,
    modifiedCount = 0,
    removedCount = 0,
    memberCount = 0,
    total = 0,
    unknown = false,
  }

  local ok, err = pcall(function()
    local members = collection:getPhotos() or {}
    local publishedPhotos = collection:getPublishedPhotos() or {}

    counts.memberCount = #members

    local memberIds = {}
    for _, photo in ipairs(members) do
      local id = photo.localIdentifier
      if id then
        memberIds[id] = true
      end
    end

    local recordedIds = {}
    for _, publishedPhoto in ipairs(publishedPhotos) do
      local photoOk, photo = pcall(function()
        return publishedPhoto:getPhoto()
      end)
      local id = (photoOk and photo) and photo.localIdentifier or nil
      if id then
        recordedIds[id] = true
      end

      local published = wasPublished(publishedPhoto)

      if id and not memberIds[id] then
        if published then
          counts.removedCount = counts.removedCount + 1
        end
      elseif not published then
        counts.newCount = counts.newCount + 1
      elseif publishedPhoto:getEditedFlag() then
        counts.modifiedCount = counts.modifiedCount + 1
      end
    end

    for _, photo in ipairs(members) do
      local id = photo.localIdentifier
      if id and not recordedIds[id] then
        counts.newCount = counts.newCount + 1
      end
    end
  end)

  if not ok then
    counts.unknown = true
    counts.message = tostring(err)
  end

  counts.total = counts.newCount + counts.modifiedCount + counts.removedCount
  return counts
end

function PublishStatus.describe(counts)
  if counts.unknown then
    return "status unreadable"
  end

  if counts.total == 0 then
    return "nothing pending"
  end

  local parts = {}
  if counts.newCount > 0 then
    parts[#parts + 1] = string.format("%d new", counts.newCount)
  end
  if counts.modifiedCount > 0 then
    parts[#parts + 1] = string.format("%d modified", counts.modifiedCount)
  end
  if counts.removedCount > 0 then
    parts[#parts + 1] = string.format("%d to remove", counts.removedCount)
  end

  return table.concat(parts, ", ")
end

return PublishStatus
