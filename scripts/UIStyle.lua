-- ============================================================================
-- UIStyle.lua - 银河猎人 UI 设计规范常量
-- 军事科幻终端风格 (Military Sci-Fi Terminal)
-- ============================================================================

local UIStyle = {}

-- ============================================================================
-- 颜色系统 (RGBA 0-255)
-- ============================================================================

-- 背景色 (深空蓝黑)
UIStyle.BG_DEEP       = { 7, 17, 28, 240 }      -- #07111C 最深底色
UIStyle.BG_MID        = { 11, 23, 36, 230 }     -- #0B1724 面板底
UIStyle.BG_LIGHT      = { 16, 29, 41, 220 }     -- #101D29 次级面板
UIStyle.BG_HOVER      = { 22, 38, 55, 220 }     -- 悬停态
UIStyle.BG_OVERLAY    = { 5, 10, 18, 235 }      -- 全屏遮罩

-- 主色 (青绿高亮)
UIStyle.PRIMARY       = { 101, 198, 173, 255 }  -- #65C6AD 主色/船体
UIStyle.PRIMARY_DIM   = { 101, 198, 173, 140 }  -- 主色暗态
UIStyle.PRIMARY_GLOW  = { 101, 198, 173, 80 }   -- 主色光晕

-- 强调色 (橙色)
UIStyle.ACCENT        = { 217, 138, 74, 255 }   -- #D98A4A 燃料/升级
UIStyle.ACCENT_DIM    = { 217, 138, 74, 140 }   -- 橙色暗态

-- 功能色
UIStyle.SHIELD        = { 74, 168, 255, 255 }   -- #4AA8FF 护盾蓝
UIStyle.SHIELD_DIM    = { 74, 168, 255, 140 }
UIStyle.WARNING       = { 209, 90, 74, 255 }    -- #D15A4A 警告红
UIStyle.WARNING_DIM   = { 209, 90, 74, 140 }
UIStyle.ENERGY        = { 74, 168, 255, 255 }   -- 能量蓝
UIStyle.SUCCESS       = { 80, 200, 120, 255 }   -- 成功绿

-- 文本色
UIStyle.TEXT_MAIN     = { 234, 242, 241, 255 }  -- #EAF2F1 主文本
UIStyle.TEXT_SEC      = { 154, 170, 180, 255 }  -- #9AAAB4 次级文本
UIStyle.TEXT_WEAK     = { 101, 119, 131, 200 }  -- #657783 弱文本
UIStyle.TEXT_DISABLED = { 61, 75, 85, 160 }     -- #3D4B55 禁用

-- 边框色
UIStyle.BORDER        = { 40, 70, 100, 120 }    -- 普通边框
UIStyle.BORDER_BRIGHT = { 101, 198, 173, 100 }  -- 高亮边框
UIStyle.BORDER_DIM    = { 30, 50, 70, 80 }      -- 暗边框

-- ============================================================================
-- 字体大小
-- ============================================================================

UIStyle.FONT_HUGE     = 24   -- 大标题 (跃迁目标名)
UIStyle.FONT_TITLE    = 18   -- 标题 (星图)
UIStyle.FONT_HEADING  = 14   -- 小标题 (面板标题)
UIStyle.FONT_BODY     = 12   -- 正文 (状态描述)
UIStyle.FONT_LABEL    = 10   -- 标签 (HUD标签)
UIStyle.FONT_TINY     = 9    -- 微型 (数据值)

-- ============================================================================
-- 间距和尺寸
-- ============================================================================

UIStyle.PANEL_RADIUS  = 4    -- 面板圆角
UIStyle.PANEL_BORDER  = 1    -- 面板边框宽度
UIStyle.SPACING_XS    = 4
UIStyle.SPACING_SM    = 8
UIStyle.SPACING_MD    = 12
UIStyle.SPACING_LG    = 16
UIStyle.SPACING_XL    = 24

-- 状态条
UIStyle.BAR_HEIGHT    = 6    -- 细长条高度
UIStyle.BAR_RADIUS    = 3    -- 条圆角

-- 小地图
UIStyle.MINIMAP_SIZE  = 130  -- 雷达尺寸

-- ============================================================================
-- 辅助函数
-- ============================================================================

--- 创建 NanoVG RGBA 颜色 (从样式数组)
---@param vg userdata NanoVG context
---@param color table {r, g, b, a}
---@return userdata NVGcolor
function UIStyle.Color(vg, color)
    return nvgRGBA(color[1], color[2], color[3], color[4])
end

--- 绘制标准面板背景 (深蓝半透明 + 细边框)
---@param vg userdata
---@param x number
---@param y number
---@param w number
---@param h number
---@param opts table|nil {border=color, bg=color, radius=number}
function UIStyle.DrawPanel(vg, x, y, w, h, opts)
    opts = opts or {}
    local bg = opts.bg or UIStyle.BG_MID
    local border = opts.border or UIStyle.BORDER
    local radius = opts.radius or UIStyle.PANEL_RADIUS

    nvgBeginPath(vg)
    nvgRoundedRect(vg, x, y, w, h, radius)
    nvgFillColor(vg, nvgRGBA(bg[1], bg[2], bg[3], bg[4]))
    nvgFill(vg)

    nvgStrokeColor(vg, nvgRGBA(border[1], border[2], border[3], border[4]))
    nvgStrokeWidth(vg, UIStyle.PANEL_BORDER)
    nvgStroke(vg)
end

--- 绘制水平分隔线
---@param vg userdata
---@param x number
---@param y number
---@param w number
function UIStyle.DrawSeparator(vg, x, y, w)
    nvgBeginPath(vg)
    nvgMoveTo(vg, x, y)
    nvgLineTo(vg, x + w, y)
    nvgStrokeColor(vg, nvgRGBA(UIStyle.BORDER[1], UIStyle.BORDER[2], UIStyle.BORDER[3], 60))
    nvgStrokeWidth(vg, 0.5)
    nvgStroke(vg)
end

--- 绘制进度条 (细长形)
---@param vg userdata
---@param x number
---@param y number
---@param w number
---@param ratio number 0.0-1.0
---@param color table {r,g,b,a} 前景色
---@param bgColor table|nil 背景色
function UIStyle.DrawBar(vg, x, y, w, ratio, color, bgColor)
    local h = UIStyle.BAR_HEIGHT
    local r = UIStyle.BAR_RADIUS
    bgColor = bgColor or { 15, 20, 30, 200 }

    -- 背景
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x, y, w, h, r)
    nvgFillColor(vg, nvgRGBA(bgColor[1], bgColor[2], bgColor[3], bgColor[4]))
    nvgFill(vg)

    -- 前景
    if ratio > 0 then
        local fillW = math.max(h, w * ratio) -- 最小宽度等于高度(确保圆角正常)
        nvgBeginPath(vg)
        nvgRoundedRect(vg, x, y, fillW, h, r)
        nvgFillColor(vg, nvgRGBA(color[1], color[2], color[3], color[4]))
        nvgFill(vg)
    end
end

--- 绘制带光晕的圆点 (星系节点)
---@param vg userdata
---@param cx number
---@param cy number
---@param radius number
---@param color table {r,g,b,a}
---@param glowScale number|nil 光晕倍数(默认2.5)
function UIStyle.DrawGlowDot(vg, cx, cy, radius, color, glowScale)
    glowScale = glowScale or 2.5
    -- 光晕
    nvgBeginPath(vg)
    nvgCircle(vg, cx, cy, radius * glowScale)
    local glow = nvgRadialGradient(vg, cx, cy, 0, radius * glowScale,
        nvgRGBAf(color[1]/255, color[2]/255, color[3]/255, 0.3),
        nvgRGBAf(color[1]/255, color[2]/255, color[3]/255, 0))
    nvgFillPaint(vg, glow)
    nvgFill(vg)
    -- 本体
    nvgBeginPath(vg)
    nvgCircle(vg, cx, cy, radius)
    nvgFillColor(vg, nvgRGBA(color[1], color[2], color[3], color[4]))
    nvgFill(vg)
end

return UIStyle
