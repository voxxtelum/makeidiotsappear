-- MakeIdiotsAppear.lua
-- Core: saved variables, name normalization, master roster tracking, invite engine.

local ADDON_NAME, ns = ...
ns.ADDON_NAME = ADDON_NAME

local PREFIX = "|cff33ff99MakeIdiotsAppear|r: "
ns.PREFIX = PREFIX

-- Reads the "## Version:" line from MakeIdiotsAppear.toc, so the addon's
-- actual shipped version (rather than a separately-maintained copy of it)
-- is available wherever it's needed - currently just the Main window's
-- title, but kept as a general-purpose accessor for future uses.
-- C_AddOns.GetAddOnMetadata is the current API; GetAddOnMetadata is kept as
-- a fallback for older clients where it's still the global.
local function GetAddonVersion()
  local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  return (getMetadata and getMetadata(ADDON_NAME, "Version")) or "?"
end
ns.GetAddonVersion = GetAddonVersion

-- Toggled via "/mia debug" (or "/ri debug" / "/ric debug"). Gates the extra
-- diagnostic prints scattered through the invite/durability engine (see
-- DebugPrint below) - harmless to leave in permanently, since they're
-- silent unless someone turns it on.
local function DebugPrint(msg)
  if MakeIdiotsAppearDB and MakeIdiotsAppearDB.settings and MakeIdiotsAppearDB.settings.debugMode then
    print(PREFIX .. "[debug] " .. msg)
  end
end
ns.DebugPrint = DebugPrint

----------------------------------------------------------------------
-- UI helpers
----------------------------------------------------------------------

-- ElvUI (and similar unitframe/skinning suites) automatically re-skins
-- every Ace3-based frame it finds, replacing whatever border/background
-- AceGUI itself drew with its own flat style. Our own border/title changes
-- below would only fight that - drawn first, then either fought over or
-- left looking inconsistent next to ElvUI's actual skin - so this bails out
-- entirely and leaves AceGUI's stock look in place whenever ElvUI is
-- loaded, letting it reskin normally instead. C_AddOns.IsAddOnLoaded is the
-- current API; IsAddOnLoaded is kept as a fallback for older clients where
-- it's still the global.
local function IsElvUILoaded()
  local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  return isLoaded and isLoaded("ElvUI") and true or false
end

-- Swaps AceGUI's Frame widget's own default look (the thick ornate
-- Interface\DialogFrame\UI-DialogBox-Border/Header, on a parchment
-- background) for a plainer Blizzard tooltip-style look instead - both the
-- edgeFile (the same one AceGUI's own InlineGroup/TabGroup widgets already
-- use for panel borders elsewhere in this addon, see PaneBackdrop in
-- AceGUIContainer-InlineGroup.lua) and the bgFile, tinted black via
-- ApplyTooltipWindowStyle's own SetBackdropColor below to match a normal
-- game tooltip's solid dark look rather than the lighter parchment tone.
--
-- The ornate rope-and-post title banner is a separate thing entirely - not
-- part of the backdrop, but three individual textures (a center piece plus
-- left/right end caps) AceGUI draws directly onto the frame. Only the center
-- one is exposed on the widget table (as .titlebg); the two end caps aren't
-- exposed at all, and can't be reliably picked out by matching their
-- texture path (Texture:GetTexture() can return either the path or a
-- numeric fileID depending on client version - comparing against a
-- hardcoded path string silently matches nothing on a client that returns
-- the fileID) or by blanket-hiding every texture region on frame (this
-- particular client implements SetBackdrop itself via real texture regions
-- parented to frame too, so that wiped out the border/background as well).
-- What's reliable: both end caps are anchored specifically *to* titlebg
-- (SetPoint(..., titlebg, ...)) in AceGUI's own Constructor, which nothing
-- backdrop-related would be - so this hides titlebg directly, then any
-- other texture region on frame whose anchor points back to it.
local WINDOW_BORDER = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true,
  tileSize = 16,
  edgeSize = 16,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local function IsAnchoredTo(region, target)
  for i = 1, region:GetNumPoints() do
    local _, relativeTo = region:GetPoint(i)
    if relativeTo == target then
      return true
    end
  end
  return false
end

local function ApplyTooltipWindowStyle(aceFrame)
  if IsElvUILoaded() then return end

  local frame = aceFrame.frame
  frame:SetBackdrop(WINDOW_BORDER)
  -- AceGUI's own Frame widget only ever calls SetBackdropColor once, for
  -- its original default backdrop (see AceGUIContainer-Frame.lua's
  -- Constructor) - swapping the backdrop via SetBackdrop above doesn't
  -- re-assert a color/opacity for the new one, leaving it rendering
  -- translucent instead of solid. Full black at full alpha is what gives
  -- this a normal, solid game-tooltip look.
  frame:SetBackdropColor(0, 0, 0, 1)

  local titlebg = aceFrame.titlebg
  titlebg:Hide()
  for _, region in ipairs({ frame:GetRegions() }) do
    if region:GetObjectType() == "Texture" and region ~= titlebg and IsAnchoredTo(region, titlebg) then
      region:Hide()
    end
  end

  -- .titletext was anchored 14px below the (now-hidden) banner's own top
  -- edge, which itself sat 12px *above* the frame to match the banner
  -- artwork's floating-tab shape - net result, only ~2px below the frame's
  -- actual top edge, so without the banner the text sits right on top of
  -- (or clipping into) the border instead of comfortably inside it.
  -- Re-anchor it directly to the frame with real padding instead.
  aceFrame.titletext:ClearAllPoints()
  aceFrame.titletext:SetPoint("TOP", frame, "TOP", 0, -10)
end
ns.ApplyTooltipWindowStyle = ApplyTooltipWindowStyle


-- AceGUI's Button widget exposes its text FontString directly as .text;
-- shrink it relative to whatever size/font it already has rather than
-- hardcoding a new one.
--
-- AceGUI recycles "Button" widgets, and a font size set via SetFont persists
-- across that recycling (nothing resets it on Acquire) - callers like
-- UI_Rosters.lua's roster list and UI_Groups.lua's composition list rebuild
-- their buttons from scratch on every refresh, so without a guard this
-- relative "-2 from whatever it currently is" would compound every single
-- refresh, shrinking the same recycled widget smaller and smaller until the
-- text vanished. The flag makes it apply at most once per underlying widget,
-- no matter how many logical buttons reuse that widget over the session.
local BUTTON_FONT_SHRINK = 2
local function ShrinkButtonFont(btn)
  if btn.riFontShrunk then return end
  btn.riFontShrunk = true

  local fontFile, size, fontFlags = btn.text:GetFont()
  btn.text:SetFont(fontFile, size - BUTTON_FONT_SHRINK, fontFlags)
end
ns.ShrinkButtonFont = ShrinkButtonFont

-- Blizzard's "Interface\QuestFrame\UI-QuestLogTitleHighlight" texture,
-- gold-tinted (ADD blend mode's native color is a mostly-white glow, which
-- reads as plain white/grey against this addon's darkened panels without an
-- explicit tint) - used for the persistent "this row is selected" highlight
-- bar in UI_Settings.lua's tab list and UI_Rosters.lua's roster list, plus
-- btn's own built-in hover highlight (mimics the vertical category list in
-- Blizzard's own Interface Options/AddOns list). Returns the persistent
-- highlight texture, hidden by default - the caller shows/hides it to mark
-- selection.
local function ApplyGoldSelectionHighlight(btn)
  local highlight = btn:CreateTexture(nil, "BACKGROUND")
  highlight:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
  highlight:SetBlendMode("ADD")
  highlight:SetVertexColor(1, 0.82, 0)
  highlight:SetAllPoints(btn)
  highlight:Hide()

  btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight", "ADD")
  btn:GetHighlightTexture():SetVertexColor(1, 0.82, 0)

  return highlight
end
ns.ApplyGoldSelectionHighlight = ApplyGoldSelectionHighlight

-- Vertically centers an AceGUI Label's text within a fixed height (padding
-- above/below is however much taller `height` is than the label's own
-- natural text height - the caller works that out).
--
-- A single SetHeight call right after creating the label isn't enough on
-- its own: AceGUI's Label widget recalculates its own frame height from its
-- FontString's *natural* text height every time its OnWidthSet fires (via
-- UpdateImageAnchor internally), which tends to happen repeatedly for a
-- label sitting in a list that gets rebuilt/relaid-out often (both the
-- label's own row layout and an outer scrolling list's layout can each
-- retrigger it), silently overwriting a one-off forced height back to the
-- natural, unpadded one. Wrapping OnWidthSet to re-assert the padded height
-- right after AceGUI's own logic runs is the one place proven to survive
-- all of those passes, since it's the same hook responsible for undoing it
-- in the first place.
--
-- Guarded (and undone in OnRelease) the same way ShrinkButtonFont above is -
-- "Label" is a generic widget type AceGUI recycles for many unrelated
-- purposes throughout this addon, so this must not still be forcing a
-- padded height onto some other Label later.
local function PadLabelVertically(aceLabel, height)
  if not aceLabel.riPadded then
    aceLabel.riPadded = true
    aceLabel.label:SetJustifyV("MIDDLE")

    local originalOnWidthSet = aceLabel.OnWidthSet
    aceLabel.OnWidthSet = function(self, width)
      originalOnWidthSet(self, width)
      self.label:SetHeight(self.riPaddedHeight)
      self.frame:SetHeight(self.riPaddedHeight)
      self.frame.height = self.riPaddedHeight
    end

    aceLabel.OnRelease = function(self)
      self.label:SetJustifyV("TOP")
      self.OnWidthSet = originalOnWidthSet
      self.riPadded = nil
      self.riPaddedHeight = nil
    end
  end

  aceLabel.riPaddedHeight = height
  aceLabel.label:SetHeight(height)
  aceLabel.frame:SetHeight(height)
  aceLabel.frame.height = height
end
ns.PadLabelVertically = PadLabelVertically

-- ChatFontNormal is Blizzard's own default chat text font (Fonts\ARIALN.TTF,
-- i.e. Arial Narrow) - used in several places throughout this addon (player
-- names, roster names, group slot/token text) instead of each widget's own
-- default font, so names read the same as they do everywhere else names show
-- up in chat. delta (typically negative) adjusts the size relative to
-- ChatFontNormal's own default rather than hardcoding an absolute size.
local function GetChatFont(delta)
  local file, height, flags = ChatFontNormal:GetFont()
  return file, height + (delta or 0), flags
end
ns.GetChatFont = GetChatFont

----------------------------------------------------------------------
-- Saved variables / defaults
----------------------------------------------------------------------

MakeIdiotsAppearDB = MakeIdiotsAppearDB or nil

local function EnsureDB()
  if not MakeIdiotsAppearDB then
    MakeIdiotsAppearDB = {}
  end

  -- migrate old field names from earlier versions of the addon
  if MakeIdiotsAppearDB.lists and not MakeIdiotsAppearDB.rosters then
    MakeIdiotsAppearDB.rosters = MakeIdiotsAppearDB.lists
    MakeIdiotsAppearDB.lists = nil
  end

  MakeIdiotsAppearDB.rosters = MakeIdiotsAppearDB.rosters or {}
  -- [lowercase name] = { [lowercase realm] = { realm = "ProperRealm", class = "WARRIOR" or nil } }
  -- A name can be known on more than one realm (e.g. two different real
  -- people both named "Tanku" on different realms), so this is keyed two
  -- levels deep rather than assuming one realm per name.
  MakeIdiotsAppearDB.masterRoster = MakeIdiotsAppearDB.masterRoster or {}

  -- migrate pre-multi-realm entries, where the value was just a plain realm
  -- string (masterRoster[name] = "Realm") instead of today's nested shape.
  for name, value in pairs(MakeIdiotsAppearDB.masterRoster) do
    if type(value) == "string" then
      MakeIdiotsAppearDB.masterRoster[name] = { [value:lower()] = { realm = value, class = nil } }
    end
  end

  MakeIdiotsAppearDB.settings = MakeIdiotsAppearDB.settings or {}
  MakeIdiotsAppearDB.windowStatus = MakeIdiotsAppearDB.windowStatus or
      {} -- per-window {width, height, top, left}, see AceGUI's SetStatusTable
  MakeIdiotsAppearDB.groupComps = MakeIdiotsAppearDB.groupComps or
      {} -- [rosterName] = {activeComp=name, comps={{name=,groups={[1..8]={...}}}, ...}}, see GroupComps.lua
  MakeIdiotsAppearDB.rosterGroupSizes = MakeIdiotsAppearDB.rosterGroupSizes or
      {} -- [rosterName] = 10|20|40, defaults to 20 when unset, see UI_Rosters.lua

  local settings = MakeIdiotsAppearDB.settings
  if settings.lastList and not settings.activeRoster then
    settings.activeRoster = settings.lastList
    settings.lastList = nil
  end

  settings.interval = settings.interval or 120
  settings.messagePrefix = settings.messagePrefix or "[MIA]"
  settings.delayAfterMessage = settings.delayAfterMessage or 5
  if settings.sendGuildMessage == nil then
    settings.sendGuildMessage = true
  end
  settings.guildMessage = settings.guildMessage
      or "Starting raid invites, please watch for your invite!"
  settings.whisperMessage = settings.whisperMessage
      or "Please leave your current group so I can invite you to the raid. I'll try you again shortly."

  if settings.durabilityWarningEnabled == nil then
    settings.durabilityWarningEnabled = true
  end
  settings.durabilityThreshold = settings.durabilityThreshold or 80
  settings.durabilityMessage = settings.durabilityMessage
      or "WARNING: Your durability is at {percent}%. Please repair your gear."

  if settings.debugMode == nil then
    settings.debugMode = false
  end

  if settings.autoMasterLoot == nil then
    settings.autoMasterLoot = false
  end

  if settings.autoLootThreshold == nil then
    settings.autoLootThreshold = false
  end
  settings.lootThresholdQuality = settings.lootThresholdQuality or 3 -- Rare

  if settings.autoPromoteMasterLooter == nil then
    settings.autoPromoteMasterLooter = false
  end
  settings.masterLooterNames = settings.masterLooterNames or ""

  if settings.autoPromoteAssist == nil then
    settings.autoPromoteAssist = false
  end
  settings.assistNames = settings.assistNames or ""

  if settings.activeRoster and not MakeIdiotsAppearDB.rosters[settings.activeRoster] then
    settings.activeRoster = nil
  end
end
ns.EnsureDB = EnsureDB

local DEFAULT_ROSTER_GROUP_SIZE = 20
ns.DEFAULT_ROSTER_GROUP_SIZE = DEFAULT_ROSTER_GROUP_SIZE

-- Shared by UI_Rosters.lua (the picker itself) and UI_Main.lua (splitting a
-- roster into its invited "main" portion vs. bench, see RefreshPlayerList).
local function GetRosterGroupSize(name)
  return (name and MakeIdiotsAppearDB.rosterGroupSizes[name]) or DEFAULT_ROSTER_GROUP_SIZE
end
ns.GetRosterGroupSize = GetRosterGroupSize

-- The "main" portion of a roster that Start Invites actually queues - bench
-- players (past the roster's own group size) are excluded, same split
-- OnStartStopClick (UI_Main.lua) and SyncActiveRosterIntoRun below both need,
-- kept in one place so they can never disagree about who's in vs. benched.
local function GetTrimmedRosterList(rosterName)
  local fullList = MakeIdiotsAppearDB.rosters[rosterName] or {}
  local groupSize = GetRosterGroupSize(rosterName)
  local list = {}
  for i = 1, math.min(groupSize, #fullList) do
    table.insert(list, fullList[i])
  end
  return list
end
ns.GetTrimmedRosterList = GetTrimmedRosterList

----------------------------------------------------------------------
-- Name normalization
----------------------------------------------------------------------

-- Known realm spellings -> proper case. Add more here if needed.
local RealmMap = {
  ["atiesh"]     = "Atiesh",
  ["azuresong"]  = "Azuresong",
  ["oldblanchy"] = "OldBlanchy",
  ["myzrael"]    = "Myzrael",
}

local function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end
ns.Trim = trim

-- Splits a UTF-8 string into an array of individual character byte-strings
-- (1-4 bytes each, per each character's own leading byte). Lua's string
-- library is byte-oriented (#str, :sub(), :upper()/:lower() all operate on
-- bytes, not characters), which silently breaks the moment a name contains
-- an accented letter like "é" (2 bytes) - #str over/undercounts it, and
-- :sub(1,1) grabs only half the character instead of all of it. Anywhere
-- below that needs to reason about actual characters walks the string via
-- this instead.
local function Utf8Chars(str)
  local chars = {}
  local i, len = 1, #str
  while i <= len do
    local b = str:byte(i)
    local charLen = 1
    if b >= 0xF0 then
      charLen = 4
    elseif b >= 0xE0 then
      charLen = 3
    elseif b >= 0xC0 then
      charLen = 2
    end
    table.insert(chars, str:sub(i, i + charLen - 1))
    i = i + charLen
  end
  return chars
end
ns.Utf8Chars = Utf8Chars

-- :lower()/:upper() only remap plain ASCII 'A'-'Z'/'a'-'z' bytes and leave
-- everything else untouched (including every byte of a multi-byte accented
-- character) - so str:lower() on a whole name is always byte-safe, but
-- capitalizing "just the first character" has to go through Utf8Chars
-- first, or a name starting with an accented letter (2-4 bytes) would get
-- truncated to its first byte by a plain :sub(1,1). An accented first
-- letter itself can't actually be uppercased this way (Lua has no Unicode
-- case folding here) - it just passes through as typed instead, which is
-- the safe fallback rather than corrupting it.
local function ProperCase(str)
  if not str or str == "" then return str end
  str = str:lower()
  local chars = Utf8Chars(str)
  chars[1] = chars[1]:upper()
  return table.concat(chars)
end
ns.ProperCase = ProperCase

-- Character-name validity: 2-12 characters, letters only - ASCII or
-- accented (e.g. "æ"/"á", which WoW character names allow) - just not
-- digits/punctuation/whitespace, and no character repeated 3+ times in a
-- row. Digits/punctuation/whitespace are always single ASCII bytes and
-- never appear inside a multi-byte UTF-8 character, so screening those out
-- via %d/%p/%s is enough to let any accented letter through without having
-- to positively enumerate every letter WoW's locales support.
local function IsValidPlayerDbName(name)
  if not name or name == "" then return false end
  if name:find("[%d%p%s]") then return false end

  local chars = Utf8Chars(name)
  if #chars < 2 or #chars > 12 then return false end

  -- Case-insensitive for single-byte (ASCII) characters, same as before -
  -- :lower() can't case-fold a multi-byte accented character (see
  -- ProperCase above), so a repeated accented letter only matches here
  -- byte-for-byte exact, e.g. three literal "é"s in a row.
  for i = 3, #chars do
    local a, b, c = chars[i], chars[i - 1], chars[i - 2]
    if #a == 1 then a = a:lower() end
    if #b == 1 then b = b:lower() end
    if #c == 1 then c = c:lower() end
    if a == b and b == c then return false end
  end

  return true
end
ns.IsValidPlayerDbName = IsValidPlayerDbName

-- Trims/lowercases input and looks it up in RealmMap, returning the
-- proper-cased realm name or nil if it's not a realm we know about.
local function NormalizeRealmName(input)
  if not input then return nil end
  input = trim(input)
  if input == "" then return nil end
  return RealmMap[input:lower()]
end
ns.NormalizeRealmName = NormalizeRealmName

-- Returns array of {realm=ProperRealm, class=classFileOrNil} for a
-- lowercase bare name - 0, 1, or many (see masterRoster's own comment in
-- EnsureDB for why a single name can be known on more than one realm).
local function GetKnownRealmEntries(lowerName)
  local entries = {}
  local byRealm = MakeIdiotsAppearDB.masterRoster[lowerName]
  if byRealm then
    for _, data in pairs(byRealm) do
      table.insert(entries, { realm = data.realm, class = data.class })
    end
  end
  return entries
end
ns.GetKnownRealmEntries = GetKnownRealmEntries

-- Returns: normalizedString, needsRealm (bool)
-- normalizedString is "Name-Realm" if we could resolve a realm, otherwise just "Name".
local function NormalizePlayerName(input)
  input = trim(input or "")
  if input == "" then return nil, false end

  -- strip any accidental leading garbage like bullets/numbers "1. " etc.
  input = input:gsub("^[%d%.%)%-%s]*", "", 1)
  input = trim(input)
  if input == "" then return nil, false end

  local namePart, realmPart = input:match("^([^%-]+)%-(.+)$")
  if not namePart then
    namePart = input
    realmPart = nil
  end

  namePart = ProperCase(trim(namePart))

  -- A realm suffix only counts as resolved if it's one of RealmMap's known
  -- realms - an unrecognized/misspelled realm (e.g. "-Aztiesh") falls through
  -- to the masterRoster lookup below just like a missing realm would, rather
  -- than being accepted as-is via ProperCase.
  local resolvedRealm = realmPart and NormalizeRealmName(realmPart) or nil
  if not resolvedRealm then
    -- Only auto-resolve a bare name when it's known on exactly one realm -
    -- if it's known on two or more, there's no way to guess which one was
    -- meant, so this falls through to "needs realm" just like a completely
    -- unknown name would.
    local known = GetKnownRealmEntries(namePart:lower())
    if #known == 1 then
      resolvedRealm = known[1].realm
    end
  end

  if resolvedRealm then
    return namePart .. "-" .. resolvedRealm, false
  else
    return namePart, true
  end
end
ns.NormalizePlayerName = NormalizePlayerName

local function ParsePastedText(text)
  local result = {}
  for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
    local t = trim(line)
    if t ~= "" then
      table.insert(result, t)
    end
  end
  return result
end
ns.ParsePastedText = ParsePastedText

-- Normalizes a whole list, returns cleaned array + array of names still needing a realm
local function NormalizeList(rawLines)
  local cleaned, needsRealm = {}, {}
  for _, line in ipairs(rawLines) do
    local norm, unresolved = NormalizePlayerName(line)
    if norm then
      table.insert(cleaned, norm)
      if unresolved then
        table.insert(needsRealm, norm)
      end
    end
  end
  return cleaned, needsRealm
end
ns.NormalizeList = NormalizeList

local function NamePart(full)
  return (full and full:match("^([^%-]+)") or full or ""):lower()
end
ns.NamePart = NamePart

----------------------------------------------------------------------
-- Master roster tracking (learn Name-Realm pairs from people who join)
----------------------------------------------------------------------

local function GetOwnRealm()
  return (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
end

-- Same-name characters on different realms are different people. Anywhere
-- we only have a bare name (no "-Realm" suffix) we assume our own realm,
-- since that's true for group members and for most guild rosters - this
-- keeps every lookup keyed on a full, unambiguous "Name-Realm" identity.
local function ResolveFullName(name, realm)
  if not name then return nil end
  if name:find("%-") then return name end
  if not realm or realm == "" then
    realm = GetOwnRealm()
  end
  if not realm then return name end
  return name .. "-" .. realm
end
ns.ResolveFullName = ResolveFullName

local function GetFullUnitName(unit)
  if not UnitExists(unit) then return nil end
  local name, realm = UnitFullName(unit)
  return ResolveFullName(name, realm)
end
ns.GetFullUnitName = GetFullUnitName

-- Adds or updates one masterRoster entry, identified by name+realm (both
-- expected to already be resolved/proper-cased by the caller - this is the
-- single write path, not a validator). class: a class file token sets it,
-- false explicitly clears it, nil (omitted) leaves whatever's already there
-- untouched - lets RecordRosterUnit below update just the realm without
-- clobbering a previously-learned class if UnitClass can't resolve one.
local function UpsertPlayerDbEntry(name, realm, class)
  if not name or name == "" or not realm or realm == "" then return end
  local lowerName, lowerRealm = name:lower(), realm:lower()
  local byRealm = MakeIdiotsAppearDB.masterRoster[lowerName]
  if not byRealm then
    byRealm = {}
    MakeIdiotsAppearDB.masterRoster[lowerName] = byRealm
  end
  local existing = byRealm[lowerRealm]
  local resolvedClass
  if class == false then
    resolvedClass = nil
  elseif class ~= nil then
    resolvedClass = class
  else
    resolvedClass = existing and existing.class or nil
  end
  byRealm[lowerRealm] = { realm = realm, class = resolvedClass }
end
ns.UpsertPlayerDbEntry = UpsertPlayerDbEntry

-- Removes one name+realm entry, cleaning up the now-empty name-level table
-- so GetKnownRealmEntries/GetAllPlayerDbEntries never see stale empty rows.
local function RemovePlayerDbEntry(name, realm)
  if not name or not realm then return end
  local lowerName = name:lower()
  local byRealm = MakeIdiotsAppearDB.masterRoster[lowerName]
  if not byRealm then return end
  byRealm[realm:lower()] = nil
  if next(byRealm) == nil then
    MakeIdiotsAppearDB.masterRoster[lowerName] = nil
  end
end
ns.RemovePlayerDbEntry = RemovePlayerDbEntry

-- Flattens the whole masterRoster into {name=ProperName, realm=ProperRealm,
-- class=classFileOrNil} rows for the Player Database window.
local function GetAllPlayerDbEntries()
  local rows = {}
  for lowerName, byRealm in pairs(MakeIdiotsAppearDB.masterRoster) do
    for _, data in pairs(byRealm) do
      table.insert(rows, { name = ProperCase(lowerName), realm = data.realm, class = data.class })
    end
  end
  return rows
end
ns.GetAllPlayerDbEntries = GetAllPlayerDbEntries

local function RecordRosterUnit(unit)
  local full = GetFullUnitName(unit)
  if not full then return end
  local name, realm = full:match("^(.-)%-(.+)$")
  if name and realm then
    local _, classFile = UnitClass(unit)
    UpsertPlayerDbEntry(name, realm, classFile)
  end
end

local function ScanGroupRoster()
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      RecordRosterUnit("raid" .. i)
    end
  elseif IsInGroup() then
    RecordRosterUnit("player")
    for i = 1, GetNumGroupMembers() - 1 do
      RecordRosterUnit("party" .. i)
    end
  end
end
ns.ScanGroupRoster = ScanGroupRoster

----------------------------------------------------------------------
-- Live status helpers (group membership / guild online state)
----------------------------------------------------------------------

-- Keyed by full lowercased "name-realm" so two characters sharing a name on
-- different realms are never confused for one another. Roster entries that
-- (rarely) still lack a resolved realm fall back to a best-effort name-only
-- match via LookupByFullOrName below - inherently ambiguous, but no worse
-- than before.
local function GetGroupNameSet()
  local set = {}
  local function record(unit)
    local full = GetFullUnitName(unit)
    if full then set[full:lower()] = full end
  end

  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      record("raid" .. i)
    end
  elseif IsInGroup() then
    record("player")
    for i = 1, GetNumGroupMembers() - 1 do
      record("party" .. i)
    end
  end
  return set
end
ns.GetGroupNameSet = GetGroupNameSet

-- Looks a roster entry up in a map keyed by full "name-realm" (as built by
-- GetGroupNameSet/GetGuildOnlineMap/GetClassMap). Falls back to a name-only
-- scan only when the roster entry itself has no resolved realm yet.
local function LookupByFullOrName(map, fullName)
  if not fullName then return nil end
  local key = fullName:lower()
  local value = map[key]
  if value ~= nil then
    return value
  end
  if key:find("%-") then
    return nil
  end
  for mapKey, mapValue in pairs(map) do
    if NamePart(mapKey) == key then
      return mapValue
    end
  end
  return nil
end
ns.LookupByFullOrName = LookupByFullOrName

-- Several guild-roster functions moved from plain globals into the
-- C_GuildInfo namespace in newer clients; fall back to the old global
-- when the namespaced version isn't present (and vice versa).
local function RequestGuildRoster()
  if C_GuildInfo and C_GuildInfo.GuildRoster then
    C_GuildInfo.GuildRoster()
  elseif GuildRoster then
    GuildRoster()
  end
end
ns.RequestGuildRoster = RequestGuildRoster

local function GetGuildOnlineMap()
  local map = {}
  if IsInGuild() then
    local getNum = (C_GuildInfo and C_GuildInfo.GetNumGuildMembers) or GetNumGuildMembers
    local getInfo = (C_GuildInfo and C_GuildInfo.GetGuildRosterInfo) or GetGuildRosterInfo
    local numTotal = getNum and getNum() or 0
    if getInfo then
      for i = 1, numTotal do
        local fullName, _, _, _, _, _, _, _, isOnline = getInfo(i)
        local full = fullName and ResolveFullName(fullName)
        if full then
          map[full:lower()] = isOnline and true or false
        end
      end
    end
  end
  return map
end
ns.GetGuildOnlineMap = GetGuildOnlineMap

-- Companion to GetGuildOnlineMap above, same scan but only for currently-online
-- members and mapping to their properly-cased full name instead of a plain
-- boolean - used by MaybeInviteNewlyOnline below, which needs an actual name to
-- match against the queues and invite, not just an online/offline flag.
local function GetOnlineGuildMembersMap()
  local map = {}
  if IsInGuild() then
    local getNum = (C_GuildInfo and C_GuildInfo.GetNumGuildMembers) or GetNumGuildMembers
    local getInfo = (C_GuildInfo and C_GuildInfo.GetGuildRosterInfo) or GetGuildRosterInfo
    local numTotal = getNum and getNum() or 0
    if getInfo then
      for i = 1, numTotal do
        local fullName, _, _, _, _, _, _, _, isOnline = getInfo(i)
        local full = fullName and ResolveFullName(fullName)
        if full and isOnline then
          map[full:lower()] = full
        end
      end
    end
  end
  return map
end

-- Class comes from three tiers, in priority order: our current group (live,
-- so it wins when available), our guild roster, then the Player Database
-- (MakeIdiotsAppearDB.masterRoster, see GetAllPlayerDbEntries) - covering
-- anyone whose class was learned from a past group or entered manually via
-- /mia playerdb, even if they're not in the guild and not currently grouped
-- with you. Keyed by full "name-realm", same as
-- GetGroupNameSet/GetGuildOnlineMap.
local function GetClassMap()
  local map = {}

  local function record(unit)
    local full = GetFullUnitName(unit)
    if not full then return end
    local _, classFile = UnitClass(unit)
    if classFile then map[full:lower()] = classFile end
  end

  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      record("raid" .. i)
    end
  elseif IsInGroup() then
    record("player")
    for i = 1, GetNumGroupMembers() - 1 do
      record("party" .. i)
    end
  end

  if IsInGuild() then
    local getNum = (C_GuildInfo and C_GuildInfo.GetNumGuildMembers) or GetNumGuildMembers
    local getInfo = (C_GuildInfo and C_GuildInfo.GetGuildRosterInfo) or GetGuildRosterInfo
    local numTotal = getNum and getNum() or 0
    if getInfo then
      for i = 1, numTotal do
        local fullName, _, _, _, _, _, _, _, _, _, classFileName = getInfo(i)
        local full = fullName and ResolveFullName(fullName)
        local key = full and full:lower()
        if key and classFileName and not map[key] then
          map[key] = classFileName
        end
      end
    end
  end

  -- Third tier: the Player Database. Only fills gaps neither the group nor
  -- guild scan above already covered.
  for _, entry in ipairs(GetAllPlayerDbEntries()) do
    if entry.class then
      local key = (entry.name .. "-" .. entry.realm):lower()
      if not map[key] then
        map[key] = entry.class
      end
    end
  end

  return map
end
ns.GetClassMap = GetClassMap

-- C_ClassColor is the modern accessor; RAID_CLASS_COLORS is the classic
-- global table. Try both so this works across client versions.
local function GetClassColor(classFile)
  if not classFile then return nil end
  if C_ClassColor and C_ClassColor.GetClassColor then
    local color = C_ClassColor.GetClassColor(classFile)
    if color then
      return color.r, color.g, color.b
    end
  end
  local legacy = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
  if legacy then
    return legacy.r, legacy.g, legacy.b
  end
  return nil
end
ns.GetClassColor = GetClassColor

-- Returns (list, order) for an AceGUI Dropdown's SetList(list, order):
-- list[classFile] = localized display name, order = classFiles in display
-- order. CLASS_SORT_ORDER is a Blizzard global giving the client's actual
-- canonical class order; RAID_CLASS_COLORS (also a Blizzard global, keyed
-- by class file token) is the fallback source of the token set itself if
-- that's ever missing. Either way this reflects whatever class set the
-- running client actually has - nothing here is hardcoded per-expansion.
local function GetClassList()
  local list, order = {}, {}
  local tokens = CLASS_SORT_ORDER
  if not tokens then
    tokens = {}
    for token in pairs(RAID_CLASS_COLORS or {}) do
      table.insert(tokens, token)
    end
    table.sort(tokens)
  end
  for _, token in ipairs(tokens) do
    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[token] then
      list[token] = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token
      table.insert(order, token)
    end
  end
  return list, order
end
ns.GetClassList = GetClassList

----------------------------------------------------------------------
-- Invite engine
----------------------------------------------------------------------

local Engine = {
  queue = {},      -- names left to invite in the current pass
  nextQueue = {},  -- names bounced/expired/still-missing this pass, held back for the next scheduled interval
  fullRoster = {}, -- the complete set of names this invite run is trying to get grouped
  running = false,
  starting = false,
  ticker = nil,
  startTimer = nil,
  durabilityTicker = nil,   -- retries durability requests every few seconds as a backstop, see StartInvites
  pendingInvites = {},      -- [lowercased "name-realm"] = fullName, currently invited but not yet confirmed
  pendingInviteSentAt = {}, -- [lowercased "name-realm"] = GetTime() when that invite was sent
  skipped = {},             -- names whispered this pass because they're already in another group, or still missing a realm
  nextPassAt = nil,         -- GetTime() timestamp of the next scheduled invite pass, if any
  convertingToRaid = nil,   -- true while waiting on a pending party->raid conversion
  convertRetryCount = 0,    -- how many times we've waited on that conversion so far

  -- Durability checks (see the LibDurability section below). Keyed by bare
  -- lowercase name, not "name-realm" - LibDurability's wire protocol only
  -- ever gives us a bare character name (via Ambiguate), so two same-named
  -- characters on different realms can't be told apart here; this mirrors
  -- the ambiguity the library itself imposes, not something we can avoid.
  durabilityChecked = {},         -- [lowercase name] = true, already warned or found fine this run
  durabilityPending = {},         -- [lowercase name] = fullName, joined and awaiting a durability reply this pass
  durabilityUnknownThisPass = {}, -- fullNames whose check never got a reply before this pass ended
}
ns.Engine = Engine

local listeners = {}
local function FireStateChanged()
  for _, fn in ipairs(listeners) do
    fn()
  end
end
ns.FireStateChanged = FireStateChanged

function ns.RegisterListener(fn)
  table.insert(listeners, fn)
end

local function CountPendingInvites()
  local n = 0
  for _ in pairs(Engine.pendingInvites) do
    n = n + 1
  end
  return n
end
ns.CountPendingInvites = CountPendingInvites

-- Engine.pendingInvites just tracks "we sent an invite and haven't heard
-- back yet" - that's true just as much for an offline target waiting on
-- its bounce-back message as for a real online invitee, so it's not enough
-- on its own to justify a "Pending Invite" status. Only show that when we
-- positively know they're online; a known-offline target always shows
-- "Offline" instead, pending invite or not.
local function ComputeStatus(fullName, groupSet, guildOnlineMap)
  if LookupByFullOrName(groupSet, fullName) then
    return "In Group"
  end

  local online = LookupByFullOrName(guildOnlineMap, fullName)

  if online == false then
    return "Offline"
  end

  if Engine.pendingInvites[fullName:lower()] and online == true then
    return "Pending Invite"
  end

  if online == true then
    return "Online"
  end
  return "-"
end
ns.ComputeStatus = ComputeStatus

-- Seconds until the next scheduled invite pass (the initial post-message
-- delay, or a retry pass for stragglers), or nil if nothing is scheduled.
function ns.GetSecondsUntilNextPass()
  if not Engine.running or not Engine.nextPassAt then
    return nil
  end
  local remaining = Engine.nextPassAt - GetTime()
  if remaining < 0 then remaining = 0 end
  return math.floor(remaining + 0.5)
end

-- Some chat-sending APIs have moved namespaces across client versions (and
-- may simply be missing/broken on a given build); try the modern one, fall
-- back to the classic global, and never let a failure here propagate -
-- a message we can't send should never be able to block the invite cycle.
local function SendChat(message, chatType, target)
  local sender = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
  if not sender then
    return false, "no SendChatMessage API available"
  end
  return pcall(sender, message, chatType, nil, target)
end
ns.SendChat = SendChat

-- Prepends the user-configured prefix (e.g. "[MIA]") to every automated
-- message. A blank prefix is how a user disables it, so an empty string is
-- left as-is rather than falling back to any default.
local function ApplyMessagePrefix(message)
  local prefix = MakeIdiotsAppearDB.settings.messagePrefix
  if prefix and prefix ~= "" then
    return prefix .. " " .. message
  end
  return message
end

local function DoInvite(fullName)
  if C_PartyInfo and C_PartyInfo.InviteUnit then
    C_PartyInfo.InviteUnit(fullName)
  else
    InviteUnit(fullName)
  end
end

-- One-off invite for a single bench player (see UI_Main.lua's "+" button on
-- each bench row) - deliberately not routed through Engine.queue/StartInvites:
-- bench players are excluded from the automated invite run on purpose, and
-- this just needs the same realm-resolution/already-in-group checks
-- RunInvitePass does for its own queue, not that pass's capacity/raid-
-- conversion handling (a manual one-at-a-time click either succeeds or
-- bounces off the game's own party-full response).
local function InvitePlayerManually(fullName)
  if not fullName:find("%-") then
    local known = GetKnownRealmEntries(fullName:lower())
    if #known == 1 then
      fullName = fullName .. "-" .. known[1].realm
    elseif #known > 1 then
      local realms = {}
      for _, entry in ipairs(known) do table.insert(realms, entry.realm) end
      print(PREFIX .. "Multiple realms known for " .. fullName .. " (" .. table.concat(realms, ", ") ..
        ") - specify which one, e.g. " .. fullName .. "-" .. known[1].realm .. ".")
      return
    else
      print(PREFIX .. "Can't invite " .. fullName .. " - no realm on file yet. Add manually later.")
      return
    end
  end

  if LookupByFullOrName(GetGroupNameSet(), fullName) then
    print(PREFIX .. fullName .. " is already in your group.")
    return
  end

  local ok, err = pcall(DoInvite, fullName)
  if ok then
    print(PREFIX .. "Invited " .. fullName .. ".")
  else
    print(PREFIX .. "Could not invite " .. fullName .. " (" .. tostring(err) .. ").")
  end
end
ns.InvitePlayerManually = InvitePlayerManually

local function ConvertPartyToRaid()
  if C_PartyInfo and C_PartyInfo.ConvertToRaid then
    C_PartyInfo.ConvertToRaid()
  elseif ConvertToRaid then
    ConvertToRaid()
  end
end

-- Same namespaced-vs-global fallback as ConvertPartyToRaid above - newer
-- clients moved loot-method access under C_PartyInfo too.
local function DoGetLootMethod()
  if C_PartyInfo and C_PartyInfo.GetLootMethod then
    return C_PartyInfo.GetLootMethod()
  end
  return GetLootMethod()
end

local function DoSetLootMethod(method, index)
  if C_PartyInfo and C_PartyInfo.SetLootMethod then
    C_PartyInfo.SetLootMethod(method, index)
  else
    SetLootMethod(method, index)
  end
end

local function DoLeaveParty()
  if C_PartyInfo and C_PartyInfo.LeaveParty then
    C_PartyInfo.LeaveParty()
  else
    LeaveParty()
  end
end

----------------------------------------------------------------------
-- Durability checks (LibDurability)
----------------------------------------------------------------------
-- Vendored the same way as the AceGUI libs, so this works even for users
-- without DBM/BigWigs installed - LibStub's version registry means our
-- copy just silently steps aside if a newer one is already loaded.

local LD = LibStub("LibDurability")

local function FormatDurabilityWarning(template, percent)
  return (template:gsub("{percent}", tostring(math.floor(percent + 0.5))))
end

-- Anyone still pending when a pass ends never replied in time (no
-- LibDurability, an old version, or simply offline) - report them as one
-- batched message rather than leaving the check hanging forever.
local function ReportDurabilityUnknown()
  for key, fullName in pairs(Engine.durabilityPending) do
    DebugPrint(string.format("Timing out durability check for '%s' (key='%s') - never got a reply this pass.", fullName,
      key))
    table.insert(Engine.durabilityUnknownThisPass, fullName)
    Engine.durabilityPending[key] = nil
  end
  if #Engine.durabilityUnknownThisPass > 0 then
    print(PREFIX .. "Durability could not be checked for: " .. table.concat(Engine.durabilityUnknownThisPass, ", "))
    Engine.durabilityUnknownThisPass = {}
  end
end

-- LibDurability reports names inconsistently: the library's own immediate
-- self-report uses a bare name (UnitName("player")), but Ambiguate(sender,
-- "none") for everyone else's reply turns out to still include the realm
-- (confirmed empirically - "none" does not mean "no realm" here). Engine.
-- durabilityPending is keyed by bare name only, so normalize whatever we
-- got through NamePart before looking it up - safe no-op on an already-bare
-- name, strips "-Realm" when present.
LD:Register(ns, function(percent, broken, name, channel)
  local key = NamePart(name)
  local fullName = Engine.durabilityPending[key]

  if MakeIdiotsAppearDB.settings.debugMode then
    local pendingList = {}
    for _, pendingName in pairs(Engine.durabilityPending) do
      table.insert(pendingList, pendingName)
    end
    DebugPrint(string.format(
      "Durability reply from '%s' (key='%s'): %d%%, matched=%s | currently pending: %s",
      name, key, percent, tostring(fullName), #pendingList > 0 and table.concat(pendingList, ", ") or "(none)"))
  end

  if not fullName then return end

  Engine.durabilityPending[key] = nil
  Engine.durabilityChecked[key] = true

  if percent < MakeIdiotsAppearDB.settings.durabilityThreshold then
    local msg = ApplyMessagePrefix(FormatDurabilityWarning(MakeIdiotsAppearDB.settings.durabilityMessage, percent))
    local ok, err = SendChat(msg, "WHISPER", fullName)
    if not ok then
      print(PREFIX .. "Could not send a durability warning to " .. fullName .. " (" .. tostring(err) .. ").")
    end
  end
end)

-- Called on every GROUP_ROSTER_UPDATE while a run is active (and on a
-- short repeating ticker as a backstop - see StartInvites): queue a
-- durability check for anyone currently in the group who hasn't been
-- checked (warned, or found fine) yet this run. This deliberately checks
-- everyone in the group, not just people on the active invite roster -
-- someone can already be in the raid without being on the list (that's
-- exactly what the "Not In List" row on the main window surfaces), and the
-- whole point of this feature is catching bad durability on whoever's
-- actually there.
--
-- Re-requests every time there's anyone still outstanding, not just when
-- someone new joins this call: LibDurability throttles its own broadcast
-- to once per 4 seconds per channel, so if an earlier request got dropped
-- by that throttle (e.g. several people joined within the same window),
-- nobody would ever ask again for whoever missed out - they'd just sit
-- pending until the pass gives up and reports them as unknown.
local function CheckNewlyJoinedDurability()
  if not Engine.running or not MakeIdiotsAppearDB.settings.durabilityWarningEnabled then
    return
  end

  local groupSet = GetGroupNameSet()
  local ownFullName = GetFullUnitName("player")
  local ownKey = ownFullName and NamePart(ownFullName)

  for _, fullName in pairs(groupSet) do
    local key = NamePart(fullName)
    if key ~= ownKey and not Engine.durabilityChecked[key] and not Engine.durabilityPending[key] then
      Engine.durabilityPending[key] = fullName
      DebugPrint(string.format("Queuing durability check for '%s' (key='%s').", fullName, key))
    end
  end

  if next(Engine.durabilityPending) then
    LD:RequestDurability()
  end
end
ns.CheckNewlyJoinedDurability = CheckNewlyJoinedDurability

local function StopInvites(reason)
  if Engine.ticker then
    Engine.ticker:Cancel()
    Engine.ticker = nil
  end
  if Engine.startTimer then
    Engine.startTimer:Cancel()
    Engine.startTimer = nil
  end
  if Engine.durabilityTicker then
    Engine.durabilityTicker:Cancel()
    Engine.durabilityTicker = nil
  end
  Engine.running = false
  Engine.starting = false
  Engine.pendingInvites = {}
  Engine.pendingInviteSentAt = {}
  Engine.nextPassAt = nil
  Engine.convertingToRaid = nil
  Engine.convertRetryCount = 0
  ReportDurabilityUnknown()
  Engine.durabilityChecked = {}
  if reason then
    print(PREFIX .. reason)
  end
  FireStateChanged()
end
ns.StopInvites = StopInvites

-- Names from the full roster that are not currently in our raid/party -
-- these are the only ones worth another pass. Takes groupSet from the caller
-- rather than fetching it itself - RunInvitePass's own group scan is still
-- valid here (see the comment at its end-of-pass call site), so there's no
-- need to walk the raid/party roster a second time.
local function ComputeStragglers(groupSet)
  local stragglers = {}
  for _, name in ipairs(Engine.fullRoster) do
    -- Skip anyone who still has one of our invites outstanding and not yet
    -- expired (see PruneExpiredPendingInvites) - re-inviting them before
    -- their first invite times out just duplicates it, and the resulting
    -- bounce gets mistaken for a genuine "already in another group" case.
    if not LookupByFullOrName(groupSet, name) and not LookupByFullOrName(Engine.pendingInvites, name) then
      table.insert(stragglers, name)
    end
  end
  return stragglers
end

-- Forward-declared so RunInvitePass can schedule a delayed continuation of
-- itself (through the safe wrapper) after converting party -> raid.
local RunInvitePass
local SafeRunInvitePass

-- Forward-declared so StartInvites (below) can run this once immediately
-- when an invite pass begins - candidates already sitting in the raid
-- before Start Invites was clicked would otherwise never trigger it, since
-- its other call site only fires on the GROUP_ROSTER_UPDATE event, i.e. an
-- actual roster change after that point.
local MaybeAutoPromoteAssist

-- Forward-declared for the same reason as MaybeAutoPromoteAssist above -
-- StartInvites (below) needs to run this once immediately too, to catch an
-- already-existing real party formed before Start Invites was clicked; its
-- other call site is the joinedGroupPattern branch in the CHAT_MSG_SYSTEM
-- handler, further down still.
local MaybeConvertToRaid

-- Forward-declared so RunInvitePass (defined above the real body of this
-- function) can call it - the real body needs ClearPendingInvite, which is
-- only defined later alongside TakePendingInvite.
local PruneExpiredPendingInvites

-- Forward-declared so RunInvitePass's end-of-pass straggler merge (defined
-- above the real body of this function) can call it too, not just the
-- CHAT_MSG_SYSTEM bounce handlers further down.
local RequeueForRetry

-- A party caps out at 5 total, and inviting past that requires being a
-- raid. The server reserves a slot for an invite the instant it's sent, not
-- once it's accepted - including while still completely solo, before
-- GetNumGroupMembers() ever leaves 0 - so yourself (at least 1) plus every
-- outstanding invite has to be counted against the cap from the very first
-- invite of a pass, not just once a party is already confirmed to exist.
-- Every invite immediately counts against the cap alongside confirmed
-- members - even to someone who turns out to be offline - so pending
-- invites have to be counted here too, not just confirmed members, or we'd
-- try to send a 3rd/4th/5th invite the game has already reserved a full
-- party against and have it bounce.
--
-- pendingCount is passed in rather than read via CountPendingInvites() -
-- RunInvitePass calls this once per queued name, and nothing inside that
-- loop can shrink Engine.pendingInvites (only PruneExpiredPendingInvites, at
-- the top of RunInvitePass before the loop starts, does that), so the
-- caller can just track the running count itself instead of re-scanning the
-- whole pendingInvites table on every iteration.
--
-- Returns true if the pass must stop here and wait on a raid conversion,
-- false if there's room to keep inviting.
local function HandleFullPartyCapacity(pendingCount)
  if IsInRaid() then
    Engine.convertingToRaid = nil
    Engine.convertRetryCount = 0
    return false
  end

  local confirmedSize = math.max(GetNumGroupMembers(), 1)
  if confirmedSize + pendingCount < 5 then
    Engine.convertingToRaid = nil
    Engine.convertRetryCount = 0
    return false
  end

  Engine.convertRetryCount = Engine.convertRetryCount + 1
  if Engine.convertRetryCount > 6 then
    print(PREFIX ..
      "Could not convert to a raid automatically - please use /convert to raid manually, then click Start Invites again.")
    Engine.convertingToRaid = nil
    Engine.convertRetryCount = 0
    FireStateChanged()
    return true
  end

  if not Engine.convertingToRaid then
    Engine.convertingToRaid = true
    print(PREFIX .. "Party is full - converting to a raid group so everyone can be invited.")
    ConvertPartyToRaid()
  end
  FireStateChanged()
  C_Timer.After(1.5, SafeRunInvitePass)
  return true
end

-- Invites everyone currently queued, right now, back to back - no waiting
-- between individual invites (up to whatever the group can currently hold -
-- see HandleFullPartyCapacity above). Called once immediately when a run
-- starts (so the whole roster goes out in one go), and again on each
-- retry-pass tick for whoever's still missing.
RunInvitePass = function()
  PruneExpiredPendingInvites()

  local groupSet = GetGroupNameSet()
  local guildOnline = GetGuildOnlineMap()
  local ownFullName = GetFullUnitName("player")
  local pendingCount = CountPendingInvites()

  while #Engine.queue > 0 do
    if HandleFullPartyCapacity(pendingCount) then return end

    local nextName = table.remove(Engine.queue, 1)

    if not nextName:find("%-") then
      local known = GetKnownRealmEntries(nextName:lower())
      if #known == 1 then
        nextName = nextName .. "-" .. known[1].realm
      elseif #known > 1 then
        local realms = {}
        for _, entry in ipairs(known) do table.insert(realms, entry.realm) end
        print(PREFIX .. "Skipping " .. nextName .. " - multiple realms known (" .. table.concat(realms, ", ") ..
          ") - specify which one, e.g. " .. nextName .. "-" .. known[1].realm .. ".")
        table.insert(Engine.skipped, nextName)
        nextName = nil
      else
        print(PREFIX .. "Skipping " .. nextName .. " - no realm on file yet. Add manually later.")
        table.insert(Engine.skipped, nextName)
        nextName = nil
      end
    end

    if nextName and LookupByFullOrName(groupSet, nextName) then
      -- already in our group, nothing to do
      nextName = nil
    end

    if nextName and ownFullName and nextName:lower() == ownFullName:lower() then
      -- never invite ourselves - we're on our own roster because we're a
      -- raid member like anyone else, not because we need an invite
      nextName = nil
    end

    -- A known-offline target still reserves a party slot the instant we
    -- invite it - the server accepts the invite (and thus the reservation)
    -- immediately, but the "player not found" bounce-back that would free
    -- that slot again only arrives asynchronously, well after this
    -- synchronous burst of invites has already finished. So burning a slot
    -- on someone the guild roster already told us is offline can starve a
    -- genuinely online target later in the same queue (see the "party is
    -- full" bug this was fixed for). Skip the invite call entirely.
    if nextName and LookupByFullOrName(guildOnline, nextName) == false then
      table.insert(Engine.skipped, nextName)
      nextName = nil
    end

    if nextName then
      local ok, err = pcall(DoInvite, nextName)
      if ok then
        Engine.pendingInvites[nextName:lower()] = nextName
        Engine.pendingInviteSentAt[nextName:lower()] = GetTime()
        pendingCount = pendingCount + 1
      else
        print(PREFIX .. "Could not invite " .. nextName .. " (" .. tostring(err) .. "). Will retry next pass.")
        table.insert(Engine.skipped, nextName)
      end
    end
  end

  FireStateChanged()

  CheckNewlyJoinedDurability()
  ReportDurabilityUnknown()

  -- this pass is done - see who's still not in the group and try again.
  -- ComputeStragglers only returns people worth a fresh invite attempt right
  -- now (it deliberately excludes anyone still holding one of our live,
  -- unexpired invites - see ComputeStragglers) - so an empty stragglers list
  -- does NOT necessarily mean everyone has joined, only that nobody needs a
  -- new invite yet. Check actual group membership separately to decide
  -- whether the run is really done.
  --
  -- Deliberately NOT touching Engine.nextPassAt here - a pass can finish
  -- well before the interval's actually up (e.g. the 1.5s capacity-retry
  -- chain resolving quickly), and recomputing "now + interval" from that
  -- early completion time would show a countdown longer than what's really
  -- going to happen. The ticker in StartInvites fires on its own fixed
  -- schedule regardless of when any given pass happens to finish, so it's
  -- the only thing that gets to set nextPassAt.
  local stragglers = ComputeStragglers(groupSet)
  local everyoneJoined = true
  for _, name in ipairs(Engine.fullRoster) do
    if not LookupByFullOrName(groupSet, name) then
      everyoneJoined = false
      break
    end
  end

  if everyoneJoined then
    StopInvites("Invite list complete - everyone is in the group.")
  elseif #stragglers > 0 then
    -- Held for the next scheduled round, not invited now - see
    -- RequeueForRetry and the ticker's queue swap in StartInvites.
    for _, name in ipairs(stragglers) do
      RequeueForRetry(name)
    end
    Engine.skipped = {}
    print(PREFIX .. string.format(
      "Pass complete. Retrying %d player(s) still not in the group in %ds.",
      #stragglers, MakeIdiotsAppearDB.settings.interval))
    FireStateChanged()
  else
    -- Nobody needs a fresh invite this pass - everyone still missing has one
    -- of ours live and not yet expired. Keep the run alive (don't stop the
    -- ticker) so the next scheduled pass can prune and retry once those
    -- actually resolve, instead of ending the run while invites are still
    -- genuinely outstanding.
    Engine.skipped = {}
    print(PREFIX .. string.format(
      "Pass complete. Waiting on %d still-pending invite(s), next check in %ds.",
      CountPendingInvites(), MakeIdiotsAppearDB.settings.interval))
    FireStateChanged()
  end
end

-- RunInvitePass drives the whole run (both the initial call and every ticker
-- firing). Nothing inside it should ever be able to kill the ticker, so any
-- error we didn't anticipate (bad name, weird API failure, etc.) just gets
-- logged instead of silently ending the invite cycle.
SafeRunInvitePass = function()
  if not Engine.running then return end
  local ok, err = pcall(RunInvitePass)
  if not ok then
    print(PREFIX .. "Invite cycle hit an error, will retry next interval: " .. tostring(err))
  end
end
ns.SafeRunInvitePass = SafeRunInvitePass

local function StartInvites(list)
  -- Converting a party to a raid only works for the party/raid leader -
  -- discovering that mid-run (after the party's already full) wastes
  -- several seconds of retries and ends in a confusing message, so check up
  -- front instead, before anything else starts.
  if IsInGroup() and not UnitIsGroupLeader("player") then
    print(PREFIX .. "You can only start invites when you're alone or the group/raid leader.")
    return
  end

  if #list == 0 then
    print(PREFIX .. "Nothing to invite - the list is empty.")
    return
  end

  Engine.queue = {}
  Engine.nextQueue = {}
  Engine.fullRoster = {}
  for _, n in ipairs(list) do
    table.insert(Engine.queue, n)
    table.insert(Engine.fullRoster, n)
  end
  Engine.skipped = {}
  Engine.convertingToRaid = nil
  Engine.convertRetryCount = 0
  Engine.durabilityChecked = {}
  Engine.durabilityPending = {}
  Engine.durabilityUnknownThisPass = {}
  Engine.running = true
  Engine.starting = true
  FireStateChanged()

  -- Catches assist candidates already sitting in a raid formed before Start
  -- Invites was clicked - the GROUP_ROSTER_UPDATE-driven call further below
  -- only fires on an actual roster change after this point, so it would
  -- otherwise never see someone who was already there.
  MaybeAutoPromoteAssist()

  -- Same reasoning: catches an already-existing real party of 2+ formed
  -- before Start Invites was clicked, which the joinedGroupPattern-driven
  -- trigger (CHAT_MSG_SYSTEM handler) would never see since no fresh "has
  -- joined" message fires for people who were already there. Safe to read
  -- GetNumGroupMembers() directly here specifically because no invites have
  -- been sent yet this run - there's no reserved-but-unconfirmed slot to be
  -- fooled by at this exact point.
  MaybeConvertToRaid()

  -- Backstop for durability checks: GROUP_ROSTER_UPDATE already triggers a
  -- check whenever someone joins, but this catches anyone whose request
  -- got dropped by LibDurability's own broadcast throttle.
  if Engine.durabilityTicker then
    Engine.durabilityTicker:Cancel()
  end
  Engine.durabilityTicker = C_Timer.NewTicker(5, CheckNewlyJoinedDurability)

  local settings = MakeIdiotsAppearDB.settings

  local function beginInviting()
    Engine.starting = false
    Engine.startTimer = nil
    SafeRunInvitePass()
    -- The ticker's own fixed schedule is the single source of truth for
    -- nextPassAt (see the comment at the end of RunInvitePass) - set once
    -- here, then re-set every time the ticker actually fires below, never
    -- touched by RunInvitePass itself.
    Engine.nextPassAt = GetTime() + settings.interval
    -- Each interval tick starts a fresh round: whatever bounced, expired, or
    -- was otherwise held back during the previous round (see RequeueForRetry
    -- and the end-of-pass straggler merge) becomes this round's queue, and
    -- gets exactly one attempt before anything unresolved is held again.
    Engine.ticker = C_Timer.NewTicker(settings.interval, function()
      Engine.nextPassAt = GetTime() + settings.interval
      Engine.queue = Engine.nextQueue
      Engine.nextQueue = {}
      SafeRunInvitePass()
    end)
    FireStateChanged()
  end

  if settings.sendGuildMessage and settings.guildMessage and settings.guildMessage ~= "" then
    local ok, err = SendChat(ApplyMessagePrefix(settings.guildMessage), "GUILD")
    if not ok then
      print(PREFIX .. "Could not send the guild message (" .. tostring(err) .. "). Continuing anyway.")
    end
    if settings.delayAfterMessage and settings.delayAfterMessage > 0 then
      Engine.nextPassAt = GetTime() + settings.delayAfterMessage
      Engine.startTimer = C_Timer.NewTimer(settings.delayAfterMessage, beginInviting)
    else
      beginInviting()
    end
  else
    beginInviting()
  end
end
ns.StartInvites = StartInvites

-- Called whenever the roster manager (UI_Rosters.lua) saves a player-list
-- edit, changes a roster's group size, or deletes a roster - so a run
-- already in progress picks up the change immediately instead of only ever
-- inviting the snapshot StartInvites captured when the run began. No-ops
-- unless a run is actually active (also true during the "starting" delay
-- window, since Engine.running is set alongside Engine.starting - see
-- StartInvites above). Doesn't need to know which roster was just edited -
-- it always re-diffs against whatever settings.activeRoster currently is, so
-- an edit to some other, inactive roster just produces an empty diff against
-- the unchanged active one and is a harmless no-op.
--
-- Only ever touches fullRoster/queue/nextQueue - never pendingInvites or
-- anyone already in the group. There's no way to un-send an invite or un-add
-- a group member, so a name dropped from the trimmed list (removed, no
-- longer any active roster, or pushed onto the bench by a smaller group
-- size) just stops being retried from here on; whatever's already
-- outstanding for them resolves on its own.
local function SyncActiveRosterIntoRun()
  if not Engine.running then return end
  local activeRoster = MakeIdiotsAppearDB.settings.activeRoster
  -- No active roster (e.g. it was just deleted - ns.DeleteRoster clears
  -- settings.activeRoster before calling this) is treated the same as an
  -- empty one below, not skipped: the run should still shed anyone in
  -- fullRoster/queue/nextQueue who's no longer backed by any roster, same as
  -- it would for a roster that still exists but was emptied out.
  local newList = activeRoster and GetTrimmedRosterList(activeRoster) or {}
  local newSet = {}
  for _, name in ipairs(newList) do
    newSet[name:lower()] = true
  end

  local oldSet = {}
  for _, name in ipairs(Engine.fullRoster) do
    oldSet[name:lower()] = true
  end

  for i = #Engine.fullRoster, 1, -1 do
    if not newSet[Engine.fullRoster[i]:lower()] then
      table.remove(Engine.fullRoster, i)
    end
  end
  for i = #Engine.queue, 1, -1 do
    if not newSet[Engine.queue[i]:lower()] then
      table.remove(Engine.queue, i)
    end
  end
  for i = #Engine.nextQueue, 1, -1 do
    if not newSet[Engine.nextQueue[i]:lower()] then
      table.remove(Engine.nextQueue, i)
    end
  end

  local addedAny = false
  for _, name in ipairs(newList) do
    if not oldSet[name:lower()] then
      table.insert(Engine.fullRoster, name)
      table.insert(Engine.queue, name)
      addedAny = true
    end
  end

  FireStateChanged()
  if addedAny then
    SafeRunInvitePass()
  end
end
ns.SyncActiveRosterIntoRun = SyncActiveRosterIntoRun

----------------------------------------------------------------------
-- Invite failure detection via system chat message
----------------------------------------------------------------------

-- Build Lua patterns out of the localized global strings once.
-- ERR_ALREADY_IN_GROUP_S looks like "%s is already in a group."
-- ERR_BAD_PLAYER_NAME_S looks like "No player named '%s' is currently playing."
-- (this is the message the server sends back for an offline/nonexistent target)
local alreadyGroupedPattern
if ERR_ALREADY_IN_GROUP_S then
  alreadyGroupedPattern = "^" .. ERR_ALREADY_IN_GROUP_S:gsub("%%s", "(.+)") .. "$"
end

local playerNotFoundPattern
if ERR_BAD_PLAYER_NAME_S then
  playerNotFoundPattern = "^" .. ERR_BAD_PLAYER_NAME_S:gsub("%%s", "(.+)") .. "$"
end

-- ERR_DECLINE_GROUP_S looks like "%s declines your group invitation."
local declinedPattern
if ERR_DECLINE_GROUP_S then
  declinedPattern = "^" .. ERR_DECLINE_GROUP_S:gsub("%%s", "(.+)") .. "$"
end

-- ERR_JOINED_GROUP_S looks like "%s has joined the group." - unlike
-- GROUP_ROSTER_UPDATE/GetNumGroupMembers(), which can transiently reflect a
-- reserved-but-unconfirmed invite slot before the client catches up to a
-- failed invite (see MaybeConvertToRaid), this message only ever fires for
-- a genuine, confirmed acceptance.
local joinedGroupPattern
if ERR_JOINED_GROUP_S then
  joinedGroupPattern = "^" .. ERR_JOINED_GROUP_S:gsub("%%s", "(.+)") .. "$"
end

-- WoW group invites expire after 60s (confirmed by testing in-game) - add a
-- 1s buffer, matching the same assumption RaidInviteClassic uses.
local INVITE_EXPIRATION_SECONDS = 61

-- Every place that clears a pendingInvites entry goes through here so
-- pendingInviteSentAt (used to detect expiration - see
-- PruneExpiredPendingInvites below) never drifts out of sync with it.
local function ClearPendingInvite(key)
  Engine.pendingInvites[key] = nil
  Engine.pendingInviteSentAt[key] = nil
end

-- Shared by RequeueForRetry/RequeueForImmediateRetry below - both just push
-- into a different Engine queue table, with the same "don't add a duplicate"
-- scan first.
local function InsertIfAbsent(queue, fullName)
  for _, queued in ipairs(queue) do
    if queued:lower() == fullName:lower() then
      return
    end
  end
  table.insert(queue, fullName)
end

-- Lets someone who resolves as "not joined" (declined or bounced - a real
-- response from the game, not silence) become eligible for the next
-- scheduled round - but not before then: goes into nextQueue rather than
-- the live queue, so they get exactly one fresh attempt per interval
-- instead of possibly being swept up again by an in-flight capacity retry
-- a few seconds later (a decliner, or someone still trying to leave another
-- group, shouldn't be re-invited that fast). A silent timeout is handled
-- separately, immediately, by RequeueForImmediateRetry below - there's no
-- "give them a moment" consideration for someone who never responded at
-- all, and the 61s wait before we even get here already covers the "don't
-- retry too early" concern this function exists for.
RequeueForRetry = function(fullName)
  if not Engine.running then return end
  InsertIfAbsent(Engine.nextQueue, fullName)
end

-- Used only by PruneExpiredPendingInvites, which runs at the very top of
-- RunInvitePass before the while-loop starts draining Engine.queue - so
-- pushing here (rather than into nextQueue like RequeueForRetry) means a
-- just-expired invite gets retried in this same pass, not held an entire
-- extra interval on top of the 61s it already waited.
local function RequeueForImmediateRetry(fullName)
  if not Engine.running then return end
  InsertIfAbsent(Engine.queue, fullName)
end

-- Multiple invites can be outstanding at once now, so a system message has to
-- be matched against whichever of them it actually refers to, not a single
-- "current" invitee. pendingInvites is keyed by full "name-realm" - if the
-- message included a realm we get an exact, unambiguous match; if it only
-- gave a bare name and more than one pending invite shares that name (e.g.
-- Tanku-OldBlanchy and Tanku-Azuresong both outstanding), we can't tell
-- which one it means, so we deliberately don't guess and leave both pending
-- - the next retry pass will only re-invite whichever one still isn't
-- actually in the group. Removes and returns the matching full name, if any.
local function TakePendingInvite(shortName)
  if not shortName then return nil end
  local key = shortName:lower()

  if Engine.pendingInvites[key] then
    local fullName = Engine.pendingInvites[key]
    ClearPendingInvite(key)
    return fullName
  end

  if key:find("%-") then
    return nil
  end

  local matchKey, matchFullName
  for pendingKey, fullName in pairs(Engine.pendingInvites) do
    if NamePart(fullName) == key then
      if matchKey then
        -- more than one candidate - ambiguous, don't guess
        return nil
      end
      matchKey, matchFullName = pendingKey, fullName
    end
  end

  if matchKey then
    ClearPendingInvite(matchKey)
    return matchFullName
  end
  return nil
end

-- Nobody clears a pendingInvites entry when the invite is simply accepted -
-- there's no "so-and-so has joined" pattern among the CHAT_MSG_SYSTEM
-- handlers below, only the already-grouped/not-found/declined bounce cases -
-- so an accepted invite would otherwise sit "pending" forever, double-
-- counting that person against the party cap (see RunInvitePass) and
-- against the "Pending invites: N" label in the UI. Keys here are always
-- full "name-realm" (see the only write site, in RunInvitePass), same as
-- GetGroupNameSet()'s keys, so a plain key match is enough.
local function PrunePendingInvites(groupSet)
  for key in pairs(Engine.pendingInvites) do
    if groupSet[key] then
      ClearPendingInvite(key)
    end
  end
end

-- Someone else (an assist manually inviting a roster member, say) can get a
-- queued name into the group without us ever sending or seeing an invite
-- for them - we'd have no way to know, since a system message about that
-- invite only ever shows to whoever sent it. GROUP_ROSTER_UPDATE is the one
-- reliable signal we do get, so drop the name from both queues the instant
-- they actually show up in the roster, regardless of who invited them.
local function PruneJoinedFromQueues(groupSet)
  for i = #Engine.queue, 1, -1 do
    if LookupByFullOrName(groupSet, Engine.queue[i]) then
      table.remove(Engine.queue, i)
    end
  end
  for i = #Engine.nextQueue, 1, -1 do
    if LookupByFullOrName(groupSet, Engine.nextQueue[i]) then
      table.remove(Engine.nextQueue, i)
    end
  end
end

-- Finds and removes the entry in this queue matching a full "Name-Realm" that
-- just came online, used by MaybeInviteNewlyOnline below. Handles both an
-- already-resolved exact match and a not-yet-realm-resolved bare-name entry -
-- but mirrors TakePendingInvite's "don't guess if ambiguous" caution: if more
-- than one entry in this queue shares that bare name, we can't tell which one
-- is actually the player who just logged on, so leave both alone rather than
-- risk moving the wrong one to the front.
local function TakeMatchingQueueEntry(queue, fullOnlineName)
  local fullKey = fullOnlineName:lower()
  local shortKey = NamePart(fullOnlineName)
  local exactIndex
  local shortIndex
  local shortMatches = 0
  for i, queued in ipairs(queue) do
    if queued:lower() == fullKey then
      exactIndex = i
      break
    elseif NamePart(queued) == shortKey then
      shortIndex = i
      shortMatches = shortMatches + 1
    end
  end
  local index = exactIndex or (shortMatches == 1 and shortIndex or nil)
  if index then
    return table.remove(queue, index)
  end
  return nil
end

-- Backstop for invites that never resolve at all (no accept, no decline,
-- nothing) - once the server's own ~60s invite window has passed, the
-- reserved party slot is gone regardless of what we do, so stop counting it
-- against the cap and make the person eligible for another invite attempt,
-- right away rather than waiting an extra interval (see
-- RequeueForImmediateRetry above).
PruneExpiredPendingInvites = function()
  local now = GetTime()
  for key, sentAt in pairs(Engine.pendingInviteSentAt) do
    if now - sentAt > INVITE_EXPIRATION_SECONDS then
      local fullName = Engine.pendingInvites[key]
      ClearPendingInvite(key)
      if fullName then
        RequeueForImmediateRetry(fullName)
      end
    end
  end
end

-- Triggered by a confirmed join (joinedGroupPattern in the CHAT_MSG_SYSTEM
-- handler) or, once, immediately from StartInvites for an already-existing
-- party - deliberately NOT from GROUP_ROSTER_UPDATE's generic member count,
-- which can transiently reflect a reserved-but-unconfirmed invite slot
-- before the client catches up to a failed invite. Only fires while a run
-- is active and only for the leader, same restriction ConvertPartyToRaid
-- itself is subject to - see StartInvites' upfront leadership check.
MaybeConvertToRaid = function()
  if not Engine.running then return end
  if IsInRaid() then return end
  if not UnitIsGroupLeader("player") then return end
  if GetNumGroupMembers() < 2 then return end
  ConvertPartyToRaid()
end

----------------------------------------------------------------------
-- Jump the queue for guild members who just came online
----------------------------------------------------------------------

-- key -> full "Name-Realm", as of the last time this ran. Deliberately a
-- plain persistent local, not reset by StartInvites - it needs to already
-- reflect who was online *before* a run starts, so a player who was already
-- online when Start Invites was clicked doesn't look like a fresh "just
-- came online" transition the first time this runs during that run.
local lastOnlineGuildMembers = {}

-- Guild online notifications ("has come online") are a client-side toast
-- gated behind a per-user setting most players don't have on, so an addon
-- can't reliably hook a system message for this the way it does for invite
-- bounces - RaidInviteClassic doesn't either, it diffs guild roster online
-- state the same way this does. Called every GUILD_ROSTER_UPDATE; only
-- actually moves anyone if a run is active, but always updates the snapshot
-- so the diff stays accurate for whenever the next run does start.
local function MaybeInviteNewlyOnline()
  local nowOnline = GetOnlineGuildMembersMap()
  if Engine.running then
    local movedAny = false
    for key, fullName in pairs(nowOnline) do
      if not lastOnlineGuildMembers[key] then
        local moved = TakeMatchingQueueEntry(Engine.queue, fullName)
            or TakeMatchingQueueEntry(Engine.nextQueue, fullName)
        if moved then
          table.insert(Engine.queue, 1, moved)
          movedAny = true
        end
      end
    end
    if movedAny then
      SafeRunInvitePass()
    end
  end
  lastOnlineGuildMembers = nowOnline
end

----------------------------------------------------------------------
-- Automatic master loot (Raid tab setting)
----------------------------------------------------------------------

-- SetLootMethod("master", raidIndex) wants the master looter's raid roster
-- index, not a unit token - mirrors GroupComps.lua's FindRaidLeader, which
-- resolves a raid index the same way rather than relying on UnitInRaid's
-- historically inconsistent (0- vs 1-based) numbering.
local function GetPlayerRaidIndex()
  for i = 1, GetNumGroupMembers() do
    if UnitIsUnit("raid" .. i, "player") then
      return i
    end
  end
  return nil
end

-- Below this size a master looter is rarely needed and round robin/group
-- loot is the more common choice, so this only ever kicks in for larger
-- raids - and only for whoever is actually leading it, since SetLootMethod
-- is restricted to the party/raid leader anyway.
local MASTER_LOOT_MIN_GROUP_SIZE = 10

local function MaybeSetMasterLoot()
  local settings = MakeIdiotsAppearDB.settings
  if not settings.autoMasterLoot then return end
  if not IsInRaid() then return end
  if GetNumGroupMembers() <= MASTER_LOOT_MIN_GROUP_SIZE then return end
  if not UnitIsGroupLeader("player") then return end
  if DoGetLootMethod() == "master" then return end

  local playerIndex = GetPlayerRaidIndex()
  if not playerIndex then return end

  DoSetLootMethod("master", playerIndex)
end

----------------------------------------------------------------------
-- Automatic loot threshold (Raid tab setting)
----------------------------------------------------------------------

-- Must run after loot is set to Master Loot but before MaybeSetMasterLooter
-- (below) hands master looter off to someone else - once that happens the
-- raid leader can no longer change the threshold themselves, so this only
-- ever tries while master looter is still un-promoted this raid.
local function MaybeSetLootThreshold()
  local settings = MakeIdiotsAppearDB.settings
  if not settings.autoLootThreshold then return end
  if Engine.masterLooterPromoted then return end
  if not IsInRaid() then return end
  if not UnitIsGroupLeader("player") then return end
  if DoGetLootMethod() ~= "master" then return end
  if GetLootThreshold() == settings.lootThresholdQuality then return end

  -- Poor/Common (0/1) aren't thresholds Blizzard's own raid UI offers and
  -- SetLootThreshold may reject them outright - pcall so a rejected value
  -- here can't interrupt the rest of this pass.
  pcall(SetLootThreshold, settings.lootThresholdQuality)
end

----------------------------------------------------------------------
-- Automatic master looter promotion (Raid tab setting)
----------------------------------------------------------------------

-- One-shot per raid: once someone's been promoted this session we leave
-- loot alone even if the user hands master looter to someone else by hand
-- afterward - see MaybeSetMasterLooter below. Reset only when the player
-- drops out of any group entirely (see the GROUP_ROSTER_UPDATE handler),
-- so the next raid starts with a clean slate.
Engine.masterLooterPromoted = false

local function FindRaidIndexForFullName(fullName)
  local target = fullName:lower()
  for i = 1, GetNumGroupMembers() do
    local full = GetFullUnitName("raid" .. i)
    if full and full:lower() == target then
      return i
    end
  end
  return nil
end

-- Candidates are tried in order; the first one currently in the group gets
-- promoted and we stop there for the rest of this raid (see
-- Engine.masterLooterPromoted above) - later candidates, and any manual
-- change the user makes afterward, are deliberately left alone.
local function MaybeSetMasterLooter()
  local settings = MakeIdiotsAppearDB.settings
  if not settings.autoPromoteMasterLooter then return end
  if Engine.masterLooterPromoted then return end
  if not IsInRaid() then return end
  if not UnitIsGroupLeader("player") then return end
  if DoGetLootMethod() ~= "master" then return end

  local groupSet = GetGroupNameSet()
  for candidateName in (settings.masterLooterNames or ""):gmatch("%S+") do
    local matchedFullName = LookupByFullOrName(groupSet, candidateName)
    if matchedFullName then
      local raidIndex = FindRaidIndexForFullName(matchedFullName)
      if raidIndex then
        DoSetLootMethod("master", raidIndex)
        Engine.masterLooterPromoted = true
      end
      return
    end
  end
end

----------------------------------------------------------------------
-- Automatic promote to assist (Raid tab setting)
----------------------------------------------------------------------

-- Gated on Engine.running/starting (an invite pass actually under way) so
-- this never fires for a raid formed by hand that one of these players
-- happens to join outside of that - unlike MaybeSetMasterLooter above,
-- there's no one-shot flag here: every candidate still not an assistant
-- gets promoted every time this runs, since simply being promoted already
-- (checked via GetRaidRosterInfo's rank) makes each one idempotent.
MaybeAutoPromoteAssist = function()
  local settings = MakeIdiotsAppearDB.settings
  if not settings.autoPromoteAssist then return end
  if not (Engine.running or Engine.starting) then return end
  if not IsInRaid() then return end
  if not UnitIsGroupLeader("player") then return end

  local groupSet = GetGroupNameSet()
  for candidateName in (settings.assistNames or ""):gmatch("%S+") do
    local matchedFullName = LookupByFullOrName(groupSet, candidateName)
    if matchedFullName then
      local raidIndex = FindRaidIndexForFullName(matchedFullName)
      if raidIndex then
        local _, rank = GetRaidRosterInfo(raidIndex)
        if rank == 0 then
          PromoteToAssistant("raid" .. raidIndex)
        end
      end
    end
  end
end

----------------------------------------------------------------------
-- Disband raid/group
----------------------------------------------------------------------
-- There's no single Blizzard API for this: uninvite everyone else in the
-- group, then leave it ourselves - a group of 1 (or 0) dissolves on its own.

local function DisbandGroup()
  if InCombatLockdown() then return end -- avoid Blizzard's protected-action error mid-combat

  local myIndex = UnitInRaid("player")
  if myIndex then
    local _, myRank = GetRaidRosterInfo(myIndex)
    if myRank == 2 then -- real raid leader, not just an assist
      for i = 1, GetNumGroupMembers() do
        if i ~= myIndex then
          local name = GetRaidRosterInfo(i)
          if name then
            UninviteUnit(name)
          end
        end
      end
    end
  elseif UnitIsGroupLeader("player") then
    for i = MAX_PARTY_MEMBERS, 1, -1 do
      local name = UnitName("party" .. i)
      if name then
        UninviteUnit(name)
      end
    end
  end

  DoLeaveParty()
end
ns.DisbandGroup = DisbandGroup

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PARTY_LEADER_CHANGED")
eventFrame:RegisterEvent("PLAYER_LOGOUT")

eventFrame:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local loaded = ...
    if loaded == ADDON_NAME then
      EnsureDB()
      if IsInGuild() then RequestGuildRoster() end
      FireStateChanged()
    end
    return
  end

  if event == "PARTY_LEADER_CHANGED" then
    if Engine.running or Engine.starting then
      if IsInGroup() or IsInRaid() then
        if not UnitIsGroupLeader("player") then
          -- Leadership changed hands (given away, or someone else took it) -
          -- everything from raid conversion to loot method needs the
          -- leader, so there's nothing left this run can do.
          StopInvites("Stopped - you're no longer the group/raid leader.")
        end
      else
        -- Group dissolved out from under the run entirely.
        StopInvites("Stopped - you're no longer in a group.")
      end
    end
    return
  end

  if event == "PLAYER_LOGOUT" then
    -- Logging out/exiting/reloading UI - nothing can continue past this
    -- point, so stop cleanly (flush any batched durability reports) rather
    -- than leaving the run in a running state that never actually resumes.
    if Engine.running or Engine.starting then
      StopInvites("Stopped - logging out.")
    end
    return
  end

  if event == "GROUP_ROSTER_UPDATE" then
    if not IsInRaid() and not IsInGroup() then
      Engine.masterLooterPromoted = false
    end
    ScanGroupRoster()
    local groupSet = GetGroupNameSet()
    PrunePendingInvites(groupSet)
    PruneJoinedFromQueues(groupSet)
    CheckNewlyJoinedDurability()
    ns.OnGroupRosterUpdateForApplyEngine()
    -- Raid conversion is deliberately NOT triggered here - GetNumGroupMembers()
    -- can transiently reflect a reserved-but-unconfirmed invite slot before
    -- the client catches up to a failed invite, which was causing conversion
    -- to fire on phantom membership. See the joinedGroupPattern branch in the
    -- CHAT_MSG_SYSTEM handler below, which only trusts a confirmed join.
    MaybeSetMasterLoot()
    MaybeSetLootThreshold()
    MaybeSetMasterLooter()
    MaybeAutoPromoteAssist()
    FireStateChanged()
    return
  end

  if event == "GUILD_ROSTER_UPDATE" then
    MaybeInviteNewlyOnline()
    FireStateChanged()
    return
  end

  if event == "CHAT_MSG_SYSTEM" then
    local msg = ...

    if alreadyGroupedPattern then
      local matched = msg:match(alreadyGroupedPattern)
      local fullName = matched and TakePendingInvite(matched)
      if fullName then
        local whisperMsg = ApplyMessagePrefix(MakeIdiotsAppearDB.settings.whisperMessage)
        local ok, err = SendChat(whisperMsg, "WHISPER", fullName)
        if not ok then
          print(PREFIX .. "Could not whisper " .. fullName .. " (" .. tostring(err) .. ").")
        end
        table.insert(Engine.skipped, fullName)
        RequeueForRetry(fullName)
        FireStateChanged()
        return
      end
    end

    if playerNotFoundPattern then
      local matched = msg:match(playerNotFoundPattern)
      local fullName = matched and TakePendingInvite(matched)
      if fullName then
        table.insert(Engine.skipped, fullName)
        RequeueForRetry(fullName)
        FireStateChanged()
        return
      end
    end

    if declinedPattern then
      local matched = msg:match(declinedPattern)
      local fullName = matched and TakePendingInvite(matched)
      if fullName then
        table.insert(Engine.skipped, fullName)
        RequeueForRetry(fullName)
        FireStateChanged()
        return
      end
    end

    if joinedGroupPattern and msg:match(joinedGroupPattern) then
      -- A confirmed join, not just a roster snapshot that might still be
      -- reflecting a reserved-but-unconfirmed invite slot - safe to trust
      -- for raid conversion. No need to pull the name out here; unlike the
      -- bounce branches above we don't need to know who, just that someone
      -- genuinely joined.
      MaybeConvertToRaid()
    end
  end
end)
