-- UI_Groups.lua
-- Manage Groups window: drag-and-drop 8x5 group grid + unassigned pool for
-- the active roster's group compositions, and an Apply Groups button that
-- moves live raid members to match. Built with AceGUI-3.0 for the window
-- chrome/columns, but the group grid and unassigned pool are raw frames
-- manually positioned inside each column's .content frame (AceGUI's
-- Flow/List layouts can't host free-form drag targets) - the same
-- raw-frame-inside-AceGUI technique UI_Main.lua's PrepareRow and
-- UI_Settings.lua's custom close button already use.

local ADDON_NAME, ns = ...
local PREFIX = ns.PREFIX
local AceGUI = LibStub("AceGUI-3.0")

local GROUPS_PER_COMP = ns.GROUPS_PER_COMP
local SLOTS_PER_GROUP = ns.SLOTS_PER_GROUP

----------------------------------------------------------------------
-- Layout constants
----------------------------------------------------------------------

local SLOT_WIDTH = 145
-- The 40 editable group slots only (see CreateEditableSlot) - kept separate
-- from SLOT_WIDTH, which the read-only unassigned-pool tokens (see
-- CreateTokenFrame) still use, so widening one doesn't also widen the other.
local EDITABLE_SLOT_WIDTH = SLOT_WIDTH + 15
local SLOT_HEIGHT = 20            -- includes 3px of vertical padding top and bottom around the centered (now 1px larger) text
local SLOT_GAP = 2
local GROUP_TITLE_TOP_PADDING = 6 -- clearance above the "Group N" label, below the box's top edge
local GROUP_TITLE_HEIGHT = 22     -- total space reserved for the label (top padding + text + bottom clearance) before the first slot
local GROUP_BOX_PADDING = 4
local GROUP_BOX_WIDTH = EDITABLE_SLOT_WIDTH + GROUP_BOX_PADDING * 2
local GROUP_BOX_HEIGHT = GROUP_TITLE_HEIGHT + SLOTS_PER_GROUP * (SLOT_HEIGHT + SLOT_GAP) + GROUP_BOX_PADDING
local GROUP_BOX_GAP_X = 10
local GROUP_BOX_GAP_Y = 4 -- smaller than GROUP_BOX_GAP_X since the taller slots already add vertical space between rows
local GROUP_GRID_LEFT_PADDING = 8 -- clearance between leftGroup's own left edge and the first column of group boxes

-- 2pt smaller than ns.GetChatFont's own default - same treatment as player
-- names in UI_Main.lua and roster names in UI_Rosters.lua.
local TOKEN_FONT_FILE, TOKEN_FONT_HEIGHT, TOKEN_FONT_FLAGS = ns.GetChatFont(-2)

local PANEL_HEIGHT = 600

-- Slots/tokens and the group boxes behind them are all explicitly pinned to
-- this same strata (rather than left to inherit an ambient default some of
-- them might not actually get) - a child frame drawn at the same strata as
-- its parent still renders above it (children get a higher frame level than
-- their parent by default), so this guarantees slots/tokens always render
-- (and are clickable) above their box/column background, rather than an
-- unset default putting the box's own background on top on some clients.
local RESTING_STRATA = "FULLSCREEN_DIALOG"

-- Backdrop-free by design: SetBackdrop on a plain CreateFrame("Frame", ...)
-- (no "BackdropTemplate") turned out to be unavailable on at least some
-- Classic Era clients (confirmed via a live "attempt to call a nil value"
-- error on box:SetBackdrop), unlike AceGUI's own bundled InlineGroup/Frame
-- widgets which happened not to hit this in practice. Plain textures work
-- everywhere, so group boxes and slots/tokens (see CreateTokenFrame) both
-- fake a bordered box out of two stacked color textures instead.
local function SetTextureColor(texture, r, g, b, a)
  if texture.SetColorTexture then
    texture:SetColorTexture(r, g, b, a)
  else
    texture:SetTexture(1, 1, 1, 1)
    texture:SetVertexColor(r, g, b, a)
  end
end

----------------------------------------------------------------------
-- Module state
----------------------------------------------------------------------

local groupsFrame = nil
local currentRosterName = nil

local slotFrames = {}    -- slotFrames[groupIndex][posIndex] = frame, 40 fixed frames
local allSlotFrames = {} -- flat list of the same 40, for drop-target hit-testing

local unassignedGroup = nil
local unassignedScrollFrame = nil
local unassignedContent = nil
local unassignedTokenPool = {}

local compListScroll = nil
local deleteBtn = nil
local applyBtn = nil
local applyStatusLabel = nil

local RefreshGroupsWindow

----------------------------------------------------------------------
-- Data access helpers
----------------------------------------------------------------------

local function GetRosterList()
  return MakeIdiotsAppearDB.rosters[currentRosterName] or {}
end

local function GetComp()
  return ns.GetActiveGroupComp(currentRosterName)
end

----------------------------------------------------------------------
-- Drag and drop
----------------------------------------------------------------------

-- Mirrors MRT's RaidGroups.lua drag technique: at drag-stop, check which of
-- the 40 fixed slot frames the mouse cursor is currently over (IsMouseOver
-- tests the live cursor position against that frame's own screen rect) -
-- simpler than computing rect overlap between two moving frames.
local function ResolveDropTarget(draggedFrame)
  for _, slot in ipairs(allSlotFrames) do
    if slot ~= draggedFrame and slot:IsMouseOver() then
      return slot
    end
  end
  return nil
end

-- Group-by-group, then position-within-group order (same as slotFrames'
-- own layout) - used by the unassigned pool's right-click-to-place shortcut
-- below, so "first empty spot" matches what a glance at the group grid
-- itself would suggest.
local function FindFirstEmptySlot(comp)
  for g = 1, GROUPS_PER_COMP do
    for p = 1, SLOTS_PER_GROUP do
      if comp.groups[g][p] == nil then
        return g, p
      end
    end
  end
  return nil
end

local function OnSlotDragStop(self)
  self:StopMovingOrSizing()
  self:SetFrameStrata(RESTING_STRATA)
  -- The initiating click focuses the EditBox (its default click behavior,
  -- ahead of the drag threshold) - a completed drag isn't a text edit, and
  -- SetSlotEditBoxDisplay below deliberately skips updating a focused box
  -- (see its comment), so leaving this focused would show stale text here
  -- until something else happened to trigger another refresh later.
  self:ClearFocus()

  local comp = GetComp()
  local groups = comp.groups
  local g1, p1 = self.groupIndex, self.posIndex

  if groups[g1][p1] == nil then
    -- dragged an empty slot - nothing to move
    RefreshGroupsWindow()
    return
  end

  local target = ResolveDropTarget(self)
  if target then
    local g2, p2 = target.groupIndex, target.posIndex
    -- Positions are fixed slots, not a compacted list, so this is always a
    -- straight swap - whatever (if anything) was in the target slot lands
    -- exactly where the dragged player came from, and vice versa. Leaves a
    -- blank exactly where the dragged player was if the target was empty.
    groups[g1][p1], groups[g2][p2] = groups[g2][p2], groups[g1][p1]
  else
    -- dropped outside every group slot - clear this slot (goes to unassigned)
    groups[g1][p1] = nil
  end

  RefreshGroupsWindow()
end

local function OnUnassignedDragStop(self)
  self:StopMovingOrSizing()
  self:SetFrameStrata(RESTING_STRATA)
  -- Undo SetupTokenDrag's escape to UIParent (see its own comment) now that
  -- the drag is over, so this token's clipping/scrolling as part of the
  -- unassigned pool resumes normally - whether or not the drop actually
  -- landed, the very next RefreshGroupsWindow below will either reposition
  -- this token back into the pool or hide it if it's no longer unassigned.
  self:SetParent(unassignedContent)

  local target = ResolveDropTarget(self)
  if target then
    local comp = GetComp()
    -- Whoever (if anyone) was in that exact slot becomes unassigned in
    -- their place - this player takes that precise position.
    comp.groups[target.groupIndex][target.posIndex] = self.playerName
  end
  -- else: dropped nowhere recognized - stays unassigned, no-op

  RefreshGroupsWindow()
end

----------------------------------------------------------------------
-- Token/slot frame factory
----------------------------------------------------------------------

-- Shared by both frame types below: click-drag to move/swap. (Click-to-edit,
-- for the EditBox-based group slots, coexists fine with this - EditBox's own
-- built-in click-to-focus only engages on a stationary click, a real drag
-- gesture routes to OnDragStart instead, same as MRT's simultaneously
-- draggable+editable rows.)
local function SetupDrag(frame)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self)
    self:SetFrameStrata("TOOLTIP")
    self:StartMoving()
  end)
end

-- Same drag behavior as SetupDrag, but for tokens specifically: they live
-- inside the unassigned pool's scroll frame (see BuildGroupsFrame's
-- unassignedGroup), and a Blizzard ScrollFrame clips everything parented under
-- it to its own visible rect regardless of frame strata - so a token
-- dragged toward a group slot elsewhere in the window would otherwise
-- vanish the instant it crossed the pool's edge. Escaping to UIParent for
-- the duration of the drag sidesteps that; OnUnassignedDragStop puts it
-- back under unassignedContent once the drag ends.
local function SetupTokenDrag(frame)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self)
    self:SetParent(UIParent)
    self:SetFrameStrata("TOOLTIP")
    self:StartMoving()
  end)
end

-- 1px border out of two stacked textures (outer = light grey border, inner
-- inset by 1px = fill color) - same trick the group box itself used to use
-- before its border was removed.
local function AddBorderedBackground(f, r, g, b, a)
  local border = f:CreateTexture(nil, "BACKGROUND")
  border:SetAllPoints()
  SetTextureColor(border, 0.3, 0.3, 0.3, 0.5)

  local fill = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  fill:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  fill:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
  SetTextureColor(fill, r, g, b, a)
  return fill
end
ns.AddBorderedBackground = AddBorderedBackground

-- Class color, always - no longer conditional on raid/party membership (see
-- MissingIndicatorWidth/UpdateMissingIndicator below for how "not currently
-- in your raid/party" is shown instead). Plain white if we don't know their
-- class (shouldn't normally happen for anyone actually placed in a slot).
local function ComputeNameColor(name, classMap)
  local classFile = ns.LookupByFullOrName(classMap, name)
  local r, g, b = ns.GetClassColor(classFile)
  if r then
    return r, g, b
  end
  return 1, 1, 1
end

-- Thin red bar on the left edge, shown only when the named player is not
-- currently a member of your raid/party (checked via groupSet - see
-- MakeIdiotsAppear.lua's GetGroupNameSet) - hidden for everyone actually in
-- the group, and for empty slots.
local MISSING_INDICATOR_WIDTH = 2

local function AddMissingIndicator(f)
  local indicator = f:CreateTexture(nil, "ARTWORK")
  indicator:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  indicator:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  indicator:SetWidth(MISSING_INDICATOR_WIDTH)
  SetTextureColor(indicator, 0.9, 0.15, 0.15, 1)
  indicator:Hide()
  f.missingIndicator = indicator
  return indicator
end

local function UpdateMissingIndicator(f, name, groupSet)
  if name and not ns.LookupByFullOrName(groupSet, name) then
    f.missingIndicator:Show()
  else
    f.missingIndicator:Hide()
  end
end

-- Light grey "B" pinned to the right edge, shown only for roster entries
-- past the roster's own group size (see ns.GetRosterGroupSize) - the same
-- bench split UI_Main.lua's player list uses, mirrored here so bench players
-- are still recognizable once they're dragged into/out of a group slot.
local BENCH_MARKER_R, BENCH_MARKER_G, BENCH_MARKER_B = 0.6, 0.6, 0.6

-- Same typeface as the player name text (TOKEN_FONT_FILE - the default chat
-- font, Fonts\ARIALN.TTF, same file SlotBaseFont derives from too) instead
-- of GameFontNormalSmall's own Friz Quadrata family - kept at
-- GameFontNormalSmall's own size/flags, so only the typeface changes.
local _, BENCH_MARKER_FONT_HEIGHT, BENCH_MARKER_FONT_FLAGS = GameFontNormalSmall:GetFont()

local function AddBenchMarker(f)
  local marker = f:CreateFontString(nil, "OVERLAY")
  marker:SetFont(TOKEN_FONT_FILE, BENCH_MARKER_FONT_HEIGHT, BENCH_MARKER_FONT_FLAGS)
  marker:SetPoint("RIGHT", f, "RIGHT", -4, 0)
  marker:SetText("B")
  marker:SetTextColor(BENCH_MARKER_R, BENCH_MARKER_G, BENCH_MARKER_B)
  marker:Hide()
  f.benchMarker = marker
  return marker
end

local function UpdateBenchMarker(f, name, benchSet)
  if name and benchSet[name:lower()] then
    f.benchMarker:Show()
  else
    f.benchMarker:Hide()
  end
end

-- Small gold crown pinned to the left edge, shown only for whichever slot/
-- token currently holds the raid leader (see ns.FindRaidLeader) - the same
-- crown Blizzard's own raid frame shows, mirrored here so leadership stays
-- recognizable once someone's dragged into/out of a group slot. Same
-- fixed-position, no-text-resizing treatment as AddBenchMarker's "B" above
-- (only one row at a time ever shows it, so an occasional pixel of overlap
-- with a short name is an acceptable tradeoff). Drawn on an explicit high
-- OVERLAY sublevel so it always renders above the name text/EditBox font
-- regardless of which was created first.
local LEADER_ICON_SIZE = 12

local function AddLeaderIcon(f)
  local icon = f:CreateTexture(nil, "OVERLAY", nil, 7)
  icon:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
  icon:SetSize(LEADER_ICON_SIZE, LEADER_ICON_SIZE)
  -- Centered on the row's left edge (vertically centered, half spilling
  -- outside to the left) rather than the top-left corner - see if this reads
  -- better than the corner placement.
  icon:SetPoint("CENTER", f, "LEFT", -8, 0)
  icon:Hide()
  f.leaderIcon = icon
  return icon
end

-- rlFullName is whatever ns.FindRaidLeader() returned this refresh (nil if no
-- raid or no leader) - matched the same tolerant way missing-indicator/bench
-- lookups already are elsewhere in this file, since a slot's stored name and
-- the unit-derived leader name might differ in whether a realm is attached.
local function UpdateLeaderIcon(f, name, rlFullName)
  local isLeader = name and rlFullName and
      (name:lower() == rlFullName:lower() or ns.NamePart(name) == ns.NamePart(rlFullName))
  if isLeader then
    f.leaderIcon:Show()
  else
    f.leaderIcon:Hide()
  end
end

-- Read-only, drag-source-only token used for the unassigned pool - matches
-- MRT's "not in list" column, which is also just a drag source, never
-- directly editable (only the main 40 group slots are, see
-- CreateEditableSlot below).
local function CreateTokenFrame(parent)
  local f = CreateFrame("Button", nil, parent)
  -- Width is just an initial placeholder (avoids a zero-width frame before
  -- the first refresh) - every refresh resizes it to fill the pool's actual
  -- current width instead, see DoRefreshGroupsWindow's tokenWidth.
  f:SetSize(SLOT_WIDTH, SLOT_HEIGHT)
  f:SetFrameStrata(RESTING_STRATA)

  AddBorderedBackground(f, 0.06, 0.06, 0.06, 0.9)

  AddMissingIndicator(f)
  AddBenchMarker(f)
  AddLeaderIcon(f)

  -- ChatFontNormal is Blizzard's own default chat text font (Fonts\ARIALN.TTF,
  -- i.e. Arial Narrow) - used here instead of GameFontHighlightSmall so
  -- player names read the same as they do everywhere else names show up in
  -- chat. 2pt smaller than ChatFontNormal's own default, same treatment as
  -- player names elsewhere in this addon.
  local text = f:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
  text:SetFont(TOKEN_FONT_FILE, TOKEN_FONT_HEIGHT, TOKEN_FONT_FLAGS)
  text:SetPoint("LEFT", f, "LEFT", 4, 0)
  text:SetPoint("RIGHT", f, "RIGHT", -4, 0)
  text:SetJustifyH("LEFT")
  text:SetWordWrap(false)
  f.text = text

  SetupTokenDrag(f)

  -- Right-click shortcut: send this token straight into the first empty
  -- group slot (see FindFirstEmptySlot), without having to drag it there.
  -- Buttons only fire OnClick for clicks they're registered for - left is
  -- on by default, right needs opting in explicitly.
  f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  f:SetScript("OnClick", function(self, button)
    if button ~= "RightButton" then
      return
    end
    local comp = GetComp()
    local g, p = FindFirstEmptySlot(comp)
    if not g then
      print(PREFIX .. "No empty group slot available.")
      return
    end
    comp.groups[g][p] = self.playerName
    RefreshGroupsWindow()
  end)

  return f
end

-- Commits a group slot's in-place edit into comp.groups only - the roster's
-- saved player list (MakeIdiotsAppearDB.rosters) is never touched here, so
-- this can't be clobbered by (and doesn't affect) a later roster save; no
-- composition, including Default, is auto-touched by a roster save, so
-- manual edits/additions made here are left alone. Reuses the same
-- ns.NormalizePlayerName the roster editor uses, so a bare name gets
-- resolved against the master roster (learned from people who've actually
-- been in your group/guild) exactly the same way, and still gets flagged if
-- no realm can be found for it.
local function CommitSlotEdit(slot)
  local rawText = ns.Trim(slot:GetText() or "")
  if rawText == (slot.textAtFocus or "") then
    return -- unchanged - nothing to do, no message to print
  end

  local comp = GetComp()
  local g, p = slot.groupIndex, slot.posIndex

  if rawText == "" then
    comp.groups[g][p] = nil
    RefreshGroupsWindow()
    return
  end

  local normalized, needsRealm = ns.NormalizePlayerName(rawText)
  if not normalized then
    comp.groups[g][p] = nil
    RefreshGroupsWindow()
    return
  end

  comp.groups[g][p] = normalized
  if needsRealm then
    print(PREFIX .. "Could not find a realm for '" .. normalized ..
      "' - saved as-is. Add '-Realm' manually, or have them show up in your group/guild once so it's learned.")
  end
  RefreshGroupsWindow()
end

-- The 40 group slots: editable in place (typing a name into a blank slot
-- adds them to just this composition; editing an existing one renames it
-- here only) as well as draggable, same as the read-only tokens above.

-- Two points larger than GameFontHighlightSmall, using ChatFontNormal's font
-- file (Fonts\ARIALN.TTF, i.e. Arial Narrow - Blizzard's own default chat
-- text font) instead of GameFontHighlightSmall's, so player names read the
-- same as they do everywhere else names show up in chat - every slot font
-- (this default and each colored variant below) derives its file/size/flags
-- from this rather than straight from GameFontHighlightSmall/ChatFontNormal,
-- so both the font swap and the size bump apply everywhere consistently.
local SlotBaseFont = CreateFont("MakeIdiotsAppearSlotBaseFont")
do
  local fontFile = ChatFontNormal:GetFont()
  local _, fontHeight, fontFlags = GameFontHighlightSmall:GetFont()
  SlotBaseFont:SetFont(fontFile, fontHeight + 2, fontFlags)
  SlotBaseFont:SetTextColor(GameFontHighlightSmall:GetTextColor())
end

-- EditBox:SetTextColor turned out to reject both plain (r, g, b) numbers and
-- a CreateColor()-wrapped object in this client, and reaching into its
-- internal FontString directly didn't visibly take effect either - but
-- EditBox:SetFontObject definitely works (it's what sets the base font at
-- creation below), and a real Font object's own SetTextColor is the same
-- long-established call FontString uses, which already works fine for the
-- unassigned pool. So instead of coloring the widget, each distinct color
-- gets its own small Font object (cached - there are only ever a handful of
-- classes plus grey/white in play at once) and slots switch between them.
local coloredFontCache = {}
local coloredFontCount = 0

local function GetColoredFont(r, g, b)
  local key = r .. "|" .. g .. "|" .. b
  local font = coloredFontCache[key]
  if not font then
    coloredFontCount = coloredFontCount + 1
    font = CreateFont("MakeIdiotsAppearSlotFont" .. coloredFontCount)
    local fontFile, fontHeight, fontFlags = SlotBaseFont:GetFont()
    font:SetFont(fontFile, fontHeight, fontFlags)
    font:SetTextColor(r, g, b)
    coloredFontCache[key] = font
  end
  return font
end

local function CreateEditableSlot(parent)
  local f = CreateFrame("EditBox", nil, parent)
  f:SetSize(EDITABLE_SLOT_WIDTH, SLOT_HEIGHT)
  f:SetFrameStrata(RESTING_STRATA)
  f:SetAutoFocus(false)
  f:SetFontObject(SlotBaseFont)
  f:SetJustifyH("LEFT")
  f:SetTextInsets(4, 4, 1, 1)

  AddBorderedBackground(f, 0.06, 0.06, 0.06, 0.9)

  AddMissingIndicator(f)
  AddBenchMarker(f)
  AddLeaderIcon(f)

  SetupDrag(f)

  f:SetScript("OnEditFocusGained", function(self)
    self.textAtFocus = self:GetText()
  end)
  f:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
  end)
  f:SetScript("OnEscapePressed", function(self)
    self:SetText(self.textAtFocus or "")
    self:ClearFocus()
  end)
  f:SetScript("OnEditFocusLost", function(self)
    CommitSlotEdit(self)
  end)

  -- Right-click shortcut: send this slot's player straight back to
  -- unassigned, without having to drag it there - same effect as dragging
  -- the slot and dropping outside every group slot (see OnSlotDragStop).
  -- EditBox has no OnClick/RegisterForClicks concept (that's Button-only) -
  -- OnMouseUp fires for any button regardless, so this doesn't need it.
  f:SetScript("OnMouseUp", function(self, button)
    if button ~= "RightButton" then
      return
    end
    self:ClearFocus()
    local comp = GetComp()
    local g, p = self.groupIndex, self.posIndex
    if comp.groups[g][p] == nil then
      return
    end
    comp.groups[g][p] = nil
    RefreshGroupsWindow()
  end)

  return f
end

-- Group slots are drag targets whose *frame* must always end up back at its
-- fixed grid position after a drop, not just have its text updated - the
-- dragged frame otherwise stays physically parked wherever it was dropped
-- (StopMovingOrSizing leaves it there), which looks like the swap silently
-- failed even though the underlying data updated correctly. Mirrors MRT's
-- RaidGroups.lua snapping each edit box back to its formulaic position after
-- every drag stop.
local function ResetSlotHome(slot)
  slot:ClearAllPoints()
  slot:SetPoint("TOPLEFT", slot.homeParent, "TOPLEFT", slot.homeX, slot.homeY)
  slot:SetFrameStrata(RESTING_STRATA)
end

local function SetTokenDisplay(frame, name, classMap, groupSet, benchSet, rlFullName)
  frame.text:SetText(name or "")
  if name then
    frame.text:SetTextColor(ComputeNameColor(name, classMap))
  end
  UpdateMissingIndicator(frame, name, groupSet)
  UpdateBenchMarker(frame, name, benchSet)
  UpdateLeaderIcon(frame, name, rlFullName)
end

-- Same idea as SetTokenDisplay, but for the editable EditBox-based group
-- slots - and skipped entirely while the slot currently has keyboard focus,
-- so a refresh triggered elsewhere (another drag, a roster save, a periodic
-- listener tick) can never stomp on an edit the user is still mid-typing.
-- Color is applied via GetColoredFont/SetFontObject rather than
-- SetTextColor - see the comment above CreateEditableSlot's font cache for
-- why.
local function SetSlotEditBoxDisplay(slot, name, classMap, groupSet, benchSet, rlFullName)
  if slot:HasFocus() then
    return
  end
  slot:SetText(name or "")
  slot.textAtFocus = name or ""
  if name then
    slot:SetFontObject(GetColoredFont(ComputeNameColor(name, classMap)))
  else
    slot:SetFontObject(SlotBaseFont)
  end
  UpdateMissingIndicator(slot, name, groupSet)
  UpdateBenchMarker(slot, name, benchSet)
  UpdateLeaderIcon(slot, name, rlFullName)
end

local function CreateGroupBox(parent, groupIndex, x, y)
  local box = CreateFrame("Frame", nil, parent)
  box:SetSize(GROUP_BOX_WIDTH, GROUP_BOX_HEIGHT)
  box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  box:SetFrameStrata(RESTING_STRATA)

  -- No background at all here for now - each slot draws its own 1px-bordered
  -- box instead (see AddBorderedBackground).

  local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("TOPLEFT", box, "TOPLEFT", 4, -GROUP_TITLE_TOP_PADDING)
  title:SetText("Group " .. groupIndex)

  slotFrames[groupIndex] = {}
  for p = 1, SLOTS_PER_GROUP do
    local slot = CreateEditableSlot(box)
    slot.groupIndex = groupIndex
    slot.posIndex = p
    slot.homeParent = box
    slot.homeX = GROUP_BOX_PADDING
    slot.homeY = -(GROUP_TITLE_HEIGHT + (p - 1) * (SLOT_HEIGHT + SLOT_GAP))
    slot:SetPoint("TOPLEFT", box, "TOPLEFT", slot.homeX, slot.homeY)
    slot:SetScript("OnDragStop", OnSlotDragStop)
    slotFrames[groupIndex][p] = slot
    table.insert(allSlotFrames, slot)
  end

  return box
end

local function AcquireUnassignedToken(index)
  local token = unassignedTokenPool[index]
  if not token then
    token = CreateTokenFrame(unassignedContent)
    token:SetScript("OnDragStop", OnUnassignedDragStop)
    unassignedTokenPool[index] = token
  end
  return token
end

----------------------------------------------------------------------
-- Composition list (right column)
----------------------------------------------------------------------

-- A from-scratch AceGUI prompt rather than StaticPopup's hasEditBox: on at
-- least some clients the current Blizzard_StaticPopup/GameDialog rewrite
-- doesn't populate self.editBox the way every older addon (and Blizzard's
-- own documented pattern) expects, throwing "attempt to index field
-- 'editBox' (a nil value)" as soon as the dialog shows. AceGUI's EditBox is
-- already proven throughout this addon (UI_Rosters.lua's roster name/player
-- list boxes), so reusing it here sidesteps that entirely.
local promptFrame = nil

local function ShowTextPrompt(title, defaultText, onAccept)
  if promptFrame then
    promptFrame.frame:Hide()
  end

  if not promptFrame then
    local f = AceGUI:Create("Frame")
    ns.ApplyTooltipWindowStyle(f)
    f:SetLayout("List")
    f:EnableResize(false)
    f:SetWidth(320)
    f:SetHeight(150)
    f:SetCallback("OnClose", function(widget)
      widget.frame:Hide()
    end)

    local box = AceGUI:Create("EditBox")
    box:SetFullWidth(true)
    f:AddChild(box)
    f.promptBox = box

    local btnRow = AceGUI:Create("SimpleGroup")
    btnRow:SetLayout("Flow")
    btnRow:SetFullWidth(true)
    f:AddChild(btnRow)

    local okBtn = AceGUI:Create("Button")
    okBtn:SetText("OK")
    okBtn:SetWidth(130)
    ns.ShrinkButtonFont(okBtn)
    btnRow:AddChild(okBtn)
    f.promptOkBtn = okBtn

    local cancelBtn = AceGUI:Create("Button")
    cancelBtn:SetText("Cancel")
    cancelBtn:SetWidth(130)
    ns.ShrinkButtonFont(cancelBtn)
    cancelBtn:SetCallback("OnClick", function()
      f.frame:Hide()
    end)
    btnRow:AddChild(cancelBtn)

    promptFrame = f
  end

  promptFrame:SetTitle(title)
  promptFrame.promptBox:SetText(defaultText or "")
  local function Accept()
    promptFrame.frame:Hide()
    onAccept(ns.Trim(promptFrame.promptBox:GetText()))
  end
  promptFrame.promptBox:SetCallback("OnEnterPressed", function(_, _, text)
    promptFrame.frame:Hide()
    onAccept(ns.Trim(text))
  end)
  promptFrame.promptOkBtn:SetCallback("OnClick", Accept)

  promptFrame.frame:Show()
  promptFrame.promptBox:SetFocus()
  promptFrame.promptBox:HighlightText()
end

StaticPopupDialogs["MAKEIDIOTSAPPEAR_CONFIRM_DELETE_GROUPCOMP"] = {
  text = "Delete composition '%s'? This cannot be undone.",
  button1 = "Delete",
  button2 = "Cancel",
  OnAccept = function(self, data)
    if not (data and data.rosterName and data.compName) then return end
    if not ns.DeleteGroupComp(data.rosterName, data.compName) then
      print(PREFIX .. "Can't delete the only composition for this roster.")
    end
    RefreshGroupsWindow()
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- ns.ComputeUnassigned only knows about the roster; this also surfaces
-- anyone currently in the raid/party who isn't on the roster at all (e.g. a
-- last-minute pug) - the same "not in list" concept UI_Main.lua's extras row
-- flags, but here they're draggable into a group slot too, not just noted.
-- Takes groupSet rather than calling ns.GetGroupNameSet() itself, since
-- DoRefreshGroupsWindow already computes it once for the group slots and
-- would otherwise trigger a second full raid/party scan on every refresh.
local function ComputeUnassignedWithExtras(rosterList, comp, groupSet)
  local unassigned = ns.ComputeUnassigned(rosterList, comp)

  local placed = {}
  for i = 1, GROUPS_PER_COMP do
    for p = 1, SLOTS_PER_GROUP do
      local name = comp.groups[i][p]
      if name then
        placed[name:lower()] = true
      end
    end
  end

  local rosterKeys = {}
  for _, name in ipairs(rosterList) do
    rosterKeys[name:lower()] = true
    rosterKeys[ns.NamePart(name)] = true
  end

  local extras = {}
  for key, fullName in pairs(groupSet) do
    if not rosterKeys[key] and not rosterKeys[ns.NamePart(fullName)] and not placed[key] then
      table.insert(extras, fullName)
    end
  end
  table.sort(extras)

  for _, name in ipairs(extras) do
    table.insert(unassigned, name)
  end
  return unassigned
end

-- One shared handler (reading the name stashed on the clicked button)
-- instead of a fresh closure per composition button on every single refresh
-- - RefreshCompList runs on essentially every FireStateChanged, not just
-- when the user actually manages compositions.
local function OnCompButtonClick(widget)
  ns.SetActiveGroupComp(currentRosterName, widget.compName)
  RefreshGroupsWindow()
end

local function RefreshCompList(data)
  compListScroll:ReleaseChildren()
  for _, comp in ipairs(data.comps) do
    local btn = AceGUI:Create("Button")
    btn:SetFullWidth(true)
    local label = comp.name
    if comp.name == data.activeComp then
      label = label .. "  |cff33ff99(active)|r"
    end
    btn:SetText(label)
    ns.ShrinkButtonFont(btn)
    btn.compName = comp.name
    btn:SetCallback("OnClick", OnCompButtonClick)
    compListScroll:AddChild(btn)
  end
  compListScroll:DoLayout()
  -- Rebuilding doesn't reset a stale scroll offset from before this call on
  -- its own (see UI_Main.lua's RefreshPlayerList, which has to explicitly
  -- save/restore scroll for the same reason) - pin it to the top so a short
  -- list can never end up scrolled past its own content and look empty.
  compListScroll:SetScroll(0)
end

----------------------------------------------------------------------
-- Full refresh
----------------------------------------------------------------------

local function DoRefreshGroupsWindow()
  local rosterList = GetRosterList()
  local comp, data = GetComp()
  local classMap = ns.GetClassMap()
  local groupSet = ns.GetGroupNameSet()
  local rlFullName = ns.FindRaidLeader()

  -- Bench = roster entries past the roster's own group size (see
  -- ns.GetRosterGroupSize) - same split UI_Main.lua's player list uses,
  -- keyed lower-case to match rosterKeys' own lookup convention in
  -- ComputeUnassignedWithExtras below.
  local groupSize = ns.GetRosterGroupSize(currentRosterName)
  local benchSet = {}
  for i, name in ipairs(rosterList) do
    if i > groupSize then
      benchSet[name:lower()] = true
    end
  end

  groupsFrame:SetTitle("Manage Groups - " .. currentRosterName)

  for g = 1, GROUPS_PER_COMP do
    local list = comp.groups[g]
    for p = 1, SLOTS_PER_GROUP do
      local slot = slotFrames[g][p]
      ResetSlotHome(slot)
      SetSlotEditBoxDisplay(slot, list[p], classMap, groupSet, benchSet, rlFullName)
    end
  end

  -- Tokens fill the pool's actual current width instead of a fixed
  -- SLOT_WIDTH - GetWidth() only reflects real, laid-out geometry once
  -- AceGUI has run layout at least once, which is already true by the time
  -- this runs (BuildGroupsFrame calls RefreshGroupsWindow itself right after
  -- creating the frame); the SLOT_WIDTH fallback just guards the
  -- off-chance that isn't true yet.
  local tokenWidth = unassignedScrollFrame:GetWidth()
  if not tokenWidth or tokenWidth <= 0 then
    tokenWidth = SLOT_WIDTH
  end
  unassignedContent:SetWidth(tokenWidth)

  local unassigned = ComputeUnassignedWithExtras(rosterList, comp, groupSet)
  unassignedGroup:SetTitle(("Unassigned (%d)"):format(#unassigned))
  for i, name in ipairs(unassigned) do
    local token = AcquireUnassignedToken(i)
    token:SetWidth(tokenWidth)
    token.playerName = name
    SetTokenDisplay(token, name, classMap, groupSet, benchSet, rlFullName)
    token:ClearAllPoints()
    token:SetPoint("TOPLEFT", unassignedContent, "TOPLEFT", 0, -(i - 1) * (SLOT_HEIGHT + SLOT_GAP))
    token:Show()
  end
  for i = #unassigned + 1, #unassignedTokenPool do
    unassignedTokenPool[i]:Hide()
  end

  -- Resize the scroll child to fit exactly the tokens actually shown, so
  -- unassignedScrollFrame's own scrollbar range (set automatically by
  -- ScrollFrameTemplate off this frame's height vs the scrollframe's) always
  -- matches the current unassigned count instead of a stale one from before
  -- someone got added/removed.
  unassignedContent:SetHeight(math.max(#unassigned * (SLOT_HEIGHT + SLOT_GAP), 1))

  RefreshCompList(data)

  -- Mirrors DeleteGroupComp's own "can't delete the only composition" guard
  -- (see the confirm-delete popup's OnAccept above) - disabled up front here
  -- instead of just relying on that guard, so it's not clickable at all when
  -- it would just print a rejection.
  deleteBtn:SetDisabled(#data.comps <= 1)

  local engine = ns.GroupApplyEngine
  if engine.pending then
    applyBtn:SetDisabled(true)
    applyBtn:SetText("Applying...")
    applyStatusLabel:SetText("Moving players into place - this can take a few moments.")
  elseif not IsInRaid() then
    -- Mirrors ApplyGroupComposition's own "must be in a raid group" reject -
    -- disabled up front instead of relying on that reject printing after the
    -- click.
    applyBtn:SetDisabled(true)
    applyBtn:SetText("Apply Groups")
    applyStatusLabel:SetText("")
  elseif not (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then
    -- Applying moves other players around via Set/SwapRaidSubgroup, which
    -- silently fails server-side for anyone without raid leader/assist -
    -- disabled here rather than letting it click through and do nothing.
    applyBtn:SetDisabled(true)
    applyBtn:SetText("Apply Groups")
    applyStatusLabel:SetText("")
  elseif ns.IsGroupCompInOrder(comp) then
    applyBtn:SetDisabled(true)
    applyBtn:SetText("All Groups in Order")
    applyStatusLabel:SetText("")
  else
    applyBtn:SetDisabled(false)
    applyBtn:SetText("Apply Groups")
    applyStatusLabel:SetText("")
  end
end

-- Wrapped in pcall so a bug in any one part of this custom raw-frame UI
-- (there's no AceGUI/FrameXML safety net here like there is for the addon's
-- other windows) can't silently abort the rest of the refresh - previously
-- an error partway through (say, in the group-slot loop) would leave
-- everything after it (the composition list, the unassigned pool, the Apply
-- button state) stuck showing stale/empty content with nothing printed to
-- explain why.
RefreshGroupsWindow = function()
  if not groupsFrame then return end
  local ok, err = pcall(DoRefreshGroupsWindow)
  if not ok then
    print(PREFIX .. "Manage Groups failed to refresh: " .. tostring(err))
  end
end

local function RefreshIfOpen()
  if groupsFrame and groupsFrame.frame:IsShown() then
    -- Follow the active roster if it changed elsewhere (e.g. "Set Active" in
    -- Manage Rosters) while this window was already open, the same way the
    -- main window already does - instead of only picking up the new roster
    -- the next time ShowGroupManagerFrame is called.
    local activeRoster = MakeIdiotsAppearDB.settings.activeRoster
    if activeRoster and activeRoster ~= currentRosterName then
      currentRosterName = activeRoster
    end
    RefreshGroupsWindow()
  end
end
ns.RegisterListener(RefreshIfOpen)

----------------------------------------------------------------------
-- Window construction
----------------------------------------------------------------------

local function BuildGroupsFrame()
  local f = AceGUI:Create("Frame")
  ns.ApplyTooltipWindowStyle(f)
  f:SetTitle("Manage Groups")
  f:SetStatusText("")
  f:SetLayout("Flow")
  f:EnableResize(false)

  -- See UI_Main.lua's BuildMainFrame for why this is all that's needed to
  -- remember window position across sessions.
  MakeIdiotsAppearDB.windowStatus.groups = MakeIdiotsAppearDB.windowStatus.groups or {}
  f:SetStatusTable(MakeIdiotsAppearDB.windowStatus.groups)
  -- 40px wider than the original 800: 15px went to unassignedGroup, which
  -- needed the extra room once it got its own real scrollbar (see
  -- unassignedScrollFrame) - the bar's track sits inset from the
  -- scrollframe's own right edge rather than fully outside it, and the
  -- original width left too little clearance between that and a token's
  -- rightmost content (namely the bench "B" marker). The remaining 25px all
  -- goes to leftGroup below - unassignedGroup/rightGroup's own relative
  -- widths are shrunk just enough to keep their ABSOLUTE pixel width
  -- unchanged as the window grew (see leftGroup's own comment for the math).
  f:SetWidth(840)
  f:SetHeight(680)

  -- Deliberately never AceGUI:Release()'d, unlike the addon's other windows:
  -- releasing would recycle leftGroup/unassignedGroup/rightGroup (and the box
  -- backdrop, apply button, status label) back into AceGUI's shared widget
  -- pool, but those hold plain Blizzard frames (the group boxes, 40 slots,
  -- unassigned tokens) parented directly onto their .content frames that
  -- AceGUI knows nothing about and would never clean up - they'd stay
  -- attached and could bleed into whatever unrelated widget gets handed
  -- that recycled instance next (see UI_Main.lua's PrepareRow for the same
  -- hazard on a smaller scale, with a texture instead of a whole frame
  -- tree). Just hiding and keeping the single instance around for the rest
  -- of the session sidesteps that entirely.
  f:SetCallback("OnClose", function(widget)
    widget.frame:Hide()
  end)

  ----------------------------------------------------------------
  -- Left: group grid
  ----------------------------------------------------------------

  local leftGroup = AceGUI:Create("InlineGroup")
  leftGroup:SetTitle("Groups")
  -- Left blank ("List" default, never given any AceGUI children - the group
  -- grid below is raw frames parented straight to leftGroup.content).
  -- Deliberately left a hair under 1.0 when summed with unassignedGroup/
  -- rightGroup below (0.4861 + 0.2374 + 0.2665 = 0.99) - see UI_Rosters.lua's
  -- leftGroup for why: AceGUI's "Flow" layout (used by this window's outer
  -- frame) can wrap a child to a new row if pixel-rounding pushes the
  -- combined width a fraction over the container's. That buffer is only 1%
  -- now (was 3%, when this summed to 0.97) - tightened since a hair under 1.0
  -- has been enough margin in practice.
  --
  -- AceGUI's Frame content area is inset 17px from each side (see
  -- AceGUIContainer-Frame.lua's content:SetPoint calls), so content width is
  -- window width minus 34: 781px at the old 815px window, 806px now at 840px.
  -- unassignedGroup/rightGroup's fractions below were both recalculated as
  -- (old fraction * 781 / 806) to keep their ABSOLUTE pixel width exactly
  -- what it was before the window grew - every pixel of the extra room (25px
  -- of window width, ~24px of content width) goes to leftGroup here instead,
  -- pushing its own fraction up from 0.45 accordingly.
  leftGroup:SetRelativeWidth(0.4861)
  leftGroup.noAutoHeight = true
  leftGroup:SetHeight(PANEL_HEIGHT)
  f:AddChild(leftGroup)

  allSlotFrames = {}
  for g = 1, GROUPS_PER_COMP do
    local col = (g - 1) % 2
    local row = math.floor((g - 1) / 2)
    local x = GROUP_GRID_LEFT_PADDING + col * (GROUP_BOX_WIDTH + GROUP_BOX_GAP_X)
    local y = -(row * (GROUP_BOX_HEIGHT + GROUP_BOX_GAP_Y))
    CreateGroupBox(leftGroup.content, g, x, y)
  end

  ----------------------------------------------------------------
  -- Center: unassigned pool
  ----------------------------------------------------------------

  unassignedGroup = AceGUI:Create("InlineGroup")
  unassignedGroup:SetTitle("Unassigned")
  -- Same as leftGroup above - no AceGUI children, tokens are raw frames.
  -- Absolute pixel width unchanged from before the window grew to 840 - see
  -- leftGroup's own comment for the fraction recalculation this and
  -- rightGroup below both got.
  unassignedGroup:SetRelativeWidth(0.2374)
  unassignedGroup.noAutoHeight = true
  unassignedGroup:SetHeight(PANEL_HEIGHT)
  f:AddChild(unassignedGroup)

  -- A real Blizzard ScrollFrame (rather than another raw-frame trick like
  -- the group grid above) - unlike the fixed 40-slot grid, the unassigned
  -- pool's row count varies with roster size and can otherwise overflow
  -- past the bottom of the panel. UIPanelScrollFrameTemplate wires up mouse
  -- wheel scrolling and the scrollbar's range automatically off the scroll
  -- child's height (set every refresh below), same template AceGUI's own
  -- MultiLineEditBox uses under the hood for playersBox in UI_Rosters.lua.
  -- Needs an explicit name (nil won't do) since the template's scrollbar is
  -- anchored via "$parent" substitution - safe as a fixed global name since
  -- groupsFrame (and so this) is only ever built once per session.
  unassignedScrollFrame = CreateFrame("ScrollFrame", "MakeIdiotsAppearUnassignedScrollFrame", unassignedGroup.content,
    "UIPanelScrollFrameTemplate")
  unassignedScrollFrame:SetPoint("TOPLEFT", unassignedGroup.content, "TOPLEFT", 0, 0)
  -- Only -2 now (was -22) - the scrollbar itself is hidden below, so this no
  -- longer needs to leave room for its visible track/thumb, just a hair of
  -- breathing room so tokens don't butt right up against the panel edge.
  unassignedScrollFrame:SetPoint("BOTTOMRIGHT", unassignedGroup.content, "BOTTOMRIGHT", -2, 0)

  -- Permanently hide the template's scrollbar (track, thumb, and up/down
  -- buttons, all children of this Slider so hiding it hides them too) - it
  -- was always visible even when every token fit without scrolling, and ate
  -- ~20px of width permanently reserved for it (see the -22 this replaced
  -- above). A plain :Hide() alone isn't enough: the template's own
  -- OnScrollRangeChanged re-Show()s this bar itself the moment
  -- unassignedContent's height overflows the scrollframe's (which is most
  -- of the time - see DoRefreshGroupsWindow, run on every refresh), undoing
  -- a one-off Hide() call almost immediately. Overriding Show as a no-op
  -- short-circuits that for good, since it's a plain Lua method call on this
  -- object and instance-level functions win over the inherited one.
  -- Mouse wheel scrolling still works without it: ScrollFrameTemplate's own
  -- OnMouseWheel handler drives this slider's value programmatically via
  -- SetValue, which still fires OnValueChanged (and so still scrolls the
  -- content) regardless of the slider's own visibility - only *dragging the
  -- thumb by hand* stops working, and there was never a visible thumb left
  -- to drag once this is hidden anyway. EnableMouse(false) on top makes sure
  -- the invisible slider can't still eat clicks meant for the row underneath
  -- it. Named lookup (rather than a return value) because
  -- UIPanelScrollFrameTemplate creates the bar itself at CreateFrame time -
  -- same pattern AceGUI's own MultiLineEditBox uses for this exact template.
  local unassignedScrollBar = _G[unassignedScrollFrame:GetName() .. "ScrollBar"]
  unassignedScrollBar.Show = function() end
  unassignedScrollBar:Hide()
  unassignedScrollBar:EnableMouse(false)

  unassignedContent = CreateFrame("Frame", "MakeIdiotsAppearUnassignedScrollChild", unassignedScrollFrame)
  unassignedContent:SetSize(SLOT_WIDTH, 1) -- both recalculated every refresh, see DoRefreshGroupsWindow's tokenWidth
  unassignedScrollFrame:SetScrollChild(unassignedContent)
  unassignedTokenPool = {}

  ----------------------------------------------------------------
  -- Right: composition list + management buttons
  ----------------------------------------------------------------

  local rightGroup = AceGUI:Create("InlineGroup")
  rightGroup:SetTitle("Compositions")
  rightGroup:SetLayout("List")
  -- See leftGroup's own comment above - absolute pixel width unchanged from
  -- before the window grew to 840, same as unassignedGroup.
  rightGroup:SetRelativeWidth(0.2665)
  rightGroup.noAutoHeight = true
  rightGroup:SetHeight(PANEL_HEIGHT)
  f:AddChild(rightGroup)

  compListScroll = AceGUI:Create("ScrollFrame")
  compListScroll:SetLayout("List")
  compListScroll:SetFullWidth(true)
  -- Reserves room below the list for the New row, Reset/Duplicate,
  -- Rename/Delete, the 20px spacer, and Apply Groups + its status label -
  -- trimmed tighter than a generic guess would be, to help keep the window
  -- height down now that Apply Groups lives here instead of under the (much
  -- taller) group grid.
  compListScroll:SetHeight(PANEL_HEIGHT - 175)
  rightGroup:AddChild(compListScroll)

  local newRow = AceGUI:Create("SimpleGroup")
  newRow:SetLayout("Flow")
  newRow:SetFullWidth(true)
  rightGroup:AddChild(newRow)

  local newBtn = AceGUI:Create("Button")
  newBtn:SetText("New")
  newBtn:SetRelativeWidth(0.99)
  newBtn:SetHeight(20)
  ns.ShrinkButtonFont(newBtn)
  newBtn:SetCallback("OnClick", function()
    ns.AddGroupComp(currentRosterName, "New Composition")
    RefreshGroupsWindow()
  end)
  newRow:AddChild(newBtn)

  local btnRow1 = AceGUI:Create("SimpleGroup")
  btnRow1:SetLayout("Flow")
  btnRow1:SetFullWidth(true)
  rightGroup:AddChild(btnRow1)

  local resetBtn = AceGUI:Create("Button")
  resetBtn:SetText("Reset")
  resetBtn:SetWidth(95)
  resetBtn:SetHeight(20)
  ns.ShrinkButtonFont(resetBtn)
  resetBtn:SetCallback("OnClick", function()
    -- Re-chunks the active composition's groups from the roster's current
    -- player-list order, discarding any manual drag/edit arrangement in this
    -- composition (this is the only way Default - or any other comp - gets
    -- resynced to the roster's order now; roster saves no longer do it).
    local comp = GetComp()
    comp.groups = ns.ChunkListIntoGroups(GetRosterList())
    RefreshGroupsWindow()
  end)
  btnRow1:AddChild(resetBtn)

  local duplicateBtn = AceGUI:Create("Button")
  duplicateBtn:SetText("Duplicate")
  duplicateBtn:SetWidth(95)
  duplicateBtn:SetHeight(20)
  ns.ShrinkButtonFont(duplicateBtn)
  duplicateBtn:SetCallback("OnClick", function()
    local comp = GetComp()
    ns.AddGroupComp(currentRosterName, comp.name .. " Copy", comp.name)
    RefreshGroupsWindow()
  end)
  btnRow1:AddChild(duplicateBtn)

  local btnRow2 = AceGUI:Create("SimpleGroup")
  btnRow2:SetLayout("Flow")
  btnRow2:SetFullWidth(true)
  rightGroup:AddChild(btnRow2)

  local renameBtn = AceGUI:Create("Button")
  renameBtn:SetText("Rename")
  renameBtn:SetWidth(95)
  renameBtn:SetHeight(20)
  ns.ShrinkButtonFont(renameBtn)
  renameBtn:SetCallback("OnClick", function()
    local comp = GetComp()
    local oldName = comp.name
    ShowTextPrompt("Rename composition", oldName, function(newName)
      if not ns.RenameGroupComp(currentRosterName, oldName, newName) then
        print(PREFIX .. "Could not rename - name is blank or already in use.")
      end
      RefreshGroupsWindow()
    end)
  end)
  btnRow2:AddChild(renameBtn)

  deleteBtn = AceGUI:Create("Button")
  deleteBtn:SetText("Delete")
  deleteBtn:SetWidth(95)
  deleteBtn:SetHeight(20)
  ns.ShrinkButtonFont(deleteBtn)
  deleteBtn:SetCallback("OnClick", function()
    local comp = GetComp()
    StaticPopup_Show("MAKEIDIOTSAPPEAR_CONFIRM_DELETE_GROUPCOMP", comp.name, nil,
      { rosterName = currentRosterName, compName = comp.name })
  end)
  btnRow2:AddChild(deleteBtn)

  -- "List" layout stacks children top-down with zero gap and no fill option,
  -- so a spacer is what pushes the status text + Apply Groups down a bit
  -- from Rename/Delete.
  local applySpacer = AceGUI:Create("SimpleGroup")
  applySpacer:SetFullWidth(true)
  applySpacer.noAutoHeight = true
  applySpacer:SetHeight(20)
  rightGroup:AddChild(applySpacer)

  -- Label auto-sizes to its own text (it ignores SetHeight - recalculates on
  -- every SetText), so it's wrapped in a fixed-height container instead:
  -- otherwise Apply Groups below it would shift up/down every time the
  -- status text changed length (including appearing/disappearing entirely).
  local statusRow = AceGUI:Create("SimpleGroup")
  statusRow:SetFullWidth(true)
  statusRow.noAutoHeight = true
  statusRow:SetHeight(16)
  rightGroup:AddChild(statusRow)

  applyStatusLabel = AceGUI:Create("Label")
  applyStatusLabel:SetFullWidth(true)
  applyStatusLabel:SetText("")
  statusRow:AddChild(applyStatusLabel)

  applyBtn = AceGUI:Create("Button")
  applyBtn:SetText("Apply Groups")
  applyBtn:SetFullWidth(true)
  ns.ShrinkButtonFont(applyBtn)
  applyBtn:SetCallback("OnClick", function()
    ns.ApplyGroupComposition((GetComp()))
    RefreshGroupsWindow()
  end)
  rightGroup:AddChild(applyBtn)

  return f
end

----------------------------------------------------------------------
-- Public entry point
----------------------------------------------------------------------

function ns.ShowGroupManagerFrame()
  ns.EnsureDB()

  local activeRoster = MakeIdiotsAppearDB.settings.activeRoster
  if not activeRoster then
    print(PREFIX .. "No active roster selected. Use Manage Rosters to create/select one first.")
    return
  end

  currentRosterName = activeRoster

  if groupsFrame then
    groupsFrame.frame:Show()
    RefreshGroupsWindow()
    return
  end

  groupsFrame = BuildGroupsFrame()
  RefreshGroupsWindow()
end

-- Closes the window if it's already open instead of just re-showing/
-- refreshing it, for the main frame's Groups button - a second press
-- toggles it shut rather than being a no-op.
function ns.ToggleGroupManagerFrame()
  if groupsFrame and groupsFrame.frame:IsShown() then
    groupsFrame.frame:Hide()
    return
  end
  ns.ShowGroupManagerFrame()
end
