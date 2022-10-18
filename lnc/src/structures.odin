package launcher

Error :: enum {
  Success = 0,
  NotYetDetailed,
}

NetworkStatus :: enum {
  Uninitialized = 0,
  Idle,
  Initializing,
  Connecting,
  Connected,
  Disconnected,
  Shutdown,
}

NetworkData :: struct {
  should_close: bool,
  status: NetworkStatus,
}

LauncherData :: struct {
  net: NetworkData,
}