-- UI_Rosters.lua
-- Roster manager window: add, save/rename, delete rosters, and pick the active one. Built with AceGUI-3.0.

local ADDON_NAME, ns = ...
local PREFIX = ns.PREFIX
local AceGUI = LibStub("AceGUI-3.0")

StaticPopupDialogs["MAKEIDIOTSAPPEAR_CONFIRM_DELETE_ROSTER"] = {
  text = "Delete roster '%s'? This cannot be undone.",
  button1 = "Delete",
  button2 = "Cancel",
  OnAccept = function(self, data)
    if data and data.rosterName then
      ns.DeleteRoster(data.rosterName)
    end
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

local rosterManagerFrame = nil
local selectedRoster = nil
local rosterScroll, nameBox, playersBox
local SaveRoster
local SetActiveRoster

-- Fixed raid-size choices a roster can be tagged with; picking one saves
-- immediately (see the checkboxes built in BuildRosterManagerFrame below).
local GROUP_SIZES = { 10, 20, 40 }
-- Shared with UI_Main.lua's bench split - see ns.GetRosterGroupSize in
-- MakeIdiotsAppear.lua.
local DEFAULT_GROUP_SIZE = ns.DEFAULT_ROSTER_GROUP_SIZE

-- size -> CheckBox widget, populated by BuildRosterManagerFrame. Kept at
-- file scope (like rosterRows above) so RefreshGroupSizeSelection can
-- restyle them from anywhere selectedRoster changes.
local groupSizeCheckboxes = {}

-- name -> row, populated by RefreshRosterList - lets a plain click update
-- just the highlight on the currently-displayed rows (see
-- UpdateRosterSelectionHighlight below) without releasing/rebuilding the
-- whole list the way RefreshRosterList does. That distinction matters for
-- double-click: RefreshRosterList's ReleaseChildren() hides every row's
-- riButton (see PrepareRosterRow's OnRelease), so if a plain click rebuilt
-- the list, the row the user just clicked would already be hidden/gone by
-- the time a second, fast click landed on it - breaking OnDoubleClick before
-- it could ever fire.
local rosterRows = {}

-- Row height for the raw roster-list rows below (not AceGUI-managed - see
-- PrepareRosterRow's own comment for why).
local ROSTER_ROW_HEIGHT = 20

-- 2pt smaller than ns.GetChatFont's own default - same treatment as player
-- names in UI_Main.lua.
local ROSTER_FONT_FILE, ROSTER_FONT_HEIGHT, ROSTER_FONT_FLAGS = ns.GetChatFont(-2)

-- Mirrors the "Invites"/"Group" tab list style in UI_Settings.lua: plain
-- left-aligned text with a highlight bar behind the selected roster,
-- instead of AceGUI's bordered/beveled Button look with a "<--" text arrow.
-- The clickable button/text/highlight are raw frames, not AceGUI widgets -
-- same reasoning as UI_Settings.lua's CreateTabRow - but unlike that one,
-- this list is dynamic and needs to scroll, so each row is wrapped in a
-- SimpleGroup so rosterScroll's own List layout/scrolling still works (it
-- needs real AceGUI widget children for its height math).
--
-- SimpleGroup is a shared widget type AceGUI recycles across this whole
-- addon, not just this list (see UI_Main.lua's PrepareRow for the same
-- point in more detail) - so the raw content here is guarded against being
-- recreated on a reused instance, and explicitly hidden again in OnRelease,
-- so a SimpleGroup that once served as a roster row can't still be showing
-- roster text if it's later recycled as an unrelated spacer/button row
-- elsewhere.
local function PrepareRosterRow(row)
  if not row.riPrepared then
    row.riPrepared = true
    row.noAutoHeight = true
    row:SetHeight(ROSTER_ROW_HEIGHT)

    local btn = CreateFrame("Button", nil, row.content)
    btn:SetAllPoints(row.content)

    local highlight = ns.ApplyGoldSelectionHighlight(btn)

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetFont(ROSTER_FONT_FILE, ROSTER_FONT_HEIGHT, ROSTER_FONT_FLAGS)
    label:SetPoint("LEFT", btn, "LEFT", 6, 0)
    label:SetJustifyH("LEFT")

    row.riButton = btn
    row.riHighlight = highlight
    row.riLabel = label

    row.OnRelease = function(self)
      self.riButton:Hide()
      self.riButton:SetScript("OnClick", nil)
      self.riButton:SetScript("OnDoubleClick", nil)
      self.riHighlight:Hide()
      self.riLabel:SetText("")
      self.noAutoHeight = nil
      self.riPrepared = nil
    end
  end

  row.riButton:Show()
end

-- Restyles just the currently-displayed rows' highlight to match
-- selectedRoster, without releasing/rebuilding them - see rosterRows' own
-- comment for why a plain click deliberately doesn't call the full
-- RefreshRosterList.
local function UpdateRosterSelectionHighlight()
  for name, row in pairs(rosterRows) do
    if name == selectedRoster then
      row.riHighlight:Show()
    else
      row.riHighlight:Hide()
    end
  end
end

-- Restyles the group-size radio row to match selectedRoster's saved size
-- (or DEFAULT_GROUP_SIZE if it hasn't been set), and disables the row
-- entirely when there's no roster selected to apply a choice to.
local function RefreshGroupSizeSelection()
  local current = selectedRoster and ns.GetRosterGroupSize(selectedRoster)
  for _, size in ipairs(GROUP_SIZES) do
    local cb = groupSizeCheckboxes[size]
    cb:SetValue(size == current)
    cb:SetDisabled(not selectedRoster)
    -- CheckBox:SetDisabled(false) always resets .text to plain white (see
    -- AceGUIWidget-CheckBox.lua) - reassert the gold set when it was created
    -- (its disabled-state grey is left alone, that one already matches).
    if selectedRoster then
      cb.text:SetTextColor(1, 0.82, 0)
    end
  end
end

local function RefreshRosterList()
  rosterScroll:ReleaseChildren()
  wipe(rosterRows)

  local names = {}
  for name in pairs(MakeIdiotsAppearDB.rosters) do
    table.insert(names, name)
  end
  table.sort(names)

  if #names == 0 then
    local emptyLabel = AceGUI:Create("Label")
    emptyLabel:SetFullWidth(true)
    emptyLabel:SetText("(no rosters yet)")
    rosterScroll:AddChild(emptyLabel)
  else
    for _, name in ipairs(names) do
      local row = AceGUI:Create("SimpleGroup")
      row:SetFullWidth(true)
      PrepareRosterRow(row)

      local label = name
      if name == MakeIdiotsAppearDB.settings.activeRoster then
        label = label .. "  |cff33ff99(active)|r"
      end
      row.riLabel:SetText(label)

      if name == selectedRoster then
        row.riHighlight:Show()
      else
        row.riHighlight:Hide()
      end

      row.riButton:SetScript("OnClick", function()
        selectedRoster = name
        nameBox:SetText(name)
        playersBox:SetText(table.concat(MakeIdiotsAppearDB.rosters[name] or {}, "\n"))
        UpdateRosterSelectionHighlight()
        RefreshGroupSizeSelection()
      end)

      row.riButton:SetScript("OnDoubleClick", function()
        selectedRoster = name
        nameBox:SetText(name)
        playersBox:SetText(table.concat(MakeIdiotsAppearDB.rosters[name] or {}, "\n"))
        RefreshGroupSizeSelection()
        SetActiveRoster(name)
      end)

      rosterRows[name] = row
      rosterScroll:AddChild(row)
    end
  end

  rosterScroll:DoLayout()
end

SetActiveRoster = function(name)
  MakeIdiotsAppearDB.settings.activeRoster = name
  print(PREFIX .. "'" .. name .. "' is now the active roster.")
  RefreshRosterList()
  ns.FireStateChanged()
end

local function GenerateUniqueRosterName()
  local base = "New Roster"
  if not MakeIdiotsAppearDB.rosters[base] then
    return base
  end
  local i = 2
  while MakeIdiotsAppearDB.rosters[base .. " " .. i] do
    i = i + 1
  end
  return base .. " " .. i
end

function ns.DeleteRoster(name)
  MakeIdiotsAppearDB.rosters[name] = nil
  MakeIdiotsAppearDB.rosterGroupSizes[name] = nil
  ns.DeleteRosterGroupData(name)
  if MakeIdiotsAppearDB.settings.activeRoster == name then
    MakeIdiotsAppearDB.settings.activeRoster = nil
  end
  if selectedRoster == name then
    selectedRoster = nil
    nameBox:SetText("")
    playersBox:SetText("")
    RefreshGroupSizeSelection()
  end
  print(PREFIX .. "Deleted roster '" .. name .. "'.")
  RefreshRosterList()
  ns.FireStateChanged()
end

local function BuildRosterManagerFrame()
  local f = AceGUI:Create("Frame")
  ns.ApplyTooltipWindowStyle(f)
  f:SetTitle("Manage Rosters")
  f:SetStatusText("")
  f:SetLayout("Flow")
  f:EnableResize(false)

  -- See UI_Main.lua's BuildMainFrame for why this is all that's needed to
  -- remember window position across sessions. Width/height are set
  -- unconditionally (not gated on first-use) because EnableResize(false)
  -- above means the user can never drag a different size into
  -- rostersStatus themselves - code is the only thing that ever sets it,
  -- same as UI_Main.lua's own frame, so it should always win. Gating this
  -- on first-use previously meant a size bump here (e.g. adding the
  -- group-size row below) would never actually reach anyone who'd already
  -- opened this window before that change shipped - their stale saved
  -- height would stick forever and the taller content would overflow it.
  MakeIdiotsAppearDB.windowStatus.rosters = MakeIdiotsAppearDB.windowStatus.rosters or {}
  local rostersStatus = MakeIdiotsAppearDB.windowStatus.rosters
  f:SetStatusTable(rostersStatus)
  f:SetWidth(500)
  f:SetHeight(640)
  f:SetCallback("OnClose", function(widget)
    AceGUI:Release(widget)
    rosterManagerFrame = nil
    selectedRoster = nil
  end)

  ----------------------------------------------------------------
  -- Left: roster list
  ----------------------------------------------------------------

  -- InlineGroup normally auto-sizes to its content (see its LayoutFinished),
  -- which fights SetFullHeight's anchor-stretch and produces stale heights
  -- that throw off Flow's row-centering math, visually shoving the shorter
  -- panel down. Giving both panels the same explicit height sidesteps that.
  -- The extra 60px over the original 500 is headroom for the group-size row
  -- added below nameBox on the right - leftGroup gets the same height (see
  -- above), so leftSpacer below absorbs that same 60px to keep its own
  -- elements at their original size/position.
  local PANEL_HEIGHT = 560

  local leftGroup = AceGUI:Create("InlineGroup")
  leftGroup:SetTitle("Rosters")
  leftGroup:SetLayout("List")
  -- Deliberately left a hair under 0.45/0.55 (rather than summing to exactly
  -- 1.0) - AceGUI's "Flow" layout (used by this window's outer frame) wraps
  -- a child to a new row if its pixel width plus everything already on that
  -- row exceeds the container's width, and with zero margin, pixel rounding
  -- on the container's width (466px here, not evenly split by 0.45/0.55)
  -- could occasionally push the sum a fraction of a pixel over, dropping
  -- Roster details onto its own row below Rosters instead of beside it.
  leftGroup:SetRelativeWidth(0.44)
  leftGroup.noAutoHeight = true
  leftGroup:SetHeight(PANEL_HEIGHT)
  f:AddChild(leftGroup)

  rosterScroll = AceGUI:Create("ScrollFrame")
  rosterScroll:SetLayout("List")
  rosterScroll:SetFullWidth(true)
  rosterScroll:SetHeight(340)
  leftGroup:AddChild(rosterScroll)

  -- "List" layout just stacks children top-down with no auto-fill, so a
  -- blank spacer is what pushes Add Roster down to the bottom of the panel.
  -- (A Label won't hold a forced height - it recalculates itself from its
  -- text on every SetText/SetWidth. SimpleGroup respects noAutoHeight.)
  -- 120 = the original 60 plus the same 60px PANEL_HEIGHT grew by above, so
  -- rosterScroll/Add Roster/Delete Roster below keep their original sizes.
  local leftSpacer = AceGUI:Create("SimpleGroup")
  leftSpacer:SetFullWidth(true)
  leftSpacer.noAutoHeight = true
  leftSpacer:SetHeight(120)
  leftGroup:AddChild(leftSpacer)

  local addRosterBtn = AceGUI:Create("Button")
  addRosterBtn:SetText("Add Roster")
  addRosterBtn:SetFullWidth(true)
  ns.ShrinkButtonFont(addRosterBtn)
  addRosterBtn:SetCallback("OnClick", function()
    local name = GenerateUniqueRosterName()
    MakeIdiotsAppearDB.rosters[name] = {}
    selectedRoster = name
    nameBox:SetText(name)
    playersBox:SetText("")
    RefreshRosterList()
    RefreshGroupSizeSelection()
    print(PREFIX .. "Created blank roster '" .. name .. "'.")

    -- Send focus straight to the name box with the placeholder name
    -- pre-highlighted, so typing immediately replaces it and Enter saves -
    -- no mouse clicks needed to name a new roster.
    nameBox:SetFocus()
    nameBox:HighlightText()
  end)
  leftGroup:AddChild(addRosterBtn)

  -- "List" layout stacks children with zero gap by default, so a small
  -- blank spacer is what creates breathing room between Add Roster and
  -- Delete Roster (same pattern used for stacked buttons elsewhere in this
  -- addon, e.g. UI_Main.lua's rightGroup).
  local deleteBtnSpacer = AceGUI:Create("SimpleGroup")
  deleteBtnSpacer:SetFullWidth(true)
  deleteBtnSpacer.noAutoHeight = true
  deleteBtnSpacer:SetHeight(4)
  leftGroup:AddChild(deleteBtnSpacer)

  local deleteBtn = AceGUI:Create("Button")
  deleteBtn:SetText("Delete Roster")
  deleteBtn:SetFullWidth(true)
  ns.ShrinkButtonFont(deleteBtn)
  deleteBtn:SetCallback("OnClick", function()
    if not selectedRoster then
      print(PREFIX .. "Select a roster to delete first.")
      return
    end
    StaticPopup_Show("MAKEIDIOTSAPPEAR_CONFIRM_DELETE_ROSTER", selectedRoster, nil, { rosterName = selectedRoster })
  end)
  leftGroup:AddChild(deleteBtn)

  ----------------------------------------------------------------
  -- Right: name + player list editor
  ----------------------------------------------------------------

  local rightGroup = AceGUI:Create("InlineGroup")
  rightGroup:SetTitle("Roster details")
  rightGroup:SetLayout("List")
  -- See leftGroup's own comment above for why this is 0.54, not 0.55.
  rightGroup:SetRelativeWidth(0.54)
  rightGroup.noAutoHeight = true
  rightGroup:SetHeight(PANEL_HEIGHT)
  f:AddChild(rightGroup)

  nameBox = AceGUI:Create("EditBox")
  nameBox:SetLabel("Roster name")
  nameBox:SetFullWidth(true)
  nameBox:SetCallback("OnEnterPressed", function()
    SaveRoster()
    -- Blizzard's EditBox doesn't lose focus on its own after OnEnterPressed;
    -- move it to the player list so Enter both saves the name and continues
    -- the workflow into the next field to fill in.
    playersBox:SetFocus()
  end)
  rightGroup:AddChild(nameBox)

  local groupSizeRow = AceGUI:Create("SimpleGroup")
  groupSizeRow:SetLayout("Flow")
  groupSizeRow:SetFullWidth(true)
  rightGroup:AddChild(groupSizeRow)

  -- Radio-style CheckBoxes (AceGUI has no dedicated radio-group widget) -
  -- mutual exclusivity and persistence are handled by hand below: picking
  -- one saves it as selectedRoster's group size immediately and restyles
  -- the row via RefreshGroupSizeSelection, and re-clicking the already
  -- -selected box just re-checks itself instead of leaving none selected.
  for _, size in ipairs(GROUP_SIZES) do
    local cb = AceGUI:Create("CheckBox")
    cb:SetType("radio")
    cb:SetLabel(size .. " Man")
    cb:SetWidth(75)
    -- CheckBox has no SetFont method, but .text is a plain FontString - drop
    -- to GameFontNormalSmall/gold to match nameBox/playersBox's own EditBox
    -- labels ("Roster name" etc, see AceGUIWidget-EditBox.lua's Constructor/
    -- SetDisabled), instead of the default GameFontHighlight (larger, plain
    -- white) a CheckBox's label normally gets.
    cb.text:SetFontObject(GameFontNormalSmall)
    cb:SetValue(size == DEFAULT_GROUP_SIZE)
    cb:SetCallback("OnValueChanged", function(widget, event, value)
      if not selectedRoster then
        return
      end
      if not value then
        widget:SetValue(true)
        return
      end
      MakeIdiotsAppearDB.rosterGroupSizes[selectedRoster] = size
      RefreshGroupSizeSelection()
      print(PREFIX .. string.format("Set group size for '%s' to %d.", selectedRoster, size))
      ns.FireStateChanged()
    end)
    groupSizeCheckboxes[size] = cb
    groupSizeRow:AddChild(cb)
  end

  -- Breathing room between the group-size row and the player list below,
  -- same spacer pattern used throughout this panel (see leftSpacer above).
  local groupSizeSpacer = AceGUI:Create("SimpleGroup")
  groupSizeSpacer:SetFullWidth(true)
  groupSizeSpacer.noAutoHeight = true
  groupSizeSpacer:SetHeight(2)
  rightGroup:AddChild(groupSizeSpacer)

  -- 24, not the original 22 - the group-size row above added 26px to this
  -- column (24 for the row + 2 for groupSizeSpacer) but leftSpacer grew by
  -- 60 to keep leftGroup's own contents pinned at their original size (see
  -- leftSpacer above), a 34px shortfall that left Save Roster/Set Active
  -- sitting above Delete Roster instead of level with it. MultiLineEditBox
  -- grows 14px/line (see its own Layout), so +2 lines recovers 28px of
  -- that; rightSpacer below makes up the remaining 6px.
  playersBox = AceGUI:Create("MultiLineEditBox")
  playersBox:SetLabel("Players (one Name-Realm per line)")
  playersBox:SetFullWidth(true)
  playersBox:SetNumLines(24)
  rightGroup:AddChild(playersBox)

  -- Pushes Save Roster/Set Active down those extra few px so they line up
  -- with Add Roster/Delete Roster on the left (see leftSpacer above).
  local rightSpacer = AceGUI:Create("SimpleGroup")
  rightSpacer:SetFullWidth(true)
  rightSpacer.noAutoHeight = true
  rightSpacer:SetHeight(26)
  rightGroup:AddChild(rightSpacer)

  local btnRow1 = AceGUI:Create("SimpleGroup")
  btnRow1:SetLayout("Flow")
  btnRow1:SetFullWidth(true)
  rightGroup:AddChild(btnRow1)

  SaveRoster = function()
    if not selectedRoster then
      print(PREFIX .. "Select or add a roster first.")
      return
    end

    local newName = ns.Trim(nameBox:GetText())
    if newName == "" then
      print(PREFIX .. "Enter a name for the roster.")
      return
    end

    if newName ~= selectedRoster then
      if MakeIdiotsAppearDB.rosters[newName] then
        print(PREFIX .. "A roster named '" .. newName .. "' already exists.")
        return
      end
      MakeIdiotsAppearDB.rosters[newName] = MakeIdiotsAppearDB.rosters[selectedRoster]
      MakeIdiotsAppearDB.rosters[selectedRoster] = nil
      MakeIdiotsAppearDB.rosterGroupSizes[newName] = MakeIdiotsAppearDB.rosterGroupSizes[selectedRoster]
      MakeIdiotsAppearDB.rosterGroupSizes[selectedRoster] = nil
      ns.MoveRosterGroupData(selectedRoster, newName)
      if MakeIdiotsAppearDB.settings.activeRoster == selectedRoster then
        MakeIdiotsAppearDB.settings.activeRoster = newName
      end
      print(PREFIX .. "Renamed roster '" .. selectedRoster .. "' to '" .. newName .. "'.")
      selectedRoster = newName
    end

    local raw = ns.ParsePastedText(playersBox:GetText())
    local cleaned, needsRealm = ns.NormalizeList(raw)
    MakeIdiotsAppearDB.rosters[selectedRoster] = cleaned
    ns.ResetDefaultGroupComp(selectedRoster, cleaned)
    playersBox:SetText(table.concat(cleaned, "\n"))
    print(PREFIX .. string.format("Saved roster '%s' with %d players.", selectedRoster, #cleaned))
    if #needsRealm > 0 then
      print(PREFIX .. "These entries still need a realm (no match found yet): " .. table.concat(needsRealm, ", "))
    end
    RefreshRosterList()
    ns.FireStateChanged()
  end

  local saveBtn = AceGUI:Create("Button")
  saveBtn:SetText("Save Roster")
  saveBtn:SetWidth(110)
  ns.ShrinkButtonFont(saveBtn)
  saveBtn:SetCallback("OnClick", SaveRoster)
  btnRow1:AddChild(saveBtn)

  local setActiveBtn = AceGUI:Create("Button")
  setActiveBtn:SetText("Set Active")
  setActiveBtn:SetWidth(120)
  ns.ShrinkButtonFont(setActiveBtn)
  setActiveBtn:SetCallback("OnClick", function()
    if not selectedRoster then
      print(PREFIX .. "Select a roster to set as active first.")
      return
    end
    SetActiveRoster(selectedRoster)
  end)
  btnRow1:AddChild(setActiveBtn)

  return f
end

function ns.ShowRosterManagerFrame()
  ns.EnsureDB()
  if rosterManagerFrame then
    rosterManagerFrame.frame:Show()
    RefreshRosterList()
    RefreshGroupSizeSelection()
    return
  end

  rosterManagerFrame = BuildRosterManagerFrame()
  RefreshRosterList()
  if MakeIdiotsAppearDB.settings.activeRoster then
    selectedRoster = MakeIdiotsAppearDB.settings.activeRoster
    nameBox:SetText(selectedRoster)
    playersBox:SetText(table.concat(MakeIdiotsAppearDB.rosters[selectedRoster] or {}, "\n"))
    RefreshRosterList()
  end
  RefreshGroupSizeSelection()
end
