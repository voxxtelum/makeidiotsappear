-- UI_Settings.lua
-- Addon settings window: a vertical tab list (left) switching between
-- setting sections (right). Built with AceGUI-3.0.

local ADDON_NAME, ns = ...
local AceGUI = LibStub("AceGUI-3.0")
local PREFIX = ns.PREFIX

local settingsFrame = nil

-- AceGUI's MultiLineEditBox clamps SetNumLines to a minimum of 4 and, unless
-- DisableButton(true) is called, reserves extra height for a built-in
-- "Accept" button that would just duplicate this window's own Save button.
-- Neither is exposed as a smaller option, so the height is set directly
-- afterward (overriding the library's clamped Layout()) using the same
-- numlines*14 + chrome + label formula it uses internally, with numlines=2
-- and no button, to get a compact two-line box instead of its four-line
-- default.
local MESSAGE_BOX_HEIGHT = 2 * 14 + 19 + 14

local function CreateMessageBox(label, text)
  local box = AceGUI:Create("MultiLineEditBox")
  box:SetLabel(label)
  box:SetText(text)
  box:SetFullWidth(true)
  box:DisableButton(true)
  box:SetHeight(MESSAGE_BOX_HEIGHT)
  return box
end

-- Vertical gap between the loosely-related sections of the settings form
-- (e.g. invite timing vs. messages vs. durability). Both section spacers
-- below share this one value.
local SECTION_SPACER_HEIGHT = 30

-- Both side-by-side panels (tab list, tab content) share this height rather
-- than auto-sizing - see UI_Main.lua's BuildMainFrame for why (InlineGroup's
-- own auto-height fights a fixed side-by-side layout and produces stale
-- heights).
local PANEL_HEIGHT = 540

-- Standard item quality colors/order (index matches the quality value
-- MakeIdiotsAppear.lua's MaybeSetLootThreshold passes straight to
-- SetLootThreshold), used to color the loot threshold dropdown below.
local QUALITY_ORDER = { 0, 1, 2, 3, 4 }
local QUALITY_NAMES = {
  [0] = "Poor",
  [1] = "Common",
  [2] = "Uncommon",
  [3] = "Rare",
  [4] = "Epic",
}
local QUALITY_COLORS = {
  [0] = { 0.61, 0.61, 0.61 },
  [1] = { 1.00, 1.00, 1.00 },
  [2] = { 0.12, 1.00, 0.00 },
  [3] = { 0.00, 0.44, 0.87 },
  [4] = { 0.64, 0.21, 0.93 },
}

local function BuildLootThresholdDropdownList()
  local list = {}
  for _, quality in ipairs(QUALITY_ORDER) do
    local r, g, b = unpack(QUALITY_COLORS[quality])
    list[quality] = string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, QUALITY_NAMES[quality])
  end
  return list
end

-- Shared with UI_Main.lua (loaded after this file - see MakeIdiotsAppear.xml)
-- so its manual "Set Loot Threshold" button/dropdown uses the exact same
-- quality order/colors as this tab instead of a second copy going stale.
ns.LootQualityOrder = QUALITY_ORDER
ns.BuildLootThresholdDropdownList = BuildLootThresholdDropdownList

----------------------------------------------------------------------
-- "Invites" tab
----------------------------------------------------------------------

-- Every field below writes straight to `settings` as soon as it changes -
-- there's no Save button, so each widget's own change event (immediate for
-- sliders/checkboxes, Enter/losing focus for text fields, since AceGUI has
-- no per-keystroke "committed" signal for those) is the only place a value
-- ever gets persisted.
local function BuildInvitesTab(container, settings)
  local intervalSlider = AceGUI:Create("Slider")
  intervalSlider:SetLabel("Invite interval (seconds)")
  intervalSlider:SetSliderValues(15, 600, 5)
  intervalSlider:SetValue(settings.interval)
  intervalSlider:SetFullWidth(true)
  intervalSlider:SetCallback("OnValueChanged", function(widget, event, value)
    settings.interval = math.floor(value + 0.5)
  end)
  container:AddChild(intervalSlider)

  local intervalSpacer = AceGUI:Create("SimpleGroup")
  intervalSpacer:SetFullWidth(true)
  intervalSpacer.noAutoHeight = true
  intervalSpacer:SetHeight(SECTION_SPACER_HEIGHT)
  container:AddChild(intervalSpacer)

  -- Side-by-side row for the prefix/delay boxes. container:AddChild triggers
  -- an immediate DoLayout (see AceGUI's WidgetContainerBase.AddChild), and on
  -- this window's very first open that ran before WoW had resolved real
  -- frame widths - an AceGUI "Flow" sub-row sized its children off stale/zero
  -- widths and the second box silently ended up 0px wide (confirmed by
  -- testing: reopening the already-built window, which re-lays-out well
  -- after that first tick, always showed it fine). Rather than deferring
  -- until "later" (which would make a widget pop in after the window is
  -- already visible - not wanted), this row sidesteps AceGUI's automatic
  -- width/position bookkeeping entirely: prefixDelayRow is a fixed-width
  -- SimpleGroup (not "fill"/"relative"), so per AceGUI's List layout it's
  -- never handed a live DoLayout call of its own, and prefixBox/delayBox are
  -- reparented onto it and given one fixed SetPoint each by hand instead of
  -- going through AddChild - so nothing here depends on any container's
  -- width being resolved yet, and nothing repositions them later either.
  -- They're still pushed onto prefixDelayRow.children by hand purely so
  -- ReleaseChildren (used when a tab is torn down/rebuilt) releases them
  -- back to AceGUI's widget pool like any other child would be.
  local prefixDelayRow = AceGUI:Create("SimpleGroup")
  prefixDelayRow:SetWidth(310)
  prefixDelayRow.noAutoHeight = true
  prefixDelayRow:SetHeight(44) -- matches EditBox's own labeled height (see AceGUIWidget-EditBox.lua's SetLabel)
  container:AddChild(prefixDelayRow)

  local prefixBox = AceGUI:Create("EditBox")
  prefixBox:SetLabel("Message Prefix")
  prefixBox:SetText(settings.messagePrefix)
  prefixBox:SetWidth(140)
  prefixBox:SetCallback("OnEnterPressed", function(widget, event, value)
    settings.messagePrefix = value
  end)
  prefixBox:SetParent(prefixDelayRow)
  prefixBox.frame:ClearAllPoints()
  prefixBox.frame:SetPoint("TOPLEFT", prefixDelayRow.content, "TOPLEFT", 0, 0)
  prefixBox.frame:Show()
  table.insert(prefixDelayRow.children, prefixBox)

  local delayBox = AceGUI:Create("EditBox")
  delayBox:SetLabel("Invites Delay (seconds)")
  delayBox:SetText(tostring(settings.delayAfterMessage))
  delayBox:SetWidth(140)
  delayBox:SetCallback("OnEnterPressed", function(widget, event, value)
    settings.delayAfterMessage = tonumber(value) or settings.delayAfterMessage
  end)
  delayBox:SetParent(prefixDelayRow)
  delayBox.frame:ClearAllPoints()
  delayBox.frame:SetPoint("TOPLEFT", prefixBox.frame, "TOPRIGHT", 20, 0)
  delayBox.frame:Show()
  table.insert(prefixDelayRow.children, delayBox)

  local whisperMsgBox = CreateMessageBox("Whisper message (sent to players already grouped)", settings.whisperMessage)
  whisperMsgBox:SetCallback("OnEditFocusLost", function(widget)
    settings.whisperMessage = widget:GetText()
  end)
  container:AddChild(whisperMsgBox)

  local whisperSpacer = AceGUI:Create("SimpleGroup")
  whisperSpacer:SetFullWidth(true)
  whisperSpacer.noAutoHeight = true
  whisperSpacer:SetHeight(SECTION_SPACER_HEIGHT)
  container:AddChild(whisperSpacer)

  local guildMsgBox = CreateMessageBox("Message to send at the start of the invite phase", settings.guildMessage)
  guildMsgBox:SetDisabled(not settings.sendGuildMessage)
  guildMsgBox:SetCallback("OnEditFocusLost", function(widget)
    settings.guildMessage = widget:GetText()
  end)

  local sendMsgCheck = AceGUI:Create("CheckBox")
  sendMsgCheck:SetLabel("Send a message at the start of the invite phase")
  sendMsgCheck:SetValue(settings.sendGuildMessage)
  sendMsgCheck:SetFullWidth(true)
  sendMsgCheck:SetCallback("OnValueChanged", function(widget, event, value)
    settings.sendGuildMessage = value and true or false
    guildMsgBox:SetDisabled(not value)
  end)
  container:AddChild(sendMsgCheck)
  container:AddChild(guildMsgBox)

  local durabilitySpacer = AceGUI:Create("SimpleGroup")
  durabilitySpacer:SetFullWidth(true)
  durabilitySpacer.noAutoHeight = true
  durabilitySpacer:SetHeight(SECTION_SPACER_HEIGHT)
  container:AddChild(durabilitySpacer)

  local durabilityMsgBox = CreateMessageBox("Durability warning message ({percent} is replaced with the value)",
    settings.durabilityMessage)
  durabilityMsgBox:SetDisabled(not settings.durabilityWarningEnabled)
  durabilityMsgBox:SetCallback("OnEditFocusLost", function(widget)
    settings.durabilityMessage = widget:GetText()
  end)

  local durabilityThresholdSlider = AceGUI:Create("Slider")
  durabilityThresholdSlider:SetLabel("Durability warning threshold (%)")
  durabilityThresholdSlider:SetSliderValues(20, 100, 5)
  durabilityThresholdSlider:SetValue(settings.durabilityThreshold)
  durabilityThresholdSlider:SetFullWidth(true)
  durabilityThresholdSlider:SetDisabled(not settings.durabilityWarningEnabled)
  durabilityThresholdSlider:SetCallback("OnValueChanged", function(widget, event, value)
    settings.durabilityThreshold = math.floor(value + 0.5)
  end)

  local durabilityCheck = AceGUI:Create("CheckBox")
  durabilityCheck:SetLabel("Whisper players whose durability is below the threshold")
  durabilityCheck:SetValue(settings.durabilityWarningEnabled)
  durabilityCheck:SetFullWidth(true)
  durabilityCheck:SetCallback("OnValueChanged", function(widget, event, value)
    settings.durabilityWarningEnabled = value and true or false
    durabilityThresholdSlider:SetDisabled(not value)
    durabilityMsgBox:SetDisabled(not value)
  end)
  container:AddChild(durabilityCheck)
  container:AddChild(durabilityThresholdSlider)
  container:AddChild(durabilityMsgBox)
end

----------------------------------------------------------------------
-- "Raid" tab
----------------------------------------------------------------------

local function BuildRaidTab(container, settings)
  local masterLootHeading = AceGUI:Create("Heading")
  masterLootHeading:SetFullWidth(true)
  masterLootHeading:SetText("Master Loot")
  container:AddChild(masterLootHeading)

  local autoMasterLootCheck = AceGUI:Create("CheckBox")
  autoMasterLootCheck:SetLabel("Automatically set loot method to Master Loot")
  autoMasterLootCheck:SetValue(settings.autoMasterLoot)
  autoMasterLootCheck:SetFullWidth(true)
  autoMasterLootCheck:SetCallback("OnValueChanged", function(widget, event, value)
    settings.autoMasterLoot = value and true or false
  end)
  container:AddChild(autoMasterLootCheck)

  local autoPromoteCheck = AceGUI:Create("CheckBox")
  autoPromoteCheck:SetLabel("Automatically promote to Master Looter")
  autoPromoteCheck:SetValue(settings.autoPromoteMasterLooter)
  autoPromoteCheck:SetFullWidth(true)
  autoPromoteCheck:SetCallback("OnValueChanged", function(widget, event, value)
    settings.autoPromoteMasterLooter = value and true or false
  end)
  container:AddChild(autoPromoteCheck)

  -- Same normalization as the Rosters UI's player list (see UI_Rosters.lua's
  -- SaveRoster) - resolve a missing realm from the master roster and fix up
  -- capitalization - just split on spaces instead of newlines, since this is
  -- a single-line box rather than the roster's paste box.
  local masterLooterBox = AceGUI:Create("EditBox")
  masterLooterBox:SetLabel("Master looter candidates (names separated by a space)")
  masterLooterBox:SetText(settings.masterLooterNames)
  masterLooterBox:SetFullWidth(true)
  masterLooterBox:SetCallback("OnEnterPressed", function(widget, event, value)
    local rawNames = {}
    for token in value:gmatch("%S+") do
      table.insert(rawNames, token)
    end
    local cleaned, needsRealm = ns.NormalizeList(rawNames)
    settings.masterLooterNames = table.concat(cleaned, " ")
    widget:SetText(settings.masterLooterNames)
    if #needsRealm > 0 then
      print(PREFIX ..
        "These master looter entries still need a realm (no match found yet): " .. table.concat(needsRealm, ", "))
    end
  end)
  container:AddChild(masterLooterBox)

  local lootThresholdSpacer = AceGUI:Create("SimpleGroup")
  lootThresholdSpacer:SetFullWidth(true)
  lootThresholdSpacer.noAutoHeight = true
  lootThresholdSpacer:SetHeight(10)
  container:AddChild(lootThresholdSpacer)

  local lootThresholdHeading = AceGUI:Create("Heading")
  lootThresholdHeading:SetFullWidth(true)
  lootThresholdHeading:SetText("Loot Threshold")
  container:AddChild(lootThresholdHeading)

  local autoLootThresholdCheck = AceGUI:Create("CheckBox")
  autoLootThresholdCheck:SetLabel("Automatically set loot threshold")
  autoLootThresholdCheck:SetValue(settings.autoLootThreshold)
  autoLootThresholdCheck:SetFullWidth(true)
  autoLootThresholdCheck:SetCallback("OnValueChanged", function(widget, event, value)
    settings.autoLootThreshold = value and true or false
  end)
  container:AddChild(autoLootThresholdCheck)

  local lootThresholdDropdown = AceGUI:Create("Dropdown")
  lootThresholdDropdown:SetLabel("Loot threshold")
  lootThresholdDropdown:SetList(BuildLootThresholdDropdownList(), QUALITY_ORDER)
  lootThresholdDropdown:SetValue(settings.lootThresholdQuality)
  lootThresholdDropdown:SetWidth(160)
  lootThresholdDropdown:SetCallback("OnValueChanged", function(widget, event, value)
    settings.lootThresholdQuality = value
  end)
  container:AddChild(lootThresholdDropdown)

  local autoPromoteAssistSpacer = AceGUI:Create("SimpleGroup")
  autoPromoteAssistSpacer:SetFullWidth(true)
  autoPromoteAssistSpacer.noAutoHeight = true
  autoPromoteAssistSpacer:SetHeight(10)
  container:AddChild(autoPromoteAssistSpacer)

  local autoPromoteAssistHeading = AceGUI:Create("Heading")
  autoPromoteAssistHeading:SetFullWidth(true)
  autoPromoteAssistHeading:SetText("Auto Promote")
  container:AddChild(autoPromoteAssistHeading)

  local autoPromoteAssistCheck = AceGUI:Create("CheckBox")
  autoPromoteAssistCheck:SetLabel("Automatically promote to Assist")
  autoPromoteAssistCheck:SetValue(settings.autoPromoteAssist)
  autoPromoteAssistCheck:SetFullWidth(true)
  autoPromoteAssistCheck:SetCallback("OnValueChanged", function(widget, event, value)
    settings.autoPromoteAssist = value and true or false
  end)
  container:AddChild(autoPromoteAssistCheck)

  -- Same normalization as the master looter candidates box above - resolve
  -- a missing realm from the master roster and fix up capitalization.
  local assistBox = AceGUI:Create("EditBox")
  assistBox:SetLabel("Assist candidates (names separated by a space)")
  assistBox:SetText(settings.assistNames)
  assistBox:SetFullWidth(true)
  assistBox:SetCallback("OnEnterPressed", function(widget, event, value)
    local rawNames = {}
    for token in value:gmatch("%S+") do
      table.insert(rawNames, token)
    end
    local cleaned, needsRealm = ns.NormalizeList(rawNames)
    settings.assistNames = table.concat(cleaned, " ")
    widget:SetText(settings.assistNames)
    if #needsRealm > 0 then
      print(PREFIX ..
        "These assist entries still need a realm (no match found yet): " .. table.concat(needsRealm, ", "))
    end
  end)
  container:AddChild(assistBox)
end

----------------------------------------------------------------------
-- Vertical tab list + window construction
----------------------------------------------------------------------

local TABS = {
  { id = "invites", text = "Invites", build = BuildInvitesTab },
  { id = "raid",    text = "Raid",    build = BuildRaidTab },
}

-- Row height/gap for the raw tab-list rows below (not AceGUI-managed - see
-- CreateTabRow's own comment for why).
local TAB_ROW_HEIGHT = 20
local TAB_ROW_GAP = 4

-- Mimics the vertical category list in Blizzard's own Interface Options /
-- AddOns list: plain left-aligned text rows with a highlight bar behind the
-- selected one, instead of AceGUI's bordered/beveled Button look. These are
-- raw frames, not AceGUI widgets, parented directly onto tabGroup.content
-- and positioned by hand - the same technique UI_Groups.lua's group
-- boxes/slots already use for the same reason (see its own comments): they
-- need a real vertical list look AceGUI's Button widget can't produce, and
-- as raw frames AceGUI's ReleaseChildren would never know to clean them up
-- if their panel were recycled into some other window - which is also why
-- this whole settings window is kept resident and only ever Hidden, never
-- AceGUI:Release()'d (see BuildSettingsFrame's OnClose below).
--
-- ns.ApplyGoldSelectionHighlight's returned texture is independent of the
-- row's built-in hover highlight (which only lights up on mouseover) -
-- SelectTab shows/hides this one to mark whichever tab is currently active.
local function CreateTabRow(parent, text, onClick)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(TAB_ROW_HEIGHT)

  row.riSelectedHighlight = ns.ApplyGoldSelectionHighlight(row)

  local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  label:SetPoint("LEFT", row, "LEFT", 6, 0)
  label:SetJustifyH("LEFT")
  label:SetText(text)

  row:SetScript("OnClick", onClick)

  return row
end

local function BuildSettingsFrame()
  local settings = MakeIdiotsAppearDB.settings

  local f = AceGUI:Create("Frame")
  ns.ApplyTooltipWindowStyle(f)
  f:SetTitle("Make Idiots Appear Settings")
  f:SetStatusText("")
  f:SetLayout("Flow")
  f:EnableResize(false)

  -- See UI_Main.lua's BuildMainFrame for why this is all that's needed to
  -- remember window position across sessions. Width/height are enforced
  -- every time (not just on first use) since this window just changed shape
  -- from a single column to a tab list + content panel - a size saved by an
  -- older version of this window would otherwise leave the new layout
  -- cramped.
  MakeIdiotsAppearDB.windowStatus.settings = MakeIdiotsAppearDB.windowStatus.settings or {}
  local settingsStatus = MakeIdiotsAppearDB.windowStatus.settings
  f:SetStatusTable(settingsStatus)
  f:SetWidth(500)
  f:SetHeight(620)

  -- Deliberately never AceGUI:Release()'d, unlike this window's own previous
  -- design (and unlike Main/Rosters) - see CreateTabRow's comment above for
  -- why: releasing would recycle tabGroup into AceGUI's shared "InlineGroup"
  -- pool with the raw tab rows still attached to its .content, and they
  -- could end up bleeding into whatever unrelated panel gets handed that
  -- recycled instance next. Just hiding and keeping the single instance
  -- around for the rest of the session sidesteps that entirely (mirrors
  -- UI_Groups.lua's Manage Groups window for the same reason).
  local function CloseWindow()
    f.frame:Hide()
  end

  f:SetCallback("OnClose", CloseWindow)

  ----------------------------------------------------------------
  -- Left: vertical tab list
  ----------------------------------------------------------------

  local tabGroup = AceGUI:Create("InlineGroup")
  tabGroup:SetTitle("")
  -- Left blank ("List" default, never given any AceGUI children - the tab
  -- rows are raw frames parented straight to tabGroup.content).
  -- Deliberately left a hair under 0.26/0.74 (rather than summing to exactly
  -- 1.0) - see UI_Rosters.lua's leftGroup for why: AceGUI's "Flow" layout
  -- (used by this window's outer frame) can wrap a child to a new row if
  -- pixel-rounding pushes the combined width a fraction over the container's.
  tabGroup:SetRelativeWidth(0.25)
  tabGroup.noAutoHeight = true
  tabGroup:SetHeight(PANEL_HEIGHT)
  f:AddChild(tabGroup)

  ----------------------------------------------------------------
  -- Right: current tab's content
  ----------------------------------------------------------------

  local contentGroup = AceGUI:Create("InlineGroup")
  contentGroup:SetTitle("")
  contentGroup:SetLayout("List")
  -- See tabGroup's own comment above for why this is 0.73, not 0.74.
  contentGroup:SetRelativeWidth(0.73)
  contentGroup.noAutoHeight = true
  contentGroup:SetHeight(PANEL_HEIGHT)
  f:AddChild(contentGroup)

  local selectedTabId = "invites"
  local tabRows = {}

  -- Rebuilds the content panel from scratch for whichever tab is selected,
  -- rather than pre-building both and toggling Hide/Show - AceGUI's own
  -- "List" layout unconditionally re-Shows every child of a container on
  -- every layout pass, so a manually hidden sibling wouldn't stay hidden.
  local function SelectTab(tabId)
    selectedTabId = tabId

    contentGroup:ReleaseChildren()
    for _, tab in ipairs(TABS) do
      local isSelected = tab.id == tabId
      tabRows[tab.id].riSelectedHighlight:SetShown(isSelected)
      if isSelected then
        tab.build(contentGroup, settings)
      end
    end
    contentGroup:DoLayout()
  end

  for i, tab in ipairs(TABS) do
    local row = CreateTabRow(tabGroup.content, tab.text, function()
      SelectTab(tab.id)
    end)
    row:SetPoint("TOPLEFT", tabGroup.content, "TOPLEFT", 0, -(i - 1) * (TAB_ROW_HEIGHT + TAB_ROW_GAP))
    row:SetPoint("RIGHT", tabGroup.content, "RIGHT", 0, 0)
    tabRows[tab.id] = row
  end

  SelectTab(selectedTabId)

  -- Lets ns.ShowSettingsFrame's already-open branch reset the currently
  -- shown tab's fields back to the persisted settings (matching this
  -- window's old always-rebuilt-on-open behavior) without needing to tear
  -- down and rebuild the whole window, which now stays resident - see
  -- CloseWindow's comment above.
  f.riRefreshCurrentTab = function()
    SelectTab(selectedTabId)
  end

  return f
end

function ns.ShowSettingsFrame()
  ns.EnsureDB()
  if settingsFrame then
    settingsFrame.frame:Show()
    settingsFrame.riRefreshCurrentTab()
    return
  end
  settingsFrame = BuildSettingsFrame()
end
