package common

import "core:fmt"
import "core:mem"
import "core:strings"

import enet "vendor:ENet"

MidStringSize :: 24

PacketDataType :: enum u16 {
  Void = 0,
  AuthenticationRequest,
}

AuthenticationRequest :: struct {
  username: string,
  password: string,
}

PacketData :: struct {
  data_type: PacketDataType,
  data: union {
    AuthenticationRequest,
  },
}

// Expected args:
// .AuthenticationRequest: { username, password }
send_packet :: proc(peer: ^enet.Peer, data_type: PacketDataType, flags: enet.PacketFlag, args: ..any) -> int {

  data: [dynamic]u8
  defer delete(data) // TODO -- better memory management

  append(&data, auto_cast (cast(u16)data_type % 256))
  append(&data, auto_cast (cast(u16)data_type / 256))

  // fmt.println("[M] send_packet args=", len(args))
  for i in 0..<len(args) {
    // fmt.println("[M] --send_packet args[", i, "]=", args[i], " type=", type_info_of(args[i].id), " data=", args[i].data)
    switch args[i].id {
      case string:
        str := cast(^string)args[i].data
        str_len : u16 = auto_cast len(str)
        append(&data, cast(u8)(str_len % 256))
        append(&data, cast(u8)(str_len / 256))
        for j in 0..<str_len {
          append(&data, str[j])
        }
      case:
        fmt.println("[M] send_packet(): Unhandled argument type:", type_info_of(args[i].id))
        return 1
    }
  }

  when ODIN_DEBUG { // TODO
    switch data_type {
      case .Void:
        fmt.println("[C-ERROR] send_packet: Void")
        return 3
      case .AuthenticationRequest:
        // Expected args: username, password
        if len(args) != 2 {
          fmt.println("[C-ERROR] send_packet: AuthenticationRequest: expected 2 args, got ", len(args))
          return 2
        }
        if args[0].id != string {
          fmt.println("[C-ERROR] send_packet: AuthenticationRequest: expected arg 0 to be string, got ", args[0].id)
          return 2
        }
        if args[1].id != string {
          fmt.println("[C-ERROR] send_packet: AuthenticationRequest: expected arg 1 to be string, got ", args[1].id)
          return 2
        }
      }
  }

  // TODO -- one day - reduce packet size to what it should be
  // fmt.println("[M] send_packet: size=", len(data), " data=", data)
  packet := enet.packet_create(raw_dynamic_array_data(data), len(data), auto_cast flags)
  enet.peer_send(peer, 0, packet)

  return 0
}

parse_packet :: proc(data: [^]u8, data_length: int) -> (pd: ^PacketData) {
  sb: strings.Builder = strings.builder_make(context.temp_allocator)

  aerr: mem.Allocator_Error
  pd, aerr = new(PacketData, context.temp_allocator)
  type_value: u16 = auto_cast data[0] + cast(u16)256 * auto_cast data[1]
  // fmt.print("data:\n")
  // for i in 0..<24 {
  //   fmt.print(",", data[i])
  // }
  // fmt.println("type_value=", type_value)
  pd.data_type = auto_cast type_value

  switch pd.data_type {
    case .Void:
      fmt.println("[M-ERROR] send_packet: Void")
      mem.free(pd)
      return nil
    case .AuthenticationRequest:
      ar: ^AuthenticationRequest = auto_cast &pd.data
      offset := 2

      ar.username = _parse_string_from_packet_data(&sb, data, &offset)
      ar.password = _parse_string_from_packet_data(&sb, data, &offset)
  }

  return
}

_parse_string_from_packet_data :: proc(sb: ^strings.Builder, data: [^]u8, offset: ^int) -> string {
  len : int = auto_cast data[offset^] + cast(int)data[offset^ + 1] * 256
  strings.builder_reset(sb)
  // fmt.println("offset=", offset^, " len=", len, " data=", data[offset^ + 2:offset^ + 2 + len])
  strings.write_bytes(sb, data[offset^ + 2:offset^ + 2 + len])

  // fmt.println("result=", strings.to_string(sb^))

  offset^ += 2 + len
  return strings.clone(strings.to_string(sb^), context.temp_allocator)
}