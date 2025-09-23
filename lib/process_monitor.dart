import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// C structures for FFI
base class ProcessEventData extends Struct {
  @Array(32)
  external Array<Uint8> _eventType;     // "start" or "stop"
  
  @Array(512)
  external Array<Uint8> _processName;   // Process name
  
  @Int32()
  external int processId;               // Process ID
  
  @Int64()
  external int timestampMs;             // Timestamp in milliseconds since epoch

  String get processName {
    final bytes = <int>[];
    for (int i = 0; i < 512; i++) {
      final byte = _processName[i];
      if (byte == 0) break;
      bytes.add(byte);
    }
    return String.fromCharCodes(bytes);
  }

  String get eventType {
    final bytes = <int>[];
    for (int i = 0; i < 32; i++) {
      final byte = _eventType[i];
      if (byte == 0) break;
      bytes.add(byte);
    }
    return String.fromCharCodes(bytes);
  }
}

// FFI function signatures
typedef InitializeProcessMonitorNative = Bool Function();
typedef InitializeProcessMonitorDart = bool Function();

typedef StartMonitoringNative = Bool Function();
typedef StartMonitoringDart = bool Function();

typedef StopMonitoringNative = Bool Function();
typedef StopMonitoringDart = bool Function();

// Callback function type
typedef ProcessEventCallbackNative = Void Function(Pointer<ProcessEventData>, Pointer<Void>);
typedef ProcessEventCallbackDart = void Function(Pointer<ProcessEventData>, Pointer<Void>);

typedef StartMonitoringWithCallbackNative = Bool Function(Pointer<NativeFunction<ProcessEventCallbackNative>>, Pointer<Void>);
typedef StartMonitoringWithCallbackDart = bool Function(Pointer<NativeFunction<ProcessEventCallbackNative>>, Pointer<Void>);

typedef GetNextEventNative = Bool Function(Pointer<ProcessEventData>);
typedef GetNextEventDart = bool Function(Pointer<ProcessEventData>);

typedef WaitForEventsNative = Int32 Function(Int32);
typedef WaitForEventsDart = int Function(int);

typedef GetAllEventsNative = Int32 Function(Pointer<ProcessEventData>, Int32);
typedef GetAllEventsDart = int Function(Pointer<ProcessEventData>, int);

typedef IsMonitoringNative = Bool Function();
typedef IsMonitoringDart = bool Function();

typedef GetPendingEventCountNative = Int32 Function();
typedef GetPendingEventCountDart = int Function();

typedef CleanupProcessMonitorNative = Void Function();
typedef CleanupProcessMonitorDart = void Function();

typedef GetLastErrorNative = Pointer<Utf8> Function();
typedef GetLastErrorDart = Pointer<Utf8> Function();

class ProcessEvent {
  final String processName;
  final int processId;
  final String eventType;
  final DateTime timestamp;

  ProcessEvent({
    required this.processName,
    required this.processId,
    required this.eventType,
    required this.timestamp,
  });

  @override
  String toString() {
    return 'ProcessEvent(processName: $processName, processId: $processId, eventType: $eventType, timestamp: $timestamp)';
  }
}

class ProcessMonitor {
  static ProcessMonitor? _instance;
  static ProcessMonitor get instance => _instance ??= ProcessMonitor._();

  ProcessMonitor._();
  
  // Add factory constructor for backwards compatibility
  factory ProcessMonitor() => instance;

  DynamicLibrary? _lib;
  InitializeProcessMonitorDart? _initialize;
  StartMonitoringDart? _startMonitoring;
  StopMonitoringDart? _stopMonitoring;
  WaitForEventsDart? _waitForEvents;
  GetAllEventsDart? _getAllEvents;
  IsMonitoringDart? _isMonitoring;
  GetPendingEventCountDart? _getPendingEventCount;
  CleanupProcessMonitorDart? _cleanup;
  GetLastErrorDart? _getLastError;

  final StreamController<ProcessEvent> _eventController = StreamController<ProcessEvent>.broadcast();
  Timer? _pollingTimer;
  bool _isInitialized = false;
  Isolate? _backgroundIsolate;
  ReceivePort? _receivePort;

  Stream<ProcessEvent> get events => _eventController.stream;
  Stream<ProcessEvent> get processEvents => _eventController.stream; // Alias for compatibility

  bool get isMonitoring {
    if (_isMonitoring == null) return _pollingTimer != null;
    return _isMonitoring!();
  }

  int get pendingEventCount {
    if (_getPendingEventCount == null) return 0;
    return _getPendingEventCount!();
  }

  String get lastError {
    if (_getLastError == null) return '';
    final errorPtr = _getLastError!();
    if (errorPtr == nullptr) return '';
    return errorPtr.toDartString();
  }

  bool initialize() {
    if (_isInitialized) return true;

    try {
      // Try to load the FFI DLL - it should be in the same directory as the exe
      const dllPath = 'process_monitor.dll';
      
      _lib = DynamicLibrary.open(dllPath);

      // Load function pointers
      _initialize = _lib!.lookupFunction<InitializeProcessMonitorNative, InitializeProcessMonitorDart>('initialize_process_monitor');
      _startMonitoring = _lib!.lookupFunction<StartMonitoringNative, StartMonitoringDart>('start_monitoring');
      _stopMonitoring = _lib!.lookupFunction<StopMonitoringNative, StopMonitoringDart>('stop_monitoring');
      _waitForEvents = _lib!.lookupFunction<WaitForEventsNative, WaitForEventsDart>('wait_for_events');
      _getAllEvents = _lib!.lookupFunction<GetAllEventsNative, GetAllEventsDart>('get_all_events');
      _isMonitoring = _lib!.lookupFunction<IsMonitoringNative, IsMonitoringDart>('is_monitoring');
      _getPendingEventCount = _lib!.lookupFunction<GetPendingEventCountNative, GetPendingEventCountDart>('get_pending_event_count');
      _cleanup = _lib!.lookupFunction<CleanupProcessMonitorNative, CleanupProcessMonitorDart>('cleanup_process_monitor');
      _getLastError = _lib!.lookupFunction<GetLastErrorNative, GetLastErrorDart>('get_last_error');

      // Initialize the native library
      final success = _initialize!();
      if (!success) {
        print('Failed to initialize process monitor: ${lastError}');
        return false;
      }

      _isInitialized = true;
      if (kDebugMode) {
        print('ProcessMonitor initialized - FFI Mode');
      }
      return true;

    } catch (e) {
      if (kDebugMode) {
        print('Failed to load FFI library: $e');
        print('Running in test mode');
      }
      _isInitialized = true; // Still mark as initialized for test mode
      return true;
    }
  }

  Future<bool> startMonitoring() async {
    if (kDebugMode) {
      print('[DEBUG] ProcessMonitor.startMonitoring() called');
    }
    
    if (!_isInitialized && !initialize()) {
      if (kDebugMode) {
        print('[ERROR] Failed to initialize ProcessMonitor');
      }
      return false;
    }

    // Use event-driven monitoring (no polling!)
    if (_startMonitoring != null && _waitForEvents != null && _getAllEvents != null) {
      if (kDebugMode) {
        print('[DEBUG] Using event-driven monitoring (no polling)');
        print('[DEBUG] Calling native start_monitoring()');
      }
      final success = _startMonitoring!();
      if (!success) {
        print('Failed to start monitoring: ${lastError}');
        return false;
      }
      if (kDebugMode) {
        print('[DEBUG] Native start_monitoring() returned: $success');
      }

      // Start the event waiting in background isolate
      await _startBackgroundEventLoop();
      
      return true;
    }

    // Fall back to test mode
    if (kDebugMode) {
      print('[DEBUG] Falling back to test mode');
    }
    _startTestMode();
    return true;
  }

  Future<void> _startBackgroundEventLoop() async {
    if (kDebugMode) {
      print('[DEBUG] Starting background event loop in isolate');
    }
    
    // Create a receive port to get events from the isolate
    _receivePort = ReceivePort();
    
    // Listen to events from the background isolate
    _receivePort!.listen((data) {
      if (data is Map<String, dynamic>) {
        try {
          final event = ProcessEvent(
            processName: data['processName'] as String,
            processId: data['processId'] as int,
            eventType: data['eventType'] as String,
            timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestampMs'] as int),
          );
          
          if (!_eventController.isClosed) {
            _eventController.add(event);
          }
          
          if (kDebugMode) {
            print('[DEBUG] Event received: ${event.eventType} - ${event.processName} (${event.processId})');
          }
        } catch (e) {
          if (kDebugMode) {
            print('[ERROR] Error processing event from isolate: $e');
          }
        }
      } else if (data == 'stopped') {
        if (kDebugMode) {
          print('[DEBUG] Background event loop stopped');
        }
      }
    });
    
    // Start the background isolate
    try {
      _backgroundIsolate = await Isolate.spawn(
        _eventLoopIsolate,
        _receivePort!.sendPort,
      );
      
      if (kDebugMode) {
        print('[DEBUG] Background isolate started successfully');
      }
    } catch (e) {
      if (kDebugMode) {
        print('[ERROR] Failed to start background isolate: $e');
      }
      _receivePort?.close();
      _receivePort = null;
    }
  }

  // Static method that runs in the background isolate
  static void _eventLoopIsolate(SendPort sendPort) async {
    if (kDebugMode) {
      print('[DEBUG] Event loop isolate started');
    }
    
    // We need to reinitialize the DLL in this isolate
    DynamicLibrary? lib;
    WaitForEventsDart? waitForEvents;
    GetAllEventsDart? getAllEvents;
    IsMonitoringDart? isMonitoring;
    
    try {
      // Load the DLL in this isolate
      const dllPath = 'process_monitor.dll';
      lib = DynamicLibrary.open(dllPath);
      
      // Load the functions we need
      waitForEvents = lib.lookupFunction<WaitForEventsNative, WaitForEventsDart>('wait_for_events');
      getAllEvents = lib.lookupFunction<GetAllEventsNative, GetAllEventsDart>('get_all_events');
      isMonitoring = lib.lookupFunction<IsMonitoringNative, IsMonitoringDart>('is_monitoring');
      
      if (kDebugMode) {
        print('[DEBUG] DLL loaded successfully in isolate');
      }
    } catch (e) {
      if (kDebugMode) {
        print('[ERROR] Failed to load DLL in isolate: $e');
      }
      sendPort.send('stopped');
      return;
    }
    
    // Event loop in background isolate
    while (true) {
      try {
        // Check if monitoring is still active
        if (!isMonitoring()) {
          if (kDebugMode) {
            print('[DEBUG] Monitoring stopped, exiting isolate');
          }
          break;
        }
        
        // Wait for events with 1 second timeout
        final eventCount = waitForEvents(1000);
        
        if (eventCount > 0) {
          // Events available, fetch all of them
          const maxEvents = 100;
          final eventsArray = calloc<ProcessEventData>(maxEvents);
          
          try {
            final actualCount = getAllEvents(eventsArray, maxEvents);
            
            // Send all events to main isolate
            for (int i = 0; i < actualCount; i++) {
              final eventData = eventsArray.elementAt(i).ref;
              
              sendPort.send({
                'processName': eventData.processName,
                'processId': eventData.processId,
                'eventType': eventData.eventType,
                'timestampMs': eventData.timestampMs,
              });
            }
          } finally {
            calloc.free(eventsArray);
          }
        } else if (eventCount < 0) {
          // Error occurred
          if (kDebugMode) {
            print('[DEBUG] Error waiting for events in isolate: $eventCount');
          }
          break;
        }
        // eventCount == 0 means timeout, which is normal
        
      } catch (e) {
        if (kDebugMode) {
          print('[ERROR] Event loop isolate error: $e');
        }
        break;
      }
    }
    
    sendPort.send('stopped');
    if (kDebugMode) {
      print('[DEBUG] Event loop isolate ended');
    }
  }

  void _startTestMode() {
    if (kDebugMode) {
      print('Starting test mode with fake events');
    }
    
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      final events = [
        ProcessEvent(
          processName: 'notepad.exe',
          processId: 1234,
          eventType: 'start',
          timestamp: DateTime.now(),
        ),
        ProcessEvent(
          processName: 'calculator.exe',
          processId: 5678,
          eventType: 'start',
          timestamp: DateTime.now(),
        ),
        ProcessEvent(
          processName: 'notepad.exe',
          processId: 1234,
          eventType: 'stop',
          timestamp: DateTime.now(),
        ),
      ];
      
      for (final event in events) {
        _eventController.add(event);
      }
    });
  }

  Future<bool> stopMonitoring() async {
    if (kDebugMode) {
      print('[DEBUG] ProcessMonitor.stopMonitoring() called');
    }
    
    try {
      // Cancel timer immediately (fallback for polling mode)
      if (kDebugMode) {
        print('[DEBUG] Cancelling polling timer');
      }
      _pollingTimer?.cancel();
      _pollingTimer = null;
      
      // Clean up background isolate
      if (_backgroundIsolate != null) {
        if (kDebugMode) {
          print('[DEBUG] Killing background isolate');
        }
        _backgroundIsolate!.kill(priority: Isolate.immediate);
        _backgroundIsolate = null;
      }
      
      // Clean up receive port
      if (_receivePort != null) {
        if (kDebugMode) {
          print('[DEBUG] Closing receive port');
        }
        _receivePort!.close();
        _receivePort = null;
      }

      if (_stopMonitoring != null) {
        if (kDebugMode) {
          print('[DEBUG] Calling native stop_monitoring()');
        }
        // Just call the native stop (which now only sets a flag)
        final success = _stopMonitoring!();
        
        if (!success) {
          print('Failed to stop monitoring: ${lastError}');
        }
        
        if (kDebugMode) {
          print('[DEBUG] Native stop_monitoring() returned: $success');
        }
        
        return success;
      }

      if (kDebugMode) {
        print('[DEBUG] No native stop function available');
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('Exception during stop monitoring: $e');
      }
      return false;
    }
  }

  Future<void> dispose() async {
    try {
      if (kDebugMode) {
        print('[DEBUG] ProcessMonitor.dispose() called');
      }
      
      // Stop monitoring immediately and synchronously
      if (isMonitoring) {
        if (kDebugMode) {
          print('[DEBUG] Stopping monitoring during dispose');
        }
        await stopMonitoring();
      }
      
      // Cancel timer immediately
      _pollingTimer?.cancel();
      _pollingTimer = null;
      
      // Close event controller immediately
      if (!_eventController.isClosed) {
        _eventController.close();
      }
      
      // Cleanup the native library immediately
      if (_cleanup != null) {
        try {
          if (kDebugMode) {
            print('[DEBUG] Calling native cleanup during dispose');
          }
          _cleanup!();
          if (kDebugMode) {
            print('[DEBUG] Native cleanup completed');
          }
        } catch (e) {
          if (kDebugMode) {
            print('Error during native cleanup: $e');
          }
        }
      }
      
      _isInitialized = false;
      
      if (kDebugMode) {
        print('[DEBUG] ProcessMonitor.dispose() completed');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error during dispose: $e');
      }
    }
  }
}
