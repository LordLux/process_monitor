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
  int _startEvents = 0;
  int _stopEvents = 0;

  @override
  void initState() {
    super.initState();
    _startMonitoring();
  }

  void _startMonitoring() {
    setState(() {
      _status = 'Starting...';
    });

    _subscription = _processMonitor.processEvents.listen(
      (ProcessEvent event) {
        setState(() {
          _events.insert(0, event); // Add to beginning for newest first
          
          // Keep only last 100 events to prevent memory issues
          if (_events.length > 100) {
            _events.removeRange(100, _events.length);
          }
          
          // Update counters
          if (event.eventType == 'start') {
            _startEvents++;
          } else if (event.eventType == 'stop') {
            _stopEvents++;
          }
          
          _status = 'Monitoring';
        });
      },
      onError: (error) {
        setState(() {
          _status = 'Error: $error';
        });
        print('Process monitor error: $error');
      },
    );
  }

  void _stopMonitoring() {
    _subscription?.cancel();
    _subscription = null;
    setState(() {
      _status = 'Stopped';
    });
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

  Widget _buildEventTile(ProcessEvent event) {
    IconData icon;
    Color color;
    
    switch (event.eventType) {
      case 'start':
        icon = Icons.play_arrow;
        color = Colors.green;
        break;
      case 'stop':
        icon = Icons.stop;
        color = Colors.red;
        break;
      default:
        icon = Icons.error;
        color = Colors.orange;
    }

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(event.processName),
      subtitle: Text('PID: ${event.processId}'),
      trailing: Text(
        '${event.timestamp.hour.toString().padLeft(2, '0')}:'
        '${event.timestamp.minute.toString().padLeft(2, '0')}:'
        '${event.timestamp.second.toString().padLeft(2, '0')}',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Process Monitor',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Process Monitor'),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          actions: [
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: _clearEvents,
              tooltip: 'Clear events',
            ),
          ],
        ),
        body: Column(
          children: [
            // Status bar
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16.0),
              color: _status == 'Monitoring' 
                  ? Colors.green.shade100 
                  : _status.startsWith('Error')
                      ? Colors.red.shade100
                      : Colors.grey.shade100,
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Status: $_status',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Events: ${_events.length}',
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Chip(
                        avatar: const Icon(Icons.play_arrow, size: 16, color: Colors.green),
                        label: Text('Started: $_startEvents'),
                        backgroundColor: Colors.green.shade50,
                      ),
                      Chip(
                        avatar: const Icon(Icons.stop, size: 16, color: Colors.red),
                        label: Text('Stopped: $_stopEvents'),
                        backgroundColor: Colors.red.shade50,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Events list
            Expanded(
              child: _events.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.hourglass_empty, size: 64, color: Colors.grey),
                          SizedBox(height: 16),
                          Text(
                            'No process events yet...',
                            style: TextStyle(fontSize: 18, color: Colors.grey),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Try starting or stopping applications to see events',
                            style: TextStyle(fontSize: 14, color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _events.length,
                      itemBuilder: (context, index) {
                        return _buildEventTile(_events[index]);
                      },
                    ),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _subscription == null ? _startMonitoring : _stopMonitoring,
          tooltip: _subscription == null ? 'Start Monitoring' : 'Stop Monitoring',
          child: Icon(_subscription == null ? Icons.play_arrow : Icons.stop),
        ),
      ),
    );
  }
}