@0xb1b1b1b1b1b1b1b1;

struct Node {
  id @0 :Int32;
  control @1 :Text;
  arity @2 :Int32;
  parent @3 :Int32;     # -1 if no parent
  ports @4 :List(Int32);
}

struct Bigraph {
  nodes @0 :List(Node);
  siteCount @1 :Int32;
  names @2 :List(Text);
}

struct Rule {
  name @0 :Text;
  redex @1 :Bigraph;
  reactum @2 :Bigraph;
}

