-- UI_Main.lua
-- Main window: player list (left) + options panel (right). Built with AceGUI-3.0.

local ADDON_NAME, ns = ...
local PREFIX = ns.PREFIX
local Engine = ns.Engine
local AceGUI = LibStub("AceGUI-3.0")

local STATUS_COLORS = {
  ["In Group"] = { 0.4, 0.8, 1 },
  ["Pending Invite"] = { 1, 0.82, 0 },
  ["Online"] = { 0.2, 1, 0.2 },
  ["Offline"] = { 0.6, 0.6, 0.6 },
  ["Not In List"] = { 1, 0.3, 0.3 },
}
local DEFAULT_STATUS_COLOR = { 0.8, 0.8, 0.8 }

-- Both the name and status columns use this - 2pt smaller than
-- ns.GetChatFont's own default, since the full size wrapped long names like
-- "Goobygoobydo-OldBlanchy" onto a second line within the name column's
-- current width.
local ROW_FONT_FILE, ROW_FONT_HEIGHT, ROW_FONT_FLAGS = ns.GetChatFont(-2)

-- Target height for ns.PadLabelVertically (see there for why a fixed
-- height instead of "current height + padding") - 2px of padding above and
-- below the name/status columns' text, measured once here via a disposable
-- scratch FontString rather than read back from a row's own (recycled)
-- Label widget.
local ROW_VERTICAL_PADDING = 2
local ROW_LABEL_HEIGHT
do
  local scratch = UIParent:CreateFontString(nil, "BACKGROUND")
  scratch:SetFont(ROW_FONT_FILE, ROW_FONT_HEIGHT, ROW_FONT_FLAGS)
  scratch:SetText("Sample")
  ROW_LABEL_HEIGHT = scratch:GetHeight() + ROW_VERTICAL_PADDING * 2
end

-- While invites are active, the roster half of the list (not the "extras"
-- callout above it) is regrouped so players still worth inviting float to
-- the top: unknown status first, then known-offline, then online/pending
-- together (a pending invite is just an online player mid-invite, so it
-- shouldn't jump to its own tier), with everyone already in the group
-- pushed to the bottom. Ties keep the roster's own order.
local ACTIVE_STATUS_SORT_RANK = {
  ["-"] = 1,
  ["Offline"] = 2,
  ["Online"] = 3,
  ["Pending Invite"] = 3,
  ["In Group"] = 4,
}

local mainFrame = nil
local leftGroup, playerScroll, engineStatusLabel, countdownLabel, startBtn
local lootThresholdBtn, lootThresholdDropdown
local benchLabel, benchScroll

local ROW_GAP = 2

-- How many bench rows benchScroll always reserves room for (see
-- RefreshPlayerList) - it scrolls, same as playerScroll, if the roster
-- actually has more players past the group size than this.
local BENCH_ROWS = 5

-- BENCH_ROWS*(ROW_LABEL_HEIGHT+ROW_GAP) is the exact math for 5 rows, but
-- came up just short of actually showing all 5 in practice (some other
-- padding this doesn't account for) - the extra 10px covers that gap.
-- Shared between BuildMainFrame (benchScroll's own SetHeight) and
-- RefreshPlayerList (how much of PLAYER_AREA_HEIGHT playerScroll gives up)
-- so the two stay in sync.
local BENCH_SCROLL_HEIGHT = BENCH_ROWS * (ROW_LABEL_HEIGHT + ROW_GAP) + 10
local BENCH_BLOCK_HEIGHT = ROW_LABEL_HEIGHT + BENCH_SCROLL_HEIGHT

-- Total height playerScroll gets when there's no bench to show (roster
-- size <= group size) - leftGroup's own PANEL_HEIGHT (420, see
-- BuildMainFrame) minus InlineGroup's ~40px title/border chrome (see
-- AceGUIContainer-InlineGroup.lua's LayoutFinished) minus headerRow's own
-- 28px (see BuildMainFrame), plus another 10px that turned out to still be
-- spare even at that. When a bench needs to be shown instead, this gets
-- split between playerScroll and BENCH_BLOCK_HEIGHT (see RefreshPlayerList)
-- rather than playerScroll keeping all of it.
local PLAYER_AREA_HEIGHT = 362

-- AceGUI's "List" layout (used site-wide, including this scroll list)
-- stacks children with zero gap, hardcoded in the vendored library - rather
-- than patch that shared file, each row is made ROW_GAP px taller than its
-- actual content, and the background texture stops short of that extra
-- strip, so the gap shows up as a visible break between rows.
--
-- "SimpleGroup" is a shared widget type used everywhere in this addon, not
-- just for these rows - spacers, button rows, etc. in every other window
-- are also SimpleGroups, and AceGUI recycles the same underlying instances
-- across ALL of them from one shared pool. So the LayoutFinished patch and
-- the background texture must be undone in OnRelease (fired when AceGUI
-- takes the widget back, e.g. via ReleaseChildren) - otherwise a frame that
-- once served as a player row can get handed out later as an unrelated
-- spacer/button row elsewhere and still show the leftover background.
local function PrepareRow(row)
  if not row.riPrepared then
    row.riPrepared = true

    local originalLayoutFinished = row.LayoutFinished
    row.LayoutFinished = function(self, width, height)
      originalLayoutFinished(self, width, (height or 0) + ROW_GAP)
    end

    if not row.frame.riRowBg then
      local bg = row.frame:CreateTexture(nil, "BACKGROUND")
      bg:SetPoint("TOPLEFT", row.frame, "TOPLEFT", 0, 0)
      bg:SetPoint("BOTTOMRIGHT", row.frame, "BOTTOMRIGHT", 0, ROW_GAP)
      if bg.SetColorTexture then
        bg:SetColorTexture(0, 0, 0, 0.18)
      else
        bg:SetTexture(1, 1, 1, 1)
        bg:SetVertexColor(0, 0, 0, 0.18)
      end
      row.frame.riRowBg = bg
    end

    row.OnRelease = function(self)
      self.frame.riRowBg:Hide()
      self.LayoutFinished = originalLayoutFinished
      self.riPrepared = nil
    end
  end

  row.frame.riRowBg:Show()
end

local function CreateRow(fullName, status, classMap)
  local row = AceGUI:Create("SimpleGroup")
  row:SetLayout("Flow")
  row:SetFullWidth(true)
  PrepareRow(row)

  -- Both columns below are deliberately left a hair under 0.65/0.35 (rather
  -- than summing to exactly 1.0) - AceGUI's "Flow" layout (used within this
  -- row) can wrap a child to a new row if pixel-rounding pushes the combined
  -- width a fraction over the row's own width (see UI_Rosters.lua's
  -- leftGroup for the same reasoning in more detail).
  local nameLabel = AceGUI:Create("Label")
  nameLabel:SetRelativeWidth(0.64)
  nameLabel:SetFont(ROW_FONT_FILE, ROW_FONT_HEIGHT, ROW_FONT_FLAGS)
  nameLabel:SetText(fullName)
  ns.PadLabelVertically(nameLabel, ROW_LABEL_HEIGHT)

  local classFile = ns.LookupByFullOrName(classMap, fullName)
  local classR, classG, classB = ns.GetClassColor(classFile)
  if classR then
    nameLabel:SetColor(classR, classG, classB)
  end

  local color = STATUS_COLORS[status] or DEFAULT_STATUS_COLOR

  local statusLabel = AceGUI:Create("Label")
  statusLabel:SetRelativeWidth(0.34)
  statusLabel:SetFont(ROW_FONT_FILE, ROW_FONT_HEIGHT, ROW_FONT_FLAGS)
  statusLabel:SetText(status)
  statusLabel:SetColor(unpack(color))
  ns.PadLabelVertically(statusLabel, ROW_LABEL_HEIGHT)

  row:AddChild(nameLabel)
  row:AddChild(statusLabel)
  return row
end

-- Same row look as CreateRow (same PrepareRow background/gap treatment,
-- same font/color rules for name and status), but narrower to leave room
-- for a manual invite button on the right - bench players are deliberately
-- left out of the automated invite run (see the startBtn callback in
-- BuildMainFrame), so this is the only way to get one of them invited.
local function CreateBenchRow(fullName, status, classMap)
  local row = AceGUI:Create("SimpleGroup")
  row:SetLayout("Flow")
  row:SetFullWidth(true)
  PrepareRow(row)

  -- The three widths below (0.6 + 0.26 + 0.12 = 0.98) are deliberately
  -- left under 1.0 for the same pixel-rounding reason as CreateRow's own
  -- two columns, but closer to it than that - inviteBtn is small and needs
  -- to sit close to the row's actual right edge, not just wherever
  -- statusLabel happens to end.
  local nameLabel = AceGUI:Create("Label")
  nameLabel:SetRelativeWidth(0.6)
  nameLabel:SetFont(ROW_FONT_FILE, ROW_FONT_HEIGHT, ROW_FONT_FLAGS)
  nameLabel:SetText(fullName)
  ns.PadLabelVertically(nameLabel, ROW_LABEL_HEIGHT)

  local classFile = ns.LookupByFullOrName(classMap, fullName)
  local classR, classG, classB = ns.GetClassColor(classFile)
  if classR then
    nameLabel:SetColor(classR, classG, classB)
  end

  local color = STATUS_COLORS[status] or DEFAULT_STATUS_COLOR

  local statusLabel = AceGUI:Create("Label")
  statusLabel:SetRelativeWidth(0.26)
  statusLabel:SetFont(ROW_FONT_FILE, ROW_FONT_HEIGHT, ROW_FONT_FLAGS)
  statusLabel:SetText(status)
  statusLabel:SetColor(unpack(color))
  ns.PadLabelVertically(statusLabel, ROW_LABEL_HEIGHT)

  local inviteBtn = AceGUI:Create("Button")
  inviteBtn:SetRelativeWidth(0.12)
  inviteBtn:SetHeight(ROW_LABEL_HEIGHT)
  inviteBtn:SetText("+")
  ns.ShrinkButtonFont(inviteBtn)
  -- AceGUI's Button hardcodes 15px of padding on each side between its text
  -- and the button's own edges (see AceGUIWidget-Button.lua's Constructor) -
  -- fine at its normal ~200px default width, but that's more padding than
  -- this whole button is wide, which is what actually made the "+" look
  -- shrunk/squeezed rather than the font itself getting smaller. Reaching
  -- into .text directly (exposed on the widget, same pattern as
  -- leftGroup.titletext elsewhere) to use a much smaller inset instead.
  inviteBtn.text:ClearAllPoints()
  inviteBtn.text:SetPoint("TOPLEFT", 4, -1)
  inviteBtn.text:SetPoint("BOTTOMRIGHT", -4, 1)
  inviteBtn:SetCallback("OnClick", function()
    ns.InvitePlayerManually(fullName)
  end)

  row:AddChild(nameLabel)
  row:AddChild(statusLabel)
  row:AddChild(inviteBtn)
  return row
end

-- Visual gap between the "still needs an invite" and "already in group"
-- clusters when the active-invite sort below is in effect. Deliberately not
-- a CreateRow() with blank text - this should read as empty space, not as a
-- nameless row with its own background strip.
local function CreateBlankSeparatorRow()
  local row = AceGUI:Create("SimpleGroup")
  row:SetFullWidth(true)
  row.noAutoHeight = true
  row:SetHeight(14)
  return row
end

local function RefreshPlayerList()
  -- AceGUI's ScrollFrame recalculates its scroll offset as content is torn
  -- down and rebuilt below, which tends to snap it back toward the top.
  -- Save the current position and force it back once the new rows are laid
  -- out, so a periodic refresh doesn't interrupt the user mid-scroll.
  local savedScroll = playerScroll.localstatus and playerScroll.localstatus.scrollvalue or 0

  local activeRoster = MakeIdiotsAppearDB.settings.activeRoster
  local list = activeRoster and MakeIdiotsAppearDB.rosters[activeRoster] or {}

  local groupSet = ns.GetGroupNameSet()
  local guildOnline = ns.GetGuildOnlineMap()
  local classMap = ns.GetClassMap()

  -- Computed once here (status includes an "In Group" check via
  -- LookupByFullOrName) and reused below for both the title's count and the
  -- roster rows themselves, rather than checking group membership again
  -- separately for each.
  local entries = {}
  local inGroupCount = 0
  for index, fullName in ipairs(list) do
    local status = ns.ComputeStatus(fullName, groupSet, guildOnline)
    if status == "In Group" then
      inGroupCount = inGroupCount + 1
    end
    table.insert(entries, { fullName = fullName, status = status, index = index })
  end
  leftGroup:SetTitle(string.format("Current Roster: %s (%d/%d)",
    activeRoster or "(none selected)", inGroupCount, #list))

  -- Anyone currently in the group who isn't part of this roster - shown
  -- above everyone else so an unexpected extra member stands out, no
  -- matter whether an invite pass has ever been started.
  local rosterKeys = {}
  for _, name in ipairs(list) do
    rosterKeys[name:lower()] = true
    rosterKeys[ns.NamePart(name)] = true
  end

  local ownFullName = ns.GetFullUnitName("player")
  local ownKey = ownFullName and ownFullName:lower()

  local extras = {}
  for key, fullName in pairs(groupSet) do
    if key ~= ownKey and not rosterKeys[key] and not rosterKeys[ns.NamePart(fullName)] then
      table.insert(extras, fullName)
    end
  end
  table.sort(extras)

  -- Bench = roster entries past the roster's own group size (see
  -- ns.GetRosterGroupSize) - split by original roster position, not by
  -- current status, so who's on the bench doesn't shuffle around whenever
  -- someone's status changes mid-invite.
  local groupSize = ns.GetRosterGroupSize(activeRoster)
  local mainEntries, benchEntries = {}, {}
  for _, entry in ipairs(entries) do
    if entry.index <= groupSize then
      table.insert(mainEntries, entry)
    else
      table.insert(benchEntries, entry)
    end
  end

  -- playerScroll keeps the whole panel to itself unless the roster actually
  -- has bench players, in which case the bench section below borrows
  -- BENCH_ROWS worth of rows plus its own caption from that same space (see
  -- PLAYER_AREA_HEIGHT/BENCH_ROWS' own comments) - raw Show()/Hide() on the
  -- bench widgets rather than leftGroup:AddChild/ReleaseChildren, same
  -- reasoning as RefreshLootThresholdControls above: leftGroup's own List
  -- layout only ever runs once (in BuildMainFrame), so nothing re-forces
  -- these back to shown, and playerScroll's SetHeight below reflows
  -- everything below it via Blizzard's own live frame anchors.
  if #benchEntries > 0 then
    playerScroll:SetHeight(PLAYER_AREA_HEIGHT - BENCH_BLOCK_HEIGHT)
    benchLabel.frame:Show()
    benchScroll.frame:Show()
  else
    playerScroll:SetHeight(PLAYER_AREA_HEIGHT)
    benchLabel.frame:Hide()
    benchScroll.frame:Hide()
  end

  playerScroll:ReleaseChildren()

  if #extras == 0 and #list == 0 then
    local emptyLabel = AceGUI:Create("Label")
    emptyLabel:SetFullWidth(true)
    emptyLabel:SetText(activeRoster and "This roster has no players yet." or "Select an active roster in Manage Rosters.")
    playerScroll:AddChild(emptyLabel)
  else
    for _, fullName in ipairs(extras) do
      playerScroll:AddChild(CreateRow(fullName, "Not In List", classMap))
    end

    local isInvitePhaseActive = Engine.running or Engine.starting

    if isInvitePhaseActive then
      table.sort(mainEntries, function(a, b)
        local rankA, rankB = ACTIVE_STATUS_SORT_RANK[a.status], ACTIVE_STATUS_SORT_RANK[b.status]
        if rankA ~= rankB then
          return rankA < rankB
        end
        return a.index < b.index
      end)
    end

    local previousInGroup = nil
    for _, entry in ipairs(mainEntries) do
      local inGroup = entry.status == "In Group"
      if isInvitePhaseActive and inGroup and previousInGroup == false then
        playerScroll:AddChild(CreateBlankSeparatorRow())
      end
      playerScroll:AddChild(CreateRow(entry.fullName, entry.status, classMap))
      previousInGroup = inGroup
    end
  end

  playerScroll:DoLayout()
  playerScroll:SetScroll(savedScroll)

  -- Always released/rebuilt (not just when shown) so no stale rows are left
  -- sitting around invisibly if the bench empties out next refresh.
  benchScroll:ReleaseChildren()
  for _, entry in ipairs(benchEntries) do
    benchScroll:AddChild(CreateBenchRow(entry.fullName, entry.status, classMap))
  end
  benchScroll:DoLayout()
end

local function RefreshEngineStatus()
  if Engine.starting then
    engineStatusLabel:SetText("Starting invites shortly...")
    startBtn:SetText("Stop Invites")
  elseif Engine.running then
    engineStatusLabel:SetText(string.format(
      "Running. Pending invites: %d | Queued for next pass: %d | Whispered/skipped: %d",
      ns.CountPendingInvites(), #Engine.queue, #Engine.skipped))
    startBtn:SetText("Stop Invites")
  else
    local skippedNote = ""
    if #Engine.skipped > 0 then
      skippedNote = " | Needs follow-up: " .. table.concat(Engine.skipped, ", ")
    end
    engineStatusLabel:SetText("Idle." .. skippedNote)
    startBtn:SetText("Start Invites")
  end
end

local function RefreshCountdown()
  local seconds = ns.GetSecondsUntilNextPass()
  if seconds then
    countdownLabel:SetText(string.format("Next invites: %ds", seconds))
  else
    countdownLabel:SetText("")
  end
end

-- Only :Show()/:Hide()s the button/dropdown rather than adding/removing
-- them from rightGroup's "List" layout - the space they occupy always
-- stays reserved (see BuildMainFrame's spacer math below), so Start/Stop
-- and everything else never shifts as leadership/group membership changes.
local function RefreshLootThresholdControls()
  if IsInGroup() and UnitIsGroupLeader("player") then
    lootThresholdBtn.frame:Show()
    lootThresholdDropdown.frame:Show()
  else
    lootThresholdBtn.frame:Hide()
    lootThresholdDropdown.frame:Hide()
  end
end

local function RefreshAll()
  if not mainFrame then return end
  RefreshPlayerList()
  RefreshEngineStatus()
  RefreshCountdown()
  RefreshLootThresholdControls()
end
ns.RegisterListener(RefreshAll)

local refreshTicker = nil
local countdownTicker = nil

local function BuildMainFrame()
  local frame = AceGUI:Create("Frame")
  ns.ApplyTooltipWindowStyle(frame)
  frame:SetTitle("Make Idiots Appear v" .. ns.GetAddonVersion())
  frame:SetStatusText("")
  frame:SetLayout("Flow")
  frame:EnableResize(false)

  -- AceGUI's Frame widget exposes its title FontString directly as
  -- .titletext; bump just the size, keeping whatever font/outline it
  -- already uses.
  do
    local fontFile, _, fontFlags = frame.titletext:GetFont()
    frame.titletext:SetFont(fontFile, 14, fontFlags)
  end

  -- AceGUI writes position into whatever status table we hand it whenever
  -- the frame is dragged (see MoverSizer_OnMouseUp in its Frame widget), and
  -- restores from it on creation - pointing it at a table in SavedVariables
  -- is all that's needed to remember window position across sessions.
  -- Resizing is disabled below, so width/height can never legitimately
  -- drift from our constants - enforce them every time (SetStatusTable
  -- would otherwise restore a stale saved width) rather than only seeding
  -- them on first use, so changing the constants takes effect immediately.
  MakeIdiotsAppearDB.windowStatus.main = MakeIdiotsAppearDB.windowStatus.main or {}
  local mainStatus = MakeIdiotsAppearDB.windowStatus.main
  frame:SetStatusTable(mainStatus)
  -- 420 + 20, all of which goes to leftGroup (see its SetRelativeWidth
  -- below) - rightGroup's own relative width was adjusted down at the same
  -- time so its absolute pixel width comes out unchanged.
  frame:SetWidth(440)
  -- 500 + 60 for the engine-status panel added below leftGroup/rightGroup
  -- (see STATUS_PANEL_HEIGHT near the bottom of this function) - kept as a
  -- separate hardcoded bump rather than referencing that constant here
  -- since it's declared later in the function, same as PANEL_HEIGHT below
  -- isn't threaded back up to here either.
  frame:SetHeight(560)

  frame:SetCallback("OnClose", function(widget)
    if refreshTicker then
      refreshTicker:Cancel()
      refreshTicker = nil
    end
    if countdownTicker then
      countdownTicker:Cancel()
      countdownTicker = nil
    end
    AceGUI:Release(widget)
    mainFrame = nil
  end)

  ----------------------------------------------------------------
  -- Left: active roster + player list
  ----------------------------------------------------------------

  -- InlineGroup normally auto-sizes to its content (see its LayoutFinished),
  -- which fights SetFullHeight's anchor-stretch and produces stale heights
  -- that throw off Flow's row-centering math, visually shoving the shorter
  -- panel down. Giving both panels the same explicit height sidesteps that.
  local PANEL_HEIGHT = 420

  leftGroup = AceGUI:Create("InlineGroup")
  leftGroup:SetTitle("Current Roster: (none selected)")
  leftGroup:SetLayout("List")
  -- 0.66/0.32 (see rightGroup below) rather than summing to exactly 1.0 -
  -- see UI_Rosters.lua's leftGroup for why: AceGUI's "Flow" layout (used by
  -- this window's outer frame) can wrap a child to a new row if
  -- pixel-rounding pushes the combined width a fraction over the
  -- container's. These two also carry rightGroup's own pixel width forward
  -- unchanged from before the window was widened by 20px - all of that
  -- extra width was added to leftGroup instead.
  leftGroup:SetRelativeWidth(0.66)
  leftGroup.noAutoHeight = true
  leftGroup:SetHeight(PANEL_HEIGHT)
  frame:AddChild(leftGroup)

  -- InlineGroup exposes its title FontString directly as .titletext; this
  -- only needs setting once since later leftGroup:SetTitle() calls (in
  -- RefreshPlayerList) just change the text, not the font.
  do
    local fontFile, _, fontFlags = leftGroup.titletext:GetFont()
    leftGroup.titletext:SetFont(fontFile, 11, fontFlags)
  end

  local headerRow = AceGUI:Create("SimpleGroup")
  headerRow:SetLayout("Flow")
  headerRow:SetFullWidth(true)
  headerRow:SetHeight(28)

  -- Drops a Label from GameFontHighlightMedium to the same chat font used
  -- for the rows below (ChatFontNormal, see ROW_FONT_FILE/HEIGHT/FLAGS at
  -- the top of this file), 2pt smaller than whatever size it already had -
  -- .label is the Label widget's own raw FontString field (same access
  -- pattern as leftGroup.titletext above).
  local function ApplyChatFontMinus2(label)
    local _, height = label.label:GetFont()
    local chatFile, _, chatFlags = ChatFontNormal:GetFont()
    label.label:SetFont(chatFile, height - 2, chatFlags)
  end

  -- Matches nameLabel/statusLabel's own relative widths in CreateRow (see
  -- its comment) so the headers stay aligned with the columns below them.
  local nameHeader = AceGUI:Create("Label")
  nameHeader:SetRelativeWidth(0.64)
  nameHeader:SetFontObject(GameFontHighlightMedium)
  nameHeader:SetText("Name")
  ApplyChatFontMinus2(nameHeader)

  local statusHeader = AceGUI:Create("Label")
  statusHeader:SetRelativeWidth(0.34)
  statusHeader:SetFontObject(GameFontHighlightMedium)
  statusHeader:SetText("Status")
  ApplyChatFontMinus2(statusHeader)

  headerRow:AddChild(nameHeader)
  headerRow:AddChild(statusHeader)
  leftGroup:AddChild(headerRow)

  playerScroll = AceGUI:Create("ScrollFrame")
  playerScroll:SetLayout("List")
  playerScroll:SetFullWidth(true)
  -- Overwritten every refresh by RefreshPlayerList depending on whether a
  -- bench needs to be shown - this initial value just avoids a flash of
  -- the wrong size before the first RefreshAll() runs.
  playerScroll:SetHeight(PLAYER_AREA_HEIGHT)
  leftGroup:AddChild(playerScroll)

  -- "Bench" section: hidden until RefreshPlayerList finds roster entries
  -- past the roster's own group size (see ns.GetRosterGroupSize) - see its
  -- own comment there for why raw Show()/Hide() is used instead of
  -- AddChild/ReleaseChildren on leftGroup itself.
  benchLabel = AceGUI:Create("Label")
  benchLabel:SetFullWidth(true)
  benchLabel:SetFont(ROW_FONT_FILE, ROW_FONT_HEIGHT, ROW_FONT_FLAGS)
  benchLabel:SetColor(1, 0.82, 0)
  benchLabel:SetText("Bench")
  ns.PadLabelVertically(benchLabel, ROW_LABEL_HEIGHT)
  leftGroup:AddChild(benchLabel)
  benchLabel.frame:Hide()

  benchScroll = AceGUI:Create("ScrollFrame")
  benchScroll:SetLayout("List")
  benchScroll:SetFullWidth(true)
  benchScroll:SetHeight(BENCH_SCROLL_HEIGHT)
  leftGroup:AddChild(benchScroll)
  benchScroll.frame:Hide()

  ----------------------------------------------------------------
  -- Right: options
  ----------------------------------------------------------------

  local rightGroup = AceGUI:Create("InlineGroup")
  rightGroup:SetTitle("")
  rightGroup:SetLayout("List")
  -- See leftGroup's own comment above - 0.32 keeps this panel's absolute
  -- pixel width the same as before the window widened by 20px.
  rightGroup:SetRelativeWidth(0.32)
  rightGroup.noAutoHeight = true
  rightGroup:SetHeight(PANEL_HEIGHT)
  frame:AddChild(rightGroup)

  -- "List" layout stacks children with zero gap (same AceGUI behavior noted
  -- above for the player rows), so a small blank SimpleGroup between each
  -- button is what creates the visible breathing room.
  local BUTTON_GAP = 4
  local BUTTON_HEIGHT = 20
  local function CreateButtonSpacer()
    local spacer = AceGUI:Create("SimpleGroup")
    spacer:SetFullWidth(true)
    spacer.noAutoHeight = true
    spacer:SetHeight(BUTTON_GAP)
    return spacer
  end

  local settingsBtn = AceGUI:Create("Button")
  settingsBtn:SetText("Settings")
  settingsBtn:SetFullWidth(true)
  settingsBtn:SetHeight(20)
  ns.ShrinkButtonFont(settingsBtn)
  settingsBtn:SetCallback("OnClick", function()
    ns.ShowSettingsFrame()
  end)
  rightGroup:AddChild(settingsBtn)

  rightGroup:AddChild(CreateButtonSpacer())

  local rostersBtn = AceGUI:Create("Button")
  rostersBtn:SetText("Rosters")
  rostersBtn:SetFullWidth(true)
  rostersBtn:SetHeight(20)
  ns.ShrinkButtonFont(rostersBtn)
  rostersBtn:SetCallback("OnClick", function()
    ns.ShowRosterManagerFrame()
  end)
  rightGroup:AddChild(rostersBtn)

  rightGroup:AddChild(CreateButtonSpacer())

  local groupsBtn = AceGUI:Create("Button")
  groupsBtn:SetText("Groups")
  groupsBtn:SetFullWidth(true)
  groupsBtn:SetHeight(20)
  ns.ShrinkButtonFont(groupsBtn)
  groupsBtn:SetCallback("OnClick", function()
    ns.ShowGroupManagerFrame()
  end)
  rightGroup:AddChild(groupsBtn)

  -- Manual loot threshold controls - only usable by the raid leader, so
  -- RefreshLootThresholdControls (called from RefreshAll) hides/shows the
  -- button and dropdown as group/leader status changes. They stay in
  -- rightGroup's "List" stack at all times (just invisible when hidden) so
  -- Start/Stop and everything else below never shifts - see
  -- RefreshLootThresholdControls's own comment for why Hide()/Show() is
  -- enough here rather than AddChild/ReleaseChildren.
  local LOOT_THRESHOLD_DROPDOWN_HEIGHT = 26 -- AceGUI Dropdown's own unlabeled height, see AceGUIWidget-Dropdown.lua's SetLabel
  local lootThresholdSpacer = AceGUI:Create("SimpleGroup")
  lootThresholdSpacer:SetFullWidth(true)
  lootThresholdSpacer.noAutoHeight = true
  lootThresholdSpacer:SetHeight(BUTTON_HEIGHT)
  rightGroup:AddChild(lootThresholdSpacer)

  lootThresholdBtn = AceGUI:Create("Button")
  lootThresholdBtn:SetText("Set Loot")
  lootThresholdBtn:SetFullWidth(true)
  lootThresholdBtn:SetHeight(BUTTON_HEIGHT)
  ns.ShrinkButtonFont(lootThresholdBtn)
  lootThresholdBtn:SetCallback("OnClick", function()
    pcall(SetLootThreshold, MakeIdiotsAppearDB.settings.lootThresholdQuality)
  end)
  rightGroup:AddChild(lootThresholdBtn)

  -- Same colored list/order as the Settings window's Raid tab (see
  -- UI_Settings.lua, loaded before this file) and bound to the same
  -- settings.lootThresholdQuality value, so picking one here keeps the
  -- Settings tab's dropdown in sync and vice versa.
  lootThresholdDropdown = AceGUI:Create("Dropdown")
  lootThresholdDropdown:SetList(ns.BuildLootThresholdDropdownList(), ns.LootQualityOrder)
  lootThresholdDropdown:SetValue(MakeIdiotsAppearDB.settings.lootThresholdQuality)
  lootThresholdDropdown:SetFullWidth(true)
  lootThresholdDropdown:SetCallback("OnValueChanged", function(widget, event, value)
    MakeIdiotsAppearDB.settings.lootThresholdQuality = value
  end)
  rightGroup:AddChild(lootThresholdDropdown)

  -- "List" layout just stacks children top-down with no auto-fill, so a
  -- blank spacer is what pushes Start/Stop down to the bottom of the panel.
  -- (A Label won't hold a forced height - it recalculates itself from its
  -- text on every SetText/SetWidth. SimpleGroup respects noAutoHeight.) The
  -- spacer is shortened by the two button gaps above, the loot threshold
  -- block above, and the countdown container reserved below, so Start/Stop
  -- lands in the same spot regardless of any of those being hidden/shown.
  local COUNTDOWN_HEIGHT = 14
  local spacer = AceGUI:Create("SimpleGroup")
  spacer:SetFullWidth(true)
  spacer.noAutoHeight = true
  spacer:SetHeight(300 - (2 * BUTTON_GAP) - COUNTDOWN_HEIGHT
    - BUTTON_HEIGHT - BUTTON_HEIGHT - LOOT_THRESHOLD_DROPDOWN_HEIGHT)
  rightGroup:AddChild(spacer)

  -- Label always left-justifies its text with no built-in way to change
  -- that, so reach into its FontString directly to center this one. The
  -- Label itself recalculates its height from its text (empty vs. "Next
  -- invites: Xs"), which used to shift Start/Stop down when a countdown
  -- appeared - wrapping it in a fixed-height, noAutoHeight SimpleGroup
  -- reserves that space permanently so nothing below it ever moves.
  local countdownContainer = AceGUI:Create("SimpleGroup")
  countdownContainer:SetFullWidth(true)
  countdownContainer.noAutoHeight = true
  countdownContainer:SetHeight(COUNTDOWN_HEIGHT)
  countdownContainer:SetLayout("Fill")

  countdownLabel = AceGUI:Create("Label")
  countdownLabel:SetFullWidth(true)
  countdownLabel:SetText("")
  countdownLabel.label:SetJustifyH("CENTER")
  countdownContainer:AddChild(countdownLabel)
  rightGroup:AddChild(countdownContainer)

  startBtn = AceGUI:Create("Button")
  startBtn:SetText("Start Invites")
  startBtn:SetFullWidth(true)
  startBtn:SetHeight(20)
  ns.ShrinkButtonFont(startBtn)
  startBtn:SetCallback("OnClick", function()
    if Engine.running or Engine.starting then
      ns.StopInvites("Stopped by user.")
      return
    end

    local activeRoster = MakeIdiotsAppearDB.settings.activeRoster
    if not activeRoster then
      print(PREFIX .. "No active roster selected. Use Manage Rosters to create/select one first.")
      return
    end

    -- Bench players (past the roster's own group size, see
    -- ns.GetRosterGroupSize) are deliberately excluded from the automated
    -- run - they're only invited manually via the "+" button on their own
    -- bench row.
    local fullList = MakeIdiotsAppearDB.rosters[activeRoster] or {}
    local groupSize = ns.GetRosterGroupSize(activeRoster)
    local list = {}
    for i = 1, math.min(groupSize, #fullList) do
      table.insert(list, fullList[i])
    end
    ns.StartInvites(list)
  end)
  rightGroup:AddChild(startBtn)

  ----------------------------------------------------------------
  -- Bottom: engine status
  ----------------------------------------------------------------

  -- Matches leftGroup+rightGroup's combined 0.66+0.32 width (see leftGroup's
  -- own comment on why that's not 1.0) rather than SetFullWidth, so this
  -- panel lines up with the row above instead of running slightly wider.
  -- 0.98 alone is still bigger than the sliver Flow has left on that row
  -- (after leftGroup+rightGroup), so it wraps onto its own row below both
  -- of them just like a fullwidth panel would - see UI_Rosters.lua's
  -- leftGroup for the same Flow wrapping behavior. No title, just the one
  -- line of engine status text that used to live at the bottom of leftGroup.
  local STATUS_PANEL_HEIGHT = 60
  local statusGroup = AceGUI:Create("InlineGroup")
  statusGroup:SetTitle("")
  statusGroup:SetLayout("List")
  statusGroup:SetRelativeWidth(0.98)
  statusGroup.noAutoHeight = true
  statusGroup:SetHeight(STATUS_PANEL_HEIGHT)
  frame:AddChild(statusGroup)

  -- InlineGroup always reserves 17px at its own top for a title bar (see
  -- AceGUIContainer-InlineGroup.lua's Constructor) even with SetTitle("") -
  -- with no title to show, that just reads as unwanted blank space above
  -- the panel's visible border. content/border aren't exposed on the
  -- widget table, but border is the panel's only Frame child, so grab it
  -- directly and pull its top in to match the small bottom inset instead.
  local statusBorder = select(1, statusGroup.frame:GetChildren())
  statusBorder:ClearAllPoints()
  statusBorder:SetPoint("TOPLEFT", 0, -3)
  statusBorder:SetPoint("BOTTOMRIGHT", -1, 3)

  -- Same font as the player name/status columns to the left (see
  -- ROW_FONT_FILE/HEIGHT/FLAGS at the top of this file).
  engineStatusLabel = AceGUI:Create("Label")
  engineStatusLabel:SetFullWidth(true)
  engineStatusLabel:SetFont(ROW_FONT_FILE, ROW_FONT_HEIGHT, ROW_FONT_FLAGS)
  engineStatusLabel:SetText("Idle.")
  statusGroup:AddChild(engineStatusLabel)

  return frame
end

local function ToggleMainFrame()
  ns.EnsureDB()
  if mainFrame then
    if mainFrame.frame:IsShown() then
      mainFrame.frame:Hide()
    else
      mainFrame.frame:Show()
      RefreshAll()
    end
    return
  end

  mainFrame = BuildMainFrame()
  RefreshAll()

  if IsInGuild() then ns.RequestGuildRoster() end
  refreshTicker = C_Timer.NewTicker(5, function()
    if IsInGuild() then ns.RequestGuildRoster() end
    RefreshAll()
  end)
  countdownTicker = C_Timer.NewTicker(1, RefreshCountdown)
end

----------------------------------------------------------------------
-- Slash command
----------------------------------------------------------------------

SLASH_MAKEIDIOTSAPPEAR1 = "/mia"
SLASH_MAKEIDIOTSAPPEAR2 = "/ri"
SLASH_MAKEIDIOTSAPPEAR3 = "/ric"
SlashCmdList["MAKEIDIOTSAPPEAR"] = function(msg)
  msg = ns.Trim((msg or ""):lower())

  if msg == "debug" then
    ns.EnsureDB()
    MakeIdiotsAppearDB.settings.debugMode = not MakeIdiotsAppearDB.settings.debugMode
    print(PREFIX .. "Debug mode " .. (MakeIdiotsAppearDB.settings.debugMode and "enabled" or "disabled") .. ".")
    return
  end

  if msg == "groups" then
    ns.ShowGroupManagerFrame()
    return
  end

  if msg == "rosters" then
    ns.ShowRosterManagerFrame()
    return
  end

  if msg == "settings" then
    ns.ShowSettingsFrame()
    return
  end

  ToggleMainFrame()
end
