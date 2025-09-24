// ignore_for_file: avoid_print, curly_braces_in_flow_control_structures
library;

import 'package:flutter/material.dart';
import 'package:process_monitor/process_monitor.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';

/// Entry point for the example app.
/// Sets up the window and launches the main widget.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  WindowOptions windowOptions = WindowOptions(
    // Hide default window buttons
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _useProcessSpecific = false;

  @override
  void dispose() {
    processMonitor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Process Monitor',
      theme: ThemeData(primarySwatch: Colors.deepPurple),
      home: Scaffold(
        appBar: AppBar(
          title: Padding(padding: const EdgeInsets.only(left: 8.0), child: Text('Process Monitor')),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8.0, left: 16.0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      await ProcessMonitor().dispose();
                      windowManager.close();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        body: Padding(padding: const EdgeInsets.all(16.0), child: _useProcessSpecific ? ProcessSpecificMonitorWidget() : GlobalMonitorWidget()),
      ),
    );
  }
}

final ProcessMonitor processMonitor = ProcessMonitor();

/// Widget for global monitoring.
class GlobalMonitorWidget extends StatefulWidget {
  const GlobalMonitorWidget({super.key});

  @override
  State<GlobalMonitorWidget> createState() => _GlobalMonitorWidgetState();
}

class _GlobalMonitorWidgetState extends State<GlobalMonitorWidget> {
  StreamSubscription<ProcessEvent>? _subscription;
  final List<ProcessEvent> _events = [];
  String _status = 'Stopped';
  String _errorMessage = '';

  void _startMonitoring() async {
    setState(() {
      _status = 'Starting...';
      _errorMessage = '';
    });
    try {
      final success = await processMonitor.startMonitoring();
      if (success) {
        setState(() => _status = 'Running (General)');
        _subscription = processMonitor.events.listen(
          (event) {
            // Process the event
            setState(() {
              _events.insert(0, event);
              if (_events.length > 50) _events.removeRange(50, _events.length);
            });
          },
          onError: (error) {
            setState(() {
              _status = 'Error';
              _errorMessage = error.toString();
            });
          },
        );
      } else {
        setState(() {
          _status = 'Failed to start';
          _errorMessage = 'Failed to start process monitoring';
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error';
        _errorMessage = e.toString();
      });
    }
  }

  void _stopMonitoring() {
    setState(() => _status = 'Stopping...');
    try {
      _subscription?.cancel();
      _subscription = null;
      processMonitor
          .stopMonitoring()
          .then((success) {
            if (!mounted) return;
            setState(() {
              _status = success ? 'Stopped' : 'Error stopping';
              _errorMessage = success ? '' : 'Failed to stop monitoring';
            });
          })
          .catchError((e) {
            if (!mounted) return;
            setState(() {
              _status = 'Error stopping';
              _errorMessage = e.toString();
            });
          });
    } catch (e) {
      setState(() {
        _status = 'Error stopping';
        _errorMessage = e.toString();
      });
    }
  }

  void _clearEvents() => setState(() => _events.clear());

  @override
  void dispose() {
    _subscription?.cancel();
    processMonitor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Status: $_status', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                if (_errorMessage.isNotEmpty) ...[const SizedBox(height: 8), Text('Error: $_errorMessage', style: const TextStyle(color: Colors.red))],
                const SizedBox(height: 16),
                Row(
                  children: [
                    ElevatedButton(onPressed: processMonitor.isMonitoring ? null : _startMonitoring, child: const Text('Start Global')),
                    const SizedBox(width: 8),
                    ElevatedButton(onPressed: !processMonitor.isMonitoring ? null : _stopMonitoring, child: const Text('Stop Monitoring')),
                    const SizedBox(width: 8),
                    ElevatedButton(onPressed: _clearEvents, child: const Text('Clear')),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Card(
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text('All Process Events', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                Expanded(
                  child: _events.isEmpty
                      ? const Center(child: Text('No events yet'))
                      : ListView.builder(
                          itemCount: _events.length,
                          itemBuilder: (context, index) {
                            final event = _events[index];
                            return ListTile(
                              leading: Icon(event.eventType == 'start' ? Icons.play_arrow : Icons.stop, color: event.eventType == 'start' ? Colors.green : Colors.red),
                              title: Text(event.processName),
                              subtitle: Text('PID: ${event.processId} • ${event.timestamp.toString().substring(11, 19)}'),
                              trailing: Text(event.eventType.toUpperCase()),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Widget for process-specific monitoring (e.g., mpc-hc64.exe only).
class ProcessSpecificMonitorWidget extends StatefulWidget {
  const ProcessSpecificMonitorWidget({super.key});

  @override
  State<ProcessSpecificMonitorWidget> createState() => _ProcessSpecificMonitorWidgetState();
}

class _ProcessSpecificMonitorWidgetState extends State<ProcessSpecificMonitorWidget> {
  final List<String> _monitoredProcesses = ['mpc-hc64.exe'];
  StreamSubscription<ProcessEvent>? _subscription;
  final List<ProcessEvent> _events = [];
  final List<String> _processCallbackLog = [];
  String _status = 'Stopped';
  String _errorMessage = '';

  void _startMonitoring() async {
    setState(() {
      _status = 'Starting...';
      _errorMessage = '';
    });
    try {
      final processConfigs = _monitoredProcesses.map((procName) {
        return ProcessConfig(
          processName: procName,
          onStart: (event) {
            setState(() {
              _processCallbackLog.insert(0, '[${DateTime.now().toString().substring(11, 19)}] $procName STARTED (PID: ${event.processId})');
              if (_processCallbackLog.length > 20) _processCallbackLog.removeLast();
            });
          },
          onStop: (event) {
            setState(() {
              _processCallbackLog.insert(0, '[${DateTime.now().toString().substring(11, 19)}] $procName STOPPED (PID: ${event.processId})');
              if (_processCallbackLog.length > 20) _processCallbackLog.removeLast();
            });
          },
          allowMultipleStartCallbacks: true,
          allowMultipleStopCallbacks: true,
        );
      }).toList();
      final success = await processMonitor.startMonitoringProcesses(processConfigs);
      if (success) {
        setState(() {
          _status = 'Running (Process-Specific)';
          _processCallbackLog.insert(0, '[${DateTime.now().toString().substring(11, 19)}] Started monitoring: ${_monitoredProcesses.join(', ')}');
        });
        _subscription = processMonitor.events.listen(
          (event) {
            setState(() {
              _events.insert(0, event);
              if (_events.length > 50) _events.removeRange(50, _events.length);
            });
          },
          onError: (error) {
            setState(() {
              _status = 'Error';
              _errorMessage = error.toString();
            });
          },
        );
      } else {
        setState(() {
          _status = 'Failed to start';
          _errorMessage = 'Failed to start process monitoring';
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error';
        _errorMessage = e.toString();
      });
    }
  }

  void _stopMonitoring() {
    setState(() => _status = 'Stopping...');
    try {
      _subscription?.cancel();
      _subscription = null;
      processMonitor
          .stopMonitoring()
          .then((success) {
            if (mounted) {
              setState(() {
                _status = success ? 'Stopped' : 'Error stopping';
                _errorMessage = success ? '' : 'Failed to stop monitoring';
              });
            }
          })
          .catchError((e) {
            if (mounted) {
              setState(() {
                _status = 'Error stopping';
                _errorMessage = e.toString();
              });
            }
          });
    } catch (e) {
      setState(() {
        _status = 'Error stopping';
        _errorMessage = e.toString();
      });
    }
  }

  void _clearEvents() {
    setState(() {
      _events.clear();
      _processCallbackLog.clear();
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    processMonitor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Status: $_status', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                if (_errorMessage.isNotEmpty) ...[const SizedBox(height: 8), Text('Error: $_errorMessage', style: const TextStyle(color: Colors.red))],
                const SizedBox(height: 16),
                Row(
                  children: [
                    ElevatedButton(onPressed: processMonitor.isMonitoring ? null : _startMonitoring, child: const Text('Start Process-Specific')),
                    const SizedBox(width: 8),
                    ElevatedButton(onPressed: !processMonitor.isMonitoring ? null : _stopMonitoring, child: const Text('Stop Monitoring')),
                    const SizedBox(width: 8),
                    ElevatedButton(onPressed: _clearEvents, child: const Text('Clear')),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: Card(
                  child: Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text('Process-Specific Callbacks', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _processCallbackLog.length,
                          itemBuilder: (context, index) {
                            final log = _processCallbackLog[index];
                            final isStart = log.contains('STARTED');
                            return ListTile(
                              leading: Icon(isStart ? Icons.play_arrow : Icons.stop, color: isStart ? Colors.green : Colors.red, size: 20),
                              title: Text(log, style: const TextStyle(fontSize: 14)),
                              dense: true,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Card(
                  child: Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text('All Events (for comparison)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                      Expanded(
                        child: _events.isEmpty
                            ? const Center(child: Text('No events yet'))
                            : ListView.builder(
                                itemCount: _events.length,
                                itemBuilder: (context, index) {
                                  final event = _events[index];
                                  final isMonitored = _monitoredProcesses.any((name) => name.toLowerCase() == event.processName.toLowerCase());
                                  return ListTile(
                                    leading: Icon(event.eventType == 'start' ? Icons.play_arrow : Icons.stop, color: isMonitored ? (event.eventType == 'start' ? Colors.green : Colors.red) : Colors.grey, size: 16),
                                    title: Text(
                                      event.processName,
                                      style: TextStyle(fontSize: 12, fontWeight: isMonitored ? FontWeight.bold : FontWeight.normal, color: isMonitored ? Colors.black : Colors.grey),
                                    ),
                                    subtitle: Text('PID: ${event.processId} • ${event.timestamp.toString().substring(11, 19)}', style: const TextStyle(fontSize: 11)),
                                    trailing: Text(event.eventType.toUpperCase(), style: const TextStyle(fontSize: 11)),
                                    dense: true,
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
