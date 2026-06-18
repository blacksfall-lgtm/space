------------------------------------------------------------
-- SpaceEnvironment.lua
-- 星系背景渲染模块 (DDS贴图多层视差系统)
--
-- 核心原理:
--   DDS 贴图无 alpha 通道, 全部使用 additive blend
--   黑色区域自然透明(加0), 亮区叠加染色
--   平面完全跟随相机, 视差纯靠 UV offset
--   平面足够大(2000m), 不暴露矩形边缘
--
-- 层级 (从底到顶):
--   Layer 0: 深空底色 (Zone fogColor)
--   Layer 1: FX_galaxy_core_cloud.dds 主星云层
--   Layer 2: FX_galaxy_core_cloud.dds 细节星云层
--   Layer 3: FX_black_hole_clouds.dds 特殊云雾层
--   Layer 4: FX_stars_blink.dds 星点层
--   Layer 5: FX_stars_flow.dds 流动星点层
--   Layer 6: 暗角 (NanoVG)
--   Layer 7: 恒星/行星/小行星带 (3D - StarSystem)
--   Layer 8: 3D战舰
--   Layer 9: HUD UI (NanoVG)
------------------------------------------------------------

local SpaceEnvironment = {}

-- ============================================================================
-- 星系类型 → 背景配色
-- ============================================================================
-- 所有 tint 值是 additive 叠加到深空底色上的颜色
-- alpha 字段控制 MatDiffColor.a (调节整层亮度/强度)
local THEME_CONFIGS = {
    RED = {
        -- #080208
        bgColor = {0.031, 0.008, 0.031},
        -- 主星云: 暗红色云雾 (远距离感: uvScale大, alpha低, 漂移慢)
        mainNebula   = { tint = {0.54, 0.11, 0.13}, alpha = 0.20, intensity = 0.85 },
        -- 细节星云: 橙红色 (更远更淡)
        detailNebula = { tint = {0.83, 0.23, 0.13}, alpha = 0.08, intensity = 0.9 },
        -- 高光云层: 极淡局部增强 #FF6530
        highlightCloud = { tint = {1.0, 0.40, 0.19}, alpha = 0.04, intensity = 1.0, enabled = true },
        -- 特殊云雾: 暗紫 (可选, 默认关)
        specialCloud = { tint = {0.45, 0.15, 0.55}, alpha = 0.12, intensity = 1.0, enabled = false },
        -- 星点: 暖白 #FFD6C0
        starsBlink   = { tint = {1.0, 0.84, 0.75}, alpha = 0.55 },
        -- 流动星点: 暖橙 #FFB090
        starsFlow    = { tint = {1.0, 0.69, 0.56}, alpha = 0.15 },
        -- 暗角
        vignette     = { color = {0.02, 0.0, 0.0}, alpha = 0.35 },
    },
    BLUE = {
        -- #041020
        bgColor = {0.016, 0.063, 0.125},
        mainNebula   = { tint = {0.11, 0.35, 0.80}, alpha = 0.20, intensity = 0.85 },
        detailNebula = { tint = {0.30, 0.70, 1.0},  alpha = 0.08, intensity = 0.9 },
        highlightCloud = { tint = {0.50, 0.80, 1.0}, alpha = 0.04, intensity = 1.0, enabled = true },
        specialCloud = { tint = {0.20, 0.55, 0.90}, alpha = 0.10, intensity = 1.0, enabled = false },
        starsBlink   = { tint = {0.85, 0.95, 1.0},  alpha = 0.55 },
        starsFlow    = { tint = {0.50, 0.85, 1.0},  alpha = 0.15 },
        vignette     = { color = {0.0, 0.02, 0.06}, alpha = 0.32 },
    },
    YELLOW = {
        -- #0A0804
        bgColor = {0.039, 0.031, 0.016},
        mainNebula   = { tint = {0.70, 0.50, 0.10}, alpha = 0.20, intensity = 0.85 },
        detailNebula = { tint = {0.90, 0.75, 0.25}, alpha = 0.08, intensity = 0.9 },
        highlightCloud = { tint = {1.0, 0.85, 0.30}, alpha = 0.04, intensity = 1.0, enabled = true },
        specialCloud = { tint = {0.60, 0.45, 0.15}, alpha = 0.10, intensity = 1.0, enabled = false },
        starsBlink   = { tint = {1.0, 0.97, 0.85},  alpha = 0.55 },
        starsFlow    = { tint = {1.0, 0.90, 0.60},  alpha = 0.15 },
        vignette     = { color = {0.03, 0.02, 0.0}, alpha = 0.30 },
    },
    ORANGE = {
        -- #0C0602
        bgColor = {0.047, 0.024, 0.008},
        mainNebula   = { tint = {0.80, 0.35, 0.06}, alpha = 0.20, intensity = 0.85 },
        detailNebula = { tint = {1.0, 0.55, 0.15},  alpha = 0.08, intensity = 0.9 },
        highlightCloud = { tint = {1.0, 0.60, 0.20}, alpha = 0.04, intensity = 1.0, enabled = true },
        specialCloud = { tint = {0.70, 0.30, 0.10}, alpha = 0.10, intensity = 1.0, enabled = false },
        starsBlink   = { tint = {1.0, 0.90, 0.75},  alpha = 0.55 },
        starsFlow    = { tint = {1.0, 0.75, 0.45},  alpha = 0.15 },
        vignette     = { color = {0.03, 0.01, 0.0}, alpha = 0.33 },
    },
    WHITE = {
        -- #0A0B0F
        bgColor = {0.039, 0.043, 0.059},
        mainNebula   = { tint = {0.40, 0.45, 0.60}, alpha = 0.18, intensity = 0.85 },
        detailNebula = { tint = {0.60, 0.65, 0.80}, alpha = 0.07, intensity = 0.9 },
        highlightCloud = { tint = {0.80, 0.85, 1.0}, alpha = 0.04, intensity = 1.0, enabled = true },
        specialCloud = { tint = {0.35, 0.40, 0.55}, alpha = 0.08, intensity = 1.0, enabled = false },
        starsBlink   = { tint = {0.95, 0.97, 1.0},  alpha = 0.60 },
        starsFlow    = { tint = {0.85, 0.90, 1.0},  alpha = 0.15 },
        vignette     = { color = {0.01, 0.01, 0.02}, alpha = 0.28 },
    },
    BINARY = {
        -- #080A14
        bgColor = {0.031, 0.039, 0.078},
        mainNebula   = { tint = {0.35, 0.20, 0.85}, alpha = 0.20, intensity = 0.85 },
        detailNebula = { tint = {0.65, 0.35, 1.0},  alpha = 0.08, intensity = 0.9 },
        highlightCloud = { tint = {0.70, 0.45, 1.0}, alpha = 0.04, intensity = 1.0, enabled = true },
        specialCloud = { tint = {0.50, 0.25, 0.80}, alpha = 0.10, intensity = 1.0, enabled = false },
        starsBlink   = { tint = {0.90, 0.85, 1.0},  alpha = 0.55 },
        starsFlow    = { tint = {0.70, 0.60, 1.0},  alpha = 0.15 },
        vignette     = { color = {0.01, 0.0, 0.04}, alpha = 0.35 },
    },
}

-- ============================================================================
-- 贴图路径
-- ============================================================================
local TEX_NEBULA      = "image/FX_galaxy_core_cloud.dds"
local TEX_STARS_BLINK = "image/FX_stars_blink.dds"
local TEX_STARS_FLOW  = "image/FX_stars_flow.dds"
local TEX_BLACK_HOLE  = "image/FX_black_hole_clouds.dds"

-- ============================================================================
-- 内部状态
-- ============================================================================
local scene_ = nil
local envRoot_ = nil
local lastCamX_ = 0
local lastCamZ_ = 0
local bgPlanes_ = {}
local theme_ = nil
local elapsedTime_ = 0

-- ============================================================================
-- 工具函数: 创建跟随相机的 additive 背景平面
-- ============================================================================

--- 创建一个背景平面 (水平, additive blend, 跟随相机)
---@param name string
---@param texPath string
---@param yPos number   深度层 (越负越远)
---@param size number   平面尺寸 (米)
---@param tintR number  叠加颜色 R
---@param tintG number  叠加颜色 G
---@param tintB number  叠加颜色 B
---@param alpha number  整层强度 (MatDiffColor.a)
---@param uvScale number UV缩放 (tiling)
local function CreateBgPlane(name, texPath, yPos, size, tintR, tintG, tintB, alpha, uvScale)
    local node = envRoot_:CreateChild(name)
    node:SetPosition(Vector3(lastCamX_, yPos, lastCamZ_))
    node:SetScale(Vector3(size, 1, size))

    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Plane.mdl"))

    -- 全部使用 additive blend: 黑色区域自然透明
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/DiffAddAlpha.xml"))

    local tex = cache:GetResource("Texture2D", texPath)
    if tex then
        mat:SetTexture(TU_DIFFUSE, tex)
    end

    -- MatDiffColor: RGB=染色, A=整层强度
    mat:SetShaderParameter("MatDiffColor", Variant(Vector4(tintR, tintG, tintB, alpha)))

    -- UV tiling (scale 在 x/y 分量, offset 在 w 分量)
    mat:SetShaderParameter("UOffset", Variant(Vector4(uvScale, 0, 0, 0)))
    mat:SetShaderParameter("VOffset", Variant(Vector4(0, uvScale, 0, 0)))

    model:SetMaterial(mat)

    return node, mat
end

-- ============================================================================
-- 公共接口
-- ============================================================================

function SpaceEnvironment.Build(scene, camX, camZ, starType)
    SpaceEnvironment.Clear()

    scene_ = scene
    envRoot_ = scene:CreateChild("SpaceEnvironment")
    lastCamX_ = camX or 0
    lastCamZ_ = camZ or 0
    elapsedTime_ = 0

    -- 选择主题
    theme_ = THEME_CONFIGS[starType or "RED"] or THEME_CONFIGS.RED

    -- 1. Zone 背景色 + 灯光
    SpaceEnvironment.SetupLighting()

    -- 2. 背景贴图层
    SpaceEnvironment.BuildBackgroundLayers()

    print("[SpaceEnvironment] Built: starType=" .. (starType or "RED") .. ", layers=" .. #bgPlanes_)
end

-- ============================================================================
-- 灯光/Zone 设置
-- ============================================================================

function SpaceEnvironment.SetupLighting()
    local lightGroup = scene_:GetChild("LightGroup", true)
    if not lightGroup then return end

    local zone = lightGroup:GetComponent("Zone", true)
    if zone then
        local bg = theme_.bgColor
        zone.fogColor = Color(bg[1], bg[2], bg[3])
        zone.fogStart = 800
        zone.fogEnd = 1200
        -- 环境光: 稍微提亮使3D物体可见
        zone.ambientColor = Color(bg[1] * 3.0 + 0.04, bg[2] * 3.0 + 0.04, bg[3] * 3.0 + 0.04)
    end

    local light = lightGroup:GetComponent("Light", true)
    if light then
        -- 主方向光基于星系主星云色调
        local mn = theme_.mainNebula.tint
        light.color = Color(
            mn[1] * 0.5 + 0.5,
            mn[2] * 0.5 + 0.4,
            mn[3] * 0.5 + 0.3
        )
        light.brightness = 1.6
        lightGroup:SetRotation(Quaternion(50, -30, 0))
    end
end

-- ============================================================================
-- 背景贴图层构建 (全部 additive, 跟随相机)
-- ============================================================================

function SpaceEnvironment.BuildBackgroundLayers()
    bgPlanes_ = {}

    -- 平面尺寸: 足够大, 即使 32x 缩放也不露边
    local PLANE_SIZE = 2000

    local mn = theme_.mainNebula
    local dn = theme_.detailNebula
    local hc = theme_.highlightCloud
    local sc = theme_.specialCloud
    local sb = theme_.starsBlink
    local sf = theme_.starsFlow

    -- Layer 1: 主星云层 (最深, 远距离感)
    -- uvScale=2.4 让云纹更小更远, alpha=0.20 更淡, parallax=0.01 近乎静止
    local node1, mat1 = CreateBgPlane(
        "MainNebula", TEX_NEBULA, -20, PLANE_SIZE,
        mn.tint[1] * mn.intensity,
        mn.tint[2] * mn.intensity,
        mn.tint[3] * mn.intensity,
        mn.alpha, 2.4
    )
    table.insert(bgPlanes_, {
        node = node1, mat = mat1,
        parallaxFactor = 0.01,
        driftX = 0.0004, driftZ = 0.0002,
        uvOffsetX = 0, uvOffsetZ = 0,
        uvScale = 2.4,
        yPos = -20,
    })

    -- Layer 2: 细节星云层 (更远更淡)
    -- uvScale=3.2 更细碎, alpha=0.08 极淡, parallax=0.02 微动
    local node2, mat2 = CreateBgPlane(
        "DetailNebula", TEX_NEBULA, -18, PLANE_SIZE,
        dn.tint[1] * dn.intensity,
        dn.tint[2] * dn.intensity,
        dn.tint[3] * dn.intensity,
        dn.alpha, 3.2
    )
    table.insert(bgPlanes_, {
        node = node2, mat = mat2,
        parallaxFactor = 0.02,
        driftX = -0.0006, driftZ = 0.0004,
        uvOffsetX = 0.3, uvOffsetZ = 0.15,  -- 初始偏移避免与主层完全重叠
        uvScale = 3.2,
        yPos = -18,
    })

    -- Layer 3: 高光云层 (极淡, 高uvScale局部增强, 营造纵深)
    if hc and hc.enabled then
        local node3, mat3 = CreateBgPlane(
            "HighlightCloud", TEX_NEBULA, -17, PLANE_SIZE,
            hc.tint[1] * hc.intensity,
            hc.tint[2] * hc.intensity,
            hc.tint[3] * hc.intensity,
            hc.alpha, 4.0
        )
        table.insert(bgPlanes_, {
            node = node3, mat = mat3,
            parallaxFactor = 0.03,
            driftX = 0.0008, driftZ = -0.0003,
            uvOffsetX = 0.6, uvOffsetZ = 0.4,  -- 不同初始偏移
            uvScale = 4.0,
            yPos = -17,
        })
    end

    -- Layer 4: 特殊云雾层 (可选, 用于黑洞/Boss区域)
    if sc and sc.enabled then
        local node4, mat4 = CreateBgPlane(
            "SpecialCloud", TEX_BLACK_HOLE, -16, PLANE_SIZE,
            sc.tint[1] * sc.intensity,
            sc.tint[2] * sc.intensity,
            sc.tint[3] * sc.intensity,
            sc.alpha, 1.5
        )
        table.insert(bgPlanes_, {
            node = node4, mat = mat4,
            parallaxFactor = 0.04,
            driftX = 0.001, driftZ = -0.0005,
            uvOffsetX = 0, uvOffsetZ = 0,
            uvScale = 1.5,
            yPos = -16,
        })
    end

    -- Layer 5: 星点层 (闪烁)
    local node5, mat5 = CreateBgPlane(
        "StarsBlink", TEX_STARS_BLINK, -14, PLANE_SIZE,
        sb.tint[1], sb.tint[2], sb.tint[3],
        sb.alpha, 1.2
    )
    table.insert(bgPlanes_, {
        node = node5, mat = mat5,
        parallaxFactor = 0.06,
        driftX = 0, driftZ = 0,
        uvOffsetX = 0, uvOffsetZ = 0,
        uvScale = 1.2,
        yPos = -14,
        blink = true,
        baseAlpha = sb.alpha,
        tintR = sb.tint[1], tintG = sb.tint[2], tintB = sb.tint[3],
    })

    -- Layer 6: 流动星点层 (速度驱动)
    local node6, mat6 = CreateBgPlane(
        "StarsFlow", TEX_STARS_FLOW, -12, PLANE_SIZE,
        sf.tint[1], sf.tint[2], sf.tint[3],
        sf.alpha, 1.0
    )
    table.insert(bgPlanes_, {
        node = node6, mat = mat6,
        parallaxFactor = 0.35,
        driftX = 0, driftZ = 0,
        uvOffsetX = 0, uvOffsetZ = 0,
        uvScale = 1.0,
        yPos = -12,
        speedBased = true,
        baseAlpha = sf.alpha,
        tintR = sf.tint[1], tintG = sf.tint[2], tintB = sf.tint[3],
    })
end

-- ============================================================================
-- 每帧更新
-- 关键: 平面位置完全跟随相机, 视差纯靠 UV offset
-- ============================================================================

function SpaceEnvironment.Update(dt, elapsedTime, camX, camZ, shipSpeed, camZoom)
    if not envRoot_ then return end

    camX = camX or 0
    camZ = camZ or 0
    elapsedTime_ = elapsedTime or (elapsedTime_ + dt)
    shipSpeed = shipSpeed or 0
    camZoom = camZoom or 1.0

    local dx = camX - lastCamX_
    local dz = camZ - lastCamZ_
    lastCamX_ = camX
    lastCamZ_ = camZ

    -- 深空背景强度固定，不随镜头缩放变化
    local zoomIntensity = 1.0

    for _, layer in ipairs(bgPlanes_) do
        -- 平面完全跟随相机位置 (消除矩形边缘)
        layer.node:SetPosition(Vector3(camX, layer.yPos, camZ))

        -- 视差: 通过 UV offset 实现, 相机移动时近层 UV 偏移大
        -- parallaxFactor 越大 = UV 偏移越多 = 看起来越近
        layer.uvOffsetX = layer.uvOffsetX + dx * layer.parallaxFactor * 0.001
        layer.uvOffsetZ = layer.uvOffsetZ + dz * layer.parallaxFactor * 0.001

        -- 自身缓慢漂移
        layer.uvOffsetX = layer.uvOffsetX + layer.driftX * dt
        layer.uvOffsetZ = layer.uvOffsetZ + layer.driftZ * dt

        -- 速度驱动层: 根据飞船速度调整强度
        if layer.speedBased then
            local speedFactor = math.min(shipSpeed / 50.0, 1.0)
            local flowAlpha = layer.baseAlpha * (0.1 + 0.9 * speedFactor) * zoomIntensity
            layer.uvOffsetX = layer.uvOffsetX - dx * 0.0003
            layer.uvOffsetZ = layer.uvOffsetZ - dz * 0.0003
            layer.mat:SetShaderParameter("MatDiffColor", Variant(Vector4(layer.tintR, layer.tintG, layer.tintB, flowAlpha)))
        -- 星点闪烁: sin波调节强度
        elseif layer.blink then
            local blinkFactor = 0.85 + math.sin(elapsedTime_ * 1.5) * 0.15
            local blinkAlpha = layer.baseAlpha * blinkFactor * zoomIntensity
            layer.mat:SetShaderParameter("MatDiffColor", Variant(Vector4(layer.tintR, layer.tintG, layer.tintB, blinkAlpha)))
        end

        -- 更新 UV offset
        if layer.mat then
            local s = layer.uvScale or 1.0
            layer.mat:SetShaderParameter("UOffset", Variant(Vector4(s, 0, 0, layer.uvOffsetX)))
            layer.mat:SetShaderParameter("VOffset", Variant(Vector4(0, s, 0, layer.uvOffsetZ)))
        end
    end
end

-- ============================================================================
-- NanoVG 暗角 (在 HUD 渲染时调用)
-- ============================================================================

function SpaceEnvironment.DrawFilter(vg, w, h)
    if not theme_ then return end

    local vig = theme_.vignette
    if not vig then return end

    -- 径向暗角: 中心透明 → 边缘深色
    local cx, cy = w * 0.5, h * 0.5
    local radius = math.max(w, h) * 0.7

    local paint = nvgRadialGradient(vg,
        cx, cy,
        radius * 0.5, radius,
        nvgRGBA(0, 0, 0, 0),
        nvgRGBA(
            math.floor(vig.color[1] * 255),
            math.floor(vig.color[2] * 255),
            math.floor(vig.color[3] * 255),
            math.floor(vig.alpha * 255)
        )
    )
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillPaint(vg, paint)
    nvgFill(vg)
end

-- ============================================================================
-- 清理
-- ============================================================================

function SpaceEnvironment.Clear()
    if envRoot_ then
        envRoot_:Remove()
        envRoot_ = nil
    end
    bgPlanes_ = {}
    theme_ = nil
    scene_ = nil
end

return SpaceEnvironment
