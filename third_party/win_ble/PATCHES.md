Vendored from win_ble 1.1.1 (MIT; see LICENSE). Original BLEServer.exe unchanged.
The Dart IPC connector now buffers length-prefixed UTF-8 frames, registers
pending calls before sending, applies timeouts and fails calls on helper exit.
Stderr is logged instead of thrown from an unowned stream callback.
