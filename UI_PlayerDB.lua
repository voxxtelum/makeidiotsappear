-- UI_PlayerDB.lua
-- Player Database window: view/add/remove/edit every learned Name-Realm-Class
-- entry from MakeIdiotsAppearDB.masterRoster as a filterable grid. Built with
-- AceGUI-3.0. Opened only via "/mia playerdb" (see UI_Main.lua's slash
-- handler) - not linked from any other window yet.
--
-- Each row is either display mode (plain, class-colored text + an Edit
-- button) or edit mode (EditBoxes + a class Dropdown + a Save button) - see
-- CreateRow. Saving a row commits it straight to MakeIdiotsAppearDB
-- immediately (via ns.UpsertPlayerDbEntry); there's no separate "staged
-- changes" state or bulk Save button - a row not currently being edited is
-- always already what's in the database.

local ADDON_NAME, ns = ...
local PREFIX = ns.PREFIX
local AceGUI = LibStub("AceGUI-3.0")

-- Forward-declared so the popup below (registered once, at file load time,
-- long before DoRemoveRow's own definition further down) closes over this
-- same upvalue rather than resolving DoRemoveRow as an undeclared global.
local DoRemoveRow

StaticPopupDialogs["MAKEIDIOTSAPPEAR_CONFIRM_REMOVE_PLAYER"] = {
  text = "Remove '%s' from the player database? This cannot be undone.",
  button1 = "Remove",
  button2 = "Cancel",
  OnAccept = function(self, data)
    if data and data.row then
      DoRemoveRow(data.row)
    end
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- Built once - the running client's class set never changes mid-session.
-- "" / "(Unknown)" is prepended so a row can represent "class not yet known"
-- as an explicit, selectable dropdown state rather than a special case.
local CLASS_LIST, CLASS_ORDER
do
  local list, order = ns.GetClassList()
  CLASS_LIST, CLASS_ORDER = { [""] = "(Unknown)" }, { "" }
  for _, token in ipairs(order) do
    CLASS_LIST[token] = list[token]
    table.insert(CLASS_ORDER, token)
  end
end

-- "action" is the Edit/Save toggle button. There's no separate column for
-- the remove button - it's a plain native icon (see CreateRemoveButton
-- below), positioned absolutely at the row's right edge rather than taking
-- its own Flow slot, the same technique UI_Main.lua uses for its own bench
-- row's "+" invite button. Deliberately left summing under 1.0 (see e.g.
-- UI_Rosters.lua's leftGroup for why: AceGUI's Flow layout can wrap a child
-- to a new row if pixel rounding pushes the combined width a hair over) -
-- the remaining ~10% at the right edge is exactly where that icon sits.
local ROW_RELWIDTHS = { name = 0.28, realm = 0.28, class = 0.24, action = 0.10 }

-- Fixed row height, same in display and edit mode, sized to fit an
-- unlabeled EditBox/Dropdown (both default to 26px tall with no label - see
-- their own SetLabel methods) without clipping. Both modes use this same
-- value for every widget in the row (see CreateRow) specifically so toggling
-- a row between modes never changes its height - which would otherwise
-- shift every row below it up or down in the list.
local ROW_HEIGHT = 26

-- Plain native icon button (no AceGUI widget), same technique as
-- UI_Main.lua's own CreateIconButton (used there for the collapse/expand
-- buttons and the bench row's invite button) - AceGUI's own Button widget
-- is built on UIPanelButtonTemplate, whose text inset leaves no room for
-- anything at this size. UI-GroupLoot-Pass is the group-loot roll frame's
-- "Pass" (decline) button - a plain red X, the closest native WoW asset to
-- a generic small delete icon. The highlight reuses the same -Up texture
-- (additive blend, so hovering just brightens it) rather than a separate
-- -Highlight variant, matching CreateIconButton's own reasoning for doing
-- the same.
local REMOVE_ICON_SIZE = 16

local function CreateRemoveButton(parent, onClick)
  local btn = CreateFrame("Button", nil, parent)
  btn:SetSize(REMOVE_ICON_SIZE, REMOVE_ICON_SIZE)
  btn:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
  btn:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")
  btn:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up", "ADD")
  btn:SetScript("OnClick", onClick)
  return btn
end

local playerDbFrame = nil
local scroll = nil

-- Every row currently shown, in DB order. Each row is:
--   { name=, realm=, class=classFileOrNil, editing=bool,
--     saved = {name=, realm=, class=} or nil }
-- `saved` is nil for a row added via "Add Player" that's never been
-- committed yet; otherwise it's that row's last-known database identity,
-- used to know what to remove-and-replace on a rename, what to revert to if
-- an edit is abandoned, and what to delete on Remove.
local workingRows = {}

-- The one row currently in edit mode, or nil - only one row can be edited
-- at a time (see StartEditingRow).
local editingRow = nil

-- Current text of the search box and whether it was actually filtering
-- (3+ characters) the last time the grid was rendered - see the search
-- box's OnTextChanged callback (in BuildPlayerDbFrame) for why
-- wasFiltering matters, and RenderRows for where it's kept up to date.
local searchText = ""
local wasFiltering = false

local RenderRows

local function LoadWorkingRows()
  workingRows = {}
  editingRow = nil
  for _, entry in ipairs(ns.GetAllPlayerDbEntries()) do
    table.insert(workingRows, {
      name = entry.name,
      realm = entry.realm,
      class = entry.class,
      editing = false,
      saved = { name = entry.name, realm = entry.realm, class = entry.class },
    })
  end

  -- ns.GetAllPlayerDbEntries flattens a plain hash table (masterRoster), so
  -- its order is otherwise arbitrary - sort by name (realm as a tiebreaker,
  -- for two entries sharing a name on different realms) so the list has a
  -- stable, predictable default order. Only applied here, at load time - a
  -- row doesn't get re-sorted into place after being edited/saved, and a
  -- freshly added row is deliberately pinned to the top instead (see the Add
  -- Player button).
  table.sort(workingRows, function(a, b)
    local an, bn = a.name:lower(), b.name:lower()
    if an == bn then
      return (a.realm or ""):lower() < (b.realm or ""):lower()
    end
    return an < bn
  end)
end

-- Removes a row that's already been confirmed (see RemoveRow below) -
-- deletes its database entry if it had one, drops it from workingRows, and
-- re-renders.
DoRemoveRow = function(row)
  if row.saved then
    ns.RemovePlayerDbEntry(row.saved.name, row.saved.realm)
    ns.FireStateChanged()
  end
  if editingRow == row then
    editingRow = nil
  end
  for i, r in ipairs(workingRows) do
    if r == row then
      table.remove(workingRows, i)
      break
    end
  end
  RenderRows()
end

-- Only confirms when there's an actual saved database entry to lose - a
-- brand-new row that was never saved has nothing destructive to confirm.
local function RemoveRow(row)
  if row.saved then
    StaticPopup_Show("MAKEIDIOTSAPPEAR_CONFIRM_REMOVE_PLAYER", row.saved.name .. "-" .. row.saved.realm, nil, { row = row })
  else
    DoRemoveRow(row)
  end
end

-- Ends edit mode on a row without saving it - reverts a previously-saved
-- row's display back to its last-saved values, or (for a brand-new row that
-- was never saved) just discards it outright, since there'd be nothing left
-- to meaningfully display. Used both when a row's own edit is abandoned by
-- starting to edit a different row (see StartEditingRow - only one row can
-- be in edit mode at a time) and could be reused for an explicit cancel
-- later if this ever gets one.
local function AbandonEdit(row)
  if row.saved then
    row.name = row.saved.name
    row.realm = row.saved.realm
    row.class = row.saved.class
    row.editing = false
  else
    for i, r in ipairs(workingRows) do
      if r == row then
        table.remove(workingRows, i)
        break
      end
    end
  end
  if editingRow == row then
    editingRow = nil
  end
end

local function StartEditingRow(row)
  if editingRow and editingRow ~= row then
    AbandonEdit(editingRow)
  end
  editingRow = row
  row.editing = true
  RenderRows()
end

local function SaveRow(row)
  local rawName = row.name or ""
  local label = rawName ~= "" and rawName or "(blank)"
  local name = ns.ProperCase(ns.Trim(rawName))
  local realmInput = ns.Trim(row.realm or "")
  local realm = ns.NormalizeRealmName(realmInput)

  if not ns.IsValidPlayerDbName(name) then
    print(PREFIX .. "Can't save " .. label .. " - invalid name (2-12 letters, no character repeated 3+ times in a row).")
    return
  end
  if not realm then
    print(PREFIX .. "Can't save " .. label .. " - unrecognized realm '" .. (realmInput ~= "" and realmInput or "(blank)") .. "'.")
    return
  end

  -- Only one row can ever be in edit mode at a time (see StartEditingRow),
  -- so every other row's identity is its own already-saved one - safe to
  -- check against directly rather than some other row's in-progress text.
  local lowerKey = name:lower() .. "|" .. realm:lower()
  for _, other in ipairs(workingRows) do
    if other ~= row and other.saved then
      local otherKey = other.saved.name:lower() .. "|" .. other.saved.realm:lower()
      if otherKey == lowerKey then
        print(PREFIX .. "Can't save " .. name .. "-" .. realm .. " - a different entry already uses that name and realm.")
        return
      end
    end
  end

  -- A rename (name or realm changed from what this row was last saved
  -- with) leaves the old key behind in the database unless it's explicitly
  -- removed too - upserting only ever adds/updates the new key.
  if row.saved and (row.saved.name:lower() ~= name:lower() or row.saved.realm:lower() ~= realm:lower()) then
    ns.RemovePlayerDbEntry(row.saved.name, row.saved.realm)
  end
  ns.UpsertPlayerDbEntry(name, realm, row.class or false)

  row.name, row.realm = name, realm
  row.saved = { name = name, realm = realm, class = row.class }
  row.editing = false
  editingRow = nil

  ns.FireStateChanged()
  print(PREFIX .. "Saved " .. name .. "-" .. realm .. ".")
  RenderRows()
end

local function ClassDisplayName(classFile)
  if not classFile then return "" end
  return CLASS_LIST[classFile] or classFile
end

local function ApplyClassColor(label, classFile)
  local r, g, b = ns.GetClassColor(classFile)
  if r then
    label:SetColor(r, g, b)
  end
end

-- needle is already trimmed/lowercased by the caller. Plain (non-pattern)
-- find, so a search string containing Lua pattern characters (e.g. "-" in a
-- realm name) is matched literally instead of erroring or matching oddly.
local function RowMatchesSearch(row, needle)
  local name = (row.name or ""):lower()
  local realm = (row.realm or ""):lower()
  local class = ClassDisplayName(row.class):lower()
  return name:find(needle, 1, true) ~= nil
    or realm:find(needle, 1, true) ~= nil
    or class:find(needle, 1, true) ~= nil
end

-- Same background technique as UI_Main.lua's own player list (PrepareRow) -
-- a plain BACKGROUND-layer texture, black at 0.5 alpha (bumped up from that
-- list's own 0.18 - this window's tooltip-style backdrop reads darker, so
-- the lighter value was too faint to see against it) - reused here for
-- visual consistency with the rest of the addon otherwise. Cached on the
-- frame itself (rather than created fresh every render) and just
-- shown/hidden after that, same as PrepareRow's own riRowBg - this exact
-- raw frame is very likely to get reused across this window's own
-- re-renders (AceGUI recycles "SimpleGroup" widgets by type - see
-- FinalizeRow's own comment below), so this avoids piling up a fresh
-- throwaway texture on it every single time.
local function ApplyRowBackground(frame, show)
  if not frame.miaRowBg then
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    if bg.SetColorTexture then
      bg:SetColorTexture(0, 0, 0, 0.5)
    else
      bg:SetTexture(1, 1, 1, 1)
      bg:SetVertexColor(0, 0, 0, 0.5)
    end
    frame.miaRowBg = bg
  end
  frame.miaRowBg:SetShown(show)
end

-- Parents a native remove icon directly onto rowGroup.frame (not added via
-- :AddChild - see ROW_RELWIDTHS' own comment for why), applies the striped
-- background above, and wires up cleanup for both so neither can leak into
-- some other window's SimpleGroup later. AceGUI recycles "SimpleGroup"
-- widgets by type across this entire addon (every row here is a fresh one
-- each render - see RenderRows/CreateRow), and HookScript-free plain child
-- frames/textures parented this way aren't reachable through AceGUI's own
-- ReleaseChildren, so without this they'd still be sitting there the next
-- time this exact recycled frame gets handed out as some unrelated
-- row/spacer/button elsewhere - same reasoning UI_Main.lua's CreateBenchRow
-- documents for its own bench-row invite button.
--
-- actionBtn is the row's own Edit/Save button, already added - anchoring the
-- remove icon to its frame (rather than the row's own right edge) is what
-- keeps it sitting right next to it instead of out at the row's full width,
-- since ROW_RELWIDTHS.action only fills a fraction of that width. isEven
-- controls the striped background - see RenderRows for how it's computed.
local function FinalizeRow(rowGroup, row, actionBtn, isEven)
  local removeBtn = CreateRemoveButton(rowGroup.frame, function()
    RemoveRow(row)
  end)
  removeBtn:SetPoint("LEFT", actionBtn.frame, "RIGHT", 6, 0)
  rowGroup.frame.miaRemoveBtn = removeBtn

  ApplyRowBackground(rowGroup.frame, isEven)

  -- Nil-checked because this same widget can later be handed out to a
  -- totally different window (AceGUI recycles "SimpleGroup" by type
  -- addon-wide, and never clears widget.OnRelease when it goes back into
  -- the pool - see this function's own comment above) - when that other
  -- window eventually releases it, this same handler fires again, and by
  -- then miaRemoveBtn is already nil (that window never set it).
  rowGroup.OnRelease = function(self)
    if self.frame.miaRemoveBtn then
      self.frame.miaRemoveBtn:Hide()
      self.frame.miaRemoveBtn:SetParent(UIParent)
      self.frame.miaRemoveBtn = nil
    end
    if self.frame.miaRowBg then
      self.frame.miaRowBg:Hide()
    end
  end
end

local function CreateEditRow(row, isEven)
  local rowGroup = AceGUI:Create("SimpleGroup")
  rowGroup:SetLayout("Flow")
  rowGroup:SetFullWidth(true)
  rowGroup.noAutoHeight = true
  rowGroup:SetHeight(ROW_HEIGHT)

  local nameBox = AceGUI:Create("EditBox")
  nameBox:SetRelativeWidth(ROW_RELWIDTHS.name)
  nameBox:DisableButton(true)
  nameBox:SetText(row.name)
  nameBox:SetCallback("OnTextChanged", function(widget, event, value)
    row.name = value
  end)
  rowGroup:AddChild(nameBox)

  local realmBox = AceGUI:Create("EditBox")
  realmBox:SetRelativeWidth(ROW_RELWIDTHS.realm)
  realmBox:DisableButton(true)
  realmBox:SetText(row.realm)
  realmBox:SetCallback("OnTextChanged", function(widget, event, value)
    row.realm = value
  end)
  rowGroup:AddChild(realmBox)

  local classDropdown = AceGUI:Create("Dropdown")
  classDropdown:SetRelativeWidth(ROW_RELWIDTHS.class)
  classDropdown:SetList(CLASS_LIST, CLASS_ORDER)
  classDropdown:SetValue(row.class or "")
  classDropdown:SetCallback("OnValueChanged", function(widget, event, value)
    row.class = (value ~= "" and value) or nil
  end)
  rowGroup:AddChild(classDropdown)

  local saveBtn = AceGUI:Create("Button")
  saveBtn:SetText("Save")
  saveBtn:SetRelativeWidth(ROW_RELWIDTHS.action)
  ns.ShrinkButtonFont(saveBtn)
  saveBtn:SetCallback("OnClick", function()
    SaveRow(row)
  end)
  rowGroup:AddChild(saveBtn)

  FinalizeRow(rowGroup, row, saveBtn, isEven)

  return rowGroup
end

local function CreateDisplayRow(row, isEven)
  local rowGroup = AceGUI:Create("SimpleGroup")
  rowGroup:SetLayout("Flow")
  rowGroup:SetFullWidth(true)
  rowGroup.noAutoHeight = true
  rowGroup:SetHeight(ROW_HEIGHT)

  local nameLabel = AceGUI:Create("Label")
  nameLabel:SetRelativeWidth(ROW_RELWIDTHS.name)
  nameLabel:SetText(row.name)
  ns.PadLabelVertically(nameLabel, ROW_HEIGHT)
  ApplyClassColor(nameLabel, row.class)
  rowGroup:AddChild(nameLabel)

  local realmLabel = AceGUI:Create("Label")
  realmLabel:SetRelativeWidth(ROW_RELWIDTHS.realm)
  realmLabel:SetText(row.realm)
  ns.PadLabelVertically(realmLabel, ROW_HEIGHT)
  ApplyClassColor(realmLabel, row.class)
  rowGroup:AddChild(realmLabel)

  local classLabel = AceGUI:Create("Label")
  classLabel:SetRelativeWidth(ROW_RELWIDTHS.class)
  classLabel:SetText(ClassDisplayName(row.class))
  ns.PadLabelVertically(classLabel, ROW_HEIGHT)
  ApplyClassColor(classLabel, row.class)
  rowGroup:AddChild(classLabel)

  local editBtn = AceGUI:Create("Button")
  editBtn:SetText("Edit")
  editBtn:SetRelativeWidth(ROW_RELWIDTHS.action)
  ns.ShrinkButtonFont(editBtn)
  editBtn:SetCallback("OnClick", function()
    StartEditingRow(row)
  end)
  rowGroup:AddChild(editBtn)

  FinalizeRow(rowGroup, row, editBtn, isEven)

  return rowGroup
end

local function CreateRow(row, isEven)
  if row.editing then
    return CreateEditRow(row, isEven)
  end
  return CreateDisplayRow(row, isEven)
end

-- Below 3 characters, the search box doesn't filter at all (matches
-- everything) - short fragments are more likely to be "still typing" than a
-- meaningful search, and would otherwise churn the full row rebuild below on
-- every single keystroke of a longer search for comparatively little
-- narrowing benefit.
local MIN_SEARCH_CHARS = 3

RenderRows = function()
  local needle = ns.Trim(searchText or ""):lower()
  local filtering = #ns.Utf8Chars(needle) >= MIN_SEARCH_CHARS
  -- Kept in sync here (the one place that actually knows the current
  -- filtered/unfiltered state), rather than in the search box's
  -- OnTextChanged callback, so it can't drift out of sync with reality
  -- whenever something other than typing triggers a re-render (Remove,
  -- Fetch Guild Info, Save, Add Player).
  wasFiltering = filtering

  -- ReleaseChildren below snaps the scroll position back to the top on its
  -- own (rebuilding the content resets it) - every edit/save/remove/filter
  -- goes through this same function, so without saving and restoring it
  -- here, scrolling down and editing or saving a single row would bounce
  -- the whole list back to the top every time. Same fix UI_Main.lua already
  -- uses for its own player list (see RefreshPlayerList).
  local savedScroll = scroll.localstatus and scroll.localstatus.scrollvalue or 0

  scroll:ReleaseChildren()
  -- Counts only rows actually being shown, not each row's position in the
  -- underlying (possibly filtered-down) data - so the striping still comes
  -- out as a clean alternating pattern based on what's actually on screen,
  -- rather than having gaps in it wherever a filtered-out row would've sat.
  local visibleCount = 0
  for _, row in ipairs(workingRows) do
    if not filtering or RowMatchesSearch(row, needle) then
      visibleCount = visibleCount + 1
      scroll:AddChild(CreateRow(row, visibleCount % 2 == 0))
    end
  end

  scroll:DoLayout()
  scroll:SetScroll(savedScroll)
end

-- Fills any row with a blank class from the group/guild class scan (see
-- ns.GetClassMap in MakeIdiotsAppear.lua). A row that's already saved gets
-- the fetched class persisted immediately (its name/realm identity is
-- already committed, so there's nothing to stage); a row that's still being
-- edited and was never saved only gets its local class field/dropdown
-- updated - there's no database identity to persist against yet, so it'll
-- go out with that row's own Save. Returns how many rows it filled.
local function FillMissingClasses()
  local classMap = ns.GetClassMap()
  local filled = 0
  for _, row in ipairs(workingRows) do
    if not row.class then
      local name = ns.Trim(row.name or "")
      local realm = ns.Trim(row.realm or "")
      if name ~= "" and realm ~= "" then
        local found = classMap[(name .. "-" .. realm):lower()]
        if found then
          row.class = found
          if row.saved then
            ns.UpsertPlayerDbEntry(row.saved.name, row.saved.realm, found)
            row.saved.class = found
          end
          filled = filled + 1
        end
      end
    end
  end
  if filled > 0 then
    ns.FireStateChanged()
    RenderRows()
  end
  return filled
end

local function BuildPlayerDbFrame()
  local f = AceGUI:Create("Frame")
  ns.ApplyTooltipWindowStyle(f)
  f:SetTitle("Player Database")
  f:SetStatusText("")
  f:SetLayout("Flow")
  f:EnableResize(false)

  MakeIdiotsAppearDB.windowStatus.playerdb = MakeIdiotsAppearDB.windowStatus.playerdb or {}
  f:SetStatusTable(MakeIdiotsAppearDB.windowStatus.playerdb)
  -- AceGUI's Frame widget anchors its "Close" button to the window's own
  -- BOTTOMRIGHT (see AceGUIContainer-Frame.lua's Constructor), not inside
  -- the scrollable content area - so the content stack (toolbar + search box
  -- + header + scroll, ~514px) needs real clearance below it or the scroll
  -- area overlaps that button. 620 leaves ~60px of margin below the content
  -- - confirmed enough to clear the Close button without excess empty space.
  f:SetWidth(620)
  f:SetHeight(620)
  f:SetCallback("OnClose", function(widget)
    AceGUI:Release(widget)
    playerDbFrame = nil
    scroll = nil
  end)

  ----------------------------------------------------------------
  -- Toolbar
  ----------------------------------------------------------------

  local toolbar = AceGUI:Create("SimpleGroup")
  toolbar:SetLayout("Flow")
  toolbar:SetFullWidth(true)
  f:AddChild(toolbar)

  local addBtn = AceGUI:Create("Button")
  addBtn:SetText("Add Player")
  addBtn:SetWidth(150)
  ns.ShrinkButtonFont(addBtn)
  addBtn:SetCallback("OnClick", function()
    local row = { name = "", realm = "", class = nil, editing = false, saved = nil }
    -- Pinned to the top rather than sorted into its (empty-name) place -
    -- keeps a just-added row immediately visible instead of requiring a
    -- scroll to find it.
    table.insert(workingRows, 1, row)
    StartEditingRow(row)
    -- StartEditingRow's RenderRows just restored whatever scroll position
    -- was active before this click - if that was scrolled down, the row
    -- just pinned to the top wouldn't actually be visible without an extra
    -- manual scroll. Force it back to the top afterward so a new row is
    -- always immediately visible to start typing into.
    scroll:SetScroll(0)
  end)
  toolbar:AddChild(addBtn)

  local fetchBtn = AceGUI:Create("Button")
  fetchBtn:SetText("Fetch Guild Info")
  fetchBtn:SetWidth(150)
  ns.ShrinkButtonFont(fetchBtn)
  fetchBtn:SetCallback("OnClick", function()
    ns.RequestGuildRoster()
    local filled = FillMissingClasses()
    if filled > 0 then
      print(PREFIX .. "Filled class for " .. filled .. " player(s) from the guild roster.")
    else
      print(PREFIX .. "No missing classes matched the guild roster yet.")
    end
    -- Guild roster data can still be loading when this button is first
    -- clicked (RequestGuildRoster just kicks off the fetch) - one more pass
    -- shortly after catches anyone who wasn't cached yet. Guarded in case
    -- the window's since been closed.
    C_Timer.After(1.5, function()
      if not playerDbFrame then return end
      local more = FillMissingClasses()
      if more > 0 then
        print(PREFIX .. "Filled class for " .. more .. " more player(s) from the guild roster.")
      end
    end)
  end)
  toolbar:AddChild(fetchBtn)

  ----------------------------------------------------------------
  -- Search box
  ----------------------------------------------------------------

  local searchBox = AceGUI:Create("EditBox")
  searchBox:SetLabel("Search (name, realm, or class - 3+ characters)")
  searchBox:SetFullWidth(true)
  searchBox:DisableButton(true)
  searchBox:SetText(searchText)
  searchBox:SetCallback("OnTextChanged", function(widget, event, value)
    searchText = value
    local needle = ns.Trim(searchText or ""):lower()
    local nowFiltering = #ns.Utf8Chars(needle) >= MIN_SEARCH_CHARS
    -- Skip the rebuild entirely while under the threshold and nothing is
    -- actually changing on screen (still showing everyone, same as the
    -- keystroke before) - this is what keeps typing the first couple
    -- characters of a search from re-rendering the full, unfiltered list on
    -- every single keypress. RenderRows itself updates wasFiltering once it
    -- actually runs.
    if nowFiltering or wasFiltering then
      RenderRows()
    end
  end)
  f:AddChild(searchBox)

  ----------------------------------------------------------------
  -- Header row
  ----------------------------------------------------------------

  local headerRow = AceGUI:Create("SimpleGroup")
  headerRow:SetLayout("Flow")
  -- Deliberately not SetFullWidth(true). The grid below lives inside a
  -- ScrollFrame, whose content area narrows by a fixed 20px the moment its
  -- scrollbar actually appears - i.e. once there are more rows than fit on
  -- screen (see AceGUIContainer-ScrollFrame.lua's FixScroll,
  -- SetPoint("BOTTOMRIGHT", -20, 0)) - a near-certainty for this window in
  -- practice (a guild roster easily exceeds a screenful of names). This
  -- header row's cells are relative-width, computed against whatever
  -- container they sit in - if the header spanned the window's full content
  -- width while the rows below compute against that already-narrowed
  -- scroll content, the two would drift out of alignment right when a
  -- scrollbar shows up. AceGUI's Frame widget insets its content area by
  -- 17px on each side (AceGUIContainer-Frame.lua's Constructor), so at this
  -- window's fixed 620px width (EnableResize(false), so this never
  -- changes) the content area is 620 - 17*2 = 586px; matching the scroll's
  -- own narrowed width means giving the header that same 586 - 20 = 566px
  -- instead.
  headerRow:SetWidth(566)
  f:AddChild(headerRow)

  ApplyRowBackground(headerRow.frame, true)
  headerRow.OnRelease = function(self)
    if self.frame.miaRowBg then
      self.frame.miaRowBg:Hide()
    end
  end

  local nameHeader = AceGUI:Create("Label")
  nameHeader:SetRelativeWidth(ROW_RELWIDTHS.name)
  nameHeader:SetText("Name")
  headerRow:AddChild(nameHeader)

  local realmHeader = AceGUI:Create("Label")
  realmHeader:SetRelativeWidth(ROW_RELWIDTHS.realm)
  realmHeader:SetText("Realm")
  headerRow:AddChild(realmHeader)

  local classHeader = AceGUI:Create("Label")
  classHeader:SetRelativeWidth(ROW_RELWIDTHS.class)
  classHeader:SetText("Class")
  headerRow:AddChild(classHeader)

  local actionHeader = AceGUI:Create("Label")
  actionHeader:SetRelativeWidth(ROW_RELWIDTHS.action)
  actionHeader:SetText("")
  headerRow:AddChild(actionHeader)

  ----------------------------------------------------------------
  -- Grid
  ----------------------------------------------------------------

  scroll = AceGUI:Create("ScrollFrame")
  scroll:SetLayout("List")
  scroll:SetFullWidth(true)
  scroll:SetHeight(420)
  f:AddChild(scroll)

  LoadWorkingRows()
  RenderRows()

  return f
end

function ns.ShowPlayerDbFrame()
  ns.EnsureDB()
  if playerDbFrame then
    playerDbFrame.frame:Show()
    LoadWorkingRows()
    RenderRows()
    return
  end

  playerDbFrame = BuildPlayerDbFrame()
end
