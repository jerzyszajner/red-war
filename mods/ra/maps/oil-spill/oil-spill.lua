--[[
   Copyright (c) The OpenRA Developers and Contributors
   This file is part of OpenRA, which is free software. It is made
   available to you under the terms of the GNU General Public License
   as published by the Free Software Foundation, either version 3 of
   the License, or (at your option) any later version. For more
   information, see COPYING.
]]

SpawnBuildings =
{
	{ FCOMTopLeft, OilTopLeft1, OilTopLeft2, OilTopLeft3 },
	{ FCOMTopRight, OilTopRight1, OilTopRight2, OilTopRight3 },
	{ FCOMBottomLeft, OilBottomLeft1, OilBottomLeft2, OilBottomLeft3 },
	{ FCOMBottomRight, OilBottomRight1, OilBottomRight2, OilBottomRight3 },
}

ExpansionInterval = 125
LoadTimeout = 1500
SailTimeout = 2500
MinEngineers = 1
ExpansionTypes = { oilb = true, ["oilb.husk"] = true, fcom = true }

Missions = { }
Landed = { }
Claimed = { }
BusyEngineers = { }

TargetKey = function(a)
	return a.Type .. ":" .. a.Location.X .. "," .. a.Location.Y
end

IsBusy = function(e)
	return Utils.Any(BusyEngineers, function(b) return b == e end)
end

ClearBusy = function(e)
	for i, b in ipairs(BusyEngineers) do
		if b == e then
			table.remove(BusyEngineers, i)
			return
		end
	end
end

FindMission = function(T)
	for _, m in ipairs(Missions) do
		if m.transport == T then
			return m
		end
	end
end

CellDistSq = function(a, b)
	local dx = a.X - b.X
	local dy = a.Y - b.Y
	return dx * dx + dy * dy
end

WalkableTerrain = { Clear = true, Beach = true, Road = true, Rough = true, Ore = true, Gems = true }

CellKey = function(cell)
	return cell.X .. "," .. cell.Y
end

-- Terrain never changes, so every lookup is cached. Cells outside the map count as no terrain.
TerrainCache = { }

TerrainAt = function(cell)
	local key = CellKey(cell)
	local terrain = TerrainCache[key]
	if terrain == nil then
		local ok, result = pcall(function() return Map.TerrainType(cell) end)
		terrain = ok and result or false
		TerrainCache[key] = terrain
	end

	return terrain
end

IsWalkable = function(cell)
	return WalkableTerrain[TerrainAt(cell)]
end

-- Water with open land next to it, where a boat can put infantry ashore.
-- Land under a building does not count: nobody can step off there.
IsShoreWater = function(cell)
	if TerrainAt(cell) ~= "Water" then
		return false
	end

	for dx = -1, 1 do
		for dy = -1, 1 do
			if (dx ~= 0 or dy ~= 0) and IsOpen(CPos.New(cell.X + dx, cell.Y + dy)) then
				return true
			end
		end
	end

	return false
end

-- ActorsInCircle measures from an actor's center, so work out the cells it covers:
-- a building's location is its top left cell and its center sits half the
-- footprint away from there.
Covers = function(a, cell)
	local corner = Map.CenterOfCell(a.Location)
	local w = math.floor((a.CenterPosition.X - corner.X) / 512 + 0.5)
	local h = math.floor((a.CenterPosition.Y - corner.Y) / 512 + 0.5)
	return cell.X >= math.min(a.Location.X, a.Location.X + w) and cell.X <= math.max(a.Location.X, a.Location.X + w)
		and cell.Y >= math.min(a.Location.Y, a.Location.Y + h) and cell.Y <= math.max(a.Location.Y, a.Location.Y + h)
end

-- Static actors (rocks, trees, buildings) block a landing and the way out of it.
-- Anything that can move (units, aircraft) does not count.
-- Static blockers rarely change, so a lookup stays valid for a short while.
-- A failed lookup counts as blocked, so no landing is planned on it.
BlockCache = { }

IsBlocked = function(cell)
	local key = CellKey(cell)
	local now = DateTime.GameTime
	local cached = BlockCache[key]
	if cached and now - cached.t < 250 then
		return cached.blocked
	end

	local ok, blocked = pcall(function()
		return Utils.Any(Map.ActorsInCircle(Map.CenterOfCell(cell), WDist.New(2048)), function(a)
			return not a.IsDead and not a.HasProperty("Move") and Covers(a, cell)
		end)
	end)

	blocked = not ok or blocked
	BlockCache[key] = { t = now, blocked = blocked }
	return blocked
end

IsOpen = function(cell)
	return IsWalkable(cell) and not IsBlocked(cell)
end

-- A helicopter needs an open cell with room around it for passengers to step out.
IsLandable = function(cell)
	if not IsOpen(cell) then
		return false
	end

	local open = 0
	for dx = -1, 1 do
		for dy = -1, 1 do
			if (dx ~= 0 or dy ~= 0) and IsOpen(CPos.New(cell.X + dx, cell.Y + dy)) then
				open = open + 1
			end
		end
	end

	return open >= 4
end

-- The penalty, if given, is added to the squared distance of a usable cell.
FindNearestCell = function(c, radius, bad, minDistSq, usable, penalty)
	local best, bestCost
	for dx = -radius, radius do
		for dy = -radius, radius do
			local d = dx * dx + dy * dy
			if d >= minDistSq and (not bestCost or d < bestCost) then
				local cell = CPos.New(c.X + dx, c.Y + dy)
				if usable(cell) and not (bad and bad[CellKey(cell)]) then
					local cost = d + (penalty and penalty(cell) or 0)
					if not bestCost or cost < bestCost then
						best = cell
						bestCost = cost
					end
				end
			end
		end
	end

	return best
end

-- Enemy defences and combat units, weighted by how much harm they do to a
-- landing party. Anti-air only matters for helicopters.
DefenceTypes = { pbox = 2, hbox = 2, gun = 2, ftur = 2, tsla = 3 }
AntiAirTypes = { agun = 3, sam = 3 }
DefendedDanger = 2

-- Filled by ManageBot for the bot it is working on.
Threats = { }

EnemyThreats = function(p)
	local list = { }
	for _, a in ipairs(TickActors) do
		if not a.IsDead and a.Owner ~= p and not a.Owner.IsNonCombatant and not a.Owner.IsAlliedWith(p) then
			if DefenceTypes[a.Type] then
				list[#list + 1] = { actor = a, location = a.Location, weight = DefenceTypes[a.Type], rangeSq = 64 }
			elseif AntiAirTypes[a.Type] then
				list[#list + 1] = { actor = a, location = a.Location, weight = AntiAirTypes[a.Type], rangeSq = 81, air = true }
			elseif a.IsInWorld and a.HasProperty("Attack") then
				list[#list + 1] = { actor = a, location = a.Location, weight = 1, rangeSq = 36 }
			end
		end
	end

	return list
end

-- A captured defence counts as well: it still shoots at the engineers.
DangerAt = function(cell, air, threats)
	local danger = 0
	for _, t in ipairs(threats or Threats) do
		if (air or not t.air) and CellDistSq(cell, t.location) <= t.rangeSq then
			danger = danger + t.weight
		end
	end

	return danger
end

IsDefended = function(a, air)
	return DangerAt(a.Location, air) >= DefendedDanger
end

FindLanding = function(T, location, bad)
	-- Only threats in reach of the search area matter.
	local near = { }
	for _, t in ipairs(Threats) do
		if CellDistSq(location, t.location) <= 400 then
			near[#near + 1] = t
		end
	end

	local air = T.Type == "tran"
	local penalty = function(cell) return DangerAt(cell, air, near) * 100 end
	if air then
		return FindNearestCell(location, 5, bad, 4, IsLandable, penalty)
	end

	return FindNearestCell(location, 7, bad, 0, IsShoreWater, penalty)
end

-- Targets a transport could not deliver to are skipped for a while,
-- so a released mission does not pick the same unreachable spot again.
FailedTargets = { }

MarkFailed = function(p, m)
	for _, key in ipairs(m.keys) do
		FailedTargets[p.Name .. key] = DateTime.GameTime
	end
end

RecentlyFailed = function(p, a)
	local t = FailedTargets[p.Name .. TargetKey(a)]
	return t and DateTime.GameTime - t < 3000
end

-- The world is scanned once per tick and shared by all bots.
TickActors = { }

-- Oil and outposts, plus any other building an enemy took from us, as long as
-- the engineer can capture it.
FreeTargets = function(p, probe)
	local list = { }
	-- The type check comes first: the list also holds actors without a
	-- location (world, players).
	for _, a in ipairs(TickActors) do
		if (ExpansionTypes[a.Type] or RepairTypes[a.Type]) and not a.IsDead and a.Owner ~= p and not a.Owner.IsAlliedWith(p) and not Claimed[TargetKey(a)] and not RecentlyFailed(p, a) then
			if (ExpansionTypes[a.Type] or WasOwned(p, a) or IsLoss(p, a)) and probe.CanCapture(a) and not IsWalkedTo(p, a) then
				list[#list + 1] = a
			end
		end
	end

	return list
end

-- Idle warships guard a boat on its trip. The engine's squad manager still owns
-- them and may send them elsewhere, so a ship that drifted away or went idle is
-- told to guard again.
EscortTypes = { "dd", "pt" }
MaxEscorts = 2

IsEscort = function(ship)
	for _, m in ipairs(Missions) do
		for _, s in ipairs(m.escorts or { }) do
			if s == ship then
				return true
			end
		end
	end

	return false
end

AssignEscorts = function(p, T, m)
	local ships = { }
	Utils.Do(p.GetActorsByTypes(EscortTypes), function(s)
		if not s.IsDead and s.IsInWorld and s.IsIdle and CellDistSq(s.Location, T.Location) <= 1600 and not IsEscort(s) then
			ships[#ships + 1] = s
		end
	end)

	table.sort(ships, function(x, y) return CellDistSq(x.Location, T.Location) < CellDistSq(y.Location, T.Location) end)

	m.escorts = { }
	for i = 1, math.min(#ships, MaxEscorts) do
		m.escorts[i] = ships[i]
		ships[i].Guard(T)
	end

	if #m.escorts > 0 then
		print("EXP " .. p.Name .. " escort " .. #m.escorts)
	end
end

-- The boat waits until its escort is close, so they pass danger together.
GatherTimeout = 500

EscortsClose = function(T, m)
	return Utils.All(m.escorts, function(s) return s.IsDead or CellDistSq(s.Location, T.Location) <= 25 end)
end

KeepEscorts = function(T, m)
	for _, s in ipairs(m.escorts or { }) do
		if not s.IsDead and (s.IsIdle or CellDistSq(s.Location, T.Location) > 100) then
			s.Guard(T)
		end
	end
end

-- Only ships still next to the boat are guarding it. Any others were sent
-- elsewhere by the squad manager and keep that order.
ReleaseEscorts = function(m)
	for _, s in ipairs(m.escorts or { }) do
		if not s.IsDead and not m.transport.IsDead and CellDistSq(s.Location, m.transport.Location) <= 100 then
			s.Stop()
		end
	end

	m.escorts = nil
end

ReleaseMission = function(m)
	ReleaseEscorts(m)
	for _, key in ipairs(m.keys) do
		Claimed[key] = nil
	end

	for _, list in ipairs({ m.engineers, m.passengers }) do
		for _, e in ipairs(list) do
			ClearBusy(e)
		end
	end

	for i, other in ipairs(Missions) do
		if other == m then
			table.remove(Missions, i)
			break
		end
	end
end

-- Cells of the buildings each bot has owned, so it can take back what it lost.
OwnedBefore = { }

-- Built once: the building types are fixed for the whole game.
OwnedTypes = nil

RememberOwned = function(p)
	OwnedBefore[p.Name] = OwnedBefore[p.Name] or { }
	if not OwnedTypes then
		OwnedTypes = { }
		for type in pairs(RepairTypes) do
			OwnedTypes[#OwnedTypes + 1] = type
		end
	end

	Utils.Do(p.GetActorsByTypes(OwnedTypes), function(a)
		OwnedBefore[p.Name][CellKey(a.Location)] = true
	end)
end

WasOwned = function(p, a)
	return OwnedBefore[p.Name] and OwnedBefore[p.Name][CellKey(a.Location)]
end

-- Buildings an enemy captured from a bot, by bot name and target key. Capture
-- triggers fill this, so the bot reacts at once instead of waiting for a
-- transport to pick the building by distance.
Losses = { }
Hooked = { }

OnBuildingCaptured = function(self, captor, oldOwner, newOwner)
	local key = TargetKey(self)
	if oldOwner.IsBot and not newOwner.IsAlliedWith(oldOwner) then
		Losses[oldOwner.Name] = Losses[oldOwner.Name] or { }
		Losses[oldOwner.Name][key] = self
		print("EXPLOST t=" .. DateTime.GameTime .. " " .. oldOwner.Name .. " " .. key .. " by " .. newOwner.Name)
	end

	if newOwner.IsBot and Losses[newOwner.Name] and Losses[newOwner.Name][key] then
		Losses[newOwner.Name][key] = nil
		print("EXPRETAKE t=" .. DateTime.GameTime .. " " .. newOwner.Name .. " " .. key .. " from " .. oldOwner.Name)
	end
end

-- New buildings appear all the time, so every tick hooks the ones not seen yet.
-- Only one building can stand on a cell, so a key needs a new hook only after
-- the old building is gone.
HookCaptures = function()
	for _, a in ipairs(TickActors) do
		if RepairTypes[a.Type] and not a.IsDead then
			local key = TargetKey(a)
			if not Hooked[key] or Hooked[key].IsDead then
				Hooked[key] = a
				Trigger.OnCapture(a, OnBuildingCaptured)
			end
		end
	end
end

IsLoss = function(p, a)
	return Losses[p.Name] ~= nil and Losses[p.Name][TargetKey(a)] ~= nil
end

-- Lost buildings that an enemy still holds. Destroyed or retaken ones drop out.
-- Defended ones wait until the defence is gone.
PendingLosses = function(p)
	local list = { }
	for key, a in pairs(Losses[p.Name] or { }) do
		if a.IsDead or a.Owner == p then
			Losses[p.Name][key] = nil
		elseif not a.Owner.IsAlliedWith(p) and not IsDefended(a, false) then
			list[#list + 1] = a
		end
	end

	return list
end

-- Diagnostics, read by analyze_bot_log.py.
-- Throttled per reason; the changing detail does not count as a new reason.
WhyLog = { }
Why = function(p, reason, detail)
	local key = p.Name .. reason
	local now = DateTime.GameTime
	if not WhyLog[key] or now - WhyLog[key] > 750 then
		WhyLog[key] = now
		print("EXPWHY t=" .. now .. " " .. p.Name .. " " .. reason .. (detail and " " .. detail or ""))
	end
end

CheckResult = function(p, type, location)
	Trigger.AfterDelay(800, function()
		local owned = Utils.Any(Map.ActorsInCircle(Map.CenterOfCell(location), WDist.New(1024)), function(a)
			return not a.IsDead and a.Owner == p and ExpansionTypes[a.Type] and a.Location == location
		end)
		print("EXPRES t=" .. DateTime.GameTime .. " " .. p.Name .. " " .. type .. " " .. location.X .. "," .. location.Y .. " " .. (owned and "captured" or "failed"))
	end)
end

StartMission = function(p, T, crew)
	local engineers = { }
	for _, e in ipairs(crew) do
		if e.Type == "e6" then
			engineers[#engineers + 1] = e
		end
	end

	if #engineers == 0 then
		-- Nothing to capture with, so let whoever is aboard get off.
		if #T.Passengers > 0 and T.IsIdle then
			T.UnloadPassengers()
		end

		Why(p, T.Type .. " has no engineers to take")
		return
	end

	local targets = FreeTargets(p, engineers[1])
	if #targets == 0 then
		Why(p, T.Type .. " no free targets")
		return
	end

	-- Taking back what an enemy took from us comes first, however far it is.
	-- Other enemy buildings are a worse choice than neutral oil and outposts.
	-- Defended targets are skipped.
	local air = T.Type == "tran"
	local scored = { }
	for _, a in ipairs(targets) do
		local danger = DangerAt(a.Location, air)
		if danger >= DefendedDanger then
			Why(p, T.Type .. " skips defended target", TargetKey(a) .. " danger=" .. danger)
		else
			local score = CellDistSq(T.Location, a.Location)
			if IsLoss(p, a) then
				score = score - 1000000
			elseif WasOwned(p, a) then
				score = score / 4
			elseif not a.Owner.IsNonCombatant then
				score = score * 4
			end

			scored[#scored + 1] = { actor = a, score = score, danger = danger }
		end
	end

	if #scored == 0 then
		Why(p, T.Type .. " all free targets defended")
		return
	end

	table.sort(scored, function(x, y) return x.score < y.score end)

	local primary, shore, danger
	for i = 1, math.min(#scored, 6) do
		shore = FindLanding(T, scored[i].actor.Location, nil)
		if shore then
			primary = scored[i].actor
			danger = scored[i].danger
			break
		end
	end

	if not primary then
		Why(p, T.Type .. " no landing spot near the 6 best targets")
		return
	end

	-- A retake goes alone with two engineers, since the enemy may defend it.
	-- Otherwise one target per engineer: the primary one and its closest neighbours.
	local retake = IsLoss(p, primary)
	local missionTargets = { primary }
	if not retake then
		local nearby = { }
		for _, a in ipairs(targets) do
			if a ~= primary and CellDistSq(primary.Location, a.Location) <= 324 and not IsDefended(a, air) then
				nearby[#nearby + 1] = a
			end
		end

		table.sort(nearby, function(x, y) return CellDistSq(primary.Location, x.Location) < CellDistSq(primary.Location, y.Location) end)

		for i = 1, math.min(#nearby, #engineers - 1) do
			missionTargets[#missionTargets + 1] = nearby[i]
		end
	end

	local keys = { }
	for _, a in ipairs(missionTargets) do
		local key = TargetKey(a)
		Claimed[key] = true
		keys[#keys + 1] = key
	end

	-- One engineer per target (two for a retake), as far as the transport has room.
	local eng = { }
	local aboard = #T.Passengers > 0
	local capacity = T.Type == "tran" and 8 or 5
	if aboard then
		for _, e in ipairs(crew) do
			eng[#eng + 1] = e
		end
	else
		for i = 1, math.min(#engineers, retake and 2 or #missionTargets, capacity) do
			eng[#eng + 1] = engineers[i]
		end
	end

	for _, e in ipairs(eng) do
		BusyEngineers[#BusyEngineers + 1] = e
	end

	local state = "load"
	if T.Type == "tran" and #T.Passengers == 0 and CellDistSq(eng[1].Location, T.Location) > 100 then
		T.Move(eng[1].Location)
		state = "pickup"
	elseif T.Type ~= "tran" and #T.Passengers == 0 then
		local pickup = FindNearestCell(eng[1].Location, 10, nil, 0, IsShoreWater)
		if pickup then
			T.Move(pickup)
			state = "pickup"
		end
	end

	local m = {
		transport = T,
		state = state,
		t0 = DateTime.GameTime,
		home = T.Location,
		shore = shore,
		targets = missionTargets,
		keys = keys,
		center = primary.Location,
		owner = p.Name,
		bad = { },
		retries = 0,
		retake = retake,
		engineers = eng,
		passengers = { }
	}

	Missions[#Missions + 1] = m
	print("EXP " .. p.Name .. " mission " .. primary.Type .. " by " .. T.Type .. " crew=" .. #eng .. " targets=" .. #missionTargets .. (retake and " retake" or "") .. " from " .. primary.Owner.Name .. " danger=" .. danger)
end

-- Sends idle units to the transport and returns how many of them are alive.
BoardAll = function(T, list)
	local alive = 0
	for _, e in ipairs(list) do
		if not e.IsDead then
			alive = alive + 1
			if e.IsInWorld and e.IsIdle then
				e.EnterTransport(T)
			end
		end
	end

	return alive
end

-- A boat has arrived when it stops. A helicopter has arrived once it is idle or
-- near the landing spot, and then gets a moment to put the passengers down.
HasArrived = function(T, m, now)
	if T.Type ~= "tran" then
		return T.IsIdle
	end

	if T.IsIdle or CellDistSq(T.Location, m.shore) <= 4 then
		m.arrivedAt = m.arrivedAt or now
		return now - m.arrivedAt > 150
	end

	return false
end

UpdateMission = function(p, T, m)
	local now = DateTime.GameTime

	if m.state == "pickup" then
		if T.IsIdle or now - m.t0 > 600 then
			m.state = "load"
			m.t0 = now
		end
	elseif m.state == "load" then
		local alive = BoardAll(T, m.engineers)
		local n = T.PassengerCount
		if n > 0 and (n >= alive or now - m.t0 > 750) then
			m.passengers = T.Passengers
			if T.Type ~= "tran" then
				AssignEscorts(p, T, m)
			end

			-- Waiting under fire is worse than sailing alone.
			local safe = DangerAt(T.Location, false) == 0
			m.state = (safe and m.escorts and #m.escorts > 0) and "gather" or "sail"
			if m.state == "sail" then
				T.Move(m.shore)
				T.UnloadPassengers()
			end

			m.t0 = now
		elseif n == 0 and now - m.t0 > LoadTimeout then
			print("EXP " .. p.Name .. " load timeout, engineers alive=" .. alive)
			ReleaseMission(m)
		end
	elseif m.state == "gather" then
		KeepEscorts(T, m)
		if EscortsClose(T, m) or now - m.t0 > GatherTimeout or DangerAt(T.Location, false) > 0 then
			T.Move(m.shore)
			T.UnloadPassengers()
			m.state = "sail"
			m.t0 = now
		end
	elseif m.state == "sail" then
		KeepEscorts(T, m)
		if (T.IsIdle or T.Type == "tran") and T.PassengerCount == 0 then
			ReleaseEscorts(m)
			local idx = 0
			local regroup = { }
			for _, e in ipairs(m.passengers) do
				if not e.IsDead and e.Type == "e6" then
					idx = idx + 1
					local target = m.targets[idx] or (m.retake and m.targets[1])
					if target and not target.IsDead and e.CanCapture(target) then
						e.Capture(target)
						CheckResult(p, target.Type, target.Location)

						-- The order keeps the target taken after the mission ends.
						local entry = AddLanded({ actor = e })
						entry.order = { actor = target, key = TargetKey(target) }
					else
						regroup[#regroup + 1] = e
					end
				end
			end

			-- Engineers without a target of their own board again and get a new mission.
			if #regroup > 0 then
				m.regroup = regroup
				m.state = "regroup"
			else
				T.Move(m.home)
				m.state = "return"
			end

			m.t0 = now
		elseif T.PassengerCount > 0 and m.retries < 4 and HasArrived(T, m, now) then
			-- Arrived but nobody could get off: try a different landing spot.
			m.bad[CellKey(m.shore)] = true
			m.retries = m.retries + 1
			m.arrivedAt = nil
			local shore = FindLanding(T, m.center, m.bad)
			print("EXPUNLOAD " .. p.Name .. " " .. T.Type .. " cannot unload at " .. CellKey(m.shore) .. " " .. tostring(TerrainAt(m.shore)) .. ", retry " .. m.retries)
			if shore then
				m.shore = shore
				T.Move(shore)
				T.UnloadPassengers()
				m.t0 = now
			else
				m.retries = 4
			end
		elseif now - m.t0 > SailTimeout or (T.IsIdle and T.PassengerCount > 0 and m.retries >= 4) then
			T.Move(m.home)
			MarkFailed(p, m)
			ReleaseMission(m)
			print("EXP " .. p.Name .. " sail timeout, passengers=" .. T.PassengerCount)
		end
	elseif m.state == "regroup" then
		local alive = BoardAll(T, m.regroup)
		local n = T.PassengerCount
		if alive == 0 or n >= alive or now - m.t0 > 500 then
			-- Those who did not make it aboard stop chasing the transport.
			for _, e in ipairs(m.regroup) do
				if not e.IsDead and e.IsInWorld then
					e.Stop()
					AddLanded({ actor = e, spare = true })
				end
			end

			local crew = T.Passengers
			local home = m.home

			-- Keep the targets reserved while the first engineers are still capturing.
			local keys = m.keys
			m.keys = { }
			Trigger.AfterDelay(1000, function()
				for _, key in ipairs(keys) do
					Claimed[key] = nil
				end
			end)

			ReleaseMission(m)
			if n > 0 then
				StartMission(p, T, crew)
			end

			if not FindMission(T) then
				T.Move(home)
			end
		end
	elseif m.state == "return" then
		if T.IsIdle or (T.Type == "tran" and CellDistSq(T.Location, m.home) <= 36) or now - m.t0 > SailTimeout then
			ReleaseMission(m)
		end
	end
end

-- Ticks per bot, so every bot gets its own EXPENG line.
EngLogCounter = { }

AddLanded = function(entry)
	for _, l in ipairs(Landed) do
		if l.actor == entry.actor then
			return l
		end
	end

	entry.owner = entry.actor.Owner
	Landed[#Landed + 1] = entry
	return entry
end

-- How many engineers of this bot are on their way to the target on foot.
WalkersTo = function(p, a)
	local key = TargetKey(a)
	local n = 0
	for _, l in ipairs(Landed) do
		if l.order and l.order.key == key and not l.actor.IsDead and l.actor.Owner == p and not l.actor.IsIdle then
			n = n + 1
		end
	end

	return n
end

IsWalkedTo = function(p, a)
	return WalkersTo(p, a) > 0
end

-- At most two engineers go for one lost building, since the enemy may defend it.
RetakeCrew = 2

-- Engineers at home walk to a lost building nearby instead of waiting for a
-- transport. If the building turns out to be across water, ManageLanded
-- remembers the failed order and a transport can take them later.
WalkToLosses = function(p, free, losses)
	for _, a in ipairs(losses) do
		local sent = 0
		local missing = RetakeCrew - WalkersTo(p, a)
		for i = #free, 1, -1 do
			local e = free[i]
			if sent < missing and CellDistSq(e.Location, a.Location) <= 400 and e.CanCapture(a) then
				e.Capture(a)
				local entry = AddLanded({ actor = e })
				entry.order = { actor = a, key = TargetKey(a) }
				table.remove(free, i)
				sent = sent + 1
			end
		end

		if sent > 0 then
			print("EXP " .. p.Name .. " walk " .. TargetKey(a) .. " engineers=" .. sent)
		end
	end
end

IsLanded = function(e)
	return Utils.Any(Landed, function(l) return l.actor == e end)
end

RepairTypes = { fcom = true, oilb = true, powr = true, apwr = true, tent = true, barr = true, dome = true, spen = true, syrd = true, hpad = true, afld = true, pbox = true, gun = true, ftur = true, tsla = true, sam = true, agun = true }

-- Engineers left on an island go for the nearest building that is not ours,
-- including buildings that were taken from their owner (e.g. a power plant).
-- They also repair badly damaged buildings of their own nearby.
LandedCandidates = function(p, probe)
	-- Only buildings worth an engineer, which also keeps capture checks cheap.
	local list = { }
	for _, a in ipairs(TickActors) do
		if (ExpansionTypes[a.Type] or RepairTypes[a.Type]) and not a.IsDead and a.IsInWorld then
			if a.Owner ~= p then
				if not a.Owner.IsAlliedWith(p) and not IsDefended(a, false) and probe.CanCapture(a) then
					list[#list + 1] = { actor = a, location = a.Location, neutral = a.Owner.IsNonCombatant }
				end
			elseif RepairTypes[a.Type] and a.Health < a.MaxHealth / 2 then
				list[#list + 1] = { actor = a, location = a.Location, hurt = true }
			end
		end
	end

	return list
end

-- A capture order that runs this long is stuck: the target cannot be reached,
-- and the engineer would wait for a path forever.
OrderTimeout = 2000

IsTried = function(entry, key, now)
	return entry.tried[key] and now - entry.tried[key] <= 3000
end

-- The nearest lost building this engineer can still help to take back.
NearestLoss = function(p, e, entry, losses, taken, now)
	local best, bestDist
	for _, a in ipairs(losses) do
		local key = TargetKey(a)
		local d = CellDistSq(e.Location, a.Location)
		if d <= 2500 and (not bestDist or d < bestDist) and (taken[key] or 0) < RetakeCrew and not IsTried(entry, key, now) then
			best = a
			bestDist = d
		end
	end

	return best
end

ManageLanded = function(p, losses)
	local now = DateTime.GameTime
	local candidates
	local taken = { }

	-- How many engineers of this bot are already walking to each target.
	Utils.Do(Landed, function(entry)
		if entry.order and not entry.actor.IsDead and entry.actor.Owner == p and not entry.actor.IsIdle then
			taken[entry.order.key] = (taken[entry.order.key] or 0) + 1
		end
	end)

	-- A lost building takes two engineers, anything else one.
	local isFull = function(a, key)
		return (taken[key] or 0) >= (IsLoss(p, a) and RetakeCrew or 1)
	end

	for i = #Landed, 1, -1 do
		local entry = Landed[i]
		local e = entry.actor
		entry.tried = entry.tried or { }
		if e.IsDead or e.Owner ~= entry.owner then
			table.remove(Landed, i)
		elseif e.Owner == p and e.IsInWorld and not e.IsIdle then
			entry.busySince = entry.busySince or now
			-- A captured husk turns into a new building, so the order may point at a dead actor.
			local loss = (not entry.order or entry.order.actor.IsDead or not IsLoss(p, entry.order.actor)) and NearestLoss(p, e, entry, losses, taken, now)
			if loss then
				-- Drop whatever it is doing: a lost building nearby comes first.
				local key = TargetKey(loss)
				if entry.order then
					taken[entry.order.key] = (taken[entry.order.key] or 1) - 1
				end

				e.Stop()
				e.Capture(loss)
				entry.order = { actor = loss, key = key }
				entry.busySince = now
				taken[key] = (taken[key] or 0) + 1
				print("EXP " .. p.Name .. " divert " .. key)
			elseif now - entry.busySince > OrderTimeout then
				-- Stopping makes the engineer idle, and the idle check below then
				-- marks the target as tried.
				print("EXPSTOP " .. p.Name .. " " .. (entry.order and entry.order.key or "no-order"))
				entry.busySince = nil
				e.Stop()
			end
		elseif e.Owner == p and e.IsInWorld then
			entry.busySince = nil

			-- An order that left the engineer idle without the building changing
			-- hands (or getting repaired) means the target cannot be reached
			-- (another island), so skip it for a while. A successful capture must
			-- not block a later retake.
			if entry.order then
				local t = entry.order.actor
				local failed
				if entry.order.repair then
					failed = not t.IsDead and t.Owner == p and t.Health < t.MaxHealth / 2
				else
					failed = not t.IsDead and t.Owner ~= p
				end

				if failed then
					entry.tried[entry.order.key] = now
				end

				entry.order = nil
			end

			-- Lost buildings come first, then oil, then anything else in reach.
			candidates = candidates or LandedCandidates(p, e)
			local best, bestDist, hurt, hurtDist, bestKey, hurtKey
			for _, c in ipairs(candidates) do
				local d = CellDistSq(e.Location, c.location)
				if c.hurt then
					local key = TargetKey(c.actor)
					if d <= 144 and (not hurtDist or d < hurtDist) and not IsTried(entry, key, now) then
						hurt = c.actor
						hurtDist = d
						hurtKey = key
					end
				elseif d <= 2500 then
					local rank = d
					if IsLoss(p, c.actor) then
						rank = d - 1000000
					elseif WasOwned(p, c.actor) then
						rank = d / 4
					elseif ExpansionTypes[c.actor.Type] then
						rank = d / 2
					end

					local key = TargetKey(c.actor)
					if (not bestDist or rank < bestDist) and not isFull(c.actor, key) and not IsTried(entry, key, now) then
						best = c.actor
						bestDist = rank
						bestKey = key
					end
				end
			end

			if best then
				entry.idleSince = nil
				entry.order = { actor = best, key = bestKey }
				taken[bestKey] = (taken[bestKey] or 0) + 1
				e.Capture(best)
			elseif hurt then
				entry.idleSince = nil
				entry.order = { actor = hurt, key = hurtKey, repair = true }
				e.InstantlyRepair(hurt)
			else
				entry.idleSince = entry.idleSince or now

				-- Idle with targets around: the analyzer counts these as stuck.
				if #candidates > 0 then
					print("EXPLAND " .. p.Name .. " " .. e.Location.X .. "," .. e.Location.Y .. " spare=" .. tostring(entry.spare == true) .. " best=nil hurt=false cands=" .. #candidates)
				end
			end
		end
	end
end

-- An island keeps one idle engineer on guard. Any others waiting next to it
-- are surplus and can be picked up for a new target. They stay in Landed
-- until a mission really takes them (see RemoveLanded).
TakeSurplus = function(p, now, minIdle)
	local group = { }
	for i = #Landed, 1, -1 do
		local entry = Landed[i]
		local e = entry.actor
		if not e.IsDead and e.IsInWorld and e.Owner == p and entry.idleSince and now - entry.idleSince >= minIdle then
			if #group == 0 then
				group[1] = { entry = entry, index = i }
			elseif CellDistSq(group[1].entry.actor.Location, e.Location) <= 144 and #group < 5 then
				group[#group + 1] = { entry = entry, index = i }
			end
		end
	end

	local crew = { }
	local entries = { }
	if #group >= 2 then
		-- Keep the first one on guard, take the rest.
		for k = 2, #group do
			crew[#crew + 1] = group[k].entry.actor
			entries[#entries + 1] = group[k].entry
		end
	elseif #group == 1 then
		-- A lone engineer has nothing to guard when we own no building near it.
		local e = group[1].entry.actor
		local owned = p.GetActorsByTypes({ "oilb", "fcom" })
		if not Utils.Any(owned, function(b) return not b.IsDead and CellDistSq(e.Location, b.Location) <= 144 end) then
			crew[1] = e
			entries[1] = group[1].entry
		end
	end

	return crew, entries
end

RemoveLanded = function(entries)
	for _, entry in ipairs(entries) do
		for i, l in ipairs(Landed) do
			if l == entry then
				table.remove(Landed, i)
				break
			end
		end
	end
end

-- Transports with engineers aboard and nothing to do. After AboardTimeout they
-- put the crew down at home, so the engineers are not stuck aboard for good.
AboardTimeout = 1500
Waiting = { }

WaitedFor = function(T)
	for _, w in ipairs(Waiting) do
		if w.transport == T then
			return DateTime.GameTime - w.since
		end
	end

	Waiting[#Waiting + 1] = { transport = T, since = DateTime.GameTime }
	return 0
end

StopWaiting = function(T)
	for i, w in ipairs(Waiting) do
		if w.transport == T then
			table.remove(Waiting, i)
			return
		end
	end
end

UnloadAtHome = function(p, T)
	StopWaiting(T)
	local base = p.GetActorsByTypes({ "fcom", "tent", "barr" })[1]
	if not base then
		return
	end

	local cell
	if T.Type == "tran" then
		cell = FindLanding(T, base.Location, nil)
	else
		cell = FindNearestCell(base.Location, 10, nil, 0, IsShoreWater)
	end

	if cell then
		print("EXP " .. p.Name .. " " .. T.Type .. " unloads idle crew at home " .. CellKey(cell))
		T.Move(cell)
		T.UnloadPassengers()
	end
end

ManageBot = function(p)
	local free = { }

	-- Engineers come out of the barracks, so those count as home as well.
	local bases = p.GetActorsByTypes({ "fcom", "tent", "barr" })
	Utils.Do(p.GetActorsByType("e6"), function(e)
		if not e.IsDead and e.IsInWorld and e.IsIdle and not IsBusy(e) and not IsLanded(e) then
			-- Far from every own base: stranded by a lost transport or a timed out
			-- mission, so treat it like an engineer that was dropped off.
			if #bases == 0 or Utils.Any(bases, function(b) return not b.IsDead and CellDistSq(e.Location, b.Location) <= 225 end) then
				free[#free + 1] = e
			else
				AddLanded({ actor = e })
			end
		end
	end)

	RememberOwned(p)
	Threats = EnemyThreats(p)
	local losses = PendingLosses(p)
	WalkToLosses(p, free, losses)
	ManageLanded(p, losses)

	local transports = p.GetActorsByTypes({ "lst", "tran" })

	EngLogCounter[p.Name] = (EngLogCounter[p.Name] or 0) + 1
	if EngLogCounter[p.Name] % 16 == 0 then
		local aboard, hunting, waiting, busy = 0, 0, 0, 0
		Utils.Do(transports, function(T) aboard = aboard + T.PassengerCount end)
		for _, entry in ipairs(Landed) do
			if not entry.actor.IsDead and entry.actor.Owner == p then
				if entry.idleSince then
					waiting = waiting + 1
				else
					hunting = hunting + 1
				end
			end
		end

		for _, e in ipairs(BusyEngineers) do
			if not e.IsDead and e.IsInWorld and e.Owner == p then
				busy = busy + 1
			end
		end

		print("EXPENG t=" .. DateTime.GameTime .. " " .. p.Name .. " home=" .. #free .. " boarding=" .. busy .. " aboard=" .. aboard .. " ashore_active=" .. hunting .. " ashore_waiting=" .. waiting)
	end

	Utils.Do(transports, function(T)
		if T.IsDead then
			return
		end

		-- A lost building nobody is on the way to yet.
		local urgent = Utils.Any(losses, function(a)
			return not Claimed[TargetKey(a)] and not RecentlyFailed(p, a) and not IsWalkedTo(p, a) and not IsDefended(a, T.Type == "tran")
		end)

		-- An empty transport on its way home turns around for a retake.
		local m = FindMission(T)
		if m and urgent and m.state == "return" then
			ReleaseMission(m)
			m = nil
		end

		if m then
			StopWaiting(T)
			UpdateMission(p, T, m)
		elseif T.PassengerCount > 0 then
			StartMission(p, T, T.Passengers)
			if not FindMission(T) and WaitedFor(T) > AboardTimeout then
				UnloadAtHome(p, T)
			end
		elseif T.IsIdle or T.Type == "tran" or urgent then
			-- Pick up the free engineers closest to the transport, wherever they
			-- are, together with those standing next to them.
			local anchor
			for _, e in ipairs(free) do
				if not anchor or CellDistSq(e.Location, T.Location) < CellDistSq(anchor.Location, T.Location) then
					anchor = e
				end
			end

			local near = { }
			for _, e in ipairs(free) do
				if CellDistSq(e.Location, anchor.Location) <= 144 then
					near[#near + 1] = e
				end
			end

			if #near < MinEngineers then
				local surplus, entries = TakeSurplus(p, DateTime.GameTime, urgent and 0 or 1500)
				if #surplus > 0 then
					StartMission(p, T, surplus)
					if FindMission(T) then
						RemoveLanded(entries)
					end
				else
					Why(p, T.Type .. " idle, no free engineers", "(free=" .. #free .. ")")
				end
			else
				table.sort(near, function(x, y) return CellDistSq(x.Location, T.Location) < CellDistSq(y.Location, T.Location) end)
				local group = { }
				for i = 1, math.min(#near, 5) do
					group[#group + 1] = near[i]
				end

				StartMission(p, T, group)
				for _, e in ipairs(group) do
					for i, f in ipairs(free) do
						if f == e then
							table.remove(free, i)
							break
						end
					end
				end
			end
		end
	end)
end

CleanupMissions = function()
	for i = #Waiting, 1, -1 do
		if Waiting[i].transport.IsDead then
			table.remove(Waiting, i)
		end
	end

	for i = #Missions, 1, -1 do
		if Missions[i].transport.IsDead then
			local alive = 0
			for _, e in ipairs(Missions[i].engineers) do
				if not e.IsDead then
					alive = alive + 1
				end
			end

			print("EXPLOSS " .. Missions[i].owner .. " transport lost in state " .. Missions[i].state .. ", engineers alive " .. alive .. " of " .. #Missions[i].engineers)
			ReleaseMission(Missions[i])
		end
	end
end

ExpansionTick = function()
	TickActors = Map.ActorsInWorld
	local hooked, hookErr = pcall(HookCaptures)
	if not hooked then
		print("EXP error " .. tostring(hookErr))
	end

	for i = 0, 3 do
		local p = Player.GetPlayer("Multi" .. i)
		if p and p.IsBot then
			local ok, err = pcall(ManageBot, p)
			if not ok then
				print("EXP error " .. p.Name .. ": " .. tostring(err))
			end
		end
	end

	local cleaned, cleanErr = pcall(CleanupMissions)
	if not cleaned then
		print("EXP error " .. tostring(cleanErr))
	end
	Trigger.AfterDelay(ExpansionInterval, ExpansionTick)
end

WorldLoaded = function()
	for i = 0, 3 do
		local player = Player.GetPlayer("Multi" .. i)
		if player then
			Utils.Do(SpawnBuildings[player.Spawn], function(actor)
				actor.Owner = player
			end)
		end
	end

	Trigger.AfterDelay(ExpansionInterval, ExpansionTick)
end
