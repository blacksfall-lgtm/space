------------------------------------------------------------
-- GalaxyData.lua
-- 银河系程序化生成数据模块
-- 包含所有星系的基础数据、位置、类型等
------------------------------------------------------------

local GalaxyData = {}

---@type table[]
local systems = {}

-- 星系类型定义
GalaxyData.STAR_TYPES = {
    YELLOW  = { name = "黄矮星",   color = {1.0, 0.95, 0.6},  size = 1.0 },
    RED     = { name = "红巨星",   color = {1.0, 0.3, 0.1},   size = 1.8 },
    BLUE    = { name = "蓝巨星",   color = {0.4, 0.6, 1.0},   size = 1.4 },
    WHITE   = { name = "白矮星",   color = {0.9, 0.95, 1.0},  size = 0.6 },
    ORANGE  = { name = "橙矮星",   color = {1.0, 0.6, 0.2},   size = 0.8 },
    BINARY  = { name = "双星系统", color = {0.8, 0.9, 1.0},   size = 1.2 },
}

-- 行星类型
GalaxyData.PLANET_TYPES = {
    ROCKY    = { name = "岩石行星", colors = {{0.6, 0.4, 0.3}, {0.5, 0.5, 0.4}} },
    GAS      = { name = "气态巨行星", colors = {{0.8, 0.6, 0.3}, {0.4, 0.5, 0.7}} },
    ICE      = { name = "冰冻行星", colors = {{0.7, 0.85, 0.95}, {0.5, 0.7, 0.9}} },
    LAVA     = { name = "熔岩行星", colors = {{0.8, 0.2, 0.05}, {0.6, 0.1, 0.0}} },
    OCEAN    = { name = "海洋行星", colors = {{0.1, 0.4, 0.8}, {0.2, 0.5, 0.7}} },
    DESERT   = { name = "沙漠行星", colors = {{0.9, 0.75, 0.4}, {0.7, 0.55, 0.3}} },
}

-- 简单确定性随机数（基于种子）
local function seededRandom(seed)
    local x = math.sin(seed * 127.1 + 311.7) * 43758.5453
    return x - math.floor(x)
end

-- 根据种子生成行星数据
-- 每个星系有 orbitCount 条轨道 (3~9), 每条轨道最多1颗行星
-- 部分轨道为空, 营造真实感
local function generatePlanets(systemSeed, orbitCount)
    local planets = {}
    local planetTypeKeys = {"ROCKY", "GAS", "ICE", "LAVA", "OCEAN", "DESERT"}

    -- 轨道参数
    local INNER_RADIUS = 240       -- 最内圈轨道半径(米)
    local ORBIT_SPACING = 180      -- 轨道间最小间距(米)
    local ORBIT_JITTER = 15        -- 轨道半径随机抖动(米)

    -- 确定哪些轨道有行星 (至少放 60% 的轨道有行星, 保证不会太空旷)
    local occupiedSlots = {}
    for i = 1, orbitCount do
        local slotSeed = systemSeed * 100 + i * 13
        -- 内圈轨道更可能有行星
        local threshold = 0.35 + (i / orbitCount) * 0.15  -- 内圈0.35, 外圈0.50 的概率为空
        if seededRandom(slotSeed) > threshold then
            table.insert(occupiedSlots, i)
        end
    end
    -- 确保至少有2颗行星
    if #occupiedSlots < 2 then
        occupiedSlots = {1, math.ceil(orbitCount / 2)}
    end

    for _, slotIdx in ipairs(occupiedSlots) do
        local pseed = systemSeed * 100 + slotIdx * 7
        local typeIdx = math.floor(seededRandom(pseed) * #planetTypeKeys) + 1
        local ptype = planetTypeKeys[typeIdx]
        local ptypeData = GalaxyData.PLANET_TYPES[ptype]

        -- 颜色在两个备选色间插值
        local colorLerp = seededRandom(pseed + 1)
        local c1 = ptypeData.colors[1]
        local c2 = ptypeData.colors[2]
        local color = {
            c1[1] + (c2[1] - c1[1]) * colorLerp,
            c1[2] + (c2[2] - c1[2]) * colorLerp,
            c1[3] + (c2[3] - c1[3]) * colorLerp,
        }

        -- 轨道半径: 基于轨道编号, 等间距 + 微小抖动
        local orbitRadius = INNER_RADIUS + (slotIdx - 1) * ORBIT_SPACING
            + (seededRandom(pseed + 2) - 0.5) * ORBIT_JITTER * 2

        local planetSize = 30 + seededRandom(pseed + 3) * 50
        if ptype == "GAS" then
            planetSize = planetSize * 1.8
        end

        -- 外行星公转更慢 (开普勒定律简化)
        local orbitSpeed = 0.1 + seededRandom(pseed + 4) * 0.3
        orbitSpeed = orbitSpeed / (1 + slotIdx * 0.25)

        -- 基于槽位均匀分布角度 + 随机偏移，避免行星排成一列
        local baseAngle = (slotIdx / orbitCount) * math.pi * 2
        local angleJitter = (seededRandom(pseed + 5) - 0.5) * math.pi * 0.8
        local startAngle = baseAngle + angleJitter

        table.insert(planets, {
            type = ptype,
            typeName = ptypeData.name,
            color = color,
            orbitRadius = orbitRadius,
            orbitIndex = slotIdx,       -- 所在轨道编号
            size = planetSize,
            orbitSpeed = orbitSpeed,
            startAngle = startAngle,
            hasRing = (ptype == "GAS" and seededRandom(pseed + 6) > 0.5),
        })
    end

    return planets, orbitCount
end

--- 初始化银河系数据
function GalaxyData.Init()
    systems = {}

    -- 12个星系的定义 (orbitCount: 3~9条轨道, 每条最多1颗行星)
    local systemDefs = {
        { name = "索拉里斯",   starType = "YELLOW", orbitCount = 5, x = 0,    y = 0,    hasStation = true },
        { name = "赤焰星域",   starType = "RED",    orbitCount = 4, x = 120,  y = 80,   hasStation = false },
        { name = "蔚蓝深渊",   starType = "BLUE",   orbitCount = 7, x = -100, y = 150,  hasStation = true },
        { name = "暮光边境",   starType = "ORANGE", orbitCount = 3, x = 200,  y = -60,  hasStation = false },
        { name = "双子漩涡",   starType = "BINARY", orbitCount = 8, x = -180, y = -120, hasStation = true },
        { name = "霜晶星云",   starType = "WHITE",  orbitCount = 4, x = 50,   y = -200, hasStation = false },
        { name = "熔炉核心",   starType = "RED",    orbitCount = 6, x = -50,  y = 250,  hasStation = true },
        { name = "翡翠走廊",   starType = "YELLOW", orbitCount = 7, x = 250,  y = 150,  hasStation = false },
        { name = "虚空裂隙",   starType = "BLUE",   orbitCount = 3, x = -250, y = 50,   hasStation = true },
        { name = "黄金航线",   starType = "ORANGE", orbitCount = 6, x = 150,  y = 250,  hasStation = true },
        { name = "暗影星冢",   starType = "WHITE",  orbitCount = 5, x = -150, y = -250, hasStation = false },
        { name = "永恒摇篮",   starType = "BINARY", orbitCount = 9, x = 300,  y = -180, hasStation = true },
    }

    for i, def in ipairs(systemDefs) do
        local starData = GalaxyData.STAR_TYPES[def.starType]
        local seed = i * 31 + 42

        local planets, orbitCount = generatePlanets(seed, def.orbitCount)

        local system = {
            index = i,
            name = def.name,
            starType = def.starType,
            starTypeName = starData.name,
            starColor = starData.color,
            starSize = starData.size * (40.0 + seededRandom(seed) * 20.0),
            -- 银河系地图上的位置
            mapX = def.x,
            mapY = def.y,
            -- 是否有空间站
            hasStation = def.hasStation,
            -- 轨道数量 (3~9)
            orbitCount = orbitCount,
            -- 小行星带密度 (0~1)
            asteroidDensity = seededRandom(seed + 10) * 0.7 + 0.1,
            -- 行星数据 (实际有行星的轨道)
            planets = planets,
            -- 双星系统第二颗星的数据
            secondStar = nil,
        }

        -- 双星系统额外数据
        if def.starType == "BINARY" then
            local secondTypes = {"YELLOW", "ORANGE", "WHITE", "RED"}
            local stIdx = math.floor(seededRandom(seed + 20) * #secondTypes) + 1
            local st = secondTypes[stIdx]
            local stData = GalaxyData.STAR_TYPES[st]
            system.secondStar = {
                starType = st,
                color = stData.color,
                size = stData.size * (1.5 + seededRandom(seed + 21) * 0.8),
                orbitRadius = 5.0,
                orbitSpeed = 0.2,
            }
        end

        systems[i] = system
    end

    print("[GalaxyData] Initialized " .. #systems .. " star systems")
end

--- 获取指定星系数据
---@param index number
---@return table|nil
function GalaxyData.GetSystem(index)
    return systems[index]
end

--- 获取所有星系
---@return table[]
function GalaxyData.GetAllSystems()
    return systems
end

--- 获取星系总数
---@return number
function GalaxyData.GetSystemCount()
    return #systems
end

--- 计算两个星系之间的跃迁距离
---@param fromIdx number
---@param toIdx number
---@return number
function GalaxyData.GetWarpDistance(fromIdx, toIdx)
    local from = systems[fromIdx]
    local to = systems[toIdx]
    if not from or not to then return 9999 end
    local dx = to.mapX - from.mapX
    local dy = to.mapY - from.mapY
    return math.sqrt(dx * dx + dy * dy)
end

return GalaxyData
