-- Hand-written declarations for the subset of the Roblox API used by the Roblox-facing modules, so that
-- luau-analyze can type check them. (Not the full API; generated from the calls this project makes.)

declare class Vector3
	X: number
	Y: number
	Z: number
	Magnitude: number
	function __add(self, o: Vector3): Vector3
	function __sub(self, o: Vector3): Vector3
	function __mul(self, o: number | Vector3): Vector3
	function __div(self, o: number): Vector3
end
declare Vector3: { new: (x: number?, y: number?, z: number?) -> Vector3 }

declare class CFrame
	Position: Vector3
end
declare CFrame: { new: ((x: number, y: number, z: number) -> CFrame) & ((p: Vector3) -> CFrame) }

declare class Region3 end
declare Region3: { new: (min: Vector3, max: Vector3) -> Region3 }

declare class Color3 end
declare Color3: { fromRGB: (r: number, g: number, b: number) -> Color3 }

declare class EnumItem end
declare Enum: {
	Material: { [string]: EnumItem } & { Air: EnumItem, Water: EnumItem, Grass: EnumItem, LeafyGrass: EnumItem, Rock: EnumItem },
	RaycastFilterType: { Exclude: EnumItem, Include: EnumItem },
}
export type Material = EnumItem

declare class RBXScriptConnection
	function Disconnect(self): ()
end
declare class RBXScriptSignal
	function Connect(self, f: (...any) -> ()): RBXScriptConnection
	function Wait(self): ...any
end

declare class Instance
	Name: string
	Parent: Instance?
	ClassName: string
	function Clone(self): any
	function Destroy(self): ()
	function FindFirstChild(self, name: string): Instance?
	function GetChildren(self): { Instance }
	function SetAttribute(self, name: string, value: any): ()
	function GetAttribute(self, name: string): any
	function IsA(self, class: string): boolean
end
declare Instance: { new: (class: string) -> any }

declare class BindableEvent extends Instance
	Event: RBXScriptSignal
	function Fire(self, ...: any): ()
end
declare class ObjectValue extends Instance
	Value: Instance?
end
declare class BasePart extends Instance
	Position: Vector3
	Size: Vector3
	Anchored: boolean
	CanCollide: boolean
	CanTouch: boolean
	CastShadow: boolean
	Locked: boolean
	Color: Color3
	Transparency: number
end
declare class Script extends Instance
	Disabled: boolean
	function GetActor(self): Actor?
end
declare class Actor extends Instance
	function BindToMessageParallel(self, topic: string, f: (...any) -> ()): RBXScriptConnection
	function BindToMessage(self, topic: string, f: (...any) -> ()): RBXScriptConnection
	function SendMessage(self, topic: string, ...: any): ()
end
declare class Terrain extends Instance
	Decoration: boolean
	function Clear(self): ()
	function FillBlock(self, cframe: CFrame, size: Vector3, material: EnumItem): ()
	function WriteVoxels(self, region: Region3, resolution: number, materials: { any }, occupancy: { any }): ()
	function SetMaterialColor(self, material: EnumItem, color: Color3): ()
end
declare class RaycastResult
	Position: Vector3
	Material: EnumItem
end
declare class RaycastParams
	IgnoreWater: boolean
end
declare RaycastParams: { new: () -> RaycastParams }
declare class Player extends Instance
	UserId: number
	Character: Model?
	function LoadCharacter(self): ()
end
declare class Model extends Instance
end
declare class Workspace extends Instance
	Terrain: Terrain
	function Raycast(self, origin: Vector3, direction: Vector3, params: RaycastParams?): RaycastResult?
end
declare workspace: Workspace
declare class PlayersService extends Instance
	CharacterAutoLoads: boolean
	PlayerRemoving: RBXScriptSignal
	function GetPlayers(self): { Player }
end
declare class RunServiceClass extends Instance
	Heartbeat: RBXScriptSignal
	function IsServer(self): boolean
end
declare class ServerScriptServiceClass extends Instance end
declare game: {
	GetService: ((self: any, name: "Players") -> PlayersService) & ((self: any, name: "RunService") -> RunServiceClass) & ((self: any, name: "ServerScriptService") -> ServerScriptServiceClass),
}
declare task: {
	wait: (number?) -> number,
	spawn: (f: (...any) -> ...any, ...any) -> thread,
	synchronize: () -> (),
	desynchronize: () -> (),
	defer: (f: (...any) -> ...any, ...any) -> thread,
}
declare function typeof(v: any): string
declare script: any
