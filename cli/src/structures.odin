package client

Error :: enum {
  Success = 0,
  NotYetDetailed,
}

NetworkStatus :: enum {
  NotConnected = 0,
  Connecting,
  Connected,
  Disconnected,
  Shutdown,
}

NetworkData :: struct {
  is_active: bool,
  should_close: bool,

  status: NetworkStatus,
}

GameData :: struct {
  network: NetworkData,
}