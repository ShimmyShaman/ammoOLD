package common

import "core:fmt"

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
  type: PacketDataType,
  data: union {
    AuthenticationRequest,
  },
}