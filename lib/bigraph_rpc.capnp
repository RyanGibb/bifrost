@0xdededeadcf0ffee1;

struct PropertyValue {
  union {
    boolVal   @0 :Bool;
    intVal    @1 :Int32;
    floatVal  @2 :Float32;
    stringVal @3 :Text;
    colorVal  :group {
      r @4 :UInt8;
      g @5 :UInt8;
      b @6 :UInt8;
    }
  }
}

struct Property {
  key   @0 :Text;
  value @1 :PropertyValue;
}

struct Node {
  id         @0 :Int32;
  control    @1 :Text;
  arity      @2 :Int32;
  parent     @3 :Int32;           # -1 means "root"
  ports      @4 :List(Int32);
  properties @5 :List(Property);
  name       @6 :Text;            # Human-readable name
  type       @7 :Text;            # Node type category
}

struct Bigraph {
  nodes       @0 :List(Node);
  siteCount   @1 :Int32;
  names       @2 :List(Text);
  # Removed idMappings since we're not using id_graph anymore
}

struct Rule {
  name    @0 :Text;
  redex   @1 :Bigraph;
  reactum @2 :Bigraph;
}