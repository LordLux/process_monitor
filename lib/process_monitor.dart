import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// C structure for process event data, used for FFI with the native DLL.
base class ProcessEventData extends Struct {
  @Array(32)
  external Array<Uint8> _eventType; // "start" or "stop"

  @Array(512)
  external Array<Uint8> _processName; // Process name

  @Int32()
  external int processId; // Process ID

  @Int64()
  external int timestampMs; // Timestamp in milliseconds since epoch

  /// Returns the process name as a Dart string.
  String get processName {
    final bytes = <int>[];
    for (int i = 0; i < 512; i++) {
      final byte = _processName[i];
      if (byte == 0) break;
      bytes.add(byte);
    }
    return String.fromCharCodes(bytes);
  }

  /// Returns the event type ("start" or "stop") as a Dart string.
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

/// Represents a process event (start/stop) detected by the monitor.
class ProcessEvent {
  final String processName;
  final int processId;
  final String eventType;
  final DateTime timestamp;

  ProcessEvent({required this.processName, required this.processId, required this.eventType, required this.timestamp});

  @override
  String toString() => 'ProcessEvent(processName: $processName, processId: $processId, eventType: $eventType, timestamp: $timestamp)';
}

/// Configuration for monitoring a specific process
///
/// Used to specify which process to monitor, and what callbacks to run when it starts or stops.
class ProcessConfig {
  /// The name of the process to monitor
  final String processName;

  /// Callback called when the process starts
  final void Function(ProcessEvent event)? onStart;

  /// Callback called when the process stops
  final void Function(ProcessEvent event)? onStop;

  /// Whether to call onStart callback for multiple instances of the same process
  /// If false, onStart is only called for the first instance
  final bool allowMultipleStartCallbacks;

  /// Whether to call onStop callback for multiple instances of the same process
  /// If false, onStop is only called when the last instance stops
  final bool allowMultipleStopCallbacks;

  ProcessConfig({required this.processName, this.onStart, this.onStop, this.allowMultipleStartCallbacks = true, this.allowMultipleStopCallbacks = true});

  @override
  String toString() => 'ProcessConfig(processName: $processName, allowMultipleStart: $allowMultipleStartCallbacks, allowMultipleStop: $allowMultipleStopCallbacks)';
}

/// Main API for process monitoring.
///
/// Use [ProcessMonitor] to start/stop monitoring, listen to process events, and configure process-specific callbacks.
class ProcessMonitor {
  static ProcessMonitor? _instance;
  static ProcessMonitor get instance => _instance ??= ProcessMonitor._();

  ProcessMonitor._();

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

  // New fields for process-specific monitoring
  List<ProcessConfig>? _processConfigs;
  final Map<String, Set<int>> _runningProcesses = {}; // processName -> Set of PIDs

  // Deduplication mechanism for events
  final Set<String> _recentEvents = {}; // Store recent event signatures to detect duplicates

  /// Stream of all process events.
  Stream<ProcessEvent> get events => _eventController.stream;

  /// Whether the monitor is currently active.
  bool get isMonitoring {
    if (_isMonitoring == null) return _pollingTimer != null;
    return _isMonitoring!();
  }

  /// Number of pending events in the native queue.
  int get pendingEventCount {
    if (_getPendingEventCount == null) return 0;
    return _getPendingEventCount!();
  }

  /// Last error message from the native DLL, if any.
  String get lastError {
    if (_getLastError == null) return '';
    final errorPtr = _getLastError!();

    if (errorPtr == nullptr) return '';
    return errorPtr.toDartString();
  }

  /// Initializes the native DLL and loads FFI function pointers.
  /// Returns true if successful, false otherwise.
  bool initialize() {
    if (_isInitialized) return true;

    try {
      // Try to load the FFI DLL
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
        print('Failed to initialize process monitor: $lastError');
        return false;
      }

      _isInitialized = true;
      return true;
    } catch (e) {
      print('Failed to load FFI library: $e');
      return false;
    }
  }

  /// Starts monitoring all processes (general mode).
  /// Returns true if monitoring started successfully.
  Future<bool> startMonitoring() async {
    if (!_isInitialized && !initialize()) {
      print('[ERROR] Failed to initialize ProcessMonitor');
      return false;
    }

    // Use event-driven monitoring (no polling!)
    if (_startMonitoring != null && _waitForEvents != null && _getAllEvents != null) {
      final success = _startMonitoring!();
      if (!success) {
        print('Failed to start monitoring: $lastError');
        return false;
      }

      // Start the event waiting in background isolate
      await _startBackgroundEventLoop();
      return true;
    }
    return true;
  }

  /// Start monitoring specific processes with individual callbacks.
  ///
  /// [processConfigs] - List of process configurations specifying which processes to monitor and their respective callbacks.
  /// Returns true if monitoring started successfully.
  Future<bool> startMonitoringProcesses(List<ProcessConfig> processConfigs) async {
    if (processConfigs.isEmpty) return false;

    // Store process configurations
    _processConfigs = processConfigs;
    _runningProcesses.clear();

    // Initialize all process sets
    for (final config in processConfigs) {
      _runningProcesses[config.processName] = <int>{};
    }

    // Start general monitoring first
    final success = await startMonitoring();
    if (!success) {
      _processConfigs = null;
      _runningProcesses.clear();
      return false;
    }

    // Set up event filtering and callback routing
    _setupProcessSpecificEventHandling();

    return true;
  }

  /// Sets up process-specific event handling (internal).
  void _setupProcessSpecificEventHandling() {
    if (_processConfigs == null) return;
  }

  /// Cleans up old event signatures from deduplication cache (internal).
  void _cleanupOldEventSignatures() {
    // In a production app, you might want to implement time-based cleanup
    // For now, just limit the size to prevent memory leaks
    if (_recentEvents.length > 1000) {
      // Remove half of the entries (oldest ones)
      final signatures = _recentEvents.toList();
      _recentEvents.clear();
      // Add back the more recent half
      _recentEvents.addAll(signatures.sublist(signatures.length ~/ 2));
    }
  }

  /// Handles process-specific callbacks for a given event (internal).
  void _handleProcessSpecificEvent(ProcessEvent event) {
    if (_processConfigs == null) return;

    // Find the process config for this event
    ProcessConfig? config;
    for (final processConfig in _processConfigs!) {
      if (processConfig.processName.toLowerCase() == event.processName.toLowerCase()) {
        config = processConfig;
        break;
      }
    }

    // If the process not in our monitoring list, ignore
    if (config == null) return;

    final processName = config.processName;
    final processInstances = _runningProcesses[processName]!;

    if (event.eventType == 'start') {
      final wasEmpty = processInstances.isEmpty;
      processInstances.add(event.processId);

      // Call start callback based on configuration
      if (config.onStart != null) {
        if (config.allowMultipleStartCallbacks || wasEmpty) {
          try {
            config.onStart!(event);
          } catch (e) {
            print('[ERROR] Error in onStart callback for ${event.processName}: $e');
          }
        } else {
          // Skipped due to configuration
        }
      }
    } else if (event.eventType == 'stop') {
      processInstances.remove(event.processId);
      final isEmpty = processInstances.isEmpty;

      // Call stop callback based on configuration
      if (config.onStop != null) {
        if (config.allowMultipleStopCallbacks || isEmpty) {
          try {
            config.onStop!(event);
          } catch (e) {
            print('[ERROR] Error in onStop callback for ${event.processName}: $e');
          }
        } else {
          // Skipped due to configuration
        }
      }
    }
  }

  /// Starts the background isolate that receives process events from the native DLL (internal).
  Future<void> _startBackgroundEventLoop() async {
    // Create a receive port to get events from the isolate
    _receivePort = ReceivePort();

    // Listen to events from the background isolate
    _receivePort!.listen((data) {
      if (data is Map<String, dynamic>) {
        try {
          final event = ProcessEvent(processName: data['processName'] as String, processId: data['processId'] as int, eventType: data['eventType'] as String, timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestampMs'] as int));

          // Create a unique signature for this event
          final eventSignature = '${event.eventType}-${event.processName}-${event.processId}-${event.timestamp.millisecondsSinceEpoch ~/ 1000}'; // Round to nearest second

          // Check for duplicate events within the deduplication window
          if (_recentEvents.contains(eventSignature)) {
            // Duplicate event, ignore
            return;
          }

          // Add to recent events and clean up old entries
          _recentEvents.add(eventSignature);
          _cleanupOldEventSignatures();

          // Handle process-specific callbacks if configured (only once)
          if (_processConfigs != null) _handleProcessSpecificEvent(event);

          // Always add to the general event stream for backward compatibility
          if (!_eventController.isClosed) _eventController.add(event);
        } catch (e) {
          print('[ERROR] Error processing event from isolate: $e');
        }
      } else if (data == 'stopped') {
        // Isolate signaled it has stopped
      }
    });

    // Start the background isolate
    try {
      _backgroundIsolate = await Isolate.spawn(_eventLoopIsolate, _receivePort!.sendPort);
    } catch (e) {
      print('[ERROR] Failed to start background isolate: $e');

      _receivePort?.close();
      _receivePort = null;
    }
  }

  // Static method that runs in the background isolate
  /// Background isolate entry point for receiving process events from the native DLL (internal).
  static void _eventLoopIsolate(SendPort sendPort) async {
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
    } catch (e) {
      print('[ERROR] Failed to load DLL in isolate: $e');
      sendPort.send('stopped');
      return;
    }

    // Event loop in background isolate
    while (true) {
      try {
        // Check if monitoring is still active
        if (!isMonitoring()) break;

        // Wait for events with 500 milliseconds timeout
        final eventCount = waitForEvents(500);

        if (eventCount > 0) {
          // Events available, fetch all of them
          const maxEvents = 100;
          final eventsArray = calloc<ProcessEventData>(maxEvents);

          try {
            final actualCount = getAllEvents(eventsArray, maxEvents);

            // Send all events to main isolate
            for (int i = 0; i < actualCount; i++) {
              final eventData = eventsArray.elementAt(i).ref;

              sendPort.send({'processName': eventData.processName, 'processId': eventData.processId, 'eventType': eventData.eventType, 'timestampMs': eventData.timestampMs});
            }
          } finally {
            calloc.free(eventsArray);
          }
        } else if (eventCount < 0) {
          // This means an error has occurred
          print('[DEBUG] Error waiting for events in isolate: $eventCount');
          break;
        }
        // eventCount == 0 means timeout which is normal
      } catch (e) {
        print('[ERROR] Event loop isolate error: $e');
        break;
      }
    }

    sendPort.send('stopped');
  }

  /// Stops process monitoring and cleans up resources.
  /// Returns true if stopped successfully.
  Future<bool> stopMonitoring() async {
    // Clear process-specific configurations
    _processConfigs = null;
    _runningProcesses.clear();
    _recentEvents.clear(); // Clear deduplication cache

    try {
      // Cancel timer immediately
      _pollingTimer?.cancel();
      _pollingTimer = null;

      // Clean up background isolate
      if (_backgroundIsolate != null) {
        _backgroundIsolate!.kill(priority: Isolate.immediate);
        _backgroundIsolate = null;
      }

      // Clean up receive port
      if (_receivePort != null) {
        _receivePort!.close();
        _receivePort = null;
      }

      if (_stopMonitoring != null) {
        // Just call the native stop (which now only sets a flag)
        final success = _stopMonitoring!();

        if (!success) print('Failed to stop monitoring: $lastError');
        return success;
      }
      return true;
    } catch (e) {
      print('Exception during stop monitoring: $e');
    }
    return false;
  }

  /// Disposes the monitor, stops monitoring, and releases all resources.
  Future<void> dispose() async {
    try {
      // Clear process-specific configurations
      _processConfigs = null;
      _runningProcesses.clear();

      // Stop monitoring immediately and synchronously
      if (isMonitoring) await stopMonitoring();

      // Cancel timer immediately
      _pollingTimer?.cancel();
      _pollingTimer = null;

      // Close event controller immediately
      if (!_eventController.isClosed) _eventController.close();

      // Cleanup the native library immediately
      if (_cleanup != null) {
        try {
          _cleanup!();
        } catch (e) {
          print('Error during native cleanup: $e');
        }
      }

      _isInitialized = false;
    } catch (e) {
      print('Error during dispose: $e');
    }
  }
}
