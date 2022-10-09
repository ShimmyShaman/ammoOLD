package server

import "core:fmt"
import "core:time"
import "core:strings"
import "core:mem"
import "core:os"

import enet "vendor:ENet"

import cm "../../common"

Error :: enum {
  Success = 0,
  NotYetDetailed,
}

HostInfo :: struct {
  host: ^enet.Host,
}

// TODO -- maybe pull this against enet vendor pkg - it should be like this?
PacketFlags :: distinct bit_set[PacketFlag; u32]
PacketFlag :: enum u32 {
	RELIABLE            = 0,
	UNSEQUENCED         = 1,
	NO_ALLOCATE         = 2,
	UNRELIABLE_FRAGMENT = 3,
	FLAG_SENT           = 8,
}

// Expected args:
// .AuthenticationRequest: { username, password }
send_packet :: proc(host_info: ^HostInfo, data_type: cm.PacketDataType, flags: enet.PacketFlag, args: ..any) -> Error {

  // fmt.println("[C] send_packet args=", len(args))
  // for i in 0..<len(args) {
  //   fmt.println("[C] --send_packet args[", i, "]=", args[i], " type=", type_info_of(args[i].id), " data=", args[i].data)
  // }

  switch data_type {
    case .Void:
      fmt.println("[C-ERROR] send_packet: Void")
      return Error.NotYetDetailed
    case .AuthenticationRequest:
      // Expected args: username, password
      when ODIN_DEBUG { // TODO
        if len(args) != 2 {
          fmt.println("[C-ERROR] send_packet: AuthenticationRequest: expected 2 args, got ", len(args))
          return Error.NotYetDetailed
        }
        if args[0].id != string {
          fmt.println("[C-ERROR] send_packet: AuthenticationRequest: expected arg 0 to be string, got ", args[0].id)
          return Error.NotYetDetailed
        }
        if args[1].id != string {
          fmt.println("[C-ERROR] send_packet: AuthenticationRequest: expected arg 1 to be string, got ", args[1].id)
          return Error.NotYetDetailed
        }
      }

      pd := cm.PacketData {
        type = data_type,
        data = cm.AuthenticationRequest {
          username = (cast(^string)args[0].data)^,
          password = (cast(^string)args[1].data)^,
        },
      }

      // TODO -- one day - reduce packet size to what it should be
      // fmt.println("[C] send_packet: size=", size_of(pd), " data=", pd)
      packet := enet.packet_create(&pd, size_of(pd), auto_cast flags)
      // enet_peer_send (peer, 0, packet);
      enet.peer_send(&host_info.host.peers[0], 0, packet)

      // // Get the length of the string args
      // user := cast(^string)args[0].data
      // user_len : u16 = auto_cast len(user)
      // pass := cast(^string)args[1].data
      // pass_len : u16 = auto_cast len(pass)
      // packet_size : int = size_of(cm.PacketDataType) + (size_of(u16) + auto_cast user_len) + (size_of(u16) + auto_cast pass_len)

      // data, aerr := mem.alloc_bytes(packet_size, mem.DEFAULT_ALIGNMENT, context.temp_allocator)
      // if aerr != .None {
      //   fmt.println("[C-ERROR] send_packet: AuthenticationRequest: alloc_bytes: ", aerr)
      //   return Error.NotYetDetailed
      // }
      // defer mem.free_all(context.temp_allocator) // -- TODO do this for each frame (not just here) 'batch free'
      
      // data_ptr := raw_data(data)
      // mem.copy(data_ptr, &data_type, size_of(cm.PacketDataType))
      // mem.copy(data + size_of(cm.PacketDataType), user_len, size_of(u16))

      // enet.packet_create(&data[0], data_size, auto_cast flags)
  }

  // s : string = args[0]
  // fmt.println("[C] --send_packet args[0]=", s, " type=", type_of(s))

  return .Success
}

main :: proc() {
  fmt.println("[C] client begin!")
  defer fmt.println("[C] client end!")
  time.sleep(time.Second * 1)
  
  res := enet.initialize()
  if res != 0 {
    fmt.println("[C] failed to initialize enet")
    return
  }
  defer enet.deinitialize()

  client: HostInfo
  client.host = enet.host_create(nil, 1, 2, 0, 0)
  if client.host == nil {
    fmt.println("[C] client.host create failed!")
    return
  }
  defer enet.host_destroy(client.host)

  server_address := enet.Address {
    port = 1234,
  }
  enet.address_set_host_ip(&server_address, "127.0.0.1")

  peer := enet.host_connect(client.host, &server_address, 2, 0)
  if peer == nil {
    fmt.println("[C] peer create failed!")
    return
  }

  event: enet.Event
  fmt.println("[C] connecting...")
  if enet.host_service(client.host, &event, 5000) > 0 && event.type == .CONNECT {
    fmt.println("[C] connected to server!")

    // p := common.PacketData {
    //   type = .AuthenticationRequest,
    //   data = common.AuthenticationRequest {
    //     username = {"test-user"},
    //     password = {"test-pass"},
    //   },
    // }
    // enet.packet_create(&p, size_of(common.PacketData), .RELIABLE)
    send_packet(&client, .AuthenticationRequest, .RELIABLE, "test-user", "test-pass")
  } else {
    enet.peer_reset(peer)
    fmt.println("[C] connection to server failed!")
    return
  }

  for enet.host_service(client.host, &event, 4000) > 0 {
    switch event.type {
      case .CONNECT:
        fmt.println("[C] client connected!")
      case .RECEIVE:
        fmt.println("[C] client received: ", cstring(event.packet.data))
        // enet.packet_destroy(event.packet)
      case .DISCONNECT:
        fmt.println("[C] client disconnected!")
      case .NONE:
        fmt.println("[C] client none!")
    }
  }

  enet.peer_disconnect(peer, 0)

  r := 0
  disconnect_loop: for {
    res := enet.host_service(client.host, &event, 1000) > 0
    #partial switch event.type {
      case .DISCONNECT:
        time.sleep(time.Second * 1)
        fmt.println("[C] client disconnected!")
        break disconnect_loop
    }
    
    r += 1
    if r > 10 do break disconnect_loop
  }
}