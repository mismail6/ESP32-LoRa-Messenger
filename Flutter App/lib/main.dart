import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:async';
import 'dart:convert';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Scanner',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const BleScannerPage(),
    );
  }
}

class BleScannerPage extends StatefulWidget {
  const BleScannerPage({super.key});

  @override
  State<BleScannerPage> createState() => _BleScannerPageState();
}

class _BleScannerPageState extends State<BleScannerPage> {
  final List<BluetoothDevice> _devicesList = [];
  bool _isScanning = false;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<bool>? _isScanningSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  BluetoothDevice? _connectedDevice;
  
  // Updated UUIDs to match ESP32 code
  final String serviceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  final String rxCharacteristicUuid = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; // RX characteristic
  final String txCharacteristicUuid = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"; // TX characteristic
  
  // New variables for message handling
  List<String> _receivedMessages = [];
  Stream<List<int>>? _characteristicStream;
  StreamSubscription? _characteristicValueSubscription;
  bool _isListeningToCharacteristic = false;

  // Message input controller
  final TextEditingController _messageController = TextEditingController();

  @override
  void initState() {
    super.initState();
    
    // Listen to scanning state changes
    _isScanningSubscription = FlutterBluePlus.isScanning.listen((isScanning) {
      setState(() {
        _isScanning = isScanning;
      });
    });
    
    // Listen for scan results
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult result in results) {
        if (result.device.platformName.isNotEmpty && !_devicesList.contains(result.device)) {
          setState(() {
            _devicesList.add(result.device);
          });
        }
      }
    });
    
    // Start scanning when app opens
    startScan();
  }

  @override
  void dispose() {
    _scanResultsSubscription?.cancel();
    _isScanningSubscription?.cancel();
    _connectionSubscription?.cancel();
    _characteristicValueSubscription?.cancel();
    _messageController.dispose();
    stopScan();
    super.dispose();
  }

  // Start scanning for BLE devices
  void startScan() async {
    if (!_isScanning) {
      setState(() {
        _devicesList.clear();
      });
      
      try {
        await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 15),
        );
      } catch (e) {
        debugPrint('Error starting scan: $e');
        stopScan();
      }
    }
  }

  // Stop scanning for BLE devices
  void stopScan() {
    if (_isScanning) {
      FlutterBluePlus.stopScan();
    }
  }

  // Method to send message to the connected device
  Future<void> sendMessageToDevice(String message) async {
    try {
      // First, find the service
      List<BluetoothService> services = await _connectedDevice!.discoverServices();
      
      // Look for the specific service
      BluetoothService? targetService;
      for (BluetoothService service in services) {
        String serviceUuidString = service.uuid.toString().toLowerCase();
        if (serviceUuidString == serviceUuid.toLowerCase()) {
          targetService = service;
          break;
        }
      }
      
      if (targetService != null) {
        // Find the RX characteristic for sending messages
        BluetoothCharacteristic? targetCharacteristic;
        for (BluetoothCharacteristic c in targetService.characteristics) {
          String charUuidString = c.uuid.toString().toLowerCase();
          if (charUuidString == rxCharacteristicUuid.toLowerCase()) {
            targetCharacteristic = c;
            break;
          }
        }
        
        if (targetCharacteristic != null) {
          // Check if the characteristic is writable
          if (targetCharacteristic.properties.write) {
            // Convert message to UTF-8 encoded bytes
            List<int> bytes = utf8.encode(message);
            
            // Write the message
            await targetCharacteristic.write(bytes);
            
            debugPrint('Sent message: $message');
            
            // Optional: Show a snackbar to confirm message was sent
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Message sent: $message')),
              );
            }
          } else {
            debugPrint('Characteristic is not writable');
          }
        } else {
          debugPrint('Target RX characteristic not found');
        }
      } else {
        debugPrint('Target service not found');
      }
    } catch (e) {
      debugPrint('Error sending message: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send message: $e')),
        );
      }
    }
  }

  // Connect to a BLE device
  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect();
      
      if (!mounted) return;
      
      setState(() {
        _connectedDevice = device;
      });
      
      // Monitor connection state
      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          if (mounted) {
            setState(() {
              _connectedDevice = null;
              _characteristicStream = null;
              _isListeningToCharacteristic = false;
              // Cancel the characteristic subscription when disconnected
              _characteristicValueSubscription?.cancel();
              _characteristicValueSubscription = null;
            });
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Disconnected from ${device.platformName}')),
            );
          }
          
          _connectionSubscription?.cancel();
          _connectionSubscription = null;
        }
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected to ${device.platformName}')),
      );
      
      // After connecting, discover services with a small delay to ensure connection is stable
      await Future.delayed(const Duration(milliseconds: 500));
      await discoverServicesAndListen(device);
      
    } catch (e) {
      debugPrint('Error connecting to device: $e');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect to ${device.platformName}: $e')),
        );
      }
    }
  }

  // Discover services and set up notifications for incoming messages
  Future<void> discoverServicesAndListen(BluetoothDevice device) async {
    try {
      // Discover services
      List<BluetoothService> services = await device.discoverServices();
      debugPrint('Discovered ${services.length} services');
      
      // We'll try both exact matching and contains matching for service UUID
      BluetoothService? targetService;
      
      // First try exact match (with lowercase)
      for (BluetoothService service in services) {
        String serviceUuidString = service.uuid.toString().toLowerCase();
        if (serviceUuidString == serviceUuid.toLowerCase()) {
          targetService = service;
          debugPrint('Found exact matching service: $serviceUuidString');
          break;
        }
      }
      
      // If still no match, try to find a service with notify characteristics
      if (targetService == null) {
        for (BluetoothService service in services) {
          for (BluetoothCharacteristic c in service.characteristics) {
            if (c.properties.notify) {
              targetService = service;
              debugPrint('Found service with notify characteristic: ${service.uuid.toString()}');
              break;
            }
          }
          if (targetService != null) break;
        }
      }
      
      // If we found a service, look for the TX characteristic for receiving messages
      if (targetService != null) {
        BluetoothCharacteristic? targetCharacteristic;
        
        // First try exact match
        for (BluetoothCharacteristic c in targetService.characteristics) {
          String charUuidString = c.uuid.toString().toLowerCase();
          if (charUuidString == txCharacteristicUuid.toLowerCase()) {
            targetCharacteristic = c;
            debugPrint('Found exact matching characteristic: $charUuidString');
            break;
          }
        }
        
        // If exact match failed, try to find a characteristic with notify property
        if (targetCharacteristic == null) {
          for (BluetoothCharacteristic c in targetService.characteristics) {
            if (c.properties.notify) {
              targetCharacteristic = c;
              debugPrint('Found characteristic with notify property: ${c.uuid.toString()}');
              break;
            }
          }
        }
        
        // If we found a characteristic, set up notifications
        if (targetCharacteristic != null) {
          try {
            debugPrint('Setting up notifications for characteristic: ${targetCharacteristic.uuid}');
            
            // First, enable notifications
            await targetCharacteristic.setNotifyValue(true);
            debugPrint('Notifications enabled');
            
            // Then listen for changes
            _characteristicStream = targetCharacteristic.onValueReceived;
            _characteristicValueSubscription = _characteristicStream!.listen(
              (value) {
                if (value.isNotEmpty) {
                  // Convert the byte array to a string
                  String message = utf8.decode(value);
                  debugPrint('Received message: $message');
                  
                  if (mounted) {
                    setState(() {
                      _receivedMessages.add('${DateTime.now().toString().substring(11, 19)}: $message');
                      _isListeningToCharacteristic = true;
                    });
                  }
                }
              },
              onError: (error) {
                debugPrint('Error receiving notification: $error');
              }
            );
            
            debugPrint('Successfully subscribed to notifications');
            
          } catch (e) {
            debugPrint('Error setting up notifications: $e');
            // Show error in UI
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Error setting up notifications: $e')),
              );
            }
          }
        } else {
          debugPrint('Target TX characteristic not found');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Target characteristic not found')),
            );
          }
        }
      } else {
        debugPrint('Target service not found');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Target service not found')),
          );
        }
      }
    } catch (e) {
      debugPrint('Error discovering services: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error discovering services: $e')),
        );
      }
    }
  }

  // Disconnect from a BLE device
  Future<void> disconnectFromDevice() async {
    if (_connectedDevice != null) {
      try {
        // Cancel the characteristic subscription first
        _characteristicValueSubscription?.cancel();
        _characteristicValueSubscription = null;
        
        await _connectedDevice!.disconnect();
        
        if (mounted) {
          setState(() {
            _connectedDevice = null;
            _characteristicStream = null;
            _isListeningToCharacteristic = false;
          });
        }
        
        _connectionSubscription?.cancel();
        _connectionSubscription = null;
      } catch (e) {
        debugPrint('Error disconnecting from device: $e');
      }
    }
  }

  // Clear the message history
  void clearMessages() {
    setState(() {
      _receivedMessages.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE Scanner'),
        actions: [
          _connectedDevice != null
              ? IconButton(
                  icon: const Icon(Icons.bluetooth_connected),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text('Connected to ${_connectedDevice!.platformName}'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Device ID: ${_connectedDevice!.remoteId.str}'),
                            const SizedBox(height: 8),
                            Text('Listening to messages: ${_isListeningToCharacteristic ? "Yes" : "No"}'),
                          ],
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              disconnectFromDevice();
                            },
                            child: const Text('Disconnect'),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              // Re-discover services if not listening
                              if (!_isListeningToCharacteristic && _connectedDevice != null) {
                                discoverServicesAndListen(_connectedDevice!);
                              }
                            },
                            child: const Text('Retry'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    );
                  },
                )
              : Container(),
        ],
      ),
      body: Column(
        children: [
          // Device list section
          Expanded(
            flex: 1,
            child: RefreshIndicator(
              onRefresh: () async {
                if (!_isScanning) {
                  startScan();
                }
              },
              child: ListView.builder(
                itemCount: _devicesList.length,
                itemBuilder: (context, index) {
                  BluetoothDevice device = _devicesList[index];
                  bool isConnected = _connectedDevice == device;
                  
                  return ListTile(
                    title: Text(device.platformName.isEmpty 
                      ? "Unknown Device" 
                      : device.platformName),
                    subtitle: Text(device.remoteId.str),
                    trailing: isConnected
                        ? const Icon(Icons.bluetooth_connected, color: Colors.green)
                        : const Icon(Icons.bluetooth, color: Colors.blue),
                    onTap: () {
                      if (isConnected) {
                        disconnectFromDevice();
                      } else {
                        connectToDevice(device);
                      }
                    },
                  );
                },
              ),
            ),
          ),
          
          // Messages section - only visible when connected
          if (_connectedDevice != null) const Divider(height: 1),
          if (_connectedDevice != null) 
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Messages from ${_connectedDevice!.platformName}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          _isListeningToCharacteristic 
                              ? 'Listening for notifications...' 
                              : 'Not listening yet. Check connection status.',
                          style: TextStyle(
                            fontSize: 12,
                            color: _isListeningToCharacteristic ? Colors.green : Colors.red,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () {
                      if (_connectedDevice != null) {
                        discoverServicesAndListen(_connectedDevice!);
                      }
                    },
                    tooltip: 'Retry connection',
                  ),
                  IconButton(
                    icon: const Icon(Icons.clear_all),
                    onPressed: clearMessages,
                    tooltip: 'Clear messages',
                  ),
                ],
              ),
            ),
          
          // Message sending input - only when connected
          if (_connectedDevice != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(
                        hintText: 'Enter message to send',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: () {
                      if (_messageController.text.isNotEmpty) {
                        sendMessageToDevice(_messageController.text);
                        _messageController.clear(); // Clear the input after sending
                      }
                    },
                  ),
                ],
              ),
            ),
          
          // Received messages list
          if (_connectedDevice != null)
            Expanded(
              flex: 2,
              child: _receivedMessages.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('Waiting for messages...'),
                          const SizedBox(height: 16),
                          _isListeningToCharacteristic
                              ? const CircularProgressIndicator()
                              : ElevatedButton(
                                  onPressed: () {
                                    if (_connectedDevice != null) {
                                      discoverServicesAndListen(_connectedDevice!);
                                    }
                                  },
                                  child: const Text('Retry Connection'),
                                ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _receivedMessages.length,
                      reverse: true,  // Shows newest messages at the bottom
                      itemBuilder: (context, index) {
                        // Display messages in reverse order (newest at the bottom)
                        final message = _receivedMessages[_receivedMessages.length - 1 - index];
                        return ListTile(
                          dense: true,
                          title: Text(message),
                          leading: const Icon(Icons.message),
                        );
                      },
                    ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isScanning ? stopScan : startScan,
        child: Icon(_isScanning ? Icons.stop : Icons.search),
      ),
    );
  }
}