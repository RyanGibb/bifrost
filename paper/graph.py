import sys
import pathlib
sys.path.append(str(pathlib.Path(__file__).parent.parent / "lib"))
from bigraph_dsl import Bigraph, Node

def Level(id, idx, label=None, children=None):
    return Node("Level", id=id, name=f"Level {idx}",
                node_type="Level",
                properties={"level_index": idx, "label": label or f"{'G' if idx==0 else ('F' if idx==1 else 'S')}"},
                children=children or [])

def Zone(id, floor_label, wing, children=None):
    return Node("Zone", id=id, name=f"{floor_label}_{wing}", node_type="Zone",
                properties={"floor": floor_label, "wing": wing}, children=children or [])

def Room(id, code, kind="Room", props=None):
    props = props or {}
    # infer floor/wing from code where possible (e.g., GE03 => G/E)
    floor = {"G":"Ground","F":"First","S":"Second"}.get(code[0], "Unknown")
    wing_map = {"N":"North","S":"South","E":"East","W":"West","C":"Centre"}
    wing = wing_map.get(code[1], "Unknown") if len(code) > 1 else "Unknown"
    base = {"code": code, "floor": floor, "wing": wing, "type": kind}
    base.update(props)
    return Node("Room", id=id, name=code, node_type="Room", properties=base)

def Corridor(id, name, floor_label):
    return Node("Corridor", id=id, name=name, node_type="Corridor",
                properties={"name": name, "floor": floor_label})

def Vertical(id, name, vtype):
    return Node(vtype, id=id, name=name, node_type=vtype, properties={"type": vtype})

def Toilet(id, code, gender=None, disabled=False):
    meta = {"code": code, "type": "Toilet"}
    if gender: meta["gender"] = gender
    if disabled: meta["disabled"] = True
    return Node("Room", id=id, name=code, node_type="Room", properties=meta)

# --- DATA (transcribed from PDFs; contiguous ranges expanded at runtime) ---

# Helpers to expand numeric sequences with zero padding where present
def seq(prefix, nums):
    return [f"{prefix}{n:02d}" if isinstance(n, int) and n < 100 else f"{prefix}{n}" for n in nums]

# Ground floor sets (from gates1.pdf)
GE = seq("GE", [1,3,5,7,9,10,12,14,16,18,20,22,23,21,19,17,15,13,11])  # includes reverse cluster from PDF
GW = seq("GW", [1,2,3,4,5,6,8,9,10,11,12,13,14,15,21,22,23,24,26,27,28,29,30,31,32])  # visible in PDF text
GN = seq("GN", [2,4,6,9,13,15,16,17,18,19,20])  # subset legible
GC = seq("GC", [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,18,20,22,27,29,31,33])  # centre offices/rooms
GS = seq("GS", [1,3,5,7,9,11,13,14,16,18,20,22,24,31,33,35,37,17,19])  # south run

GROUND_SPECIALS = [
    ("Reception", "Reception"),
    ("Foyer 1", "Foyer_1"),
    ("Foyer 2", "Foyer_2"),
    ("The Street", "The_Street"),
    ("Student Entrance", "Student_Entrance"),
    ("Student Hangout", "Student_Hangout"),
    ("Admin Student Point", "Admin_Student_Point"),
    ("Library", "N Library"),
    ("Canteen Area", "Canteen_Area"),
    ("Lecture Theatre 1", "Lecture_Theatre_1"),
    ("Lecture Theatre 2", "Lecture_Theatre_2"),
    ("Cycle Compound", "Cycle_Compound"),
    ("Car Park", "Car_Park"),
    ("Fire Assembly", "Fire_Assembly"),
]

GROUND_TOILETS = [
    # from legends: "Toilets Male", "Toilets Female", plus Disabled (T/D)
    ("GS09", "Female", False),
    ("GS15", "Male", False),
    ("T/D_G_1", None, True),
    ("T/D_G_2", None, True),
]

# First floor sets (from gates2.pdf)
FE = seq("FE", [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,17,18,19,20,21,22,23,24,25])  # includes FE24/25
FW = seq("FW", [1,3,4,5,6,7,8,9,10,11,13,14,15,16,17,18,19,20,21,22,24,25,26,27,28,29,30])  # west run
FN = seq("FN", [1,2,4,5,6,7,8,9,10,11,12,13,14,15,16,17,19,21,28,30,32,34])  # north cluster
FC = seq("FC", [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,20,22,24,29,31,33,35])  # centre
FS = seq("FS", [1,2,3,4,5,6,7,8,9,10,12,13,14,15,16,17,18,20,22,24,26,29,31,33,35])  # south

FIRST_SPECIALS = [
    ("Lecture Theatre 1", "Lecture_Theatre_1"),
    ("Lecture Theatre 2", "Lecture_Theatre_2"),
]

FIRST_TOILETS = [
    ("T_F_1", None, False),
    ("T_F_2", None, False),
    ("T/D_F_1", None, True),
]

# Second floor sets (from gates3.pdf)
SE = seq("SE", [1,2,4,5,6,9,12,13,14,15,17,18,21,22,23,25])  # east
SW = seq("SW", [0,1,2,3,4,5,9,10,11,12,13,19,20,21])  # west includes SW00 on the plan
SN = seq("SN", [1,2,3,4,5,6,8,9,10,11,12,13,15,16,17,21,25,27,28,30,31,32,34])  # north
SC = seq("SC", [1,2,3,4,6,7,8,10,11,12,14,17,18,20,22,24,26,28,29,30,31,32,33,35])  # centre
SS = seq("SS", [1,2,3,4,5,6,8,9,10,11,12,13,14,15,16,17,18,20,22,24,26,28,29,31,33,35])  # south

SECOND_TOILETS = [
    ("T_S_1", None, False),
    ("T_S_2", None, False),
    ("T/D_S_1", None, True),
    ("T/D_S_2", None, True),
]

# --- BUILD GRAPH ---

gid = 10_000_000  # synthetic id seed
def next_id():
    global gid
    gid += 1
    return gid

def rooms_as_nodes(codes):
    return [Room(next_id(), c) for c in codes]

def make_ground():
    floor_label = "Ground"
    # Corridors & specials
    specials = [
        Corridor(next_id(), "The Street", floor_label),
        Room(next_id(), "Reception", "Reception"),
        Room(next_id(), "Foyer 1", "Foyer"),
        Room(next_id(), "Foyer 2", "Foyer"),
        Room(next_id(), "Student Entrance", "Entrance"),
        Room(next_id(), "Student Hangout", "Common_Area"),
        Room(next_id(), "Admin Student Point", "Admin"),
        Room(next_id(), "N Library", "Library"),
        Room(next_id(), "Canteen Area", "Canteen"),
        Room(next_id(), "Lecture Theatre 1", "Lecture_Theatre"),
        Room(next_id(), "Lecture Theatre 2", "Lecture_Theatre"),
        Room(next_id(), "Cycle Compound", "Exterior"),
        Room(next_id(), "Car Park", "Exterior"),
        Room(next_id(), "Fire Assembly", "Exterior"),
        Vertical(next_id(), "Lift_G_A", "Lift"),
        Vertical(next_id(), "Lift_G_B", "Lift"),
    ]
    toilets = [
        Toilet(next_id(), code, gender, disabled)
        for (code, gender, disabled) in GROUND_TOILETS
    ]
    zones = [
        Zone(next_id(), "Ground", "North",   rooms_as_nodes(GN)),
        Zone(next_id(), "Ground", "East",    rooms_as_nodes(GE)),
        Zone(next_id(), "Ground", "West",    rooms_as_nodes(GW)),
        Zone(next_id(), "Ground", "Centre",  rooms_as_nodes(GC)),
        Zone(next_id(), "Ground", "South",   rooms_as_nodes(GS)),
    ]
    return Level(next_id(), 0, "G",
                 children=specials + toilets + zones)

def make_first():
    floor_label = "First"
    specials = [
        Corridor(next_id(), "The Street", floor_label),
        Room(next_id(), "Lecture Theatre 1", "Lecture_Theatre"),
        Room(next_id(), "Lecture Theatre 2", "Lecture_Theatre"),
        Vertical(next_id(), "Lift_F_A", "Lift"),
        Vertical(next_id(), "Lift_F_B", "Lift"),
    ]
    toilets = [Toilet(next_id(), code, gender, disabled)
               for (code, gender, disabled) in FIRST_TOILETS]

    rooms_FN = rooms_as_nodes(FN)
    rooms_FE = rooms_as_nodes(FE)
    rooms_FW = rooms_as_nodes(FW)  
    rooms_FC = rooms_as_nodes(FC)
    rooms_FS = rooms_as_nodes(FS)

    try:
        fw15 = next(r for r in rooms_FW
                    if (r.properties or {}).get("code") == "FW15" or r.name == "FW15")
    except StopIteration:
        raise RuntimeError("FW15 not found in FW list — check the FW codes set")

    stt_node = Node("STT",
                    id=next_id(),
                    name="stt_fw15",
                    node_type="STT",
                    properties={"active": False, "lang": "en"})
    fw15.children.append(stt_node)

    zones = [
        Zone(next_id(), "First", "North",  rooms_FN),
        Zone(next_id(), "First", "East",   rooms_FE),
        Zone(next_id(), "First", "West",   rooms_FW),  
        Zone(next_id(), "First", "Centre", rooms_FC),
        Zone(next_id(), "First", "South",  rooms_FS),
    ]
    return Level(next_id(), 1, "F",
                 children=specials + toilets + zones)

def make_second():
    floor_label = "Second"
    specials = [
        Corridor(next_id(), "The Street", floor_label),
        Vertical(next_id(), "Lift_S_A", "Lift"),
        Vertical(next_id(), "Lift_S_B", "Lift"),
    ]
    toilets = [Toilet(next_id(), code, gender, disabled)
               for (code, gender, disabled) in SECOND_TOILETS]
    zones = [
        Zone(next_id(), "Second", "North",  rooms_as_nodes(SN)),
        Zone(next_id(), "Second", "East",   rooms_as_nodes(SE)),
        Zone(next_id(), "Second", "West",   rooms_as_nodes(SW)),
        Zone(next_id(), "Second", "Centre", rooms_as_nodes(SC)),
        Zone(next_id(), "Second", "South",  rooms_as_nodes(SS)),
    ]
    return Level(next_id(), 2, "S",
                 children=specials + toilets + zones)

master = Bigraph([
    Node("Building",
         id=9_999_999,
         name="William Gates Building",
         node_type="Building",
         properties={
            "name": "William Gates Building",
            "addr:city": "Cambridge",
            "addr:street": "JJ Thomson Avenue",
            "addr:housenumber": "15",
            "addr:postcode": "CB3 0FD",
         },
         children=[
            make_ground(),
            make_first(),
            make_second(),
         ]),
])

# persist
master.save("william_gates_building.capnp")
print("Saved to william_gates_building.capnp")
