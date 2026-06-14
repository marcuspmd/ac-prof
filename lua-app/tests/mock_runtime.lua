-- Headless mock of the Assetto Corsa / CSP runtime so the overlay's Lua modules can
-- be loaded and exercised outside the game. Installs the globals the app touches:
--   ac.*, vec3, rgbm
-- Require this BEFORE any app module (config runs ac.storage at load time).

----------------------------------------------------------------------
-- vec3 (only the operations the app uses)
----------------------------------------------------------------------
local vec3_mt = {}
vec3_mt.__index = vec3_mt

local function vec3(x, y, z)
  return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, vec3_mt)
end

function vec3_mt.__add(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
function vec3_mt.__sub(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
function vec3_mt.__mul(a, b)
  if type(a) == "number" then return vec3(b.x * a, b.y * a, b.z * a) end
  if type(b) == "number" then return vec3(a.x * b, a.y * b, a.z * b) end
  return vec3(a.x * b.x, a.y * b.y, a.z * b.z)
end
function vec3_mt:length() return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end
function vec3_mt:cross(o)
  return vec3(self.y * o.z - self.z * o.y,
              self.z * o.x - self.x * o.z,
              self.x * o.y - self.y * o.x)
end
function vec3_mt:normalize()
  local l = self:length()
  if l < 1e-9 then return vec3(0, 0, 0) end
  return vec3(self.x / l, self.y / l, self.z / l)
end

----------------------------------------------------------------------
-- rgbm
----------------------------------------------------------------------
local function rgbm(r, g, b, m)
  return { r = r or 0, g = g or 0, b = b or 0, mult = m or 1 }
end

----------------------------------------------------------------------
-- ac namespace
----------------------------------------------------------------------
local trackPaint_mt = { __index = {
  reset  = function() end,
  line   = function() end,
  circle = function() end,
} }

-- Current track context, swapped per scenario by harness via ac.__setTrack(...)
local ctx = { id = "unknown", layout = "", points = nil, detailCount = 0, trackLength = 0 }

local ac = {
  FolderID = { CurrentTrackLayout = 1 },

  storage = function(defaults) return defaults end,

  TrackPaint = function()
    return setmetatable({ forceRecast = false, ageFactor = 0, bulgeFactor = 0 }, trackPaint_mt)
  end,

  -- Folder path varies per track so ai-loader's filePath cache reloads on track switch
  getFolder      = function() return "/tmp/actest/" .. ctx.id .. "_" .. ctx.layout end,
  getTrackID     = function() return ctx.id end,
  getTrackLayout = function() return ctx.layout end,
  getCarID       = function() return "test_car" end,
  getSim         = function() return { trackLengthM = ctx.trackLength } end,
  getTrackUpcomingTurn = function() return nil end,

  -- Map progress -> world position by interpolating the loaded spline points
  trackProgressToWorldCoordinate = function(p, _clamp)
    if not ctx.points or ctx.detailCount <= 0 then return vec3(0, 0, 0) end
    p = p % 1.0
    if p < 0 then p = p + 1.0 end
    local f = p * ctx.detailCount
    local i0 = math.floor(f) + 1
    local frac = f - math.floor(f)
    local i1 = (i0 % ctx.detailCount) + 1
    local a = ctx.points[i0] or ctx.points[1]
    local b = ctx.points[i1] or a
    return vec3(a[1] + (b[1] - a[1]) * frac,
                a[2] + (b[2] - a[2]) * frac,
                a[3] + (b[3] - a[3]) * frac)
  end,

  worldCoordinateToTrack = function(_pos) return vec3(0, 0, 0) end,
  trackCoordinateToWorld = function(_pos) return vec3(0, 0, 0) end,
  getTrackAISplineSides  = function() return nil end,

  -- Test helper: point the runtime at a freshly-loaded track
  __setTrack = function(id, layout, points, detailCount, trackLength)
    ctx.id = id; ctx.layout = layout
    ctx.points = points; ctx.detailCount = detailCount; ctx.trackLength = trackLength
  end,
}

_G.vec3 = vec3
_G.rgbm = rgbm
_G.ac = ac

return { vec3 = vec3, rgbm = rgbm, ac = ac }
