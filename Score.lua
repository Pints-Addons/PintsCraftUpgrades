-- Craft Upgrades scoring engine (original - no Pawn code or data).
-- An item's value = sum of (stat amount x weight) for the character's role; an upgrade is an item worth
-- more than what's equipped in that slot. Roles come from class + the talent tree with the most points,
-- and can be overridden per character with /craftup role <name>.
-- Compatibility: WoW Forever runs on the modern game client, where these older functions moved or were renamed.
local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)
local GetItemStats = GetItemStats or (C_Item and C_Item.GetItemStats)

local S = {}
_G.CraftUpgradesScore = S

---------------------------------------------------------------- roles and weights (our own values)
-- stat keys: STR AGI STA INT SPI ARMOR AP RAP SP HEAL CRIT HIT SCRIT SHIT MP5 DEF DODGE BLOCK BLOCKV DPS
S.ROLES = {
  melee  = { label = "Melee (strength)", STR = 1.0, AGI = 0.7, STA = 0.35, INT = 0.05, AP = 0.5, CRIT = 14, HIT = 12,
             DEF = 0.2, DODGE = 3, ARMOR = 0.02, DPS = 3.2, rangedDPS = 0.4 },
  agile  = { label = "Melee (agility)", AGI = 1.0, STR = 0.55, STA = 0.35, AP = 0.5, CRIT = 15, HIT = 14,
             DODGE = 2, ARMOR = 0.02, DPS = 3.2, rangedDPS = 0.4 },
  hunter = { label = "Hunter", AGI = 1.0, INT = 0.3, STA = 0.35, SPI = 0.05, STR = 0.05, AP = 0.2, RAP = 0.45,
             CRIT = 13, HIT = 13, MP5 = 0.6, ARMOR = 0.015, DPS = 0.6, rangedDPS = 2.8 },
  tank   = { label = "Tank", STA = 1.0, AGI = 0.6, STR = 0.5, ARMOR = 0.08, DEF = 1.6, DODGE = 12, BLOCK = 6,
             BLOCKV = 0.25, HIT = 6, AP = 0.2, DPS = 1.2, rangedDPS = 0.2 },
  caster = { label = "Caster", INT = 0.6, SPI = 0.25, STA = 0.4, SP = 1.0, SCRIT = 10, SHIT = 12, MP5 = 1.0,
             ARMOR = 0.005, DPS = 0, rangedDPS = 1.0 },
  healer = { label = "Healer", INT = 0.8, SPI = 0.6, STA = 0.35, HEAL = 0.6, SP = 0.6, SCRIT = 8, MP5 = 1.6,
             ARMOR = 0.005, DPS = 0, rangedDPS = 0.8 },
}
-- talent tree (1-3) -> role, per class; [0] = before any talents
local CLASS_ROLE = {
  WARRIOR = { [0] = "melee", "melee", "melee", "tank" },
  PALADIN = { [0] = "melee", "healer", "tank", "melee" },
  HUNTER  = { [0] = "hunter", "hunter", "hunter", "hunter" },
  ROGUE   = { [0] = "agile", "agile", "agile", "agile" },
  PRIEST  = { [0] = "healer", "healer", "healer", "caster" },
  SHAMAN  = { [0] = "melee", "caster", "melee", "healer" },
  MAGE    = { [0] = "caster", "caster", "caster", "caster" },
  WARLOCK = { [0] = "caster", "caster", "caster", "caster" },
  DRUID   = { [0] = "agile", "caster", "agile", "healer" },
}
local DUAL_WIELD = { WARRIOR = true, ROGUE = true, HUNTER = true }

-- WoW Forever (modern client): the chosen specialization, when the game has one (same order as the talent trees)
local function SpecIndex()
  local get = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or GetSpecialization
  local ok, i = pcall(function() return get and get() end)
  if ok and type(i) == "number" and i > 0 and i <= 3 then return i end
  return 0
end
S.SpecIndex = SpecIndex

local function TopTree()
  -- the talent tree with the most points, read the same way Pint's Tips reads it (trees 1-3: WoW Forever has no
  -- GetNumTalentTabs, which left every character on its class's default role)
  local best, bestPts = 0, 0
  local n = math.max(3, (GetNumTalentTabs and GetNumTalentTabs()) or 0)
  for i = 1, n do
    local ok, a, b, c, d, e = pcall(GetTalentTabInfo, i)
    local pts = ok and a and ((type(a) == "number") and e or c)
    if type(pts) == "number" and pts > bestPts then best, bestPts = i, pts end
  end
  -- no talent points to go on: the specialization the game says you chose, if it has one
  if best == 0 then best = SpecIndex() end
  return best
end

function S.RoleKey()
  local db = CraftUpgradesDB or {}
  local key = (GetUnitName and GetUnitName("player", false) or UnitName("player")) .. "-" .. GetRealmName()
  if db.role and db.role[key] and S.ROLES[db.role[key]] then return db.role[key], true end
  local _, class = UnitClass("player")
  local map = CLASS_ROLE[class] or CLASS_ROLE.WARRIOR
  return map[TopTree()] or map[0], false
end
function S.SetRole(name)
  CraftUpgradesDB = CraftUpgradesDB or {}
  CraftUpgradesDB.role = CraftUpgradesDB.role or {}
  CraftUpgradesDB.role[(GetUnitName and GetUnitName("player", false) or UnitName("player")) .. "-" .. GetRealmName()] = (name ~= "auto") and name or nil
end

---------------------------------------------------------------- reading an item's stats
local STATMAP = {
  ITEM_MOD_STRENGTH_SHORT = "STR", ITEM_MOD_AGILITY_SHORT = "AGI", ITEM_MOD_STAMINA_SHORT = "STA",
  ITEM_MOD_INTELLECT_SHORT = "INT", ITEM_MOD_SPIRIT_SHORT = "SPI", RESISTANCE0_NAME = "ARMOR",
  ITEM_MOD_ATTACK_POWER_SHORT = "AP", ITEM_MOD_RANGED_ATTACK_POWER_SHORT = "RAP",
  ITEM_MOD_SPELL_POWER_SHORT = "SP", ITEM_MOD_SPELL_HEALING_DONE_SHORT = "HEAL", ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "SP",
  ITEM_MOD_MANA_REGENERATION_SHORT = "MP5", ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = "DEF",
  ITEM_MOD_DAMAGE_PER_SECOND_SHORT = "DPS",
}
-- "Equip:" lines (enUS Classic wording)
local EQUIP = {
  -- "Increases healing done by up to 9 and damage done by up to 3 for all magical spells and effects." (WoW Forever)
  { "healing done by up to (%d+) and damage done by up to (%d+)", "HEAL", 1, "SP" },
  { "damage and healing done by magical spells and effects by up to (%d+)", "SP" },
  { "healing done by spells and effects by up to (%d+)", "HEAL" },
  { "damage done by %a+ spells and effects by up to (%d+)", "SP", 0.7 },
  { "^Equip: %+(%d+) ranged Attack Power", "RAP" },
  { "^Equip: %+(%d+) Attack Power%.$", "AP" },
  { "critical strike with spells by (%d+)%%", "SCRIT" },
  { "chance to hit with spells by (%d+)%%", "SHIT" },
  { "chance to get a critical strike by (%d+)%%", "CRIT" },
  { "your chance to hit by (%d+)%%", "HIT" },
  { "Restores (%d+) mana per 5 sec", "MP5" },
  { "Increased Defense %+(%d+)", "DEF" },
  { "chance to dodge an attack by (%d+)%%", "DODGE" },
  { "chance to block attacks with a shield by (%d+)%%", "BLOCK" },
  { "block value of your shield by (%d+)", "BLOCKV" },
}
local tip = CreateFrame("GameTooltip", "CraftUpgradesScanTip", UIParent, "GameTooltipTemplate")
tip:SetOwner(UIParent, "ANCHOR_NONE")
local cache = {}

function S.Stats(link)
  if not link then return nil end
  if cache[link] then return cache[link] end
  local st = {}
  local raw = (C_Item and C_Item.GetItemStats and C_Item.GetItemStats(link)) or (GetItemStats and GetItemStats(link)) or {}
  local fromList = {}
  for k, v in pairs(raw) do
    local key = STATMAP[k]
    if key then st[key] = (st[key] or 0) + v; fromList[key] = true end
  end
  tip:ClearLines()
  tip:SetOwner(UIParent, "ANCHOR_NONE")
  local ok = pcall(tip.SetHyperlink, tip, link)
  if ok then
    for i = 2, tip:NumLines() do
      local fs = _G["CraftUpgradesScanTipTextLeft" .. i]
      local text = fs and fs:GetText()
      if text and text:find("^Equip:") then
        for _, p in ipairs(EQUIP) do
          local n, n2 = text:match(p[1])
          if n then
            -- (skipped when the game's own stat list already counted it)
            if not fromList[p[2]] then st[p[2]] = (st[p[2]] or 0) + tonumber(n) * (p[3] or 1) end
            if p[4] and n2 and not fromList[p[4]] then st[p[4]] = (st[p[4]] or 0) + tonumber(n2) end
            break
          end
        end
      elseif text and not raw.ITEM_MOD_STAMINA_SHORT then
        -- older clients: white "+N Stat" lines
        for word, key in pairs({ Strength = "STR", Agility = "AGI", Stamina = "STA", Intellect = "INT", Spirit = "SPI" }) do
          local n = text:match("^%+(%d+) " .. word .. "$")
          if n and not raw["ITEM_MOD_" .. word:upper() .. "_SHORT"] then st[key] = (st[key] or 0) + tonumber(n) end
        end
      end
    end
  end
  if GetItemInfo(link) and ok then cache[link] = st end   -- don't remember half-loaded items
  return st
end

-- role for any character the ledger knows (class + talent tree index + per-character override)
function S.RoleFor(rec)
  local db = CraftUpgradesDB or {}
  local key = (rec.name or "") .. "-" .. (rec.realm or "")
  if db.role and db.role[key] and S.ROLES[db.role[key]] then return db.role[key] end
  local map = CLASS_ROLE[rec.classFile or ""] or CLASS_ROLE.WARRIOR
  return map[rec.specIndex or 0] or map[0]
end

function S.Value(link, equipLoc, roleKey)
  local st = S.Stats(link)
  if not st then return 0 end
  local w = S.ROLES[roleKey or S.RoleKey()]
  local v = 0
  for k, amount in pairs(st) do
    if k == "DPS" then
      local ranged = equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT" or equipLoc == "INVTYPE_THROWN"
      v = v + amount * ((ranged and w.rangedDPS or w.DPS) or 0)
    else
      v = v + amount * (w[k] or 0)
    end
  end
  return v
end

---------------------------------------------------------------- compare against what's equipped
local SLOT = {
  INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
  INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
  INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
  INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
  INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 },
}
-- ctx = { role = roleKey, class = "PRIEST", gear = function(slot) return link end }
local function UpgradeVs(link, ctx)
  local equipLoc = select(9, GetItemInfo(link))
  if not equipLoc or equipLoc == "" then return end
  local role = ctx.role
  local new = S.Value(link, equipLoc, role)
  if new <= 0 then return end
  local function Equipped(slot)
    local l = ctx.gear(slot)
    if not l then return nil, 0 end
    return l, S.Value(l, select(9, GetItemInfo(l)), role)
  end
  local oldLink, old
  if equipLoc == "INVTYPE_2HWEAPON" then
    local l1, v1 = Equipped(16)
    local _, v2 = Equipped(17)
    if not l1 then return 1e9, true end
    oldLink, old = l1, v1 + v2
  elseif equipLoc == "INVTYPE_WEAPON" then
    local l1, v1 = Equipped(16)
    if not l1 then return 1e9, true end
    oldLink, old = l1, v1
    local l2, v2 = Equipped(17)
    if DUAL_WIELD[ctx.class] and l2 and select(9, GetItemInfo(l2)) == "INVTYPE_WEAPON" and v2 < v1 then oldLink, old = l2, v2 end
  elseif SLOT[equipLoc] then
    if equipLoc == "INVTYPE_SHIELD" or equipLoc == "INVTYPE_HOLDABLE" or equipLoc == "INVTYPE_WEAPONOFFHAND" then
      local mh = ctx.gear(16)
      if mh and select(9, GetItemInfo(mh)) == "INVTYPE_2HWEAPON" then return end
    end
    for _, s in ipairs(SLOT[equipLoc]) do
      local l, v = Equipped(s)
      if not l then return 1e9, true end
      if not old or v < old then oldLink, old = l, v end
    end
  else
    return
  end
  if new <= old then return end
  return (new - old) / math.max(old, 1) * 100, false, oldLink
end
S.UpgradeVs = UpgradeVs

-- returns pct (number), empty (bool), existingLink  -- or nil if it can't be compared / isn't better
function S.Upgrade(link)
  local _, class = UnitClass("player")
  return UpgradeVs(link, { role = S.RoleKey(), class = class, gear = function(slot) return GetInventoryItemLink("player", slot) end })
end

-- which equipment slots an item would go in (for "upgrades for this slot")
function S.SlotsFor(equipLoc)
  if equipLoc == "INVTYPE_2HWEAPON" or equipLoc == "INVTYPE_WEAPON" then return { 16, 17 } end
  return SLOT[equipLoc]
end

function S.ClearCache() wipe(cache) end
