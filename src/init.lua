--!nonstrict
--Version 1.2.0

--Settings
local Debug = false -- Enable if you want extra debug messages
local PlayerJoinTime = 10 -- The amount of time to wait for a player
local CanJoinMultipleParties = false -- Set to true if you want players to join more than 1 party at once for some reason

--Services
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

--Dependencies
local Signal = require(script.Parent:FindFirstChild("Signal") or script.Signal)
local Trove = require(script.Parent:FindFirstChild("Trove") or script.Trove)
local Option = require(script.Parent:FindFirstChild("Option") or script.Option)
local Promise = require(script.Parent:FindFirstChild("Promise") or script.Promise)
local EnumList = require(script.Parent:FindFirstChild("EnumList") or script.EnumList)

local function DebugPrint(msg: string)
	if Debug then
		print(msg)
	end
end

local Parties = {}
local RNG = Random.new()
local ActiveServers = RunService:IsServer() and MemoryStoreService:GetSortedMap("ActivePartyServers")

--[=[
	@class PartyModule

	This is the module itself, used to construct a party and find parties.
]=]
local PartyModule = {}

--[=[
	@class Party

	The party object returned by the [PartyModule.new] function.
]=]
local Party = {}
Party.__index = Party

--Types

export type PartyType = {
	Public: Enum,
	Friends: Enum,
	Private: Enum,
}

type self = {
	Id: string,
	Name: string,
	Players: { Player },
	OwnerId: number,
	PlaceId: number,
	Data: { [any]: any },
	MaxPlayers: number,
	Type: PartyType,
	Password: number | string,

	PlayerAdded: RBXScriptSignal | Signal,
	PlayerRemoved: RBXScriptSignal | Signal,
	OwnerChanged: RBXScriptSignal | Signal,
}

export type Party = typeof(setmetatable({} :: self, Party))

--[=[
	@interface PartyType
	@within PartyModule
	.Public Enum -- Public, all players can join the party.
	.Friends Enum -- Friends, only the owner's friends can join the party.
	.Private Enum -- Private, people can only join the group with a password. To set a password. All you have to do is Party.Password = "example".
]=]

--[=[
	@interface Party
	@within Party
	.Id string -- The Id of the party.
	.Name string -- The Name of the party.
	.Players { Player } -- The players inside the party.
	.OwnerId number -- The Owner's User Id.
	.PlaceId number -- The place Id the players will teleport to.
	.Data { [any]: any } -- An empty table used to store info of your choice.
	.MaxPlayers number -- The max amount of players there can be inside.
	.Type PartyType -- The behaviour of the party.
	.Password number | string -- The password in case the Party Type is Private.

	.PlayerAdded RBXScriptSignal | Signal -- Fires when a player has been added inside the party. Returns the player as the first parameter.
	.PlayerRemoved RBXScriptSignal | Signal -- Fires when a player has been removed inside the party. Returns the player as the first parameter.
	.OwnerChanged RBXScriptSignal | Signal -- Fires when the owner changes. Returns the new owner.
]=]

--PartyModule

--[=[
	@prop PartyCreated RBXScriptSignal | Signal
	@within PartyModule

	Fires whenever a party is created. Returns the party as a parameter.
]=]
--[=[
	@prop PartyRemoved RBXScriptSignal | Signal
	@within PartyModule

	Fires whenever a party is removed. Returns the party as a parameter.
]=]
--[=[
	@prop ServerStarted RBXScriptSignal | Signal
	@within PartyModule

	Fires whenever a party has started. Returns the party as a parameter.
	This should only fire on the server that the party has teleported to.

	An example would be:

	```lua
	-- In Server the player teleports to
	local PartyModule = require(Path.PartyModule)

	PartyModule.ServerStarted:Connect(function(Party: Party)
		print(Party.Data) -- prints the custom data
		print(Party.OwnerId) -- prints the owner user id
	end)
	```

	:::note
		The party will try to keep the player instances inside the Player array.
		If A player does not join the game in the amount of time specified in PlayerJoinTime, it will be replaced by their UserId.
	:::

	@tag In-Game
]=]
--[=[
	@prop PlayersLoaded RBXScriptSignal | Signal
	@within PartyModule

	This is an event that fires after all the Player array inside the party has finished loading.
	This is usually useful if added inside the [PartyModule.ServerStarted] event.

	```lua
	-- In Server the player teleports to
	local PartyModule = require(Path.PartyModule)

	PartyModule.ServerStarted:Connect(function(Party: Party)
		PartyModule.PlayersLoaded:Connect(function(Players: { Player })
			print(Players) -- prints the array of players (or user id on failed players)
		end)

		PartyModule.PlayersLoaded:Wait() -- waiting for all players to load
	end)
	```
	@tag In-Game
]=]
--[=[
	@prop CurrentParty Party
	@within PartyModule

	The party from the [PartyModule.ServerStarted] event.
	@tag In-Game
]=]
--[=[
	@prop PartyType PartyType
	@within PartyModule

	@readonly
	A enum of all the party types.
]=]

PartyModule.PartyCreated = Signal.new()
PartyModule.PartyDestroyed = Signal.new()
PartyModule.ServerStarted = Signal.new()
PartyModule.PlayersLoaded = Signal.new()
PartyModule.CurrentParty = nil
PartyModule.PartyType = EnumList.new("PartyType", {
	"Public",
	"Friends",
	"Private",
})

--[=[
	Returns the party that the given player is in, if any.

	@param Player Player -- The player to search for.
	@return Party -- The party object. 

	@error "No Player" -- Happens when the player isn't a valid player instance.
]=]
function PartyModule.GetPartyFromPlayer(Player: Player): Party
	assert(typeof(Player) == "Instance" and Player:IsA("Player"), "Please provide a valid player.")

	for _, PartyTable: Party in pairs(Parties) do
		if table.find(PartyTable.Players, Player) then
			return PartyTable
		end
	end
end

--[=[
	Returns an array of all the parties.

	@return { Party } -- The party array. 
]=]
function PartyModule.GetParties(): { Party }
	local PartyArray = {}

	for _, PartyTable in pairs(Parties) do
		table.insert(PartyArray, PartyTable)
	end

	return PartyArray
end

--[=[
	Returns the party with the provided Id.

	@param Id string -- The id of the party to search for.

	@return Party -- The party.
]=]
function PartyModule.GetPartyFromId(Id: string): Party
	assert(type(Id) == "string", "Please provide a valid id.")

	return Parties[Id]
end

--[=[
	Returns a boolean indicating if the player is inside the party.

	@param PartyTable Party -- The party.
	@param Player Player -- The Player that will be searched.

	@return boolean -- The boolean indicating if the player is in the party.
]=]
function PartyModule.IsInParty(PartyTable: Party, Player: Player): boolean
	assert(typeof(Player) == "Instance" and Player:IsA("Player"), "Please provide a valid player.")

	return Option.Wrap(table.find(PartyTable.Players, Player)):IsSome()
end

--[=[
	Returns the party's owner.

	@param PartyTable Party -- The party.

	@return Player -- The owner of the party.
]=]
function PartyModule.GetOwner(PartyTable: Party): Player
	return Players:GetPlayerByUserId(PartyTable.OwnerId)
end

--[=[
	Returns a boolean indicating if the given player is the owner.

	@param PartyTable Party -- The party.
	@param Player Player -- The player to be checked.

	@return boolean -- The boolean indicating if the player is the owner of the party.

	@error "No Player" -- Happens when no valid player is provided.
]=]
function PartyModule.IsOwner(PartyTable: Party, Player: Player): boolean
	assert(typeof(Player) == "Instance" and Player:IsA("Player"), "Please provide a valid player.")

	return Player.UserId == PartyTable.OwnerId
end

--[=[
	Returns a party object.

	@server

	@param Owner Player -- The Player that will be the owner.
	@param PlaceId number -- The place that the players will teleport to.
	@param Name string? -- The name the party will have. If not provided, it will be the owner's name.
	@param MaxPlayers number? -- The max amount of players that will be able to join. If not provided, defaults to 8.
	@param Type PartyType? -- Sets the type of the party. Got to [PartyModule.PartyType] for more info.

	@return Party -- A new Party.

	@error "Server Only" -- Happens when this function is called on the client.
]=]
function PartyModule.new(Owner: Player, PlaceId: number, Name: string?, MaxPlayers: number?, Type: PartyType?): Party
	assert(typeof(Owner) == "Instance" and Owner:IsA("Player"), "Please provide a player as the owner.")
	assert(type(PlaceId) == "number", "Please provide a valid Place Id.")
	assert(RunService:IsServer(), "A party can only be created on the server.")

	local self = setmetatable({}, Party)

	--Non Usable
	self._Trove = Trove.new()

	--Usable
	self.Id = HttpService:GenerateGUID(false)
	self.Name = Name or Owner.Name
	self.Players = { Owner }
	self.OwnerId = Owner.UserId
	self.PlaceId = PlaceId
	self.Data = {}
	self.MaxPlayers = MaxPlayers or 8
	self.Type = if PartyModule.PartyType:BelongsTo(Type) then Type else PartyModule.PartyType.Public
	self.Password = nil

	self.PlayerAdded = self._Trove:Construct(Signal)
	self.PlayerRemoved = self._Trove:Construct(Signal)
	self.OwnerChanged = self._Trove:Construct(Signal)

	PartyModule.PartyCreated:Fire(self)

	Parties[self.Id] = self

	return self
end

--Party

function Party.__tostring(_)
	return "Party"
end

--[=[
	@method AddPlayer
	@within Party

	Adds the given player inside the party.

	@server
	@param Player Player -- The Player that will be added.
	@param Password number | string? -- The password of the party. Should only use this if party type is private.

	@return boolean -- A boolean indicating if the player has been successfully added.

	@error "Server Only" -- Happens when this method is called on the client.
	@error "No Player" -- Happens when no valid player is provided.
]=]
function Party.AddPlayer(self: Party, Player: Player, Password: number | string?): boolean
	assert(typeof(Player) == "Instance" and Player:IsA("Player"), "Please provide a valid player.")
	assert(RunService:IsServer(), "AddPlayer can only be called on the server.")

	if not CanJoinMultipleParties and PartyModule.GetPartyFromPlayer(Player) then
		warn("Player " .. Player.Name .. " is already in a party.")
		return false
	end

	local Exists = Option.Wrap(table.find(self.Players, Player))
	local Type = self.Type
	local Status = false

	Exists:Match({
		["Some"] = function(_)
			warn(Player.Name .. " is already in the party.")
		end,
		["None"] = function()
			if #self.Players < self.MaxPlayers then
				if
					Type == PartyModule.PartyType.Public
					or (Type == PartyModule.PartyType.Friends and PartyModule.GetOwner(self)
						:IsFriendsWith(Player.UserId))
					or (Type == PartyModule.PartyType.Private and Password == self.Password)
				then
					table.insert(self.Players, Player)
					self.PlayerAdded:Fire(Player)
					Status = true
				else
					DebugPrint("Could not add player. This is due to not being friends or password not being right.")
				end
			else
				warn("Cannot add player " .. Player.Name .. " due to max players.")
			end
		end,
	})

	return Status
end

--[=[
	@method RemovePlayer
	@within Party

	Removes the given player inside the party.

	@server
	@param Player Player -- The Player that will be removed.

	@return boolean -- A boolean indicating if the player has been successfully removed.

	@error "Server Only" -- Happens when this method is called on the client.
	@error "No Player" -- Happens when no valid player is provided.
]=]
function Party.RemovePlayer(self: Party, Player: Player)
	assert(typeof(Player) == "Instance" and Player:IsA("Player"), "Please provide a valid player.")
	assert(RunService:IsServer(), "RemovePlayer can only be called on the server.")

	local Exists = Option.Wrap(table.find(self.Players, Player))

	Exists:Match({
		["Some"] = function(Index)
			table.remove(self.Players, Index)
			self.PlayerRemoved:Fire(Player)

			if #self.Players > 0 then
				if self:IsOwner(Player) then
					self:SetOwner(RNG:NextInteger(1, #self.Players))
				end
			else
				self:Destroy()
			end
		end,
		["None"] = function()
			warn(Player.Name .. " is not in the party.")
		end,
	})

	return Exists:IsSome()
end

--[=[
	@method Start
	@within Party

	Teleports all the players.
	Calls [PartyModule.ServerStarted] on the teleported server.

	@server

	@error "Server Only" -- Happens when this method is called on the client.
]=]
function Party.Start(self: Party)
	assert(RunService:IsServer(), "Start can only be called on the server.")

	local Options = Instance.new("TeleportOptions")

	Options.ShouldReserveServer = true
	Promise.try(function()
		return TeleportService:TeleportAsync(self.PlaceId, self.Players, Options)
	end)
		:andThen(function(Info)
			local function ConvertToId(PlayerTable: { Player }): { number }
				local Converted = {}

				for _, Player: Player in pairs(PlayerTable) do
					table.insert(Converted, Player.UserId)
				end

				return Converted
			end

			self.Players = ConvertToId(self.Players)
			local SavingData = {
				ReservedServerAccessCode = Info.ReservedServerAccessCode,
				Party = HttpService:JSONEncode(self),
			}

			Promise.try(function()
				ActiveServers:SetAsync(Info.PrivateServerId, SavingData, 1000)
			end):catch(function(err)
				error("There was an error setting data for the party on teleport, more info here: " .. tostring(err))
			end)
		end)
		:catch(function(err)
			error("There was an error teleporting the party. more info here: " .. tostring(err))
		end)
end

--[=[
	@method SetOwner
	@within Party

	Sets the given player as the party's owner.

	@server

	@error "Server Only" -- Happens when this method is called on the client.
	@error "No Player" -- Happens when no valid player is provided.
]=]
function Party.SetOwner(self: Party, Player: Player)
	assert(typeof(Player) == "Instance" and Player:IsA("Player"), "Please provide a valid player.")
	assert(RunService:IsServer(), "SetOwner can only be called on the server.")

	self.OwnerId = Player.UserId
	self.OwnerChanged:Fire(Player)
end

--[=[
	@method Destroy
	@within Party

	Destroys the party.

	@server

	@error "Server Only" -- Happens when this method is called on the client.
]=]
function Party.Destroy(self: Party)
	assert(RunService:IsServer(), "Destroy can only be called on the server.")

	Parties[self.Id] = nil
	PartyModule.PartyDestroyed:Fire(self)
	self._Trove:Destroy()
	table.clear(self.Players)
	table.clear(self.Data)
end

do -- misc
	if RunService:IsServer() then
		if game.PrivateServerId ~= "" then
			Promise.try(function()
				return ActiveServers:GetAsync(game.PrivateServerId)
			end)
				:andThen(function(Data)
					local PartyTable: Party = HttpService:JSONDecode(Data.Party)

					Promise.each(PartyTable.Players, function(Value, _)
						return Promise.new(function(resolve, reject, onCancel)
							local Player: Player = Players:GetPlayerByUserId(Value)
								or Players:WaitForChild(Players:GetNameFromUserIdAsync(Value), PlayerJoinTime)

							if Player then
								resolve(Player)
							else
								reject(Value)
							end
						end)
							:andThen(function(Player: Player)
								local Index = table.find(PartyTable.Players, Player.UserId)
								PartyTable.Players[Index] = Player
							end)
							:catch(function(UserId: number)
								DebugPrint(
									"Couldn't transform the player with the user id "
										.. UserId
										.. " into an instance. He did not join in time."
								)
							end)
					end)
						:andThen(function()
							DebugPrint("Successfully converted all players")
						end)
						:catch(function()
							DebugPrint("Not all players were converted to instances.")
						end)
						:finally(function()
							PartyModule.PlayersLoaded:Fire(PartyTable.Players)
						end)

					PartyModule.ServerStarted:Fire(PartyTable)
					PartyModule.CurrentParty = PartyTable
					local function CheckServer()
						if #Players:GetPlayers() == 0 then
							Promise.Try(function()
								ActiveServers:RemoveAsync(game.PrivateServerId)
							end):catch(function(err)
								error("There was an error closing the server. " .. tostring(err), 2)
							end)
						end
					end

					game:BindToClose(CheckServer)
					Players.PlayerAdded:Connect(CheckServer)
					Players.PlayerRemoving:Connect(CheckServer)
				end)
				:catch(function(err)
					error("There was an error getting the data. " .. tostring(err), 2)
				end)
		end
	end
end

return PartyModule
