class_name PlanetTerrain
extends Node3D

## Smooth planetary terrain — domain-warped noise + Marching Cubes isosurface.
## Supports true 3D geometry: overhangs, caves, tunnels.
## Surface sits at world y ≈ 0 in the flat spawn zone.
## Terrain rises outside FLAT_RADIUS.  Caves carved by 3-D noise below surface.

# ── Tile / vertex dimensions ──────────────────────────────────────────────────
const TILE_GRID      : int   = 16      # Voxel cubes per tile side (XZ)
const VERT_SPACING   : float = 16.0    # World units between voxel corners
const TILE_WORLD_SIZE: float = TILE_GRID * VERT_SPACING   # 256 world units

# ── Vertical voxel extent ─────────────────────────────────────────────────────
const VOXEL_Y_SLICES : int   = 44      # Voxel cubes in Y → 45 corner layers
const VOXEL_Y_BOTTOM : float = -200.0  # World Y of bottom voxel layer
# Top = VOXEL_Y_BOTTOM + VOXEL_Y_SLICES * VERT_SPACING = -200 + 44*16 = 504

const MAX_HEIGHT     : float = 450.0
const PLANET_RADIUS  : float = 50000.0
const WATER_LEVEL    : float = -5.0
const FLAT_RADIUS    : float = 1500.0

# ── LOD ───────────────────────────────────────────────────────────────────────
const LOD_STEPS  : Array = [1, 2, 4, 8]
const LOD_RANGES : Array = [768.0, 1536.0, 3072.0, 6144.0]
const UNLOAD_RANGE       : float = 7000.0
const HIGH_SPOT_THRESH   : float = 40.0
const HIGH_SPOT_EXTEND   : float = 1.6
const MAX_NEW_TILES      : int   = 4      # Keep per-frame stalls short (MC is heavy)
const UPDATE_INTERVAL    : float = 0.12

# ── Marching Cubes tables (Paul Bourke / Lorensen-Cline, public domain) ───────
# Corner layout (X right, Y up, Z forward):
#   4---5      Edges:  0:0-1  1:1-2  2:2-3  3:0-3
#  /|  /|              4:4-5  5:5-6  6:6-7  7:4-7
# 7---6 |              8:0-4  9:1-5 10:2-6 11:3-7
# | 0-|-1
# |/  |/
# 3---2
# (note: Y is up, so "top" corners 4-7 are at y+1)

# edge_table[case] → 12-bit mask of which edges are crossed
static var EDGE_TABLE : PackedInt32Array = PackedInt32Array([
	0x000,0x109,0x203,0x30a,0x406,0x50f,0x605,0x70c,0x80c,0x905,0xa0f,0xb06,0xc0a,0xd03,0xe09,0xf00,
	0x190,0x099,0x393,0x29a,0x596,0x49f,0x795,0x69c,0x99c,0x895,0xb9f,0xa96,0xd9a,0xc93,0xf99,0xe90,
	0x230,0x339,0x033,0x13a,0x636,0x73f,0x435,0x53c,0xa3c,0xb35,0x83f,0x936,0xe3a,0xf33,0xc39,0xd30,
	0x3a0,0x2a9,0x1a3,0x0aa,0x7a6,0x6af,0x5a5,0x4ac,0xbac,0xaa5,0x9af,0x8a6,0xfaa,0xea3,0xda9,0xca0,
	0x460,0x569,0x663,0x76a,0x066,0x16f,0x265,0x36c,0xc6c,0xd65,0xe6f,0xf66,0x86a,0x963,0xa69,0xb60,
	0x5f0,0x4f9,0x7f3,0x6fa,0x1f6,0x0ff,0x3f5,0x2fc,0xdfc,0xcf5,0xfff,0xef6,0x9fa,0x8f3,0xbf9,0xaf0,
	0x650,0x759,0x453,0x55a,0x256,0x35f,0x055,0x15c,0xe5c,0xf55,0xc5f,0xd56,0xa5a,0xb53,0x859,0x950,
	0x7c0,0x6c9,0x5c3,0x4ca,0x3c6,0x2cf,0x1c5,0x0cc,0xfcc,0xec5,0xdcf,0xcc6,0xbca,0xac3,0x9c9,0x8c0,
	0x8c0,0x9c9,0xac3,0xbca,0xcc6,0xdcf,0xec5,0xfcc,0x0cc,0x1c5,0x2cf,0x3c6,0x4ca,0x5c3,0x6c9,0x7c0,
	0x950,0x859,0xb53,0xa5a,0xd56,0xc5f,0xf55,0xe5c,0x15c,0x055,0x35f,0x256,0x55a,0x453,0x759,0x650,
	0xaf0,0xbf9,0x8f3,0x9fa,0xef6,0xfff,0xcf5,0xdfc,0x2fc,0x3f5,0x0ff,0x1f6,0x6fa,0x7f3,0x4f9,0x5f0,
	0xb60,0xa69,0x963,0x86a,0xf66,0xe6f,0xd65,0xc6c,0x36c,0x265,0x16f,0x066,0x76a,0x663,0x569,0x460,
	0xca0,0xda9,0xea3,0xfaa,0x8a6,0x9af,0xaa5,0xbac,0x4ac,0x5a5,0x6af,0x7a6,0x0aa,0x1a3,0x2a9,0x3a0,
	0xd30,0xc39,0xf33,0xe3a,0x936,0x83f,0xb35,0xa3c,0x53c,0x435,0x73f,0x636,0x13a,0x033,0x339,0x230,
	0xe90,0xf99,0xc93,0xd9a,0xa96,0xb9f,0x895,0x99c,0x69c,0x795,0x49f,0x596,0x29a,0x393,0x099,0x190,
	0xf00,0xe09,0xd03,0xc0a,0xb06,0xa0f,0x905,0x80c,0x70c,0x605,0x50f,0x406,0x30a,0x203,0x109,0x000,
])

# tri_table[case*16 + i] → edge index (or -1 to end list); up to 5 triangles per case
static var TRI_TABLE : PackedInt32Array = PackedInt32Array([
	-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1, # 0
	0,8,3,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 1
	0,1,9,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 2
	1,8,3,9,8,1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 3
	1,2,10,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,    # 4
	0,8,3,1,2,10,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 5
	9,2,10,0,2,9,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 6
	2,8,3,2,10,8,10,9,8,-1,-1,-1,-1,-1,-1,-1,         # 7
	3,11,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,    # 8
	0,11,2,8,11,0,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,      # 9
	1,9,0,2,3,11,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 10
	1,11,2,1,9,11,9,8,11,-1,-1,-1,-1,-1,-1,-1,        # 11
	3,10,1,11,10,3,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 12
	0,10,1,0,8,10,8,11,10,-1,-1,-1,-1,-1,-1,-1,       # 13
	3,9,0,3,11,9,11,10,9,-1,-1,-1,-1,-1,-1,-1,        # 14
	9,8,10,10,8,11,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 15
	4,7,8,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 16
	4,3,0,7,3,4,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 17
	0,1,9,8,4,7,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 18
	4,1,9,4,7,1,7,3,1,-1,-1,-1,-1,-1,-1,-1,           # 19
	1,2,10,8,4,7,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 20
	3,4,7,3,0,4,1,2,10,-1,-1,-1,-1,-1,-1,-1,          # 21
	9,2,10,9,0,2,8,4,7,-1,-1,-1,-1,-1,-1,-1,          # 22
	2,10,9,2,9,7,2,7,3,7,9,4,-1,-1,-1,-1,             # 23
	8,4,7,3,11,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 24
	11,4,7,11,2,4,2,0,4,-1,-1,-1,-1,-1,-1,-1,         # 25
	9,0,1,8,4,7,2,3,11,-1,-1,-1,-1,-1,-1,-1,          # 26
	4,7,11,9,4,11,9,11,2,9,2,1,-1,-1,-1,-1,           # 27
	3,10,1,3,11,10,7,8,4,-1,-1,-1,-1,-1,-1,-1,        # 28
	1,11,10,1,4,11,1,0,4,7,11,4,-1,-1,-1,-1,          # 29
	4,7,8,9,0,11,9,11,10,11,0,3,-1,-1,-1,-1,          # 30
	4,7,11,4,11,9,9,11,10,-1,-1,-1,-1,-1,-1,-1,       # 31
	9,5,4,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 32
	9,5,4,0,8,3,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 33
	0,5,4,1,5,0,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 34
	8,5,4,8,3,5,3,1,5,-1,-1,-1,-1,-1,-1,-1,           # 35
	1,2,10,9,5,4,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 36
	3,0,8,1,2,10,4,9,5,-1,-1,-1,-1,-1,-1,-1,          # 37
	5,2,10,5,4,2,4,0,2,-1,-1,-1,-1,-1,-1,-1,          # 38
	2,10,5,3,2,5,3,5,4,3,4,8,-1,-1,-1,-1,             # 39
	9,5,4,2,3,11,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 40
	0,11,2,0,8,11,4,9,5,-1,-1,-1,-1,-1,-1,-1,         # 41
	0,5,4,0,1,5,2,3,11,-1,-1,-1,-1,-1,-1,-1,          # 42
	2,1,5,2,5,8,2,8,11,4,8,5,-1,-1,-1,-1,             # 43
	10,3,11,10,1,3,9,5,4,-1,-1,-1,-1,-1,-1,-1,        # 44
	4,9,5,0,8,1,8,10,1,8,11,10,-1,-1,-1,-1,           # 45
	5,4,0,5,0,11,5,11,10,11,0,3,-1,-1,-1,-1,          # 46
	5,4,8,5,8,10,10,8,11,-1,-1,-1,-1,-1,-1,-1,        # 47
	9,7,8,5,7,9,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 48
	9,3,0,9,5,3,5,7,3,-1,-1,-1,-1,-1,-1,-1,           # 49
	0,7,8,0,1,7,1,5,7,-1,-1,-1,-1,-1,-1,-1,           # 50
	1,5,3,3,5,7,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 51
	9,7,8,9,5,7,10,1,2,-1,-1,-1,-1,-1,-1,-1,          # 52
	10,1,2,9,5,0,5,3,0,5,7,3,-1,-1,-1,-1,             # 53
	8,0,2,8,2,5,8,5,7,10,5,2,-1,-1,-1,-1,             # 54
	2,10,5,2,5,3,3,5,7,-1,-1,-1,-1,-1,-1,-1,          # 55
	7,9,5,7,8,9,3,11,2,-1,-1,-1,-1,-1,-1,-1,          # 56
	9,5,7,9,7,2,9,2,0,2,7,11,-1,-1,-1,-1,             # 57
	2,3,11,0,1,8,1,7,8,1,5,7,-1,-1,-1,-1,             # 58
	11,2,1,11,1,7,7,1,5,-1,-1,-1,-1,-1,-1,-1,         # 59
	9,5,8,8,5,7,10,1,3,10,3,11,-1,-1,-1,-1,           # 60
	5,7,0,5,0,9,7,11,0,1,0,10,11,10,0,-1,             # 61
	11,10,0,11,0,3,10,5,0,8,0,7,5,7,0,-1,             # 62
	11,10,5,7,11,5,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 63
	10,6,5,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,    # 64
	0,8,3,10,6,5,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 65
	9,0,1,5,10,6,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 66
	1,8,3,1,9,8,5,10,6,-1,-1,-1,-1,-1,-1,-1,          # 67
	1,6,5,2,6,1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 68
	1,6,5,1,2,6,3,0,8,-1,-1,-1,-1,-1,-1,-1,           # 69
	9,6,5,9,0,6,0,2,6,-1,-1,-1,-1,-1,-1,-1,           # 70
	5,9,8,5,8,2,5,2,6,3,2,8,-1,-1,-1,-1,              # 71
	2,3,11,10,6,5,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,      # 72
	11,0,8,11,2,0,10,6,5,-1,-1,-1,-1,-1,-1,-1,        # 73
	0,1,9,2,3,11,5,10,6,-1,-1,-1,-1,-1,-1,-1,         # 74
	5,10,6,1,9,2,9,11,2,9,8,11,-1,-1,-1,-1,           # 75
	3,11,6,3,6,0,0,6,5,0,5,9,-1,-1,-1,-1,             # 76
	0,8,11,0,11,5,0,5,1,5,11,6,-1,-1,-1,-1,           # 77
	3,11,6,0,3,6,0,6,5,0,5,9,-1,-1,-1,-1,             # 78 (variant)
	9,5,6,9,6,11,9,11,8,-1,-1,-1,-1,-1,-1,-1,         # 79
	5,10,6,4,7,8,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 80
	4,3,0,4,7,3,6,5,10,-1,-1,-1,-1,-1,-1,-1,          # 81
	1,9,0,5,10,6,8,4,7,-1,-1,-1,-1,-1,-1,-1,          # 82
	10,6,5,1,9,7,1,7,3,7,9,4,-1,-1,-1,-1,             # 83
	6,1,2,6,5,1,4,7,8,-1,-1,-1,-1,-1,-1,-1,           # 84
	1,2,5,5,2,6,3,0,4,3,4,7,-1,-1,-1,-1,              # 85
	8,4,7,9,0,5,0,6,5,0,2,6,-1,-1,-1,-1,              # 86
	7,3,9,7,9,4,3,2,9,5,9,6,2,6,9,-1,                 # 87
	3,11,2,7,8,4,10,6,5,-1,-1,-1,-1,-1,-1,-1,         # 88
	5,10,6,4,7,2,4,2,0,2,7,11,-1,-1,-1,-1,            # 89
	0,1,9,4,7,8,2,3,11,5,10,6,-1,-1,-1,-1,            # 90
	9,2,1,9,11,2,9,4,11,7,11,4,5,10,6,-1,             # 91
	8,4,7,3,11,5,3,5,1,5,11,6,-1,-1,-1,-1,            # 92
	5,1,11,5,11,6,1,0,11,7,11,4,0,4,11,-1,            # 93
	0,5,9,0,6,5,0,3,6,11,6,3,8,4,7,-1,                # 94
	6,5,9,6,9,11,4,7,9,7,11,9,-1,-1,-1,-1,            # 95
	10,4,9,6,4,10,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,      # 96
	4,10,6,4,9,10,0,8,3,-1,-1,-1,-1,-1,-1,-1,         # 97
	10,0,1,10,6,0,6,4,0,-1,-1,-1,-1,-1,-1,-1,         # 98
	8,3,1,8,1,6,8,6,4,6,1,10,-1,-1,-1,-1,             # 99
	1,4,9,1,2,4,2,6,4,-1,-1,-1,-1,-1,-1,-1,           # 100
	3,0,8,1,2,9,2,4,9,2,6,4,-1,-1,-1,-1,              # 101
	0,2,4,4,2,6,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 102
	8,3,2,8,2,4,4,2,6,-1,-1,-1,-1,-1,-1,-1,           # 103
	10,4,9,10,6,4,11,2,3,-1,-1,-1,-1,-1,-1,-1,        # 104
	0,8,2,2,8,11,4,9,10,4,10,6,-1,-1,-1,-1,           # 105
	3,11,2,0,1,6,0,6,4,6,1,10,-1,-1,-1,-1,            # 106
	6,4,1,6,1,10,4,8,1,2,1,11,8,11,1,-1,              # 107
	9,6,4,9,3,6,9,1,3,11,6,3,-1,-1,-1,-1,             # 108
	8,11,1,8,1,0,11,6,1,9,1,4,6,4,1,-1,               # 109
	3,11,6,3,6,0,0,6,4,-1,-1,-1,-1,-1,-1,-1,          # 110
	6,4,8,11,6,8,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 111
	7,10,6,7,8,10,8,9,10,-1,-1,-1,-1,-1,-1,-1,        # 112
	0,7,3,0,10,7,0,9,10,6,7,10,-1,-1,-1,-1,           # 113
	10,6,7,1,10,7,1,7,8,1,8,0,-1,-1,-1,-1,            # 114
	10,6,7,10,7,1,1,7,3,-1,-1,-1,-1,-1,-1,-1,         # 115
	1,2,6,1,6,8,1,8,9,8,6,7,-1,-1,-1,-1,              # 116
	2,6,9,2,9,1,6,7,9,0,9,3,7,3,9,-1,                 # 117
	7,8,0,7,0,6,6,0,2,-1,-1,-1,-1,-1,-1,-1,           # 118
	7,3,2,6,7,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 119
	2,3,11,10,6,8,10,8,9,8,6,7,-1,-1,-1,-1,           # 120
	2,0,7,2,7,11,0,9,7,6,7,10,9,10,7,-1,              # 121
	1,8,0,1,7,8,1,10,7,6,7,10,2,3,11,-1,              # 122
	11,2,1,11,1,7,10,6,1,6,7,1,-1,-1,-1,-1,           # 123
	8,9,6,8,6,7,9,1,6,11,6,3,1,3,6,-1,                # 124
	0,9,1,11,6,7,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 125
	7,8,0,7,0,6,3,11,0,11,6,0,-1,-1,-1,-1,            # 126
	7,11,6,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,    # 127
	7,6,11,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,    # 128
	3,0,8,11,7,6,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 129
	0,1,9,11,7,6,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 130
	8,1,9,8,3,1,11,7,6,-1,-1,-1,-1,-1,-1,-1,          # 131
	10,1,2,6,11,7,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,      # 132
	1,2,10,3,0,8,6,11,7,-1,-1,-1,-1,-1,-1,-1,         # 133
	2,9,0,2,10,9,6,11,7,-1,-1,-1,-1,-1,-1,-1,         # 134
	6,11,7,2,10,3,10,8,3,10,9,8,-1,-1,-1,-1,          # 135
	7,2,3,6,2,7,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 136
	7,0,8,7,6,0,6,2,0,-1,-1,-1,-1,-1,-1,-1,           # 137
	2,7,6,2,3,7,0,1,9,-1,-1,-1,-1,-1,-1,-1,           # 138
	1,6,2,1,8,6,1,9,8,8,7,6,-1,-1,-1,-1,              # 139
	10,7,6,10,1,7,1,3,7,-1,-1,-1,-1,-1,-1,-1,         # 140
	10,7,6,1,7,10,1,8,7,1,0,8,-1,-1,-1,-1,            # 141
	0,3,7,0,7,10,0,10,9,6,10,7,-1,-1,-1,-1,           # 142
	7,6,10,7,10,8,8,10,9,-1,-1,-1,-1,-1,-1,-1,        # 143
	6,8,4,11,8,6,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 144
	3,6,11,3,0,6,0,4,6,-1,-1,-1,-1,-1,-1,-1,          # 145
	8,6,11,8,4,6,9,0,1,-1,-1,-1,-1,-1,-1,-1,          # 146
	9,4,6,9,6,3,9,3,1,11,3,6,-1,-1,-1,-1,             # 147
	6,8,4,6,11,8,2,10,1,-1,-1,-1,-1,-1,-1,-1,         # 148
	1,2,10,3,0,11,0,6,11,0,4,6,-1,-1,-1,-1,           # 149
	4,11,8,4,6,11,0,2,9,2,10,9,-1,-1,-1,-1,           # 150
	10,9,3,10,3,2,9,4,3,11,3,6,4,6,3,-1,              # 151
	8,2,3,8,4,2,4,6,2,-1,-1,-1,-1,-1,-1,-1,           # 152
	0,4,2,4,6,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 153
	1,9,0,2,3,4,2,4,6,4,3,8,-1,-1,-1,-1,              # 154
	1,9,4,1,4,2,2,4,6,-1,-1,-1,-1,-1,-1,-1,           # 155
	8,1,3,8,6,1,8,4,6,6,10,1,-1,-1,-1,-1,             # 156
	10,1,0,10,0,6,6,0,4,-1,-1,-1,-1,-1,-1,-1,         # 157
	4,6,3,4,3,8,6,10,3,0,3,9,10,9,3,-1,               # 158
	10,9,4,6,10,4,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,      # 159
	4,9,5,7,6,11,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 160
	0,8,3,4,9,5,11,7,6,-1,-1,-1,-1,-1,-1,-1,          # 161
	5,0,1,5,4,0,7,6,11,-1,-1,-1,-1,-1,-1,-1,          # 162
	11,7,6,8,3,4,3,5,4,3,1,5,-1,-1,-1,-1,             # 163
	9,5,4,10,1,2,7,6,11,-1,-1,-1,-1,-1,-1,-1,         # 164
	6,11,7,1,2,10,0,8,3,4,9,5,-1,-1,-1,-1,            # 165
	7,6,11,5,4,10,4,2,10,4,0,2,-1,-1,-1,-1,           # 166
	3,4,8,3,5,4,3,2,5,10,5,2,11,7,6,-1,               # 167
	7,2,3,7,6,2,5,4,9,-1,-1,-1,-1,-1,-1,-1,           # 168
	9,5,4,0,8,6,0,6,2,6,8,7,-1,-1,-1,-1,              # 169
	3,6,2,3,7,6,1,5,0,5,4,0,-1,-1,-1,-1,              # 170
	6,2,8,6,8,7,2,1,8,4,8,5,1,5,8,-1,                 # 171
	9,5,4,10,1,6,1,7,6,1,3,7,-1,-1,-1,-1,             # 172
	1,6,10,1,7,6,1,0,7,8,7,0,9,5,4,-1,                # 173
	4,0,10,4,10,5,0,3,10,6,10,7,3,7,10,-1,            # 174
	7,6,10,7,10,8,5,4,10,4,8,10,-1,-1,-1,-1,          # 175
	6,9,5,6,11,9,11,8,9,-1,-1,-1,-1,-1,-1,-1,         # 176
	3,6,11,0,6,3,0,5,6,0,9,5,-1,-1,-1,-1,             # 177
	0,11,8,0,5,11,0,1,5,5,6,11,-1,-1,-1,-1,           # 178
	6,11,3,6,3,5,5,3,1,-1,-1,-1,-1,-1,-1,-1,          # 179
	1,2,10,9,5,11,9,11,8,11,5,6,-1,-1,-1,-1,          # 180
	0,11,3,0,6,11,0,9,6,5,6,9,1,2,10,-1,              # 181
	11,8,5,11,5,6,8,0,5,10,5,2,0,2,5,-1,              # 182
	6,11,3,6,3,5,2,10,3,10,5,3,-1,-1,-1,-1,           # 183
	5,8,9,5,2,8,5,6,2,3,8,2,-1,-1,-1,-1,              # 184
	9,5,6,9,6,0,0,6,2,-1,-1,-1,-1,-1,-1,-1,           # 185
	1,5,8,1,8,0,5,6,8,3,8,2,6,2,8,-1,                 # 186
	1,5,6,2,1,6,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 187
	1,3,6,1,6,10,3,8,6,5,6,9,8,9,6,-1,                # 188
	10,1,0,10,0,6,9,5,0,5,6,0,-1,-1,-1,-1,            # 189
	0,3,8,5,6,10,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 190
	10,5,6,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,    # 191
	11,5,10,7,5,11,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 192
	11,5,10,11,7,5,8,3,0,-1,-1,-1,-1,-1,-1,-1,        # 193
	5,11,7,5,10,11,1,9,0,-1,-1,-1,-1,-1,-1,-1,        # 194
	10,7,5,10,11,7,9,8,1,8,3,1,-1,-1,-1,-1,           # 195
	11,1,2,11,7,1,7,5,1,-1,-1,-1,-1,-1,-1,-1,         # 196
	0,8,3,1,2,7,1,7,5,7,2,11,-1,-1,-1,-1,             # 197
	9,7,5,9,2,7,9,0,2,2,11,7,-1,-1,-1,-1,             # 198
	7,5,2,7,2,11,5,9,2,3,2,8,9,8,2,-1,                # 199
	2,5,10,2,3,5,3,7,5,-1,-1,-1,-1,-1,-1,-1,          # 200
	8,2,0,8,5,2,8,7,5,10,2,5,-1,-1,-1,-1,             # 201
	9,0,1,5,10,3,5,3,7,3,10,2,-1,-1,-1,-1,            # 202
	9,8,2,9,2,1,8,7,2,10,2,5,7,5,2,-1,                # 203
	1,3,5,3,7,5,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 204
	0,8,7,0,7,1,1,7,5,-1,-1,-1,-1,-1,-1,-1,           # 205
	9,0,3,9,3,5,5,3,7,-1,-1,-1,-1,-1,-1,-1,           # 206
	9,8,7,5,9,7,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 207
	5,8,4,5,10,8,10,11,8,-1,-1,-1,-1,-1,-1,-1,        # 208
	5,0,4,5,11,0,5,10,11,11,3,0,-1,-1,-1,-1,          # 209
	0,1,9,8,4,10,8,10,11,10,4,5,-1,-1,-1,-1,          # 210
	10,11,4,10,4,5,11,3,4,9,4,1,3,1,4,-1,             # 211
	2,5,1,2,8,5,2,11,8,4,5,8,-1,-1,-1,-1,             # 212
	0,4,11,0,11,3,4,5,11,2,11,1,5,1,11,-1,            # 213
	0,2,5,0,5,9,2,11,5,4,5,8,11,8,5,-1,               # 214
	9,4,5,2,11,3,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 215
	2,5,10,3,5,2,3,4,5,3,8,4,-1,-1,-1,-1,             # 216
	5,10,2,5,2,4,4,2,0,-1,-1,-1,-1,-1,-1,-1,          # 217
	3,10,2,3,5,10,3,8,5,4,5,8,0,1,9,-1,               # 218
	5,10,2,5,2,4,1,9,2,9,4,2,-1,-1,-1,-1,             # 219
	8,4,5,8,5,3,3,5,1,-1,-1,-1,-1,-1,-1,-1,           # 220
	0,4,5,1,0,5,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 221
	8,4,5,8,5,3,9,0,5,0,3,5,-1,-1,-1,-1,              # 222
	9,4,5,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 223
	4,11,7,4,9,11,9,10,11,-1,-1,-1,-1,-1,-1,-1,       # 224
	0,8,3,4,9,7,9,11,7,9,10,11,-1,-1,-1,-1,           # 225
	1,10,11,1,11,4,1,4,0,7,4,11,-1,-1,-1,-1,          # 226
	3,1,4,3,4,8,1,10,4,7,4,11,10,11,4,-1,             # 227
	4,11,7,9,11,4,9,2,11,9,1,2,-1,-1,-1,-1,           # 228
	9,7,4,9,11,7,9,1,11,2,11,1,0,8,3,-1,              # 229
	11,7,4,11,4,2,2,4,0,-1,-1,-1,-1,-1,-1,-1,         # 230
	11,7,4,11,4,2,8,3,4,3,2,4,-1,-1,-1,-1,            # 231
	2,9,10,2,7,9,2,3,7,7,4,9,-1,-1,-1,-1,             # 232
	9,10,7,9,7,4,10,2,7,8,7,0,2,0,7,-1,               # 233
	3,7,10,3,10,2,7,4,10,1,10,0,4,0,10,-1,            # 234
	1,10,2,8,7,4,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 235
	4,9,1,4,1,7,7,1,3,-1,-1,-1,-1,-1,-1,-1,           # 236
	4,9,1,4,1,7,0,8,1,8,7,1,-1,-1,-1,-1,              # 237
	4,0,3,7,4,3,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 238
	4,8,7,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 239
	9,10,8,10,11,8,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 240
	3,0,9,3,9,11,11,9,10,-1,-1,-1,-1,-1,-1,-1,        # 241
	0,1,10,0,10,8,8,10,11,-1,-1,-1,-1,-1,-1,-1,       # 242
	3,1,10,11,3,10,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 243
	1,2,11,1,11,9,9,11,8,-1,-1,-1,-1,-1,-1,-1,        # 244
	3,0,9,3,9,11,1,2,9,2,11,9,-1,-1,-1,-1,            # 245
	0,2,11,8,0,11,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,      # 246
	3,2,11,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,    # 247
	2,3,8,2,8,10,10,8,9,-1,-1,-1,-1,-1,-1,-1,         # 248
	9,10,2,0,9,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,       # 249
	2,3,8,2,8,10,0,1,8,1,10,8,-1,-1,-1,-1,            # 250
	1,10,2,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,    # 251
	1,3,8,9,1,8,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,        # 252
	0,9,1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 253
	0,3,8,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,     # 254
	-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,  # 255
])

# Corner offsets (xi, yi, zi) for each of 8 cube corners
static var _CO_X : PackedInt32Array = PackedInt32Array([0,1,1,0, 0,1,1,0])
static var _CO_Y : PackedInt32Array = PackedInt32Array([0,0,0,0, 1,1,1,1])
static var _CO_Z : PackedInt32Array = PackedInt32Array([0,0,1,1, 0,0,1,1])
# Edge endpoint corner pairs
static var _EA : PackedInt32Array = PackedInt32Array([0,1,2,3, 4,5,6,7, 0,1,2,3])
static var _EB : PackedInt32Array = PackedInt32Array([1,2,3,0, 5,6,7,4, 4,5,6,7])

# ── Runtime state ─────────────────────────────────────────────────────────────
var tiles        : Dictionary = {}
var player_pos   : Vector3   = Vector3.ZERO
var update_timer : float     = 0.0

var terrain_material : StandardMaterial3D
var noise_warp  : FastNoiseLite
var noise_base  : FastNoiseLite
var noise_ridge : FastNoiseLite
var noise_detail: FastNoiseLite
var noise_cave  : FastNoiseLite

# ── Map / orbit camera ────────────────────────────────────────────────────────
var map_mode        : bool     = false
var map_camera      : Camera3D
var map_orbit_yaw   : float    = 0.0
var map_orbit_pitch : float    = -60.0
var map_orbit_dist  : float    = 400.0
var map_pivot       : Vector3  = Vector3.ZERO
var map_dragging    : bool     = false

var main_camera_ref : Camera3D
var dual_camera_ref : DualCameraView

# ── Space impostor ────────────────────────────────────────────────────────────
var planet_impostor : MeshInstance3D

# ── City flat zones ───────────────────────────────────────────────────────────
var _city_flat_zones : Array = []   # [[cx, cz, target_h, inner_r, outer_r], …]


# ═════════════════════════════════════════════════════════════════════════════
# Inner class – one voxel tile (3D density grid)
# ═════════════════════════════════════════════════════════════════════════════
class VoxelTile:
	var coord         : Vector2i
	var densities     : PackedFloat32Array   # (TILE_GRID+1)³-ish in XZ, (VOXEL_Y_SLICES+1) in Y
	var mesh_instance : MeshInstance3D
	var static_body   : StaticBody3D
	var current_lod   : int   = -1
	var max_height    : float = 0.0   # Approximate surface height for LOD
	var dirty         : bool  = true
	var origin        : Vector3   # World-space corner of this tile's density grid

	func _init(c: Vector2i) -> void:
		coord  = c
		origin = Vector3(c.x * PlanetTerrain.TILE_WORLD_SIZE,
						 PlanetTerrain.VOXEL_Y_BOTTOM,
						 c.y * PlanetTerrain.TILE_WORLD_SIZE)
		var nx := PlanetTerrain.TILE_GRID + 1
		var ny := PlanetTerrain.VOXEL_Y_SLICES + 1
		densities = PackedFloat32Array()
		densities.resize(nx * ny * nx)
		densities.fill(0.0)

	func didx(xi: int, yi: int, zi: int) -> int:
		var nx := PlanetTerrain.TILE_GRID + 1
		var ny := PlanetTerrain.VOXEL_Y_SLICES + 1
		xi = clampi(xi, 0, nx - 1)
		yi = clampi(yi, 0, ny - 1)
		zi = clampi(zi, 0, nx - 1)
		return xi + nx * (zi + nx * yi)

	func get_d(xi: int, yi: int, zi: int) -> float:
		return densities[didx(xi, yi, zi)]


# ═════════════════════════════════════════════════════════════════════════════
# Lifecycle
# ═════════════════════════════════════════════════════════════════════════════
func _ready() -> void:
	_setup_noise()
	_setup_material()
	_setup_map_camera()
	_create_water_sphere()
	_create_planet_impostor()


func _setup_noise() -> void:
	noise_warp = FastNoiseLite.new()
	noise_warp.noise_type         = FastNoiseLite.TYPE_PERLIN
	noise_warp.seed               = 7
	noise_warp.frequency          = 1.0
	noise_warp.fractal_type       = FastNoiseLite.FRACTAL_FBM
	noise_warp.fractal_octaves    = 4
	noise_warp.fractal_lacunarity = 2.0
	noise_warp.fractal_gain       = 0.5

	noise_base = FastNoiseLite.new()
	noise_base.noise_type         = FastNoiseLite.TYPE_PERLIN
	noise_base.seed               = 42
	noise_base.frequency          = 1.0
	noise_base.fractal_type       = FastNoiseLite.FRACTAL_FBM
	noise_base.fractal_octaves    = 6
	noise_base.fractal_lacunarity = 2.0
	noise_base.fractal_gain       = 0.5

	noise_ridge = FastNoiseLite.new()
	noise_ridge.noise_type                = FastNoiseLite.TYPE_PERLIN
	noise_ridge.seed                      = 13
	noise_ridge.frequency                 = 1.0
	noise_ridge.fractal_type              = FastNoiseLite.FRACTAL_RIDGED
	noise_ridge.fractal_octaves           = 6
	noise_ridge.fractal_lacunarity        = 2.1
	noise_ridge.fractal_gain              = 0.5
	noise_ridge.fractal_weighted_strength = 0.7

	noise_detail = FastNoiseLite.new()
	noise_detail.noise_type         = FastNoiseLite.TYPE_PERLIN
	noise_detail.seed               = 99
	noise_detail.frequency          = 1.0
	noise_detail.fractal_type       = FastNoiseLite.FRACTAL_FBM
	noise_detail.fractal_octaves    = 5
	noise_detail.fractal_lacunarity = 2.0
	noise_detail.fractal_gain       = 0.55

	# Cave noise: 3-D simplex for organic tunnels and chambers
	noise_cave = FastNoiseLite.new()
	noise_cave.noise_type         = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise_cave.seed               = 777
	noise_cave.frequency          = 1.0
	noise_cave.fractal_type       = FastNoiseLite.FRACTAL_FBM
	noise_cave.fractal_octaves    = 3
	noise_cave.fractal_lacunarity = 2.0
	noise_cave.fractal_gain       = 0.5


func _setup_material() -> void:
	terrain_material = StandardMaterial3D.new()
	terrain_material.vertex_color_use_as_albedo = true
	terrain_material.roughness     = 0.92
	terrain_material.metallic      = 0.02
	terrain_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	terrain_material.cull_mode     = BaseMaterial3D.CULL_DISABLED


func _setup_map_camera() -> void:
	map_camera         = Camera3D.new()
	map_camera.name    = "MapOrbitCamera"
	map_camera.fov     = 60.0
	map_camera.far     = 3000.0
	map_camera.current = false
	add_child(map_camera)


# ═════════════════════════════════════════════════════════════════════════════
# Per-frame
# ═════════════════════════════════════════════════════════════════════════════
func _process(delta: float) -> void:
	update_timer -= delta
	if update_timer <= 0.0:
		update_timer = UPDATE_INTERVAL
		_update_tiles()
	if map_mode:
		_update_map_camera()
	_update_impostor_uniforms()


func _update_impostor_uniforms() -> void:
	if not is_instance_valid(planet_impostor):
		return
	var mat := planet_impostor.material_override as ShaderMaterial
	if not mat:
		return
	var altitude : float = player_pos.distance_to(Vector3(0.0, -PLANET_RADIUS, 0.0)) - PLANET_RADIUS
	mat.set_shader_parameter("player_xz",      Vector2(player_pos.x, player_pos.z))
	mat.set_shader_parameter("player_altitude", altitude)
	mat.set_shader_parameter("fade_near",       UNLOAD_RANGE * 0.55)
	mat.set_shader_parameter("fade_far",        UNLOAD_RANGE * 0.90)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M:
			_toggle_map_mode()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_QUOTELEFT:
			var vp := get_viewport()
			vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED if vp.debug_draw == Viewport.DEBUG_DRAW_WIREFRAME else Viewport.DEBUG_DRAW_WIREFRAME
			get_viewport().set_input_as_handled()
			return

	if not map_mode and event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_carve_terrain()

	if map_mode:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			match mb.button_index:
				MOUSE_BUTTON_LEFT:      map_dragging = mb.pressed
				MOUSE_BUTTON_WHEEL_UP:  map_orbit_dist = max(40.0, map_orbit_dist * 0.88)
				MOUSE_BUTTON_WHEEL_DOWN:map_orbit_dist = min(2000.0, map_orbit_dist * 1.14)
		elif event is InputEventMouseMotion and map_dragging:
			var mm := event as InputEventMouseMotion
			map_orbit_yaw   -= mm.relative.x * 0.25
			map_orbit_pitch  = clamp(map_orbit_pitch - mm.relative.y * 0.20, -88.0, -5.0)


# ═════════════════════════════════════════════════════════════════════════════
# Map camera
# ═════════════════════════════════════════════════════════════════════════════
func _toggle_map_mode() -> void:
	map_mode = not map_mode
	if map_mode:
		map_pivot = player_pos
		_update_map_camera()
		map_camera.current = true
		if is_instance_valid(dual_camera_ref):
			dual_camera_ref.map_mode_active = true
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		map_camera.current = false
		if is_instance_valid(dual_camera_ref):
			dual_camera_ref.map_mode_active = false
		if is_instance_valid(main_camera_ref):
			main_camera_ref.current = true
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _update_map_camera() -> void:
	var yaw   := deg_to_rad(map_orbit_yaw)
	var pitch := deg_to_rad(map_orbit_pitch)
	map_camera.global_position = map_pivot + Vector3(
		map_orbit_dist * cos(pitch) * sin(yaw),
		map_orbit_dist * -sin(pitch),
		map_orbit_dist * cos(pitch) * cos(yaw))
	map_camera.look_at(map_pivot, Vector3.UP)


func _is_in_frustum(tc: Vector3) -> bool:
	if not is_instance_valid(main_camera_ref):
		return true
	for plane in main_camera_ref.get_frustum():
		if plane.distance_to(tc) < -TILE_WORLD_SIZE:
			return false
	return true


# ═════════════════════════════════════════════════════════════════════════════
# Tile streaming
# ═════════════════════════════════════════════════════════════════════════════
func _update_tiles() -> void:
	var altitude : float = player_pos.distance_to(Vector3(0.0, -PLANET_RADIUS, 0.0)) - PLANET_RADIUS
	if altitude > UNLOAD_RANGE * 2.0:
		return

	var px    := player_pos.x
	var pz    := player_pos.z
	var cx    := int(floor(px / TILE_WORLD_SIZE))
	var cz    := int(floor(pz / TILE_WORLD_SIZE))
	var max_r := int(ceil(UNLOAD_RANGE * HIGH_SPOT_EXTEND / TILE_WORLD_SIZE)) + 1

	var needed : Dictionary = {}

	for dz in range(-max_r, max_r + 1):
		for dx in range(-max_r, max_r + 1):
			var coord := Vector2i(cx + dx, cz + dz)
			var tc_x  := (coord.x + 0.5) * TILE_WORLD_SIZE
			var tc_z  := (coord.y + 0.5) * TILE_WORLD_SIZE
			var dist  := Vector2(px, pz).distance_to(Vector2(tc_x, tc_z))
			var extend := 1.0
			if coord in tiles:
				var t := tiles[coord] as VoxelTile
				if t.max_height >= HIGH_SPOT_THRESH:
					extend = HIGH_SPOT_EXTEND
			if dist > UNLOAD_RANGE * extend:
				continue
			var req_lod := LOD_RANGES.size() - 1
			for li in range(LOD_RANGES.size()):
				if dist <= LOD_RANGES[li] * extend:
					req_lod = li
					break
			needed[coord] = req_lod

	var to_remove : Array = []
	for coord in tiles:
		if not coord in needed:
			to_remove.append(coord)
	for coord in to_remove:
		_unload_tile(coord)

	for coord in needed:
		if coord in tiles:
			var t    := tiles[coord] as VoxelTile
			var rlod : int = needed[coord]
			if t.current_lod != rlod or t.dirty:
				_build_mesh(t, rlod)

	var to_load : Array = []
	for coord in needed:
		if not coord in tiles:
			to_load.append(coord)

	to_load.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var ca := Vector3((a.x + 0.5) * TILE_WORLD_SIZE, 0.0, (a.y + 0.5) * TILE_WORLD_SIZE)
		var cb := Vector3((b.x + 0.5) * TILE_WORLD_SIZE, 0.0, (b.y + 0.5) * TILE_WORLD_SIZE)
		var av := 1 if _is_in_frustum(ca) else 0
		var bv := 1 if _is_in_frustum(cb) else 0
		if av != bv: return av > bv
		return Vector2(px,pz).distance_squared_to(Vector2(ca.x,ca.z)) < \
			   Vector2(px,pz).distance_squared_to(Vector2(cb.x,cb.z))
	)

	var loaded := 0
	for coord in to_load:
		if loaded >= MAX_NEW_TILES:
			break
		_load_tile(coord, needed[coord])
		loaded += 1


func _load_tile(coord: Vector2i, lod: int) -> void:
	var t := VoxelTile.new(coord)
	tiles[coord] = t
	_gen_densities(t)
	_build_mesh(t, lod)


func _unload_tile(coord: Vector2i) -> void:
	var t := tiles[coord] as VoxelTile
	if is_instance_valid(t.mesh_instance): t.mesh_instance.queue_free()
	if is_instance_valid(t.static_body):   t.static_body.queue_free()
	tiles.erase(coord)


# ═════════════════════════════════════════════════════════════════════════════
# Density generation
# ═════════════════════════════════════════════════════════════════════════════
func _gen_densities(t: VoxelTile) -> void:
	var nx := TILE_GRID + 1
	var ny := VOXEL_Y_SLICES + 1

	# Pre-compute surface heights for each XZ point — avoids calling _surface_height
	# 45 times per column (once per Y slice), which was the main perf bottleneck.
	var surf_cache := PackedFloat32Array()
	surf_cache.resize(nx * nx)
	var mh := 0.0
	for zi in range(nx):
		for xi in range(nx):
			var wx := t.origin.x + xi * VERT_SPACING
			var wz := t.origin.z + zi * VERT_SPACING
			var sh : float = _surface_height(wx, wz)
			surf_cache[xi + nx * zi] = sh
			if sh > mh: mh = sh
	t.max_height = mh

	for yi in range(ny):
		var wy := t.origin.y + yi * VERT_SPACING
		for zi in range(nx):
			for xi in range(nx):
				var wx   := t.origin.x + xi * VERT_SPACING
				var wz   := t.origin.z + zi * VERT_SPACING
				var surf : float = surf_cache[xi + nx * zi]
				t.densities[t.didx(xi, yi, zi)] = _sample_density_at(wx, wy, wz, surf)
	t.dirty = false


## Positive density = solid, negative = air. Two isosurfaces are generated:
##   TOP    surface at y = surf            (terrain ground level)
##   BOTTOM surface at y = surf - SLAB_H   (visible underside, gives volume)
## The slab between them appears solid from any angle.
const SLAB_H : float = 64.0   # 4 voxels of apparent terrain thickness

func _sample_density_at(wx: float, wy: float, wz: float, surf: float) -> float:
	# top:  positive below surf, negative above
	# bot:  positive above (surf - SLAB_H), negative below
	var top : float = surf - wy
	var bot : float = wy - (surf - SLAB_H)

	# Cave carving only punches through the top surface; the bottom stays intact,
	# forming cave floors and keeping the slab visually closed from below.
	var depth_below : float = surf - wy
	if depth_below > 15.0:
		var cave  : float = noise_cave.get_noise_3d(wx * 0.006, wy * 0.009, wz * 0.006)
		var carve : float = maxf(0.0, cave - 0.28) * 120.0
		var taper : float = clampf((depth_below - 15.0) / 25.0, 0.0, 1.0)
		top -= carve * taper

	# Slab: solid where both boundaries are positive
	return minf(top, bot)


## Surface height at (wx, wz) — same domain-warped noise as before.
## Used as the isosurface reference level and by CityGenerator.
func _surface_height(wx: float, wz: float) -> float:
	# Spherical base
	var r2 := wx * wx + wz * wz
	if r2 >= PLANET_RADIUS * PLANET_RADIUS:
		return -PLANET_RADIUS
	var sphere_y : float = sqrt(PLANET_RADIUS * PLANET_RADIUS - r2) - PLANET_RADIUS

	# Domain warp
	const S_W1 := 0.00033
	var wx1 := wx + 250.0 * noise_warp.get_noise_2d(wx * S_W1,         wz * S_W1)
	var wz1 := wz + 250.0 * noise_warp.get_noise_2d(wx * S_W1 + 31.7,  wz * S_W1 + 17.3)
	const S_W2 := 0.00200
	var wx2 := wx1 + 50.0 * noise_warp.get_noise_2d(wx1 * S_W2 + 100.0, wz1 * S_W2 + 200.0)
	var wz2 := wz1 + 50.0 * noise_warp.get_noise_2d(wx1 * S_W2 + 300.0, wz1 * S_W2 + 400.0)

	var continent := noise_base.get_noise_2d(wx1 * 0.00033, wz1 * 0.00033)
	var plains    := (noise_base.get_noise_2d(wx2 * 0.00140 + 500.0, wz2 * 0.00140 + 900.0) + 1.0) * 0.5
	var ridge     : float = clampf(noise_ridge.get_noise_2d(wx2 * 0.00250, wz2 * 0.00250), 0.0, 1.0)
	ridge = sqrt(ridge) * ridge
	var fracture  : float = clampf(noise_ridge.get_noise_2d(wx2 * 0.0100 + 700.0, wz2 * 0.0100 + 800.0), 0.0, 1.0)
	fracture = fracture * fracture
	var d1 := noise_detail.get_noise_2d(wx * 0.033, wz * 0.033) * 0.045
	var d2 := noise_detail.get_noise_2d(wx * 0.100 + 111.1, wz * 0.100 + 222.2) * 0.015

	var ocean_depth   : float = clamp((-continent - 0.25) / 0.75, 0.0, 1.0)
	var mountain_mask : float = clamp((continent - 0.35) / 0.50, 0.0, 1.0)
	mountain_mask = mountain_mask * mountain_mask

	var ocean_h    := -(ocean_depth * 0.08 + 0.02)
	var plains_h   := plains * 0.10 + d1 + d2
	var mountain_h := ridge * 0.76 + fracture * 0.10 + d1 * 1.5 + d2
	var land_blend : float = clamp((continent + 0.25) / 0.40, 0.0, 1.0)
	land_blend = land_blend * land_blend
	var combined   : float = lerpf(ocean_h, lerpf(plains_h, mountain_h, mountain_mask), land_blend)

	# Spawn flat zone
	var dist_from_origin : float = sqrt(wx * wx + wz * wz)
	var flat_blend : float = clamp((dist_from_origin - FLAT_RADIUS) / 150.0, 0.0, 1.0)
	flat_blend = flat_blend * flat_blend

	# Use sphere_y (not 0.0) as the flat-zone baseline so the zone follows the
	# planet sphere surface. The water sphere is always |WATER_LEVEL| below
	# sphere_y everywhere, giving a constant 5 m gap. With the old 0.0 baseline
	# the gap grew to ~27 m at r=1500 m, so destroyed terrain sat above the
	# water sphere at the edges → player walked on water / varying submersion.
	var h : float = sphere_y + clampf(combined, -0.12, 1.0) * MAX_HEIGHT * flat_blend

	# City flat zones
	for zone in _city_flat_zones:
		var cdx   : float = wx - zone[0]
		var cdz   : float = wz - zone[1]
		var cdist : float = sqrt(cdx * cdx + cdz * cdz)
		if cdist < zone[4]:
			var blend := 1.0 - smoothstep(zone[3], zone[4], cdist)
			h = lerp(h, zone[2] as float, blend)

	return h


func set_city_flat_zones(zones: Array) -> void:
	_city_flat_zones.clear()
	for z in zones:
		var nat_h := _surface_height(z[0], z[1])
		_city_flat_zones.append([z[0], z[1], nat_h, z[2], z[3]])


func sample_height_at(wx: float, wz: float) -> float:
	return _surface_height(wx, wz)


# ═════════════════════════════════════════════════════════════════════════════
# Marching Cubes mesh building
# ═════════════════════════════════════════════════════════════════════════════
func _build_mesh(t: VoxelTile, lod: int) -> void:
	if is_instance_valid(t.mesh_instance): t.mesh_instance.queue_free()
	if is_instance_valid(t.static_body):   t.static_body.queue_free()
	t.mesh_instance = null
	t.static_body   = null

	var stride : int = LOD_STEPS[lod]
	@warning_ignore("integer_division")
	var nx : int = TILE_GRID / stride
	@warning_ignore("integer_division")
	var ny : int = VOXEL_Y_SLICES / stride
	@warning_ignore("integer_division")
	var nz : int = TILE_GRID / stride

	var verts  := PackedVector3Array()
	var norms  := PackedVector3Array()
	var colors := PackedColorArray()

	for cy in range(ny):
		for cz in range(nz):
			for cx in range(nx):
				_march_cube(t, cx * stride, cy * stride, cz * stride,
							stride, verts, norms, colors)

	if verts.is_empty():
		t.current_lod = lod
		t.dirty       = false
		return

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR]  = colors

	var amesh := ArrayMesh.new()
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	amesh.surface_set_material(0, terrain_material)

	t.mesh_instance          = MeshInstance3D.new()
	t.mesh_instance.mesh     = amesh
	t.mesh_instance.position = t.origin
	t.mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if lod <= 1 \
								  else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(t.mesh_instance)

	# Collision only for close tiles — distant LODs are never walked on
	if lod <= 1:
		t.static_body          = StaticBody3D.new()
		t.static_body.position = t.origin
		add_child(t.static_body)
		if not verts.is_empty():
			var cs    := CollisionShape3D.new()
			var shape := ConcavePolygonShape3D.new()
			shape.backface_collision = true
			shape.set_faces(verts)
			cs.shape = shape
			t.static_body.add_child(cs)

	t.current_lod = lod
	t.dirty       = false


func _march_cube(t: VoxelTile, xi: int, yi: int, zi: int, stride: int,
				 verts: PackedVector3Array, norms: PackedVector3Array,
				 colors: PackedColorArray) -> void:
	var s := stride
	var sp := float(s) * VERT_SPACING

	# Sample 8 corner densities and build case index
	var vals : PackedFloat32Array = PackedFloat32Array()
	vals.resize(8)
	var case_idx := 0
	for c in range(8):
		var d := t.get_d(xi + _CO_X[c] * s, yi + _CO_Y[c] * s, zi + _CO_Z[c] * s)
		vals[c] = d
		if d > 0.0:
			case_idx |= (1 << c)

	if case_idx == 0 or case_idx == 255:
		return

	var ef := EDGE_TABLE[case_idx]
	if ef == 0:
		return

	# Interpolated vertex positions along each of the 12 edges
	var ev : Array[Vector3] = []
	ev.resize(12)
	for e in range(12):
		if ef & (1 << e):
			var a   := _EA[e]
			var b   := _EB[e]
			var da  := vals[a]
			var db  := vals[b]
			var fac := da / (da - db)
			var ax  := _CO_X[a] * sp
			var ay  := _CO_Y[a] * sp
			var az  := _CO_Z[a] * sp
			var bxf := _CO_X[b] * sp
			var byf := _CO_Y[b] * sp
			var bzf := _CO_Z[b] * sp
			ev[e] = Vector3(ax + fac * (bxf - ax),
							ay + fac * (byf - ay),
							az + fac * (bzf - az))

	# Base position of this cube in tile-local space
	var bx := float(xi) * VERT_SPACING
	var by := float(yi) * VERT_SPACING
	var bz := float(zi) * VERT_SPACING
	var base := Vector3(bx, by, bz)

	# Emit triangles
	var ti := case_idx * 16
	var i  := 0
	while i < 15 and TRI_TABLE[ti + i] != -1:
		var p0 : Vector3 = base + ev[TRI_TABLE[ti + i]]
		var p1 : Vector3 = base + ev[TRI_TABLE[ti + i + 1]]
		var p2 : Vector3 = base + ev[TRI_TABLE[ti + i + 2]]
		var n_raw : Vector3 = (p2 - p0).cross(p1 - p0)
		if n_raw.length_squared() < 1e-10:
			i += 3
			continue   # skip degenerate triangle
		var n  : Vector3 = n_raw.normalized()
		# Visual normal: always face "outward" (upward hemisphere) so the slab underside
		# isn't black.  Collision uses the winding in verts[], not these stored normals.
		var n_vis : Vector3 = n if n.y >= 0.0 else -n
		var wh : float   = t.origin.y + p0.y
		var col := _terrain_color(wh, n_vis)
		verts.append(p0); verts.append(p1); verts.append(p2)
		norms.append(n_vis);  norms.append(n_vis);  norms.append(n_vis)
		colors.append(col); colors.append(col); colors.append(col)
		i += 3


func _terrain_color(world_y: float, normal: Vector3) -> Color:
	var t     : float = clamp(world_y / MAX_HEIGHT, -0.15, 1.0)
	var slope : float = 1.0 - clamp(normal.dot(Vector3.UP), 0.0, 1.0)

	var hc : Color
	if t < -0.04:
		hc = Color(0.08, 0.12, 0.22)
	elif t < 0.0:
		hc = Color(0.08, 0.12, 0.22).lerp(Color(0.18, 0.18, 0.16), (t + 0.04) / 0.04)
	elif t < 0.06:
		hc = Color(0.18, 0.18, 0.16).lerp(Color(0.48, 0.38, 0.22), t / 0.06)
	elif t < 0.25:
		hc = Color(0.48, 0.38, 0.22).lerp(Color(0.42, 0.30, 0.16), (t - 0.06) / 0.19)
	elif t < 0.55:
		hc = Color(0.42, 0.30, 0.16).lerp(Color(0.68, 0.54, 0.36), (t - 0.25) / 0.30)
	else:
		hc = Color(0.68, 0.54, 0.36).lerp(Color(0.80, 0.74, 0.62), (t - 0.55) / 0.45)

	return hc.lerp(Color(0.38, 0.34, 0.30), clamp((slope - 0.25) / 0.40, 0.0, 1.0) * 0.65)


# ═════════════════════════════════════════════════════════════════════════════
# Terrain carving (right-click)
# ═════════════════════════════════════════════════════════════════════════════
func _carve_terrain() -> void:
	if not is_instance_valid(main_camera_ref):
		return
	var from := main_camera_ref.global_position
	var to   := from + (-main_camera_ref.global_transform.basis.z) * 30.0
	var hit  := get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(from, to))
	if hit.is_empty():
		return

	var hp    : Vector3 = hit["position"]
	# cr must exceed VERT_SPACING/2 (= 8) so the sphere always reaches voxel corners.
	# In flat zones the surface sits exactly between two voxel layers, so a radius < 8
	# would never touch any corner and produce no effect.
	var cr    := VERT_SPACING * 1.5   # = 24.0
	var depth := 5.0
	var dirty : Dictionary = {}

	var tile_r := int(ceil(cr / TILE_WORLD_SIZE)) + 1
	var btc    := Vector2i(int(floor(hp.x / TILE_WORLD_SIZE)),
						   int(floor(hp.z / TILE_WORLD_SIZE)))

	for dtz in range(-tile_r, tile_r + 1):
		for dtx in range(-tile_r, tile_r + 1):
			var tc := Vector2i(btc.x + dtx, btc.y + dtz)
			if not tc in tiles:
				continue
			var tile := tiles[tc] as VoxelTile
			var nx   := TILE_GRID + 1
			var ny   := VOXEL_Y_SLICES + 1
			for yi in range(ny):
				for zi in range(nx):
					for xi in range(nx):
						var vx := tile.origin.x + xi * VERT_SPACING
						var vy := tile.origin.y + yi * VERT_SPACING
						var vz := tile.origin.z + zi * VERT_SPACING
						var d  := Vector3(vx - hp.x, vy - hp.y, vz - hp.z).length()
						if d < cr:
							var f := 1.0 - d / cr
							tile.densities[tile.didx(xi, yi, zi)] -= f * f * depth
							dirty[tc] = true

	for tc in dirty:
		_build_mesh(tiles[tc] as VoxelTile, 0)


# ═════════════════════════════════════════════════════════════════════════════
# Water sphere
# ═════════════════════════════════════════════════════════════════════════════
static func water_surface_y(wx: float, wz: float) -> float:
	var water_r : float = PLANET_RADIUS + WATER_LEVEL
	var r2 : float = wx * wx + wz * wz
	if r2 >= water_r * water_r:
		return -PLANET_RADIUS
	return sqrt(water_r * water_r - r2) - PLANET_RADIUS


func _create_water_sphere() -> void:
	var radius : float = PLANET_RADIUS + WATER_LEVEL
	# Use a BoxMesh as a minimal proxy (12 triangles) — the ray-sphere shader computes
	# the exact mathematical sphere surface per-fragment, so proxy geometry only needs
	# to cover the right screen pixels.  A cube of side 2×radius fully encloses the
	# sphere and avoids all tessellation / midpoint-sag issues.
	var box := BoxMesh.new()
	box.size = Vector3(radius * 2.0, radius * 2.0, radius * 2.0)

	# Ray-sphere shader: each fragment ray-casts to the exact mathematical sphere so
	# the visible water surface is pixel-perfect regardless of proxy geometry.
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
// depth_draw_always so the explicit DEPTH write below takes effect even in the
// transparent pass.  Without this the box-proxy face depth (not the sphere
// surface depth) would be used for occlusion, letting water bleed over terrain.
render_mode blend_mix, depth_draw_always, cull_disabled;

uniform vec3  sphere_center;
uniform float sphere_radius;

varying vec3 world_pos;

void vertex() {
    world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    vec3  cam = INV_VIEW_MATRIX[3].xyz;
    vec3  d   = normalize(world_pos - cam);
    vec3  oc  = cam - sphere_center;
    float b   = dot(oc, d);
    float c   = dot(oc, oc) - sphere_radius * sphere_radius;
    float h   = b * b - c;
    if (h < 0.0) discard;

    float sh = sqrt(h);
    float t;

    if (c < 0.0) {
        // Camera is inside the sphere (underwater) — render the far exit intersection.
        // All sphere polygons appear back-facing from inside, FRONT_FACING = false.
        t = -b + sh;
    } else {
        // Camera is outside — render the near entry intersection.
        // Discard back-face fragments (far hemisphere) to avoid double-blending.
        if (!FRONT_FACING) discard;
        t = -b - sh;
    }
    if (t <= 0.0) discard;

    vec3 hit = cam + t * d;
    vec3 N   = normalize(hit - sphere_center);

    // Write the sphere-surface depth so terrain closer than the water surface
    // correctly occludes it via the depth test.  Without this, the proxy box
    // face depth is used, which differs from the sphere surface and causes
    // water to render over land (or land to show through shallow water).
    vec4 clip_hit = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(hit, 1.0));
    DEPTH = clip_hit.z / clip_hit.w;

    ALBEDO    = vec3(0.06, 0.22, 0.52);
    ALPHA     = 0.70;
    NORMAL    = normalize(mat3(VIEW_MATRIX) * N);
    ROUGHNESS = 0.04;
    METALLIC  = 0.15;
}
"""

	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("sphere_center", Vector3(0.0, -PLANET_RADIUS, 0.0))
	mat.set_shader_parameter("sphere_radius", radius)

	var mi := MeshInstance3D.new()
	mi.name              = "WaterSphere"
	mi.mesh              = box
	mi.material_override = mat
	mi.position          = Vector3(0.0, -PLANET_RADIUS, 0.0)
	mi.cast_shadow       = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


# ═════════════════════════════════════════════════════════════════════════════
# Planet impostor (visible from orbit)
# ═════════════════════════════════════════════════════════════════════════════
func _create_planet_impostor() -> void:
	var radius : float = PLANET_RADIUS - 10.0
	var sphere := SphereMesh.new()
	sphere.radius          = radius
	sphere.height          = radius * 2.0
	sphere.radial_segments = 180
	sphere.rings           = 90

	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode cull_back, diffuse_lambert, blend_mix, depth_draw_never;
uniform sampler2D noise_tex : hint_default_white, repeat_enable;
uniform vec2  player_xz       = vec2(0.0);
uniform float player_altitude = 0.0;
uniform float fade_near       = 3500.0;
uniform float fade_far        = 6000.0;
varying vec3 local_pos;
void vertex() { local_pos = VERTEX; }
void fragment() {
	vec3 n = normalize(local_pos);
	vec3 w = pow(abs(n), vec3(6.0));
	w /= w.x + w.y + w.z;
	float s_x = texture(noise_tex, n.yz * 0.45).r * 0.7 + texture(noise_tex, n.yz * 1.80 + 0.31).r * 0.3;
	float s_y = texture(noise_tex, n.xz * 0.45).r * 0.7 + texture(noise_tex, n.xz * 1.80 + 0.47).r * 0.3;
	float s_z = texture(noise_tex, n.xy * 0.45).r * 0.7 + texture(noise_tex, n.xy * 1.80 + 0.63).r * 0.3;
	float land = s_x * w.x + s_y * w.y + s_z * w.z;
	float t_coast = smoothstep(0.46, 0.56, land);
	float t_mount = smoothstep(0.70, 0.82, land);
	float t_polar = smoothstep(0.76, 0.93, abs(n.y));
	vec3 col = mix(vec3(0.05, 0.20, 0.50), vec3(0.16, 0.44, 0.11), t_coast);
	col = mix(col, vec3(0.40, 0.36, 0.22), t_mount);
	col = mix(col, vec3(0.88, 0.93, 1.00), t_polar);
	ALBEDO = col; ROUGHNESS = mix(0.04, 0.88, t_coast); METALLIC = 0.0;
	float dist_xz = length(local_pos.xz - player_xz);
	float terrain_alpha = smoothstep(fade_near, fade_far, dist_xz);
	float alt_t = clamp(player_altitude / 8000.0, 0.0, 1.0);
	alt_t = alt_t * alt_t;
	ALPHA = mix(terrain_alpha, 1.0, alt_t);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var noise_tex := NoiseTexture2D.new()
	noise_tex.width    = 512
	noise_tex.height   = 512
	noise_tex.seamless = true
	var fn := FastNoiseLite.new()
	fn.noise_type      = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fn.seed            = noise_base.seed if noise_base else 42
	fn.frequency       = 0.6
	fn.fractal_type    = FastNoiseLite.FRACTAL_FBM
	fn.fractal_octaves = 6
	noise_tex.noise = fn
	mat.set_shader_parameter("noise_tex", noise_tex)

	planet_impostor                  = MeshInstance3D.new()
	planet_impostor.name             = "PlanetImpostor"
	planet_impostor.mesh             = sphere
	planet_impostor.material_override= mat
	planet_impostor.position         = Vector3(0.0, -PLANET_RADIUS, 0.0)
	planet_impostor.cast_shadow      = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(planet_impostor)
