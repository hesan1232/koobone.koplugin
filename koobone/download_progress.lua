local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Screen = Device.screen

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local DownloadProgress = InputContainer:extend{
    title = _("下载中"),
    on_cancel = nil,
    on_background = nil,
}

local function clamp(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function format_size(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then return tostring(bytes) .. "B" end
    if bytes < 1024 * 1024 then return string.format("%.1fKB", bytes / 1024) end
    if bytes < 1024 * 1024 * 1024 then return string.format("%.1fMB", bytes / (1024 * 1024)) end
    return string.format("%.2fGB", bytes / (1024 * 1024 * 1024))
end

function DownloadProgress:init()
    self.dimen = Screen:getSize()
    self.cancelled = false

    local frame_width = math.floor(Screen:getWidth() * 0.82)
    local frame_height = math.floor(Screen:getHeight() * 0.60)
    local content_width = frame_width - Size.padding.large * 2
    local content_height = frame_height - Size.padding.large * 2
    local group = VerticalGroup:new{align="center"}

    self.title_widget = TextBoxWidget:new{
        text = self.title or _("下载中"),
        face = Font:getFace("ffont", 22),
        bold = true,
        width = content_width,
        height = math.floor(content_height * 0.12),
        height_adjust = false,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }
    group[#group + 1] = self.title_widget
    group[#group + 1] = VerticalSpan:new{width = Size.padding.medium}

    self.progress = ProgressWidget:new{
        width = content_width,
        height = Screen:scaleBySize(20),
        percentage = 0,
        fillcolor = Blitbuffer.COLOR_BLACK,
        padding = Size.padding.small,
        margin = Size.margin.tiny,
    }
    group[#group + 1] = self.progress
    group[#group + 1] = VerticalSpan:new{width = Size.padding.small}

    self.percent_widget = TextBoxWidget:new{
        text = "0%",
        face = Font:getFace("cfont", 19),
        width = content_width,
        height = math.floor(content_height * 0.07),
        height_adjust = false,
        alignment = "center",
    }
    group[#group + 1] = self.percent_widget
    group[#group + 1] = VerticalSpan:new{width = Size.padding.medium}

    self.status_widget = TextBoxWidget:new{
        text = _("准备下载……"),
        face = Font:getFace("cfont", 18),
        width = content_width,
        height = math.floor(content_height * 0.40),
        height_adjust = false,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }
    group[#group + 1] = self.status_widget
    group[#group + 1] = VerticalSpan:new{width = Size.padding.medium}

    self.buttons = ButtonTable:new{
        width = content_width,
        show_parent = self,
        zero_sep = true,
        buttons = {
            {
                {
                    text = _("后台运行"),
                    callback = function()
                        if self.on_background then
                            self.on_background()
                        end
                    end,
                },
                {
                    text = _("取消下载"),
                    callback = function()
                        if self.cancelled then return end
                        self.cancelled = true
                        self.status_widget:setText(_("正在取消……"))
                        self:_redraw()
                        if self.on_cancel then self.on_cancel() end
                    end,
                },
            },
        },
    }
    group[#group + 1] = self.buttons

    local fixed_area = CenterContainer:new{
        dimen = Geom:new{x=0, y=0, w=content_width, h=content_height},
        group,
    }
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.large,
        fixed_area,
    }
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.frame,
    }
end

function DownloadProgress:_redraw()
    local target = (self.frame and self.frame.dimen) or self.dimen
    UIManager:setDirty(self, function()
        return "fast", target
    end)
end

function DownloadProgress:setState(state)
    state = state or {}
    local current = tonumber(state.current) or 0
    local total = tonumber(state.total) or 0
    local percent = state.percent
    local download_bytes = tonumber(state.download_bytes) or 0
    local expected_size = tonumber(state.expected_size) or 0

    -- 优先级1: 如果同时有字节数和总大小，直接用它们计算（最准确）
    if download_bytes > 0 and expected_size > 0 then
        percent = download_bytes / expected_size
    -- 优先级2: 如果有 percent 字段，判断是百分比还是小数
    elseif percent ~= nil then
        percent = tonumber(percent) or 0
        if percent > 1 then
            -- 大于1视为百分比整数（如 85 表示 85%）
            percent = percent / 100
        end
        -- 否则视为 0~1 的小数
    -- 优先级3: 用 current/total 计算
    elseif total > 0 then
        percent = current / total
    else
        percent = 0
    end
    percent = clamp(percent, 0, 1)

    local labels = {
        prepare = _("准备下载"),
        download = _("下载中"),
        downloading = _("下载中"),
        extracting = _("解压中"),
        parsing = _("解析中"),
        done = _("下载完成"),
        error = _("下载失败"),
        cancelled = _("下载已取消"),
    }
    local rows = {}
    local label = labels[state.stage] or tostring(state.stage or _("处理中"))
    rows[#rows + 1] = label
    if state.vol_name and state.vol_name ~= "" then
        rows[#rows + 1] = state.vol_name
    end
    if expected_size > 0 then
        rows[#rows + 1] = string.format(_("%s / %s"), format_size(download_bytes), format_size(expected_size))
    elseif download_bytes > 0 then
        rows[#rows + 1] = format_size(download_bytes)
    end
    if state.message and state.message ~= "" then
        rows[#rows + 1] = state.message
    end
    local percent_text = tostring(math.floor(percent * 100 + 0.5)) .. "%"
    local status_text = table.concat(rows, "\n")
    local signature = percent_text .. "\n" .. status_text
    if signature == self._last_signature then return end
    self._last_signature = signature
    self.progress:setPercentage(percent)
    self.percent_widget:setText(percent_text)
    self.status_widget:setText(status_text)
    self:_redraw()
end

function DownloadProgress:isCanceled()
    return self.cancelled
end

function DownloadProgress:show()
    if self._visible then return end
    self._visible = true
    UIManager:show(self, "ui")
end

function DownloadProgress:close()
    if not self._visible then return end
    self._visible = false
    self._closed = true
    -- 使用调度器延迟关闭，确保UI更新完成
    if UIManager then
        UIManager:scheduleIn(0.1, function()
            pcall(function()
                UIManager:close(self, "ui")
            end)
        end)
    end
end

function DownloadProgress:onCloseWidget()
    if InputContainer.onCloseWidget then
        InputContainer.onCloseWidget(self)
    end
end

return DownloadProgress
