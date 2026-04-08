import 'package:window_manager/window_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'theme.dart';
import 'models.dart';
import 'serial_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1280, 720),
    minimumSize: Size(1280, 720),
    maximumSize: Size(1280, 720),
    center: true,
    title: 'Serial Port Plotter',
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setResizable(false);
  });

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool isDarkMode = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Serial Port Plotter',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: SerialPlotterPage(
        onThemeToggle: () => setState(() => isDarkMode = !isDarkMode),
      ),
    );
  }
}

class SerialPlotterPage extends StatefulWidget {
  final VoidCallback onThemeToggle;

  const SerialPlotterPage({super.key, required this.onThemeToggle});

  @override
  State<SerialPlotterPage> createState() => _SerialPlotterPageState();
}

class _SerialPlotterPageState extends State<SerialPlotterPage> {
  final SerialManager _serialManager = SerialManager();
  final GlobalKey _graphKey = GlobalKey();
  final ScrollController _tableScrollController = ScrollController();

  String? selectedPort;
  int selectedBaudRate = 115200;
  bool isConnected = false;
  bool isScanning = false;
  bool isMonitoring = false;
  bool isPlotting = false;
  bool isSweeping = false;
  String statusMessage = '';

  double currentVoltage = 0.0;
  double currentCurrent = 0.0;

  List<FlSpot> dataPoints = [];
  List<TableDataRow> dataRows = [];
  final int maxDataPoints = 1000;

  double sweepStart = 0.0;
  double sweepEnd = 5.0;
  double sweepStep = 0.1;
  int sweepDelay = 100;

  Set<int> _hitSweepSteps = {};
  int _totalSweepSteps = 0;
  bool _sweepActive = false;

  StreamSubscription? _dataSubscription;
  StreamSubscription? _statusSubscription;
  Timer? _connectionCheckTimer;

  @override
  void initState() {
    super.initState();
    _setupListeners();
    _startConnectionCheck();
  }

  void _startConnectionCheck() {
    _connectionCheckTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (isConnected && !_serialManager.isConnected) {
        setState(() {
          isConnected = false;
          isMonitoring = false;
          isPlotting = false;
          isSweeping = false;
          currentVoltage = 0.0;
          currentCurrent = 0.0;
          statusMessage = 'Connection lost';
        });
      }
    });
  }

  void _processSweepDataPoint(SensorData data) {
    final v = data.voltage;

    // Check if this voltage matches any expected sweep step (within ±stepSize/2 tolerance)
    final tolerance = sweepStep / 2.0;

    int stepIndex = ((v - sweepStart) / sweepStep).round();
    double expectedVoltage = sweepStart + stepIndex * sweepStep;

    if (stepIndex >= 0 &&
        stepIndex < _totalSweepSteps &&
        (v - expectedVoltage).abs() <= tolerance) {
      // Valid sweep point — only add if not already hit this step
      if (!_hitSweepSteps.contains(stepIndex)) {
        _hitSweepSteps.add(stepIndex);
        _addDataPoint(data);

        // Check if all steps are done
        if (_hitSweepSteps.length >= _totalSweepSteps) {
          _completeSweep();
        }
      }
    }
  }

  void _completeSweep() {
    setState(() {
      _sweepActive = false;
      isSweeping = false;
      isPlotting = false;
    });

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: AppColors.success),
            SizedBox(width: 8),
            Text('DC Sweep Completed'),
          ],
        ),
        content: Text(
          'Sweep finished!\n\n'
          '• Range: ${sweepStart.toStringAsFixed(2)}V → ${sweepEnd.toStringAsFixed(2)}V\n'
          '• Steps: $_totalSweepSteps (${sweepStep.toStringAsFixed(3)}V each)\n'
          '• Data points collected: ${dataPoints.length}',
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.success),
            child: const Text('OK', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _setupListeners() {
    _dataSubscription = _serialManager.dataStream.listen((data) {
      if (isMonitoring) {
        setState(() {
          currentVoltage = data.voltage;
          currentCurrent = data.current;
        });
      }

      if (isPlotting && !_sweepActive) {
        _addDataPoint(data); // normal plotting (no sweep)
      }

      if (isPlotting && _sweepActive) {
        _processSweepDataPoint(data);
      }
    });

    _statusSubscription = _serialManager.statusStream.listen((status) {
      setState(() => statusMessage = status);
    });
  }

  @override
  void dispose() {
    _connectionCheckTimer?.cancel();
    _dataSubscription?.cancel();
    _statusSubscription?.cancel();
    _tableScrollController.dispose();
    _serialManager.dispose();
    super.dispose();
  }

  void _addDataPoint(SensorData data) {
    setState(() {
      dataPoints.add(FlSpot(data.voltage, data.current));
      dataRows.insert(
        0,
        TableDataRow(
          index: dataRows.length + 1,
          voltageValue: data.voltage,
          currentValue: data.current,
        ),
      );
      if (dataPoints.length > maxDataPoints) dataPoints.removeAt(0);
    });
  }

  Future<void> autoScanAndConnect() async {
    if (isScanning || isConnected) return;

    setState(() {
      isScanning = true;
      statusMessage = 'Starting auto-scan...';
    });

    try {
      final foundPort =
          await _serialManager.autoDetectArduino(selectedBaudRate);

      if (foundPort != null) {
        setState(() => selectedPort = foundPort);
        await Future.delayed(const Duration(milliseconds: 500));
        final connected =
            await _serialManager.connect(foundPort, selectedBaudRate);
        setState(() {
          isConnected = connected;
          isScanning = false;
        });
      } else {
        setState(() {
          isScanning = false;
          statusMessage = 'Smart kit not detected';
        });
        _showError('Smart kit not found. Check connection and signature.');
      }
    } catch (e) {
      setState(() {
        isScanning = false;
        statusMessage = 'Scan failed: $e';
      });
    }
  }

  void _disconnect() {
    if (isMonitoring) _serialManager.stopDataStream();
    if (isSweeping) _serialManager.stopSweep();
    _serialManager.disconnect();
    setState(() {
      isConnected = false;
      isMonitoring = false;
      isPlotting = false;
      isSweeping = false;
      currentVoltage = 0.0;
      currentCurrent = 0.0;
    });
  }

  void _toggleMonitoring() {
    if (isMonitoring) {
      _serialManager.stopDataStream();
      setState(() {
        isMonitoring = false;
        currentVoltage = 0.0;
        currentCurrent = 0.0;
      });
    } else {
      _serialManager.startDataStream();
      setState(() => isMonitoring = true);
    }
  }

  void _stopSweep() {
    setState(() {
      _sweepActive = false;
      isSweeping = false;
      isPlotting = false;
    });
    _showMessage('DC Sweep stopped manually.', AppColors.warning);
  }

  void _togglePlotting() {
    if (isPlotting) {
      setState(() {
        isPlotting = false;
        _sweepActive = false;
        isSweeping = false;
      });
    } else {
      setState(() {
        dataPoints.clear();
        dataRows.clear();
        isPlotting = true;
      });
    }
  }

  void _clearGraph() {
    setState(() {
      dataPoints.clear();
      dataRows.clear();
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: AppColors.error,
      behavior: SnackBarBehavior.floating,
      width: 300,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
  }

  void _showMessage(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      width: 300,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
  }

  void _showDCSweepConfigDialog() {
    final startController = TextEditingController(text: sweepStart.toString());
    final endController = TextEditingController(text: sweepEnd.toString());
    final stepController = TextEditingController(text: sweepStep.toString());
    final delayController = TextEditingController(text: sweepDelay.toString());
    String? startError, endError, stepError, delayError;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('DC Sweep Configuration'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _sweepField(
                  controller: startController,
                  label: 'Start (V)',
                  errorText: startError,
                  onChanged: (v) => setDialogState(() {
                    if (v.isEmpty) {
                      startError = 'Start voltage is required';
                    } else if (double.tryParse(v) == null) {
                      startError = 'Enter a valid decimal value';
                    } else {
                      startError = null;
                      sweepStart = double.parse(v);
                    }
                  }),
                ),
                const SizedBox(height: 12),
                _sweepField(
                  controller: endController,
                  label: 'End (V)',
                  errorText: endError,
                  onChanged: (v) => setDialogState(() {
                    if (v.isEmpty) {
                      endError = 'End voltage is required';
                    } else if (double.tryParse(v) == null) {
                      endError = 'Enter a valid decimal value';
                    } else {
                      endError = null;
                      sweepEnd = double.parse(v);
                    }
                  }),
                ),
                const SizedBox(height: 12),
                _sweepField(
                  controller: stepController,
                  label: 'Step (V)',
                  errorText: stepError,
                  onChanged: (v) => setDialogState(() {
                    if (v.isEmpty) {
                      stepError = 'Step is required';
                    } else if (double.tryParse(v) == null) {
                      stepError = 'Enter a valid decimal value';
                    } else if (double.parse(v) <= 0) {
                      stepError = 'Step must be > 0';
                    } else {
                      stepError = null;
                      sweepStep = double.parse(v);
                    }
                  }),
                ),
                const SizedBox(height: 12),
                _sweepField(
                  controller: delayController,
                  label: 'Delay (ms)',
                  errorText: delayError,
                  isInt: true,
                  onChanged: (v) => setDialogState(() {
                    if (v.isEmpty) {
                      delayError = 'Delay is required';
                    } else if (int.tryParse(v) == null) {
                      delayError = 'Enter a valid integer value';
                    } else if (int.parse(v) < 0) {
                      delayError = 'Delay cannot be negative';
                    } else {
                      delayError = null;
                      sweepDelay = int.parse(v);
                    }
                  }),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: startError == null &&
                      endError == null &&
                      stepError == null &&
                      delayError == null &&
                      startController.text.isNotEmpty &&
                      endController.text.isNotEmpty &&
                      stepController.text.isNotEmpty &&
                      delayController.text.isNotEmpty
                  ? () {
                      // Calculate total steps
                      final steps =
                          ((sweepEnd - sweepStart) / sweepStep).ceil() + 1;
                      if (!isMonitoring) {
                        _serialManager.startDataStream();
                      }
                      setState(() {
                        isMonitoring = true;
                        _totalSweepSteps = steps;
                        _hitSweepSteps = {};
                        _sweepActive = true;
                        isSweeping = true;
                        dataPoints.clear();
                        dataRows.clear();
                        isPlotting = true;
                      });
                      Navigator.pop(context);
                      _showMessage(
                        'DC Sweep started: ${sweepStart}V → ${sweepEnd}V, step ${sweepStep}V',
                        AppColors.success,
                      );
                    }
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.success,
                foregroundColor: Colors.white,
              ),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sweepField({
    required TextEditingController controller,
    required String label,
    required String? errorText,
    required ValueChanged<String> onChanged,
    bool isInt = false,
  }) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        errorText: errorText,
        hintText: isInt ? 'Enter integer value' : 'Enter decimal value',
      ),
      keyboardType: isInt
          ? TextInputType.number
          : const TextInputType.numberWithOptions(decimal: true),
      onChanged: onChanged,
    );
  }

  Future<void> _exportCSV() async {
    try {
      final timestamp = DateTime.now()
          .toString()
          .replaceAll('.', '_')
          .replaceAll(':', '-')
          .substring(0, 19);

      final result = await FilePicker.platform.saveFile(
        fileName: 'sensor_data_$timestamp.csv',
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );

      if (result == null) return;

      final csvBuffer = StringBuffer()..writeln('Voltage(V),Current(mA)');
      for (final p in dataPoints) {
        csvBuffer
            .writeln('${p.x.toStringAsFixed(4)},${p.y.toStringAsFixed(4)}');
      }

      await File(result).writeAsString(csvBuffer.toString());
      _showMessage('CSV exported successfully!\n$result', AppColors.success);
    } catch (e) {
      _showError('Error exporting CSV: $e');
    }
  }

  Future<void> _exportGraphImage() async {
    try {
      final timestamp = DateTime.now()
          .toString()
          .replaceAll('.', '_')
          .replaceAll(':', '-')
          .substring(0, 19);

      final result = await FilePicker.platform.saveFile(
        fileName: 'graph_$timestamp.png',
        type: FileType.custom,
        allowedExtensions: ['png'],
      );

      if (result == null) return;

      final boundary = _graphKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        _showError('Failed to find graph widget');
        return;
      }

      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        _showError('Failed to convert image');
        return;
      }

      await File(result).writeAsBytes(byteData.buffer.asUint8List());
      _showMessage(
          'Graph image exported successfully!\n$result', AppColors.success);
    } catch (e) {
      _showError('Error exporting image: $e');
    }
  }

  void _showContextMenu(BuildContext context, Offset position) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          enabled: dataPoints.isNotEmpty,
          onTap: () => Future.delayed(Duration.zero, _exportGraphImage),
          child: const Row(children: [
            Icon(Icons.image, size: 18),
            SizedBox(width: 8),
            Text('Export Graph as Image'),
          ]),
        ),
        PopupMenuItem(
          enabled: dataPoints.isNotEmpty,
          onTap: () => Future.delayed(Duration.zero, _exportCSV),
          child: const Row(children: [
            Icon(Icons.download, size: 18),
            SizedBox(width: 8),
            Text('Export Data as CSV'),
          ]),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        toolbarHeight: 80,
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            _appBarButton(
              onPressed: isScanning
                  ? null
                  : (isConnected ? _disconnect : autoScanAndConnect),
              icon: isScanning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Icon(isConnected ? Icons.stop : Icons.search, size: 18),
              label: isScanning
                  ? 'Scanning...'
                  : (isConnected ? 'Disconnect' : 'Scan & Connect'),
              color: isConnected ? AppColors.error : AppColors.success,
            ),
            const SizedBox(width: 10),
            _appBarButton(
              onPressed:
                  !isConnected || isPlotting ? null : _showDCSweepConfigDialog,
              icon: const Icon(Icons.settings_input_composite, size: 18),
              label: 'DC Sweep',
              color: const Color.fromARGB(255, 243, 159, 33),
            ),
            const SizedBox(width: 10),
            if (isSweeping)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: _appBarButton(
                  onPressed: _stopSweep,
                  icon: const Icon(Icons.stop_circle, size: 18),
                  label: 'Stop Sweep',
                  color: AppColors.error,
                ),
              ),
            const SizedBox(width: 10),
            _appBarButton(
              onPressed: !isConnected || isSweeping ? null : _toggleMonitoring,
              icon: Icon(isMonitoring ? Icons.pause : Icons.monitor, size: 18),
              label: isMonitoring ? 'Stop Monitor' : 'Start Monitor',
              color: isMonitoring ? AppColors.warning : AppColors.success,
            ),
            const SizedBox(width: 10),
            _appBarButton(
              onPressed: !isConnected || !isMonitoring || isSweeping
                  ? null
                  : _togglePlotting,
              icon: Icon(isPlotting ? Icons.stop : Icons.show_chart, size: 18),
              label: isPlotting ? 'Stop Plot' : 'Start Plot',
              color: isPlotting ? AppColors.error : AppColors.success,
            ),
            const SizedBox(width: 20),
            _buildRealTimeData(currentVoltage, currentCurrent),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(right: 20),
              child: _appBarButton(
                onPressed: _clearGraph,
                icon: const Icon(Icons.clear_all, size: 18),
                label: 'Clear',
                color: AppColors.error,
              ),
            ),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: _buildGraph()),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 260,
                    child: _buildDataTable(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _buildStatusBar(),
          ],
        ),
      ),
    );
  }

  Widget _appBarButton({
    required VoidCallback? onPressed,
    required Widget icon,
    required String label,
    required Color color,
  }) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: icon,
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  Widget _buildGraph() {
    double minX = -0.5, maxX = 5.5;
    double minY = -0.5, maxY = 5.5;

    if (dataPoints.isNotEmpty) {
      double rawMinX =
          dataPoints.map((p) => p.x).reduce((a, b) => a < b ? a : b);
      double rawMaxX =
          dataPoints.map((p) => p.x).reduce((a, b) => a > b ? a : b);
      double rawMinY =
          dataPoints.map((p) => p.y).reduce((a, b) => a < b ? a : b);
      double rawMaxY =
          dataPoints.map((p) => p.y).reduce((a, b) => a > b ? a : b);

      double xSpan = (rawMaxX - rawMinX).abs();
      double ySpan = (rawMaxY - rawMinY).abs();
      if (xSpan < 0.001) xSpan = 1.0;
      if (ySpan < 0.001) ySpan = 1.0;

      minX = rawMinX - xSpan * 0.1;
      maxX = rawMaxX + xSpan * 0.1;
      minY = rawMinY - ySpan * 0.1;
      maxY = rawMaxY + ySpan * 0.1;
    }

    return GestureDetector(
      onSecondaryTapDown: (details) {
        if (dataPoints.isNotEmpty) {
          _showContextMenu(context, details.globalPosition);
        }
      },
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: RepaintBoundary(
            key: _graphKey,
            child: Container(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.grey[900]
                  : AppColors.grey.withValues(alpha: 0.01),
              padding: const EdgeInsets.only(top: 5.0, right: 5.0),
              child: dataPoints.isEmpty
                  ? const Center(
                      child: Text(
                        'No data yet. Press "Start Monitor" then "Start Plot" to begin.',
                        style: TextStyle(
                            fontSize: 16, color: AppColors.textDisabled),
                      ),
                    )
                  : LineChart(LineChartData(
                      minX: minX,
                      maxX: maxX,
                      minY: minY,
                      maxY: maxY,
                      clipData: const FlClipData.all(),
                      gridData: const FlGridData(show: true),
                      titlesData: FlTitlesData(
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(
                          showTitles: false,
                          reservedSize: 10,
                        )),
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(
                          showTitles: false,
                          reservedSize: 10,
                        )),
                        bottomTitles: AxisTitles(
                          axisNameWidget: const Text('Voltage (V)'),
                          axisNameSize: 20,
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 20,
                            interval: (maxX - minX) / 5,
                            getTitlesWidget: (value, _) => Padding(
                              padding: const EdgeInsets.only(top: 8.0),
                              child: Text(value.toStringAsFixed(2),
                                  style: const TextStyle(fontSize: 10)),
                            ),
                          ),
                        ),
                        leftTitles: AxisTitles(
                          axisNameWidget: const Text('Current (A)'),
                          axisNameSize: 20,
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 30,
                            interval: (maxY - minY) / 5,
                            getTitlesWidget: (value, _) => Padding(
                              padding: const EdgeInsets.only(right: 8.0),
                              child: Text(value.toStringAsFixed(2),
                                  style: const TextStyle(fontSize: 10)),
                            ),
                          ),
                        ),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(color: AppColors.borderColor),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: dataPoints,
                          isCurved: true,
                          preventCurveOverShooting: true,
                          color: AppColors.primary,
                          barWidth: 3,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            color: AppColors.primary.withValues(alpha: 0.1),
                          ),
                        ),
                      ],
                    )),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRealTimeData(double voltage, double current) {
    return SizedBox(
      width: 200,
      height: 70,
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _valueColumn('Voltage', '${voltage.toStringAsFixed(2)} V'),
              Container(
                  height: 40,
                  width: 2,
                  color: const Color.fromARGB(255, 9, 105, 232)),
              _valueColumn('Current', '${current.toStringAsFixed(2)} mA'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _valueColumn(String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        Text(value,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildDataTable() {
    return GestureDetector(
      onSecondaryTapDown: (details) {
        if (dataRows.isNotEmpty)
          _showContextMenu(context, details.globalPosition);
      },
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Incoming Data',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.download, size: 18),
                        onPressed: dataRows.isEmpty ? null : _exportCSV,
                        tooltip: 'Export CSV',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.image, size: 18),
                        onPressed: dataRows.isEmpty ? null : _exportGraphImage,
                        tooltip: 'Export Image',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Container(
              color: AppColors.primary.withValues(alpha: 0.1),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              child: const Row(
                children: [
                  SizedBox(
                      width: 40,
                      child: Text('Sr.No',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 12))),
                  SizedBox(
                      width: 90,
                      child: Text('Voltage(V)',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 12))),
                  Expanded(
                      child: Text('Current(mA)',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 12))),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: dataRows.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text(
                          'No data logged yet\n\nPress "Start Monitor" then "Start Plot"\n\nRight-click to export',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 14, color: AppColors.textDisabled),
                        ),
                      ),
                    )
                  : Scrollbar(
                      controller: _tableScrollController,
                      thumbVisibility: true,
                      child: ListView.builder(
                        controller: _tableScrollController,
                        itemCount: dataRows.length,
                        itemBuilder: (context, index) {
                          final row = dataRows[index];
                          return Container(
                            height: 30,
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                    color: Colors.grey.withValues(alpha: 0.2),
                                    width: 0.5),
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 40,
                                  child: Text(row.index.toString(),
                                      style: const TextStyle(fontSize: 11)),
                                ),
                                SizedBox(
                                  width: 90,
                                  child: Text(
                                      row.voltageValue.toStringAsFixed(4),
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: AppColors.voltageLineColor,
                                          fontWeight: FontWeight.w500)),
                                ),
                                Expanded(
                                  child: Text(
                                      row.currentValue.toStringAsFixed(4),
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: AppColors.currentLineColor,
                                          fontWeight: FontWeight.w500)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          children: [
            Icon(
              isConnected ? Icons.circle : Icons.circle_outlined,
              color: isConnected ? AppColors.success : AppColors.textDisabled,
              size: 14,
            ),
            const SizedBox(width: 6),
            Text(
              isConnected ? 'Connected' : 'Disconnected',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: isConnected ? AppColors.success : AppColors.textDisabled,
              ),
            ),
            if (isMonitoring) ...[
              const SizedBox(width: 12),
              _buildStatusBadge('Monitoring', Icons.monitor, AppColors.success),
            ],
            if (isPlotting) ...[
              const SizedBox(width: 12),
              _buildStatusBadge(
                  'Plotting', Icons.show_chart, AppColors.streaming),
            ],
            if (isSweeping) ...[
              const SizedBox(width: 12),
              _buildStatusBadge('Sweeping', Icons.sync, AppColors.warning),
            ],
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                statusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: AppColors.info),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text('Points(1000 max): ${dataPoints.length}',
                style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(String label, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }
}

class TableDataRow {
  final int index;
  final double voltageValue;
  final double currentValue;

  const TableDataRow({
    required this.index,
    required this.voltageValue,
    required this.currentValue,
  });
}
