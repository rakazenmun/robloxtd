-- discord replace_me roblox replace_me

local RunService = game:GetService("RunService") -- heartbeat keeps movement and target updates on the server simulation clock

local TowerTargeting = {} -- one method table lets managers share behavior without sharing enemy state
TowerTargeting.__index = TowerTargeting -- missing instance fields resolve to these methods through the metatable

TowerTargeting.Modes = table.freeze({ -- freezing avoids accidental changes to the public mode names
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

local DEFAULTS = table.freeze({ -- defaults stay shared and immutable while each tower receives a separate copy
    Mode = "First", -- progress makes the default tower defend against enemies closest to escaping
    Range = 25, -- a bounded search prevents selecting enemies across the whole map
    MinimumRange = 0, -- zero removes the inner exclusion zone for ordinary towers
    MinimumHeight = -math.huge, -- an unbounded lower limit allows targeting below elevated towers
    MaximumHeight = math.huge, -- an unbounded upper limit keeps flying eligibility separate from height limits
    ArcDegrees = 360, -- full coverage avoids making turret facing affect the default selection
    DetectHidden = false, -- hidden enemies need an explicit detection capability
    HitGround = true, -- ordinary towers should accept enemies using the ground path
    HitFlying = false, -- flying enemies need a separate attack capability
    RequireLineOfSight = false, -- raycasts are optional because some tower attacks pass through cover
    UsePriority = true, -- special enemy priorities can override the chosen scoring mode
    AvoidOverkill = true, -- expected projectile damage should influence later targeting decisions
    Sticky = false, -- rescoring allows newly urgent enemies to replace the current target
    SwitchMargin = 0, -- zero permits any positive improvement instead of adding hysteresis by default
    RefreshInterval = 0.1, -- selection runs less often than movement to reduce repeated searches
    ProjectileSpeed = 0, -- zero selects direct aiming when a tower does not use projectile prediction
    MaximumLeadTime = 3, -- long predictions become unreliable when enemies can change path direction
    AimOffset = Vector3.new(0, 0, 0), -- a world space offset lets the aim point differ from the root center
    SplashRadius = 8, -- cluster scoring needs the same area size as the eventual attack
    SplashLimit = 10, -- cluster scoring stops rewarding enemies beyond the attack hit limit
})

local function cellKey(x, z)
    return tostring(x) .. ":" .. tostring(z) -- a separator prevents different cell coordinate pairs from sharing a key
end

local function distanceSquared(a, b)
    local delta = a - b -- relative displacement makes the distance independent of world origin
    return delta:Dot(delta) -- the self dot product avoids a square root when only comparing distances
end

local function makeSettings(overrides)
    local settings = table.clone(DEFAULTS) -- each tower can change settings without mutating other towers
    for name, value in pairs(overrides or {}) do -- optional overrides replace individual defaults without needing every setting
        settings[name] = value -- copying supplied values preserves defaults for all omitted settings
    end
    return settings
end

local function effectiveHealth(enemy)
    return enemy.Health + enemy.Shield -- shield absorbs damage too so health alone understates the remaining durability
end

local function interceptTime(offset, velocity, speed, maximum)
    local a = velocity:Dot(velocity) - speed * speed -- equating squared travel distances produces this quadratic coefficient
    local b = 2 * offset:Dot(velocity) -- relative motion along the starting displacement affects interception time
    local c = offset:Dot(offset) -- the initial squared separation is the constant term in the intercept equation
    if c == 0 then -- an overlapping aim point needs no travel prediction
        return 0
    end
    -- the linear case avoids dividing by a near zero quadratic term
    if math.abs(a) < 0.000001 then -- nearly equal speeds require solving the linear form instead
        if b < 0 then -- the linear form has a future solution only when relative separation is closing
            return math.min(-c / b, maximum) -- the linear solution still respects the prediction horizon
        end
        return 0
    end
    local discriminant = b * b - 4 * a * c -- its sign determines whether real interception times exist
    if discriminant < 0 then -- no real intersection means constant velocity prediction cannot produce a hit
        return 0
    end
    local root = math.sqrt(discriminant) -- both quadratic roots need the same square root so it is calculated once
    local first = (-b - root) / (2 * a) -- one possible intersection may occur before the other
    local second = (-b + root) / (2 * a) -- the other root must also be considered because the first can be negative
    local time = math.huge -- infinity allows the earliest future solution to replace the initial value
    if first >= 0 then -- past intersections cannot guide a projectile fired now
        time = first
    end
    if second >= 0 then -- the second solution is usable only when it lies in the future
        time = math.min(time, second) -- choosing the earliest solution avoids unnecessary projectile travel
    end
    if time == math.huge then -- both roots can exist while neither represents a future interception
        return 0
    end
    return math.min(time, maximum) -- capping time limits how far a stale velocity estimate can lead the shot
end

function TowerTargeting.new(enemyFolder, blockerFolder, cellSize)
    local self = setmetatable({}, TowerTargeting) -- the instance owns state while method lookup uses the shared class table
    self.EnemyFolder = enemyFolder -- the folder defines the population owned by this manager
    self.BlockerFolder = blockerFolder -- cover belongs to a separate hierarchy from attackable enemies
    self.CellSize = cellSize or 16 -- cell width trades bucket density against the number of visited cells
    self.Enemies = {} -- model keys let removal events find records without scanning an array
    self.Towers = {} -- model keys keep tower configuration and selection state together
    self.Grid = {} -- spatial buckets reduce candidate work for towers with limited range
    self.Reservations = {} -- pending shots need independent tokens so hits and misses release their own damage
    self.Clock = 0 -- one simulation clock keeps refresh deadlines and reservation expiry consistent
    self.NextEnemyId = 0 -- registration order supplies a deterministic final tie breaker
    self.NextTowerId = 0 -- tower records receive a stable identity for inspection
    self.NextReservationId = 0 -- monotonic tokens prevent an old projectile from cancelling a newer reservation
    self.MaximumRadius = 0 -- broad phase searches must include the largest active enemy radius
    self.Running = false -- manual updates and an optional heartbeat subscription use the same manager
    self.Connection = nil -- the optional heartbeat subscription must be retained for later disconnection
    self.TargetChanged = Instance.new("BindableEvent") -- server listeners can update indicators without coupling them to selection logic
    self.RaycastParameters = RaycastParams.new() -- one reusable filter avoids allocating new raycast settings for every candidate
    self.RaycastParameters.FilterType = Enum.RaycastFilterType.Include -- only descendants of the blocker folder should obstruct tower visibility
    self.RaycastParameters.FilterDescendantsInstances = { blockerFolder } -- the explicit cover hierarchy excludes towers and enemies from obstruction tests
    self.RaycastParameters.IgnoreWater = true -- terrain water should not count as solid cover for this demo
    self.AddedConnection = enemyFolder.ChildAdded:Connect(function(model) -- newly spawned enemies enter the index through one lifecycle subscription
        self:_registerEnemy(model)
    end)
    self.RemovedConnection = enemyFolder.ChildRemoved:Connect(function(model) -- despawned enemies must release targets and pending reservations
        self:_unregisterEnemy(model)
    end)
    for _, model in ipairs(enemyFolder:GetChildren()) do -- existing enemies need registration even when they predate the manager
        self:_registerEnemy(model)
    end
    return self
end

function TowerTargeting:_registerEnemy(model)
    self.NextEnemyId = self.NextEnemyId + 1 -- ids are never reused so tied candidates retain registration order
    local root = model.PrimaryPart -- one explicitly assigned root gives movement and prediction the same reference point
    self.Enemies[model] = { -- registration captures the fields required by range tests and scoring
        Model = model, -- keeping the model reference lets records return the original roblox instance
        Root = root, -- caching the primary part avoids repeated descendant searches during updates
        Id = self.NextEnemyId, -- stable ids make equal scores independent of table iteration order
        Position = root.Position, -- the initial position is needed before velocity can be measured
        Velocity = Vector3.new(0, 0, 0), -- new enemies have no displacement sample until the next simulation update
        Health = model:GetAttribute("Health"), -- the demo uses explicit attributes so targeting does not depend on a humanoid
        Shield = model:GetAttribute("Shield"), -- durability scoring includes damage that shield will absorb first
        Progress = model:GetAttribute("Progress"), -- distance along the path lets first and last work across different segments
        Priority = model:GetAttribute("TargetPriority"), -- special priority remains separate from normal scoring modes
        Radius = model:GetAttribute("TargetRadius"), -- range checks treat the enemy as a sphere around its root
        Flying = model:GetAttribute("Flying"), -- a capability flag separates flying eligibility from visual height
        Hidden = model:GetAttribute("Hidden"), -- detection checks use explicit state instead of inferring it from transparency
        Invulnerable = model:GetAttribute("Invulnerable"), -- unattackable enemies should not consume a tower target slot
        Reserved = 0, -- only projectiles created after registration can reserve this enemy durability
    }
end

function TowerTargeting:_unregisterEnemy(model)
    local enemy = self.Enemies[model] -- model identity retrieves the same record referenced by reservations
    self.Enemies[model] = nil -- removed models must stop participating in later target lookups
    for token, reservation in pairs(self.Reservations) do
        if reservation.Enemy == enemy then -- reservations for other enemies must survive this despawn
            self.Reservations[token] = nil -- the completed token must no longer participate in expiry or cancellation
        end
    end
    for _, tower in pairs(self.Towers) do
        if tower.Focus == model then -- manual focus cannot outlive its enemy model
            tower.Focus = nil
        end
        if tower.Target == model then -- only towers using this enemy need a target change event
            self:_changeTarget(tower, nil) -- clearing through the shared method also notifies visual listeners
        end
    end
end

function TowerTargeting:AddTower(model, origin, overrides)
    self.NextTowerId = self.NextTowerId + 1 -- tower identity stays stable even when other towers are removed
    local tower = {
        Model = model, -- keeping the model reference lets records return the original roblox instance
        Origin = origin, -- range and aim calculations share a caller supplied basepart reference
        Id = self.NextTowerId,
        Settings = makeSettings(overrides), -- isolated settings let each tower expose different capabilities
        Target = nil,
        Focus = nil,
        Enabled = true,
        NextRefresh = self.Clock, -- a new tower should participate in the next selection update
        Candidates = {}, -- reusing per tower storage avoids allocating a candidate array every scan
        Visible = {}, -- line of sight can be reused while comparing candidates within one scan
        SplashScores = {}, -- cluster counts can be reused when candidates are compared repeatedly
    }
    self.Towers[model] = tower -- model lookup connects external tower instances to manager state
    return tower
end

function TowerTargeting:RemoveTower(model)
    local tower = self.Towers[model] -- the caller uses roblox model identity rather than internal record references
    self:_changeTarget(tower, nil) -- clearing through the shared method also notifies visual listeners
    for token, reservation in pairs(self.Reservations) do
        if reservation.Tower == tower then -- removing one tower should release only the shots attributed to it
            self:CancelReservation(token) -- all releases go through one subtraction path to keep pending damage consistent
        end
    end
    self.Towers[model] = nil -- later updates must no longer select targets for the removed tower
end

function TowerTargeting:ConfigureTower(model, changes)
    local tower = self.Towers[model] -- the caller uses roblox model identity rather than internal record references
    for name, value in pairs(changes) do -- partial updates retain tower settings that were not supplied
        tower.Settings[name] = value -- settings are copied into the existing record so target state remains intact
    end
    tower.NextRefresh = self.Clock -- a setting change should take effect on the next update without waiting
end

function TowerTargeting:SetMode(model, mode)
    self:ConfigureTower(model, { Mode = mode }) -- mode changes reuse the same invalidation path as other configuration changes
end

function TowerTargeting:SetFocus(model, enemyModel)
    local tower = self.Towers[model] -- the caller uses roblox model identity rather than internal record references
    tower.Focus = enemyModel -- a preferred model is still checked for eligibility before it can be selected
    tower.NextRefresh = self.Clock -- a setting change should take effect on the next update without waiting
end

function TowerTargeting:SetEnabled(model, enabled)
    local tower = self.Towers[model] -- the caller uses roblox model identity rather than internal record references
    tower.Enabled = enabled -- disabling selection does not require deleting the tower record
    tower.NextRefresh = self.Clock -- a setting change should take effect on the next update without waiting
    if not enabled then -- a disabled tower must stop advertising its previous target immediately
        self:_changeTarget(tower, nil) -- clearing through the shared method also notifies visual listeners
    end
end

function TowerTargeting:_refreshEnemies(deltaTime)
    -- one shared snapshot avoids reading every attribute once per tower
    table.clear(self.Grid) -- positions changed since the last frame so old cell membership is no longer valid
    self.MaximumRadius = 0 -- broad phase searches must include the largest active enemy radius
    for _, enemy in pairs(self.Enemies) do
        local model = enemy.Model
        local position = enemy.Root.Position -- all towers use this frame position rather than taking different samples
        if deltaTime > 0 then -- an initial zero time update cannot supply a velocity denominator
            -- pivot moved enemies do not report useful assembly velocity
            enemy.Velocity = (position - enemy.Position) / deltaTime -- displacement over elapsed seconds also measures anchored enemies moved with pivotto
        end
        enemy.Position = position -- the current sample becomes the previous position for the next frame
        enemy.Health = model:GetAttribute("Health") -- combat may have changed health since the previous snapshot
        enemy.Shield = model:GetAttribute("Shield") -- shield loss must affect both strongest scoring and overkill avoidance
        enemy.Progress = model:GetAttribute("Progress") -- path movement owns progress and targeting reads that shared value
        enemy.Priority = model:GetAttribute("TargetPriority") -- priority changes should affect selection without requiring registration again
        enemy.Radius = model:GetAttribute("TargetRadius") -- size changes must update range checks and broad phase expansion
        enemy.Flying = model:GetAttribute("Flying") -- an enemy can change movement class during its lifetime
        enemy.Hidden = model:GetAttribute("Hidden") -- revealing or hiding an enemy should affect the next selection scan
        enemy.Invulnerable = model:GetAttribute("Invulnerable") -- temporary immunity needs to be reflected before candidates are collected
        if enemy.Health > 0 then -- dead enemies should not occupy spatial buckets used by splash or targeting
            local x = math.floor(position.X / self.CellSize) -- floor maps positions on both sides of zero into consistent horizontal cells
            local z = math.floor(position.Z / self.CellSize) -- the grid ignores height because precise vertical checks happen afterward
            local key = cellKey(x, z) -- a coordinate pair becomes the lookup key for its spatial bucket
            local bucket = self.Grid[key] -- enemies in the same horizontal cell share one candidate list
            if bucket == nil then -- an unoccupied cell has no list until its first live enemy arrives
                bucket = {}
                self.Grid[key] = bucket -- subsequent enemies in this cell append to the same bucket
            end
            bucket[#bucket + 1] = enemy -- one insertion per enemy prevents duplicate visits through adjacent cells
            self.MaximumRadius = math.max(self.MaximumRadius, enemy.Radius) -- the search expansion must account for the largest live spherical target
        end
    end
end

function TowerTargeting:_visitCells(position, radius, visitor)
    -- floor keeps negative world positions in the correct grid cells
    local minimumX = math.floor((position.X - radius) / self.CellSize) -- the left edge determines the first horizontal cell that could intersect the search
    local maximumX = math.floor((position.X + radius) / self.CellSize) -- the right edge includes boundary cells before precise distance filtering
    local minimumZ = math.floor((position.Z - radius) / self.CellSize) -- the near edge bounds cell visits on the second horizontal axis
    local maximumZ = math.floor((position.Z + radius) / self.CellSize) -- the far edge completes the rectangular broad phase search
    for x = minimumX, maximumX do
        for z = minimumZ, maximumZ do
            local bucket = self.Grid[cellKey(x, z)] -- empty world regions cost a lookup instead of a full enemy scan
            if bucket ~= nil then
                for _, enemy in ipairs(bucket) do
                    visitor(enemy) -- the same cell traversal supports targeting and area damage without duplicating grid logic
                end
            end
        end
    end
end

function TowerTargeting:_insideRange(tower, enemy)
    local settings = tower.Settings
    local offset = enemy.Position - tower.Origin.Position -- range and height checks need displacement relative to this tower
    -- center only checks would make large enemies enter range too late
    local range = settings.Range + enemy.Radius
    local minimum = settings.MinimumRange + enemy.Radius -- an inner dead zone requires the enemy sphere to clear its boundary
    local squared = offset:Dot(offset) -- squared comparisons avoid a square root for every candidate
    if squared > range * range then -- sphere overlap determines whether any part of the enemy reaches the outer range
        return false
    end
    if settings.MinimumRange > 0 and squared < minimum * minimum then -- zero disables the inner dead zone while positive values exclude overlapping spheres
        return false
    end
    if offset.Y < settings.MinimumHeight then -- relative height limits remain meaningful when towers are placed above ground
        return false
    end
    if offset.Y > settings.MaximumHeight then -- a separate upper bound can restrict how far above the tower enemies may be
        return false
    end
    if settings.ArcDegrees < 360 then -- full circle towers do not need cone calculations
        local horizontal = Vector3.new(offset.X, 0, offset.Z) -- the firing arc measures horizontal heading independently of enemy elevation
        local forward = tower.Origin.CFrame.LookVector -- the tower part orientation defines the center of the firing cone
        local flatForward = Vector3.new(forward.X, 0, forward.Z) -- projecting forward onto the ground plane removes turret pitch from arc tests
        if horizontal.Magnitude > 0 and flatForward.Magnitude > 0 then -- zero projections do not define a horizontal direction that can be normalized
            local dot = horizontal.Unit:Dot(flatForward.Unit) -- normalized directions make the dot product equal to the heading angle cosine
            local cutoff = math.cos(math.rad(settings.ArcDegrees / 2)) -- the cone boundary uses half the full arc converted from degrees to radians
            if dot < cutoff then -- a smaller cosine places the enemy outside the allowed heading angle
                return false
            end
        end
    end
    return true
end

function TowerTargeting:_eligible(tower, enemy)
    local settings = tower.Settings
    if enemy.Health <= 0 or enemy.Invulnerable then -- dead or immune enemies cannot receive an effective attack
        return false
    end
    if enemy.Hidden and not settings.DetectHidden then -- hidden eligibility belongs to the tower detection capability
        return false
    end
    if enemy.Flying and not settings.HitFlying then -- height alone cannot decide whether a tower can damage flying enemies
        return false
    end
    if not enemy.Flying and not settings.HitGround then -- an air only tower must reject ordinary path enemies
        return false
    end
    if settings.AvoidOverkill and enemy.Reserved >= effectiveHealth(enemy) then -- fully committed durability should send later shots toward another enemy
        return false
    end
    return self:_insideRange(tower, enemy) -- geometric checks run after cheap state and capability rejections
end

function TowerTargeting:_visible(tower, enemy)
    if not tower.Settings.RequireLineOfSight then -- attacks that ignore cover do not need a raycast
        return true
    end
    local cached = tower.Visible[enemy] -- visibility is shared across comparisons within the current scan
    if cached ~= nil then
        return cached
    end
    local origin = tower.Origin.Position
    local destination = enemy.Position + tower.Settings.AimOffset -- cover checks should use the same world space aim offset as the projectile
    local direction = destination - origin -- roblox raycast direction carries both the heading and the cast length
    local visible = true
    if direction.Magnitude > 0 then -- overlapping aim points do not define a nonzero ray
        local hit = workspace:Raycast(origin, direction, self.RaycastParameters) -- the include filter makes only designated cover block the segment to the aim point
        visible = hit == nil -- no blocker intersection means the segment to the aim point is unobstructed
    end
    -- an include filter keeps other enemies from hiding a valid target
    tower.Visible[enemy] = visible -- repeated comparisons should not raycast the same enemy twice in one scan
    return visible
end

function TowerTargeting:_collect(tower)
    -- visibility must not survive a scan because towers and enemies can move
    table.clear(tower.Candidates) -- candidate records from the previous scan may no longer be in range
    table.clear(tower.Visible) -- cached rays become invalid after movement or cover changes
    table.clear(tower.SplashScores) -- cluster density can change even when the chosen center enemy stays still
    local radius = tower.Settings.Range + self.MaximumRadius -- large enemies can intersect tower range while their centers lie beyond it
    self:_visitCells(tower.Origin.Position, radius, function(enemy) -- the broad phase limits precise eligibility tests to nearby buckets
        if self:_eligible(tower, enemy) then -- only attackable enemies should be scored or used as focused candidates
            tower.Candidates[#tower.Candidates + 1] = enemy -- the narrow phase result becomes the scan list used by all selection modes
        end
    end)
    return tower.Candidates
end

function TowerTargeting:_splashScore(tower, center)
    local cached = tower.SplashScores[center] -- a comparison may request the same cluster score more than once
    if cached ~= nil then
        return cached
    end
    local count = 0
    local settings = tower.Settings
    self:_visitCells(center.Position, settings.SplashRadius + self.MaximumRadius, function(enemy) -- cluster scoring must include large enemies overlapping the area boundary
        if enemy.Health > 0 and not enemy.Invulnerable then
            local canHit = settings.HitGround and not enemy.Flying -- area damage counts only movement classes the tower can attack
                or settings.HitFlying and enemy.Flying -- flying eligibility is an alternative to ground eligibility
            local canSee = not enemy.Hidden or settings.DetectHidden -- area scoring should not reward hidden enemies this tower cannot affect
            local radius = settings.SplashRadius + enemy.Radius -- sphere overlap is used for both splash scoring and eventual area damage
            if canHit and canSee and distanceSquared(center.Position, enemy.Position) <= radius * radius then
                count = count + 1
            end
        end
    end)
    local score = math.min(count, settings.SplashLimit) -- additional enemies cannot improve an attack beyond its maximum hit count
    tower.SplashScores[center] = score -- memoizing the result avoids rescanning the cluster during tie comparisons
    return score
end

function TowerTargeting:_score(tower, enemy)
    local mode = tower.Settings.Mode
    if mode == "First" then
        -- path distance stays comparable across bends unlike waypoint numbers
        return enemy.Progress -- greater path distance means an enemy is closer to reaching the exit
    elseif mode == "Last" then
        return -enemy.Progress -- negation lets the same greater score comparison prefer lower progress
    elseif mode == "Nearest" then
        return -distanceSquared(tower.Origin.Position, enemy.Position) -- negation lets nearby enemies win without changing the comparison direction
    elseif mode == "Farthest" then
        return distanceSquared(tower.Origin.Position, enemy.Position) -- larger squared distance favors the far edge of tower range
    elseif mode == "Strongest" then
        return effectiveHealth(enemy) -- shield and health together determine the durability ranked by strongest
    elseif mode == "Weakest" then
        return -effectiveHealth(enemy) -- negation makes lower remaining durability produce the larger score
    elseif mode == "Fastest" then
        return enemy.Velocity.Magnitude -- measured world speed lets faster moving enemies win
    elseif mode == "Slowest" then
        return -enemy.Velocity.Magnitude -- negative measured speed makes slower enemies rank higher
    elseif mode == "LeastReserved" then
        return -enemy.Reserved / effectiveHealth(enemy) -- normalizing committed damage by durability compares commitment across enemy sizes
    elseif mode == "Splash" then
        return self:_splashScore(tower, enemy) -- the best cluster center should maximize the number of eligible area hits
    end
    error("unknown targeting mode " .. tostring(mode)) -- an unsupported mode should be visible as a configuration error
end

function TowerTargeting:_better(tower, candidate, current)
    if current == nil then -- the first valid candidate establishes a comparison baseline
        return true
    end
    local settings = tower.Settings
    if settings.UsePriority and candidate.Priority ~= current.Priority then -- explicit priority takes precedence over ordinary mode scoring
        return candidate.Priority > current.Priority -- priority direction stays consistent across all scoring modes
    end
    local candidateScore = self:_score(tower, candidate) -- mode dependent scores share the same greater is better convention
    local currentScore = self:_score(tower, current) -- both candidates must be evaluated using this tower mode
    if candidateScore ~= currentScore then
        return candidateScore > currentScore -- one comparison rule handles modes that originally minimize or maximize values
    end
    if candidate.Progress ~= current.Progress then
        return candidate.Progress > current.Progress -- progress breaks score ties in favor of the more urgent enemy
    end
    -- stable ties stop a stationary tower from changing targets every scan
    return candidate.Id < current.Id -- registration order resolves the final tie without relying on hash iteration order
end

function TowerTargeting:_select(tower)
    local candidates = self:_collect(tower) -- each selection uses a fresh geometric and capability filter
    local focused = self.Enemies[tower.Focus] -- a requested focus must still refer to an enemy owned by this manager
    if focused ~= nil and self:_eligible(tower, focused) and self:_visible(tower, focused) then -- focus overrides ranking but does not bypass attack restrictions
        return focused.Model
    end
    local current = self.Enemies[tower.Target] -- the previous target record is needed for stickiness and switch hysteresis
    local currentValid = current ~= nil
        and self:_eligible(tower, current) -- keeping a target cannot bypass changed health or capabilities
        and self:_visible(tower, current) -- a target hidden behind new cover should not be retained
    if tower.Settings.Sticky and currentValid then -- sticky towers keep an attackable target even when another score improves
        return current.Model
    end
    local best = nil
    for _, enemy in ipairs(candidates) do
        if self:_better(tower, enemy, best) and self:_visible(tower, enemy) then -- expensive visibility checks are needed only for candidates that could win
            best = enemy -- the running winner avoids sorting every candidate for a single target
        end
    end
    if best == nil then -- an empty or fully obstructed candidate set has no attackable winner
        return nil
    end
    if currentValid and best ~= current then
        -- a switch margin prevents small score changes from causing flicker
        local priorityChanged = tower.Settings.UsePriority and best.Priority > current.Priority -- higher explicit priority must bypass ordinary switch margins
        local improvement = self:_score(tower, best) - self:_score(tower, current) -- switch hysteresis compares scores in the units used by the active mode
        if not priorityChanged and improvement < tower.Settings.SwitchMargin then -- small score gains should retain the current target when hysteresis is enabled
            return current.Model
        end
    end
    return best.Model
end

function TowerTargeting:_changeTarget(tower, model)
    local previous = tower.Target -- listeners need the old model to distinguish acquisition from replacement
    tower.Target = model
    if previous ~= model then -- unchanged targets should not trigger repeated visual work
        self.TargetChanged:Fire(tower.Model, model, previous) -- one server event decouples target indicators from ranking internals
    end
end

function TowerTargeting:GetTarget(model)
    return self.Towers[model].Target -- combat reads the selected model without owning or modifying the targeting record
end

function TowerTargeting:RefreshTower(model)
    local tower = self.Towers[model] -- the caller uses roblox model identity rather than internal record references
    if tower.Enabled then
        self:_changeTarget(tower, self:_select(tower)) -- selection and notification remain separate so target changes use one event path
    end
    tower.NextRefresh = self.Clock + tower.Settings.RefreshInterval -- a fresh deadline avoids catch up scan bursts after a long frame
    return tower.Target
end

function TowerTargeting:GetAimPoint(model, enemyModel)
    local tower = self.Towers[model] -- the caller uses roblox model identity rather than internal record references
    local enemy = self.Enemies[enemyModel]
    local settings = tower.Settings
    local point = enemy.Position + settings.AimOffset -- prediction starts at the same aim point used by line of sight
    local time = 0
    if settings.ProjectileSpeed > 0 then -- only attacks with a positive projectile speed need a travel time solution
        time = interceptTime(point - tower.Origin.Position, enemy.Velocity, -- the solver uses displacement relative to the muzzle rather than world coordinates
            settings.ProjectileSpeed, settings.MaximumLeadTime)
    end
    return point + enemy.Velocity * time, time -- the predicted point and travel estimate let combat schedule the same shot
end

function TowerTargeting:ReserveDamage(model, enemyModel, damage, lifetime)
    -- pending damage stops towers from committing every projectile to one enemy
    local tower = self.Towers[model] -- the caller uses roblox model identity rather than internal record references
    local enemy = self.Enemies[enemyModel]
    self.NextReservationId = self.NextReservationId + 1 -- each shot needs an independent cancellation token
    local token = self.NextReservationId
    self.Reservations[token] = {
        Tower = tower,
        Enemy = enemy,
        Damage = damage,
        Expires = self.Clock + lifetime, -- simulation time expiry releases shots that never report completion
    }
    enemy.Reserved = enemy.Reserved + damage -- later tower scans can account for damage already committed in flight
    return token
end

function TowerTargeting:CancelReservation(token)
    local reservation = self.Reservations[token] -- the token ties a release to the exact enemy and damage amount originally reserved
    if reservation ~= nil then -- a projectile can finish after expiry has already consumed its token
        local enemy = reservation.Enemy
        enemy.Reserved = enemy.Reserved - reservation.Damage -- only this shot contribution is removed from the shared pending damage total
        self.Reservations[token] = nil -- the completed token must no longer participate in expiry or cancellation
    end
end

function TowerTargeting:_expireReservations()
    -- missed projectiles must not reserve health forever
    for token, reservation in pairs(self.Reservations) do
        if reservation.Expires <= self.Clock then -- expired shots must stop influencing overkill decisions
            self:CancelReservation(token) -- all releases go through one subtraction path to keep pending damage consistent
        end
    end
end

function TowerTargeting:Update(deltaTime)
    self.Clock = self.Clock + deltaTime -- all deadlines advance using elapsed simulation time instead of wall clock calls
    self:_expireReservations() -- expired commitments must be removed before new targets are selected
    self:_refreshEnemies(deltaTime) -- one current snapshot and grid rebuild precede all tower scans
    for model, tower in pairs(self.Towers) do
        if tower.Enabled and self.Clock >= tower.NextRefresh then -- disabled towers and towers between deadlines need no candidate search
            self:RefreshTower(model)
        end
    end
end

function TowerTargeting:Start()
    if not self.Running then
        self.Running = true
        self:Update(0) -- the initial snapshot builds the grid before the first timed heartbeat update
        self.Connection = RunService.Heartbeat:Connect(function(deltaTime) -- the optional runner advances the same update method used by manual simulations
            self:Update(deltaTime)
        end)
    end
end

function TowerTargeting:Stop()
    if self.Running then
        self.Connection:Disconnect() -- stopping must release the subscription that owns future manager updates
        self.Connection = nil -- the optional heartbeat subscription must be retained for later disconnection
        self.Running = false -- manual updates and an optional heartbeat subscription use the same manager
    end
end

function TowerTargeting:Destroy()
    self:Stop()
    self.AddedConnection:Disconnect() -- destroyed managers must stop reacting to future enemy spawns
    self.RemovedConnection:Disconnect() -- destroyed managers must stop reacting to future enemy removals
    self.TargetChanged:Destroy() -- the manager owns this event so its listeners should not outlive it
    table.clear(self.Reservations) -- pending shots must release enemy references when the manager is destroyed
    table.clear(self.Grid) -- positions changed since the last frame so old cell membership is no longer valid
    table.clear(self.Towers) -- destroyed managers should no longer retain tower models
    table.clear(self.Enemies) -- destroyed managers should no longer retain enemy models
end

local scene = Instance.new("Folder") -- a dedicated root keeps every generated demo instance together in explorer
scene.Name = "TargetingDemo" -- a stable name makes the generated instance tree easy to inspect in studio
scene.Parent = workspace -- parenting the scene exposes its descendants to the server world

local function folder(name)
    local item = Instance.new("Folder") -- separate folders distinguish enemies and cover for lifecycle and raycast filtering
    item.Name = name
    item.Parent = scene -- all generated groups remain owned by the same demo root
    return item
end

local enemies = folder("Enemies")
local blockers = folder("Blockers")
local towers = folder("Towers")
local scenery = folder("Scenery")
local shots = folder("Shots")
local manager = TowerTargeting.new(enemies, blockers, 16) -- the scene supplies explicit enemy and cover populations to the targeting class

local function part(parent, name, size, position, color)
    local item = Instance.new("Part") -- real parts make the demo inspectable and give it physical world positions
    item.Name = name
    item.Size = size
    item.Position = position
    item.Color = color
    item.Anchored = true -- scripted movement should not compete with rigid body simulation
    item.CanCollide = false -- moving demo objects should not push players or block one another
    item.TopSurface = Enum.SurfaceType.Smooth -- legacy surface connectors are unnecessary for these anchored objects
    item.BottomSurface = Enum.SurfaceType.Smooth -- the demo does not need automatic joints between touching parts
    item.Parent = parent -- the caller chooses whether this part is cover or an excluded scene object
    return item
end

local function label(parent, text, offset)
    local gui = Instance.new("BillboardGui") -- world space status labels keep each tower explanation beside its model
    gui.Name = "Status"
    gui.Size = UDim2.fromOffset(230, 65) -- pixel dimensions keep text readable independently of the attached part size
    gui.StudsOffset = Vector3.new(0, offset, 0) -- the label needs enough vertical separation to avoid covering its model
    gui.AlwaysOnTop = true -- status should remain readable while cover blocks a tower shot
    gui.MaxDistance = 180 -- distant labels should stop drawing before they clutter the screen
    gui.Parent = parent -- parenting to the part gives the billboard its world anchor
    local textLabel = Instance.new("TextLabel") -- the billboard needs a real gui descendant to display status text
    textLabel.Size = UDim2.fromScale(1, 1) -- filling the billboard makes the shared status size control all text labels
    textLabel.BackgroundColor3 = Color3.fromRGB(17, 23, 35)
    textLabel.BackgroundTransparency = 0.2 -- partial opacity separates text from the scene without fully hiding it
    textLabel.TextColor3 = Color3.new(1, 1, 1)
    textLabel.Font = Enum.Font.GothamMedium
    textLabel.TextSize = 15
    textLabel.TextWrapped = true -- target names and counters must fit the fixed billboard width
    textLabel.Text = text
    textLabel.Parent = gui -- the text belongs inside the world anchored gui instance
    return textLabel
end

local floor = part(scenery, "Floor", Vector3.new(140, 1, 110),
    Vector3.new(0, -1, 0), Color3.fromRGB(44, 59, 54))
floor.CanCollide = true -- players need a solid floor even though enemies move through scripted pivots
local wall = part(blockers, "SightBlocker", Vector3.new(3, 10, 12),
    Vector3.new(3, 4, 10), Color3.fromRGB(75, 82, 103))
wall.CanCollide = true -- cover should also behave as a solid obstacle for players
local spawn = Instance.new("SpawnLocation") -- a neutral spawn makes a fresh baseplate usable without adding any assets
spawn.Name = "DemoSpawn"
spawn.Anchored = true -- the spawn must remain fixed above the generated floor
spawn.Size = Vector3.new(6, 1, 6)
spawn.Position = Vector3.new(0, 0, 30)
spawn.Neutral = true -- the demo has no teams so every joining player may use this spawn
spawn.Parent = scenery -- the spawn is excluded from the dedicated cover raycast filter
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
    local length = (b - a).Magnitude -- segment lengths allow progress to represent actual traveled distance
    lengths[index] = length -- movement reuses segment lengths instead of recalculating them for every enemy
    totalLength = totalLength + length -- escape detection needs the full path distance rather than the final waypoint index
    local road = part(scenery, "Path", Vector3.new(6, 0.2, length),
        (a + b) / 2 - Vector3.new(0, 1.9, 0), Color3.fromRGB(142, 125, 95))
    road.CFrame = CFrame.lookAt(road.Position, b - Vector3.new(0, 1.9, 0)) -- the road local depth axis should align with its path segment
end

local function pathPosition(progress)
    local remaining = progress -- walking segment lengths converts total path distance into one segment fraction
    for index, length in ipairs(lengths) do
        if remaining <= length then -- the first segment containing the remaining distance determines the world position
            return points[index]:Lerp(points[index + 1], remaining / length) -- a normalized segment fraction interpolates continuously between its endpoints
        end
        remaining = remaining - length -- removing completed segments carries progress correctly around path bends
    end
    return points[#points] -- the last point supplies a consistent escape position once all segments are traversed
end

local modeNames = { "First", "Last", "Nearest", "Farthest", "Strongest",
    "Weakest", "Fastest", "Slowest", "LeastReserved", "Splash" }
local towerStates = {}
for index, position in ipairs({ Vector3.new(-33, 3, 1),
    Vector3.new(0, 3, 22), Vector3.new(33, 3, 1) }) do
    local model = Instance.new("Model") -- a model groups each root and its status or targeting attachments
    model.Name = "Tower" .. tostring(index)
    local root = part(model, "Turret", Vector3.new(4, 6, 4), position,
        Color3.fromHSV(index / 4, 0.6, 0.9))
    model.PrimaryPart = root -- pivot movement and targeting must share the explicitly assigned root
    model.Parent = towers -- the tower hierarchy is separate from the enemy registration hierarchy
    local attachment = Instance.new("Attachment") -- beams need real attachment endpoints rather than arbitrary vector positions
    attachment.Position = Vector3.new(0, 3, 0) -- a local muzzle offset places the beam above the tower body
    attachment.Parent = root -- the endpoint follows the tower root transform automatically
    local beam = Instance.new("Beam") -- a real beam shows which enemy won selection without implementing a client renderer
    beam.Name = "TargetIndicator"
    beam.Attachment0 = attachment -- the tower muzzle is the persistent start endpoint
    beam.Width0 = 0.12
    beam.Width1 = 0.12
    beam.FaceCamera = true -- camera facing makes a thin target indicator readable from different viewing angles
    beam.Color = ColorSequence.new(root.Color) -- matching the tower color identifies which tower owns a target indicator
    beam.Enabled = false -- the beam should remain hidden until a valid target endpoint is assigned
    beam.Parent = root -- the tower owns the beam and its attachment lifetime
    local status = label(root, "", 7)
    local prompt = Instance.new("ProximityPrompt") -- server handled interaction lets players change modes without a separate local script
    prompt.ActionText = "Change targeting mode"
    prompt.ObjectText = model.Name
    prompt.HoldDuration = 0 -- mode comparisons should respond to a single activation
    prompt.MaxActivationDistance = 15 -- interaction stays local to the tower whose mode will change
    prompt.RequiresLineOfSight = false -- the mode control should remain usable even when cover blocks a tower attack
    prompt.Parent = root -- the tower root supplies the prompt location
    local state = { Model = model, Root = root, Beam = beam, Status = status,
        ModeIndex = index, NextShot = 0, Damage = 12 }
    towerStates[model] = state
    manager:AddTower(model, root, { Mode = modeNames[index], Range = 32,
        DetectHidden = index == 2, HitFlying = true, ProjectileSpeed = 50,
        RequireLineOfSight = index == 2, SplashRadius = 9, SplashLimit = 6 })
    prompt.Triggered:Connect(function()
        state.ModeIndex = state.ModeIndex % #modeNames + 1 -- modulo wraps the final mode back to the first without a separate branch
        manager:SetMode(model, modeNames[state.ModeIndex]) -- the prompt updates configuration through the same public method as game code
    end)
end

manager.TargetChanged.Event:Connect(function(model, target) -- indicators react to selection changes instead of performing their own enemy search
    local beam = towerStates[model].Beam
    beam.Enabled = target ~= nil -- losing a target must hide the indicator immediately
    beam.Attachment1 = target and target.PrimaryPart.TargetAttachment or nil -- the selected enemy attachment supplies the beam endpoint while nil clears it
end)

local activeEnemies = {}
local activeShots = {}
local spawnClock = 0
local nextEnemy = 0
local escaped = 0
local defeated = 0

local function spawnEnemy()
    nextEnemy = nextEnemy + 1 -- spawn identity also drives repeatable variants for comparing targeting modes
    local model = Instance.new("Model") -- a model groups each root and its status or targeting attachments
    model.Name = "Enemy" .. tostring(nextEnemy)
    local hidden = nextEnemy % 5 == 0 -- a predictable hidden variant demonstrates detection differences between towers
    local flying = nextEnemy % 4 == 0 -- a predictable flying variant exercises vertical movement and capability filtering
    local health = 30 + nextEnemy % 4 * 20 -- different durability values make strongest and weakest visibly distinct
    local root = part(model, "Root", Vector3.new(3, 3, 3), points[1] + Vector3.new(0, flying and 7 or 0, 0),
        hidden and Color3.fromRGB(170, 100, 230) or Color3.fromRGB(235, 100, 90))
    root.Transparency = hidden and 0.45 or 0 -- transparency communicates hidden state without being the rule that controls detection
    model.PrimaryPart = root -- pivot movement and targeting must share the explicitly assigned root
    local attachment = Instance.new("Attachment") -- beams need real attachment endpoints rather than arbitrary vector positions
    attachment.Name = "TargetAttachment" -- the target change listener needs the same attachment name on every enemy
    attachment.Parent = root -- the endpoint follows the tower root transform automatically
    model:SetAttribute("Health", health) -- combat and targeting share an explicit durability value on the model
    model:SetAttribute("Shield", nextEnemy % 3 == 0 and 20 or 0) -- some enemies gain shield so durability modes can be compared against health alone
    model:SetAttribute("Progress", 0) -- new enemies begin at zero distance along the shared path
    model:SetAttribute("TargetPriority", 0) -- equal priorities let the demo show mode differences without priority overrides
    model:SetAttribute("TargetRadius", 1.5) -- the spherical targeting radius matches half the root width
    model:SetAttribute("Flying", flying) -- eligibility reads a gameplay flag instead of guessing from height
    model:SetAttribute("Hidden", hidden) -- visibility capability tests need state independent from the visual transparency
    model:SetAttribute("Invulnerable", false) -- ordinary demo enemies remain damageable so combat can progress
    local status = label(root, "", 3)
    activeEnemies[model] = { Progress = 0, Speed = 7 + nextEnemy % 5,
        Height = flying and 7 or 0, Status = status }
    -- parenting last prevents registration before the required data exists
    model.Parent = enemies
end

local function applyDamage(model, amount)
    local shield = model:GetAttribute("Shield") -- damage resolves against the same shield value used by targeting scores
    local absorbed = math.min(shield, amount) -- shield absorption cannot exceed either available shield or incoming damage
    model:SetAttribute("Shield", shield - absorbed) -- the remaining shield must be visible to later damage and targeting snapshots
    model:SetAttribute("Health", math.max(0, model:GetAttribute("Health") - amount + absorbed)) -- only damage left after absorption reaches health and health never becomes negative
end

local function fireShot(state, target)
    local destination, leadTime = manager:GetAimPoint(state.Model, target) -- combat uses the targeting solver rather than independently predicting enemy movement
    local origin = state.Root.Position
    local duration = math.max(leadTime, (destination - origin).Magnitude / 50, 0.02) -- direct aim still needs travel time when the solver returns no future intercept
    local token = manager:ReserveDamage(state.Model, target, state.Damage, duration + 0.2) -- pending damage lasts slightly beyond expected flight while the shot resolves
    local visual = part(shots, "Projectile", Vector3.new(0.6, 0.6, 0.6), origin, state.Root.Color)
    visual.Material = Enum.Material.Neon -- unlit projectiles remain visible against the floor without additional light instances
    visual.Shape = Enum.PartType.Ball -- a small sphere makes the projectile direction visible without imported assets
    activeShots[#activeShots + 1] = { Visual = visual, Origin = origin,
        Destination = destination, Duration = duration, Elapsed = 0,
        Token = token, Target = target, Tower = state.Model, Damage = state.Damage,
        Splash = modeNames[state.ModeIndex] == "Splash" }
end

RunService.Heartbeat:Connect(function(deltaTime) -- one ordered server loop advances movement then targeting then projectile resolution
    spawnClock = spawnClock + deltaTime -- elapsed seconds keep spawn timing independent of frame rate
    if spawnClock >= 1.3 then
        spawnClock = spawnClock % 1.3 -- keeping the remainder preserves cadence while avoiding a spawn burst after a stall
        spawnEnemy()
    end
    for model, state in pairs(activeEnemies) do
        state.Progress = state.Progress + state.Speed * deltaTime -- distance advances in studs per second rather than studs per frame
        model:SetAttribute("Progress", state.Progress) -- the targeting snapshot must see the same progress used by movement
        model:PivotTo(CFrame.new(pathPosition(state.Progress) + Vector3.new(0, state.Height, 0))) -- pivoting moves the anchored model while a height offset keeps flying variants above the path
        state.Status.Text = model.Name .. "  hp " .. tostring(model:GetAttribute("Health"))
            .. "  shield " .. tostring(model:GetAttribute("Shield"))
        if model:GetAttribute("Health") <= 0 or state.Progress >= totalLength then
            if model:GetAttribute("Health") <= 0 then
                defeated = defeated + 1
            else
                escaped = escaped + 1
            end
            activeEnemies[model] = nil -- combat should stop considering an enemy after death or escape
            model:Destroy() -- removing the model also triggers the manager lifecycle cleanup through childremoved
        end
    end
    manager:Update(deltaTime) -- manual updates preserve movement before targeting order without a second heartbeat connection
    for index = #activeShots, 1, -1 do -- reverse iteration allows completed shots to be removed without skipping another entry
        local shot = activeShots[index]
        shot.Elapsed = shot.Elapsed + deltaTime -- projectile travel uses elapsed simulation seconds just like enemy movement
        shot.Visual.Position = shot.Origin:Lerp(shot.Destination, math.min(1, shot.Elapsed / shot.Duration)) -- a clamped flight fraction moves the visual to a fixed predicted destination
        if shot.Elapsed >= shot.Duration then
            manager:CancelReservation(shot.Token) -- the shot no longer represents future damage after impact resolution begins
            if activeEnemies[shot.Target] ~= nil then -- a projectile may arrive after its intended enemy has already died or escaped
                if (shot.Target.PrimaryPart.Position - shot.Destination).Magnitude <= 3 then
                    -- a path turn can make a constant velocity prediction miss
                    if shot.Splash then
                        local tower = manager.Towers[shot.Tower]
                        local radius = tower.Settings.SplashRadius
                        manager:_visitCells(shot.Destination, radius + manager.MaximumRadius, function(enemy)
                            local reach = radius + enemy.Radius -- splash uses sphere overlap consistently with the cluster score
                            if enemy.Health > 0 and not enemy.Invulnerable
                                and (not enemy.Hidden or tower.Settings.DetectHidden)
                                and distanceSquared(enemy.Position, shot.Destination) <= reach * reach then
                                applyDamage(enemy.Model, shot.Damage) -- area hits reuse shield absorption rather than implementing separate damage rules
                            end
                        end)
                    else
                        applyDamage(shot.Target, shot.Damage) -- a direct hit applies damage only to the intended enemy
                    end
                end
            end
            shot.Visual:Destroy() -- completed shots must release their real world visual instance
            table.remove(activeShots, index) -- completed shots must stop accumulating frame updates
        end
    end
    for model, state in pairs(towerStates) do
        local target = manager:GetTarget(model) -- combat uses the manager selection instead of searching enemies again
        state.Status.Text = modeNames[state.ModeIndex] .. "  |  " .. (target and target.Name or "no target")
            .. "\ndefeated " .. tostring(defeated) .. "  escaped " .. tostring(escaped)
        if target ~= nil and manager.Clock >= state.NextShot then -- a tower needs both a selected enemy and an elapsed cooldown to fire
            fireShot(state, target)
            state.NextShot = manager.Clock + 0.8 -- the next deadline prevents firing once per heartbeat
        end
    end
end)

