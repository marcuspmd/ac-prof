-- Main coordinator for the Race Coach Overlay Lua app
local physics = require('physics-calc')
local uiBrowser = require('ui-browser')
local painter = require('track-painter')
local recorder = require('telemetry-recorder')


local function log(msg)
  ac.log("[Race Coach Overlay] " .. tostring(msg))
end

-- Browser instances for each window
local browserHud = nil
local browserNextTurn = nil
local browserGG = nil
local browserColors = nil

-- Size trackers to prevent frame-flicker resize loops
local trackerHud = { x = 0, y = 0 }
local trackerNextTurn = { x = 0, y = 0 }
local trackerGG = { x = 0, y = 0 }
local trackerColors = { x = 0, y = 0 }

-- Primary Window: HUD (Speed, Gear, Pedals, Tyres, Engineer Feedback)
function windowMain(dt)
  if not browserHud then
    browserHud = uiBrowser.createBrowser("#hud", vec2(350, 180))
  end
  uiBrowser.updateAndDraw(browserHud, trackerHud)
end

-- Secondary Window: Next Turn Info Board
function windowNextTurn(dt)
  if not browserNextTurn then
    browserNextTurn = uiBrowser.createBrowser("#next-turn", vec2(140, 110))
  end
  uiBrowser.updateAndDraw(browserNextTurn, trackerNextTurn)
end

-- Tertiary Window: G-G Diagram (Friction Circle)
function windowGG(dt)
  if not browserGG then
    browserGG = uiBrowser.createBrowser("#gg", vec2(160, 180))
  end
  uiBrowser.updateAndDraw(browserGG, trackerGG)
end

-- Quaternary Window: Color Semaphore (Peripheral vision braking color)
function windowColors(dt)
  if not browserColors then
    browserColors = uiBrowser.createBrowser("#colors", vec2(80, 80))
  end
  uiBrowser.updateAndDraw(browserColors, trackerColors)
end

-- Main physics loop updates and 3D track painter drawings
function script.update(dt)
  local car = ac.getCar(0)
  if not car then return end

  -- 1. Calibrate dynamic G limits based on vehicle state
  physics.updateGLimits(car)

  -- 2. Obtain track simulation details
  local sim = ac.getSim()
  local roadGrip = sim and sim.roadGrip or 1.0
  local upcomingTurn = ac.getTrackUpcomingTurn(0)

  -- 3. Calculate ideal velocity and braking distance
  local nextTurnDist, nextTurnAngle, vTarget, totalBrakingDistanceNeeded = 
    physics.calculateTurnPhysics(car, upcomingTurn, roadGrip)

  -- 4. Draw speed-relative racing line and optimized braking point on track
  painter.drawRacingLine(
    car, 
    sim, 
    nextTurnDist, 
    nextTurnAngle, 
    vTarget, 
    totalBrakingDistanceNeeded,
    physics.maxObservedDecelG
  )

  -- 5. Record telemetry data
  recorder.update(dt)
end
