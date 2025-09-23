import 'package:flutter/material.dart';
import 'package:process_monitor/process_monitor.dart';
import 'dart:async';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _processMonitor = ProcessMonitor();
  final List<ProcessEvent> _events = [];
  StreamSubscription<ProcessEvent>? _subscription;
  String _status = 'Stopped';
  String _errorMessage = '';
  int _startEvents = 0;
  int _stopEvents = 0;

  @override
  void initState() {
    super.initState();
    // Don't auto start - let user click button to test
  }

  void _startMonitoring() async {
    setState(() {
      _status = 'Starting...';
      _errorMessage = '';
    });

    try {
      // Start monitoring with FFI
      print('[DEBUG] Calling ProcessMonitor.startMonitoring()');
      bool success = await _processMonitor.startMonitoring();
      print('[DEBUG] ProcessMonitor.startMonitoring() returned: $success');
      
      if (success) {
        setState(() {
          _status = 'Running (FFI)';
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
      } else {
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
      _processMonitor.stopMonitoring().then((success) {
        print('[DEBUG] ProcessMonitor.stopMonitoring() returned: $success');
        if (mounted) {
          setState(() {
            _status = success ? 'Stopped' : 'Error stopping';
            _errorMessage = success ? '' : 'Failed to stop monitoring';
          });
        }
      }).catchError((e) {
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
      title: 'Process Monitor FFI Test',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Process Monitor FFI Test'),
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
                      Text(
                        'Status: $_status',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      if (_errorMessage.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Error: $_errorMessage',
                          style: const TextStyle(color: Colors.red),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          ElevatedButton(
                            onPressed: _processMonitor.isMonitoring ? null : _startMonitoring,
                            child: const Text('Start Monitoring'),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: !_processMonitor.isMonitoring ? null : _stopMonitoring,
                            child: const Text('Stop Monitoring'),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: _clearEvents,
                            child: const Text('Clear'),
                          ),
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
              // Events list
              Expanded(
                child: Card(
                  child: Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text(
                          'Recent Process Events',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ),
                      Expanded(
                        child: _events.isEmpty
                            ? const Center(child: Text('No events yet'))
                            : ListView.builder(
                                itemCount: _events.length,
                                itemBuilder: (context, index) {
                                  final event = _events[index];
                                  return ListTile(
                                    leading: Icon(
                                      event.eventType == 'start' ? Icons.play_arrow : Icons.stop,
                                      color: event.eventType == 'start' ? Colors.green : Colors.red,
                                    ),
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