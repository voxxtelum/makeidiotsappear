-- GroupComps.lua
-- Per-roster raid group compositions: data model + apply-to-raid engine.
--
-- A roster can have several named "compositions", each arranging up to 40
-- of its players into 8 groups of 5. The "unassigned" pool (players on the
-- roster not currently placed in any group) is never stored - it's always
-- computed live from the roster list vs. a composition's groups, see
-- ComputeUnassigned below.
--
-- One composition, "Default", is special: UI_Rosters.lua calls
-- ResetDefaultGroupComp on every roster save, which overwrites it with a
-- fresh chunking of the roster's current player-list order. So Default
-- always mirrors "whatever order the roster is in right now" and any manual
-- rearranging of it will be lost the next time the roster is edited/saved -
-- compositions you want to keep should be duplicated into their own named
-- copy first (see the "Duplicate" button in UI_Groups.lua).
--
-- Each group (comp.groups[1..8]) is a fixed 5-slot table, addressed by
-- explicit position 1-5 rather than compacted/appended - an empty slot is
-- simply a nil at that position, not a hole that gets squeezed out. This
-- means position within a group is meaningful and preserved (matters both
-- for the UI - dragging someone out of slot 3 leaves slot 3 blank, doesn't
-- shuffle slots 4-5 up - and for ApplyGroupComposition, which uses the same
-- slot index as the target position to place someone at in the live raid).
-- Because of the nil holes, every place that reads a group's contents must
-- index it by explicit position (for p = 1, SLOTS_PER_GROUP do ... end),
-- never ipairs/# (both are undefined/unreliable once holes are involved).

local ADDON_NAME, ns = ...
local PREFIX = ns.PREFIX

local GROUPS_PER_COMP = 8
local SLOTS_PER_GROUP = 5
ns.GROUPS_PER_COMP = GROUPS_PER_COMP
ns.SLOTS_PER_GROUP = SLOTS_PER_GROUP

----------------------------------------------------------------------
-- Data model
----------------------------------------------------------------------

local function NewEmptyGroups()
  local groups = {}
  for i = 1, GROUPS_PER_COMP do
    groups[i] = {}
  end
  return groups
end

-- Chunks a roster list (in order) into groups of 5, up to 8 groups (40
-- players). Anything past the 40th player is simply left out - it'll show
-- up as unassigned (see ComputeUnassigned) rather than being lost.
local function ChunkListIntoGroups(list)
  local groups = NewEmptyGroups()
  for index, name in ipairs(list) do
    if index > GROUPS_PER_COMP * SLOTS_PER_GROUP then break end
    local groupIndex = math.floor((index - 1) / SLOTS_PER_GROUP) + 1
    local posInGroup = ((index - 1) % SLOTS_PER_GROUP) + 1
    groups[groupIndex][posInGroup] = name
  end
  return groups
end
ns.ChunkListIntoGroups = ChunkListIntoGroups

local function FindComp(rosterGroupData, compName)
  for _, comp in ipairs(rosterGroupData.comps) do
    if comp.name == compName then return comp end
  end
  return nil
end

local function GenerateUniqueCompName(rosterGroupData, base)
  base = base or "New Composition"
  local function taken(name)
    return FindComp(rosterGroupData, name) ~= nil
  end
  if not taken(base) then return base end
  local i = 2
  while taken(base .. " " .. i) do
    i = i + 1
  end
  return base .. " " .. i
end

-- Get-or-create the roster's group data, seeding a "Default" composition
-- (chunked from rosterList's current order) the first time this roster is
-- ever seen. Does NOT otherwise touch Default on later calls - see
-- ResetDefaultGroupComp below for keeping it in sync as the roster changes.
function ns.EnsureRosterGroupData(rosterName, rosterList)
  ns.EnsureDB()
  local data = MakeIdiotsAppearDB.groupComps[rosterName]
  if not data then
    data = { activeComp = "Default", comps = {} }
    MakeIdiotsAppearDB.groupComps[rosterName] = data
  end
  if #data.comps == 0 then
    table.insert(data.comps, { name = "Default", groups = ChunkListIntoGroups(rosterList or {}) })
    data.activeComp = "Default"
  end
  return data
end

-- Overwrites (or recreates, at the front of the list, if it was deleted or
-- renamed away) the roster's "Default" composition with a fresh chunking of
-- rosterList's current order. Called every time a roster is saved in
-- UI_Rosters.lua, so Default always mirrors the current player list -
-- unlike every other composition, which is left exactly as arranged and
-- never auto-touched by roster edits.
function ns.ResetDefaultGroupComp(rosterName, rosterList)
  local data = ns.EnsureRosterGroupData(rosterName, rosterList)
  local groups = ChunkListIntoGroups(rosterList or {})
  local comp = FindComp(data, "Default")
  if comp then
    comp.groups = groups
  else
    table.insert(data.comps, 1, { name = "Default", groups = groups })
  end
end

-- Resolves the roster's active composition, self-healing to the first
-- composition on the list if the activeComp pointer is stale (e.g. that
-- comp was renamed/deleted through some other path).
function ns.GetActiveGroupComp(rosterName)
  local rosterList = MakeIdiotsAppearDB.rosters[rosterName] or {}
  local data = ns.EnsureRosterGroupData(rosterName, rosterList)
  local comp = FindComp(data, data.activeComp)
  if not comp then
    comp = data.comps[1]
    data.activeComp = comp and comp.name or nil
  end
  return comp, data
end

function ns.SetActiveGroupComp(rosterName, compName)
  local data = ns.EnsureRosterGroupData(rosterName, MakeIdiotsAppearDB.rosters[rosterName] or {})
  if FindComp(data, compName) then
    data.activeComp = compName
  end
end

-- copyFromCompName: if given (and found), the new comp starts as a deep
-- copy of that comp's groups. Otherwise it starts pre-arranged in the
-- roster's current order (same chunking Default gets seeded with), not
-- blank - matches "New" being a fresh starting point you then tweak, rather
-- than an empty grid you have to fill from scratch. Returns the final
-- (possibly de-duplicated) name.
function ns.AddGroupComp(rosterName, name, copyFromCompName)
  local data = ns.EnsureRosterGroupData(rosterName, MakeIdiotsAppearDB.rosters[rosterName] or {})
  name = ns.Trim(name or "")
  if name == "" or FindComp(data, name) then
    name = GenerateUniqueCompName(data, name ~= "" and name or nil)
  end

  local groups
  local source = copyFromCompName and FindComp(data, copyFromCompName)
  if source then
    groups = NewEmptyGroups()
    for i = 1, GROUPS_PER_COMP do
      for p = 1, SLOTS_PER_GROUP do
        groups[i][p] = source.groups[i][p]
      end
    end
  else
    groups = ChunkListIntoGroups(MakeIdiotsAppearDB.rosters[rosterName] or {})
  end

  table.insert(data.comps, { name = name, groups = groups })
  data.activeComp = name
  return name
end

function ns.RenameGroupComp(rosterName, oldName, newName)
  local data = ns.EnsureRosterGroupData(rosterName, MakeIdiotsAppearDB.rosters[rosterName] or {})
  newName = ns.Trim(newName or "")
  if newName == "" or (newName ~= oldName and FindComp(data, newName)) then
    return false
  end
  local comp = FindComp(data, oldName)
  if not comp then return false end
  comp.name = newName
  if data.activeComp == oldName then
    data.activeComp = newName
  end
  return true
end

-- Refuses to delete the last remaining composition for a roster - there
-- must always be at least one to view/edit/apply.
function ns.DeleteGroupComp(rosterName, compName)
  local data = ns.EnsureRosterGroupData(rosterName, MakeIdiotsAppearDB.rosters[rosterName] or {})
  if #data.comps <= 1 then return false end
  for i, comp in ipairs(data.comps) do
    if comp.name == compName then
      table.remove(data.comps, i)
      if data.activeComp == compName then
        data.activeComp = data.comps[1].name
      end
      return true
    end
  end
  return false
end

function ns.MoveRosterGroupData(oldName, newName)
  local data = MakeIdiotsAppearDB.groupComps[oldName]
  if data then
    MakeIdiotsAppearDB.groupComps[oldName] = nil
    MakeIdiotsAppearDB.groupComps[newName] = data
  end
end

function ns.DeleteRosterGroupData(rosterName)
  MakeIdiotsAppearDB.groupComps[rosterName] = nil
end

-- Names from rosterList not currently placed in any of comp's 8 groups, in
-- roster order. Names placed in comp.groups that are no longer part of the
-- roster just never show up here - nothing needs to actively clean those
-- out of comp.groups itself.
function ns.ComputeUnassigned(rosterList, comp)
  local placed = {}
  for i = 1, GROUPS_PER_COMP do
    for p = 1, SLOTS_PER_GROUP do
      local name = comp.groups[i][p]
      if name then
        placed[name] = true
      end
    end
  end
  local unassigned = {}
  for _, name in ipairs(rosterList) do
    if not placed[name] then
      table.insert(unassigned, name)
    end
  end
  return unassigned
end

----------------------------------------------------------------------
-- Apply-to-raid engine
----------------------------------------------------------------------
-- Ported from MRT's RaidGroups.lua (ApplyGroups/ProcessRoster): moves and
-- reorders live raid members to match a composition, a few members at a
-- time, converging over several GROUP_ROSTER_UPDATE events rather than all
-- at once (each Set/SwapRaidSubgroup call only takes effect after a server
-- round-trip). Runs in three phases per composition: (1) move anyone into
-- their target group where there's room, (2) swap group membership for
-- whoever's still stuck, (3) once everyone's in the right group, reorder
-- position within each group. Phase 3 can't swap two members of the same
-- group directly (SwapRaidSubgroup only exchanges subgroup *numbers*, which
-- would be a no-op for two people already sharing one) so it routes one of
-- them out through a third "bridge" member in a different group and back -
-- a 3-step dance, same trick MRT uses.

local ApplyEngine = {
  pending = false,       -- true while a convergence run is in progress
  needGroup = nil,       -- [lowercased full name] = target group index
  needPosInGroup = nil,  -- [lowercased full name] = target position within that group
  lockedUnit = nil,      -- [lowercased full name] = true once its position swap has locked in
  groupsReady = false,   -- true once phase 1/2 (group placement) has converged
  rlKey = nil,           -- lowercased full name of the current raid leader, if any
  groupWithRL = nil,     -- the raid leader's current group, only set when the comp doesn't explicitly place them
}
ns.GroupApplyEngine = ApplyEngine

local stepTimer = nil

local function AnyoneInCombat()
  for i = 1, GetNumGroupMembers() do
    local unit = "raid" .. i
    if UnitExists(unit) and UnitAffectingCombat(unit) then
      return ns.GetFullUnitName(unit) or UnitName(unit)
    end
  end
  return nil
end

local function FindRaidLeader()
  for i = 1, GetNumGroupMembers() do
    local unit = "raid" .. i
    if UnitExists(unit) and UnitIsGroupLeader(unit) then
      local full = ns.GetFullUnitName(unit)
      local _, _, subgroup = GetRaidRosterInfo(i)
      return full, subgroup
    end
  end
  return nil
end

local function StopApplyEngine(reason)
  if stepTimer then
    stepTimer:Cancel()
    stepTimer = nil
  end
  ApplyEngine.pending = false
  ApplyEngine.needGroup = nil
  ApplyEngine.needPosInGroup = nil
  ApplyEngine.lockedUnit = nil
  ApplyEngine.groupsReady = false
  ApplyEngine.rlKey = nil
  ApplyEngine.groupWithRL = nil
  if reason then
    print(PREFIX .. reason)
  end
  ns.FireStateChanged()
end
ns.StopApplyEngine = StopApplyEngine

function ns.StepApplyEngine()
  if not ApplyEngine.pending then return end

  local inCombat = AnyoneInCombat()
  if inCombat then
    StopApplyEngine("Apply groups stopped - " .. inCombat .. " entered combat.")
    return
  end

  local needGroup = ApplyEngine.needGroup
  local needPosInGroup = ApplyEngine.needPosInGroup
  local lockedUnit = ApplyEngine.lockedUnit
  if not needGroup then return end

  -- Snapshot of who's actually in the raid right now, and where.
  local currentGroup, currentPos, nameToID, groupSize = {}, {}, {}, {}
  for i = 1, GROUPS_PER_COMP do groupSize[i] = 0 end

  for i = 1, GetNumGroupMembers() do
    local unit = "raid" .. i
    local full = ns.GetFullUnitName(unit)
    if full then
      local key = full:lower()
      local _, _, subgroup = GetRaidRosterInfo(i)
      if subgroup then
        currentGroup[key] = subgroup
        nameToID[key] = i
        groupSize[subgroup] = groupSize[subgroup] + 1
        currentPos[key] = groupSize[subgroup]
      end
    end
  end

  if not ApplyEngine.groupsReady then
    -- Phase 1: move anyone whose current group is wrong into their target
    -- group, as long as there's room. Comp entries for players not
    -- currently in the raid are silently skipped (currentGroup[key] is nil
    -- for them) - nothing to move.
    local movedAny = false
    for key, targetGroup in pairs(needGroup) do
      local currGroup = currentGroup[key]
      if currGroup and currGroup ~= targetGroup and groupSize[targetGroup] < SLOTS_PER_GROUP then
        SetRaidSubgroup(nameToID[key], targetGroup)
        groupSize[currGroup] = groupSize[currGroup] - 1
        groupSize[targetGroup] = groupSize[targetGroup] + 1
        movedAny = true
      end
    end
    if movedAny then return end

    -- Phase 2: for anyone still stuck (their target group is full of people
    -- who belong there), swap with someone in that group who doesn't.
    local swappedOut = {}
    local swappedAny = false
    for key, targetGroup in pairs(needGroup) do
      if not swappedOut[key] and currentGroup[key] and currentGroup[key] ~= targetGroup then
        for key2, group2 in pairs(currentGroup) do
          if not swappedOut[key2] and group2 == targetGroup and needGroup[key2] ~= group2 then
            SwapRaidSubgroup(nameToID[key], nameToID[key2])
            swappedOut[key] = true
            swappedOut[key2] = true
            swappedAny = true
            break
          end
        end
      end
    end
    if swappedAny then return end

    ApplyEngine.groupsReady = true
  end

  -- Phase 3: everyone's in the correct group now - fix ordering within each
  -- group. The raid leader is only protected from being moved/swapped here
  -- when the comp DIDN'T explicitly place them (groupWithRL set) - in that
  -- case everyone else landing in the leader's untouched group has their
  -- target position bumped by 1 to leave the leader's slot alone. If the
  -- comp DID explicitly assign the leader a slot, they're repositioned like
  -- anyone else - otherwise a full group that happens to include the leader
  -- could never finish reordering (nothing else could ever swap into the
  -- leader's slot to complete the permutation).
  local skipRL = ApplyEngine.groupWithRL ~= nil
  local function IsLockedRL(key)
    return skipRL and key == ApplyEngine.rlKey
  end

  local swappedOut = {}
  local anyUnresolved = false
  for key, wantedPos in pairs(needPosInGroup) do
    local pos = wantedPos
    if currentGroup[key] == ApplyEngine.groupWithRL then
      pos = pos + 1
    end
    if not lockedUnit[key] and currentPos[key] and currentPos[key] ~= pos
        and not IsLockedRL(key) and not swappedOut[key] then
      local bridgeKey
      for key2, group2 in pairs(currentGroup) do
        if group2 ~= currentGroup[key] and not IsLockedRL(key2) and not swappedOut[key2] then
          bridgeKey = key2
          break
        end
      end

      local swapKey
      for key2, pos2 in pairs(currentPos) do
        if currentGroup[key2] == currentGroup[key] and pos2 == pos
            and not IsLockedRL(key2) and not swappedOut[key2] then
          swapKey = key2
          break
        end
      end

      if bridgeKey and swapKey then
        lockedUnit[key] = true
        SwapRaidSubgroup(nameToID[key], nameToID[bridgeKey])
        SwapRaidSubgroup(nameToID[bridgeKey], nameToID[swapKey])
        SwapRaidSubgroup(nameToID[key], nameToID[bridgeKey])

        swappedOut[key] = true
        swappedOut[swapKey] = true
        swappedOut[bridgeKey] = true
        return
      else
        -- No bridge candidate exists (e.g. this group's members are the
        -- only people currently in the raid) - reordering within it isn't
        -- possible with the raid-subgroup API, note it and move on instead
        -- of looping on it forever.
        anyUnresolved = true
      end
    end
  end

  if anyUnresolved then
    StopApplyEngine("Groups applied - some players could not be reordered (no one outside their group to temporarily swap through).")
  else
    StopApplyEngine("Groups applied.")
  end
end

-- Called on every GROUP_ROSTER_UPDATE (see MakeIdiotsAppear.lua's
-- eventFrame) - a cheap no-op unless an apply is actually pending. Debounced
-- a beat behind the event: firing Set/SwapRaidSubgroup too rapidly back to
-- back has been reported to cause disconnects, so each new event just
-- restarts a short timer rather than stepping immediately.
function ns.OnGroupRosterUpdateForApplyEngine()
  if not ApplyEngine.pending then return end
  if stepTimer then
    stepTimer:Cancel()
  end
  stepTimer = C_Timer.NewTimer(0.5, function()
    stepTimer = nil
    ns.StepApplyEngine()
  end)
end

function ns.ApplyGroupComposition(comp)
  if not IsInRaid() then
    print(PREFIX .. "You must be in a raid group to apply groups.")
    return
  end

  local inCombat = AnyoneInCombat()
  if inCombat then
    print(PREFIX .. "Can't apply groups - " .. inCombat .. " is in combat.")
    return
  end

  local rlFullName, rlGroup = FindRaidLeader()
  local rlKey = rlFullName and rlFullName:lower()

  local needGroup, needPosInGroup = {}, {}
  local rlPlaced = false

  -- needPosInGroup uses the composition's own slot index (1-5) directly,
  -- not a compacted counter - a blank slot 3 with someone in slot 4 means
  -- position 4 is genuinely what gets requested for them, preserving
  -- exactly how the groups were arranged in the editor.
  for groupIndex = 1, GROUPS_PER_COMP do
    for pos = 1, SLOTS_PER_GROUP do
      local name = comp.groups[groupIndex][pos]
      if name then
        local key = name:lower()
        if rlKey and key == rlKey then
          rlPlaced = true
        end
        needGroup[key] = groupIndex
        needPosInGroup[key] = pos
      end
    end
  end

  if not next(needGroup) then
    print(PREFIX .. "This composition has no players placed in any group.")
    return
  end

  ApplyEngine.needGroup = needGroup
  ApplyEngine.needPosInGroup = needPosInGroup
  ApplyEngine.lockedUnit = {}
  ApplyEngine.groupsReady = false
  ApplyEngine.rlKey = rlKey
  ApplyEngine.groupWithRL = (rlKey and not rlPlaced) and rlGroup or nil
  ApplyEngine.pending = true
  ns.FireStateChanged()

  ns.StepApplyEngine()
end
