package launcher

import "core:time"
import "core:sync"

import enet "vendor:ENet"

Error :: enum {
  Success = 0,
  NotYetDetailed,
}

NetworkStatus :: enum {
  Uninitialized = 0,
  Idle,
  Initializing,
  Initialized,
  Connecting,
  Connected,
  Disconnecting,
  Disconnected,
  Shutdown,
}

NetworkData :: struct {
  should_close: bool,
  // mutex: sync.Mutex, TODO: use this
  status: NetworkStatus,

  server_address: enet.Address,
  connection_sequence_retries: int,
  connection_sequence_retry_time: time.Time,
}

LauncherData :: struct {
  net: NetworkData,
}