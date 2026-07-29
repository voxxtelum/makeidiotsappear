-- GroupComps.lua
-- Per-roster raid group compositions: data model + apply-to-raid engine.
--
-- A roster can have several named "compositions", each arranging up to 40
-- players into 8 groups of 5. The unassigned pool is never stored - it's
-- computed live as roster minus placed players (see ComputeUnassigned).
--
-- "Default" is auto-seeded once (see EnsureRosterGroupData) the first time a
-- roster is saved with players that all have resolved realms; after that
-- it's an ordinary composition and edits stick.
--
-- Each group is a fixed 5-slot table addressed by explicit position, not
-- compacted - an empty slot is a nil at that position, so every reader must
-- index by position (never ipairs/#), and ApplyGroupComposition relies on
-- slot index matching the target raid position.

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

-- A resolved name is always stored as "Name-Realm" (see NormalizePlayerName
-- in MakeIdiotsAppear.lua); an unresolved one is just "Name" with no dash.
local function AllNamesResolved(rosterList)
  for _, name in ipairs(rosterList) do
    if not name:find("%-") then return false end
  end
  return true
end

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

-- Get-or-create the roster's group data, seeding "Default" (chunked from
-- rosterList) the first time it's saved with players and every name is
-- resolved. Seeding is skipped for an empty or unresolved list so an empty/
-- wrong Default doesn't get permanently locked in before a real one can be
-- seeded later.
function ns.EnsureRosterGroupData(rosterName, rosterList)
  ns.EnsureDB()
  local data = MakeIdiotsAppearDB.groupComps[rosterName]
  if not data then
    data = { activeComp = "Default", comps = {} }
    MakeIdiotsAppearDB.groupComps[rosterName] = data
  end
  if #data.comps == 0 and rosterList and #rosterList > 0 and AllNamesResolved(rosterList) then
    table.insert(data.comps, { name = "Default", groups = ChunkListIntoGroups(rosterList) })
    data.activeComp = "Default"
  end
  return data
end

-- Resolves the active composition, self-healing to the first comp if
-- activeComp is stale. Always returns non-nil: if Default hasn't been
-- seeded yet, hands back a transient empty stand-in without inserting it,
-- so a real Default can still seed later.
function ns.GetActiveGroupComp(rosterName)
  local rosterList = MakeIdiotsAppearDB.rosters[rosterName] or {}
  local data = ns.EnsureRosterGroupData(rosterName, rosterList)
  local comp = FindComp(data, data.activeComp)
  if not comp then
    comp = data.comps[1]
    data.activeComp = comp and comp.name or nil
  end
  if not comp then
    comp = { name = "Default", groups = ChunkListIntoGroups({}) }
  end
  return comp, data
end

function ns.SetActiveGroupComp(rosterName, compName)
  local data = ns.EnsureRosterGroupData(rosterName, MakeIdiotsAppearDB.rosters[rosterName] or {})
  if FindComp(data, compName) then
    data.activeComp = compName
  end
end

-- Starts pre-arranged in the roster's current order, not blank. Returns the
-- final (possibly de-duplicated) name.
function ns.AddGroupComp(rosterName, name)
  local data = ns.EnsureRosterGroupData(rosterName, MakeIdiotsAppearDB.rosters[rosterName] or {})
  name = ns.Trim(name or "")
  if name == "" or FindComp(data, name) then
    name = GenerateUniqueCompName(data, name ~= "" and name or nil)
  end

  local groups = ChunkListIntoGroups(MakeIdiotsAppearDB.rosters[rosterName] or {})

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

-- Refuses to delete the last composition - a roster must always have one.
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

-- Roster names not currently placed in any of comp's groups, in roster
-- order. Placed names no longer on the roster just don't show up here.
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
-- Moves and reorders live raid members to match a composition, converging
-- over several GROUP_ROSTER_UPDATE events (each Set/SwapRaidSubgroup call
-- only takes effect after a server round-trip). Three phases: (1) move
-- anyone into their target group where there's room, (2) swap group
-- membership for whoever's still stuck, (3) reorder position within each
-- group. SwapRaidSubgroup only exchanges subgroup numbers, so two people
-- already in the same group can't be swapped directly - phase 3 routes one
-- of them out through a "bridge" member in a different group and back (a
-- 3-step dance) to reorder them.

local ApplyEngine = {
  pending = false,       -- true while a convergence run is in progress
  needGroup = nil,       -- [lowercased full name] = target group index
  needPosInGroup = nil,  -- [lowercased full name] = target position within that group
  lockedUnit = nil,      -- [lowercased full name] = true once its position swap has locked in
  groupsReady = false,   -- true once phase 1/2 (group placement) has converged
  rlKey = nil,           -- current raid leader's key, if any - Blizzard always forces them
                         -- into position 1 of their group, so they're excluded from
                         -- needPosInGroup and never used as a bridge/swap partner.
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
ns.FindRaidLeader = FindRaidLeader

-- Snapshot of the live raid, keyed by lowercased full name: subgroup,
-- position within it (by raid-index order), and nameToID for moving people.
local function SnapshotRaidGroups()
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
  return currentGroup, currentPos, nameToID, groupSize
end

-- Builds an 8x5 groups table from the raid's actual live layout - the
-- reverse of ApplyGroupComposition, used by "Apply Current". Every raid
-- member is placed, including pugs not on the roster; anyone not currently
-- in the raid is simply absent, which ComputeUnassignedWithExtras already
-- treats as unassigned.
function ns.CaptureGroupsFromRaid()
  local currentGroup, currentPos, nameToID = SnapshotRaidGroups()
  local groups = NewEmptyGroups()
  for key, subgroup in pairs(currentGroup) do
    local pos = currentPos[key]
    -- Guarded defensively; pos should always be 1-5 and unique per subgroup.
    if pos and pos <= SLOTS_PER_GROUP and groups[subgroup][pos] == nil then
      groups[subgroup][pos] = ns.GetFullUnitName("raid" .. nameToID[key]) or key
    end
  end
  return groups
end

-- Builds needGroup/needPosInGroup from comp.groups, shared by
-- ApplyGroupComposition and IsGroupCompInOrder.
local function ComputeCompNeeds(comp)
  local needGroup, needPosInGroup = {}, {}
  for groupIndex = 1, GROUPS_PER_COMP do
    for pos = 1, SLOTS_PER_GROUP do
      local name = comp.groups[groupIndex][pos]
      if name then
        local key = name:lower()
        needGroup[key] = groupIndex
        needPosInGroup[key] = pos
      end
    end
  end
  return needGroup, needPosInGroup
end

-- True when applying this composition right now would be a no-op: every
-- placed player is already in the right group and (subject to two
-- exceptions) position. Players not currently in the raid are ignored.
--
-- Raid-leader exception: Blizzard always forces the leader into position 1
-- of their group, so their own position is skipped, and the rest of their
-- group is compared by relative order instead of absolute slot.
--
-- No-bridge exception: phase 3 can only fix order via a bridge member in a
-- different group. If the whole raid is in one group, no bridge exists and
-- that group's order can never be fixed by Apply Groups, so it's exempt
-- from the check too (otherwise it'd read "out of order" forever).
function ns.IsGroupCompInOrder(comp)
  local needGroup, needPosInGroup = ComputeCompNeeds(comp)
  if not next(needGroup) then
    return false
  end

  local currentGroup, currentPos = SnapshotRaidGroups()
  local rlFullName = FindRaidLeader()
  local rlKey = rlFullName and rlFullName:lower()

  local occupiedGroups = {}
  for _, g in pairs(currentGroup) do
    occupiedGroups[g] = true
  end

  local compGroups = {}
  for key, targetGroup in pairs(needGroup) do
    compGroups[targetGroup] = compGroups[targetGroup] or {}
    table.insert(compGroups[targetGroup], key)
  end

  for targetGroup, keys in pairs(compGroups) do
    for _, key in ipairs(keys) do
      if currentGroup[key] and currentGroup[key] ~= targetGroup then
        return false
      end
    end

    local hasBridge = false
    for g in pairs(occupiedGroups) do
      if g ~= targetGroup then
        hasBridge = true
        break
      end
    end

    if hasBridge then
      table.sort(keys, function(a, b) return needPosInGroup[a] < needPosInGroup[b] end)

      local compOrder = {}
      for _, key in ipairs(keys) do
        if key ~= rlKey and currentGroup[key] == targetGroup then
          table.insert(compOrder, key)
        end
      end

      local actualOrder = {}
      for _, key in ipairs(compOrder) do
        table.insert(actualOrder, key)
      end
      table.sort(actualOrder, function(a, b) return currentPos[a] < currentPos[b] end)

      for i, key in ipairs(compOrder) do
        if actualOrder[i] ~= key then
          return false
        end
      end
    end
  end

  return true
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

  local currentGroup, currentPos, nameToID, groupSize = SnapshotRaidGroups()

  if not ApplyEngine.groupsReady then
    -- Phase 1: move anyone into their target group where there's room.
    -- Players not in the raid are silently skipped (currentGroup[key] is
    -- nil for them).
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

  -- Phase 3: fix ordering within each group now that everyone's in the
  -- right one. The raid leader has no needPosInGroup entry (see
  -- ApplyGroupComposition) and is never used as a bridge/swap partner.
  --
  -- Only one bridge-swap dance per call, not batched: batching multiple
  -- dances into a single pass triggered the client's "too many group
  -- actions" throttle in practice.
  local swappedOut = {}
  local anyUnresolved = false
  local unresolvedNames = {}
  for key, pos in pairs(needPosInGroup) do
    if not lockedUnit[key] and currentPos[key] and currentPos[key] ~= pos
        and key ~= ApplyEngine.rlKey and not swappedOut[key] then
      local bridgeKey
      for key2, group2 in pairs(currentGroup) do
        if group2 ~= currentGroup[key] and key2 ~= ApplyEngine.rlKey and not swappedOut[key2] then
          bridgeKey = key2
          break
        end
      end

      local swapKey
      for key2, pos2 in pairs(currentPos) do
        if currentGroup[key2] == currentGroup[key] and pos2 == pos
            and key2 ~= ApplyEngine.rlKey and not swappedOut[key2] then
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
        -- No bridge available (e.g. everyone's in this one group) - can't
        -- be reordered, note it and move on.
        anyUnresolved = true
        table.insert(unresolvedNames, ns.GetFullUnitName("raid" .. nameToID[key]) or key)
      end
    end
  end

  if anyUnresolved then
    table.sort(unresolvedNames)
    StopApplyEngine("Groups applied - some players could not be reordered (" ..
      table.concat(unresolvedNames, ", ") .. ").")
  else
    StopApplyEngine("Groups applied.")
  end
end

-- Runs on every GROUP_ROSTER_UPDATE; a no-op unless an apply is pending.
-- Debounced 0.5s behind the event, since firing swaps too rapidly risks
-- disconnects.
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

  -- needPosInGroup uses the comp's own slot index directly, preserving gaps
  -- exactly as arranged.
  local needGroup, needPosInGroup = ComputeCompNeeds(comp)

  -- Blizzard always forces the raid leader into position 1 of their group,
  -- so they get no needPosInGroup entry, and everyone else headed for their
  -- group is renumbered 2-5 by relative comp order (reserving slot 1)
  -- instead of their raw comp slot number. rlTargetGroup is wherever the
  -- comp places the leader, or their current group if the comp doesn't.
  local rlTargetGroup = rlKey and (needGroup[rlKey] or rlGroup) or nil
  if rlTargetGroup then
    local others = {}
    for key, g in pairs(needGroup) do
      if g == rlTargetGroup and key ~= rlKey then
        table.insert(others, key)
      end
    end
    table.sort(others, function(a, b)
      return (needPosInGroup[a] or math.huge) < (needPosInGroup[b] or math.huge)
    end)
    for i, key in ipairs(others) do
      needPosInGroup[key] = i + 1
    end
    needPosInGroup[rlKey] = nil
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
  ApplyEngine.pending = true
  ns.FireStateChanged()

  ns.StepApplyEngine()
end
