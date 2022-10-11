package server

import "core:fmt"
import "core:time"
import "core:strings"

import enet "vendor:ENet"

import cm "../../common"

Error :: enum {
  Success,
  NotYetDetailed,
}

ClientStatus :: enum {
  Unauthorized = 0,
  Authorized = 1,
}

PeerProfile :: struct {
  _in_use: bool,
  status: ClientStatus,
}

PP_CACHE_SIZE :: 1024
ServerInfo :: struct {
  peer_profile_cache: [PP_CACHE_SIZE]PeerProfile,
  host: ^enet.Host,
}

main :: proc() {
  fmt.println("[S] server begin!")
  defer fmt.println("[S] server end!")
  defer time.sleep(time.Second * 2)

  // Initialize
  res := enet.initialize()
  if res != 0 {
    fmt.println("[S] failed to initialize enet")
    return
  }
  defer enet.deinitialize()

  server_info: ServerInfo

  // Create host
  address := enet.Address {
    host = enet.HOST_ANY,
    port = 1234,
  }
  enet.address_set_host(&address, "127.0.0.1")

  server_info.host = enet.host_create(&address, 32, 2, 0, 0)
  if server_info.host == nil {
    fmt.println("[S] failed to create server host")
    return
  }
  defer enet.host_destroy(server_info.host)
  fmt.println("[S] server_info.host created")

  // Listen for events
  process_events(&server_info)

  return
}

process_events :: proc(server_info: ^ServerInfo) -> Error {
  // Loop
  event: enet.Event
  for {
    res := enet.host_service(server_info.host, &event, 1000)
    if res < 0 {
      fmt.println("[S] host_service error:", res)
      break
    }

    if res == 0 {
      continue
    }

    switch event.type {
      case .CONNECT:
        fmt.println(args={"[S] Client Connection:", event.peer.address.host, ":", event.peer.address.port,
          " [connectedPeers=", server_info.host.connectedPeers, "]"}, sep = "")
        handle_connect_event(server_info, &event) or_return
      case .DISCONNECT:
        fmt.println(args={"[S] Client Disconnection:", event.peer.address.host, ":", event.peer.address.port,
          " [connectedPeers=", server_info.host.connectedPeers, "]"}, sep = "")
        handle_disconnect_event(server_info, &event) or_return
      case .RECEIVE:
        fmt.println(args={"[S] Client Receive:", event.peer.address.host, ":", event.peer.address.port,
          " [connectedPeers=", server_info.host.connectedPeers, "]"}, sep = "")
        handle_receive_event(server_info, &event) or_return
      case .NONE:
        fmt.println("[S] Error? Client None")
        break
    }
  }

  return .Success
}

handle_connect_event :: proc(server_info: ^ServerInfo, event: ^enet.Event) -> Error {
  // Find cached profile
  profile: ^PeerProfile
  for i := 0; i < PP_CACHE_SIZE; i+=1 {
    if !server_info.peer_profile_cache[i]._in_use {
      server_info.peer_profile_cache[i]._in_use = true
      server_info.peer_profile_cache[i].status = .Unauthorized
      profile = &server_info.peer_profile_cache[i]
      break
    }
  }
  if profile == nil {
    fmt.println("[S] Error? No free peer profiles")
    return .NotYetDetailed
  }

  // Set
  event.peer.data = auto_cast profile

  return .Success
}

handle_disconnect_event :: proc(server_info: ^ServerInfo, event: ^enet.Event) -> Error {
  // Reset cached profile
  profile: ^PeerProfile = auto_cast event.peer.data
  profile._in_use = false
  profile.status = .Unauthorized

  return .Success
}

handle_receive_event :: proc(server_info: ^ServerInfo, event: ^enet.Event) -> Error {
  // Parse the received data packet
  pd: ^cm.PacketData = cm.parse_packet(event.packet.data, auto_cast event.packet.dataLength)
  
  //  auto_cast event.packet.data
  fmt.println("[S] Received packet:", pd.data_type, "size:", event.packet.dataLength)

  #partial switch pd.data_type {
    case .AuthenticationRequest:
      handle_authentication_request(server_info, event, auto_cast &pd.data) or_return
    case:
      fmt.println("[S] Error? Unknown packet type:", pd.data_type)
      return .NotYetDetailed
  }

  return .Success
}

handle_authentication_request :: proc(server_info: ^ServerInfo, event: ^enet.Event, request: ^cm.AuthenticationRequest) -> Error {
  fmt.println("[S] Received authentication request")

  fmt.println("[S] request:", request)

  // Get profile
  profile: ^PeerProfile = auto_cast event.peer.data
  if profile.status != .Unauthorized {
    fmt.println("[S] Error? Client is already authorized")
    return .Success
  }

  // Check credentials
  fmt.println(args={"[S] request.username:'", request.username, "'<>'test-user' =", strings.compare(request.username, "test-user")}, sep = "")
  fmt.println(args={"[S] request.password:'", request.password, "'<>'test-pass' =", strings.compare(request.password, "test-pass")}, sep = "")
  if strings.compare(request.username, "test-user") == 0 && strings.compare(request.password, "test-pass") == 0 {
    fmt.println("[S] Client", request.username, "authenticated")
    profile.status = .Authorized
  } else {
    fmt.println("[S] Client authentication failed for user:", request.username)
  }

  return .Success
}