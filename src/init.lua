--!nonstrict
--Version 1.0.0

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

type self = {
	Id: number,
	Name: string,
	Players: { Player },
	OwnerId: number,
	PlaceId: number,
	Data: { [any]: any },
	MaxPlayers: number,

	PlayerAdded: RBXScriptSignal | Signal,
	PlayerRemoved: RBXScriptSignal | Signal,
	OwnerChanged: RBXScriptSignal | Signal,
}

export type Party = typeof(setmetatable({} :: self, Party))

--[=[
	@interface Party
	@within Party
	.Id number -- The Id of the party.
	.Name string -- The Name of the party.
	.Players { Player } -- The players inside the party.
	.OwnerId number -- The Owner's User Id.
	.PlaceId number -- The place Id the players will teleport to.
	.Data { [any]: any } -- An empty table used to store info of your choice.
	.MaxPlayers number -- The max amount of players there can be inside.

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
]=]

PartyModule.PartyCreated = Signal.new()
PartyModule.PartyDestroyed = Signal.new()
PartyModule.ServerStarted = Signal.new()

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

	@param Id number -- The id of the party to search for.

	@return Party -- The party. 
]=]
function PartyModule.GetPartyFromId(Id: number): Party
	assert(type(Id) == "number", "Please provide a valid id.")

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

	@return Party -- A new Party.

	@error "Server Only" -- Happens when this function is called on the client.
]=]
function PartyModule.new(Owner: Player, PlaceId: number, Name: string?, MaxPlayers: number?): Party
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

	self.PlayerAdded = self._Trove:Construct(Signal)
	self.PlayerRemoved = self._Trove:Construct(Signal)
	self.OwnerChanged = self._Trove:Construct(Signal)

	PartyModule.PartyCreated:Fire(self)

	Parties[self.Id] = self

	return self
end

--Party

--[=[
	@method tostring
	@within Party

	@return string
]=]
function Party.__tostring(_)
	return "Party"
end

--[=[
	@method AddPlayer
	@within Party

	Adds the given player inside the party.

	@server
	@param Player Player -- The Player that will be added.

	@return boolean -- A boolean indicating if the player has been successfully added.

	@error "Server Only" -- Happens when this method is called on the client.
	@error "No Player" -- Happens when no valid player is provided.
]=]
function Party.AddPlayer(self: Party, Player: Player): boolean
	assert(typeof(Player) == "Instance" and Player:IsA("Player"), "Please provide a valid player.")
	assert(RunService:IsServer(), "AddPlayer can only be called on the server.")

	local Exists = Option.Wrap(table.find(self.Players, Player))
	local TargetPlayers = #self.Players + 1

	Exists:Match({
		["Some"] = function(_)
			warn(Player.Name .. " is already in the party.")
		end,
		["None"] = function()
			if #self.Players < self.MaxPlayers then
				table.insert(self.Players, Player)
				self.PlayerAdded:Fire(Player)
			else
				warn("Cannot add player " .. Player.Name .. " due to max players.")
			end
		end,
	})

	return Exists:IsNone() and #TargetPlayers <= self.MaxPlayers
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
end

do -- misc
	if RunService:IsServer() then
		if game.PrivateServerId ~= "" then
			Promise.try(function()
				return ActiveServers:GetAsync(game.PrivateServerId)
			end)
				:andThen(function(Data)
					local PartyTable = HttpService:JSONDecode(Data.Party)
					PartyModule.ServerStarted:Fire(PartyTable)

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
