------------------------------------------------------------
-- StarSystem.lua
-- 星系3D内容生成模块
-- 负责在3D场景中构建恒星、行星、小行星带等天体
------------------------------------------------------------

local StarSystem = {}

-- 内部引用
local rootNode_ = nil
local scene_ = nil
local systemData_ = nil
local planetNodes_ = {}
local asteroidNodes_ = {}
local starNode_ = nil
local secondStarNode_ = nil

------------------------------------------------------------
-- 辅助：创建 PBR 材质
------------------------------------------------------------
local function CreateEmissiveMaterial(r, g, b, intensity)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Vector4(r, g, b, 1.0)))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Vector3(r * intensity, g * intensity, b * intensity)))
    mat:SetShaderParameter("Roughness", Variant(1.0))
    mat:SetShaderParameter("Metallic", Variant(0.0))
    return mat
end

------------------------------------------------------------
-- 行星类型 → 贴图映射
------------------------------------------------------------
local PLANET_TEXTURE_MAP = {
    LAVA   = { diffuse = "Textures/Planets/lava_diffuse.png",  normal = "Textures/Planets/lava_normal.png" },
    ICE    = { diffuse = "Textures/Planets/ice_diffuse.png",   normal = "Textures/Planets/ice_normal.png" },
    OCEAN  = { diffuse = "Textures/Planets/ice_diffuse.png",   normal = "Textures/Planets/ice_normal.png" },
    GAS    = { diffuse = "Textures/Planets/gas_giant_diffuse.png", normal = "Textures/Planets/gas_giant_normal.png" },
    ROCKY  = { diffuse = "Textures/Planets/rocky_diffuse.png", normal = "Textures/Planets/rocky_normal.png" },
    DESERT = { diffuse = "Textures/Planets/rocky_diffuse.png", normal = "Textures/Planets/rocky_normal.png" },
}

local function CreatePlanetMaterial(r, g, b, planetType)
    local mat = Material:new()
    local texInfo = planetType and PLANET_TEXTURE_MAP[planetType]
    local diffTex = texInfo and cache:GetResource("Texture2D", texInfo.diffuse)
    local normTex = texInfo and texInfo.normal and cache:GetResource("Texture2D", texInfo.normal)

    if diffTex and normTex then
        -- PBR + 漫反射贴图 + 法线贴图
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRDiffNormal.xml"))
        mat:SetTexture(TU_DIFFUSE, diffTex)
        mat:SetTexture(TU_NORMAL, normTex)
        mat:SetShaderParameter("MatDiffColor", Variant(Vector4(1.0, 1.0, 1.0, 1.0)))
        mat:SetShaderParameter("Roughness", Variant(0.8))
        mat:SetShaderParameter("Metallic", Variant(0.05))
    elseif diffTex then
        -- 仅漫反射贴图
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/Diff.xml"))
        mat:SetTexture(TU_DIFFUSE, diffTex)
        mat:SetShaderParameter("MatDiffColor", Variant(Vector4(1.0, 1.0, 1.0, 1.0)))
    else
        -- 降级：纯色 PBR
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(Vector4(r, g, b, 1.0)))
        mat:SetShaderParameter("Roughness", Variant(0.7))
        mat:SetShaderParameter("Metallic", Variant(0.1))
    end
    return mat
end

local function CreateAsteroidMaterial()
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    -- 灰褐色岩石
    local r = 0.35 + math.random() * 0.15
    local g = 0.3 + math.random() * 0.1
    local b = 0.25 + math.random() * 0.1
    mat:SetShaderParameter("MatDiffColor", Variant(Vector4(r, g, b, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(0.9))
    mat:SetShaderParameter("Metallic", Variant(0.05))
    return mat
end

------------------------------------------------------------
-- 红巨星贴图路径
------------------------------------------------------------
local STAR_TEXTURES = {
    surface  = "image/恒星贴图/star_surface_red_giant.png",
    emissive = "image/恒星贴图/star_emissive_red_giant.png",
    normal   = "image/恒星贴图/star_normal_red_giant.png",
    noise01  = "image/恒星贴图/star_noise_01.png",
    noise02  = "image/恒星贴图/star_noise_02.png",
    corona   = "image/恒星贴图/star_corona_red.png",
    flare    = "image/恒星贴图/star_flare_red.png",
    mask     = "image/恒星贴图/star_mask_red_giant.png",
}

-- ========== Phase 2: 自发光恒星 ==========
local STAR_RENDER_DEBUG_BODY_ONLY = false  -- Phase 1 已通过，进入正式渲染
local STAR_ENABLE_CORONA = true            -- 小范围日冕（Scale≤1.25, Alpha≤0.10）
local STAR_ENABLE_FLARE  = false           -- 耀斑关闭

-- 恒星各层节点引用（用于动态更新）
local starLayers_ = nil

------------------------------------------------------------
-- 创建恒星本体材质
-- Phase 2: Diff.xml + 低强度自发光（让暗面不死黑）
------------------------------------------------------------
local function CreateStarBodyMaterial(color)
    local mat = Material:new()

    local tech = cache:GetResource("Technique", "Techniques/Diff.xml")
    if tech then
        mat:SetTechnique(0, tech)
    else
        print("[StarSystem] ERROR: Diff.xml technique missing")
    end

    local surfaceTex = cache:GetResource("Texture2D", STAR_TEXTURES.surface)
    if surfaceTex then
        -- 减少 MipMap 模糊，保留表面纹理锐度
        surfaceTex.filterMode = FILTER_BILINEAR
        surfaceTex:SetNumLevels(1)  -- 关闭 MipMap，近景更锐
        mat:SetTexture(TU_DIFFUSE, surfaceTex)
        print("[StarSystem] star surface texture loaded: " .. surfaceTex:GetWidth() .. "x" .. surfaceTex:GetHeight())
    else
        print("[StarSystem] ERROR: FAILED to load star surface texture: " .. STAR_TEXTURES.surface)
        mat:SetShaderParameter("MatDiffColor", Variant(Vector4(1.0, 0.0, 1.0, 1.0)))
        return mat
    end

    -- DiffColor 深红：压低绿通道，保留纹理暗红层次
    mat:SetShaderParameter("MatDiffColor", Variant(Vector4(1.0, 0.38, 0.26, 1.0)))

    -- 高自发光：驱动 HDR Bloom 产生自然边缘辉光溢出
    mat:SetShaderParameter("MatEmissiveColor", Variant(Vector3(2.5, 0.6, 0.15)))

    return mat
end

------------------------------------------------------------
-- 创建加性混合材质（用于日冕、耀斑等外层）
------------------------------------------------------------
local function CreateAdditiveLayerMaterial(texturePath, r, g, b, alpha)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/DiffAddAlpha.xml"))

    local tex = cache:GetResource("Texture2D", texturePath)
    if tex then
        mat:SetTexture(TU_DIFFUSE, tex)
    else
        print("[StarSystem] WARNING: missing additive texture: " .. texturePath)
    end

    mat:SetShaderParameter("MatDiffColor", Variant(Vector4(r, g, b, alpha)))
    mat.depthWrite = false

    return mat
end

------------------------------------------------------------
-- 辅助：创建恒星外层 Billboard（日冕/耀斑统一入口）
------------------------------------------------------------
local function CreateStarBillboard(parentNode, name, texturePath, size, r, g, b, alpha)
    local node = parentNode:CreateChild(name)
    local bbs = node:CreateComponent("BillboardSet")
    bbs:SetNumBillboards(1)
    bbs:SetFaceCameraMode(FC_ROTATE_XYZ)

    local mat = CreateAdditiveLayerMaterial(texturePath, r, g, b, alpha)
    bbs:SetMaterial(mat)

    local bb = bbs:GetBillboard(0)
    bb.size = Vector2(size, size)
    bb.position = Vector3(0, 0, 0)
    bb.enabled = true
    bbs:Commit()

    return node, bbs, mat
end

------------------------------------------------------------
-- 创建恒星（多层渲染系统，通过开关控制各层级）
------------------------------------------------------------
local function BuildStar(parentNode, color, size, name)
    local node = parentNode:CreateChild(name or "Star")
    node:SetScale(Vector3(size, size, size))

    -- ========== Layer 1: 恒星本体（始终创建） ==========
    local bodyNode = node:CreateChild("StarBody")
    local bodyModel = bodyNode:CreateComponent("StaticModel")
    bodyModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    bodyModel:SetMaterial(CreateStarBodyMaterial(color))
    bodyModel.castShadows = false

    -- ========== Layer 2: 多层半透明球体发光（差速旋转产生等离子流动感） ==========
    -- 原理：半透明球壳叠加，边缘处多层 alpha 重叠自然产生发光描边效果
    -- 差速旋转让不同层交错，模拟等离子体流动
    local glowShells = {}  -- { {node, model, mat, baseScale, baseAlpha, color, rotAxis, rotSpeed}, ... }

    local GLOW_SPHERE_LAYERS = {
        -- 大幅降低透明度：Bloom 负责主要辉光，球壳只做流动层次辅助
        -- Layer A: 中层等离子（暖橙色，紧贴星体）
        {
            scale = 1.08, alpha = 0.08,
            color = {1.0, 0.55, 0.15},
            emissive = {3.0, 1.2, 0.2},   -- 高emissive 驱动额外 bloom
            rotAxis = Vector3(0.4, 1.0, 0.2):Normalized(),
            rotSpeed = 10,
        },
        -- Layer B: 外层等离子（深红，略大）
        {
            scale = 1.18, alpha = 0.05,
            color = {0.9, 0.3, 0.08},
            emissive = {2.0, 0.5, 0.1},
            rotAxis = Vector3(0.2, 0.8, 0.5):Normalized(),
            rotSpeed = -6,
        },
        -- Layer C: 最外晕（淡红，最大最透，几乎不可见，只增加 bloom 范围）
        {
            scale = 1.32, alpha = 0.03,
            color = {0.8, 0.2, 0.05},
            emissive = {1.0, 0.25, 0.05},
            rotAxis = Vector3(-0.3, 1.0, -0.4):Normalized(),
            rotSpeed = 4,
        },
    }

    if not STAR_RENDER_DEBUG_BODY_ONLY then
        for i, layer in ipairs(GLOW_SPHERE_LAYERS) do
            local shellNode = node:CreateChild("StarGlowShell_" .. i)
            shellNode:SetScale(layer.scale)
            -- 给初始旋转一个偏移，避免所有层初始对齐
            shellNode:SetRotation(Quaternion(i * 37, layer.rotAxis))

            local shellModel = shellNode:CreateComponent("StaticModel")
            shellModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))

            local mat = Material:new()
            mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            mat:SetShaderParameter("MatDiffColor", Variant(Vector4(
                layer.color[1], layer.color[2], layer.color[3], layer.alpha
            )))
            mat:SetShaderParameter("MatEmissiveColor", Variant(Vector3(
                layer.emissive[1], layer.emissive[2], layer.emissive[3]
            )))
            mat:SetShaderParameter("MatRoughness", Variant(0.4))
            mat:SetShaderParameter("MatMetallic", Variant(0.0))
            shellModel:SetMaterial(mat)
            shellModel.castShadows = false

            glowShells[i] = {
                node = shellNode, model = shellModel, mat = mat,
                baseAlpha = layer.alpha, baseScale = layer.scale,
                color = layer.color, emissive = layer.emissive,
                rotAxis = layer.rotAxis, rotSpeed = layer.rotSpeed,
            }
        end
    end

    -- ========== Layer 3: 日冕（条件创建） ==========
    local coronaNode = nil
    local coronaBbs = nil
    local coronaMat = nil
    local coronaBaseScale = 1.035
    local coronaBaseAlpha = 0.025

    if (not STAR_RENDER_DEBUG_BODY_ONLY) and STAR_ENABLE_CORONA then
        coronaNode, coronaBbs, coronaMat = CreateStarBillboard(
            node, "StarCorona", STAR_TEXTURES.corona,
            coronaBaseScale,
            color[1], color[2] * 0.18, color[3] * 0.08, coronaBaseAlpha
        )
    end

    -- ========== Layer 4: 耀斑（条件创建） ==========
    local flareNode = nil
    local flareBbs = nil
    local flareMat = nil
    local flareBaseAlpha = 0.04

    if (not STAR_RENDER_DEBUG_BODY_ONLY) and STAR_ENABLE_FLARE then
        flareNode, flareBbs, flareMat = CreateStarBillboard(
            node, "StarFlare", STAR_TEXTURES.flare,
            1.1,
            color[1] * 1.2, color[2] * 0.75, color[3] * 0.55, flareBaseAlpha
        )
    end

    -- ========== 恒星光源（调试模式完全不创建） ==========
    if not STAR_RENDER_DEBUG_BODY_ONLY then
        local lightNode = node:CreateChild("StarLight")
        local light = lightNode:CreateComponent("Light")
        light.lightType = LIGHT_POINT
        light.range = 400.0
        light.brightness = 1.4
        light.color = Color(color[1], color[2], color[3])
        light.castShadows = true
    end

    -- 保存各层引用用于动态更新
    starLayers_ = {
        body = bodyNode,
        bodyMat = bodyModel:GetMaterial(0),
        glowShells = glowShells,  -- 多层发光球壳数组
        corona = coronaNode,
        coronaBbs = coronaBbs,
        coronaMat = coronaMat,
        coronaBaseScale = coronaBaseScale,
        coronaBaseAlpha = coronaBaseAlpha,
        flare = flareNode,
        flareBbs = flareBbs,
        flareMat = flareMat,
        flareBaseAlpha = flareBaseAlpha,
        baseColor = color,
    }

    return node
end

------------------------------------------------------------
-- 创建行星
------------------------------------------------------------
local function BuildPlanet(parentNode, planetData, index)
    -- 行星轨道锚点节点（用于公转）
    local orbitNode = parentNode:CreateChild("PlanetOrbit_" .. index)

    -- 行星实体节点（偏离中心 orbitRadius 距离）
    local planetNode = orbitNode:CreateChild("Planet_" .. index)
    planetNode:SetPosition(Vector3(planetData.orbitRadius, 0, 0))

    local model = planetNode:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    model:SetMaterial(CreatePlanetMaterial(
        planetData.color[1], planetData.color[2], planetData.color[3],
        planetData.type
    ))

    local s = planetData.size
    planetNode:SetScale(Vector3(s, s, s))

    -- 气态巨行星的环
    if planetData.hasRing then
        local ringNode = planetNode:CreateChild("Ring")
        local ringModel = ringNode:CreateComponent("StaticModel")
        ringModel:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
        -- Torus 默认大小约 1.0，缩放到比行星略大
        local ringScale = s * 2.0
        ringNode:SetScale(Vector3(ringScale, ringScale * 0.05, ringScale))
        local ringMat = CreatePlanetMaterial(
            planetData.color[1] * 0.7,
            planetData.color[2] * 0.7,
            planetData.color[3] * 0.6
        )
        ringModel:SetMaterial(ringMat)
        -- 环稍微倾斜
        ringNode:SetRotation(Quaternion(15, Vector3.RIGHT))
    end

    -- 设置初始公转角度
    orbitNode:SetRotation(Quaternion(
        math.deg(planetData.startAngle), Vector3.UP
    ))

    return orbitNode
end

------------------------------------------------------------
-- 创建小行星带
------------------------------------------------------------
local function BuildAsteroidBelt(parentNode, density, innerRadius, outerRadius)
    local count = math.floor(density * 40) + 10
    local nodes = {}

    for i = 1, count do
        local angle = math.random() * math.pi * 2
        local radius = innerRadius + math.random() * (outerRadius - innerRadius)
        local height = (math.random() - 0.5) * 8.0

        local node = parentNode:CreateChild("Asteroid_" .. i)
        node:SetPosition(Vector3(
            math.cos(angle) * radius,
            height,
            math.sin(angle) * radius
        ))

        -- 随机旋转
        node:SetRotation(Quaternion(
            math.random() * 360, Vector3(math.random(), math.random(), math.random()):Normalized()
        ))

        -- 随机大小（2~6米，接近战舰尺寸的1/4~3/4）
        local s = 2.0 + math.random() * 4.0
        -- 不规则形状：使用不等比缩放的 Box 或 Sphere
        local sx = s * (0.6 + math.random() * 0.8)
        local sy = s * (0.5 + math.random() * 0.7)
        local sz = s * (0.6 + math.random() * 0.8)
        node:SetScale(Vector3(sx, sy, sz))

        local model = node:CreateComponent("StaticModel")
        -- 随机选择模型
        local models = {"Models/Box.mdl", "Models/Sphere.mdl"}
        local mdlIdx = math.random(1, #models)
        model:SetModel(cache:GetResource("Model", models[mdlIdx]))
        model:SetMaterial(CreateAsteroidMaterial())

        -- 给每个小行星存储旋转速度
        node.rotSpeed = (math.random() - 0.5) * 30

        nodes[i] = node
    end

    return nodes
end

------------------------------------------------------------
-- 创建空间站（简单几何体组合）
------------------------------------------------------------
local function BuildSpaceStation(parentNode, orbitRadius)
    local orbitNode = parentNode:CreateChild("StationOrbit")
    local stationNode = orbitNode:CreateChild("SpaceStation")
    stationNode:SetPosition(Vector3(orbitRadius, 2, 0))

    -- 主体圆柱
    local bodyNode = stationNode:CreateChild("Body")
    local bodyModel = bodyNode:CreateComponent("StaticModel")
    bodyModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    bodyNode:SetScale(Vector3(2.0, 3.0, 2.0))
    local stationMat = Material:new()
    stationMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    stationMat:SetShaderParameter("MatDiffColor", Variant(Vector4(0.6, 0.65, 0.7, 1.0)))
    stationMat:SetShaderParameter("Roughness", Variant(0.3))
    stationMat:SetShaderParameter("Metallic", Variant(0.9))
    bodyModel:SetMaterial(stationMat)

    -- 环形结构（Torus）
    local ringNode = stationNode:CreateChild("Ring")
    local ringModel = ringNode:CreateComponent("StaticModel")
    ringModel:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    ringNode:SetScale(Vector3(4.0, 4.0, 4.0))
    ringNode:SetPosition(Vector3(0, 0, 0))
    local ringMat = Material:new()
    ringMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    ringMat:SetShaderParameter("MatDiffColor", Variant(Vector4(0.5, 0.55, 0.6, 1.0)))
    ringMat:SetShaderParameter("Roughness", Variant(0.35))
    ringMat:SetShaderParameter("Metallic", Variant(0.85))
    ringModel:SetMaterial(ringMat)

    -- 信号灯（发光小球）
    local beaconNode = stationNode:CreateChild("Beacon")
    beaconNode:SetPosition(Vector3(0, 2.0, 0))
    local beaconModel = beaconNode:CreateComponent("StaticModel")
    beaconModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    beaconNode:SetScale(Vector3(0.3, 0.3, 0.3))
    beaconModel:SetMaterial(CreateEmissiveMaterial(0.2, 1.0, 0.4, 3.0))

    -- 初始角度
    orbitNode:SetRotation(Quaternion(math.random() * 360, Vector3.UP))

    return orbitNode
end

------------------------------------------------------------
-- 公开接口
------------------------------------------------------------

--- 构建星系3D内容
---@param scene any Scene 对象
---@param parentNode any 根节点
---@param data table 星系数据（来自 GalaxyData）
function StarSystem.Build(scene, parentNode, data)
    -- 清理旧内容
    StarSystem.Clear()

    scene_ = scene
    rootNode_ = parentNode
    systemData_ = data
    planetNodes_ = {}
    asteroidNodes_ = {}

    print("[StarSystem] Building: " .. data.name .. " (" .. data.starTypeName .. ")")

    -- 1. 创建恒星 (缩小到0.75倍, 避免过大遮挡星云深空感)
    starNode_ = BuildStar(rootNode_, data.starColor, data.starSize * 0.75, "MainStar")
    starNode_:SetPosition(Vector3(0, 0, 0))

    -- 2. 双星系统第二颗星
    if data.secondStar then
        local ss = data.secondStar
        secondStarNode_ = BuildStar(rootNode_, ss.color, ss.size, "SecondStar")
        secondStarNode_:SetPosition(Vector3(ss.orbitRadius, 0, 0))
    end

    -- 3. 创建行星
    for i, pdata in ipairs(data.planets) do
        local orbitNode = BuildPlanet(rootNode_, pdata, i)
        planetNodes_[i] = { node = orbitNode, data = pdata }
    end

    -- 4. 小行星带（在最外层行星之外）
    local outerRadius = 240 + #data.planets * 180 + 80
    local innerRadius = outerRadius - 60
    asteroidNodes_ = BuildAsteroidBelt(rootNode_, data.asteroidDensity, innerRadius, outerRadius + 40)

    -- 5. 空间站
    if data.hasStation then
        local stationOrbitR = 240 + math.floor(#data.planets / 2) * 180 + 30
        BuildSpaceStation(rootNode_, stationOrbitR)
    end

    print("[StarSystem] Build complete: " .. #data.planets .. " planets, " .. #asteroidNodes_ .. " asteroids")
end

--- 每帧更新天体动画（行星公转、恒星脉动、小行星自转）
---@param dt number 帧时间
---@param elapsedTime number 总已过时间
function StarSystem.Update(dt, elapsedTime)
    if not systemData_ then return end

    -- 行星公转
    for i, pInfo in ipairs(planetNodes_) do
        local node = pInfo.node
        local data = pInfo.data
        local angle = data.startAngle + elapsedTime * data.orbitSpeed
        node:SetRotation(Quaternion(math.deg(angle), Vector3.UP))
    end

    -- 双星公转
    if secondStarNode_ and systemData_.secondStar then
        local ss = systemData_.secondStar
        local angle = elapsedTime * ss.orbitSpeed
        local x = math.cos(angle) * ss.orbitRadius
        local z = math.sin(angle) * ss.orbitRadius
        secondStarNode_:SetPosition(Vector3(x, 0, z))
    end

    -- 恒星多层动态效果
    if starNode_ and starLayers_ then
        local baseSize = systemData_.starSize * 0.75

        -- 只保留缩放和旋转
        starNode_:SetScale(Vector3(baseSize, baseSize, baseSize))

        local bodyRotY = elapsedTime * 1.2
        starLayers_.body:SetRotation(Quaternion(bodyRotY, Vector3.UP))

        -- 调试阶段只验证贴图采样，不允许 emissive / corona / flare 干扰
        if STAR_RENDER_DEBUG_BODY_ONLY then
            starLayers_.bodyMat:SetShaderParameter("MatEmissiveColor", Variant(Vector3(0.0, 0.0, 0.0)))
            starLayers_.bodyMat:SetShaderParameter("MatDiffColor", Variant(Vector4(1.0, 1.0, 1.0, 1.0)))
            return
        end

        -- 下面才允许正式版本的 emissive / corona / flare
        local color = starLayers_.baseColor

        -- 高自发光脉冲：围绕 (2.5, 0.6, 0.15) 做 ±5% 微弱呼吸（驱动 Bloom）
        local emPulse = 1.0 + math.sin(elapsedTime * 0.35) * 0.04
            + math.sin(elapsedTime * 0.83) * 0.02
        starLayers_.bodyMat:SetShaderParameter("MatEmissiveColor", Variant(Vector3(
            2.5 * emPulse,
            0.6 * emPulse,
            0.15 * emPulse
        )))

        -- 多层发光球壳：差速旋转 + 呼吸脉动
        if starLayers_.glowShells then
            for i, shell in ipairs(starLayers_.glowShells) do
                if shell.node and shell.mat then
                    -- 差速旋转（每层不同轴和速度，产生等离子流动感）
                    shell.node:SetRotation(Quaternion(
                        elapsedTime * shell.rotSpeed, shell.rotAxis
                    ))
                    -- 呼吸脉动：alpha + emissive 微弱起伏
                    local freq = 0.4 + i * 0.25
                    local breathe = 1.0 + math.sin(elapsedTime * freq) * 0.12
                        + math.sin(elapsedTime * freq * 2.3) * 0.06
                    local shellAlpha = shell.baseAlpha * breathe
                    shell.mat:SetShaderParameter("MatDiffColor", Variant(Vector4(
                        shell.color[1], shell.color[2], shell.color[3], shellAlpha
                    )))
                    shell.mat:SetShaderParameter("MatEmissiveColor", Variant(Vector3(
                        shell.emissive[1] * breathe,
                        shell.emissive[2] * breathe,
                        shell.emissive[3] * breathe
                    )))
                    -- 尺寸微弱呼吸（±3%）
                    local scalePulse = shell.baseScale * (1.0 + math.sin(elapsedTime * freq * 0.7) * 0.03)
                    shell.node:SetScale(scalePulse)
                end
            end
        end

        -- 日冕透明度呼吸（nil-safe）
        if starLayers_.corona and starLayers_.coronaMat then
            local coronaAlpha = starLayers_.coronaBaseAlpha + math.sin(elapsedTime * 0.3) * 0.012
            starLayers_.coronaMat:SetShaderParameter("MatDiffColor", Variant(Vector4(
                color[1], color[2] * 0.18, color[3] * 0.08, coronaAlpha
            )))
        end

        -- 耀斑透明度微变（nil-safe）
        if starLayers_.flareBbs and starLayers_.flareMat then
            local flareAlpha = starLayers_.flareBaseAlpha + math.sin(elapsedTime * 0.45) * 0.01
            starLayers_.flareMat:SetShaderParameter("MatDiffColor", Variant(Vector4(
                color[1] * 1.2, color[2] * 0.75, color[3] * 0.55, flareAlpha
            )))
        end
    elseif starNode_ then
        -- 降级：简单脉动（无贴图时）
        local pulse = 1.0 + math.sin(elapsedTime * 1.5) * 0.02
        local baseSize = systemData_.starSize * 0.75
        starNode_:SetScale(Vector3(baseSize * pulse, baseSize * pulse, baseSize * pulse))
    end

    -- 小行星自转
    for _, node in ipairs(asteroidNodes_) do
        if node.rotSpeed then
            local currentRot = node:GetRotation()
            node:SetRotation(currentRot * Quaternion(node.rotSpeed * dt, Vector3.UP))
        end
    end
end

--- 清理当前星系内容
function StarSystem.Clear()
    if rootNode_ then
        rootNode_:RemoveAllChildren()
    end
    planetNodes_ = {}
    asteroidNodes_ = {}
    starNode_ = nil
    starLayers_ = nil
    secondStarNode_ = nil
    systemData_ = nil
    print("[StarSystem] Cleared")
end

--- 获取当前星系数据
---@return table|nil
function StarSystem.GetCurrentData()
    return systemData_
end

return StarSystem
