--- A utility module for updating drivers from GitHub releases.
--- This module provides functionality to check for, download, and install driver updates from GitHub repositories.

local http = require("lib.http")
local log = require("lib.logging")
local deferred = require("deferred")
local version = require("version")

require("lib.utils")
require("drivers-common-public.global.lib")

--- Utility class for updating drivers from GitHub releases.
--- @class GitHubUpdater
local GitHubUpdater = {}
GitHubUpdater.__index = GitHubUpdater

--- Default headers for all HTTP requests to GitHub.
--- @type table<string, string>
local DEFAULT_HEADERS = {
  ["User-Agent"] = "curl/8.1.2",
  Accept = "*/*",
}

--- The largest driver file downloaded, in bytes. Setting it sends the download through the http library's
--- streaming path: the controller's plain transfer fails on a body past 4 MiB.
--- @type integer
local MAX_ASSET_BYTES = 64 * 1024 * 1024

--- Create a new instance of GitHubUpdater.
--- @return GitHubUpdater updater A new GitHubUpdater instance.
function GitHubUpdater:new()
  local instance = setmetatable({}, self)
  return instance
end

--- Retrieve the latest release from a GitHub repository.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @return Deferred<table|nil, string> latestRelease Deferred resolving to the latest release table, or rejected with an error message.
--- @diagnostic disable-next-line: unused
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

--- Downloads the outdated driver assets of the latest release from GitHub.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param driverFilenames string[] List of driver filenames to update.
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @param forceUpdate? boolean Optional. If true, downloads all drivers regardless of version (optional).
--- @return Deferred<DriverPackage[], string|table<number, string>> packages Deferred resolving to each downloaded driver, or rejected with an error message or a table of them indexed by number.
function GitHubUpdater:downloadOutdatedDrivers(repo, driverFilenames, includePrereleases, forceUpdate)
  log:trace(
    "GitHubUpdater:downloadOutdatedDrivers(%s, %s, %s, %s)",
    repo,
    driverFilenames,
    includePrereleases,
    forceUpdate
  )
  return self:getOutdatedDriverAssets(repo, driverFilenames, includePrereleases, forceUpdate):next(function(assets)
    --- @type Deferred<table, string>[]
    local downloads = {}
    for _, asset in pairs(assets) do
      if IsEmpty(asset.browser_download_url) then
        return reject(string.format("repo %s latest release asset %s download is unavailable", repo, asset.name))
      end

      --- @type Deferred<table, string>
      local download = http
        :get(asset.browser_download_url, DEFAULT_HEADERS, { maxBytes = MAX_ASSET_BYTES })
        :next(function(response)
          local downloadSize = string.len(response.body)
          if downloadSize < 1 then
            return reject(string.format("asset %s download is empty", asset.name))
          end
          log:info("Downloaded asset %s (%d bytes)", asset.name, downloadSize)
          return { name = asset.name, body = response.body }
        end, function(response)
          return reject(response.error)
        end)

      table.insert(downloads, download)
    end
    -- Nothing is installed until every asset has downloaded, so a failed download leaves
    -- every installed file as it was.
    return deferred.all(downloads)
  end)
end

--- Update all given drivers to the latest release from GitHub.
--- Downloads new drivers and installs them with InstallDrivers.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param driverFilenames string[] List of driver filenames to update: the repo's own is `require("lib.driver-filenames")`.
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @param forceUpdate? boolean If true, runs update even if drivers are up to date (optional).
--- @return Deferred<string[], string|table<number, string>> updatedDrivers Deferred resolving to a list of updated driver filenames, or rejected with an error message or table.
function GitHubUpdater:updateAll(repo, driverFilenames, includePrereleases, forceUpdate)
  log:trace("GitHubUpdater:updateAll(%s, %s, %s, %s)", repo, driverFilenames, includePrereleases, forceUpdate)
  -- Only update drivers that are already installed.
  local installedDriverFilenames = {}
  for _, driverFilename in pairs(driverFilenames) do
    if not IsEmpty(C4:GetDevicesByC4iName(driverFilename) or {}) then
      table.insert(installedDriverFilenames, driverFilename)
    end
  end

  return self
    :downloadOutdatedDrivers(repo, installedDriverFilenames, includePrereleases, forceUpdate)
    :next(InstallDrivers)
end

return GitHubUpdater:new()
