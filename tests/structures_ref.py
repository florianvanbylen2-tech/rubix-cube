"""Independent reference for Structures.potentialChunk (Minecraft's RandomSpreadStructurePlacement)."""
MASK = (1 << 48) - 1
M64 = (1 << 64) - 1


def s32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


class JRandom:
    def __init__(self, seed):
        self.seed = ((seed & M64) ^ 0x5DEECE66D) & MASK

    def next(self, bits):
        self.seed = (self.seed * 0x5DEECE66D + 0xB) & MASK
        return s32(self.seed >> (48 - bits))

    def next_int(self, bound):
        r = self.next(31)
        m = bound - 1
        if bound & m == 0:
            return s32((bound * r) >> 31)
        u = r
        while True:
            r = u % bound
            if s32(u - r + m) >= 0:
                return r
            u = self.next(31)


def potential_chunk(world_seed, cx, cz, spacing, separation, salt, spread):
    rx, rz = cx // spacing, cz // spacing
    seed = (rx * 341873128712 + rz * 132897987541 + world_seed + salt) & M64
    rnd = JRandom(seed)
    bound = spacing - separation
    if spread == "triangular":
        a = (rnd.next_int(bound) + rnd.next_int(bound)) // 2
        b = (rnd.next_int(bound) + rnd.next_int(bound)) // 2
    else:
        a = rnd.next_int(bound)
        b = rnd.next_int(bound)
    return rx * spacing + a, rz * spacing + b


SEEDS = [12345, -987654321, -4172144997902289642]
DEFS = [("Village", 34, 8, 10387312, "linear"), ("Tri", 32, 5, 1234567, "triangular"), ("Tiny", 3, 1, 99, "linear")]
for seed in SEEDS:
    for name, spacing, sep, salt, spread in DEFS:
        for rx in range(-4, 5):
            for rz in range(-4, 5):
                cx, cz = potential_chunk(seed, rx * spacing + 1, rz * spacing, spacing, sep, salt, spread)
                print(f"{seed} {name} {rx} {rz} {cx} {cz}")
