package launcher

import "core:fmt"
import "core:time"
import "core:strings"
import "core:mem"
import "core:os"
import "core:sync"

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
  cli.netdata.status = .Initializing
  
  res := enet.initialize()
  if res != 0 {
    fmt.println("[C] failed to initialize enet")
    cli.netdata.status = .Shutdown
    return
  }
  defer enet.deinitialize()

  cli.host = enet.host_create(nil, 1, 2, 0, 0)
  if cli.host == nil {
    fmt.println("[C] cli.host create failed!")
    cli.netdata.status = .Shutdown
    return
  }
  defer enet.host_destroy(cli.host)

  cli.netdata.server_address = enet.Address {
    port = 1234,
  }
  enet.address_set_host_ip(&cli.netdata.server_address, "127.0.0.1")

  if cli.netdata.should_close {
    cli.netdata.status = .Shutdown
    return
  }
  cli.netdata.status = .Initialized

  // Begin receive loop
  // Loop
  _process_events(&cli)

  // Disconnect & confirm
  if cli.netdata.status == .Connected {
    _force_disconnect(&cli)
  }
  cli.netdata.status = .Shutdown
}

_process_events :: proc(cli: ^HostInfo) -> Error {
  fmt.println("process_events:", cli.netdata.status)

  event: enet.Event
  res: i32
  activity_time := time.now()
  for {
    if cli.netdata.should_close {
      // fmt.println("[C] Client Network Thread closing by request")
      return .Success
    }
    // MaxUpTimeSecs :: 3
    // if time.diff(activity_time, time.now()) >= MaxUpTimeSecs * time.Second {
    //   fmt.println("[C] Client recieved no activity for", MaxUpTimeSecs, "seconds. Closing down...")
    //   break
    // }

    #partial switch cli.netdata.status {
      case .Initialized, .Disconnected:
        _reconnect_to_server(cli)
        continue
    }

    res = enet.host_service(cli.host, &event, 1000)
    if res < 0 {
      fmt.eprintln("[C] Error host_service:", res)
      break
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

        // Reset connection data
        cli.netdata.connection_sequence_retries = 0
        cli.netdata.connection_sequence_retry_time = time.now()
      case .RECEIVE:
        _handle_receive_event(cli, &event) or_return
      case .NONE:
        fmt.println("[C] Error? Client None")
        break
    }
  }

  return .Success
}

_reconnect_to_server :: proc(cli: ^HostInfo) {
  event: enet.Event
  res: i32

  time_diff := time.diff(time.now(), cli.netdata.connection_sequence_retry_time)
  if time_diff >= 0 {
    time.sleep(time_diff)
  }
  cli.netdata.connection_sequence_retries += 1

  // Attempt to connect to the server
  cli.netdata.status = .Connecting
  fmt.println("[C] Attempting to connect to server...")
  cli.server = enet.host_connect(cli.host, &cli.netdata.server_address, 2, 0)
  if cli.server == nil {
    fmt.println("[C] peer host_connect failed!")
    cli.netdata.status = .Disconnected
    return
  }

  // Wait for connection
  for i in 0..<10 {
    if cli.netdata.should_close do return

    res = enet.host_service(cli.host, &event, 500)
    if res == 0 do continue

    if res > 0 && event.type == .CONNECT {
      fmt.println("[C] Connected to server!")
      cli.netdata.status = .Connected
      return
    }

    if res < 0 {
      fmt.eprintln("[C] Error host_service:", res)
      cli.netdata.status = .Disconnected
      break
    }

    break
  }

  // Reset
  res = 0
  for i in 0..<cli.netdata.connection_sequence_retries do res += auto_cast (i / 2)
  res = min(90, 1 + res)
  fmt.print("[C] Connection failed!")
  if res > 4 {
    fmt.println(" Retrying in", res, "seconds...")
  } else {
    fmt.println("")
  }

  cli.netdata.connection_sequence_retry_time = time.time_add(time.now(), time.Second * auto_cast res)
  cli.netdata.status = .Disconnected

  enet.peer_reset(cli.server)
  cli.server = nil
  
  return
}

_force_disconnect :: proc(cli: ^HostInfo) {
  // Disconnect
  cli.netdata.status = .Disconnecting
  enet.peer_disconnect(cli.server, 0)

  event: enet.Event
  r := 0
  disconnect_loop: for {
    res := enet.host_service(cli.host, &event, 50) > 0
    #partial switch event.type {
      case .DISCONNECT:
        time.sleep(time.Second * 1)
        fmt.println("[C] client disconnected!")
        cli.netdata.status = .Disconnected
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