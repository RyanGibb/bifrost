import capnp

capnp.remove_import_hook()
bigraph_capnp = capnp.load('bigraph.capnp')

class Node:
    def __init__(self, control, id, arity=0, children=None, ports=None):
        self.control = control
        self.id = id
        self.arity = arity
        self.children = children or []
        self.ports = ports or [id * 1000 + i for i in range(arity)]

    def __repr__(self):
        return f"Node({self.id}, {self.control}, arity={self.arity})"

class Bigraph:
    def __init__(self, nodes=None, sites=0, names=None):
        self.nodes = nodes or []
        self.sites = sites
        self.names = names or []

    def _flatten_nodes(self):
        flat = []

        def visit(node, parent):
            flat.append((node, parent))
            for child in node.children:
                visit(child, node.id)

        for root in self.nodes:
            visit(root, -1)
        return flat

    def to_capnp(self):
        bg = bigraph_capnp.Bigraph.new_message()
        flat_nodes = self._flatten_nodes()
        
        nodes_list = bg.init("nodes", len(flat_nodes))
        for i, (node, parent) in enumerate(flat_nodes):
            print(f"Set node {i}: id={node.id}, control={node.control}, parent={parent}")
            node_msg = nodes_list[i]
            node_msg.id = node.id
            node_msg.control = node.control
            node_msg.arity = node.arity
            node_msg.parent = parent
            
            ports_list = node_msg.init("ports", len(node.ports))
            for j, port in enumerate(node.ports):
                ports_list[j] = port

        bg.siteCount = self.sites
        
        names_list = bg.init("names", len(self.names))
        for i, name in enumerate(self.names):
            names_list[i] = name
        
        return bg

    def save(self, path):
        capnp_msg = self.to_capnp()
        print(f"Saving bigraph with {len(self._flatten_nodes())} nodes to {path}")
        with open(path, "wb") as f:
            capnp_msg.write(f)

class Rule:
    def __init__(self, name, redex, reactum):
        self.name = name
        self.redex = redex
        self.reactum = reactum

    def to_capnp(self):
        r = bigraph_capnp.Rule.new_message()
        r.name = self.name
        
        redex_msg = self.redex.to_capnp()
        reactum_msg = self.reactum.to_capnp()
        
        r.redex = redex_msg
        r.reactum = reactum_msg
        
        return r

    def save(self, path):
        capnp_msg = self.to_capnp()
        print(f"Saving rule '{self.name}' to {path}")
        print(f"Redex nodes: {len(self.redex._flatten_nodes())}")
        print(f"Reactum nodes: {len(self.reactum._flatten_nodes())}")
        with open(path, "wb") as f:
            capnp_msg.write(f)