import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart'
    as classic;
import 'package:permission_handler/permission_handler.dart';

// #region LOGGING
void _log(String message) {
  debugPrint('🅿️ [$message]');
}
// #endregion

// =============================================================================
// ARQUITECTURA UNIFICADA: WRAPPER UNIVERSAL DE BLUETOOTH
// =============================================================================

/// Clase abstracta que define la interfaz común para cualquier dispositivo Bluetooth
/// (sea BLE o Clásico). Esto permite que la lógica de negocio funcione sin importar
/// el tipo de módulo conectado.
abstract class UniversalBluetoothDevice {
  String get name;
  String get address;
  bool get isConnected;

  Future<void> connect();
  Future<void> disconnect();
  Future<void> send(String data);
  Stream<String> get dataStream;
}

// =============================================================================
// IMPLEMENTACIÓN BLE (HM-10, BT-05, AT-09)
// =============================================================================

class BLEDevice implements UniversalBluetoothDevice {
  final ble.BluetoothDevice device;
  ble.BluetoothCharacteristic? _characteristic;
  final StreamController<String> _dataController =
      StreamController<String>.broadcast();
  StreamSubscription<List<int>>? _notifySubscription;
  bool _isConnected = false;

  // UUIDs estándar para módulos BLE genéricos (HM-10, BT-05, AT-09)
  static const String SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb";
  static const String CHAR_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb";

  BLEDevice(this.device);

  @override
  String get name => device.platformName;

  @override
  String get address => device.remoteId.toString();

  @override
  bool get isConnected => _isConnected;

  @override
  Stream<String> get dataStream => _dataController.stream;

  @override
  Future<void> connect() async {
    try {
      _log("BLE: Conectando a $name...");
      await device.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 15),
      );

      _log("BLE: Descubriendo servicios...");
      List<ble.BluetoothService> services = await device.discoverServices();

      // Buscar la característica FFE1 (UART estándar para módulos BLE genéricos)
      for (ble.BluetoothService service in services) {
        if (service.uuid.toString().toLowerCase().contains("ffe0")) {
          for (ble.BluetoothCharacteristic c in service.characteristics) {
            if (c.uuid.toString().toLowerCase().contains("ffe1")) {
              _characteristic = c;
              break;
            }
          }
        }
      }

      if (_characteristic == null) {
        throw Exception(
          "No se encontró característica FFE1 (módulo no compatible)",
        );
      }

      // Activar notificaciones para recibir datos
      await _characteristic!.setNotifyValue(true);
      _notifySubscription = _characteristic!.lastValueStream.listen((value) {
        String data = utf8.decode(value);
        _dataController.add(data);
      });

      _isConnected = true;
      _log("BLE: Conectado exitosamente a $name");
    } catch (e) {
      _log("BLE: Error de conexión: $e");
      _isConnected = false;
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _notifySubscription?.cancel();
      await device.disconnect();
      _isConnected = false;
      _log("BLE: Desconectado de $name");
    } catch (e) {
      _log("BLE: Error al desconectar: $e");
    }
  }

  @override
  Future<void> send(String data) async {
    if (_characteristic == null) {
      throw Exception("No hay característica disponible");
    }
    try {
      // Enviar con retorno de carro y nueva línea para máxima compatibilidad
      String dataWithCR = "$data\r\n";
      _log("BLE: Enviando: '$data' como bytes: ${utf8.encode(dataWithCR)}");

      // Usar withoutResponse: false porque algunos módulos BLE no soportan WRITE_NO_RESPONSE
      await _characteristic!.write(
        utf8.encode(dataWithCR),
        withoutResponse: false, // Cambiado a false para compatibilidad
      );
      _log("BLE: ✓ Enviado correctamente");
    } catch (e) {
      _log("BLE: ✗ Error al enviar: $e");
      rethrow;
    }
  }

  void dispose() {
    _notifySubscription?.cancel();
    _dataController.close();
  }
}

// =============================================================================
// IMPLEMENTACIÓN CLÁSICO (HC-05, HC-06)
// =============================================================================

class ClassicDevice implements UniversalBluetoothDevice {
  final classic.BluetoothDevice device;
  classic.BluetoothConnection? _connection;
  final StreamController<String> _dataController =
      StreamController<String>.broadcast();
  StreamSubscription<Uint8List>? _dataSubscription;
  bool _isConnected = false;

  ClassicDevice(this.device);

  @override
  String get name => device.name ?? "HC-05/06";

  @override
  String get address => device.address;

  @override
  bool get isConnected => _isConnected;

  @override
  Stream<String> get dataStream => _dataController.stream;

  @override
  Future<void> connect() async {
    try {
      _log("Clásico: Conectando a $name...");

      // Conectar mediante SPP (Serial Port Profile)
      _connection = await classic.BluetoothConnection.toAddress(device.address);

      // Escuchar datos entrantes
      _dataSubscription = _connection!.input!.listen((Uint8List data) {
        String received = utf8.decode(data);
        _dataController.add(received);
      });

      _isConnected = true;
      _log("Clásico: Conectado exitosamente a $name");
    } catch (e) {
      _log("Clásico: Error de conexión: $e");
      _isConnected = false;
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _dataSubscription?.cancel();
      await _connection?.close();
      _isConnected = false;
      _log("Clásico: Desconectado de $name");
    } catch (e) {
      _log("Clásico: Error al desconectar: $e");
    }
  }

  @override
  Future<void> send(String data) async {
    if (_connection == null || !_connection!.isConnected) {
      throw Exception("Dispositivo no conectado");
    }
    try {
      // Enviar con retorno de carro y nueva línea para máxima compatibilidad
      String dataWithCR = "$data\r\n";
      _log("Clásico: Enviando: '$data' como bytes: ${utf8.encode(dataWithCR)}");

      _connection!.output.add(utf8.encode(dataWithCR));
      await _connection!.output.allSent;
      _log("Clásico: ✓ Enviado correctamente");
    } catch (e) {
      _log("Clásico: ✗ Error al enviar: $e");
      rethrow;
    }
  }

  void dispose() {
    _dataSubscription?.cancel();
    _dataController.close();
  }
}

// =============================================================================
// CONTROLADOR UNIVERSAL: MANEJA AMBOS TIPOS
// =============================================================================

enum BluetoothType { ble, classic }

class DeviceInfo {
  final String name;
  final String address;
  final BluetoothType type;
  final dynamic rawDevice; // ble.BluetoothDevice o classic.BluetoothDevice

  DeviceInfo({
    required this.name,
    required this.address,
    required this.type,
    required this.rawDevice,
  });
}

class UniversalBluetoothController {
  UniversalBluetoothDevice? _currentDevice;
  final StreamController<List<DeviceInfo>> _devicesController =
      StreamController<List<DeviceInfo>>.broadcast();

  StreamSubscription<List<ble.ScanResult>>? _bleScanSubscription;
  StreamSubscription<ble.BluetoothAdapterState>? _bleAdapterSubscription;

  List<DeviceInfo> _discoveredDevices = [];
  bool _isScanning = false;

  Stream<List<DeviceInfo>> get devicesStream => _devicesController.stream;
  bool get isScanning => _isScanning;
  UniversalBluetoothDevice? get currentDevice => _currentDevice;

  /// Inicia escaneo de AMBOS tipos de Bluetooth simultáneamente
  Future<void> startScan() async {
    if (_isScanning) return;

    _isScanning = true;
    _discoveredDevices.clear();
    _devicesController.add(_discoveredDevices);

    try {
      // 1. Escanear BLE (flutter_blue_plus)
      await _scanBLE();

      // 2. Escanear Clásico (flutter_bluetooth_serial)
      await _scanClassic();
    } catch (e) {
      _log("Error en escaneo: $e");
    } finally {
      _isScanning = false;
    }
  }

  Future<void> _scanBLE() async {
    try {
      _log("Iniciando escaneo BLE...");

      // Escuchar resultados del escaneo BLE
      _bleScanSubscription = ble.FlutterBluePlus.scanResults.listen((results) {
        for (ble.ScanResult result in results) {
          if (result.device.platformName.isNotEmpty) {
            // Evitar duplicados
            bool exists = _discoveredDevices.any(
              (d) => d.address == result.device.remoteId.toString(),
            );
            if (!exists) {
              _discoveredDevices.add(
                DeviceInfo(
                  name: result.device.platformName,
                  address: result.device.remoteId.toString(),
                  type: BluetoothType.ble,
                  rawDevice: result.device,
                ),
              );
              _devicesController.add(List.from(_discoveredDevices));
            }
          }
        }
      });

      // Iniciar escaneo con timeout de 10 segundos
      await ble.FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        // No filtrar por UUID para encontrar todos los módulos BLE
      );

      _log("Escaneo BLE completado");
    } catch (e) {
      _log("Error en escaneo BLE: $e");
    }
  }

  Future<void> _scanClassic() async {
    try {
      _log("Iniciando escaneo Clásico...");

      // Obtener dispositivos vinculados (paired)
      List<classic.BluetoothDevice> bondedDevices = await classic
          .FlutterBluetoothSerial
          .instance
          .getBondedDevices();

      for (classic.BluetoothDevice device in bondedDevices) {
        // Evitar duplicados
        bool exists = _discoveredDevices.any(
          (d) => d.address == device.address,
        );
        if (!exists && device.name != null) {
          _discoveredDevices.add(
            DeviceInfo(
              name: device.name ?? "HC-05/06",
              address: device.address,
              type: BluetoothType.classic,
              rawDevice: device,
            ),
          );
          _devicesController.add(List.from(_discoveredDevices));
        }
      }

      _log("Escaneo Clásico completado");
    } catch (e) {
      _log("Error en escaneo Clásico: $e");
    }
  }

  Future<void> stopScan() async {
    try {
      await ble.FlutterBluePlus.stopScan();
      await _bleScanSubscription?.cancel();
      _isScanning = false;
    } catch (e) {
      _log("Error deteniendo escaneo: $e");
    }
  }

  /// Conecta al dispositivo seleccionado (decide automáticamente si es BLE o Clásico)
  Future<void> connect(DeviceInfo deviceInfo) async {
    try {
      await stopScan(); // Detener escaneo antes de conectar

      // Desconectar dispositivo anterior si existe
      if (_currentDevice != null) {
        await _currentDevice!.disconnect();
      }

      // Crear el wrapper apropiado según el tipo
      if (deviceInfo.type == BluetoothType.ble) {
        _currentDevice = BLEDevice(deviceInfo.rawDevice as ble.BluetoothDevice);
      } else {
        _currentDevice = ClassicDevice(
          deviceInfo.rawDevice as classic.BluetoothDevice,
        );
      }

      // Conectar
      await _currentDevice!.connect();
      _log("Conectado exitosamente a ${deviceInfo.name} (${deviceInfo.type})");
    } catch (e) {
      _log("Error al conectar: $e");
      _currentDevice = null;
      rethrow;
    }
  }

  Future<void> disconnect() async {
    if (_currentDevice != null) {
      await _currentDevice!.disconnect();
      _currentDevice = null;
    }
  }

  Future<void> send(String data) async {
    if (_currentDevice != null && _currentDevice!.isConnected) {
      await _currentDevice!.send(data);
    } else {
      throw Exception("No hay dispositivo conectado");
    }
  }

  Stream<String>? get dataStream => _currentDevice?.dataStream;

  void dispose() {
    _bleScanSubscription?.cancel();
    _bleAdapterSubscription?.cancel();
    _currentDevice?.disconnect();
    _devicesController.close();
  }
}

// =============================================================================
// APLICACIÓN PRINCIPAL
// =============================================================================

void main() {
  runApp(const ParkingTerminalApp());
}

class ParkingTerminalApp extends StatelessWidget {
  const ParkingTerminalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Parking Terminal IoT',
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.grey[100],
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  // --- CONTROLADOR BLUETOOTH UNIVERSAL ---
  final UniversalBluetoothController _btController =
      UniversalBluetoothController();
  StreamSubscription<String>? _dataStreamSubscription;

  // --- VARIABLES LÓGICAS ---
  String qrData = "";
  int precioDetectado = 0;
  int saldoIngresado = 0;
  int monedasNecesarias = 0;
  int monedasRecibidas = 0;
  bool ticketEscaneado = false;
  bool pagoCompletado = false;

  // Buffer y Control del Protocolo PIC
  String bufferBluetooth = "";
  bool picConfirmado = false;

  // --- CÁMARA ---
  MobileScannerController? cameraController;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _initBluetooth();
    _generarNuevoTicket();
    _inicializarCamara();
  }

  @override
  void dispose() {
    _dataStreamSubscription?.cancel();
    _btController.dispose();
    cameraController?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // GESTIÓN DE PERMISOS (ANDROID 10, 11, 12, 13+)
  // ---------------------------------------------------------------------------
  Future<void> _checkPermissions() async {
    if (Platform.isAndroid) {
      // Android 12+ (API 31+)
      await Permission.bluetoothScan.request();
      await Permission.bluetoothConnect.request();

      // Android < 12 (necesita ubicación)
      await Permission.location.request();

      // Para Cámara (QR)
      await Permission.camera.request();

      _log("Permisos verificados");
    }
  }

  void _initBluetooth() {
    // Escuchar estado del adaptador BLE
    ble.FlutterBluePlus.adapterState.listen((state) {
      if (state == ble.BluetoothAdapterState.off) {
        if (mounted) {
          _mostrarSnack("⚠ Encienda el Bluetooth", Colors.orange);
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // CÁMARA Y GENERACIÓN DE QR
  // ---------------------------------------------------------------------------
  void _inicializarCamara() {
    cameraController = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
  }

  void _generarNuevoTicket() {
    final random = Random();
    int monedas = random.nextInt(9) + 1; // 1 a 9 monedas
    int precio = monedas * 5;
    int ticketId = random.nextInt(9999);
    setState(() {
      qrData = "TICKET-ID-$ticketId|PRECIO:$precio";
    });
  }

  Future<void> _procesarQR(String rawValue) async {
    if (ticketEscaneado) return;

    // Verificar conexión Bluetooth ANTES de procesar el QR
    if (_btController.currentDevice == null ||
        !_btController.currentDevice!.isConnected) {
      _mostrarSnack(
        "⚠️ Conéctate al módulo Bluetooth primero (Pestaña Conexión)",
        Colors.red,
      );
      return;
    }

    if (cameraController != null) await cameraController!.stop();

    try {
      if (rawValue.contains("PRECIO:")) {
        final parts = rawValue.split('|');
        final precioPart = parts.firstWhere((e) => e.startsWith("PRECIO:"));
        final precioStr = precioPart.split(':')[1];
        int precio = int.parse(precioStr);
        int monedasReq = (precio / 5).ceil();

        if (!mounted) return;

        _log("🎫 QR Escaneado: \$$precio = $monedasReq monedas de \$5");

        setState(() {
          precioDetectado = precio;
          monedasNecesarias = monedasReq;
          monedasRecibidas = 0;
          ticketEscaneado = true;
          saldoIngresado = 0;
          pagoCompletado = false;
          bufferBluetooth = "";
          picConfirmado = false;
        });

        // ENVIAR AL PIC (funciona con BLE o Clásico gracias al wrapper)
        String comandoMonedas = monedasNecesarias.toString();
        await _btController.send(comandoMonedas);
        _log(
          "✉️ Enviado al PIC: '$comandoMonedas' (${monedasNecesarias} monedas de \$5 = \$$precio)",
        );
        _mostrarSnack(
          "📤 Enviado al PIC: $monedasNecesarias monedas (\$$precio)",
          Colors.indigo,
        );
      }
    } catch (e) {
      _log("❌ Error procesando QR: $e");
      _mostrarSnack("❌ Error al procesar el ticket", Colors.red);
      _inicializarCamara();
      setState(() {});
    }
  }

  void _resetTerminal() {
    _inicializarCamara();
    setState(() {
      ticketEscaneado = false;
      pagoCompletado = false;
      saldoIngresado = 0;
      precioDetectado = 0;
      monedasNecesarias = 0;
      monedasRecibidas = 0;
      bufferBluetooth = "";
      picConfirmado = false;
    });
  }

  // ---------------------------------------------------------------------------
  // PROTOCOLO PIC (UNIVERSAL - FUNCIONA CON BLE Y CLÁSICO)
  // ---------------------------------------------------------------------------

  /// Este método procesa los datos entrantes del PIC siguiendo el protocolo:
  /// - "ST" → Confirmación de tarifa (opcional)
  /// - "$" → Incremento de monedas (cada $ = 1 moneda = $5)
  /// - "P" → Pago completado
  void _onDataReceived(String data) {
    bufferBluetooth += data;
    _log("📨 Recibido del PIC: '$data' | Buffer: '$bufferBluetooth'");

    // 1. Confirmación de Tarifa "ST" (opcional)
    if (bufferBluetooth.contains("ST")) {
      if (!picConfirmado) {
        setState(() => picConfirmado = true);
        _log("✅ PIC confirmó tarifa recibida");
        _mostrarSnack("✅ PIC listo. Inserte monedas de \$5", Colors.green);
      }
      bufferBluetooth = bufferBluetooth.replaceAll("ST", "");
    }

    // 2. Conteo de Monedas "$" (cada $ = $5)
    int countDollars = "\$".allMatches(bufferBluetooth).length;
    if (countDollars > 0) {
      if (ticketEscaneado && !pagoCompletado) {
        setState(() {
          monedasRecibidas += countDollars;
          saldoIngresado = monedasRecibidas * 5;
        });
        _log(
          "💰 Moneda insertada! Total: $monedasRecibidas/${monedasNecesarias} monedas (\$$saldoIngresado/\$$precioDetectado)",
        );
        bufferBluetooth = bufferBluetooth.replaceAll("\$", "");

        // Feedback visual por cada moneda
        if (monedasRecibidas < monedasNecesarias) {
          int faltantes = monedasNecesarias - monedasRecibidas;
          _mostrarSnack(
            "💰 +\$5 | Faltan $faltantes monedas (\$${faltantes * 5})",
            Colors.blue,
          );
        }
      }
    }

    // 3. Pago Completo "P"
    if (bufferBluetooth.contains("P")) {
      _log("🎯 PIC envió señal de pago completo 'P'");
      if (monedasRecibidas >= monedasNecesarias && monedasNecesarias > 0) {
        setState(() {
          pagoCompletado = true;
          saldoIngresado = precioDetectado;
        });
        _log(
          "✨ PAGO COMPLETADO! ${monedasRecibidas} monedas = \$$saldoIngresado",
        );
        _mostrarSnack("✨ ¡PAGO COMPLETADO! 🚧 Pluma Abierta", Colors.green);
      } else {
        _log(
          "⚠️ PIC envió 'P' pero no hay suficientes monedas (${monedasRecibidas}/${monedasNecesarias})",
        );
      }
      bufferBluetooth = bufferBluetooth.replaceAll("P", "");
    }

    // Limpieza preventiva del buffer
    if (bufferBluetooth.length > 50) {
      _log("🧹 Buffer limpiado (excedió 50 caracteres)");
      bufferBluetooth = "";
    }
  }

  void _mostrarSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // INTERFAZ GRÁFICA
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Sistema Parking IoT Universal"),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        selectedItemColor: Colors.indigo,
        onTap: (idx) => setState(() => _selectedIndex = idx),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.qr_code), label: "Generar"),
          BottomNavigationBarItem(
            icon: Icon(Icons.point_of_sale),
            label: "Terminal",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bluetooth),
            label: "Conexión",
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          _buildGeneratorTab(),
          _buildTerminalTab(),
          _buildBluetoothTab(),
        ],
      ),
    );
  }

  // TAB 1: GENERADOR QR
  Widget _buildGeneratorTab() {
    return Center(
      child: Card(
        margin: const EdgeInsets.all(20),
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.all(30.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "ENTRADA DE VEHÍCULO",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 20),
              QrImageView(data: qrData, size: 200.0),
              const SizedBox(height: 20),
              Text(
                qrData,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _generarNuevoTicket,
                icon: const Icon(Icons.refresh),
                label: const Text("Generar Nuevo"),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // TAB 2: TERMINAL DE COBRO
  Widget _buildTerminalTab() {
    // Verificar estado de conexión Bluetooth
    bool bluetoothConectado =
        _btController.currentDevice != null &&
        _btController.currentDevice!.isConnected;

    return Column(
      children: [
        // Banner de estado Bluetooth
        if (!bluetoothConectado)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.orange[100],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.bluetooth_disabled,
                  color: Colors.orange[900],
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  "⚠️ Bluetooth desconectado - Ve a la pestaña Conexión",
                  style: TextStyle(
                    color: Colors.orange[900],
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        if (bluetoothConectado)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: Colors.green[100],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.bluetooth_connected,
                  color: Colors.green[900],
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  "✓ Conectado a ${_btController.currentDevice!.name}",
                  style: TextStyle(
                    color: Colors.green[900],
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          flex: 4,
          child: !ticketEscaneado && cameraController != null
              ? MobileScanner(
                  controller: cameraController!,
                  onDetect: (capture) {
                    final List<Barcode> barcodes = capture.barcodes;
                    for (final barcode in barcodes) {
                      if (barcode.rawValue != null) {
                        _procesarQR(barcode.rawValue!);
                        break;
                      }
                    }
                  },
                )
              : Container(
                  width: double.infinity,
                  color: pagoCompletado ? Colors.green[100] : Colors.indigo[50],
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        pagoCompletado
                            ? Icons.check_circle
                            : Icons.receipt_long,
                        size: 80,
                        color: pagoCompletado ? Colors.green : Colors.indigo,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        pagoCompletado ? "¡PAGO EXITOSO!" : "Total a Pagar",
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (!pagoCompletado)
                        Text(
                          "\$$precioDetectado",
                          style: const TextStyle(
                            fontSize: 40,
                            fontWeight: FontWeight.bold,
                            color: Colors.indigo,
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        Expanded(
          flex: 5,
          child: Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                if (ticketEscaneado) ...[
                  const Text(
                    "Dinero Ingresado:",
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  Text(
                    "\$$saldoIngresado",
                    style: const TextStyle(
                      fontSize: 60,
                      fontWeight: FontWeight.bold,
                      color: Colors.indigo,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.indigo[50],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      children: [
                        Text(
                          "Monedas: $monedasRecibidas / $monedasNecesarias",
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          "Falta: \$${(monedasNecesarias - monedasRecibidas) * 5}",
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (!pagoCompletado)
                    Chip(
                      avatar: Icon(
                        picConfirmado ? Icons.attach_money : Icons.sync,
                        color: Colors.white,
                        size: 18,
                      ),
                      label: Text(
                        picConfirmado
                            ? "INSERTE MONEDAS DE \$5"
                            : "ESPERANDO RESPUESTA DEL PIC...",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      backgroundColor: picConfirmado
                          ? Colors.green[600]
                          : Colors.orange,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                ] else
                  const Text(
                    "Escanee un ticket QR para comenzar",
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                const Spacer(),
                if (ticketEscaneado)
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: pagoCompletado
                            ? Colors.green
                            : Colors.red,
                      ),
                      onPressed: _resetTerminal,
                      child: Text(
                        pagoCompletado ? "FINALIZAR" : "CANCELAR",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // TAB 3: CONEXIÓN BLUETOOTH UNIVERSAL (BLE + CLÁSICO)
  Widget _buildBluetoothTab() {
    return Column(
      children: [
        // Header de Estado
        Container(
          padding: const EdgeInsets.all(16),
          color:
              _btController.currentDevice != null &&
                  _btController.currentDevice!.isConnected
              ? Colors.green[100]
              : Colors.grey[200],
          child: Row(
            children: [
              Icon(
                _btController.currentDevice != null &&
                        _btController.currentDevice!.isConnected
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_disabled,
                size: 30,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _btController.currentDevice != null &&
                              _btController.currentDevice!.isConnected
                          ? "Conectado"
                          : "Desconectado",
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    if (_btController.currentDevice != null)
                      Text(
                        _btController.currentDevice!.name,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                  ],
                ),
              ),
              if (_btController.currentDevice != null &&
                  _btController.currentDevice!.isConnected)
                ElevatedButton(
                  onPressed: () async {
                    await _btController.disconnect();
                    await _dataStreamSubscription?.cancel();
                    setState(() {});
                    _mostrarSnack("Desconectado", Colors.orange);
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text(
                    "Desconectar",
                    style: TextStyle(color: Colors.white),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Botón de Escaneo
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _btController.isScanning
                  ? null
                  : () async {
                      await _btController.startScan();
                      setState(() {});
                    },
              icon: _btController.isScanning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.search),
              label: Text(
                _btController.isScanning
                    ? "Escaneando..."
                    : "Buscar Dispositivos (BLE + Clásico)",
                style: const TextStyle(fontSize: 16),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ),

        // Lista de Dispositivos (BLE + Clásico con iconos distintos)
        Expanded(
          child: StreamBuilder<List<DeviceInfo>>(
            stream: _btController.devicesStream,
            initialData: const [],
            builder: (context, snapshot) {
              final devices = snapshot.data ?? [];

              if (devices.isEmpty) {
                return const Center(
                  child: Text(
                    "No se encontraron dispositivos.\nPresione 'Buscar' para escanear.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                );
              }

              return ListView.separated(
                itemCount: devices.length,
                separatorBuilder: (c, i) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final device = devices[index];
                  final isConnected =
                      _btController.currentDevice != null &&
                      _btController.currentDevice!.address == device.address;

                  return ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: device.type == BluetoothType.ble
                            ? Colors.blue[100]
                            : Colors.green[100],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        device.type == BluetoothType.ble
                            ? Icons
                                  .bluetooth_searching // BLE
                            : Icons.bluetooth, // Clásico
                        color: device.type == BluetoothType.ble
                            ? Colors.blue
                            : Colors.green,
                      ),
                    ),
                    title: Text(
                      device.name,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          device.address,
                          style: const TextStyle(fontSize: 11),
                        ),
                        Text(
                          device.type == BluetoothType.ble
                              ? "BLE (HM-10/BT-05/AT-09)"
                              : "Clásico (HC-05/HC-06)",
                          style: TextStyle(
                            fontSize: 10,
                            color: device.type == BluetoothType.ble
                                ? Colors.blue
                                : Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    trailing: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isConnected
                            ? Colors.grey
                            : Colors.indigo,
                      ),
                      onPressed: isConnected
                          ? null
                          : () async {
                              try {
                                await _btController.connect(device);

                                // Suscribirse al stream de datos
                                _dataStreamSubscription?.cancel();
                                _dataStreamSubscription = _btController
                                    .dataStream
                                    ?.listen(_onDataReceived);

                                setState(() {});
                                _mostrarSnack(
                                  "✅ Conectado a ${device.name}",
                                  Colors.green,
                                );
                              } catch (e) {
                                _mostrarSnack("❌ Error: $e", Colors.red);
                              }
                            },
                      child: Text(
                        isConnected ? "Conectado" : "Conectar",
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
