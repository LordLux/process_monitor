// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:process_monitor/process_monitor.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  WindowOptions windowOptions = WindowOptions(
    size: Size(1100, 850),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    title: "Process Monitor FFI Test",
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false, //
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
  final _processMonitor = ProcessMonitor();
  final List<ProcessEvent> _events = [];
  final List<String> _processCallbackLog = [];
  StreamSubscription<ProcessEvent>? _subscription;
  String _status = 'Stopped';
  String _errorMessage = '';
  int _startEvents = 0;
  int _stopEvents = 0;
  bool _useProcessSpecificMonitoring = false;
  final List<String> _monitoredProcesses = ['mpc-hc64.exe'];

  @override
  void initState() => super.initState();

  void _startMonitoring() async {
    setState(() {
      _status = 'Starting...';
      _errorMessage = '';
    });

    try {
      bool success;
      if (_useProcessSpecificMonitoring) {
        // Start process-specific monitoring
        print('[DEBUG] Starting process-specific monitoring');
        success = await _startProcessSpecificMonitoring();
      } else {
        // Start general monitoring with FFI
        print('[DEBUG] Calling ProcessMonitor.startMonitoring()');
        success = await _processMonitor.startMonitoring();
        print('[DEBUG] ProcessMonitor.startMonitoring() returned: $success');

        if (success) {
          setState(() {
            _status = 'Running (General)';
          });

          print('[DEBUG] Setting up event subscription');
          _subscription = _processMonitor.processEvents.listen(
            (ProcessEvent event) {
              setState(() {
                _events.insert(0, event); // Add to beginning for newest first

                // Keep only last 50 events to prevent memory issues
                if (_events.length > 50) {
                  _events.removeRange(50, _events.length);
                }

                // Update counters
                if (event.eventType == 'start') {
                  _startEvents++;
                } else if (event.eventType == 'stop') {
                  _stopEvents++;
                }
              });
            },
            onError: (error) {
              print('[ERROR] Event stream error: $error');
              setState(() {
                _status = 'Error';
                _errorMessage = error.toString();
              });
            },
          );
          print('[DEBUG] Event subscription set up successfully');
        }
      }

      if (!success) {
        setState(() {
          _status = 'Failed to start';
          _errorMessage = 'Failed to start process monitoring';
        });
      }
    } catch (e) {
      print('[ERROR] Exception in _startMonitoring: $e');
      setState(() {
        _status = 'Error';
        _errorMessage = e.toString();
      });
    }
  }

  Future<bool> _startProcessSpecificMonitoring() async {
    final processConfigs = _monitoredProcesses.map((procName) {
      return ProcessConfig(
        processName: procName,
        onStart: (event) {
          setState(() {
            _processCallbackLog.insert(0, '[${DateTime.now().toString().substring(11, 19)}] $procName STARTED (PID: ${event.processId})');
            if (_processCallbackLog.length > 20) _processCallbackLog.removeLast();
          });
          print('[CALLBACK] $procName started: PID ${event.processId}');
        },
        onStop: (event) {
          setState(() {
            _processCallbackLog.insert(0, '[${DateTime.now().toString().substring(11, 19)}] $procName STOPPED (PID: ${event.processId})');
            if (_processCallbackLog.length > 20) _processCallbackLog.removeLast();
          });
          print('[CALLBACK] $procName stopped: PID ${event.processId}');
        },
        allowMultipleStartCallbacks: true,
        allowMultipleStopCallbacks: true,
      );
    }).toList();

    final success = await _processMonitor.startMonitoringProcesses(processConfigs);
    if (success) {
      setState(() {
        _status = 'Running (Process-Specific)';
        _processCallbackLog.insert(0, '[${DateTime.now().toString().substring(11, 19)}] Started monitoring: ${_monitoredProcesses.join(', ')}');
      });

      // Still listen to general events for display (but callbacks are handled separately)
      _subscription = _processMonitor.processEvents.listen(
        (ProcessEvent event) {
          setState(() {
            _events.insert(0, event);
            if (_events.length > 50) {
              _events.removeRange(50, _events.length);
            }
            if (event.eventType == 'start') {
              _startEvents++;
            } else if (event.eventType == 'stop') {
              _stopEvents++;
            }
          });
        },
        onError: (error) {
          print('[ERROR] Event stream error: $error');
          setState(() {
            _status = 'Error';
            _errorMessage = error.toString();
          });
        },
      );
    }
    return success;
  }

  void _stopMonitoring() {
    print('[DEBUG] _stopMonitoring() button pressed');
    setState(() {
      _status = 'Stopping...';
    });

    try {
      // Cancel the subscription first (immediate)
      print('[DEBUG] Cancelling subscription');
      _subscription?.cancel();
      _subscription = null;

      // Stop monitoring (now just sets a flag, very fast)
      print('[DEBUG] Calling ProcessMonitor.stopMonitoring()');
      _processMonitor
          .stopMonitoring()
          .then((success) {
            print('[DEBUG] ProcessMonitor.stopMonitoring() returned: $success');
            if (mounted) {
              setState(() {
                _status = success ? 'Stopped' : 'Error stopping';
                _errorMessage = success ? '' : 'Failed to stop monitoring';
              });
            }
          })
          .catchError((e) {
            print('[ERROR] Exception in stopMonitoring().then: $e');
            if (mounted) {
              setState(() {
                _status = 'Error stopping';
                _errorMessage = e.toString();
              });
            }
          });
    } catch (e) {
      print('[ERROR] Exception in _stopMonitoring: $e');
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
      _startEvents = 0;
      _stopEvents = 0;
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _processMonitor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Process Monitor FFI Test',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Process Monitor FFI Test'),
          actions: [
            const Text('Process Monitor FFI Test'),
            Spacer(),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () async {
                print('[DEBUG] Close button pressed');
                _subscription?.cancel();
                await _processMonitor.dispose();
                windowManager.close();
              },
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // Status and controls
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Status: $_status', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      if (_errorMessage.isNotEmpty) ...[const SizedBox(height: 8), Text('Error: $_errorMessage', style: const TextStyle(color: Colors.red))],
                      const SizedBox(height: 16),
                      // Monitoring type toggle
                      Row(
                        children: [
                          Checkbox(
                            value: _useProcessSpecificMonitoring,
                            onChanged: _processMonitor.isMonitoring
                                ? null
                                : (value) {
                                    setState(() {
                                      _useProcessSpecificMonitoring = value ?? false;
                                    });
                                  },
                          ),
                          Expanded(
                            child: Text(_useProcessSpecificMonitoring ? 'Process-Specific Monitoring (${_monitoredProcesses.join(', ')})' : 'General Monitoring (all processes)', style: TextStyle(color: _processMonitor.isMonitoring ? Colors.grey : Colors.black)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          ElevatedButton(onPressed: _processMonitor.isMonitoring ? null : _startMonitoring, child: Text(_useProcessSpecificMonitoring ? 'Start Process-Specific' : 'Start General')),
                          const SizedBox(width: 8),
                          ElevatedButton(onPressed: !_processMonitor.isMonitoring ? null : _stopMonitoring, child: const Text('Stop Monitoring')),
                          const SizedBox(width: 8),
                          ElevatedButton(onPressed: _clearEvents, child: const Text('Clear')),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Statistics
              Row(
                children: [
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            const Text('Started'),
                            Text(
                              '$_startEvents',
                              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.green),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            const Text('Stopped'),
                            Text(
                              '$_stopEvents',
                              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.red),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Content area - shows either callback log or events list
              Expanded(
                child: _useProcessSpecificMonitoring && _processCallbackLog.isNotEmpty
                    ? Column(
                        children: [
                          // Callback log
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
                          // Events list (smaller)
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
                      )
                    : Card(
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Text(_useProcessSpecificMonitoring ? 'Monitored Process Events (${_monitoredProcesses.join(', ')})' : 'All Process Events', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                            ),
                            Expanded(
                              child: _events.isEmpty
                                  ? Center(child: Text(_useProcessSpecificMonitoring ? 'No monitored process events yet\nTry opening ${_monitoredProcesses.join(', ')}' : 'No events yet'))
                                  : ListView.builder(
                                      itemCount: _events.length,
                                      itemBuilder: (context, index) {
                                        final event = _events[index];
                                        final isMonitored = _useProcessSpecificMonitoring ? _monitoredProcesses.any((name) => name.toLowerCase() == event.processName.toLowerCase()) : true;

                                        if (_useProcessSpecificMonitoring && !isMonitored) {
                                          return const SizedBox.shrink(); // Hide non-monitored processes in specific mode
                                        }

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
          ),
        ),
      ),
    );
  }
}
