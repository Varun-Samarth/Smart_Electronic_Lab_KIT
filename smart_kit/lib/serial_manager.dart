import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'models.dart';

class SerialManager {
  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription? _subscription;
  String _buffer = '';

  final _dataController = StreamController<SensorData>.broadcast();
  final _statusController = StreamController<String>.broadcast();

  Stream<SensorData> get dataStream => _dataController.stream;
  Stream<String> get statusStream => _statusController.stream;

  bool get isConnected => _port != null && _port!.isOpen;

  List<String> getAvailablePorts() {
    return SerialPort.availablePorts;
  }

  Future<String?> autoDetectArduino(int baudRate) async {
    final ports = getAvailablePorts();
    _statusController.add('Scanning ${ports.length} ports...');
    print('DEBUG: Scanning ${ports.length} available ports');

    for (String portName in ports) {
      _statusController.add('Checking $portName...');
      print('DEBUG: Checking port: $portName');

      bool found = await _checkPortForSignature(portName, baudRate);

      if (found) {
        _statusController.add('Device found on $portName!');
        print('DEBUG: Device found on $portName');
        return portName;
      }

      await Future.delayed(const Duration(milliseconds: 200));
    }

    _statusController.add('Smart kit not detected.');
    print('DEBUG: Smart kit not detected on any port');
    return null;
  }

  Future<bool> _checkPortForSignature(String portName, int baudRate) async {
    SerialPort? testPort;
    SerialPortReader? testReader;
    StreamSubscription? testSubscription;
    Completer<bool> completer = Completer<bool>();

    try {
      testPort = SerialPort(portName);

      if (!testPort.openReadWrite()) {
        print('DEBUG: Failed to open port $portName');
        completer.complete(false);
        return completer.future;
      }

      final config = SerialPortConfig()
        ..baudRate = baudRate
        ..bits = 8
        ..stopBits = 1
        ..parity = SerialPortParity.none;

      testPort.config = config;
      print('DEBUG: Port $portName configured with baudRate: $baudRate');

      String buffer = '';
      testReader = SerialPortReader(testPort);

      Timer timeoutTimer = Timer(const Duration(seconds: 2), () {
        if (!completer.isCompleted) {
          print('DEBUG: Timeout waiting for signature on $portName');
          completer.complete(false);
        }
      });

      testSubscription = testReader.stream.listen(
        (data) {
          buffer += String.fromCharCodes(data);
          print(
              'DEBUG: Received on $portName: ${String.fromCharCodes(data).trim()}');

          List<String> lines = buffer.split('\n');
          buffer = lines.last;

          for (int i = 0; i < lines.length - 1; i++) {
            String line = lines[i].trim();
            print('DEBUG: Processing line: $line');
            if (line == SerialCommand.signature) {
              print('DEBUG: Signature matched on $portName!');
              timeoutTimer.cancel();
              if (!completer.isCompleted) {
                completer.complete(true);
              }
              break;
            }
          }
        },
        onError: (error) {
          print('DEBUG: Error reading from $portName: $error');
          if (!completer.isCompleted) {
            completer.complete(false);
          }
        },
      );

      bool result = await completer.future;

      await testSubscription.cancel();
      testReader.close();
      testPort.close();

      return result;
    } catch (e) {
      print('DEBUG: Exception checking port $portName: $e');
      return false;
    }
  }

  Future<bool> connect(String portName, int baudRate) async {
    try {
      print('DEBUG: Attempting to connect to $portName at $baudRate baud');

      // Clean up any existing connection first
      if (_port != null) {
        print('DEBUG: Cleaning up existing connection');
        disconnect();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      _port = SerialPort(portName);

      if (!_port!.openReadWrite()) {
        print('DEBUG: Failed to open port $portName');
        _statusController.add('Failed to open port');
        return false;
      }

      final config = SerialPortConfig()
        ..baudRate = baudRate
        ..bits = 8
        ..stopBits = 1
        ..parity = SerialPortParity.none;

      _port!.config = config;
      print('DEBUG: Port configured successfully');

      // Clear any existing buffer
      _buffer = '';

      _reader = SerialPortReader(_port!);
      _subscription = _reader!.stream.listen(
        _handleData,
        onError: (error) {
          print('DEBUG: Read error: $error');
          _statusController.add('Read error: $error');
          disconnect();
        },
      );

      _statusController.add('Connected to $portName');
      print('DEBUG: Successfully connected to $portName');
      return true;
    } catch (e) {
      print('DEBUG: Connection error: $e');
      _statusController.add('Connection error: $e');
      return false;
    }
  }

  void _handleData(Uint8List data) {
    String str = String.fromCharCodes(data);
    print('DEBUG: Received from Arduino: ${str.trim()}');

    _buffer += str;

    List<String> lines = _buffer.split('\n');
    _buffer = lines.last;

    for (int i = 0; i < lines.length - 1; i++) {
      String line = lines[i].trim();
      if (line.isEmpty) continue;

      print('DEBUG: Processing received line: $line');

      // Ignore control messages
      if (line == SerialCommand.signature ||
          line.startsWith('ACK_') ||
          line.startsWith('DEBUG:')) {
        print('DEBUG: Ignoring control message: $line');
        continue;
      }

      // Try to parse as JSON
      try {
        final json = line.startsWith('{') ? line : '{"value":$line}';
        final data =
            SensorData.fromJson(Map<String, dynamic>.from(jsonDecode(json)));
        print(
            'DEBUG: Parsed sensor data - Voltage: ${data.voltage}V, Current: ${data.current}A');
        _dataController.add(data);
      } catch (e) {
        print('DEBUG: JSON parsing failed, trying simple number: $e');
        // If JSON parsing fails, try simple number
        double? value = double.tryParse(line);
        if (value != null) {
          print('DEBUG: Parsed as simple value: $value');
          _dataController.add(SensorData(voltage: value, current: 0));
        } else {
          print('DEBUG: Failed to parse line as data: $line');
        }
      }
    }
  }

  void sendCommand(String command) {
    if (_port != null && _port!.isOpen) {
      print('DEBUG: Sending to Arduino: $command');
      _port!.write(Uint8List.fromList('$command\n'.codeUnits));
      // Flush to ensure command is sent immediately
      try {
        _port!.drain();
      } catch (e) {
        print('DEBUG: Drain failed: $e');
      }
    } else {
      print('DEBUG: Cannot send command - port not open');
    }
  }

  void sendPing() {
    print('DEBUG: Sending PING');
    sendCommand(SerialCommand.ping);
  }

  void startDataStream() {
    print('DEBUG: Starting data stream');
    sendCommand(SerialCommand.startData);
    _statusController.add('Data streaming started');
  }

  void stopDataStream() {
    print('DEBUG: Stopping data stream');
    sendCommand(SerialCommand.stopData);
    _statusController.add('Data streaming stopped');
  }

  void startSweep(DCSweepConfig config) {
    print('DEBUG: Starting DC sweep with config: ${config.toJson()}');
    sendCommand(SerialCommand.sweepConfig(config));
    sendCommand(SerialCommand.startSweep);
    _statusController.add('DC Sweep started');
  }

  void sendDCSweepConfig(DCSweepConfig config) {
    // Send DC sweep configuration as JSON
    final jsonCommand = jsonEncodeMap(config.toJson());
    print('DEBUG: Sending DC sweep config: $jsonCommand');
    sendCommand(jsonCommand);
    _statusController.add('DC Sweep config sent: $jsonCommand');
  }

  String jsonEncodeMap(Map<String, dynamic> map) {
    final pairs = map.entries
        .map(
            (e) => '"${e.key}":${e.value is String ? '"${e.value}"' : e.value}')
        .toList();
    return '{${pairs.join(',')}}';
  }

  void stopSweep() {
    print('DEBUG: Stopping DC sweep');
    sendCommand(SerialCommand.stopSweep);
    _statusController.add('DC Sweep stopped');
  }

  void disconnect() {
    print('DEBUG: Disconnecting from serial port');

    // Cancel subscription first
    _subscription?.cancel();
    _subscription = null;

    // Close reader
    _reader?.close();
    _reader = null;

    // Close port
    if (_port != null) {
      try {
        _port!.close();
      } catch (e) {
        print('DEBUG: Error closing port: $e');
      }
      _port = null;
    }

    // Clear buffer
    _buffer = '';

    _statusController.add('Disconnected');
    print('DEBUG: Disconnect complete');
  }

  void dispose() {
    print('DEBUG: Disposing SerialManager');
    disconnect();
    _dataController.close();
    _statusController.close();
  }

  dynamic jsonDecode(String source) {
    // Simple JSON decoder for basic cases
    print('DEBUG: Decoding JSON: $source');
    if (source.startsWith('{') && source.endsWith('}')) {
      final Map<String, dynamic> result = {};
      final content = source.substring(1, source.length - 1);
      final pairs = content.split(',');

      for (var pair in pairs) {
        final kv = pair.split(':');
        if (kv.length == 2) {
          final key = kv[0].trim().replaceAll('"', '');
          final value = kv[1].trim().replaceAll('"', '');
          result[key] = double.tryParse(value) ?? value;
        }
      }
      print('DEBUG: JSON decoded result: $result');
      return result;
    }
    print('DEBUG: JSON decode failed - returning empty map');
    return {};
  }
}
