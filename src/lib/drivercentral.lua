--- The DriverCentral build's link to DriverCentral: the product it sells as, the cloud client that licenses it, and
--- the gate that stops the driver while it has no license.

--- @class DriverCentral
--- @field _licensed boolean
--- @field _zeros integer
--- @field _onChange? fun(licensed: boolean)
--- @field _timer? userdata
local DriverCentral = { _licensed = true, _zeros = 0 }

--- The product's id in DriverCentral's vendor panel, from the repo's `dc_pid` answer; 0 until the product exists.
DriverCentral.PRODUCT_ID = 819

--- The Driver Status a driver shows while the gate holds it stopped.
DriverCentral.UNLICENSED_STATUS = "No active license"

-- The gate reads DC_X every 10 s and stops the driver after 30 reads of 0 in a row: five minutes, longer than a Cloud
-- driver update, a slow boot or a Director stall. Counted in reads, since a controller's clock can jump at boot.
local CHECK_MS = 10000
local ZERO_CHECKS = 30

--- Starts DriverCentral's cloud client and closes the Lua window, which the Support Code reopens.
--- Call it first in OnDriverInit: the client wraps OnDriverLateInit, ExecuteCommand, OnPropertyChanged and
--- OnDriverDestroyed as they stand when it loads, so the driver must have defined them by then.
function DriverCentral:startClient()
  DC_PID = self.PRODUCT_ID
  if self.PRODUCT_ID == 0 then
    -- No product to ask about: the client stays out, and the gate stops the driver.
    DC_X = 0
    C4:UpdateProperty("Cloud Status", "No DriverCentral product")
  else
    DC_X = nil
    require("cloud-client-byte")
  end
  C4:AllowExecute(false)
end

--- Starts the gate. The driver runs from its load until a 0 has lasted the grace; `onChange` then hears `false`, and
--- `true` as soon as a license is back. Call it at the end of OnDriverLateInit, where DC_X is still nil since the
--- client starts after it. Never put a gate in front of the client's ExecuteCommand: the license arrives through it.
--- @param onChange fun(licensed: boolean)
function DriverCentral:startGate(onChange)
  self._onChange = onChange
  self._licensed = true
  self._zeros = 0
  -- The client calls this on each change; a license back restarts the driver without waiting for the next read.
  local prior = DC_OnDriverStatus
  function DC_OnDriverStatus(...)
    if prior then
      prior(...)
    end
    if DC_X ~= 0 and self.PRODUCT_ID ~= 0 then
      self._zeros = 0
      self:_set(true)
    end
  end
  self._timer = C4:SetTimer(CHECK_MS, function()
    self:_check()
  end, true)
  if self.PRODUCT_ID == 0 then
    self:_set(false)
  end
end

--- Whether the driver may run: false only while the gate holds it stopped.
--- @return boolean
function DriverCentral:licensed()
  return self._licensed
end

--- One read of DC_X. Nil is a client that has not started, and runs.
--- @private
function DriverCentral:_check()
  if self.PRODUCT_ID == 0 then
    return
  end
  if DC_X == 0 then
    self._zeros = self._zeros + 1
    if self._zeros >= ZERO_CHECKS then
      self:_set(false)
    end
  else
    self._zeros = 0
    self:_set(true)
  end
end

--- @private
--- @param licensed boolean
function DriverCentral:_set(licensed)
  if self._licensed == licensed then
    return
  end
  self._licensed = licensed
  if self._onChange then
    self._onChange(licensed)
  end
end

return DriverCentral
