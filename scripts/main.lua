-- ============================================================================
-- 银河猎人 (Galaxy Hunter)
-- 混合渲染架构: 3D 舰船模型 + NanoVG 2D 背景/HUD
-- 
-- 架构层次:
--   Layer 0: 3D Scene (深空背景 Skybox + 星系恒星/行星 3D + 舰船 3D)
--   Layer 1: NanoVG Overlay (HUD / 星图 / 跃迁特效)
-- ============================================================================

local UI = require("urhox-libs/UI")

-- ============================================================================
-- 引入子模块
-- ============================================================================
local ShipFactory = require("ShipFactory")
local StarSystem = require("StarSystem")
local GalaxyData = require("GalaxyData")
local SpaceEnvironment = require("SpaceEnvironment")
local S = require("UIStyle")  -- UI样式常量

-- ============================================================================
-- 全局状态
-- ============================================================================
---@type Scene|nil
local scene_ = nil
---@type Node|nil
local cameraNode_ = nil
---@type Node|nil
local playerShipNode_ = nil

-- NanoVG
local vg = nil
local fontNormal = -1

-- 游戏配置
local CONFIG = {
    Title = "银河猎人",
    -- 舰船运动 (2D逻辑坐标, 映射到 X/Z 平面)
    ShipMaxSpeed = 40,          -- 米/秒
    ShipAcceleration = 25,
    ShipDeceleration = 8,
    ShipRotateSpeed = 4.0,      -- 弧度/秒 (朝向插值)
    ShipBankAngle = 25,         -- 最大侧倾角度
    ShipFloatAmplitude = 0.08,  -- 浮动幅度(米)
    ShipFloatSpeed = 2.0,       -- 浮动频率
    -- 相机
    CameraHeight = 20,          -- 相机高度(米)
    CameraDistance = 12,        -- 相机后方偏移(米)
    CameraAngle = 55,           -- 俯仰角度
    CameraSmooth = 3.0,         -- 跟随平滑度
    CameraFOV = 50.0,
    -- 跃迁
    WarpChargeTime = 2.0,
    WarpCooldown = 3.0,
    -- 燃料/船体
    MaxFuel = 1000,
    MaxHull = 5000,
}

-- 飞船状态 (2D逻辑坐标)
local ship = {
    x = 0,           -- 逻辑X (映射到3D X)
    z = 0,           -- 逻辑Y (映射到3D Z)
    vx = 0,
    vz = 0,
    speed = 0,
    heading = 0,     -- 朝向弧度 (Y轴旋转)
    bankAngle = 0,   -- 当前侧倾
    thrust = false,
    fuel = 1000,
    hull = 5000,
}

-- 相机状态
local cam = {
    currentX = 0,
    currentZ = 0,
    currentY = 35,
    zoom = 1.0,       -- 缩放倍率 (1.0=默认, 小=拉近, 大=拉远)
    zoomMin = 0.3,    -- 最近
    zoomMax = 32.0,   -- 最远（可看到整个恒星系）
}

-- 游戏状态
local gameState = "playing"  -- playing, starmap, warping

-- 跃迁状态
local warp = {
    cooldown = 0,
    targetIndex = 0,
    animProgress = 0,
}

-- 当前星系
local currentSystemIndex = 1
local currentSystemData = nil

-- 星系场景节点
---@type Node|nil
local systemRootNode_ = nil

-- 时间
local elapsedTime = 0

-- 屏幕尺寸
local screenW = 0
local screenH = 0

-- 引擎火焰系统(每个引擎3层: core/mid/trail)
local engineFlames = {}  -- { {core=Node, mid=Node, trail=Node}, ... }
local flameInvScale = 1.0

-- ============================================================================
-- 生命周期
-- ============================================================================

function Start()
    graphics.windowTitle = CONFIG.Title
    
    -- 初始化UI系统(用于事件和NanoVG)
    UI.Init({
        fonts = {
            { family = "sans", weights = {
                normal = "Fonts/MiSans-Regular.ttf",
            } }
        },
        scale = UI.Scale.DEFAULT,
    })
    
    -- 创建3D场景
    CreateScene()
    
    -- 设置相机
    SetupCamera()
    
    -- 初始化银河系数据
    GalaxyData.Init()
    
    -- 进入第一个星系
    EnterSystem(1)
    
    -- 创建NanoVG上下文(用于HUD)
    vg = nvgCreate(1)
    if vg then
        fontNormal = nvgCreateFont(vg, "sans", "Fonts/MiSans-Regular.ttf")
    end
    
    -- 设置鼠标模式
    input.mouseMode = MM_FREE
    
    -- 创建空UI (占位, HUD通过NanoVG绘制)
    UI.SetRoot(UI.Panel { width = "100%", height = "100%", pointerEvents = "box-none" })
    
    -- 订阅事件
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("KeyDown", "HandleKeyDown")
    SubscribeToEvent("MouseButtonDown", "HandleMouseDown")
    if vg then
        SubscribeToEvent(vg, "NanoVGRender", "HandleNanoVGRender")
    end
    
    print("=== 银河猎人启动 (混合3D渲染) ===")
    print("操作: WASD移动 | TAB星图 | 星图中点击跃迁")
end

function Stop()
    UI.Shutdown()
    if vg then
        nvgDelete(vg)
        vg = nil
    end
end

-- ============================================================================
-- 3D 场景创建
-- ============================================================================

function CreateScene()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    scene_:CreateComponent("DebugRenderer")
    
    -- 使用夜晚光照预设(太空环境)
    local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/DarkNight.xml")
    local lightGroup = scene_:CreateChild("LightGroup")
    lightGroup:LoadXML(lightGroupFile:GetRoot())
    
    -- 调整Zone: 禁用雾(太空无雾), 保留环境光
    local zone = lightGroup:GetComponent("Zone", true)
    if zone then
        zone.fogStart = 9000
        zone.fogEnd = 10000
    end
    
    -- 调低方向光亮度(调试模式：极低，纯验证贴图)
    local light = lightGroup:GetComponent("Light", true)
    if light then
        light.brightness = 0.5
        light.color = Color(1.0, 1.0, 1.0)
    end
    
    -- HDR + Bloom：恒星高自发光通过 Bloom 溢出产生自然边缘辉光
    renderer.hdrRendering = true
    if zone then
        zone.bloomPlusEnabled = true
        zone.bloomThreshold = 0.8       -- 亮度超过此值开始泛光
        zone.bloomWeight = 0.6          -- 泛光混合权重
        zone.bloomPlusIntensity = 1.2   -- 泛光强度
        zone.autoExposureEnabled = true -- 自动曝光避免过曝
    end
    
    -- 创建星系根节点(用于切换星系时清除)
    -- 下移到飞船下方, 恒星/行星在飞船脚下(类似群星Stellaris视角)
    systemRootNode_ = scene_:CreateChild("SystemRoot")
    systemRootNode_:SetPosition(Vector3(0, -8, 0))
end

function SetupCamera()
    cameraNode_ = scene_:CreateChild("Camera")
    local camera = cameraNode_:CreateComponent("Camera")
    camera.nearClip = 0.5
    camera.farClip = 2000.0
    camera.fov = CONFIG.CameraFOV
    
    local viewport = Viewport:new(scene_, camera)
    renderer:SetViewport(0, viewport)
    
    -- 初始化相机位置
    UpdateCameraPosition(true)
end

-- ============================================================================
-- 星系管理
-- ============================================================================

function EnterSystem(index)
    currentSystemIndex = index
    currentSystemData = GalaxyData.GetSystem(index)
    
    -- 清除旧星系内容
    if systemRootNode_ then
        systemRootNode_:RemoveAllChildren()
    end
    
    -- 创建星系3D内容
    StarSystem.Build(scene_, systemRootNode_, currentSystemData)
    
    -- 构建星系背景环境（根据星型选择主题色）
    SpaceEnvironment.Build(scene_, ship.x, ship.z, currentSystemData.starType)
    
    -- 创建/重置玩家飞船
    CreatePlayerShip()
    
    -- 重置飞船位置
    ship.x = -100
    ship.z = 60
    ship.vx = 5
    ship.vz = 0
    ship.speed = 5
    ship.heading = 0
    
    -- 重置相机
    cam.currentX = ship.x
    cam.currentZ = ship.z
    
    print("进入星系: " .. currentSystemData.name)
end

function CreatePlayerShip()
    -- 移除旧飞船
    if playerShipNode_ then
        playerShipNode_:Remove()
    end
    
    -- 创建玩家主舰: 父节点负责游戏逻辑(位置/航向)
    playerShipNode_ = scene_:CreateChild("PlayerShip")
    
    -- 子节点负责模型朝向修正(静态旋转，不会被每帧覆盖)
    local modelNode = playerShipNode_:CreateChild("ShipModel")
    -- 模型朝向修正: Quaternion(pitch=0, yaw=-90, roll=0)
    modelNode:SetRotation(Quaternion(0, -90, 0))
    
    -- 加载飞船模型到子节点
    local shipModel = modelNode:CreateComponent("StaticModel")
    shipModel:SetModel(cache:GetResource("Model", "Meshes/PlayerShip.mdl"))
    -- 飞船模型有3个几何体，分别设置材质
    local shipMats = {
        "Materials/PlayerShip_00_tripo_material_c43f1d62-fc6b-414a-a0d5-334ae0f4472f.xml",
        "Materials/PlayerShip_00_tripo_material_20bcd78a-28e1-4fa5-b822-04e68de03ea2.xml",
        "Materials/PlayerShip_00_tripo_material_b276863c-99f6-4286-acb1-6e9d6441e1e3.xml",
    }
    local numGeom = shipModel:GetNumGeometries()
    print(string.format("[Ship] Model has %d geometries", numGeom))
    for i = 0, numGeom - 1 do
        local matIdx = (i % #shipMats) + 1
        shipModel:SetMaterial(i, cache:GetResource("Material", shipMats[matIdx]))
    end
    shipModel.castShadows = true
    
    -- 根据模型实际尺寸调整缩放(在父节点上)
    local bbox = shipModel.boundingBox
    local modelSize = bbox.size
    local maxDim = math.max(modelSize.x, modelSize.y, modelSize.z)
    local targetSize = 8.0  -- 目标飞船长度(米)，配合俯视摄像机
    local scaleFactor = targetSize / maxDim
    playerShipNode_:SetScale(Vector3(scaleFactor, scaleFactor, scaleFactor))
    
    print(string.format("飞船模型尺寸: %.2f x %.2f x %.2f, 缩放: %.3f", 
        modelSize.x, modelSize.y, modelSize.z, scaleFactor))
    
    -- 引擎火焰效果: 推进火焰风格 (锥体多层叠加, 柔和渐变, 非硬线条)
    -- 颜色方案: 核心 #4FE6FF → 中层 #9FEFFF → 尾部 #DFF8FF
    -- 使用 Cone 模型: 底部较宽, 尖端收窄 → 自然火焰形态
    local invScale = 1.0 / scaleFactor
    flameInvScale = invScale
    engineFlames = {}
    
    local nozzlePositions = {
        Vector3(-4.19, 0, -0.20),  -- 左引擎喷口
        Vector3(-4.19, 0,  0.20),  -- 右引擎喷口
    }
    
    -- Cone旋转: 让锥体尖端朝-X方向(向后延伸), 底部朝引擎喷口
    -- Cone默认Y轴, 底在-Y, 尖在+Y → 旋转让尖端指向-X
    local coneRot = Quaternion(90, Vector3(0, 0, 1))
    
    for i, nozzlePos in ipairs(nozzlePositions) do
        local flame = {}
        
        -- 层0: 喷口辉球 (核心光点, 最亮)
        -- 紧贴喷口, 一个小发光球提供核心亮度
        local glowNode = modelNode:CreateChild("FlameGlow_" .. i)
        glowNode.position = nozzlePos * invScale
        local glowModel = glowNode:CreateComponent("StaticModel")
        glowModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local glowMat = Material:new()
        glowMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        glowMat:SetShaderParameter("MatDiffColor", Variant(Color(0.7, 0.98, 1.0, 0.9)))
        glowMat:SetShaderParameter("MatEmissiveColor", Variant(Color(4.0, 7.0, 8.0)))
        glowMat:SetShaderParameter("Roughness", Variant(1.0))
        glowMat:SetShaderParameter("Metallic", Variant(0.0))
        glowModel:SetMaterial(glowMat)
        glowNode:SetScale(Vector3(0.06, 0.06, 0.06) * invScale)
        flame.glow = glowNode
        
        -- 层1: 内焰锥 (核心, 较短较宽, 高亮 #4FE6FF)
        -- Cone尺寸: 直径0.5 高1.0 → 这里用 scaleXZ 控制粗细, scaleY 控制长度
        local coreNode = modelNode:CreateChild("FlameCore_" .. i)
        -- 锥体底面中心在原点, 偏移让底面贴近喷口
        coreNode.position = (nozzlePos + Vector3(-0.15, 0, 0)) * invScale
        local coreModel = coreNode:CreateComponent("StaticModel")
        coreModel:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        local coreMat = Material:new()
        coreMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        coreMat:SetShaderParameter("MatDiffColor", Variant(Color(0.31, 0.90, 1.0, 0.75)))  -- #4FE6FF
        coreMat:SetShaderParameter("MatEmissiveColor", Variant(Color(2.0, 4.5, 5.5)))
        coreMat:SetShaderParameter("Roughness", Variant(1.0))
        coreMat:SetShaderParameter("Metallic", Variant(0.0))
        coreModel:SetMaterial(coreMat)
        coreNode:SetScale(Vector3(0.07, 0.6, 0.07) * invScale)
        coreNode:SetRotation(coneRot)
        flame.core = coreNode
        
        -- 层2: 中焰锥 (包裹内焰, 更宽更长, 半透明 #9FEFFF)
        local midNode = modelNode:CreateChild("FlameMid_" .. i)
        midNode.position = (nozzlePos + Vector3(-0.1, 0, 0)) * invScale
        local midModel = midNode:CreateComponent("StaticModel")
        midModel:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        local midMat = Material:new()
        midMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        midMat:SetShaderParameter("MatDiffColor", Variant(Color(0.62, 0.94, 1.0, 0.35)))  -- #9FEFFF
        midMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.2, 2.5, 3.0)))
        midMat:SetShaderParameter("Roughness", Variant(1.0))
        midMat:SetShaderParameter("Metallic", Variant(0.0))
        midModel:SetMaterial(midMat)
        midNode:SetScale(Vector3(0.12, 0.9, 0.12) * invScale)
        midNode:SetRotation(coneRot)
        flame.mid = midNode
        
        -- 层3: 外焰锥 (最外层, 最宽最长, 极淡 #DFF8FF, 营造散射感)
        local outerNode = modelNode:CreateChild("FlameOuter_" .. i)
        outerNode.position = (nozzlePos + Vector3(-0.05, 0, 0)) * invScale
        local outerModel = outerNode:CreateComponent("StaticModel")
        outerModel:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        local outerMat = Material:new()
        outerMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        outerMat:SetShaderParameter("MatDiffColor", Variant(Color(0.87, 0.97, 1.0, 0.15)))  -- #DFF8FF 极淡
        outerMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.6, 1.0, 1.2)))
        outerMat:SetShaderParameter("Roughness", Variant(1.0))
        outerMat:SetShaderParameter("Metallic", Variant(0.0))
        outerModel:SetMaterial(outerMat)
        outerNode:SetScale(Vector3(0.18, 1.3, 0.18) * invScale)
        outerNode:SetRotation(coneRot)
        flame.outer = outerNode
        
        -- 层4: 尾迹锥 (细长尾巴, 最长最淡, 速度越快越明显)
        local trailNode = modelNode:CreateChild("FlameTrail_" .. i)
        trailNode.position = (nozzlePos + Vector3(-0.6, 0, 0)) * invScale
        local trailModel = trailNode:CreateComponent("StaticModel")
        trailModel:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        local trailMat = Material:new()
        trailMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        trailMat:SetShaderParameter("MatDiffColor", Variant(Color(0.87, 0.97, 1.0, 0.08)))
        trailMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.3, 0.6, 0.8)))
        trailMat:SetShaderParameter("Roughness", Variant(1.0))
        trailMat:SetShaderParameter("Metallic", Variant(0.0))
        trailModel:SetMaterial(trailMat)
        trailNode:SetScale(Vector3(0.06, 1.8, 0.06) * invScale)
        trailNode:SetRotation(coneRot)
        flame.trail = trailNode
        
        table.insert(engineFlames, flame)
    end
end

-- ============================================================================
-- 更新逻辑
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()
    elapsedTime = elapsedTime + dt
    
    screenW = graphics:GetWidth()
    screenH = graphics:GetHeight()
    
    -- 滚轮缩放相机
    local wheel = input:GetMouseMoveWheel()
    if wheel ~= 0 then
        -- 滚轮向上=拉远(zoom增大), 向下=拉近(zoom减小)
        local zoomSpeed = 0.15
        cam.zoom = cam.zoom * (1.0 - wheel * zoomSpeed)
        cam.zoom = math.max(cam.zoomMin, math.min(cam.zoomMax, cam.zoom))
    end
    
    if gameState == "playing" then
        UpdateShipMovement(dt)
        UpdateShip3DTransform(dt)
        UpdateEngineFlames(dt)
        UpdateCameraPosition(false, dt)
        StarSystem.Update(dt, elapsedTime)
        SpaceEnvironment.Update(dt, elapsedTime, cam.currentX, cam.currentZ, ship.speed, cam.zoom)
    elseif gameState == "warping" then
        UpdateWarpAnimation(dt)
    end
    
    -- 跃迁冷却
    if warp.cooldown > 0 then
        warp.cooldown = warp.cooldown - dt
    end
end

-- ============================================================================
-- 飞船运动 (2D逻辑)
-- ============================================================================

function UpdateShipMovement(dt)
    local thrustX = 0
    local thrustZ = 0
    ship.thrust = false
    
    if input:GetKeyDown(KEY_W) then
        thrustZ = 1
        ship.thrust = true
    end
    if input:GetKeyDown(KEY_S) then
        thrustZ = -1
        ship.thrust = true
    end
    if input:GetKeyDown(KEY_A) then
        thrustX = -1
        ship.thrust = true
    end
    if input:GetKeyDown(KEY_D) then
        thrustX = 1
        ship.thrust = true
    end
    
    -- 归一化
    local inputLen = math.sqrt(thrustX * thrustX + thrustZ * thrustZ)
    if inputLen > 0 then
        thrustX = thrustX / inputLen
        thrustZ = thrustZ / inputLen
    end
    
    -- 加速
    if ship.thrust and ship.fuel > 0 then
        ship.vx = ship.vx + thrustX * CONFIG.ShipAcceleration * dt
        ship.vz = ship.vz + thrustZ * CONFIG.ShipAcceleration * dt
        ship.fuel = math.max(0, ship.fuel - dt * 3)
    end
    
    -- 限速
    ship.speed = math.sqrt(ship.vx * ship.vx + ship.vz * ship.vz)
    if ship.speed > CONFIG.ShipMaxSpeed then
        local scale = CONFIG.ShipMaxSpeed / ship.speed
        ship.vx = ship.vx * scale
        ship.vz = ship.vz * scale
        ship.speed = CONFIG.ShipMaxSpeed
    end
    
    -- 自然减速
    if not ship.thrust then
        local decel = CONFIG.ShipDeceleration * dt
        if ship.speed > decel then
            local factor = 1.0 - (decel / ship.speed)
            ship.vx = ship.vx * factor
            ship.vz = ship.vz * factor
        else
            ship.vx = 0
            ship.vz = 0
        end
        ship.speed = math.sqrt(ship.vx * ship.vx + ship.vz * ship.vz)
    end
    
    -- 更新朝向 (朝速度方向)
    if ship.speed > 1.0 then
        local targetHeading = math.atan(ship.vx, ship.vz)  -- atan(x,z) 给出Y轴旋转
        local diff = targetHeading - ship.heading
        -- 标准化到 [-pi, pi]
        while diff > math.pi do diff = diff - math.pi * 2 end
        while diff < -math.pi do diff = diff + math.pi * 2 end
        ship.heading = ship.heading + diff * CONFIG.ShipRotateSpeed * dt
    end
    
    -- 侧倾 (转弯时倾斜)
    local turnRate = 0
    if ship.speed > 1.0 then
        local targetHeading = math.atan(ship.vx, ship.vz)
        local diff = targetHeading - ship.heading
        while diff > math.pi do diff = diff - math.pi * 2 end
        while diff < -math.pi do diff = diff + math.pi * 2 end
        turnRate = diff * CONFIG.ShipRotateSpeed
    end
    local targetBank = -turnRate * CONFIG.ShipBankAngle / CONFIG.ShipRotateSpeed
    targetBank = math.max(-CONFIG.ShipBankAngle, math.min(CONFIG.ShipBankAngle, targetBank))
    ship.bankAngle = ship.bankAngle + (targetBank - ship.bankAngle) * 5.0 * dt
    
    -- 移动
    ship.x = ship.x + ship.vx * dt
    ship.z = ship.z + ship.vz * dt
end

-- ============================================================================
-- 飞船3D变换
-- ============================================================================

function UpdateShip3DTransform(dt)
    if not playerShipNode_ then return end
    
    -- 浮动效果
    local floatY = math.sin(elapsedTime * CONFIG.ShipFloatSpeed) * CONFIG.ShipFloatAmplitude
    
    -- 位置: 逻辑(x,z) → 3D(X, Y≈0+float, Z)
    playerShipNode_.position = Vector3(ship.x, floatY, ship.z)
    
    -- 旋转: heading(Y轴) + bankAngle(Z轴前倾)
    local headingDeg = math.deg(ship.heading)
    local bankDeg = ship.bankAngle
    -- 俯仰微倾: 加速时微微抬头
    local pitchDeg = ship.thrust and -3.0 or 0
    
    -- 游戏逻辑旋转(模型朝向修正已由子节点处理)
    playerShipNode_.rotation = Quaternion(pitchDeg, headingDeg, bankDeg)
end

-- ============================================================================
-- 引擎火焰
-- ============================================================================

function UpdateEngineFlames(dt)
    if #engineFlames == 0 then return end
    
    local inv = flameInvScale
    local speedRatio = ship.speed / CONFIG.ShipMaxSpeed
    
    -- 强度: 待机0.15 / 推进0.4~1.0 / 滑行0.15~0.5
    local intensity = 0.15
    if ship.thrust then
        intensity = 0.4 + speedRatio * 0.6
    elseif ship.speed > 1.0 then
        intensity = 0.15 + (speedRatio * 0.35)
    end
    
    -- 柔和脉冲 (比之前频率低, 幅度小, 更像火焰呼吸而非闪烁)
    local glowPulse  = 0.88 + 0.12 * math.sin(elapsedTime * 12)
    local corePulse  = 0.92 + 0.08 * math.sin(elapsedTime * 8 + 0.5)
    local midPulse   = 0.94 + 0.06 * math.sin(elapsedTime * 5 + 1.0)
    local outerPulse = 0.96 + 0.04 * math.sin(elapsedTime * 3 + 1.5)
    local trailPulse = 0.97 + 0.03 * math.sin(elapsedTime * 2.5 + 2.0)
    
    for i = 1, #engineFlames do
        local flame = engineFlames[i]
        
        -- 喷口辉球: 随强度微缩放
        local glowSize = (0.04 + intensity * 0.03) * glowPulse * inv
        flame.glow.scale = Vector3(glowSize, glowSize, glowSize)
        
        -- 内焰锥: 核心火焰, 粗短, 随推力膨胀
        local coreW = (0.05 + intensity * 0.04) * corePulse * inv
        local coreL = (0.4 + intensity * 0.4) * corePulse * inv
        flame.core.scale = Vector3(coreW, coreL, coreW)
        
        -- 中焰锥: 包裹层, 更宽更长
        local midW = (0.08 + intensity * 0.06) * midPulse * inv
        local midL = (0.6 + intensity * 0.6) * midPulse * inv
        flame.mid.scale = Vector3(midW, midL, midW)
        
        -- 外焰锥: 散射层, 最宽
        local outerW = (0.12 + intensity * 0.08) * outerPulse * inv
        local outerL = (0.8 + intensity * 0.8) * outerPulse * inv
        flame.outer.scale = Vector3(outerW, outerL, outerW)
        
        -- 尾迹锥: 细长, 速度越快越长 (推力时才明显)
        local trailW = (0.03 + intensity * 0.04) * trailPulse * inv
        local trailL = (0.5 + intensity * 1.8) * trailPulse * inv
        flame.trail.scale = Vector3(trailW, trailL, trailW)
    end
end

-- ============================================================================
-- 相机控制
-- ============================================================================

function UpdateCameraPosition(instant, dt)
    if not cameraNode_ then return end
    dt = dt or 0
    
    local targetX = ship.x
    local targetZ = ship.z
    
    if instant then
        cam.currentX = targetX
        cam.currentZ = targetZ
    else
        local smooth = CONFIG.CameraSmooth * dt
        cam.currentX = cam.currentX + (targetX - cam.currentX) * smooth
        cam.currentZ = cam.currentZ + (targetZ - cam.currentZ) * smooth
    end
    
    -- 相机位置: 在玩家后上方，受 zoom 缩放
    local angleRad = math.rad(CONFIG.CameraAngle)
    local camY = CONFIG.CameraHeight * cam.zoom
    local camOffsetZ = -CONFIG.CameraDistance * cam.zoom * math.cos(angleRad)
    
    cameraNode_.position = Vector3(cam.currentX, camY, cam.currentZ + camOffsetZ)
    
    -- 相机看向玩家位置前方一点（前方偏移也随缩放变化）
    local lookAhead = 5 * cam.zoom
    local lookTarget = Vector3(cam.currentX, 0, cam.currentZ + lookAhead)
    cameraNode_:LookAt(lookTarget)
end

-- ============================================================================
-- 跃迁
-- ============================================================================

function UpdateWarpAnimation(dt)
    warp.animProgress = warp.animProgress + dt / CONFIG.WarpChargeTime
    if warp.animProgress >= 1.0 then
        warp.animProgress = 0
        warp.cooldown = CONFIG.WarpCooldown
        EnterSystem(warp.targetIndex)
        gameState = "playing"
    end
end

-- ============================================================================
-- 输入处理
-- ============================================================================

---@param eventType string
---@param eventData KeyDownEventData
function HandleKeyDown(eventType, eventData)
    local key = eventData["Key"]:GetInt()
    
    if key == KEY_TAB then
        if gameState == "playing" then
            gameState = "starmap"
        elseif gameState == "starmap" then
            gameState = "playing"
        end
    end
    
    if key == KEY_ESCAPE then
        if gameState == "starmap" then
            gameState = "playing"
        end
    end
end

---@param eventType string
---@param eventData MouseButtonDownEventData
function HandleMouseDown(eventType, eventData)
    local button = eventData["Button"]:GetInt()
    if button ~= MOUSEB_LEFT then return end
    
    if gameState == "starmap" then
        HandleStarmapClick()
    end
end

function HandleStarmapClick()
    local mx = input.mousePosition.x
    local my = input.mousePosition.y
    local dpr = graphics:GetDPR()
    local logicalW = screenW / dpr
    local logicalH = screenH / dpr
    
    local centerX = logicalW / 2
    local centerY = logicalH / 2
    local mapScale = math.min(logicalW, logicalH) / 800
    
    local galaxyList = GalaxyData.GetAllSystems()
    for i = 1, #galaxyList do
        local sys = galaxyList[i]
        local sx = centerX + sys.mapX * mapScale
        local sy = centerY + sys.mapY * mapScale
        local dx = mx / dpr - sx
        local dy = my / dpr - sy
        local dist = math.sqrt(dx * dx + dy * dy)
        
        if dist < 20 and i ~= currentSystemIndex then
            warp.targetIndex = i
            warp.animProgress = 0
            gameState = "warping"
            print("跃迁到: " .. sys.name)
            return
        end
    end
end

-- ============================================================================
-- NanoVG HUD 渲染 (覆盖在3D场景之上)
-- ============================================================================

function HandleNanoVGRender(eventType, eventData)
    if not vg then return end
    
    local dpr = graphics:GetDPR()
    local logicalW = screenW / dpr
    local logicalH = screenH / dpr
    
    nvgBeginFrame(vg, logicalW, logicalH, dpr)
    
    -- 红巨星环境滤镜 (在HUD之下)
    if gameState == "playing" then
        SpaceEnvironment.DrawFilter(vg, logicalW, logicalH)
    end
    
    if gameState == "playing" then
        DrawHUD(logicalW, logicalH)
    elseif gameState == "starmap" then
        DrawStarmap(logicalW, logicalH)
    elseif gameState == "warping" then
        DrawWarpEffect(logicalW, logicalH)
    end
    
    nvgEndFrame(vg)
end

-- ============================================================================
-- HUD绘制 (参考 Highfleet 军事终端风格)
-- ============================================================================

function DrawHUD(w, h)
    nvgFontFaceId(vg, fontNormal)

    -- ── 顶部信息栏 (全宽) ──
    DrawTopBar(w, h)

    -- ── 右侧: 舰船状态面板 ──
    DrawShipPanel(w, h)

    -- ── 左下角: 雷达小地图 ──
    DrawMinimap(w, h)

    -- ── 底部中央: 速度 + 航向 ──
    DrawNavInfo(w, h)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 顶部栏: 日期 | 位置+资源 | 通讯状态
-- ─────────────────────────────────────────────────────────────────────────────
function DrawTopBar(w, h)
    local barH = 28
    -- 背景条 (极薄半透明)
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, barH)
    nvgFillColor(vg, nvgRGBA(5, 10, 18, 200))
    nvgFill(vg)
    -- 底边线
    nvgBeginPath(vg)
    nvgMoveTo(vg, 0, barH)
    nvgLineTo(vg, w, barH)
    nvgStrokeColor(vg, nvgRGBA(S.BORDER[1], S.BORDER[2], S.BORDER[3], 60))
    nvgStrokeWidth(vg, 0.5)
    nvgStroke(vg)

    local cy = barH / 2

    -- ── 左侧: 时钟 + 日期 ──
    nvgFontSize(vg, S.FONT_BODY)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    -- 模拟时间 (基于 elapsedTime)
    local gameHour = math.floor(elapsedTime / 60) % 24
    local gameMin = math.floor(elapsedTime) % 60
    nvgFillColor(vg, S.Color(vg, S.TEXT_MAIN))
    nvgText(vg, 12, cy, string.format("%02d:%02d", gameHour, gameMin), nil)

    nvgFillColor(vg, S.Color(vg, S.TEXT_WEAK))
    nvgFontSize(vg, S.FONT_LABEL)
    nvgText(vg, 52, cy, "CYCLE 2547", nil)

    -- 竖分隔线
    nvgBeginPath(vg)
    nvgMoveTo(vg, 110, 6)
    nvgLineTo(vg, 110, barH - 6)
    nvgStrokeColor(vg, nvgRGBA(S.BORDER[1], S.BORDER[2], S.BORDER[3], 80))
    nvgStrokeWidth(vg, 0.5)
    nvgStroke(vg)

    -- 游戏速度指示 (竖线右侧)
    nvgFontSize(vg, S.FONT_TINY)
    nvgFillColor(vg, S.Color(vg, S.PRIMARY))
    nvgText(vg, 116, cy, "NORMAL", nil)

    -- ── 中央: 星系位置 + 资源 ──
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFontSize(vg, S.FONT_BODY)
    nvgFillColor(vg, S.Color(vg, S.TEXT_MAIN))
    local sysName = currentSystemData and currentSystemData.name or "---"
    nvgText(vg, w / 2, cy, sysName, nil)

    -- 资源指示 (中央偏右)
    local resX = w / 2 + 80
    nvgFontSize(vg, S.FONT_LABEL)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    -- 船体
    nvgFillColor(vg, S.Color(vg, S.PRIMARY_DIM))
    nvgText(vg, resX, cy, string.format("⛨ %d", ship.hull), nil)
    -- 燃料
    nvgFillColor(vg, S.Color(vg, S.ACCENT_DIM))
    nvgText(vg, resX + 60, cy, string.format("⛽ %d", math.floor(ship.fuel)), nil)

    -- ── 右侧: 跃迁/通讯状态 ──
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgFontSize(vg, S.FONT_LABEL)
    if warp.cooldown > 0 then
        nvgFillColor(vg, S.Color(vg, S.ACCENT))
        nvgText(vg, w - 12, cy, string.format("WARP CD %.1fs", warp.cooldown), nil)
    else
        nvgFillColor(vg, S.Color(vg, S.PRIMARY_DIM))
        nvgText(vg, w - 12, cy, "WARP READY", nil)
    end

    -- 右侧第二行: TAB提示
    nvgFontSize(vg, S.FONT_TINY)
    nvgFillColor(vg, S.Color(vg, S.TEXT_WEAK))
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
    nvgText(vg, w - 12, barH + 4, "[TAB] STAR MAP", nil)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 右侧面板: 飞船组件/状态 (参考 SHIP COMPONENTS)
-- ─────────────────────────────────────────────────────────────────────────────
function DrawShipPanel(w, h)
    local panelW = 170
    local panelH = 220
    local panelX = w - panelW - 10
    local panelY = 42

    S.DrawPanel(vg, panelX, panelY, panelW, panelH, { border = S.BORDER_DIM })

    -- 标题 "SHIP STATUS"
    local titleH = 20
    nvgBeginPath(vg)
    nvgRoundedRect(vg, panelX, panelY, panelW, titleH, S.PANEL_RADIUS)
    -- 标题栏 (如参考图: 青绿色背景条)
    nvgFillColor(vg, nvgRGBA(S.PRIMARY[1], S.PRIMARY[2], S.PRIMARY[3], 35))
    nvgFill(vg)

    nvgFontSize(vg, S.FONT_LABEL)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, S.Color(vg, S.PRIMARY))
    nvgText(vg, panelX + 8, panelY + titleH / 2, "SHIP STATUS", nil)

    -- 分隔线
    local contentY = panelY + titleH + 6
    S.DrawSeparator(vg, panelX + 8, contentY - 2, panelW - 16)

    -- ── 状态条 (垂直排列) ──
    local barX = panelX + 48
    local barW = panelW - 58
    local lineH = 22

    nvgFontSize(vg, S.FONT_TINY)
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)

    -- HULL
    nvgFillColor(vg, S.Color(vg, S.PRIMARY_DIM))
    nvgText(vg, barX - 4, contentY + S.BAR_HEIGHT / 2, "HULL", nil)
    S.DrawBar(vg, barX, contentY, barW, ship.hull / CONFIG.MaxHull, S.PRIMARY)
    -- 数值
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgFontSize(vg, S.FONT_TINY)
    nvgFillColor(vg, S.Color(vg, S.TEXT_SEC))
    nvgText(vg, panelX + panelW - 8, contentY + S.BAR_HEIGHT / 2,
        string.format("%d/%d", ship.hull, CONFIG.MaxHull), nil)

    -- SHIELD
    contentY = contentY + lineH
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, S.Color(vg, S.SHIELD_DIM))
    nvgText(vg, barX - 4, contentY + S.BAR_HEIGHT / 2, "SHLD", nil)
    S.DrawBar(vg, barX, contentY, barW, 1.0, S.SHIELD)
    nvgFillColor(vg, S.Color(vg, S.TEXT_SEC))
    nvgText(vg, panelX + panelW - 8, contentY + S.BAR_HEIGHT / 2, "4950/4950", nil)

    -- FUEL
    contentY = contentY + lineH
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, S.Color(vg, S.ACCENT_DIM))
    nvgText(vg, barX - 4, contentY + S.BAR_HEIGHT / 2, "FUEL", nil)
    S.DrawBar(vg, barX, contentY, barW, ship.fuel / CONFIG.MaxFuel, S.ACCENT)
    nvgFillColor(vg, S.Color(vg, S.TEXT_SEC))
    nvgText(vg, panelX + panelW - 8, contentY + S.BAR_HEIGHT / 2,
        string.format("%d/%d", math.floor(ship.fuel), CONFIG.MaxFuel), nil)

    -- ── 武器分区 (橙色标题) ──
    contentY = contentY + lineH + 6
    -- 橙色分区标题条
    nvgBeginPath(vg)
    nvgRect(vg, panelX + 6, contentY, panelW - 12, 14)
    nvgFillColor(vg, nvgRGBA(S.ACCENT[1], S.ACCENT[2], S.ACCENT[3], 25))
    nvgFill(vg)
    nvgFontSize(vg, S.FONT_TINY)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, S.Color(vg, S.ACCENT))
    nvgText(vg, panelX + 10, contentY + 7, "MAIN WEAPONS", nil)
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgText(vg, panelX + panelW - 10, contentY + 7, "2/2", nil)

    -- 武器列表
    contentY = contentY + 18
    nvgFontSize(vg, S.FONT_TINY)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg, S.Color(vg, S.TEXT_MAIN))
    nvgText(vg, panelX + 12, contentY, "Plasma Cannon Mk.3", nil)
    contentY = contentY + 12
    nvgFillColor(vg, S.Color(vg, S.TEXT_WEAK))
    nvgText(vg, panelX + 12, contentY, "DMG 450  RNG 120m", nil)

    contentY = contentY + 16
    nvgFillColor(vg, S.Color(vg, S.TEXT_MAIN))
    nvgText(vg, panelX + 12, contentY, "Railgun Mk.2", nil)
    contentY = contentY + 12
    nvgFillColor(vg, S.Color(vg, S.TEXT_WEAK))
    nvgText(vg, panelX + 12, contentY, "DMG 680  RNG 200m", nil)

    -- ── 底部: TOTALS ──
    local totalsY = panelY + panelH - 22
    S.DrawSeparator(vg, panelX + 8, totalsY - 4, panelW - 16)
    nvgFontSize(vg, S.FONT_TINY)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg, S.Color(vg, S.PRIMARY))
    nvgText(vg, panelX + 8, totalsY, "TOTALS", nil)
    nvgFillColor(vg, S.Color(vg, S.TEXT_SEC))
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
    nvgText(vg, panelX + panelW - 8, totalsY,
        string.format("SPD %d  ARM %d", math.floor(ship.speed), ship.hull), nil)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 底部中央: 航行信息 (速度+航向)
-- ─────────────────────────────────────────────────────────────────────────────
function DrawNavInfo(w, h)
    local panelW = 160
    local panelH = 44
    local panelX = w / 2 - panelW / 2
    local panelY = h - panelH - 8

    S.DrawPanel(vg, panelX, panelY, panelW, panelH, { border = S.BORDER_DIM })

    -- 速度 (大字)
    local speedText = string.format("%.0f", ship.speed)
    nvgFontSize(vg, S.FONT_TITLE)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, S.Color(vg, S.TEXT_MAIN))
    nvgText(vg, panelX + panelW * 0.35, panelY + panelH / 2, speedText, nil)

    -- M/S 标签
    nvgFontSize(vg, S.FONT_TINY)
    nvgFillColor(vg, S.Color(vg, S.TEXT_WEAK))
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgText(vg, panelX + panelW * 0.55, panelY + panelH / 2 - 5, "M/S", nil)

    -- 航向角度
    local headingDeg = math.floor(math.deg(ship.heading)) % 360
    nvgFillColor(vg, S.Color(vg, S.TEXT_SEC))
    nvgText(vg, panelX + panelW * 0.55, panelY + panelH / 2 + 7,
        string.format("HDG %03d°", headingDeg), nil)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 左下角: 雷达小地图 (圆形, 扫描线效果)
-- ─────────────────────────────────────────────────────────────────────────────
function DrawMinimap(w, h)
    local mapSize = S.MINIMAP_SIZE
    local mapX = 10
    local mapY = h - mapSize - 10
    local cx = mapX + mapSize / 2
    local cy = mapY + mapSize / 2
    local radius = mapSize / 2 - 4

    -- 圆形背景
    nvgBeginPath(vg)
    nvgCircle(vg, cx, cy, radius)
    nvgFillColor(vg, nvgRGBA(5, 12, 22, 220))
    nvgFill(vg)
    nvgStrokeColor(vg, S.Color(vg, S.BORDER_BRIGHT))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)

    -- 同心圆 (距离环)
    nvgStrokeWidth(vg, 0.4)
    nvgStrokeColor(vg, nvgRGBA(S.BORDER[1], S.BORDER[2], S.BORDER[3], 35))
    nvgBeginPath(vg)
    nvgCircle(vg, cx, cy, radius * 0.33)
    nvgStroke(vg)
    nvgBeginPath(vg)
    nvgCircle(vg, cx, cy, radius * 0.66)
    nvgStroke(vg)

    -- 十字准星
    nvgStrokeColor(vg, nvgRGBA(S.BORDER[1], S.BORDER[2], S.BORDER[3], 45))
    nvgStrokeWidth(vg, 0.4)
    nvgBeginPath(vg)
    nvgMoveTo(vg, cx - radius * 0.8, cy)
    nvgLineTo(vg, cx + radius * 0.8, cy)
    nvgStroke(vg)
    nvgBeginPath(vg)
    nvgMoveTo(vg, cx, cy - radius * 0.8)
    nvgLineTo(vg, cx, cy + radius * 0.8)
    nvgStroke(vg)

    -- 扫描线 (旋转的渐变扇形)
    local sweepAngle = elapsedTime * 1.5  -- 旋转速度
    nvgSave(vg)
    nvgTranslate(vg, cx, cy)
    nvgRotate(vg, sweepAngle)
    nvgBeginPath(vg)
    nvgMoveTo(vg, 0, 0)
    nvgArc(vg, 0, 0, radius * 0.9, 0, math.pi * 0.15, 1)  -- NVG_CW=1
    nvgClosePath(vg)
    local sweepGrad = nvgRadialGradient(vg, 0, 0, 0, radius * 0.9,
        nvgRGBA(S.PRIMARY[1], S.PRIMARY[2], S.PRIMARY[3], 40),
        nvgRGBA(S.PRIMARY[1], S.PRIMARY[2], S.PRIMARY[3], 0))
    nvgFillPaint(vg, sweepGrad)
    nvgFill(vg)
    -- 扫描线本体 (亮线)
    nvgBeginPath(vg)
    nvgMoveTo(vg, 0, 0)
    nvgLineTo(vg, radius * 0.9, 0)
    nvgStrokeColor(vg, nvgRGBA(S.PRIMARY[1], S.PRIMARY[2], S.PRIMARY[3], 60))
    nvgStrokeWidth(vg, 0.8)
    nvgStroke(vg)
    nvgRestore(vg)

    -- 缩放比
    local mapScale = mapSize / 300

    -- 恒星 (相对位置)
    if currentSystemData then
        local starRelX = cx - ship.x * mapScale * 0.3
        local starRelY = cy - ship.z * mapScale * 0.3
        local distFromCenter = math.sqrt((starRelX - cx)^2 + (starRelY - cy)^2)
        if distFromCenter < radius * 0.85 then
            local sc = currentSystemData.starColor
            S.DrawGlowDot(vg, starRelX, starRelY, 3,
                { math.floor(sc[1]*255), math.floor(sc[2]*255), math.floor(sc[3]*255), 255 }, 2)
        end
    end

    -- 玩家指示器 (中心三角)
    nvgSave(vg)
    nvgTranslate(vg, cx, cy)
    nvgRotate(vg, -ship.heading + math.pi / 2)
    nvgBeginPath(vg)
    nvgMoveTo(vg, 0, -5)
    nvgLineTo(vg, -3.5, 4)
    nvgLineTo(vg, 3.5, 4)
    nvgClosePath(vg)
    nvgFillColor(vg, S.Color(vg, S.PRIMARY))
    nvgFill(vg)
    nvgRestore(vg)

    -- 标签
    nvgFontFaceId(vg, fontNormal)
    nvgFontSize(vg, S.FONT_TINY)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg, S.Color(vg, S.TEXT_WEAK))
    nvgText(vg, mapX + 8, mapY + 4, "RADAR", nil)

    -- 右下角: 范围标注
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_BOTTOM)
    nvgText(vg, mapX + mapSize - 6, mapY + mapSize - 4, "300m", nil)
end

-- ============================================================================
-- 星图绘制 (全屏面板, 军事风格网格)
-- ============================================================================

function DrawStarmap(w, h)
    -- 全屏深蓝遮罩
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, S.Color(vg, S.BG_OVERLAY))
    nvgFill(vg)

    -- 面板区域 (居中, 留边距)
    local margin = 30
    local panelX = margin
    local panelY = margin
    local panelW = w - margin * 2
    local panelH = h - margin * 2
    S.DrawPanel(vg, panelX, panelY, panelW, panelH, { border = S.BORDER_BRIGHT, radius = 6 })

    -- 网格 (淡暗)
    nvgStrokeWidth(vg, 0.3)
    local gridSpacing = 50
    for gx = panelX + gridSpacing, panelX + panelW - 1, gridSpacing do
        nvgBeginPath(vg)
        nvgMoveTo(vg, gx, panelY)
        nvgLineTo(vg, gx, panelY + panelH)
        nvgStrokeColor(vg, nvgRGBA(20, 35, 55, 40))
        nvgStroke(vg)
    end
    for gy = panelY + gridSpacing, panelY + panelH - 1, gridSpacing do
        nvgBeginPath(vg)
        nvgMoveTo(vg, panelX, gy)
        nvgLineTo(vg, panelX + panelW, gy)
        nvgStrokeColor(vg, nvgRGBA(20, 35, 55, 40))
        nvgStroke(vg)
    end

    -- 面板标题栏
    nvgFontFaceId(vg, fontNormal)
    nvgFontSize(vg, S.FONT_TITLE)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg, S.Color(vg, S.TEXT_MAIN))
    nvgText(vg, w / 2, panelY + 12, "银 河 星 图", nil)

    -- 标题栏分隔线
    S.DrawSeparator(vg, panelX + 20, panelY + 38, panelW - 40)

    -- 副标题
    nvgFontSize(vg, S.FONT_LABEL)
    nvgFillColor(vg, S.Color(vg, S.TEXT_WEAK))
    nvgText(vg, w / 2, panelY + 44, "点击星系跃迁 | ESC 返回", nil)

    -- 星系连线和节点
    local centerX = w / 2
    local centerY = h / 2 + 10  -- 稍微下移避开标题
    local mapScale = math.min(panelW, panelH) / 800

    local galaxyList = GalaxyData.GetAllSystems()

    -- 航线连线 (暗青色)
    nvgStrokeWidth(vg, 0.6)
    for i = 1, #galaxyList do
        for j = i + 1, #galaxyList do
            local dx = galaxyList[i].mapX - galaxyList[j].mapX
            local dy = galaxyList[i].mapY - galaxyList[j].mapY
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist < 4000 then
                local sx1 = centerX + galaxyList[i].mapX * mapScale
                local sy1 = centerY + galaxyList[i].mapY * mapScale
                local sx2 = centerX + galaxyList[j].mapX * mapScale
                local sy2 = centerY + galaxyList[j].mapY * mapScale
                nvgBeginPath(vg)
                nvgMoveTo(vg, sx1, sy1)
                nvgLineTo(vg, sx2, sy2)
                nvgStrokeColor(vg, nvgRGBA(S.PRIMARY[1], S.PRIMARY[2], S.PRIMARY[3], 25))
                nvgStroke(vg)
            end
        end
    end

    -- 星系节点
    for i = 1, #galaxyList do
        local sys = galaxyList[i]
        local sx = centerX + sys.mapX * mapScale
        local sy = centerY + sys.mapY * mapScale
        local sc = sys.starColor
        local isCurrent = (i == currentSystemIndex)
        local radius = isCurrent and 8 or 5

        -- 颜色转 0-255
        local cr = math.floor(sc[1] * 255)
        local cg = math.floor(sc[2] * 255)
        local cb = math.floor(sc[3] * 255)

        -- 光晕 + 本体
        S.DrawGlowDot(vg, sx, sy, radius, { cr, cg, cb, 255 })

        -- 当前位置: 外圈标记 (主色圆环)
        if isCurrent then
            nvgBeginPath(vg)
            nvgCircle(vg, sx, sy, radius + 5)
            nvgStrokeColor(vg, S.Color(vg, S.PRIMARY))
            nvgStrokeWidth(vg, 1.2)
            nvgStroke(vg)
            -- "YOU" 标记
            nvgFontSize(vg, 7)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
            nvgFillColor(vg, S.Color(vg, S.PRIMARY_DIM))
            nvgText(vg, sx, sy - radius - 6, "◆ YOU", nil)
        end

        -- 星系名
        nvgFontSize(vg, S.FONT_LABEL)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(S.TEXT_SEC[1], S.TEXT_SEC[2], S.TEXT_SEC[3],
            isCurrent and 255 or 160))
        nvgText(vg, sx, sy + radius + 6, sys.name, nil)
    end

    -- 底部: 当前位置信息
    nvgFontSize(vg, S.FONT_BODY)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg, S.Color(vg, S.TEXT_SEC))
    nvgText(vg, panelX + 15, panelY + panelH - 10,
        "当前: " .. (currentSystemData and currentSystemData.name or "---"), nil)

    -- 底部右: 跃迁状态
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_BOTTOM)
    if warp.cooldown > 0 then
        nvgFillColor(vg, S.Color(vg, S.ACCENT))
        nvgText(vg, panelX + panelW - 15, panelY + panelH - 10,
            string.format("冷却中 %.1fs", warp.cooldown), nil)
    else
        nvgFillColor(vg, S.Color(vg, S.PRIMARY_DIM))
        nvgText(vg, panelX + panelW - 15, panelY + panelH - 10, "就绪", nil)
    end
end

-- ============================================================================
-- 跃迁特效 (青绿色隧道 + 拉伸星线)
-- ============================================================================

function DrawWarpEffect(w, h)
    local progress = warp.animProgress
    local cx = w / 2
    local cy = h / 2

    -- 深黑底
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(2, 4, 10, 255))
    nvgFill(vg)

    -- 隧道径向渐变 (中心深蓝 → 边缘纯黑)
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    local tunnel = nvgRadialGradient(vg, cx, cy, 0, math.max(w, h) * 0.5,
        nvgRGBA(S.BG_LIGHT[1], S.BG_LIGHT[2], S.BG_LIGHT[3], math.floor(80 * progress)),
        nvgRGBA(0, 0, 0, 0))
    nvgFillPaint(vg, tunnel)
    nvgFill(vg)

    -- 星线 (青绿色 + 少量白色)
    local numLines = 80
    for i = 1, numLines do
        local angle = (i / numLines) * math.pi * 2 + elapsedTime * 3
        local startDist = 10 + progress * 60
        local endDist = 100 + progress * math.max(w, h) * 0.65

        -- 交替青绿/白色
        local isPrimary = (i % 4 ~= 0)
        local alpha = progress * (isPrimary and 0.6 or 0.3)
        local lineW = isPrimary and (1.0 + progress * 1.5) or (0.5 + progress * 0.8)

        nvgBeginPath(vg)
        nvgMoveTo(vg, cx + math.cos(angle) * startDist, cy + math.sin(angle) * startDist)
        nvgLineTo(vg, cx + math.cos(angle) * endDist, cy + math.sin(angle) * endDist)
        if isPrimary then
            nvgStrokeColor(vg, nvgRGBAf(S.PRIMARY[1]/255, S.PRIMARY[2]/255, S.PRIMARY[3]/255, alpha))
        else
            nvgStrokeColor(vg, nvgRGBAf(0.8, 0.9, 1.0, alpha))
        end
        nvgStrokeWidth(vg, lineW)
        nvgStroke(vg)
    end

    -- 中心聚光 (白到青绿渐变)
    local glowRadius = 5 + progress * 50
    nvgBeginPath(vg)
    nvgCircle(vg, cx, cy, glowRadius)
    local centerGlow = nvgRadialGradient(vg, cx, cy, 0, glowRadius,
        nvgRGBAf(1, 1, 1, 0.9 * (1 - progress)),
        nvgRGBAf(S.PRIMARY[1]/255, S.PRIMARY[2]/255, S.PRIMARY[3]/255, 0))
    nvgFillPaint(vg, centerGlow)
    nvgFill(vg)

    -- 跃迁信息文字
    nvgFontFaceId(vg, fontNormal)
    nvgFontSize(vg, S.FONT_HEADING)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(S.PRIMARY[1], S.PRIMARY[2], S.PRIMARY[3],
        math.floor(255 * (1 - progress))))
    local targetName = GalaxyData.GetSystem(warp.targetIndex).name
    nvgText(vg, cx, cy + 80, "超光速跃迁 → " .. targetName, nil)

    -- 进度条 (底部居中)
    local barW = 160
    local barX = cx - barW / 2
    local barY = cy + 100
    S.DrawBar(vg, barX, barY, barW, progress, S.PRIMARY)
end
