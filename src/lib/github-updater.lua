--- @module "lib.github-updater"
--- A utility module for updating drivers from GitHub releases.
--- This module provides functionality to check for, download, and install driver updates from GitHub repositories.

local http = require("lib.http")
local log = require("lib.logging")
local deferred = require("vendor.deferred")
local version = require("vendor.version")

--- Utility class for updating drivers from GitHub releases.
--- @class GitHubUpdater
local GitHubUpdater = {}

--- Default headers for all HTTP requests to GitHub.
--- @type table<string, string>
local DEFAULT_HEADERS = {
  ["User-Agent"] = "curl/8.1.2",
  Accept = "*/*",
}

--- Create a new instance of GitHubUpdater.
--- @return GitHubUpdater updater A new GitHubUpdater instance.
function GitHubUpdater:new()
  local properties = {}
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties GitHubUpdater
  return properties
end

--- Retrieve the latest release from a GitHub repository.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @return Deferred<table|nil, string> latestRelease Deferred resolving to the latest release table, or rejected with an error message.
function GitHubUpdater:getLatestRelease(repo, includePrereleases)
  log:trace("GitHubUpdater:getLatestRelease(%s, %s)", repo, includePrereleases)
  if IsEmpty(repo) then
    return reject("repo name is required")
  end
  return http:get("https://api.github.com/repos/" .. repo .. "/releases", DEFAULT_HEADERS):next(function(response)
    for _, release in pairs(response.body or {}) do
      local releaseVersion, err = version(release.tag_name)
      if IsEmpty(err) then
        if not release.draft and (toboolean(includePrereleases) or not release.prerelease) then
          release.version = releaseVersion
          return release
        end
      else
        log:warn("repo %s release '%s' has an invalid tag version '%s'", repo, release.name, release.tag_name)
      end
    end
    return reject(string.format("repo %s does not have any valid releases", repo))
  end, function(response)
    return reject(response.error)
  end)
end

--- Identify assets for driver files that are outdated compared to the latest GitHub release.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param driverFilenames string[] List of driver filenames to check.
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @param forceUpdate? boolean If true, all assets will be treated as outdated regardless of version (optional).
--- @return Deferred<table[], string> outdatedAssets Deferred resolving to a list of assets to be updated, or rejected with an error message.
function GitHubUpdater:getOutdatedDriverAssets(repo, driverFilenames, includePrereleases, forceUpdate)
  log:trace(
    "GitHubUpdater:getOutdatedDriverAssets(%s, %s, %s, %s)",
    repo,
    driverFilenames,
    includePrereleases,
    forceUpdate
  )
  if IsEmpty(driverFilenames) then
    return reject(string.format("at least one driver filename is required to check for updates"))
  end
  -- Determine the minimum driver version from the provided filenames; this determines if an update is needed.
  local minDriverVersion
  for _, driverFilename in pairs(driverFilenames) do
    local driverVersion, err = version(GetDriverVersion(driverFilename))
    if not IsEmpty(err) then
      return reject(string.format("failed to determine the current %s driver version", driverFilename))
    elseif minDriverVersion == nil or minDriverVersion > driverVersion then
      minDriverVersion = driverVersion
    end
  end

  return self:getLatestRelease(repo, includePrereleases):next(function(latestRelease)
    if not forceUpdate and latestRelease.version <= minDriverVersion then
      return {}
    end
    --- @type table[]
    local assets = {}
    local driverFilenamesMap = TableReverse(driverFilenames)
    for _, asset in pairs(Select(latestRelease, "assets") or {}) do
      local assetName = Select(asset, "name")
      if driverFilenamesMap[assetName] ~= nil then
        driverFilenamesMap[assetName] = nil
        table.insert(assets, asset)
      end
    end
    if not IsEmpty(driverFilenamesMap) then
      return reject(
        string.format(
          "repo %s latest release does not have the following asset(s): %s",
          repo,
          table.concat(TableKeys(driverFilenamesMap), ", ")
        )
      )
    end
    return assets
  end)
end

--- Download outdated driver assets from GitHub and write them to the specified directory.
--- @param dir string Target directory to save downloaded driver assets.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param driverFilenames string[] List of driver filenames to update.
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @param forceUpdate? boolean Optional. If true, downloads all drivers regardless of version (optional).
--- @return Deferred<string[], table<number, string>> outdatedDrivers Deferred resolving to a list of successfully downloaded driver filenames, or rejected with a table of error messages indexed by number.
function GitHubUpdater:downloadOutdatedDrivers(dir, repo, driverFilenames, includePrereleases, forceUpdate)
  log:trace(
    "GitHubUpdater:downloadOutdatedDrivers(%s, %s, %s, %s, %s)",
    dir,
    repo,
    driverFilenames,
    includePrereleases,
    forceUpdate
  )
  return self:getOutdatedDriverAssets(repo, driverFilenames, includePrereleases, forceUpdate):next(function(assets)
    --- @type Deferred<string, string>[]
    local downloads = {}
    for _, asset in pairs(assets) do
      if IsEmpty(asset.browser_download_url) then
        return reject(string.format("repo %s latest release asset %s download is unavailable", repo, asset.name))
      end

      --- @type Deferred<string, string>
      local download = http:get(asset.browser_download_url, DEFAULT_HEADERS):next(function(response)
        local downloadSize = string.len(response.body)
        if downloadSize < 1 then
          return reject(string.format("asset %s download is empty", asset.name))
        end
        C4:FileSetDir(dir)
        local currentContents = C4:FileExists(asset.name) and FileRead(asset.name) or nil
        if FileWrite(asset.name, response.body, true) == -1 then
          -- Restore the previous contents if the write failed
          if currentContents ~= nil then
            FileWrite(asset.name, currentContents, true)
          end
          return reject(string.format("failed to download asset %s", asset.name))
        end
        log:info("Downloaded asset %s (%d bytes)", asset.name, downloadSize)
        return asset.name
      end, function(response)
        return reject(response.error)
      end)

      table.insert(downloads, download)
    end
    return deferred.all(downloads)
  end)
end

--- Update all given drivers to the latest release from GitHub.
--- Downloads new drivers, writes them, and sends them for update over TCP to the local system.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param driverFilenames string[] List of driver filenames to update.
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @param forceUpdate? boolean If true, runs update even if drivers are up to date (optional).
--- @return Deferred<string[], table<number, string>> updatedDrivers Deferred resolving to a list of updated driver filenames, or rejected with an error table.
function GitHubUpdater:updateAll(repo, driverFilenames, includePrereleases, forceUpdate)
  log:trace("GitHubUpdater:updateAll(%s, %s, %s, %s)", repo, driverFilenames, includePrereleases, forceUpdate)
  return self
    :downloadOutdatedDrivers("C4Z_ROOT", repo, driverFilenames, includePrereleases, forceUpdate)
    :next(function(downloadedDriverFilenames)
      --- @type Deferred<string[], table<number, string>>
      local d = deferred.new()
      if IsEmpty(downloadedDriverFilenames) then
        return d:resolve(downloadedDriverFilenames)
      end

      C4:CreateTCPClient()
        :OnConnect(function(client)
          for _, driverFilename in pairs(downloadedDriverFilenames) do
            local c4soap = XMLTag(
              "c4soap",
              XMLTag("param", driverFilename, nil, nil, {
                name = "name",
                type = "string",
              }),
              false,
              false,
              {
                name = "UpdateProjectC4i",
                session = "0",
                operation = "RWX",
                category = "composer",
                async = "0",
              }
            ) .. "\0"
            client:Write(c4soap)
          end
          client:Close()
          d:resolve(downloadedDriverFilenames)
        end)
        :OnError(function(client, errCode, errMsg)
          client:Close()
          d:reject("Error " .. errCode .. ": " .. errMsg)
        end)
        :Connect("127.0.0.1", 5020)
      return d
    end)
end

return GitHubUpdater:new()
