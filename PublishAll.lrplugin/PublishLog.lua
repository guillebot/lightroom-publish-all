--[[
  Append-only run log.

  A failing publish service usually reports through its own error dialog,
  which disappears as soon as it is dismissed and never says which collection
  was in flight. The log keeps that record.
]]

local LrDate = import "LrDate"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"

local MAX_BYTES = 2 * 1024 * 1024

local PublishLog = {}
PublishLog.__index = PublishLog

local function timestamp()
  return LrDate.timeToUserFormat(LrDate.currentTime(), "%Y-%m-%d %H:%M:%S")
end

local function logPath()
  return LrPathUtils.child(
    LrPathUtils.getStandardFilePath("documents"),
    "PublishAllPending.log"
  )
end

function PublishLog.create()
  local self = setmetatable({ path = logPath() }, PublishLog)

  pcall(function()
    local attributes = LrFileUtils.fileAttributes(self.path)
    if attributes and attributes.fileSize and attributes.fileSize > MAX_BYTES then
      local file = io.open(self.path, "w")
      if file then
        file:close()
      end
    end
  end)

  self:write("")
  self:write("=== Publish All Pending run started ===")
  return self
end

function PublishLog:write(line)
  pcall(function()
    local file = io.open(self.path, "a")
    if not file then
      return
    end
    if line == "" then
      file:write("\n")
    else
      file:write(timestamp() .. "  " .. tostring(line) .. "\n")
    end
    file:close()
  end)
end

return PublishLog
