class SensorData {
  final double voltage;
  final double current;
  final DateTime timestamp;

  SensorData({
    required this.voltage,
    required this.current,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory SensorData.fromJson(Map<String, dynamic> json) {
    return SensorData(
      voltage: (json['voltage'] ?? json['v'] ?? 0.0).toDouble(),
      current: (json['current'] ?? json['i'] ?? 0.0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'voltage': voltage,
      'current': current,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  double get power => voltage * current;
}

class DCSweepConfig {
  final double startVoltage;
  final double endVoltage;
  final double stepVoltage;
  final int delayMs;

  DCSweepConfig({
    required this.startVoltage,
    required this.endVoltage,
    required this.stepVoltage,
    this.delayMs = 100,
  });

  int get totalSteps =>
      ((endVoltage - startVoltage) / stepVoltage).abs().ceil() + 1;

  Map<String, dynamic> toJson() {
    return {
      'start': startVoltage,
      'end': endVoltage,
      'step': stepVoltage,
      'delay': delayMs,
    };
  }

  String toCommand() {
    return 'SWEEP:$startVoltage,$endVoltage,$stepVoltage,$delayMs';
  }
}

class SerialCommand {
  static const String signature = 'vimlesh_kit_0001';
  static const String startData = 'START_DATA';
  static const String stopData = 'STOP_DATA';
  static const String startSweep = 'START_SWEEP';
  static const String stopSweep = 'STOP_SWEEP';
  static const String ping = 'PING';

  static String sweepConfig(DCSweepConfig config) {
    return config.toCommand();
  }
}
