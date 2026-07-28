-- UI_PlayerDB.lua
-- Player Database window: view/add/remove/edit every learned Name-Realm-Class
-- entry from MakeIdiotsAppearDB.masterRoster as a sortable grid. Built with
-- AceGUI-3.0. Opened only via "/mia playerdb" (see UI_Main.lua's slash
-- handler) - not linked from any other window yet.

local ADDON_NAME, ns = ...
local PREFIX = ns.PREFIX
local AceGUI = LibStub("AceGUI-3.0")

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

local ROW_RELWIDTHS = { name = 0.28, realm = 0.28, class = 0.24, remove = 0.14 }

local playerDbFrame = nil
local scroll = nil
local nameHeader, realmHeader, classHeader

-- Edits are staged here, not written to MakeIdiotsAppearDB until "Save
-- Changes" is clicked - closing the window without saving just discards
-- this. Each row is {name=, realm=, class=classFileOrNil, origName=,
-- origRealm=}; origName/origRealm are nil for a row added via "Add Player"
-- this session, and otherwise record what the entry looked like when this
-- window was (re)opened, so Save can tell a rename from a fresh add and
-- remove the old key it superseded (see the Save button below).
local workingRows = {}

-- {name=, realm=} pairs explicitly removed via a row's Remove button this
-- session, applied on Save. A brand-new (never-saved) row removed this way
-- just disappears from workingRows with nothing queued here.
local pendingRemovals = {}

local sortColumn = "name"
local sortAscending = true

local RenderRows

local function LoadWorkingRows()
  workingRows = {}
  for _, entry in ipairs(ns.GetAllPlayerDbEntries()) do
    table.insert(workingRows, {
      name = entry.name,
      realm = entry.realm,
      class = entry.class,
      origName = entry.name,
      origRealm = entry.realm,
    })
  end
  pendingRemovals = {}
end

local function RemoveRow(row)
  if row.origName then
    table.insert(pendingRemovals, { name = row.origName, realm = row.origRealm })
  end
  for i, r in ipairs(workingRows) do
    if r == row then
      table.remove(workingRows, i)
      break
    end
  end
  RenderRows()
end

local function ClassDisplayName(classFile)
  if not classFile then return "" end
  return CLASS_LIST[classFile] or classFile
end

local function CompareRows(a, b)
  local av, bv
  if sortColumn == "class" then
    av, bv = ClassDisplayName(a.class):lower(), ClassDisplayName(b.class):lower()
  else
    av, bv = (a[sortColumn] or ""):lower(), (b[sortColumn] or ""):lower()
  end

  if av == bv then
    -- Tiebreaker so rows with equal sort keys don't visibly reshuffle
    -- between re-renders.
    return (a.name or ""):lower() < (b.name or ""):lower()
  end
  if sortAscending then
    return av < bv
  else
    return av > bv
  end
end

local function UpdateHeaderLabel(header, columnKey, baseText)
  if sortColumn == columnKey then
    header:SetText(baseText .. (sortAscending and "  \226\150\178" or "  \226\150\188"))
  else
    header:SetText(baseText)
  end
end

local function OnHeaderClick(columnKey)
  if sortColumn == columnKey then
    sortAscending = not sortAscending
  else
    sortColumn = columnKey
    sortAscending = true
  end
  RenderRows()
end

local function CreateRow(row)
  local rowGroup = AceGUI:Create("SimpleGroup")
  rowGroup:SetLayout("Flow")
  rowGroup:SetFullWidth(true)

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

  local removeBtn = AceGUI:Create("Button")
  removeBtn:SetText("Remove")
  removeBtn:SetRelativeWidth(ROW_RELWIDTHS.remove)
  ns.ShrinkButtonFont(removeBtn)
  removeBtn:SetCallback("OnClick", function()
    RemoveRow(row)
  end)
  rowGroup:AddChild(removeBtn)

  return rowGroup
end

RenderRows = function()
  table.sort(workingRows, CompareRows)
  UpdateHeaderLabel(nameHeader, "name", "Name")
  UpdateHeaderLabel(realmHeader, "realm", "Realm")
  UpdateHeaderLabel(classHeader, "class", "Class")

  scroll:ReleaseChildren()
  for _, row in ipairs(workingRows) do
    scroll:AddChild(CreateRow(row))
  end
end

-- Fills any row with a blank class from the group/guild class scan (see
-- ns.GetClassMap in MakeIdiotsAppear.lua) - only touches the working copy,
-- same as every other edit here, so Save Changes still has to be clicked
-- to persist it. Returns how many rows it filled.
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
          filled = filled + 1
        end
      end
    end
  end
  if filled > 0 then
    RenderRows()
  end
  return filled
end

local function SaveChanges()
  local validRows, errors, removeKeys, seen = {}, {}, {}, {}

  for _, key in ipairs(pendingRemovals) do
    table.insert(removeKeys, key)
  end

  for _, row in ipairs(workingRows) do
    local rawName = row.name or ""
    local label = rawName ~= "" and rawName or "(blank)"
    local name = ns.ProperCase(ns.Trim(rawName))
    local realmInput = ns.Trim(row.realm or "")
    local realm = ns.NormalizeRealmName(realmInput)

    if not ns.IsValidPlayerDbName(name) then
      table.insert(errors, label .. " - invalid name (2-12 letters, no character repeated 3+ times in a row)")
    elseif not realm then
      table.insert(errors, label .. " - unrecognized realm '" .. (realmInput ~= "" and realmInput or "(blank)") .. "'")
    else
      local key = name:lower() .. "|" .. realm:lower()
      if seen[key] then
        table.insert(errors, name .. "-" .. realm .. " - duplicate entry, skipped")
      else
        seen[key] = true
        -- A rename (name or realm changed from what this row was loaded
        -- with) leaves the old name+realm key behind in the DB unless we
        -- explicitly remove it too - upserting only ever adds/updates the
        -- new key.
        if row.origName and (row.origName:lower() ~= name:lower() or row.origRealm:lower() ~= realm:lower()) then
          table.insert(removeKeys, { name = row.origName, realm = row.origRealm })
        end
        table.insert(validRows, { name = name, realm = realm, class = row.class })
      end
    end
  end

  for _, key in ipairs(removeKeys) do
    ns.RemovePlayerDbEntry(key.name, key.realm)
  end
  for _, row in ipairs(validRows) do
    ns.UpsertPlayerDbEntry(row.name, row.realm, row.class or false)
  end

  local msg = PREFIX .. "Saved " .. #validRows .. " player" .. (#validRows == 1 and "" or "s") .. "."
  if #errors > 0 then
    msg = msg .. " Skipped " .. #errors .. ": " .. table.concat(errors, "; ")
  end
  print(msg)

  ns.FireStateChanged()
  LoadWorkingRows()
  RenderRows()
end

local function BuildPlayerDbFrame()
  local f = AceGUI:Create("Frame")
  ns.ApplyTooltipWindowStyle(f)
  ns.CloseWindowOnEscape(f)
  f:SetTitle("Player Database")
  f:SetStatusText("")
  f:SetLayout("Flow")
  f:EnableResize(false)

  MakeIdiotsAppearDB.windowStatus.playerdb = MakeIdiotsAppearDB.windowStatus.playerdb or {}
  f:SetStatusTable(MakeIdiotsAppearDB.windowStatus.playerdb)
  f:SetWidth(620)
  f:SetHeight(560)
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
    table.insert(workingRows, { name = "", realm = "", class = nil })
    RenderRows()
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

  local saveBtn = AceGUI:Create("Button")
  saveBtn:SetText("Save Changes")
  saveBtn:SetWidth(150)
  ns.ShrinkButtonFont(saveBtn)
  saveBtn:SetCallback("OnClick", SaveChanges)
  toolbar:AddChild(saveBtn)

  ----------------------------------------------------------------
  -- Header row
  ----------------------------------------------------------------

  local headerRow = AceGUI:Create("SimpleGroup")
  headerRow:SetLayout("Flow")
  headerRow:SetFullWidth(true)
  f:AddChild(headerRow)

  nameHeader = AceGUI:Create("InteractiveLabel")
  nameHeader:SetRelativeWidth(ROW_RELWIDTHS.name)
  nameHeader:SetText("Name")
  nameHeader:SetCallback("OnClick", function() OnHeaderClick("name") end)
  headerRow:AddChild(nameHeader)

  realmHeader = AceGUI:Create("InteractiveLabel")
  realmHeader:SetRelativeWidth(ROW_RELWIDTHS.realm)
  realmHeader:SetText("Realm")
  realmHeader:SetCallback("OnClick", function() OnHeaderClick("realm") end)
  headerRow:AddChild(realmHeader)

  classHeader = AceGUI:Create("InteractiveLabel")
  classHeader:SetRelativeWidth(ROW_RELWIDTHS.class)
  classHeader:SetText("Class")
  classHeader:SetCallback("OnClick", function() OnHeaderClick("class") end)
  headerRow:AddChild(classHeader)

  local removeHeader = AceGUI:Create("Label")
  removeHeader:SetRelativeWidth(ROW_RELWIDTHS.remove)
  removeHeader:SetText("")
  headerRow:AddChild(removeHeader)

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
