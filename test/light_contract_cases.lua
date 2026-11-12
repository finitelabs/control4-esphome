--- The contract's cases: named scenarios with the exact LightCommand list the library hands an adapter's
--- send for each, so an adapter's wire test can feed the same commands to its send and check the wire.
--- The template's Motion suite checks every case against Motion, so a case never drifts from the library.
---
--- Each case gives the device's facts, where the light starts, the settings Motion reads, the intents the
--- proxy's commands become (with the on choice Light would pass, where there is one), and the commands
--- expected, each with the ms after the case's start it goes at. Numbers are as Motion computes them.

--- One intent into the case, at its time.
--- @class LightContractStep
--- @field at integer ms after the case starts.
--- @field intent LightIntent
--- @field choice LightOnChoice|nil What OnColor.choose gives Light for it.

--- One command the library sends, at its time.
--- @class LightContractSent
--- @field at integer ms after the case starts.
--- @field command LightCommand

--- @class LightContractCase
--- @field name string
--- @field device LightDevice As Caps.device fills it.
--- @field seed LightSeed Where the light starts.
--- @field settings LightMotionSettings
--- @field steps LightContractStep[]
--- @field runMs integer How long the case runs after its last step.
--- @field commands LightContractSent[]

local Cases = {}

--- @type LightContractCase[]
Cases.list = {
  {
    name = "an on from off on a preOn device opens with a 0 ms on at the bottom step",
    device = {
      color = true,
      dims = true,
      cct = { minK = 2000, maxK = 6500 },
      colorWhileOff = "send",
      levelSteps = 255,
      fade = { kind = "device", curve = "linear", preOn = true, retimes = false, maxMs = 65535 },
      feedback = { shows = "target", waitMs = 1000, refresh = false },
    },
    seed = { level = 0 },
    settings = {
      on = { defaultOn = true, onModes = true, onLo = 1, onHi = 100, presetLevel = 100, colorOnMode = "none" },
      lo = 1,
      hi = 100,
      rate = 500,
      colorRate = 500,
    },
    steps = {
      {
        at = 0,
        intent = { kind = "on", rateMs = 1000, source = "proxy" },
        choice = { level = 100, unchosen = false, followUp = false },
      },
    },
    runMs = 2000,
    commands = {
      {
        at = 0,
        command = {
          kind = "preOn",
          on = true,
          fromOff = true,
          level = 0.0039215686274509803,
          color = { x = 0.31576713349498398, y = 0.32566383425793799, mode = "cct", kelvin = 6360 },
          setsLevel = true,
          setsColor = false,
          transitionMs = 0,
          from = { level = 0 },
          colorUnchosen = false,
        },
      },
      {
        at = 0,
        command = {
          kind = "change",
          on = true,
          fromOff = false,
          level = 1,
          color = { x = 0.31576713349498398, y = 0.32566383425793799, mode = "cct", kelvin = 6360 },
          setsLevel = true,
          setsColor = false,
          transitionMs = 1000,
          from = { level = 0.0039215686274509803 },
          colorUnchosen = false,
        },
      },
    },
  },
  {
    name = "an off sets the level, with level the level kept",
    device = {
      color = true,
      dims = true,
      cct = { minK = 2000, maxK = 6500 },
      colorWhileOff = "send",
      levelSteps = 255,
      fade = { kind = "device", curve = "linear", preOn = false, retimes = false, maxMs = 65535 },
      feedback = { shows = "target", waitMs = 1000, refresh = false },
    },
    seed = { level = 1 },
    settings = {
      on = { defaultOn = true, onModes = true, onLo = 1, onHi = 100, presetLevel = 100, colorOnMode = "none" },
      lo = 1,
      hi = 100,
      rate = 500,
      colorRate = 500,
    },
    steps = {
      { at = 0, intent = { kind = "off", rateMs = 500, source = "proxy" } },
    },
    runMs = 1000,
    commands = {
      {
        at = 0,
        command = {
          kind = "change",
          on = false,
          fromOff = false,
          level = 1,
          color = { x = 0.31576713349498398, y = 0.32566383425793799, mode = "cct", kelvin = 6360 },
          setsLevel = true,
          setsColor = false,
          transitionMs = 500,
          from = { level = 1 },
          colorUnchosen = false,
        },
      },
    },
  },
  {
    name = "a color for an off light on a send device goes out, and the light stays off",
    device = {
      color = true,
      dims = true,
      cct = { minK = 2000, maxK = 6500 },
      colorWhileOff = "send",
      levelSteps = 255,
      fade = { kind = "device", curve = "linear", preOn = false, retimes = false, maxMs = 65535 },
      feedback = { shows = "target", waitMs = 1000, refresh = false },
    },
    seed = { level = 0, color = { x = 0.4370492915949673, y = 0.4043753101386876, mode = "cct", kelvin = 3000 } },
    settings = {
      on = { defaultOn = true, onModes = true, onLo = 1, onHi = 100, presetLevel = 100, colorOnMode = "none" },
      lo = 1,
      hi = 100,
      rate = 500,
      colorRate = 500,
    },
    steps = {
      {
        at = 0,
        intent = {
          kind = "color",
          color = { x = 0.64000000000000001, y = 0.33000000000000002, mode = "xy" },
          rateMs = 0,
          source = "proxy",
        },
      },
    },
    runMs = 500,
    commands = {
      {
        at = 0,
        command = {
          kind = "change",
          on = false,
          fromOff = false,
          level = 1,
          color = { x = 0.64000000000000001, y = 0.33000000000000002, mode = "xy" },
          setsLevel = false,
          setsColor = true,
          transitionMs = 0,
          from = { level = 0, color = { x = 0.4370492915949673, y = 0.4043753101386876, mode = "cct", kelvin = 3000 } },
          colorUnchosen = false,
        },
      },
    },
  },
  {
    name = "a color for an off light on a hold device is held, and the next on carries it",
    device = {
      color = true,
      dims = true,
      cct = { minK = 2000, maxK = 6500 },
      colorWhileOff = "hold",
      levelSteps = 255,
      fade = { kind = "device", curve = "linear", preOn = false, retimes = false, maxMs = 65535 },
      feedback = { shows = "target", waitMs = 1000, refresh = false },
    },
    seed = { level = 0, color = { x = 0.4370492915949673, y = 0.4043753101386876, mode = "cct", kelvin = 3000 } },
    settings = {
      on = { defaultOn = true, onModes = true, onLo = 1, onHi = 100, presetLevel = 100, colorOnMode = "none" },
      lo = 1,
      hi = 100,
      rate = 500,
      colorRate = 500,
    },
    steps = {
      {
        at = 0,
        intent = {
          kind = "color",
          color = { x = 0.64000000000000001, y = 0.33000000000000002, mode = "xy" },
          rateMs = 0,
          source = "proxy",
        },
      },
      {
        at = 1000,
        intent = { kind = "on", rateMs = 0, source = "proxy" },
        choice = { level = 100, unchosen = false, followUp = false },
      },
    },
    runMs = 500,
    commands = {
      {
        at = 1000,
        command = {
          kind = "change",
          on = true,
          fromOff = true,
          level = 1,
          color = { x = 0.64000000000000001, y = 0.33000000000000002, mode = "xy" },
          setsLevel = true,
          setsColor = true,
          transitionMs = 0,
          from = { level = 0, color = { x = 0.64000000000000001, y = 0.33000000000000002, mode = "xy" } },
          colorUnchosen = false,
        },
      },
    },
  },
  {
    name = "a level stop under retimes carries the color's time left",
    device = {
      color = true,
      dims = true,
      cct = { minK = 2000, maxK = 6500 },
      colorWhileOff = "send",
      levelSteps = 255,
      fade = { kind = "device", curve = "linear", preOn = false, retimes = true, maxMs = 65535 },
      feedback = { shows = "target", waitMs = 1000, refresh = false },
    },
    seed = { level = 0.20000000000000001, color = { x = 0.64000000000000001, y = 0.33000000000000002, mode = "xy" } },
    settings = {
      on = { defaultOn = true, onModes = true, onLo = 1, onHi = 100, presetLevel = 100, colorOnMode = "none" },
      lo = 1,
      hi = 100,
      rate = 500,
      colorRate = 500,
    },
    steps = {
      { at = 0, intent = { kind = "level", level = 100, rateMs = 4000, source = "proxy" } },
      {
        at = 0,
        intent = {
          kind = "color",
          color = { x = 0.14999999999999999, y = 0.059999999999999998, mode = "xy" },
          rateMs = 4000,
          source = "proxy",
        },
      },
      { at = 2000, intent = { kind = "stopLevel", source = "proxy" } },
    },
    runMs = 3000,
    commands = {
      {
        at = 0,
        command = {
          kind = "change",
          on = true,
          fromOff = false,
          level = 1,
          color = { x = 0.64000000000000001, y = 0.33000000000000002, mode = "xy" },
          setsLevel = true,
          setsColor = false,
          transitionMs = 4000,
          from = {
            level = 0.20000000000000001,
            color = { x = 0.64000000000000001, y = 0.33000000000000002, mode = "xy" },
          },
          colorUnchosen = false,
        },
      },
      {
        at = 0,
        command = {
          kind = "change",
          on = true,
          fromOff = false,
          level = 1,
          color = { x = 0.14999999999999999, y = 0.059999999999999998, mode = "xy" },
          setsLevel = false,
          setsColor = true,
          transitionMs = 4000,
          from = {
            level = 0.20000000000000001,
            color = { x = 0.64000000000000001, y = 0.33000000000000002, mode = "xy" },
          },
          colorUnchosen = false,
        },
      },
      {
        at = 2000,
        command = {
          kind = "stop",
          on = true,
          fromOff = false,
          level = 0.59999999999999998,
          color = { x = 0.14999999999999999, y = 0.059999999999999998, mode = "xy" },
          setsLevel = true,
          setsColor = false,
          transitionMs = 2000,
          from = {
            level = 0.59999999999999998,
            color = { x = 0.14999999999999999, y = 0.059999999999999998, mode = "xy" },
          },
          colorUnchosen = false,
        },
      },
    },
  },
  {
    name = "a level stop without retimes holds at once",
    device = {
      color = true,
      dims = true,
      cct = { minK = 2000, maxK = 6500 },
      colorWhileOff = "send",
      levelSteps = 255,
      fade = { kind = "device", curve = "linear", preOn = false, retimes = false, maxMs = 65535 },
      feedback = { shows = "target", waitMs = 1000, refresh = false },
    },
    seed = { level = 0.20000000000000001, color = { x = 0.64000000000000001, y = 0.33000000000000002, mode = "xy" } },
    settings = {
      on = { defaultOn = true, onModes = true, onLo = 1, onHi = 100, presetLevel = 100, colorOnMode = "none" },
      lo = 1,
      hi = 100,
      rate = 500,
      colorRate = 500,
    },
    steps = {
      { at = 0, intent = { kind = "level", level = 100, rateMs = 4000, source = "proxy" } },
      {
        at = 0,
        intent = {
          kind = "color",
          color = { x = 0.14999999999999999, y = 0.059999999999999998, mode = "xy" },
          rateMs = 4000,
          source = "proxy",
        },
      },
      { at = 2000, intent = { kind = "stopLevel", source = "proxy" } },
    },
    runMs = 3000,
    commands = {
      {
        at = 0,
        command = {
          kind = "change",
          on = true,
          fromOff = false,
          level = 1,
          color = { x = 0.64000000000000001, y = 0.33000000000000002, mode = "xy" },
          setsLevel = true,
          setsColor = false,
          transitionMs = 4000,
          from = {
            level = 0.20000000000000001,
            color = { x = 0.64000000000000001, y = 0.33000000000000002, mode = "xy" },
          },
          colorUnchosen = false,
        },
      },
      {
        at = 0,
        command = {
          kind = "change",
          on = true,
          fromOff = false,
          level = 1,
          color = { x = 0.14999999999999999, y = 0.059999999999999998, mode = "xy" },
          setsLevel = false,
          setsColor = true,
          transitionMs = 4000,
          from = {
            level = 0.20000000000000001,
            color = { x = 0.64000000000000001, y = 0.33000000000000002, mode = "xy" },
          },
          colorUnchosen = false,
        },
      },
      {
        at = 2000,
        command = {
          kind = "stop",
          on = true,
          fromOff = false,
          level = 0.59999999999999998,
          color = { x = 0.14999999999999999, y = 0.059999999999999998, mode = "xy" },
          setsLevel = true,
          setsColor = false,
          transitionMs = 0,
          from = {
            level = 0.59999999999999998,
            color = { x = 0.14999999999999999, y = 0.059999999999999998, mode = "xy" },
          },
          colorUnchosen = false,
        },
      },
    },
  },
  {
    name = "Dim-To-Warm: a level carries the mix as an unchosen color, and an off fades to the Dim color",
    device = {
      color = true,
      dims = true,
      cct = { minK = 2000, maxK = 6500 },
      colorWhileOff = "send",
      levelSteps = 255,
      fade = { kind = "device", curve = "linear", preOn = false, retimes = false, maxMs = 65535 },
      feedback = { shows = "target", waitMs = 1000, refresh = false },
    },
    seed = { level = 1, color = { x = 0.4370492915949673, y = 0.4043753101386876, mode = "cct", kelvin = 3000 } },
    settings = {
      on = {
        defaultOn = true,
        onModes = true,
        onLo = 1,
        onHi = 100,
        presetLevel = 100,
        colorOnMode = "fade",
        onColor = { x = 0.4370492915949673, y = 0.4043753101386876, mode = "cct", kelvin = 3000 },
        dimColor = { x = 0.50567941680435746, y = 0.41539786754464297, mode = "cct", kelvin = 2200 },
      },
      lo = 1,
      hi = 100,
      rate = 500,
      colorRate = 500,
    },
    steps = {
      {
        at = 0,
        intent = { kind = "level", level = 30, rateMs = 1000, source = "proxy" },
        choice = {
          level = 30,
          color = { x = 0.48439679367808741, y = 0.41482039983099928, mode = "cct", kelvin = 2420 },
          unchosen = true,
          followUp = false,
        },
      },
      {
        at = 2000,
        intent = { kind = "off", rateMs = 1000, source = "proxy" },
        choice = {
          level = 0,
          color = { x = 0.50567941680435746, y = 0.41539786754464297, mode = "cct", kelvin = 2200 },
          unchosen = true,
          followUp = false,
        },
      },
    },
    runMs = 1500,
    commands = {
      {
        at = 0,
        command = {
          kind = "change",
          on = true,
          fromOff = false,
          level = 0.29999999999999999,
          color = { x = 0.48439679367808741, y = 0.41482039983099928, mode = "cct", kelvin = 2420 },
          setsLevel = true,
          setsColor = true,
          transitionMs = 1000,
          from = { level = 1, color = { x = 0.4370492915949673, y = 0.4043753101386876, mode = "cct", kelvin = 3000 } },
          colorUnchosen = true,
        },
      },
      {
        at = 2000,
        command = {
          kind = "change",
          on = false,
          fromOff = false,
          level = 0.29999999999999999,
          color = { x = 0.50567941680435746, y = 0.41539786754464297, mode = "cct", kelvin = 2200 },
          setsLevel = true,
          setsColor = true,
          transitionMs = 1000,
          from = {
            level = 0.29999999999999999,
            color = { x = 0.48439679367808741, y = 0.41482039983099928, mode = "cct", kelvin = 2420 },
          },
          colorUnchosen = true,
        },
      },
    },
  },
  {
    name = "a walk sends 0 ms steps every stepMs",
    device = {
      color = true,
      dims = true,
      cct = { minK = 2000, maxK = 6500 },
      colorWhileOff = "send",
      levelSteps = 255,
      fade = { kind = "walk", maxMs = 60000, stepMs = 100 },
      feedback = { shows = "target", waitMs = 1000, refresh = false },
    },
    seed = { level = 0.20000000000000001 },
    settings = {
      on = { defaultOn = true, onModes = true, onLo = 1, onHi = 100, presetLevel = 100, colorOnMode = "none" },
      lo = 1,
      hi = 100,
      rate = 500,
      colorRate = 500,
    },
    steps = {
      { at = 0, intent = { kind = "level", level = 50, rateMs = 300, source = "proxy" } },
    },
    runMs = 1000,
    commands = {
      {
        at = 100,
        command = {
          kind = "change",
          on = true,
          fromOff = false,
          level = 0.29999999999999999,
          color = { x = 0.31576713349498398, y = 0.32566383425793799, mode = "cct", kelvin = 6360 },
          setsLevel = true,
          setsColor = false,
          transitionMs = 0,
          from = { level = 0.20000000000000001 },
          colorUnchosen = false,
        },
      },
      {
        at = 200,
        command = {
          kind = "change",
          on = true,
          fromOff = false,
          level = 0.40000000000000002,
          color = { x = 0.31576713349498398, y = 0.32566383425793799, mode = "cct", kelvin = 6360 },
          setsLevel = true,
          setsColor = false,
          transitionMs = 0,
          from = { level = 0.29999999999999999 },
          colorUnchosen = false,
        },
      },
      {
        at = 300,
        command = {
          kind = "change",
          on = true,
          fromOff = false,
          level = 0.5,
          color = { x = 0.31576713349498398, y = 0.32566383425793799, mode = "cct", kelvin = 6360 },
          setsLevel = true,
          setsColor = false,
          transitionMs = 0,
          from = { level = 0.40000000000000002 },
          colorUnchosen = false,
        },
      },
    },
  },
}

return Cases
