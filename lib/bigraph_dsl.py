import capnp, pathlib, json
capnp.remove_import_hook()
bigraph_capnp = capnp.load(str(pathlib.Path(__file__).with_name("bigraph_rpc.capnp")))
import pathlib
import logging

_ASSETS_DIR = pathlib.Path(__file__).parent.parent / "assets"
_SCHEMA_PATH = _ASSETS_DIR / "schema.json"

def load_schema():
    if _SCHEMA_PATH.exists():
        with open(_SCHEMA_PATH) as f:
            return json.load(f)
    return {}

CONTROL_SCHEMA = load_schema()

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)-8s %(message)s",
    datefmt="%H:%M:%S")
logger = logging.getLogger(__name__)

def validate_properties(node_type: str, props: dict):
    """Ensure props conform to schema for the given node type."""
    schema = CONTROL_SCHEMA.get("types", {}).get(node_type, {}).get("properties", {})
    
    if not schema and props:
        # If no schema defined for this type, allow any properties
        logger.warning(f"No schema defined for type '{node_type}', skipping validation")
        return
        
    for k, v in props.items():
        if k not in schema:
            raise ValueError(f"Invalid property '{k}' for type '{node_type}'")

        meta = schema[k]
        t = meta["type"]

        if t == "int":
            if not isinstance(v, int):
                raise TypeError(f"Property '{k}' expects int, got {type(v)}")
            r = meta.get("range")
            if r and not (r[0] <= v <= r[1]):
                raise ValueError(f"Value {v} out of range {r} for '{k}'")
        elif t == "bool":
            if not isinstance(v, bool):
                raise TypeError(f"Property '{k}' expects bool, got {type(v)}")
        elif t == "string":
            if not isinstance(v, str):
                raise TypeError(f"Property '{k}' expects string, got {type(v)}")
            allowed = meta.get("values")
            if allowed is not None and v not in allowed:
                raise ValueError(f"'{v}' not in allowed values {allowed} for '{k}'")
        elif t == "color":
            if not (isinstance(v, tuple) and len(v) == 3 and all(isinstance(c, int) and 0 <= c <= 255 for c in v)):
                raise TypeError(f"Property '{k}' expects color (R,G,B), got {v}")
        elif t == "float":
            if not isinstance(v, float):
                raise TypeError(f"Property '{k}' expects float, got {type(v)}")
            
# ------------------------------------------------------------------ #
class Node:
    def __init__(self, control, id, arity=0, *,
                 children=None, ports=None, properties=None, 
                 name=None, node_type=None):
        self.control    = control
        self.id         = id
        self.arity      = arity
        self.children   = children or []
        self.ports      = ports or [id * 1000 + i for i in range(arity)]
        
        # New fields for better matching
        self.name = name or f"node_{id}"  # Default name
        self.node_type = node_type or control  # Default type is control name

        self.properties = {}
        if properties:
            # validate_properties(self.node_type, properties)
            self.properties.update(properties)

    def to_dict(self):
        return {
            "control": self.control,
            "id": self.id,
            "name": self.name,
            "type": self.node_type,
            "properties": self.properties,
            "children": [child.to_dict() for child in self.children]
        }
    
    def __repr__(self):
        return f"Node({self.id}, {self.control}, name={self.name}, type={self.node_type})"

# ------------------------------------------------------------------ #
class Bigraph:
    def __init__(self, nodes=None, *, sites=0, names=None):
        self.nodes = nodes or []
        self.sites = sites
        self.names = names or []

    # --- helpers ---------------------------------------------------- #
    def _flatten_nodes(self):
        flat = []

        def visit(node, parent):
            flat.append((node, parent))
            for ch in node.children:
                visit(ch, node.id)

        for r in self.nodes:
            visit(r, -1)
        return flat

    # ---------------------------------------------------------------- #
    def to_capnp(self):
        bg = bigraph_capnp.Bigraph.new_message()
        flat_nodes = self._flatten_nodes()
        nodes_msg = bg.init("nodes", len(flat_nodes))

        for i, (node, parent) in enumerate(flat_nodes):
            n = nodes_msg[i]
            n.id      = node.id
            n.control = node.control
            n.arity   = node.arity
            n.parent  = parent
            n.name    = node.name
            n.type    = node.node_type

            # ports
            ports = n.init("ports", len(node.ports))
            for j,p in enumerate(node.ports): ports[j] = p

            # properties
            if node.properties:
                props = n.init("properties", len(node.properties))
                for j,(k,v) in enumerate(node.properties.items()):
                    prop = props[j]
                    prop.key = k
                    if   isinstance(v,bool):   prop.value.boolVal   = v
                    elif isinstance(v,int):    prop.value.intVal    = v
                    elif isinstance(v,float):  prop.value.floatVal  = v
                    elif isinstance(v,str):    prop.value.stringVal = v
                    elif (isinstance(v,tuple) and len(v)==3):
                        prop.value.colorVal.r, prop.value.colorVal.g, prop.value.colorVal.b = v

        bg.siteCount = self.sites
        names = bg.init("names", len(self.names))
        for i,nm in enumerate(self.names): names[i] = nm
        return bg

    @classmethod
    def load(cls, path):
        with open(path, "rb") as f:
            msg = bigraph_capnp.Bigraph.read(f)
        nodes_raw = msg.nodes
        id_to_node = {}
        children_map = {}
        for n in nodes_raw:
            # Extract properties
            props = {}
            for p in n.properties:
                key = p.key
                value = p.value
                which = value.which()
                if which == 'boolVal':
                    props[key] = value.boolVal
                elif which == 'intVal':
                    props[key] = value.intVal
                elif which == 'floatVal':
                    props[key] = value.floatVal
                elif which == 'stringVal':
                    props[key] = value.stringVal
                elif which == 'colorVal':
                    props[key] = (value.colorVal.r, value.colorVal.g, value.colorVal.b)
                    
            node = Node(
                control=n.control,
                id=n.id,
                arity=n.arity,
                ports=[p for p in n.ports],
                properties=props,
                name=n.name,
                node_type=n.type
            )
            id_to_node[n.id] = node
            parent = n.parent
            children_map.setdefault(parent, []).append(n.id)

        for parent_id, child_ids in children_map.items():
            if parent_id != -1:
                parent = id_to_node[parent_id]
                for cid in child_ids:
                    parent.children.append(id_to_node[cid])

        root_nodes = [id_to_node[nid] for nid in children_map.get(-1, [])]
        return Bigraph(nodes=root_nodes, sites=msg.siteCount, names=[n for n in msg.names])
    
    def add_node(self, node, parent=None):
        """Add a node to the bigraph. If parent is None, it becomes a root."""
        if parent is None:
            self.nodes.append(node)
        else:
            parent.children.append(node)

    def find_node_by_name(self, name):
        """Find the first node whose name matches."""
        def search(nodes):
            for n in nodes:
                if n.name == name:
                    return n
                found = search(n.children)
                if found:
                    return found
            return None
        return search(self.nodes)
    
    def find_nodes_by_type(self, node_type):
        """Find all nodes of a given type."""
        results = []
        def search(nodes):
            for n in nodes:
                if n.node_type == node_type:
                    results.append(n)
                search(n.children)
        search(self.nodes)
        return results

    def find_node_by_control(self, control):
        """Find the first node whose control name matches."""
        def search(nodes):
            for n in nodes:
                if n.control == control:
                    return n
                found = search(n.children)
                if found:
                    return found
            return None
        return search(self.nodes)

    def to_dict(self):
        return {
            "sites": self.sites,
            "names": self.names,
            "nodes": [node.to_dict() for node in self.nodes]
        }
    
    # ---------------------------------------------------------------- #
    def save(self, path):
        with open(path, "wb") as fp:
            self.to_capnp().write(fp)
        print(f"Saved bigraph → {path}")

# ------------------------------------------------------------------ #
class Rule:
    def __init__(self, name, redex:Bigraph, reactum:Bigraph):
        self.name    = name

        def validate_all(bigraph):
            def walk(nodes):
                for n in nodes:
                    # validate_properties(n.node_type, n.properties)
                    walk(n.children)
            walk(bigraph.nodes)

        validate_all(redex)
        validate_all(reactum)

        self.redex   = redex
        self.reactum = reactum

    def to_capnp(self):
        r = bigraph_capnp.Rule.new_message()
        r.name    = self.name
        r.redex   = self.redex.to_capnp()
        r.reactum = self.reactum.to_capnp()
        return r

    def save(self, path):
        with open(path,"wb") as fp: self.to_capnp().write(fp)
        print(f"Saved rule '{self.name}' → {path}")