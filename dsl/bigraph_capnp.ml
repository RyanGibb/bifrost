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

module MakeRPC(MessageWrapper : Capnp.RPC.S) = struct
  type 'a reader_t = 'a MessageWrapper.StructStorage.reader_t
  type 'a builder_t = 'a MessageWrapper.StructStorage.builder_t
  module CamlBytes = Bytes
  module DefaultsMessage_ = Capnp.BytesMessage

  let _builder_defaults_message =
    let message_segments = [
      Bytes.unsafe_of_string "\
      ";
    ] in
    DefaultsMessage_.Message.readonly
      (DefaultsMessage_.Message.of_storage message_segments)

  let invalid_msg = Capnp.Message.invalid_msg

  include Capnp.Runtime.BuilderInc.Make(MessageWrapper)

  type 'cap message_t = 'cap MessageWrapper.Message.t

  module DefaultsCopier_ =
    Capnp.Runtime.BuilderOps.Make(Capnp.BytesMessage)(MessageWrapper)

  let _reader_defaults_message =
    MessageWrapper.Message.create
      (DefaultsMessage_.Message.total_size _builder_defaults_message)


  module Reader = struct
    type array_t = ro MessageWrapper.ListStorage.t
    type builder_array_t = rw MessageWrapper.ListStorage.t
    type pointer_t = ro MessageWrapper.Slice.t option
    let of_pointer = RA_.deref_opt_struct_pointer

    module Node = struct
      type struct_t = [`Node_e5ee33d65d702c6b]
      type t = struct_t reader_t
      let id_get x =
        RA_.get_int32 ~default:(0l) x 0
      let id_get_int_exn x =
        Capnp.Runtime.Util.int_of_int32_exn (id_get x)
      let has_control x =
        RA_.has_field x 0
      let control_get x =
        RA_.get_text ~default:"" x 0
      let arity_get x =
        RA_.get_int32 ~default:(0l) x 4
      let arity_get_int_exn x =
        Capnp.Runtime.Util.int_of_int32_exn (arity_get x)
      let parent_get x =
        RA_.get_int32 ~default:(0l) x 8
      let parent_get_int_exn x =
        Capnp.Runtime.Util.int_of_int32_exn (parent_get x)
      let has_ports x =
        RA_.has_field x 1
      let ports_get x =
        RA_.get_int32_list x 1
      let ports_get_list x =
        Capnp.Array.to_list (ports_get x)
      let ports_get_array x =
        Capnp.Array.to_array (ports_get x)
      let of_message x = RA_.get_root_struct (RA_.Message.readonly x)
      let of_builder x = Some (RA_.StructStorage.readonly x)
    end
    module Bigraph = struct
      type struct_t = [`Bigraph_8e14203ffb69382c]
      type t = struct_t reader_t
      let has_nodes x =
        RA_.has_field x 0
      let nodes_get x = 
        RA_.get_struct_list x 0
      let nodes_get_list x =
        Capnp.Array.to_list (nodes_get x)
      let nodes_get_array x =
        Capnp.Array.to_array (nodes_get x)
      let site_count_get x =
        RA_.get_int32 ~default:(0l) x 0
      let site_count_get_int_exn x =
        Capnp.Runtime.Util.int_of_int32_exn (site_count_get x)
      let has_names x =
        RA_.has_field x 1
      let names_get x =
        RA_.get_text_list x 1
      let names_get_list x =
        Capnp.Array.to_list (names_get x)
      let names_get_array x =
        Capnp.Array.to_array (names_get x)
      let of_message x = RA_.get_root_struct (RA_.Message.readonly x)
      let of_builder x = Some (RA_.StructStorage.readonly x)
    end
    module Rule = struct
      type struct_t = [`Rule_d50f45be1d2b21d0]
      type t = struct_t reader_t
      let has_name x =
        RA_.has_field x 0
      let name_get x =
        RA_.get_text ~default:"" x 0
      let has_redex x =
        RA_.has_field x 1
      let redex_get x =
        RA_.get_struct x 1
      let redex_get_pipelined x =
        MessageWrapper.Untyped.struct_field x 1
      let has_reactum x =
        RA_.has_field x 2
      let reactum_get x =
        RA_.get_struct x 2
      let reactum_get_pipelined x =
        MessageWrapper.Untyped.struct_field x 2
      let of_message x = RA_.get_root_struct (RA_.Message.readonly x)
      let of_builder x = Some (RA_.StructStorage.readonly x)
    end
  end

  module Builder = struct
    type array_t = Reader.builder_array_t
    type reader_array_t = Reader.array_t
    type pointer_t = rw MessageWrapper.Slice.t

    module Node = struct
      type struct_t = [`Node_e5ee33d65d702c6b]
      type t = struct_t builder_t
      let id_get x =
        BA_.get_int32 ~default:(0l) x 0
      let id_get_int_exn x =
        Capnp.Runtime.Util.int_of_int32_exn (id_get x)
      let id_set x v =
        BA_.set_int32 ~default:(0l) x 0 v
      let id_set_int_exn x v = id_set x (Capnp.Runtime.Util.int32_of_int_exn v)
      let has_control x =
        BA_.has_field x 0
      let control_get x =
        BA_.get_text ~default:"" x 0
      let control_set x v =
        BA_.set_text x 0 v
      let arity_get x =
        BA_.get_int32 ~default:(0l) x 4
      let arity_get_int_exn x =
        Capnp.Runtime.Util.int_of_int32_exn (arity_get x)
      let arity_set x v =
        BA_.set_int32 ~default:(0l) x 4 v
      let arity_set_int_exn x v = arity_set x (Capnp.Runtime.Util.int32_of_int_exn v)
      let parent_get x =
        BA_.get_int32 ~default:(0l) x 8
      let parent_get_int_exn x =
        Capnp.Runtime.Util.int_of_int32_exn (parent_get x)
      let parent_set x v =
        BA_.set_int32 ~default:(0l) x 8 v
      let parent_set_int_exn x v = parent_set x (Capnp.Runtime.Util.int32_of_int_exn v)
      let has_ports x =
        BA_.has_field x 1
      let ports_get x =
        BA_.get_int32_list x 1
      let ports_get_list x =
        Capnp.Array.to_list (ports_get x)
      let ports_get_array x =
        Capnp.Array.to_array (ports_get x)
      let ports_set x v =
        BA_.set_int32_list x 1 v
      let ports_init x n =
        BA_.init_int32_list x 1 n
      let ports_set_list x v =
        let builder = ports_init x (List.length v) in
        let () = List.iteri (fun i a -> Capnp.Array.set builder i a) v in
        builder
      let ports_set_array x v =
        let builder = ports_init x (Array.length v) in
        let () = Array.iteri (fun i a -> Capnp.Array.set builder i a) v in
        builder
      let of_message x = BA_.get_root_struct ~data_words:2 ~pointer_words:2 x
      let to_message x = x.BA_.NM.StructStorage.data.MessageWrapper.Slice.msg
      let to_reader x = Some (RA_.StructStorage.readonly x)
      let init_root ?message_size () =
        BA_.alloc_root_struct ?message_size ~data_words:2 ~pointer_words:2 ()
      let init_pointer ptr =
        BA_.init_struct_pointer ptr ~data_words:2 ~pointer_words:2
    end
    module Bigraph = struct
      type struct_t = [`Bigraph_8e14203ffb69382c]
      type t = struct_t builder_t
      let has_nodes x =
        BA_.has_field x 0
      let nodes_get x = 
        BA_.get_struct_list ~data_words:2 ~pointer_words:2 x 0
      let nodes_get_list x =
        Capnp.Array.to_list (nodes_get x)
      let nodes_get_array x =
        Capnp.Array.to_array (nodes_get x)
      let nodes_set x v =
        BA_.set_struct_list ~data_words:2 ~pointer_words:2 x 0 v
      let nodes_init x n =
        BA_.init_struct_list ~data_words:2 ~pointer_words:2 x 0 n
      let nodes_set_list x v =
        let builder = nodes_init x (List.length v) in
        let () = List.iteri (fun i a -> Capnp.Array.set builder i a) v in
        builder
      let nodes_set_array x v =
        let builder = nodes_init x (Array.length v) in
        let () = Array.iteri (fun i a -> Capnp.Array.set builder i a) v in
        builder
      let site_count_get x =
        BA_.get_int32 ~default:(0l) x 0
      let site_count_get_int_exn x =
        Capnp.Runtime.Util.int_of_int32_exn (site_count_get x)
      let site_count_set x v =
        BA_.set_int32 ~default:(0l) x 0 v
      let site_count_set_int_exn x v = site_count_set x (Capnp.Runtime.Util.int32_of_int_exn v)
      let has_names x =
        BA_.has_field x 1
      let names_get x =
        BA_.get_text_list x 1
      let names_get_list x =
        Capnp.Array.to_list (names_get x)
      let names_get_array x =
        Capnp.Array.to_array (names_get x)
      let names_set x v =
        BA_.set_text_list x 1 v
      let names_init x n =
        BA_.init_text_list x 1 n
      let names_set_list x v =
        let builder = names_init x (List.length v) in
        let () = List.iteri (fun i a -> Capnp.Array.set builder i a) v in
        builder
      let names_set_array x v =
        let builder = names_init x (Array.length v) in
        let () = Array.iteri (fun i a -> Capnp.Array.set builder i a) v in
        builder
      let of_message x = BA_.get_root_struct ~data_words:1 ~pointer_words:2 x
      let to_message x = x.BA_.NM.StructStorage.data.MessageWrapper.Slice.msg
      let to_reader x = Some (RA_.StructStorage.readonly x)
      let init_root ?message_size () =
        BA_.alloc_root_struct ?message_size ~data_words:1 ~pointer_words:2 ()
      let init_pointer ptr =
        BA_.init_struct_pointer ptr ~data_words:1 ~pointer_words:2
    end
    module Rule = struct
      type struct_t = [`Rule_d50f45be1d2b21d0]
      type t = struct_t builder_t
      let has_name x =
        BA_.has_field x 0
      let name_get x =
        BA_.get_text ~default:"" x 0
      let name_set x v =
        BA_.set_text x 0 v
      let has_redex x =
        BA_.has_field x 1
      let redex_get x =
        BA_.get_struct ~data_words:1 ~pointer_words:2 x 1
      let redex_set_reader x v =
        BA_.set_struct ~data_words:1 ~pointer_words:2 x 1 v
      let redex_set_builder x v =
        BA_.set_struct ~data_words:1 ~pointer_words:2 x 1 (Some v)
      let redex_init x =
        BA_.init_struct ~data_words:1 ~pointer_words:2 x 1
      let has_reactum x =
        BA_.has_field x 2
      let reactum_get x =
        BA_.get_struct ~data_words:1 ~pointer_words:2 x 2
      let reactum_set_reader x v =
        BA_.set_struct ~data_words:1 ~pointer_words:2 x 2 v
      let reactum_set_builder x v =
        BA_.set_struct ~data_words:1 ~pointer_words:2 x 2 (Some v)
      let reactum_init x =
        BA_.init_struct ~data_words:1 ~pointer_words:2 x 2
      let of_message x = BA_.get_root_struct ~data_words:0 ~pointer_words:3 x
      let to_message x = x.BA_.NM.StructStorage.data.MessageWrapper.Slice.msg
      let to_reader x = Some (RA_.StructStorage.readonly x)
      let init_root ?message_size () =
        BA_.alloc_root_struct ?message_size ~data_words:0 ~pointer_words:3 ()
      let init_pointer ptr =
        BA_.init_struct_pointer ptr ~data_words:0 ~pointer_words:3
    end
  end

  module Client = struct
  end

  module Service = struct
  end
  module MessageWrapper = MessageWrapper
end

module Make(M:Capnp.MessageSig.S) = MakeRPC(Capnp.RPC.None(M))
