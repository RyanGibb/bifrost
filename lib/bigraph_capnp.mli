[@@@ocaml.warning "-27-32-37-60"]

type ro = Capnp.Message.ro
type rw = Capnp.Message.rw

module type S = sig
  module MessageWrapper : Capnp.RPC.S
  type 'cap message_t = 'cap MessageWrapper.Message.t
  type 'a reader_t = 'a MessageWrapper.StructStorage.reader_t
  type 'a builder_t = 'a MessageWrapper.StructStorage.builder_t


  module Reader : sig
    type array_t
    type builder_array_t
    type pointer_t = ro MessageWrapper.Slice.t option
    val of_pointer : pointer_t -> 'a reader_t
    module Node : sig
      type struct_t = [`Node_e5ee33d65d702c6b]
      type t = struct_t reader_t
      val id_get : t -> int32
      val id_get_int_exn : t -> int
      val has_control : t -> bool
      val control_get : t -> string
      val arity_get : t -> int32
      val arity_get_int_exn : t -> int
      val parent_get : t -> int32
      val parent_get_int_exn : t -> int
      val has_ports : t -> bool
      val ports_get : t -> (ro, int32, array_t) Capnp.Array.t
      val ports_get_list : t -> int32 list
      val ports_get_array : t -> int32 array
      val of_message : 'cap message_t -> t
      val of_builder : struct_t builder_t -> t
    end
    module Bigraph : sig
      type struct_t = [`Bigraph_8e14203ffb69382c]
      type t = struct_t reader_t
      val has_nodes : t -> bool
      val nodes_get : t -> (ro, Node.t, array_t) Capnp.Array.t
      val nodes_get_list : t -> Node.t list
      val nodes_get_array : t -> Node.t array
      val site_count_get : t -> int32
      val site_count_get_int_exn : t -> int
      val has_names : t -> bool
      val names_get : t -> (ro, string, array_t) Capnp.Array.t
      val names_get_list : t -> string list
      val names_get_array : t -> string array
      val of_message : 'cap message_t -> t
      val of_builder : struct_t builder_t -> t
    end
    module Rule : sig
      type struct_t = [`Rule_d50f45be1d2b21d0]
      type t = struct_t reader_t
      val has_name : t -> bool
      val name_get : t -> string
      val has_redex : t -> bool
      val redex_get : t -> Bigraph.t
      val redex_get_pipelined : struct_t MessageWrapper.StructRef.t -> Bigraph.struct_t MessageWrapper.StructRef.t
      val has_reactum : t -> bool
      val reactum_get : t -> Bigraph.t
      val reactum_get_pipelined : struct_t MessageWrapper.StructRef.t -> Bigraph.struct_t MessageWrapper.StructRef.t
      val of_message : 'cap message_t -> t
      val of_builder : struct_t builder_t -> t
    end
  end

  module Builder : sig
    type array_t = Reader.builder_array_t
    type reader_array_t = Reader.array_t
    type pointer_t = rw MessageWrapper.Slice.t
    module Node : sig
      type struct_t = [`Node_e5ee33d65d702c6b]
      type t = struct_t builder_t
      val id_get : t -> int32
      val id_get_int_exn : t -> int
      val id_set : t -> int32 -> unit
      val id_set_int_exn : t -> int -> unit
      val has_control : t -> bool
      val control_get : t -> string
      val control_set : t -> string -> unit
      val arity_get : t -> int32
      val arity_get_int_exn : t -> int
      val arity_set : t -> int32 -> unit
      val arity_set_int_exn : t -> int -> unit
      val parent_get : t -> int32
      val parent_get_int_exn : t -> int
      val parent_set : t -> int32 -> unit
      val parent_set_int_exn : t -> int -> unit
      val has_ports : t -> bool
      val ports_get : t -> (rw, int32, array_t) Capnp.Array.t
      val ports_get_list : t -> int32 list
      val ports_get_array : t -> int32 array
      val ports_set : t -> (rw, int32, array_t) Capnp.Array.t -> (rw, int32, array_t) Capnp.Array.t
      val ports_set_list : t -> int32 list -> (rw, int32, array_t) Capnp.Array.t
      val ports_set_array : t -> int32 array -> (rw, int32, array_t) Capnp.Array.t
      val ports_init : t -> int -> (rw, int32, array_t) Capnp.Array.t
      val of_message : rw message_t -> t
      val to_message : t -> rw message_t
      val to_reader : t -> struct_t reader_t
      val init_root : ?message_size:int -> unit -> t
      val init_pointer : pointer_t -> t
    end
    module Bigraph : sig
      type struct_t = [`Bigraph_8e14203ffb69382c]
      type t = struct_t builder_t
      val has_nodes : t -> bool
      val nodes_get : t -> (rw, Node.t, array_t) Capnp.Array.t
      val nodes_get_list : t -> Node.t list
      val nodes_get_array : t -> Node.t array
      val nodes_set : t -> (rw, Node.t, array_t) Capnp.Array.t -> (rw, Node.t, array_t) Capnp.Array.t
      val nodes_set_list : t -> Node.t list -> (rw, Node.t, array_t) Capnp.Array.t
      val nodes_set_array : t -> Node.t array -> (rw, Node.t, array_t) Capnp.Array.t
      val nodes_init : t -> int -> (rw, Node.t, array_t) Capnp.Array.t
      val site_count_get : t -> int32
      val site_count_get_int_exn : t -> int
      val site_count_set : t -> int32 -> unit
      val site_count_set_int_exn : t -> int -> unit
      val has_names : t -> bool
      val names_get : t -> (rw, string, array_t) Capnp.Array.t
      val names_get_list : t -> string list
      val names_get_array : t -> string array
      val names_set : t -> (rw, string, array_t) Capnp.Array.t -> (rw, string, array_t) Capnp.Array.t
      val names_set_list : t -> string list -> (rw, string, array_t) Capnp.Array.t
      val names_set_array : t -> string array -> (rw, string, array_t) Capnp.Array.t
      val names_init : t -> int -> (rw, string, array_t) Capnp.Array.t
      val of_message : rw message_t -> t
      val to_message : t -> rw message_t
      val to_reader : t -> struct_t reader_t
      val init_root : ?message_size:int -> unit -> t
      val init_pointer : pointer_t -> t
    end
    module Rule : sig
      type struct_t = [`Rule_d50f45be1d2b21d0]
      type t = struct_t builder_t
      val has_name : t -> bool
      val name_get : t -> string
      val name_set : t -> string -> unit
      val has_redex : t -> bool
      val redex_get : t -> Bigraph.t
      val redex_set_reader : t -> Bigraph.struct_t reader_t -> Bigraph.t
      val redex_set_builder : t -> Bigraph.t -> Bigraph.t
      val redex_init : t -> Bigraph.t
      val has_reactum : t -> bool
      val reactum_get : t -> Bigraph.t
      val reactum_set_reader : t -> Bigraph.struct_t reader_t -> Bigraph.t
      val reactum_set_builder : t -> Bigraph.t -> Bigraph.t
      val reactum_init : t -> Bigraph.t
      val of_message : rw message_t -> t
      val to_message : t -> rw message_t
      val to_reader : t -> struct_t reader_t
      val init_root : ?message_size:int -> unit -> t
      val init_pointer : pointer_t -> t
    end
  end
end

module MakeRPC(MessageWrapper : Capnp.RPC.S) : sig
  include S with module MessageWrapper = MessageWrapper

  module Client : sig
  end

  module Service : sig
  end
end

module Make(M : Capnp.MessageSig.S) : module type of MakeRPC(Capnp.RPC.None(M))
