// ignore_for_file: library_private_types_in_public_api

import 'dart:async';

/// Represents a process event (start or stop)
class ProcessEvent {
  final String eventType; // "start" or "stop"
  final String processName;
  final int processId;
  final DateTime timestamp;

  ProcessEvent({
    required this.eventType,
    required this.processName,
    required this.processId,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() {
    return 'ProcessEvent{eventType: $eventType, processName: $processName, processId: $processId, timestamp: $timestamp}';
  }
}

class ProcessMonitor {
  static final ProcessMonitor _instance = ProcessMonitor._internal();
  factory ProcessMonitor() => _instance;

  bool _isMonitoring = false;
  StreamController<ProcessEvent>? _eventsController;
  Timer? _testTimer;

  ProcessMonitor._internal() {
    // Simple test implementation without FFI callbacks for now
    print('ProcessMonitor initialized - Test Mode');
  }

  /// Stream of process events (start/stop)
  Stream<ProcessEvent> get processEvents {
    _eventsController ??= StreamController<ProcessEvent>.broadcast();
    return _eventsController!.stream;
  }

  /// Start monitoring process events
  Future<bool> startMonitoring() async {
    if (_isMonitoring) {
      return true; // Already monitoring
    }

    try {
      _isMonitoring = true;
      
      _eventsController ??= StreamController<ProcessEvent>.broadcast();
      
      // For testing, create a timer that generates fake process events
      _testTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
        if (!_isMonitoring) {
          timer.cancel();
          return;
        }
        
        // Generate a random process event
        final processNames = ['notepad.exe', 'chrome.exe', 'explorer.exe', 'cmd.exe'];
        final eventTypes = ['start', 'stop'];
        final randomProcess = processNames[DateTime.now().millisecond % processNames.length];
        final randomEvent = eventTypes[DateTime.now().millisecond % eventTypes.length];
        final randomPid = 1000 + (DateTime.now().millisecond % 9000);
        
        _eventsController?.add(ProcessEvent(
          eventType: randomEvent,
          processName: randomProcess,
          processId: randomPid,
        ));
      });
      
      return true;
    } catch (e) {
      print('Error starting monitoring: $e');
      _isMonitoring = false;
      return false;
    }
  }

  /// Stop monitoring process events
  Future<bool> stopMonitoring() async {
    _isMonitoring = false;
    _testTimer?.cancel();
    _testTimer = null;
    return true;
  }

  /// Check if currently monitoring
  bool get isMonitoring => _isMonitoring;

  /// Dispose of resources
  void dispose() {
    _isMonitoring = false;
    _testTimer?.cancel();
    _testTimer = null;
    _eventsController?.close();
    _eventsController = null;
  }
}
