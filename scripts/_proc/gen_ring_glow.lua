-- 生成环形发光贴图：中心黑色，在特定半径处有柔和高斯发光环
function Start()
    local ok, err = pcall(function()
        local W, H = 256, 256
        local img = Image()
        img:SetSize(W, H, 4)

        -- 环参数（归一化到 0~1，中心为 0.5,0.5）
        local ringRadius = 0.85   -- 环中心半径（归一化，相对于图片半宽）
        local ringWidth  = 0.07   -- 高斯衰减 sigma

        -- 暖橙色 RGB (归一化)
        local R, G, B = 1.0, 0.71, 0.31

        for y = 0, H - 1 do
            for x = 0, W - 1 do
                -- 归一化坐标，中心为 (0,0)
                local nx = (x + 0.5) / W * 2.0 - 1.0  -- -1 to 1
                local ny = (y + 0.5) / H * 2.0 - 1.0  -- -1 to 1
                local dist = math.sqrt(nx * nx + ny * ny)  -- 0 to ~1.414

                -- 高斯环：在 ringRadius 处最亮，向内外衰减
                local diff = (dist - ringRadius) / ringWidth
                local intensity = math.exp(-0.5 * diff * diff)

                -- 外边界硬裁剪（超出1.0的完全黑）
                if dist > 1.0 then
                    intensity = 0
                end

                -- 内部额外衰减：让中心更黑（避免近中心微弱残留）
                if dist < ringRadius - ringWidth * 3 then
                    local innerFade = (dist - (ringRadius - ringWidth * 3)) / (ringWidth * 2)
                    if innerFade < 0 then
                        intensity = intensity * math.max(0, 1.0 + innerFade * 0.5)
                    end
                end

                img:SetPixel(x, y, Color(
                    R * intensity,
                    G * intensity,
                    B * intensity,
                    1.0  -- 不透明黑底，用加法混合
                ))
            end
        end

        local outPath = "/workspace/assets/image/恒星贴图/star_ring_glow.png"
        assert(img:SavePNG(outPath), "SavePNG failed")
        print("[procedural] wrote " .. outPath .. " (" .. W .. "x" .. H .. ")")
    end)
    if not ok then
        log:Write(LOG_ERROR, "[gen_ring_glow] " .. tostring(err))
    end
    engine:Exit()
end
