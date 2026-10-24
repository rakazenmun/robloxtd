-- discord iomonewz roblox williamoct23

local RunService = game:GetService("RunService")

local TowerTargeting = {}
TowerTargeting.__index = TowerTargeting

TowerTargeting.Modes = table.freeze({
    First = "First",
    Last = "Last",
    Nearest = "Nearest",
    Farthest = "Farthest",
    Strongest = "Strongest",
    Weakest = "Weakest",
    Fastest = "Fastest",
    Slowest = "Slowest",
    LeastReserved = "LeastReserved",
    Splash = "Splash",
})

local DEFAULTS = table.freeze({
    Mode = "First",
    Range = 25,
    MinimumRange = 0,
    MinimumHeight = -math.huge,
    MaximumHeight = math.huge,
    ArcDegrees = 360,
    DetectHidden = false,
    HitGround = true,
    HitFlying = false,
    RequireLineOfSight = false,
    UsePriority = true,
    AvoidOverkill = true,
    Sticky = false,
    SwitchMargin = 0,
    RefreshInterval = 0.1,
    ProjectileSpeed = 0,
    MaximumLeadTime = 3,
    AimOffset = Vector3.new(0, 0, 0),
    SplashRadius = 8,
    SplashLimit = 10,
})

local function cellKey(x, z)
    return tostring(x) .. ":" .. tostring(z)
end

local function distanceSquared(a, b)
    local delta = a - b
    return delta:Dot(delta)
end

local function makeSettings(overrides)
    local settings = table.clone(DEFAULTS)
    for name, value in pairs(overrides or {}) do
        settings[name] = value
    end
    return settings
end

local function effectiveHealth(enemy)
    return enemy.Health + enemy.Shield
end

local function interceptTime(offset, velocity, speed, maximum)
    local a = velocity:Dot(velocity) - speed * speed
    local b = 2 * offset:Dot(velocity)
    local c = offset:Dot(offset)
    if c == 0 then
        return 0
    end
    -- avoids dividing by a near zero quadratic term
    if math.abs(a) < 0.000001 then
        if b < 0 then
            return math.min(-c / b, maximum)
        end
        return 0
    end
    local discriminant = b * b - 4 * a * c
    if discriminant < 0 then
        return 0
    end
    local root = math.sqrt(discriminant)
    local first = (-b - root) / (2 * a)
    local second = (-b + root) / (2 * a)
    local time = math.huge
    if first >= 0 then
        time = first
    end
    if second >= 0 then
        time = math.min(time, second)
    end
    if time == math.huge then
        return 0
    end
    return math.min(time, maximum)
end

function TowerTargeting.new(enemyFolder, blockerFolder, cellSize)
    local self = setmetatable({}, TowerTargeting)
    self.EnemyFolder = enemyFolder
    self.BlockerFolder = blockerFolder
    self.CellSize = cellSize or 16
    self.Enemies = {}
    self.Towers = {}
    self.Grid = {}
    self.Reservations = {}
    self.Clock = 0
    self.NextEnemyId = 0
    self.NextTowerId = 0
    self.NextReservationId = 0
    self.MaximumRadius = 0
    self.Running = false
    self.Connection = nil
    self.TargetChanged = Instance.new("BindableEvent")
    self.RaycastParameters = RaycastParams.new()
    self.RaycastParameters.FilterType = Enum.RaycastFilterType.Include
    self.RaycastParameters.FilterDescendantsInstances = { blockerFolder }
    self.RaycastParameters.IgnoreWater = true
    self.AddedConnection = enemyFolder.ChildAdded:Connect(function(model)
        self:_registerEnemy(model)
    end)
    self.RemovedConnection = enemyFolder.ChildRemoved:Connect(function(model)
        self:_unregisterEnemy(model)
    end)
    for _, model in ipairs(enemyFolder:GetChildren()) do
        self:_registerEnemy(model)
    end
    return self
end

function TowerTargeting:_registerEnemy(model)
    self.NextEnemyId = self.NextEnemyId + 1
    local root = model.PrimaryPart
    self.Enemies[model] = {
        Model = model,
        Root = root,
        Id = self.NextEnemyId,
        Position = root.Position,
        Velocity = Vector3.new(0, 0, 0),
        Health = model:GetAttribute("Health"),
        Shield = model:GetAttribute("Shield"),
        Progress = model:GetAttribute("Progress"),
        Priority = model:GetAttribute("TargetPriority"),
        Radius = model:GetAttribute("TargetRadius"),
        Flying = model:GetAttribute("Flying"),
        Hidden = model:GetAttribute("Hidden"),
        Invulnerable = model:GetAttribute("Invulnerable"),
        Reserved = 0,
    }
end

function TowerTargeting:_unregisterEnemy(model)
    local enemy = self.Enemies[model]
    self.Enemies[model] = nil
    for token, reservation in pairs(self.Reservations) do
        if reservation.Enemy == enemy then
            self.Reservations[token] = nil
        end
    end
    for _, tower in pairs(self.Towers) do
        if tower.Focus == model then
            tower.Focus = nil
        end
        if tower.Target == model then
            self:_changeTarget(tower, nil)
        end
    end
end

function TowerTargeting:AddTower(model, origin, overrides)
    self.NextTowerId = self.NextTowerId + 1
    local tower = {
        Model = model,
        Origin = origin,
        Id = self.NextTowerId,
        Settings = makeSettings(overrides),
        Target = nil,
        Focus = nil,
        Enabled = true,
        NextRefresh = self.Clock,
        Candidates = {},
        Visible = {},
        SplashScores = {},
    }
    self.Towers[model] = tower
    return tower
end

function TowerTargeting:RemoveTower(model)
    local tower = self.Towers[model]
    self:_changeTarget(tower, nil)
    for token, reservation in pairs(self.Reservations) do
        if reservation.Tower == tower then
            self:CancelReservation(token)
        end
    end
    self.Towers[model] = nil
end

function TowerTargeting:ConfigureTower(model, changes)
    local tower = self.Towers[model]
    for name, value in pairs(changes) do
        tower.Settings[name] = value
    end
    tower.NextRefresh = self.Clock
end

function TowerTargeting:SetMode(model, mode)
    self:ConfigureTower(model, { Mode = mode })
end

function TowerTargeting:SetFocus(model, enemyModel)
    local tower = self.Towers[model]
    tower.Focus = enemyModel
    tower.NextRefresh = self.Clock
end

function TowerTargeting:SetEnabled(model, enabled)
    local tower = self.Towers[model]
    tower.Enabled = enabled
    tower.NextRefresh = self.Clock
    if not enabled then
        self:_changeTarget(tower, nil)
    end
end

function TowerTargeting:_refreshEnemies(deltaTime)
    -- avoids reading every attribute, once per tower
    table.clear(self.Grid)
    self.MaximumRadius = 0
    for _, enemy in pairs(self.Enemies) do
        local model = enemy.Model
        local position = enemy.Root.Position
        if deltaTime > 0 then
            -- pivot moved enemies, do not report useful assembly velocity
            enemy.Velocity = (position - enemy.Position) / deltaTime
        end
        enemy.Position = position
        enemy.Health = model:GetAttribute("Health")
        enemy.Shield = model:GetAttribute("Shield")
        enemy.Progress = model:GetAttribute("Progress")
        enemy.Priority = model:GetAttribute("TargetPriority")
        enemy.Radius = model:GetAttribute("TargetRadius")
        enemy.Flying = model:GetAttribute("Flying")
        enemy.Hidden = model:GetAttribute("Hidden")
        enemy.Invulnerable = model:GetAttribute("Invulnerable")
        if enemy.Health > 0 then
            local x = math.floor(position.X / self.CellSize)
            local z = math.floor(position.Z / self.CellSize)
            local key = cellKey(x, z)
            local bucket = self.Grid[key]
            if bucket == nil then
                bucket = {}
                self.Grid[key] = bucket
            end
            bucket[#bucket + 1] = enemy
            self.MaximumRadius = math.max(self.MaximumRadius, enemy.Radius)
        end
    end
end

function TowerTargeting:_visitCells(position, radius, visitor)
    -- floor keeps negative world positions in the correct grid cells
    local minimumX = math.floor((position.X - radius) / self.CellSize)
    local maximumX = math.floor((position.X + radius) / self.CellSize)
    local minimumZ = math.floor((position.Z - radius) / self.CellSize)
    local maximumZ = math.floor((position.Z + radius) / self.CellSize)
    for x = minimumX, maximumX do
        for z = minimumZ, maximumZ do
            local bucket = self.Grid[cellKey(x, z)]
            if bucket ~= nil then
                for _, enemy in ipairs(bucket) do
                    visitor(enemy)
                end
            end
        end
    end
end

function TowerTargeting:_insideRange(tower, enemy)
    local settings = tower.Settings
    local offset = enemy.Position - tower.Origin.Position
    -- center only checks would make large enemies enter range too late
    local range = settings.Range + enemy.Radius
    local minimum = settings.MinimumRange + enemy.Radius
    local squared = offset:Dot(offset)
    if squared > range * range then
        return false
    end
    if settings.MinimumRange > 0 and squared < minimum * minimum then
        return false
    end
    if offset.Y < settings.MinimumHeight then
        return false
    end
    if offset.Y > settings.MaximumHeight then
        return false
    end
    if settings.ArcDegrees < 360 then
        local horizontal = Vector3.new(offset.X, 0, offset.Z)
        local forward = tower.Origin.CFrame.LookVector
        local flatForward = Vector3.new(forward.X, 0, forward.Z)
        if horizontal.Magnitude > 0 and flatForward.Magnitude > 0 then
            local dot = horizontal.Unit:Dot(flatForward.Unit)
            local cutoff = math.cos(math.rad(settings.ArcDegrees / 2))
            if dot < cutoff then
                return false
            end
        end
    end
    return true
end

function TowerTargeting:_eligible(tower, enemy)
    local settings = tower.Settings
    if enemy.Health <= 0 or enemy.Invulnerable then
        return false
    end
    if enemy.Hidden and not settings.DetectHidden then
        return false
    end
    if enemy.Flying and not settings.HitFlying then
        return false
    end
    if not enemy.Flying and not settings.HitGround then
        return false
    end
    if settings.AvoidOverkill and enemy.Reserved >= effectiveHealth(enemy) then
        return false
    end
    return self:_insideRange(tower, enemy)
end

function TowerTargeting:_visible(tower, enemy)
    if not tower.Settings.RequireLineOfSight then
        return true
    end
    local cached = tower.Visible[enemy]
    if cached ~= nil then
        return cached
    end
    local origin = tower.Origin.Position
    local destination = enemy.Position + tower.Settings.AimOffset
    local direction = destination - origin
    local visible = true
    if direction.Magnitude > 0 then
        local hit = workspace:Raycast(origin, direction, self.RaycastParameters)
        visible = hit == nil
    end
    -- keeps other enemies from hiding a valid target
    tower.Visible[enemy] = visible
    return visible
end

function TowerTargeting:_collect(tower)
    -- visibility must not survive a scan
    table.clear(tower.Candidates)
    table.clear(tower.Visible)
    table.clear(tower.SplashScores)
    local radius = tower.Settings.Range + self.MaximumRadius
    self:_visitCells(tower.Origin.Position, radius, function(enemy)
        if self:_eligible(tower, enemy) then
            tower.Candidates[#tower.Candidates + 1] = enemy
        end
    end)
    return tower.Candidates
end

function TowerTargeting:_splashScore(tower, center)
    local cached = tower.SplashScores[center]
    if cached ~= nil then
        return cached
    end
    local count = 0
    local settings = tower.Settings
    self:_visitCells(center.Position, settings.SplashRadius + self.MaximumRadius, function(enemy)
        if enemy.Health > 0 and not enemy.Invulnerable then
            local canHit = settings.HitGround and not enemy.Flying
                or settings.HitFlying and enemy.Flying
            local canSee = not enemy.Hidden or settings.DetectHidden
            local radius = settings.SplashRadius + enemy.Radius
            if canHit and canSee and distanceSquared(center.Position, enemy.Position) <= radius * radius then
                count = count + 1
            end
        end
    end)
    local score = math.min(count, settings.SplashLimit)
    tower.SplashScores[center] = score
    return score
end

function TowerTargeting:_score(tower, enemy)
    local mode = tower.Settings.Mode
    if mode == "First" then
        -- path distance stays comparable across bends (different from waypoint numbers)
        return enemy.Progress
    elseif mode == "Last" then
        return -enemy.Progress
    elseif mode == "Nearest" then
        return -distanceSquared(tower.Origin.Position, enemy.Position)
    elseif mode == "Farthest" then
        return distanceSquared(tower.Origin.Position, enemy.Position)
    elseif mode == "Strongest" then
        return effectiveHealth(enemy)
    elseif mode == "Weakest" then
        return -effectiveHealth(enemy)
    elseif mode == "Fastest" then
        return enemy.Velocity.Magnitude
    elseif mode == "Slowest" then
        return -enemy.Velocity.Magnitude
    elseif mode == "LeastReserved" then
        return -enemy.Reserved / effectiveHealth(enemy)
    elseif mode == "Splash" then
        return self:_splashScore(tower, enemy)
    end
    error("unknown targeting mode " .. tostring(mode))
end

function TowerTargeting:_better(tower, candidate, current)
    if current == nil then
        return true
    end
    local settings = tower.Settings
    if settings.UsePriority and candidate.Priority ~= current.Priority then
        return candidate.Priority > current.Priority
    end
    local candidateScore = self:_score(tower, candidate)
    local currentScore = self:_score(tower, current)
    if candidateScore ~= currentScore then
        return candidateScore > currentScore
    end
    if candidate.Progress ~= current.Progress then
        return candidate.Progress > current.Progress
    end
    -- stop a stationary tower from changing targets every scan
    return candidate.Id < current.Id
end

function TowerTargeting:_select(tower)
    local candidates = self:_collect(tower)
    local focused = self.Enemies[tower.Focus]
    if focused ~= nil and self:_eligible(tower, focused) and self:_visible(tower, focused) then
        return focused.Model
    end
    local current = self.Enemies[tower.Target]
    local currentValid = current ~= nil
        and self:_eligible(tower, current)
        and self:_visible(tower, current)
    if tower.Settings.Sticky and currentValid then
        return current.Model
    end
    local best = nil
    for _, enemy in ipairs(candidates) do
        if self:_better(tower, enemy, best) and self:_visible(tower, enemy) then
            best = enemy
        end
    end
    if best == nil then
        return nil
    end
    if currentValid and best ~= current then
        -- prevent small score changes from causing flicker
        local priorityChanged = tower.Settings.UsePriority and best.Priority > current.Priority
        local improvement = self:_score(tower, best) - self:_score(tower, current)
        if not priorityChanged and improvement < tower.Settings.SwitchMargin then
            return current.Model
        end
    end
    return best.Model
end

function TowerTargeting:_changeTarget(tower, model)
    local previous = tower.Target
    tower.Target = model
    if previous ~= model then
        self.TargetChanged:Fire(tower.Model, model, previous)
    end
end

function TowerTargeting:GetTarget(model)
    return self.Towers[model].Target
end

function TowerTargeting:RefreshTower(model)
    local tower = self.Towers[model]
    if tower.Enabled then
        self:_changeTarget(tower, self:_select(tower))
    end
    tower.NextRefresh = self.Clock + tower.Settings.RefreshInterval
    return tower.Target
end

function TowerTargeting:GetAimPoint(model, enemyModel)
    local tower = self.Towers[model]
    local enemy = self.Enemies[enemyModel]
    local settings = tower.Settings
    local point = enemy.Position + settings.AimOffset
    local time = 0
    if settings.ProjectileSpeed > 0 then
        time = interceptTime(point - tower.Origin.Position, enemy.Velocity,
            settings.ProjectileSpeed, settings.MaximumLeadTime)
    end
    return point + enemy.Velocity * time, time
end

function TowerTargeting:ReserveDamage(model, enemyModel, damage, lifetime)
    -- pending damage stops towers from committing every projectile to one enemy
    local tower = self.Towers[model]
    local enemy = self.Enemies[enemyModel]
    self.NextReservationId = self.NextReservationId + 1
    local token = self.NextReservationId
    self.Reservations[token] = {
        Tower = tower,
        Enemy = enemy,
        Damage = damage,
        Expires = self.Clock + lifetime,
    }
    enemy.Reserved = enemy.Reserved + damage
    return token
end

function TowerTargeting:CancelReservation(token)
    local reservation = self.Reservations[token]
    if reservation ~= nil then
        local enemy = reservation.Enemy
        enemy.Reserved = enemy.Reserved - reservation.Damage
        self.Reservations[token] = nil
    end
end

function TowerTargeting:_expireReservations()
    -- missed projectiles must not reserve health forever
    for token, reservation in pairs(self.Reservations) do
        if reservation.Expires <= self.Clock then
            self:CancelReservation(token)
        end
    end
end

function TowerTargeting:Update(deltaTime)
    self.Clock = self.Clock + deltaTime
    self:_expireReservations()
    self:_refreshEnemies(deltaTime)
    for model, tower in pairs(self.Towers) do
        if tower.Enabled and self.Clock >= tower.NextRefresh then
            self:RefreshTower(model)
        end
    end
end

function TowerTargeting:Start()
    if not self.Running then
        self.Running = true
        self:Update(0)
        self.Connection = RunService.Heartbeat:Connect(function(deltaTime)
            self:Update(deltaTime)
        end)
    end
end

function TowerTargeting:Stop()
    if self.Running then
        self.Connection:Disconnect()
        self.Connection = nil
        self.Running = false
    end
end

function TowerTargeting:Destroy()
    self:Stop()
    self.AddedConnection:Disconnect()
    self.RemovedConnection:Disconnect()
    self.TargetChanged:Destroy()
    table.clear(self.Reservations)
    table.clear(self.Grid)
    table.clear(self.Towers)
    table.clear(self.Enemies)
end

local scene = Instance.new("Folder")
scene.Name = "TargetingDemo"
scene.Parent = workspace

local function folder(name)
    local item = Instance.new("Folder")
    item.Name = name
    item.Parent = scene
    return item
end

local enemies = folder("Enemies")
local blockers = folder("Blockers")
local towers = folder("Towers")
local scenery = folder("Scenery")
local shots = folder("Shots")
local manager = TowerTargeting.new(enemies, blockers, 16)

local function part(parent, name, size, position, color)
    local item = Instance.new("Part")
    item.Name = name
    item.Size = size
    item.Position = position
    item.Color = color
    item.Anchored = true
    item.CanCollide = false
    item.TopSurface = Enum.SurfaceType.Smooth
    item.BottomSurface = Enum.SurfaceType.Smooth
    item.Parent = parent
    return item
end

local function label(parent, text, offset)
    local gui = Instance.new("BillboardGui")
    gui.Name = "Status"
    gui.Size = UDim2.fromOffset(230, 65)
    gui.StudsOffset = Vector3.new(0, offset, 0)
    gui.AlwaysOnTop = true
    gui.MaxDistance = 180
    gui.Parent = parent
    local textLabel = Instance.new("TextLabel")
    textLabel.Size = UDim2.fromScale(1, 1)
    textLabel.BackgroundColor3 = Color3.fromRGB(17, 23, 35)
    textLabel.BackgroundTransparency = 0.2
    textLabel.TextColor3 = Color3.new(1, 1, 1)
    textLabel.Font = Enum.Font.GothamMedium
    textLabel.TextSize = 15
    textLabel.TextWrapped = true
    textLabel.Text = text
    textLabel.Parent = gui
    return textLabel
end

local floor = part(scenery, "Floor", Vector3.new(140, 1, 110),
    Vector3.new(0, -1, 0), Color3.fromRGB(44, 59, 54))
floor.CanCollide = true
local wall = part(blockers, "SightBlocker", Vector3.new(3, 10, 12),
    Vector3.new(3, 4, 10), Color3.fromRGB(75, 82, 103))
wall.CanCollide = true
local spawn = Instance.new("SpawnLocation")
spawn.Name = "DemoSpawn"
spawn.Anchored = true
spawn.Size = Vector3.new(6, 1, 6)
spawn.Position = Vector3.new(0, 0, 30)
spawn.Neutral = true
spawn.Parent = scenery
label(spawn, "Targeting demo\nWalk to a tower and use its prompt", 5)

local points = {
    Vector3.new(-55, 2, -20),
    Vector3.new(-25, 2, -20),
    Vector3.new(-25, 2, 12),
    Vector3.new(25, 2, 12),
    Vector3.new(25, 2, -20),
    Vector3.new(55, 2, -20),
}
local lengths = {}
local totalLength = 0
for index = 1, #points - 1 do
    local a = points[index]
    local b = points[index + 1]
    local length = (b - a).Magnitude
    lengths[index] = length
    totalLength = totalLength + length
    local road = part(scenery, "Path", Vector3.new(6, 0.2, length),
        (a + b) / 2 - Vector3.new(0, 1.9, 0), Color3.fromRGB(142, 125, 95))
    road.CFrame = CFrame.lookAt(road.Position, b - Vector3.new(0, 1.9, 0))
end

local function pathPosition(progress)
    local remaining = progress
    for index, length in ipairs(lengths) do
        if remaining <= length then
            return points[index]:Lerp(points[index + 1], remaining / length)
        end
        remaining = remaining - length
    end
    return points[#points]
end

local modeNames = { "First", "Last", "Nearest", "Farthest", "Strongest",
    "Weakest", "Fastest", "Slowest", "LeastReserved", "Splash" }
local towerStates = {}
for index, position in ipairs({ Vector3.new(-33, 3, 1),
    Vector3.new(0, 3, 22), Vector3.new(33, 3, 1) }) do
    local model = Instance.new("Model")
    model.Name = "Tower" .. tostring(index)
    local root = part(model, "Turret", Vector3.new(4, 6, 4), position,
        Color3.fromHSV(index / 4, 0.6, 0.9))
    model.PrimaryPart = root
    model.Parent = towers
    local attachment = Instance.new("Attachment")
    attachment.Position = Vector3.new(0, 3, 0)
    attachment.Parent = root
    local beam = Instance.new("Beam")
    beam.Name = "TargetIndicator"
    beam.Attachment0 = attachment
    beam.Width0 = 0.12
    beam.Width1 = 0.12
    beam.FaceCamera = true
    beam.Color = ColorSequence.new(root.Color)
    beam.Enabled = false
    beam.Parent = root
    local status = label(root, "", 7)
    local prompt = Instance.new("ProximityPrompt")
    prompt.ActionText = "Change targeting mode"
    prompt.ObjectText = model.Name
    prompt.HoldDuration = 0
    prompt.MaxActivationDistance = 15
    prompt.RequiresLineOfSight = false
    prompt.Parent = root
    local state = { Model = model, Root = root, Beam = beam, Status = status,
        ModeIndex = index, NextShot = 0, Damage = 12 }
    towerStates[model] = state
    manager:AddTower(model, root, { Mode = modeNames[index], Range = 32,
        DetectHidden = index == 2, HitFlying = true, ProjectileSpeed = 50,
        RequireLineOfSight = index == 2, SplashRadius = 9, SplashLimit = 6 })
    prompt.Triggered:Connect(function()
        state.ModeIndex = state.ModeIndex % #modeNames + 1
        manager:SetMode(model, modeNames[state.ModeIndex])
    end)
end

manager.TargetChanged.Event:Connect(function(model, target)
    local beam = towerStates[model].Beam
    beam.Enabled = target ~= nil
    beam.Attachment1 = target and target.PrimaryPart.TargetAttachment or nil
end)

local activeEnemies = {}
local activeShots = {}
local spawnClock = 0
local nextEnemy = 0
local escaped = 0
local defeated = 0

local function spawnEnemy()
    nextEnemy = nextEnemy + 1
    local model = Instance.new("Model")
    model.Name = "Enemy" .. tostring(nextEnemy)
    local hidden = nextEnemy % 5 == 0
    local flying = nextEnemy % 4 == 0
    local health = 30 + nextEnemy % 4 * 20
    local root = part(model, "Root", Vector3.new(3, 3, 3), points[1] + Vector3.new(0, flying and 7 or 0, 0),
        hidden and Color3.fromRGB(170, 100, 230) or Color3.fromRGB(235, 100, 90))
    root.Transparency = hidden and 0.45 or 0
    model.PrimaryPart = root
    local attachment = Instance.new("Attachment")
    attachment.Name = "TargetAttachment"
    attachment.Parent = root
    model:SetAttribute("Health", health)
    model:SetAttribute("Shield", nextEnemy % 3 == 0 and 20 or 0)
    model:SetAttribute("Progress", 0)
    model:SetAttribute("TargetPriority", 0)
    model:SetAttribute("TargetRadius", 1.5)
    model:SetAttribute("Flying", flying)
    model:SetAttribute("Hidden", hidden)
    model:SetAttribute("Invulnerable", false)
    local status = label(root, "", 3)
    activeEnemies[model] = { Progress = 0, Speed = 7 + nextEnemy % 5,
        Height = flying and 7 or 0, Status = status }
    -- prevent registration before the required data exists
    model.Parent = enemies
end

local function applyDamage(model, amount)
    local shield = model:GetAttribute("Shield")
    local absorbed = math.min(shield, amount)
    model:SetAttribute("Shield", shield - absorbed)
    model:SetAttribute("Health", math.max(0, model:GetAttribute("Health") - amount + absorbed))
end

local function fireShot(state, target)
    local destination, leadTime = manager:GetAimPoint(state.Model, target)
    local origin = state.Root.Position
    local duration = math.max(leadTime, (destination - origin).Magnitude / 50, 0.02)
    local token = manager:ReserveDamage(state.Model, target, state.Damage, duration + 0.2)
    local visual = part(shots, "Projectile", Vector3.new(0.6, 0.6, 0.6), origin, state.Root.Color)
    visual.Material = Enum.Material.Neon
    visual.Shape = Enum.PartType.Ball
    activeShots[#activeShots + 1] = { Visual = visual, Origin = origin,
        Destination = destination, Duration = duration, Elapsed = 0,
        Token = token, Target = target, Tower = state.Model, Damage = state.Damage,
        Splash = modeNames[state.ModeIndex] == "Splash" }
end

RunService.Heartbeat:Connect(function(deltaTime)
    spawnClock = spawnClock + deltaTime
    if spawnClock >= 1.3 then
        spawnClock = spawnClock % 1.3
        spawnEnemy()
    end
    for model, state in pairs(activeEnemies) do
        state.Progress = state.Progress + state.Speed * deltaTime
        model:SetAttribute("Progress", state.Progress)
        model:PivotTo(CFrame.new(pathPosition(state.Progress) + Vector3.new(0, state.Height, 0)))
        state.Status.Text = model.Name .. "  hp " .. tostring(model:GetAttribute("Health"))
            .. "  shield " .. tostring(model:GetAttribute("Shield"))
        if model:GetAttribute("Health") <= 0 or state.Progress >= totalLength then
            if model:GetAttribute("Health") <= 0 then
                defeated = defeated + 1
            else
                escaped = escaped + 1
            end
            activeEnemies[model] = nil
            model:Destroy()
        end
    end
    manager:Update(deltaTime)
    for index = #activeShots, 1, -1 do
        local shot = activeShots[index]
        shot.Elapsed = shot.Elapsed + deltaTime
        shot.Visual.Position = shot.Origin:Lerp(shot.Destination, math.min(1, shot.Elapsed / shot.Duration))
        if shot.Elapsed >= shot.Duration then
            manager:CancelReservation(shot.Token)
            if activeEnemies[shot.Target] ~= nil then
                if (shot.Target.PrimaryPart.Position - shot.Destination).Magnitude <= 3 then
                    -- a path turn can make a constant velocity prediction miss, fix
                    if shot.Splash then
                        local tower = manager.Towers[shot.Tower]
                        local radius = tower.Settings.SplashRadius
                        manager:_visitCells(shot.Destination, radius + manager.MaximumRadius, function(enemy)
                            local reach = radius + enemy.Radius
                            if enemy.Health > 0 and not enemy.Invulnerable
                                and (not enemy.Hidden or tower.Settings.DetectHidden)
                                and distanceSquared(enemy.Position, shot.Destination) <= reach * reach then
                                applyDamage(enemy.Model, shot.Damage)
                            end
                        end)
                    else
                        applyDamage(shot.Target, shot.Damage)
                    end
                end
            end
            shot.Visual:Destroy()
            table.remove(activeShots, index)
        end
    end
    for model, state in pairs(towerStates) do
        local target = manager:GetTarget(model)
        state.Status.Text = modeNames[state.ModeIndex] .. "  |  " .. (target and target.Name or "no target")
            .. "\ndefeated " .. tostring(defeated) .. "  escaped " .. tostring(escaped)
        if target ~= nil and manager.Clock >= state.NextShot then
            fireShot(state, target)
            state.NextShot = manager.Clock + 0.8
        end
    end
end)
