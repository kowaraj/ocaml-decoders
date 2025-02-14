module DOMParser = struct
  type t

  external create : unit -> t = "DOMParser" [@@bs.new]

  external parseFromString : t -> string -> string -> Dom.element
    = "parseFromString"
    [@@bs.send]

  external firstElementChildUnsafe : Dom.element -> Dom.element
    = "firstElementChild"
    [@@bs.get]

  let parse_xml text =
    let parser = create () in
    let doc = parseFromString parser text "text/xml" in
    firstElementChildUnsafe doc
end

module Node = struct
  (* See https://developer.mozilla.org/en-US/docs/Web/API/Node/nodeType *)
  external element_node : int = "ELEMENT_NODE" [@@bs.val] [@@bs.scope "Node"]

  external text_node : int = "TEXT_NODE" [@@bs.val] [@@bs.scope "Node"]

  external comment_node : int = "COMMENT_NODE" [@@bs.val] [@@bs.scope "Node"]

  external nodeType : Dom.node -> int = "nodeType" [@@bs.get]

  external of_element : Dom.element -> Dom.node = "%identity"

  external to_element_unsafe : Dom.node -> Dom.element = "%identity"

  external of_text : Dom.text -> Dom.node = "%identity"

  external to_text_unsafe : Dom.node -> Dom.text = "%identity"
end

type value =
  [ `El of Dom.element
  | `Data of Dom.text
  ]

module Node_list = struct
  external to_array_like : Dom.nodeList -> Dom.node Js.Array.array_like
    = "%identity"

  let to_array (nodesList : Dom.nodeList) : value array =
    nodesList
    |> to_array_like
    |> Js.Array.from
    |. Belt.Array.keepMap (fun node ->
           let ty = Node.nodeType node in
           if ty = Node.element_node
           then Some (`El (Node.to_element_unsafe node))
           else if ty = Node.text_node
           then Some (`Data (Node.to_text_unsafe node))
           else if ty = Node.comment_node
           then None
           else failwith (Format.asprintf "Unexpected node type %i" ty) )
end

module Text = struct
  external data : Dom.text -> string = "data" [@@bs.get]
end

module Element = struct
  external childNodes : Dom.element -> Dom.nodeList = "childNodes" [@@bs.get]

  let child_nodes elt = childNodes elt |> Node_list.to_array |> Array.to_list

  external tagName : Dom.element -> string = "tagName" [@@bs.get]

  external getAttribute : Dom.element -> string -> string Js.Nullable.t
    = "getAttribute"
    [@@bs.send]

  external getAttributeNames : Dom.element -> string Js.Array.t
    = "getAttributeNames"
    [@@bs.send]

  let get_attribute elt attr =
    let v = getAttribute elt attr in
    Js.Nullable.toOption v


  external append : Dom.element -> Dom.node array -> unit = "append"
    [@@bs.send] [@@variadic]

  external setAttribute : Dom.element -> string -> string -> unit
    = "setAttribute"
    [@@bs.send]
end

module XMLSerializer = struct
  type t

  external create : unit -> t = "XMLSerializer" [@@bs.new]

  external serializeToString : t -> Dom.node -> string = "serializeToString"
    [@@bs.send]
end

module Document = struct
  external createElementNS : string -> string -> Dom.element = "createElementNS"
    [@@val] [@@scope "window", "document"]

  external createTextNode : string -> Dom.text = "createTextNode"
    [@@val] [@@scope "window", "document"]
end

module Encode = struct
  type nonrec value = value

  type 'a encoder = 'a -> value

  let to_node = function
    | `El el ->
        Node.of_element el
    | `Data text ->
        Node.of_text text


  let tag name ?(attrs = []) children =
    (* Remove xmlns="http://www.w3.org/1999/xhtml" and "NS1:" prefix *)
    let xmlns = "" in
    let el = Document.createElementNS xmlns name in
    Element.append el (List.map to_node children |> Array.of_list) ;
    List.iter (fun (name, value) -> Element.setAttribute el name value) attrs ;
    `El el


  let data string = `Data (Document.createTextNode string)

  let value x = x

  let encode_string encoder v =
    let s = XMLSerializer.create () in
    XMLSerializer.serializeToString s (to_node (encoder v))
end

module Decode = struct
  module E = Encode
  open Decoders
  open Util

  type nonrec value = value

  let pp fmt v = Format.fprintf fmt "%s" E.(encode_string value v)

  type error = value Error.t

  let pp_error = Error.pp pp

  let string_of_error = Error.to_string pp

  type 'a decoder = (value, 'a) Decoder.t

  include Decoder.Infix
  include Decoder

  let succeed = pure

  let and_then = bind

  let from_result = of_result

  let tag (name : string) : unit decoder =
   fun (v : value) ->
    match v with
    | `El el when Element.tagName el = name ->
        Ok ()
    | _ ->
        fail (Format.asprintf "Expected a tag with name %S" name) v


  let any_tag : string decoder =
   fun (v : value) ->
    match v with
    | `El el ->
        Ok (Element.tagName el)
    | _ ->
        fail "Expected a Tag" v


  let data : string decoder =
   fun (v : value) ->
    match v with
    | `Data text ->
        Ok (Text.data text)
    | `El _ ->
        fail "Expected Data" v


  let attr_opt name : string option decoder =
   fun (v : value) ->
    match v with
    | `El el ->
        Ok (Element.get_attribute el name)
    | `Data _ ->
        fail "Expected a Tag" v


  let attr name : string decoder =
    attr_opt name
    >>= function
    | Some value ->
        succeed value
    | None ->
        fail (Format.asprintf "Expected an attribute named %S" name)


  let attrs : (string * string) list decoder =
   fun (v : value) ->
    match v with
    | `El el ->
        let names = Element.getAttributeNames el |> Array.to_list in
        let attrs =
          names
          |> List.map (fun name ->
                 let value =
                   match Element.get_attribute el name with
                   | Some v ->
                       v
                   | None ->
                       assert false
                 in
                 (name, value) )
        in
        Ok attrs
    | `Data _ ->
        fail "Expected a Tag" v


  let pick_children (child : 'a decoder decoder) : 'a list decoder = function
    | `El el ->
        Element.child_nodes el
        |> My_list.filter_mapi (fun i v ->
               match child v with
               | Error _ ->
                   None
               | Ok dec ->
                   Some
                     ( dec v
                     |> My_result.map_err
                          (Error.tag
                             (Format.asprintf "While decoding child %i" i) ) ) )
        |> My_result.combine_l
        |> My_result.map_err
             (Error.tag_group
                (Format.asprintf "In tag %s" (Element.tagName el)) )
    | `Data _ as v ->
        fail "Expected a Tag" v


  let children (child : 'a decoder) : 'a list decoder =
    pick_children (pure child)


  let decode_value decoder v = decoder v

  let of_string str =
    try Ok (`El (DOMParser.parse_xml str)) with
    | e ->
        Error (Error.tag "Parse error" (Error.make (Printexc.to_string e)))


  let decode_string decoder str =
    My_result.Infix.(of_string str >>= decode_value decoder)


  let of_file _ = failwith "Not implemented"

  let decode_file _ = failwith "Not implemented"
end
