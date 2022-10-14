package launcher

import "core:fmt"
import "core:time"
import "core:strings"
import "core:mem"
import "core:os"

import enet "vendor:ENet"

import cm "../../common"

HostInfo :: struct {
  netdata: ^NetworkData,
  host: ^enet.Host,
  server: ^enet.Peer,
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

begin_client_network_connection :: proc(arg: rawptr) {
  fmt.println("[C] client begin!")
  defer fmt.println("[C] client end!")

  // Cast
  cli: HostInfo
  cli.netdata = auto_cast arg
  
  res := enet.initialize()
  if res != 0 {
    fmt.println("[C] failed to initialize enet")
    return
  }
  defer enet.deinitialize()

  cli.host = enet.host_create(nil, 1, 2, 0, 0)
  if cli.host == nil {
    fmt.println("[C] cli.host create failed!")
    return
  }
  defer enet.host_destroy(cli.host)

  server_address := enet.Address {
    port = 1234,
  }
  enet.address_set_host_ip(&server_address, "127.0.0.1")

  if cli.netdata.should_close do return

  // Attempt to connect to the server
  cli.netdata.status = .Connecting
  fmt.println("[C]", cli.netdata.status, "...")
  cli.server = enet.host_connect(cli.host, &server_address, 2, 0)
  if cli.server == nil {
    fmt.println("[C] peer host_connect failed!")
    return
  }

  // Begin receive loop
  // Loop
  _process_events(&cli)

  // Disconnect & confirm
  _force_disconnect(&cli)
  cli.netdata.is_active = false
  cli.netdata.status = .Shutdown
}

_process_events :: proc(cli: ^HostInfo) -> Error {
  event: enet.Event
  retries := 0
  activity_time := time.now()
  for {
    if cli.netdata.should_close {
      fmt.println("[C] Client Network Thread forced to close")
      return .Success
    }
    // MaxUpTimeSecs :: 3
    // if time.diff(activity_time, time.now()) >= MaxUpTimeSecs * time.Second {
    //   fmt.println("[C] Client recieved no activity for", MaxUpTimeSecs, "seconds. Closing down...")
    //   break
    // }

    res := enet.host_service(cli.host, &event, 1000)
    if res < 0 {
      fmt.println("[C] host_service error:", res)
      break
    }

    if res == 0 {
      #partial switch cli.netdata.status {
        case .Connecting:
          if retries >= 5 {
            fmt.println("[C] Connection to Server Failed")
            break
          }
          retries += 1
      }
      continue
    }

    // Received something
    activity_time = time.now()
    defer {
      mem.free_all(context.temp_allocator)
      enet.packet_destroy(event.packet)
    }

    switch event.type {
      case .CONNECT:
        _handle_connect_event(cli, &event) or_return
      case .DISCONNECT:
        _handle_disconnect_event(cli, &event) or_return
      case .RECEIVE:
        _handle_receive_event(cli, &event) or_return
      case .NONE:
        fmt.println("[C] Error? Client None")
        break
    }
  }

  return .Success
}

_force_disconnect :: proc(cli: ^HostInfo) {
  // Disconnect
  enet.peer_disconnect(cli.server, 0)

  event: enet.Event
  r := 0
  disconnect_loop: for {
    res := enet.host_service(cli.host, &event, 50) > 0
    #partial switch event.type {
      case .DISCONNECT:
        time.sleep(time.Second * 1)
        fmt.println("[C] client disconnected!")
        break disconnect_loop
    }
    
    r += 1
    if r >= 100 {
      fmt.println("Disconnect from server not confirmed")
      break disconnect_loop
    }
  }
}

_handle_connect_event :: proc(cli: ^HostInfo, event: ^enet.Event) -> Error {
  if cli.netdata.status != .Connecting {
    fmt.println("[C] Unexpected connect event")
  }
  else {
    fmt.println("[C] Connected to Server")
    cli.netdata.status = .Connected
  }

  return .Success
}

_handle_disconnect_event :: proc(cli: ^HostInfo, event: ^enet.Event) -> Error {
  // // Reset cached profile
  // profile: ^PeerProfile = auto_cast event.peer.data
  // profile._in_use = false
  // profile.status = .Unauthorized
  fmt.println(args={"[C] Client Disconnection:", event.peer.address.host, ":", event.peer.address.port}, sep = "")

  return .NotYetDetailed
}

_handle_receive_event :: proc(cli: ^HostInfo, event: ^enet.Event) -> Error {
  fmt.println(args={"[C] Client Receive:", event.peer.address.host, ":", event.peer.address.port}, sep = "")

  // Parse the received data packet
  pd: ^cm.PacketData = cm.parse_packet(event.packet.data, auto_cast event.packet.dataLength)
  
  //  auto_cast event.packet.data
  fmt.println("[C] Received packet:", pd.data_type, "size:", event.packet.dataLength)

  #partial switch pd.data_type {
    case:
      fmt.println("[C] Error? Unknown packet type:", pd.data_type)
      return .NotYetDetailed
  }

  return .Success
}