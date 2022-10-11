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

main :: proc() {
  time.sleep(time.Second * 1)
  fmt.println("[C] client begin!")
  defer fmt.println("[C] client end!")
  
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

    cm.send_packet(peer, .AuthenticationRequest, .RELIABLE, "test-user", "test-pass")
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