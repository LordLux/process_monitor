import 'dart:async';
import 'dart:ffi';

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

typedef GetNextEventNative = Bool Function(Pointer<ProcessEventData>);
typedef GetNextEventDart = bool Function(Pointer<ProcessEventData>);

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
  GetNextEventDart? _getNextEvent;
  IsMonitoringDart? _isMonitoring;
  GetPendingEventCountDart? _getPendingEventCount;
  CleanupProcessMonitorDart? _cleanup;
  GetLastErrorDart? _getLastError;

  final StreamController<ProcessEvent> _eventController = StreamController<ProcessEvent>.broadcast();
  Timer? _pollingTimer;
  bool _isInitialized = false;

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
      _getNextEvent = _lib!.lookupFunction<GetNextEventNative, GetNextEventDart>('get_next_event');
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

    // If we have FFI functions, use them
    if (_startMonitoring != null) {
      if (kDebugMode) {
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

      // Start polling for events
      if (kDebugMode) {
        print('[DEBUG] Starting event polling timer');
      }
      _pollingTimer = Timer.periodic(const Duration(milliseconds: 100), _pollForEvents);
      return true;
    }

    // Fall back to test mode
    if (kDebugMode) {
      print('[DEBUG] Falling back to test mode');
    }
    _startTestMode();
    return true;
  }

  void _pollForEvents(Timer timer) {
    if (_getNextEvent == null) return;

    final eventData = calloc<ProcessEventData>();
    try {
      while (_getNextEvent!(eventData)) {
        final timestampMs = eventData.ref.timestampMs;
        
        // Safety check for invalid timestamps
        DateTime timestamp;
        if (timestampMs > 0 && timestampMs < 4102444800000) { // Valid range (before year 2100)
          timestamp = DateTime.fromMillisecondsSinceEpoch(timestampMs);
        } else {
          if (kDebugMode) {
            print('Invalid timestamp received: $timestampMs, using current time');
          }
          timestamp = DateTime.now();
        }
        
        final event = ProcessEvent(
          processName: eventData.ref.processName,
          processId: eventData.ref.processId,
          eventType: eventData.ref.eventType,
          timestamp: timestamp,
        );
        
        if (kDebugMode) {
          print('Process event: ${event.eventType} - ${event.processName} (${event.processId}) at $timestampMs');
        }
        
        _eventController.add(event);
      }
    } finally {
      calloc.free(eventData);
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
      // Cancel timer immediately
      if (kDebugMode) {
        print('[DEBUG] Cancelling polling timer');
      }
      _pollingTimer?.cancel();
      _pollingTimer = null;

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

  void dispose() {
    try {
      // Stop monitoring first
      stopMonitoring();
      
      // Small delay to ensure stop completes
      Future.delayed(const Duration(milliseconds: 100), () {
        // Cleanup the native library
        if (_cleanup != null) {
          try {
            _cleanup!();
          } catch (e) {
            if (kDebugMode) {
              print('Error during cleanup: $e');
            }
          }
        }
      });
      
      if (!_eventController.isClosed) {
        _eventController.close();
      }
      
      _isInitialized = false;
    } catch (e) {
      if (kDebugMode) {
        print('Error during dispose: $e');
      }
    }
  }
}
