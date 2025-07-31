import capnp, pathlib
capnp.remove_import_hook()
bigraph_capnp = capnp.load(str(pathlib.Path(__file__).with_name("bigraph.capnp")))

# ------------------------------------------------------------------ #
class Node:
    def __init__(self, control, id, arity=0, *,
                 children=None, ports=None, properties=None, unique_id=None):
        self.control    = control
        self.id         = id
        self.arity      = arity
        self.children   = children or []
        self.ports      = ports or [id * 1000 + i for i in range(arity)]
        self.properties = properties or {}          # key -> python value
        self.unique_id  = unique_id                # optional string

    def to_dict(self):
        return {
            "control": self.control,
            "id": self.id,
            "properties": self.properties,
            "children": [child.to_dict() for child in self.children]
        }
    
    def __repr__(self):
        return f"Node({self.id}, {self.control})"

# ------------------------------------------------------------------ #
class Bigraph:
    def __init__(self, nodes=None, *, sites=0, names=None):
        self.nodes        = nodes or []
        self.sites        = sites
        self.names        = names or []
        self.id_mappings  = {}  # uniqueId -> node_id will be filled in to_capnp

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
            # unique id mapping
            if node.unique_id: self.id_mappings[node.unique_id] = node.id

        # idMappings
        if self.id_mappings:
            maps = bg.init("idMappings", len(self.id_mappings))
            for i,(uid,nid) in enumerate(self.id_mappings.items()):
                maps[i].uniqueId = uid
                maps[i].nodeId   = nid

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
            node = Node(
                control=n.control,
                id=n.id,
                arity=n.arity,
                ports=[p for p in n.ports],
                properties=n.properties,
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