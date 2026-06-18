------------------------------------------------------------
-- 生成恒星边缘辉光贴图（纯白亮度图，颜色由材质染色）
-- Fresnel rim 效果：中心黑色，边缘亮白色柔和衰减
-- 用于加法混合 DiffAddAlpha.xml，材质 MatDiffColor 控制最终颜色
------------------------------------------------------------
function Start()
    local ok, err = pcall(function()
        local img = Image()
        local W, H = 512, 512
        img:SetSize(W, H, 4)

        local cx, cy = W / 2, H / 2
        local maxR = W / 2

        -- Fresnel rim 参数（紧贴星体版）：
        -- 中心黑(r<0.70)，从0.70开始渐入，0.85~0.96满亮度，边缘快速衰减
        -- 配合 size=1.12 时：星体边缘在r=0.893，辉光恰好从边缘处可见
        local innerStart = 0.70   -- 光晕开始出现
        local peakInner  = 0.85   -- 峰值内缘
        local peakOuter  = 0.96   -- 峰值外缘
        local outerEnd   = 1.0    -- 光晕完全消失

        for y = 0, H - 1 do
            for x = 0, W - 1 do
                local dx = (x - cx) / maxR
                local dy = (y - cy) / maxR
                local r = math.sqrt(dx * dx + dy * dy)

                local intensity = 0.0

                if r < innerStart then
                    intensity = 0.0
                elseif r < peakInner then
                    -- 内侧平滑渐入
                    local t = (r - innerStart) / (peakInner - innerStart)
                    intensity = t * t * (3.0 - 2.0 * t)
                elseif r <= peakOuter then
                    -- 峰值区域满强度
                    intensity = 1.0
                elseif r < outerEnd then
                    -- 外侧高斯衰减
                    local t = (r - peakOuter) / (outerEnd - peakOuter)
                    intensity = math.exp(-3.0 * t * t)
                else
                    intensity = 0.0
                end

                -- 纯白亮度图（RGB 相同，颜色由材质控制）
                img:SetPixel(x, y, Color(intensity, intensity, intensity, 1.0))
            end
        end

        local outPath = "/workspace/assets/image/恒星贴图/star_edge_glow_fresnel.png"
        assert(img:SavePNG(outPath), "SavePNG failed")
        print("[procedural] wrote " .. outPath .. " (" .. W .. "x" .. H .. ")")
    end)
    if not ok then log:Write(LOG_ERROR, "[procedural] " .. tostring(err)) end
    engine:Exit()
end
