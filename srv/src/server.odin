package server

import "core:fmt"
import "core:time"

import enet "vendor:ENet"

main :: proc() {
  fmt.println("server begin!")
  defer fmt.println("server end!")
  defer time.sleep(time.Second * 2)

  res := enet.initialize()
  if res != 0 {
    fmt.println("failed to initialize enet")
    return
  }
  defer enet.deinitialize()

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
  event: enet.Event
  for enet.host_service(server, &event, 5000) > 0 {
    switch event.type {
      case .CONNECT:
        fmt.println("client connected!")
      case .RECEIVE:
        fmt.println("client received: ") //, string(event.packet.data))
        // enet.packet_destroy(event.packet)
      case .DISCONNECT:
        fmt.println("client disconnected!")
      case .NONE:
        fmt.println("client none!")
    }
  }
  
  return
}