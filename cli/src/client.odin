package server

import "core:fmt"
import "core:time"

import enet "vendor:ENet"

main :: proc() {
  fmt.println("client begin!")
  defer fmt.println("client end!")
  time.sleep(time.Second * 1)
  
  res := enet.initialize()
  if res != 0 {
    fmt.println("failed to initialize enet")
    return
  }
  defer enet.deinitialize()

  client := enet.host_create(nil, 1, 2, 0, 0)
  if client == nil {
    fmt.println("client create failed!")
    return
  }
  defer enet.host_destroy(client)

  server_address := enet.Address {
    port = 1234,
  }
  enet.address_set_host_ip(&server_address, "127.0.0.1")

  peer := enet.host_connect(client, &server_address, 2, 0)
  if peer == nil {
    fmt.println("peer create failed!")
    return
  }

  event: enet.Event
  fmt.println("connecting...")
  if enet.host_service(client, &event, 5000) > 0 && event.type == .CONNECT {
    fmt.println("connected to server!")
  } else {
    enet.peer_reset(peer)
    fmt.println("connection to server failed!")
    return
  }

  for enet.host_service(client, &event, 4000) > 0 {
    switch event.type {
      case .CONNECT:
        fmt.println("client connected!")
      case .RECEIVE:
        fmt.println("client received: ", cstring(event.packet.data))
        // enet.packet_destroy(event.packet)
      case .DISCONNECT:
        fmt.println("client disconnected!")
      case .NONE:
        fmt.println("client none!")
    }
  }

  enet.peer_disconnect(peer, 0)

  r := 0
  disconnect_loop: for {
    res := enet.host_service(client, &event, 1000) > 0
    #partial switch event.type {
      case .DISCONNECT:
        time.sleep(time.Second * 1)
        fmt.println("client disconnected!")
        break disconnect_loop
    }
    
    r += 1
    if r > 10 do break disconnect_loop
  }
}