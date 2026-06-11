-- ============================================================================
-- ShipFactory.lua
-- 程序化3D飞船组装: 使用内置基础体(Box/Cylinder/Cone/Sphere)构建飞船
-- ============================================================================

local ShipFactory = {}

-- 引擎火焰节点缓存(按飞船节点)
local flameNodeCache = {}

-- ============================================================================
-- PBR 材质工具
-- ============================================================================

local function CreatePBRMaterial(color, metallic, roughness, emissiveColor)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("MatSpecColor", Variant(Color(0.5, 0.5, 0.5, 1.0)))
    mat:SetShaderParameter("Metallic", Variant(metallic))
    mat:SetShaderParameter("Roughness", Variant(roughness))
    if emissiveColor then
        mat:SetShaderParameter("MatEmissiveColor", Variant(emissiveColor))
    end
    return mat
end

local function CreateAlphaMaterial(color, metallic, roughness, emissiveColor)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("MatSpecColor", Variant(Color(0.3, 0.3, 0.3, 1.0)))
    mat:SetShaderParameter("Metallic", Variant(metallic))
    mat:SetShaderParameter("Roughness", Variant(roughness))
    if emissiveColor then
        mat:SetShaderParameter("MatEmissiveColor", Variant(emissiveColor))
    end
    return mat
end

-- ============================================================================
-- 通用部件添加
-- ============================================================================

local function AddPart(parentNode, name, model, position, scale, material, castShadows)
    local node = parentNode:CreateChild(name)
    node.position = position
    node.scale = scale
    local sm = node:CreateComponent("StaticModel")
    sm:SetModel(cache:GetResource("Model", model))
    sm:SetMaterial(material)
    sm.castShadows = castShadows ~= false
    return node
end

local function AddPartWithRotation(parentNode, name, model, position, rotation, scale, material)
    local node = parentNode:CreateChild(name)
    node.position = position
    node.rotation = rotation
    node.scale = scale
    local sm = node:CreateComponent("StaticModel")
    sm:SetModel(cache:GetResource("Model", model))
    sm:SetMaterial(material)
    sm.castShadows = true
    return node
end

-- ============================================================================
-- 玩家主舰构建
-- ============================================================================
-- 整体尺寸约: 长4米 x 宽3米 x 高1米
-- 造型: 流线型战斗机, 三角翼, 双引擎

function ShipFactory.BuildPlayerShip(rootNode)
    flameNodeCache[rootNode] = {}
    
    -- 材质定义
    local hullMat = CreatePBRMaterial(
        Color(0.45, 0.5, 0.6, 1.0),  -- 蓝灰金属
        0.92, 0.15                      -- 高金属/低粗糙 = 光滑金属
    )
    local darkMat = CreatePBRMaterial(
        Color(0.15, 0.18, 0.22, 1.0), -- 暗色面板
        0.85, 0.3
    )
    local accentMat = CreatePBRMaterial(
        Color(0.1, 0.4, 0.9, 1.0),   -- 蓝色装饰
        0.7, 0.2,
        Color(0.05, 0.2, 0.5)          -- 微弱自发光
    )
    local cockpitMat = CreatePBRMaterial(
        Color(0.2, 0.6, 0.9, 1.0),   -- 驾驶舱玻璃蓝
        0.1, 0.05,
        Color(0.1, 0.3, 0.5)           -- 自发光
    )
    local engineMat = CreatePBRMaterial(
        Color(0.2, 0.2, 0.25, 1.0),
        0.9, 0.4
    )
    local flameMat = CreateAlphaMaterial(
        Color(0.3, 0.6, 1.0, 0.8),   -- 蓝色引擎光
        0.0, 0.1,
        Color(0.5, 0.8, 1.5)           -- 强发光
    )
    
    -- ===== 主体 (扁平长方形, 前窄后宽) =====
    -- 中央机身
    AddPart(rootNode, "Hull_Main", "Models/Box.mdl",
        Vector3(0, 0, 0.3),
        Vector3(1.0, 0.35, 2.5),
        hullMat
    )
    
    -- 前部尖头(用锥体旋转)
    AddPartWithRotation(rootNode, "Hull_Nose", "Models/Cone.mdl",
        Vector3(0, 0, 2.0),
        Quaternion(90, Vector3.RIGHT),  -- 锥体朝前
        Vector3(0.5, 1.0, 0.35),
        hullMat
    )
    
    -- ===== 机翼 (左右对称的扁平Box) =====
    -- 左翼
    AddPartWithRotation(rootNode, "Wing_Left", "Models/Box.mdl",
        Vector3(-1.2, -0.05, -0.2),
        Quaternion(0, 0, -5),  -- 微微下倾
        Vector3(1.4, 0.1, 1.2),
        hullMat
    )
    -- 右翼
    AddPartWithRotation(rootNode, "Wing_Right", "Models/Box.mdl",
        Vector3(1.2, -0.05, -0.2),
        Quaternion(0, 0, 5),
        Vector3(1.4, 0.1, 1.2),
        hullMat
    )
    
    -- 翼尖装饰
    AddPart(rootNode, "WingTip_Left", "Models/Box.mdl",
        Vector3(-1.85, -0.05, -0.3),
        Vector3(0.15, 0.15, 0.6),
        accentMat
    )
    AddPart(rootNode, "WingTip_Right", "Models/Box.mdl",
        Vector3(1.85, -0.05, -0.3),
        Vector3(0.15, 0.15, 0.6),
        accentMat
    )
    
    -- ===== 驾驶舱 (球体, 位于前部上方) =====
    AddPart(rootNode, "Cockpit", "Models/Sphere.mdl",
        Vector3(0, 0.2, 1.0),
        Vector3(0.5, 0.3, 0.7),
        cockpitMat
    )
    
    -- ===== 后部引擎舱 =====
    -- 左引擎
    AddPartWithRotation(rootNode, "Engine_Left", "Models/Cylinder.mdl",
        Vector3(-0.5, 0, -1.2),
        Quaternion(90, Vector3.RIGHT),
        Vector3(0.3, 0.5, 0.3),
        engineMat
    )
    -- 右引擎
    AddPartWithRotation(rootNode, "Engine_Right", "Models/Cylinder.mdl",
        Vector3(0.5, 0, -1.2),
        Quaternion(90, Vector3.RIGHT),
        Vector3(0.3, 0.5, 0.3),
        engineMat
    )
    
    -- ===== 引擎火焰 (Cone, 方向朝后) =====
    local flameLeft = AddPartWithRotation(rootNode, "Flame_Left", "Models/Cone.mdl",
        Vector3(-0.5, 0, -1.6),
        Quaternion(-90, Vector3.RIGHT),  -- 锥体尖端朝后
        Vector3(0.25, 0.6, 0.25),
        flameMat
    )
    flameLeft:GetComponent("StaticModel").castShadows = false
    
    local flameRight = AddPartWithRotation(rootNode, "Flame_Right", "Models/Cone.mdl",
        Vector3(0.5, 0, -1.6),
        Quaternion(-90, Vector3.RIGHT),
        Vector3(0.25, 0.6, 0.25),
        flameMat
    )
    flameRight:GetComponent("StaticModel").castShadows = false
    
    flameNodeCache[rootNode] = { flameLeft, flameRight }
    
    -- ===== 顶部背鳍 =====
    AddPartWithRotation(rootNode, "Fin_Top", "Models/Box.mdl",
        Vector3(0, 0.3, -0.5),
        Quaternion(0, 0, 0),
        Vector3(0.06, 0.35, 0.8),
        darkMat
    )
    
    -- ===== 底部腹鳍 (小) =====
    AddPart(rootNode, "Fin_Bottom", "Models/Box.mdl",
        Vector3(0, -0.2, -0.6),
        Vector3(0.04, 0.2, 0.5),
        darkMat
    )
    
    print("  [ShipFactory] 玩家主舰创建完毕 (14个部件)")
end

-- ============================================================================
-- 获取火焰节点
-- ============================================================================

function ShipFactory.GetFlameNodes(rootNode)
    return flameNodeCache[rootNode] or {}
end

-- ============================================================================
-- NPC 舰船构建 (敌方侦察舰)
-- ============================================================================

function ShipFactory.BuildEnemyScout(rootNode)
    local hullMat = CreatePBRMaterial(
        Color(0.6, 0.2, 0.15, 1.0),  -- 暗红色
        0.85, 0.25
    )
    local wingMat = CreatePBRMaterial(
        Color(0.35, 0.12, 0.1, 1.0),
        0.8, 0.3
    )
    local glowMat = CreatePBRMaterial(
        Color(0.9, 0.3, 0.1, 1.0),
        0.0, 0.1,
        Color(0.8, 0.2, 0.0)
    )
    
    -- 小型菱形体
    AddPart(rootNode, "Hull", "Models/Box.mdl",
        Vector3(0, 0, 0),
        Vector3(0.6, 0.25, 1.5),
        hullMat
    )
    
    -- 前锥
    AddPartWithRotation(rootNode, "Nose", "Models/Cone.mdl",
        Vector3(0, 0, 1.0),
        Quaternion(90, Vector3.RIGHT),
        Vector3(0.3, 0.5, 0.25),
        hullMat
    )
    
    -- V型翼
    AddPartWithRotation(rootNode, "Wing_L", "Models/Box.mdl",
        Vector3(-0.7, 0.1, -0.3),
        Quaternion(0, -15, -20),
        Vector3(0.8, 0.06, 0.6),
        wingMat
    )
    AddPartWithRotation(rootNode, "Wing_R", "Models/Box.mdl",
        Vector3(0.7, 0.1, -0.3),
        Quaternion(0, 15, 20),
        Vector3(0.8, 0.06, 0.6),
        wingMat
    )
    
    -- 引擎光点
    AddPart(rootNode, "EngineGlow", "Models/Sphere.mdl",
        Vector3(0, 0, -0.9),
        Vector3(0.2, 0.2, 0.3),
        glowMat
    )
end

-- ============================================================================
-- 友方护卫舰
-- ============================================================================

function ShipFactory.BuildAllyFrigate(rootNode)
    local hullMat = CreatePBRMaterial(
        Color(0.5, 0.55, 0.6, 1.0),  -- 浅灰蓝
        0.9, 0.2
    )
    local accentMat = CreatePBRMaterial(
        Color(0.2, 0.7, 0.4, 1.0),   -- 绿色标记
        0.5, 0.3,
        Color(0.05, 0.15, 0.05)
    )
    
    -- 较大的长条形体
    AddPart(rootNode, "Hull", "Models/Box.mdl",
        Vector3(0, 0, 0),
        Vector3(1.2, 0.5, 3.0),
        hullMat
    )
    
    -- 桥楼
    AddPart(rootNode, "Bridge", "Models/Box.mdl",
        Vector3(0, 0.4, 0.5),
        Vector3(0.6, 0.3, 0.8),
        hullMat
    )
    
    -- 侧翼炮台
    AddPart(rootNode, "Turret_L", "Models/Cylinder.mdl",
        Vector3(-0.7, 0.3, -0.5),
        Vector3(0.2, 0.3, 0.2),
        accentMat
    )
    AddPart(rootNode, "Turret_R", "Models/Cylinder.mdl",
        Vector3(0.7, 0.3, -0.5),
        Vector3(0.2, 0.3, 0.2),
        accentMat
    )
end

return ShipFactory
