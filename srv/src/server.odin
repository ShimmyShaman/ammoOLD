package server

import "core:fmt"
import "core:time"

import enet "vendor:ENet"

ClientStatus :: enum {
  Unauthorized = 0,
  Authorized = 1,
}

PeerProfile :: struct {
  status: ClientStatus,
}

main :: proc() {
  fmt.println("server begin!")
  defer fmt.println("server end!")
  defer time.sleep(time.Second * 2)

  // Initialize
  res := enet.initialize()
  if res != 0 {
    fmt.println("failed to initialize enet")
    return
  }
  defer enet.deinitialize()

  // Create host
  address := enet.Address {
    host = enet.HOST_ANY,
    port = 1234,
  }
  enet.address_set_host(&address, "127.0.0.1")

  server := enet.host_create(&address, 32, 2, 0, 0)
  if server == nil {
    fmt.println("failed to create server")
    return
  }
  defer enet.host_destroy(server)
  fmt.println("server created")

  // Listen for events
  event: enet.Event
  for {
    res := enet.host_service(server, &event, 5000)
    if res < 1 do continue
    switch event.type {
      case .CONNECT:
        fmt.println(args={"Client Connection:", event.peer.address.host, ":", event.peer.address.port,
          " [connectedPeers=", server.connectedPeers, "]"}, sep = "")

      case .RECEIVE:
        fmt.println("server received: ") //, string(event.packet.data))
        // enet.packet_destroy(event.packet)
      case .DISCONNECT:
        fmt.println(args={"Client Disconnection:", event.peer.address.host, ":", event.peer.address.port,
          " [connectedPeers=", server.connectedPeers, "]"}, sep = "")
      case .NONE:
        fmt.println("server none!")
    }
  }

  return
}