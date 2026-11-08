-- Craft Upgrades
-- Gathers every item your characters on this realm know how to craft (from DataStore_Crafts, which
-- records recipes when each character opens their profession window), keeps the ones this character
-- can wear and use right now (level + armor/weapon skill), scores each with our own stat weights
-- (Score.lua) against what's equipped, and lists the upgrades by gear slot with who can craft it.
-- Works through the list a few items at a time so it stays under Hardcore's script time limit.

-- Compatibility: WoW Forever runs on the modern game client, where these older functions moved or were renamed.
local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
local GetItemIcon = GetItemIcon or (C_Item and C_Item.GetItemIconByID)
local GetNumSkillLines, GetSkillLineInfo = GetNumSkillLines, GetSkillLineInfo
if not GetNumSkillLines and GetProfessions then
	local lines = {}
	GetNumSkillLines = function()
		wipe(lines)
		local p = { GetProfessions() }
		for k = 1, 6 do
			if p[k] then
				local name, _, rank, maxRank = GetProfessionInfo(p[k])
				if name then lines[#lines + 1] = { name, rank, maxRank } end
			end
		end
		return #lines
	end
	GetSkillLineInfo = function(i)
		local l = lines[i]
		if l then return l[1], false, false, l[2], 0, 0, l[3] end
	end
end

local BATCH = 8           -- items checked per step
local STEP = 0.05

local SLOT_ORDER = {
  INVTYPE_HEAD = { 1, "Head" }, INVTYPE_NECK = { 2, "Neck" }, INVTYPE_SHOULDER = { 3, "Shoulder" },
  INVTYPE_CLOAK = { 4, "Back" }, INVTYPE_CHEST = { 5, "Chest" }, INVTYPE_ROBE = { 5, "Chest" },
  INVTYPE_WRIST = { 6, "Wrist" }, INVTYPE_HAND = { 7, "Hands" }, INVTYPE_WAIST = { 8, "Waist" },
  INVTYPE_LEGS = { 9, "Legs" }, INVTYPE_FEET = { 10, "Feet" }, INVTYPE_FINGER = { 11, "Finger" },
  INVTYPE_TRINKET = { 12, "Trinket" }, INVTYPE_2HWEAPON = { 13, "Two-Hand" },
  INVTYPE_WEAPON = { 14, "One-Hand" }, INVTYPE_WEAPONMAINHAND = { 14, "Main Hand" },
  INVTYPE_WEAPONOFFHAND = { 15, "Off Hand" }, INVTYPE_SHIELD = { 15, "Off Hand" }, INVTYPE_HOLDABLE = { 15, "Off Hand" },
  INVTYPE_RANGED = { 16, "Ranged" }, INVTYPE_RANGEDRIGHT = { 16, "Ranged" }, INVTYPE_THROWN = { 16, "Ranged" },
}

-- item sub-type -> skill-line name the character must have (weapons + armor types)
local NEEDS_SKILL = {
  ["One-Handed Axes"] = "Axes", ["Two-Handed Axes"] = "Two-Handed Axes", ["Bows"] = "Bows", ["Guns"] = "Guns",
  ["One-Handed Maces"] = "Maces", ["Two-Handed Maces"] = "Two-Handed Maces", ["Polearms"] = "Polearms",
  ["One-Handed Swords"] = "Swords", ["Two-Handed Swords"] = "Two-Handed Swords", ["Staves"] = "Staves",
  ["Fist Weapons"] = "Fist Weapons", ["Daggers"] = "Daggers", ["Thrown"] = "Thrown", ["Crossbows"] = "Crossbows",
  ["Wands"] = "Wands", ["Shields"] = "Shield", ["Leather"] = "Leather", ["Mail"] = "Mail", ["Plate"] = "Plate Mail",
}

local function Print(m) print("|cffd4a017Pint's|r Craft Upgrades: " .. m) end
local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function KnownSkills()
  local known = {}
  if GetNumSkillLines then
    for i = 1, GetNumSkillLines() do
      local name, isHeader = GetSkillLineInfo(i)
      if name and not isHeader then known[name:lower()] = true end
    end
  end
  return known
end

-- ---------------------------------------------------------------- data gathering
local recipeOf = {}
local knownBy, profRanks = {}, {}   -- knownBy[recipeID] = true ; profRanks[profName] = { {char, rank}, ... }
local ledgerReagents = {}
local function CollectFromDataStore(items, crafters)
  if not (DataStore and DataStore.GetCharacters) then return end
  local chars = DataStore:GetCharacters() or {}
  for charName, key in pairs(chars) do
    local profs = DataStore:GetProfessions(key)
    if type(profs) == "table" then
      for profName, prof in pairs(profs) do
        -- Classic DataStore keeps professions as an array; the real name is prof.Name
        if type(prof) == "table" and prof.Name then profName = prof.Name end
        if type(prof) == "table" then
          local rank
          if DataStore.GetProfessionRank then local ok, r = pcall(DataStore.GetProfessionRank, DataStore, key, profName); if ok then rank = r end end
          rank = rank or tonumber(prof.Rank)
          if rank then profRanks[profName] = profRanks[profName] or {}; table.insert(profRanks[profName], { charName, rank }) end
        end
        if type(prof) == "table" and prof.Crafts then
          DataStore:IterateRecipes(prof, 0, 0, function(color, id)
            if type(color) ~= "number" then return end      -- only the classic recipe list entries
            id = tonumber(id)
            local recipeID = id
            if id then knownBy[id] = true end
            -- DataStore stores a recipe (spell) ID here; turn it into the item it makes
            if id and DataStore.GetCraftResultItem then
              local _, resultItem = DataStore:GetCraftResultItem(id)
              if resultItem and resultItem > 0 then
                id = resultItem
              else
                -- older scans stored the item ID itself; keep it only if it's a piece of gear
                local instant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
                local _, _, _, equipLoc = instant(id)
                if not equipLoc or equipLoc == "" then id = nil end
              end
            end
            if id and id > 0 then
              if not crafters[id] then crafters[id] = {}; items[#items + 1] = id end
              recipeOf[id] = recipeOf[id] or recipeID
              crafters[id][#crafters[id] + 1] = charName .. " (" .. profName .. ")"
            end
          end)
        end
      end
    end
  end
end

-- Pint's Alts first (our own data), then anything extra DataStore knows
local function CollectCraftables()
  local items, crafters = {}, {}
  wipe(knownBy); wipe(profRanks); wipe(ledgerReagents)
  local L = _G.PintsLedger
  if L and L.Craftables then
    local li, lc, lr = L.Craftables()
    for _, id in ipairs(li) do items[#items + 1] = id; crafters[id] = lc[id]; ledgerReagents[id] = lr[id] end
    for prof, list in pairs(L.ProfessionRanks()) do profRanks[prof] = list end
  end
  local before = {}
  for id in pairs(crafters) do before[id] = true end
  local dsItems, dsCrafters = {}, {}
  local savedRanks = {}
  for k, v in pairs(profRanks) do savedRanks[k] = { unpack(v) } end
  CollectFromDataStore(dsItems, dsCrafters)
  for _, id in ipairs(dsItems) do
    if not before[id] then items[#items + 1] = id; crafters[id] = dsCrafters[id] end
  end
  for k, v in pairs(savedRanks) do profRanks[k] = v end   -- ledger ranks win
  return items, crafters
end

local PROF_BY_SKILL = { [171]="Alchemy", [164]="Blacksmithing", [333]="Enchanting", [202]="Engineering",
  [165]="Leatherworking", [197]="Tailoring", [185]="Cooking", [129]="First Aid" }
local SOON = 25   -- "soon" = within this many skill points

-- Recipes no character knows yet that someone could learn now or soon. Chunked (Hardcore-safe).
-- result: candidates[createdItemID] = { cat = "now"|"soon", recipe = spellID, who = "Name (Prof rank/need)" }
-- Uses the recipe data bundled with Pints Recipe Sources (no other addons needed).
local function Obtainable(D, srcs, fac)
  for _, row in ipairs(srcs) do
    local k = row[1]
    if k == "t" or k == "v" then
      local n = D.npc[row[2]]
      if not n or n[5] == 0 or n[5] == fac then return true end
    elseif k == "q" then
      local q = D.quest[row[2]]
      if not q or q[2] == 0 or q[2] == fac then return true end
    else
      return true      -- drops, world drops, containers: anyone
    end
  end
end

local function GatherUnknown(done)
  local D = _G.RecipeSourcesData
  if not (D and D.recipes and D.make) then return done({}) end
  local fac = (UnitFactionGroup("player") == "Horde") and 1 or 2
  local ids = {}
  for id in pairs(D.recipes) do ids[#ids + 1] = id end
  local out, i = {}, 1
  local t
  t = C_Timer.NewTicker(0.01, function()
    local stop = math.min(i + 150, #ids)
    for k = i, stop do
      local id = ids[k]
      local r, mk = D.recipes[id], D.make[id]
      local profName = r and PROF_BY_SKILL[r[1]]
      if mk and profName and profRanks[profName] and r[4] == 0 and not knownBy[id] and Obtainable(D, r[5], fac) then
        local item, la = mk[1], r[2]
        local best
        for _, cr in ipairs(profRanks[profName]) do
          local cat = (cr[2] >= la and "now") or ((la - cr[2] <= SOON) and "soon") or nil
          if cat and (not best or (cat == "now" and best.cat == "soon")) then
            best = { cat = cat, recipe = id, who = ("%s (%s %d/%d)"):format(cr[1], profName, cr[2], la) }
          end
        end
        if best then
          local prev = out[item]
          if not prev or (best.cat == "now" and prev.cat == "soon") then out[item] = best end
        end
      end
    end
    i = stop + 1
    if i > #ids then t:Cancel(); done(out) end
  end)
end

local function GetMats(itemID)
  local mats = {}
  if ledgerReagents[itemID] then
    for _, r in ipairs(ledgerReagents[itemID]) do mats[#mats + 1] = { id = r[1], count = r[2] } end
    return mats
  end
  -- unlearned recipe: reagents from the bundled Recipe Sources data
  local D = _G.RecipeSourcesData
  local mk = D and D.make and recipeOf[itemID] and D.make[recipeOf[itemID]]
  if mk then
    for _, r in ipairs(mk[2]) do mats[#mats + 1] = { id = r[1], count = r[2] } end
    return mats
  end
  if not (DataStore and DataStore.GetCraftReagents) then return mats end
  local str = (recipeOf[itemID] and DataStore:GetCraftReagents(recipeOf[itemID])) or DataStore:GetCraftReagents(itemID)
  if type(str) ~= "string" then return mats end
  for part in str:gmatch("[^|]+") do
    local id, count = part:match("(%d+),(%d+)")
    if id then mats[#mats + 1] = { id = tonumber(id), count = tonumber(count) } end
  end
  return mats
end

-- Tooltip for a material: who on this realm has it, and where
local function ShowMatTooltip(owner, mat)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  local name = (C_Item and C_Item.GetItemInfo or GetItemInfo)(mat.id)
  GameTooltip:AddLine(name or ("item " .. mat.id))
  GameTooltip:AddLine(("Needed: %d"):format(mat.count), 1, 1, 1)
  local total, any = 0, false
  local L = _G.PintsLedger
  if L and L.ItemCounts then
    local list, tot = L.ItemCounts(mat.id)
    for _, e in ipairs(list) do
      if not any then GameTooltip:AddLine(" "); any = true end
      local parts = {}
      if e[2] > 0 then parts[#parts + 1] = e[2] .. " bags" end
      if e[3] > 0 then parts[#parts + 1] = e[3] .. " bank" end
      if e[4] > 0 then parts[#parts + 1] = e[4] .. " mail" end
      GameTooltip:AddDoubleLine(e[1], ("%d  (%s)"):format(e[2] + e[3] + e[4], table.concat(parts, ", ")), 1, 0.82, 0, 1, 1, 1)
    end
    total = tot
  end
  for charName, key in pairs((not any and DataStore and DataStore.GetCharacters and DataStore:GetCharacters()) or {}) do
    local bags, bank = 0, 0
    if DataStore.GetContainerItemCount then bags, bank = DataStore:GetContainerItemCount(key, mat.id) end
    local mail = DataStore.GetMailItemCount and DataStore:GetMailItemCount(key, mat.id) or 0
    bags, bank, mail = bags or 0, bank or 0, mail or 0
    local n = bags + bank + mail
    if n > 0 then
      if not any then GameTooltip:AddLine(" "); any = true end
      local parts = {}
      if bags > 0 then parts[#parts + 1] = bags .. " bags" end
      if bank > 0 then parts[#parts + 1] = bank .. " bank" end
      if mail > 0 then parts[#parts + 1] = mail .. " mail" end
      GameTooltip:AddDoubleLine(charName, ("%d  (%s)"):format(n, table.concat(parts, ", ")), 1, 0.82, 0, 1, 1, 1)
      total = total + n
    end
  end
  if any then
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Total", total, 1, 1, 1, total >= mat.count and 0 or 1, total >= mat.count and 1 or 0.3, 0.3)
  else
    GameTooltip:AddLine("None of your characters have this.", 1, 0.3, 0.3)
  end
  GameTooltip:Show()
end

-- ---------------------------------------------------------------- UI
local win = CreateFrame("Frame", "CraftUpgradesFrame", UIParent, "BackdropTemplate")
win:SetSize(820, 440)
win:SetPoint("CENTER")
win:SetFrameStrata("DIALOG")
win:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
win:SetBackdropColor(0, 0, 0, 0.92)
win:EnableMouse(true); win:SetMovable(true); win:RegisterForDrag("LeftButton")
win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing)
win:Hide()
tinsert(UISpecialFrames, "CraftUpgradesFrame")

local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 14, -12)
title:SetText("|cffd4a017Pint's|r Craft Upgrades")
local status = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
status:SetPoint("BOTTOMLEFT", 16, 16)
local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -2, -2)
local rescan = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
rescan:SetSize(80, 20); rescan:SetPoint("BOTTOMRIGHT", -12, 10); rescan:SetText("Rescan")

-- whose upgrades: nil = the character you're on (the default every session); or a Pint's Alts character entry
local target
-- "alts" mode: gear YOU can make that would be an upgrade for one of your other characters
local altsMode = false
local Scan
local function Ledger() return _G.PintsLedger end
local function Me() return (GetUnitName and GetUnitName("player", false) or UnitName("player")) end
local function ClassColor(classFile, name)
  local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
  return c and ("|c" .. (c.colorStr or "ffffffff") .. name .. "|r") or name
end

local pick = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
pick:SetSize(170, 20); pick:SetPoint("RIGHT", rescan, "LEFT", -6, 0)
local altsBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
altsBtn:SetSize(120, 20); altsBtn:SetPoint("RIGHT", pick, "LEFT", -6, 0)
local function UpdateButtons()
  pick:SetText("For: " .. (target and target.name or Me()) .. "  v")
  altsBtn:SetText(altsMode and "Back to one" or "Craft for Alts")
  if CraftUpgradesAPI and CraftUpgradesAPI.OnChange then pcall(CraftUpgradesAPI.OnChange) end
end
local menu
local function Menu()
  if not menu then
    menu = CreateFrame("Frame", nil, win, "BackdropTemplate")
    menu:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    menu:SetBackdropColor(0, 0, 0, 0.95); menu:SetFrameStrata("FULLSCREEN_DIALOG"); menu.rows = {}
  end
  if menu:IsShown() then menu:Hide(); return end
  local L = Ledger()
  local list = {}
  if L and L.Characters then for _, ch in ipairs(L.Characters()) do list[#list + 1] = ch end end
  table.sort(list, function(a, b)
    if (a.rec.level or 0) ~= (b.rec.level or 0) then return (a.rec.level or 0) > (b.rec.level or 0) end
    return a.name < b.name
  end)
  if #list == 0 then Print("needs Pint's Alts to know your other characters."); return end
  for i, ch in ipairs(list) do
    local r = menu.rows[i]
    if not r then
      r = CreateFrame("Button", nil, menu); r:SetSize(160, 18); r:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 18)
      r:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
      r.t = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); r.t:SetPoint("LEFT", 4, 0)
      r:SetScript("OnClick", function(self)
        menu:Hide()
        target = (self.ch.name == Me()) and nil or self.ch
        UpdateButtons(); Scan()
      end)
      menu.rows[i] = r
    end
    r.ch = ch
    r.t:SetText(ClassColor(ch.rec.classFile, ch.name) .. "  |cffaaaaaa" .. (ch.rec.level or "?") .. "|r" .. (ch.name == Me() and "  |cff40ff40(you)|r" or ""))
    r:Show()
  end
  for i = #list + 1, #menu.rows do menu.rows[i]:Hide() end
  menu:SetSize(172, #list * 18 + 12)
  menu:ClearAllPoints(); menu:SetPoint("BOTTOMRIGHT", pick, "TOPRIGHT", 0, 2)
  menu:Show()
end
pick:SetScript("OnClick", Menu)
pick:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine("Whose upgrades")
  GameTooltip:AddLine("Pick any of your characters (from Pint's Alts). Starts on the one you're playing each session.", 1, 1, 1, true)
  GameTooltip:Show()
end)
pick:SetScript("OnLeave", GameTooltip_Hide)
altsBtn:SetScript("OnClick", function()
  altsMode = not altsMode
  if menu then menu:Hide() end
  UpdateButtons(); Scan()
end)
altsBtn:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine("Craft for Alts")
  GameTooltip:AddLine("What the picked character can make that would be an upgrade for one of your others. Bind-on-pickup crafts are left out - they couldn't be handed over.", 1, 1, 1, true)
  GameTooltip:Show()
end)
altsBtn:SetScript("OnLeave", GameTooltip_Hide)
win:HookScript("OnHide", function() if menu then menu:Hide() end end)

-- Filters: which recipes to include
local FILTERS = { { "known", "Known recipes", "|cffffffff" }, { "now", "Learnable now", "|cff40ff40" }, { "soon", "Learnable soon (+" .. SOON .. ")", "|cffffff40" },
  { "wearsoon", "Wearable soon", "|cff66ccff" } }
local function Ahead() return (CraftUpgradesDB and CraftUpgradesDB.lvlAhead) or 2 end
local lastResults
local Render
local fx = 160
for _, f in ipairs(FILTERS) do
  local cb = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
  cb:SetSize(22, 22); cb:SetPoint("TOPLEFT", fx, -10)
  local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  lbl:SetPoint("LEFT", cb, "RIGHT", 1, 0); lbl:SetText(f[3] .. f[2] .. "|r")
  cb:SetScript("OnShow", function(self) self:SetChecked(CraftUpgradesDB and CraftUpgradesDB.filters and CraftUpgradesDB.filters[f[1]]) end)
  if f[1] == "wearsoon" then
    -- editable look-ahead: how many levels above your current level to include
    local function Label() lbl:SetText(f[3] .. f[2] .. " (+" .. Ahead() .. " lvl)|r") end
    Label()
    local pending
    local function Change(d)
      CraftUpgradesDB.lvlAhead = math.max(0, math.min(30, Ahead() + d))
      Label()
      if not pending then   -- rescan once the clicking stops
        pending = true
        C_Timer.After(0.6, function() pending = nil; if CraftUpgradesAPI then CraftUpgradesAPI.Scan() end end)
      end
    end
    local minus = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    minus:SetSize(18, 18); minus:SetPoint("LEFT", lbl, "RIGHT", 4, 0); minus:SetText("-")
    minus:SetScript("OnClick", function() Change(-1) end)
    local plus = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    plus:SetSize(18, 18); plus:SetPoint("LEFT", minus, "RIGHT", 2, 0); plus:SetText("+")
    plus:SetScript("OnClick", function() Change(1) end)
    for _, b in ipairs({ minus, plus }) do
      b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Levels to look ahead")
        GameTooltip:AddLine("Include gear you can wear within this many levels (0-30). 0 = only what you can wear now.", 1, 1, 1, true)
        GameTooltip:Show()
      end)
      b:SetScript("OnLeave", GameTooltip_Hide)
    end
    cb:HookScript("OnShow", Label)
  end
  cb:SetScript("OnClick", function(self)
    CraftUpgradesDB.filters[f[1]] = self:GetChecked() and true or false
    if lastResults then Render(lastResults) end
  end)
  fx = fx + 30 + lbl:GetStringWidth() + 14
end

-- Column headers (line up with the row columns below)
local function Header(text, x, width, justify)
  local h = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  h:SetPoint("TOPLEFT", 12 + x, -42); h:SetWidth(width); h:SetJustifyH(justify); h:SetText(text)
  return h
end
local hItem = Header("Slot / Item", 4, 260, "LEFT")
Header("Upgrade", 266, 50, "RIGHT")
Header("Mats (hover for who has them)", 330, 240, "LEFT")
local hWho = Header("Craftable by", 580, 190, "LEFT")
local divider = win:CreateTexture(nil, "ARTWORK")
divider:SetColorTexture(1, 0.82, 0, 0.35)
divider:SetHeight(1)
divider:SetPoint("TOPLEFT", 14, -56); divider:SetPoint("TOPRIGHT", -34, -56)

local scroll = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 12, -60); scroll:SetPoint("BOTTOMRIGHT", -32, 36)
local content = CreateFrame("Frame", nil, scroll); content:SetSize(770, 10); scroll:SetScrollChild(content)
local lines = {}
local function Line(i)
  if lines[i] then return lines[i] end
  local b = CreateFrame("Button", nil, content)
  b:SetSize(770, 20)
  b:SetPoint("TOPLEFT", 0, -(i - 1) * 20)
  b.left = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); b.left:SetPoint("LEFT", 4, 0); b.left:SetWidth(260); b.left:SetJustifyH("LEFT")
  b.mid = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); b.mid:SetPoint("LEFT", 266, 0); b.mid:SetWidth(50); b.mid:SetJustifyH("RIGHT")
  b.right = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); b.right:SetPoint("LEFT", 580, 0); b.right:SetWidth(190); b.right:SetJustifyH("LEFT")
  b:SetScript("OnEnter", function(self)
    if self.link then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(self.link); GameTooltip:Show() end
  end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  b:SetScript("OnClick", function(self) if self.link and IsModifiedClick("CHATLINK") then ChatEdit_InsertLink(self.link) end end)
  b.mats = {}
  for m = 1, 6 do
    local mb = CreateFrame("Button", nil, b)
    mb:SetSize(40, 18)
    mb:SetPoint("LEFT", 330 + (m - 1) * 41, 0)
    mb.icon = mb:CreateTexture(nil, "ARTWORK"); mb.icon:SetSize(16, 16); mb.icon:SetPoint("LEFT")
    mb.count = mb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); mb.count:SetPoint("LEFT", mb.icon, "RIGHT", 2, 0)
    mb:SetScript("OnEnter", function(self) if self.mat then ShowMatTooltip(self, self.mat) end end)
    mb:SetScript("OnLeave", GameTooltip_Hide)
    mb:SetScript("OnClick", function(self)
      if self.mat and IsModifiedClick("CHATLINK") then
        local _, l = (C_Item and C_Item.GetItemInfo or GetItemInfo)(self.mat.id); if l then ChatEdit_InsertLink(l) end
      end
    end)
    mb:Hide()
    b.mats[m] = mb
  end
  lines[i] = b
  return b
end

function Render(all)
  lastResults = all
  local flt = CraftUpgradesDB.filters
  local results = {}
  for _, r in ipairs(all) do
    if flt[r.cat] and (not r.lvlSoon or flt.wearsoon) then results[#results + 1] = r end
  end
  for _, l in ipairs(lines) do l:Hide() end
  hItem:SetText(altsMode and "Character / Item" or "Slot / Item"); hWho:SetText(altsMode and "Slot" or "Craftable by")
  table.sort(results, function(a, b)
    if altsMode and a.forName ~= b.forName then
      if (a.forLevel or 0) ~= (b.forLevel or 0) then return (a.forLevel or 0) > (b.forLevel or 0) end
      return a.forName < b.forName
    end
    if a.order ~= b.order then return a.order < b.order end
    return a.pct > b.pct
  end)
  local n, lastSlot = 0, nil
  for _, r in ipairs(results) do
    local group = altsMode and r.forName or r.slot
    if group ~= lastSlot then
      n = n + 1
      local h = Line(n); h.link = nil
      h.left:SetText(altsMode and (ClassColor(r.forClass, r.forName) .. "  |cffaaaaaa" .. (r.forLevel or "?") .. "|r") or ("|cffffd100" .. r.slot .. "|r"))
      h.mid:SetText(""); h.right:SetText("")
      for _, mb in ipairs(h.mats) do mb.mat = nil; mb:Hide() end
      h:Show(); lastSlot = group
    end
    n = n + 1
    local l = Line(n); l.link = r.link
    l.left:SetText("   " .. r.link .. (r.lvlSoon and ("  |cff66ccff(lvl " .. r.minLevel .. ")|r") or ""))
    l.mid:SetText(r.empty and "|cff00ff00empty|r" or ("|cff00ff00+%d%%|r"):format(r.pct))
    if altsMode then l.right:SetText(r.slot .. (r.cat == "now" and "  |cff40ff40(learn it)|r" or r.cat == "soon" and "  |cffffff40(learn soon)|r" or ""))
    else l.right:SetText(r.cat == "now" and ("|cff40ff40learn:|r " .. r.who) or r.cat == "soon" and ("|cffffff40soon:|r " .. r.who) or r.who) end
    for m, mb in ipairs(l.mats) do
      local mat = r.mats and r.mats[m]
      if mat then
        mb.mat = mat
        mb.icon:SetTexture((C_Item and C_Item.GetItemIconByID or GetItemIcon)(mat.id) or 134400)
        mb.count:SetText("x" .. mat.count)
        mb:Show()
      else
        mb.mat = nil; mb:Hide()
      end
    end
    l:Show()
  end
  if n == 0 then
    local l = Line(1); l.link = nil
    l.left:SetText(altsMode and ("Nothing " .. (target and target.name or Me()) .. " can craft is an upgrade for your other characters.") or "No craftable upgrades found for the checked filters.")
    l.mid:SetText(""); l.right:SetText("")
    for _, mb in ipairs(l.mats) do mb.mat = nil; mb:Hide() end
    l:Show(); n = 1
  end
  content:SetHeight(n * 20)
end

-- ---------------------------------------------------------------- scanning
local running, ticker
local retries = 0          -- automatic re-checks while the game is still loading item data
-- everything needed to judge an item for one character: the one you're on (live) or one Pint's Alts remembers
local function Context(entry)
  local S = CraftUpgradesScore
  if not entry then
    local _, class = UnitClass("player")
    return { name = Me(), level = UnitLevel("player"), skills = KnownSkills(), class = class, role = S.RoleKey(),
             gear = function(slot) return GetInventoryItemLink("player", slot) end }
  end
  local rec = entry.rec
  local skills = {}
  for _, sk in ipairs(rec.skillList or {}) do if sk[2] ~= 1 and sk[1] then skills[sk[1]:lower()] = true end end
  return { name = entry.name, level = rec.level or 1, skills = skills, class = rec.classFile, classFile = rec.classFile,
           role = S.RoleFor({ name = entry.name, realm = entry.realm, classFile = rec.classFile, specIndex = rec.specIndex }),
           gear = function(slot) return rec.gear and rec.gear[slot] end }
end
local function MadeBy(who, name) return who == name or who:sub(1, #name + 1) == name .. " " end
local scanToken = 0
function Scan(auto)
  if not auto then retries = 0 end
  if running then
    -- a new character or mode was picked mid-scan: stop the old one and start over
    if ticker then ticker:Cancel() end
    running = false
  end
  scanToken = scanToken + 1
  local token = scanToken
  if not (_G.PintsLedger or (DataStore and DataStore.GetProfessions)) then
    Print("needs Pint's Alts enabled."); return
  end
  running = true
  local items, crafters = CollectCraftables()
  status:SetText("finding learnable recipes...")
  GatherUnknown(function(cands)
  if token ~= scanToken then return end
  local cat = {}
  for id in pairs(crafters) do cat[id] = "known" end
  for id, c in pairs(cands) do
    if not crafters[id] then
      items[#items + 1] = id; crafters[id] = { c.who }; cat[id] = c.cat; recipeOf[id] = c.recipe
    end
  end
  -- who we're judging for, and which items count
  local ctxs = {}
  if altsMode then
    -- the crafter is whoever is picked (you, by default); everyone else is who it's for
    local maker = target and target.name or Me()
    local L = Ledger()
    for _, ch in ipairs(L and L.Characters and L.Characters() or {}) do
      if ch.name ~= maker then ctxs[#ctxs + 1] = (ch.name == Me()) and Context(nil) or Context(ch) end
    end
    -- only what the crafter makes (or could learn)
    local mine = {}
    for _, id in ipairs(items) do
      for _, w in ipairs(crafters[id] or {}) do if MadeBy(w, maker) then mine[#mine + 1] = id; break end end
    end
    items = mine
    if #ctxs == 0 then status:SetText("Pint's Alts doesn't know any other characters yet."); running = false; Render({}); return end
  else
    ctxs[1] = Context(target)
  end
  local results, i, waiting = {}, 0, 0
  status:SetText(("checking %d recipes..."):format(#items))
  ticker = C_Timer.NewTicker(STEP, function(t)
    for _ = 1, BATCH do
      i = i + 1
      local id = items[i]
      if not id then
        t:Cancel(); running = false
        if waiting > 0 and retries < 4 then
          -- the game hadn't loaded some items yet; their data has now been requested, so check again shortly
          retries = retries + 1
          status:SetText(("loading %d item%s from the game..."):format(waiting, waiting == 1 and "" or "s"))
          Render(results)
          C_Timer.After(1.5, function() if win:IsShown() and token == scanToken then Scan(true) end end)
          return
        end
        local whose = altsMode and ("that " .. (target and target.name or Me()) .. " can make for your other characters") or ("for " .. (target and target.name or Me()))
        status:SetText(("%d recipes checked %s%s"):format(#items, whose, waiting > 0 and (", %d still loading - Rescan in a moment"):format(waiting) or ""))
        Render(results)
        return
      end
      local name, link, _, _, minLevel, _, subType, _, equipLoc = GetInfo(id)
      if not name then
        waiting = waiting + 1
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
      elseif SLOT_ORDER[equipLoc] then
        local need = subType and NEEDS_SKILL[subType]
        local boundToCrafter = select(14, GetItemInfo(id)) == 1
        for _, cx in ipairs(ctxs) do
          if (minLevel or 0) <= cx.level + Ahead() then
            local ok = not boundToCrafter
            -- bind-on-pickup: only for the character who makes it (and never in alts mode)
            if boundToCrafter and not altsMode then for _, w in ipairs(crafters[id] or {}) do if MadeBy(w, cx.name) then ok = true end end end
            if ok and (not need or cx.skills[need:lower()]) then
              local good, pct, empty = pcall(CraftUpgradesScore.UpgradeVs, link, cx)
              if good and pct then
                local so = SLOT_ORDER[equipLoc]
                results[#results + 1] = { order = so[1], slot = so[2], link = link, pct = empty and 1e9 or floor(pct + 0.5), empty = empty,
                                          lvlSoon = (minLevel or 0) > cx.level, minLevel = minLevel,
                                          who = table.concat(crafters[id], ", "), mats = GetMats(id), cat = cat[id],
                                          forName = cx.name, forLevel = cx.level, forClass = cx.class }
              end
            end
          end
        end
      end
    end
    status:SetText(("checking %d / %d..."):format(i, #items))
  end)
  end)
end

rescan:SetScript("OnClick", function() Scan() end)
win:HookScript("OnShow", UpdateButtons)
CraftUpgradesAPI = { Scan = function() if not running then Scan() end end, Frame = win }
-- for Pint's Alts's character list (docked in its window): pick whose upgrades to show
function CraftUpgradesAPI.SetTarget(entry)
  target = (entry and entry.name ~= Me()) and entry or nil      -- in Craft for Alts mode this is the crafter
  if menu then menu:Hide() end
  UpdateButtons(); Scan()
end
function CraftUpgradesAPI.GetTarget() return target and target.name or Me(), altsMode end
CraftUpgradesAPI.OnChange = nil      -- set by Pint's Alts to repaint its list
function CraftUpgradesAPI.SetDocked(docked)
  -- docked: the ledger's list on the left picks the character, so the bottom picker isn't needed
  pick:SetShown(not docked)
  -- docked it's a tab of the Ledger window: no close button, and Esc closes the Ledger instead of just this page
  close:SetShown(not docked)
  for i = #UISpecialFrames, 1, -1 do if UISpecialFrames[i] == "CraftUpgradesFrame" then table.remove(UISpecialFrames, i) end end
  if not docked then tinsert(UISpecialFrames, "CraftUpgradesFrame") end
  altsBtn:ClearAllPoints()
  if docked then altsBtn:SetPoint("RIGHT", rescan, "LEFT", -6, 0) else altsBtn:SetPoint("RIGHT", pick, "LEFT", -6, 0) end
end

SLASH_CRAFTUPGRADES1 = "/craftup"
SlashCmdList.CRAFTUPGRADES = function(msg)
  local cmd, arg = (msg or ""):lower():match("^(%S*)%s*(%S*)")
  if cmd == "role" then
    local S = CraftUpgradesScore
    if arg ~= "" and (S.ROLES[arg] or arg == "auto") then S.SetRole(arg); S.ClearCache() end
    local key, manual = S.RoleKey()
    Print(("scoring as |cffffd100%s|r%s. /craftup role melee | agile | hunter | tank | caster | healer | auto"):format(S.ROLES[key].label, manual and " (set by you)" or " (from your class and talents)"))
    return
  end
  if win:IsShown() then win:Hide() return end
  if InCombatLockdown() then Print("open it out of combat."); return end
  UpdateButtons()
  win:Show()
  Scan()
end


-- ---------------------------------------------------------------- minimap button
-- Uses the shared minimap-button library other addons already load (so MinimapButtonButton can collect it);
-- falls back to a simple button on the minimap edge if that library isn't around.
local ICON = "Interface\\AddOns\\PintsCraftUpgrades\\UpgradeArrow"   -- our own green arrow
local ICON_COORDS = { 0, 1, 0, 1 }
local function Toggle() SlashCmdList.CRAFTUPGRADES() end
local function TooltipLines(tt)
  tt:AddLine("|cffd4a017Pint's|r Craft Upgrades")
  tt:AddLine("Click to show craftable gear upgrades for this character.", 1, 1, 1, true)
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
  CraftUpgradesDB = CraftUpgradesDB or {}
  CraftUpgradesDB.minimap = CraftUpgradesDB.minimap or { hide = false }
  CraftUpgradesDB.filters = CraftUpgradesDB.filters or { known = true, now = true, soon = true, wearsoon = true }
  if CraftUpgradesDB.filters.wearsoon == nil then CraftUpgradesDB.filters.wearsoon = true end
  local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
  local Icon = LibStub and LibStub("LibDBIcon-1.0", true)
  if LDB and Icon then
    local obj = LDB:NewDataObject("CraftUpgrades", {
      type = "launcher", text = "Pint's Craft Upgrades", icon = ICON, iconCoords = ICON_COORDS,
      OnClick = function() Toggle() end,
      OnTooltipShow = TooltipLines,
    })
    Icon:Register("CraftUpgrades", obj, CraftUpgradesDB.minimap)
    return
  end
  -- fallback button
  local b = CreateFrame("Button", "CraftUpgradesMinimapButton", Minimap)
  b:SetSize(31, 31); b:SetFrameStrata("MEDIUM"); b:SetFrameLevel(8)
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local icon = b:CreateTexture(nil, "BACKGROUND"); icon:SetTexture(ICON); icon:SetTexCoord(unpack(ICON_COORDS)); icon:SetSize(22, 22); icon:SetPoint("CENTER", 0, 1)
  local border = b:CreateTexture(nil, "OVERLAY"); border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder"); border:SetSize(53, 53); border:SetPoint("TOPLEFT")
  local function Place()
    local a = math.rad(CraftUpgradesDB.minimap.angle or 200)
    b:ClearAllPoints(); b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
  end
  Place()
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter(); local px, py = GetCursorPosition(); local s = Minimap:GetEffectiveScale()
      CraftUpgradesDB.minimap.angle = math.deg(math.atan2(py / s - my, px / s - mx)); Place()
    end)
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  b:SetScript("OnClick", Toggle)
  b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_LEFT"); TooltipLines(GameTooltip); GameTooltip:Show() end)
  b:SetScript("OnLeave", GameTooltip_Hide)
end)
