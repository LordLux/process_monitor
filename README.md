# process_monitor

A Flutter plugin for monitoring process creation and termination events on Windows using FFI.

## Features

- Monitor all process start/stop events on Windows
- Monitor specific processes with per-process callbacks
- Control whether callbacks are triggered for each instance or only once
- Deduplication of duplicate events from the native layer
- Works in background isolate for non-blocking UI

## Getting Started

Add to your `pubspec.yaml`:

```yaml
dependencies:
  process_monitor:
    git:
      url: https://github.com/yourusername/process_monitor.git
```

## Usage

### Import the package

```dart
import 'package:process_monitor/process_monitor.dart';
```

### General Monitoring (all processes)

```dart
final monitor = ProcessMonitor();
await monitor.startMonitoring();
monitor.processEvents.listen((event) {
  print('Process ${event.processName} (${event.processId}) ${event.eventType} at ${event.timestamp}');
});
```

### Process-Specific Monitoring

```dart
final configs = [
  ProcessConfig(
    processName: 'notepad.exe',
    onStart: (event) => print('Notepad started: ${event.processId}'),
    onStop: (event) => print('Notepad stopped: ${event.processId}'),
    allowMultipleStartCallbacks: true, // or false
    allowMultipleStopCallbacks: true,  // or false
  ),
];
await monitor.startMonitoringProcesses(configs);
```

### Stopping Monitoring

```dart
await monitor.stopMonitoring();
```

## API Reference

### ProcessMonitor

- `Future<bool> startMonitoring()` — Start monitoring all processes
- `Future<bool> startMonitoringProcesses(List<ProcessConfig>)` — Monitor specific processes with callbacks
- `Stream<ProcessEvent> get processEvents` — Stream of all process events
- `Future<bool> stopMonitoring()` — Stop monitoring
- `Future<void> dispose()` — Dispose and clean up resources

### ProcessConfig

- `String processName` — Name of the process to monitor (e.g. 'notepad.exe')
- `void Function(ProcessEvent event)? onStart` — Callback for process start
- `void Function(ProcessEvent event)? onStop` — Callback for process stop
- `bool allowMultipleStartCallbacks` — Call onStart for each instance?
- `bool allowMultipleStopCallbacks` — Call onStop for each instance?

### ProcessEvent

- `String processName` — Name of the process
- `int processId` — PID
- `String eventType` — 'start' or 'stop'
- `DateTime timestamp` — Event time

## Example

See [`example/lib/main.dart`](example/lib/main.dart) for a full Flutter app example.

## Platform Support

- Windows (FFI, WMI)

## License

MIT
