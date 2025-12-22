import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const ParkingTerminalApp());

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

  // --- BLUETOOTH ---
  BluetoothConnection? connection;
  bool isConnected = false;
  BluetoothDevice? selectedDevice;

  // --- VARIABLES LÓGICAS ---
  String qrData = "";
  int precioDetectado = 0;
  int saldoIngresado = 0;
  bool ticketEscaneado =
      false; // Controla si mostramos cámara o pantalla de pago
  bool pagoCompletado = false; // Controla si mostramos éxito

  // --- CÁMARA ---
  MobileScannerController? cameraController;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _generarNuevoTicket();
    _inicializarCamara();
  }

  @override
  void dispose() {
    cameraController?.dispose();
    if (isConnected) {
      connection?.dispose();
    }
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.camera,
      Permission.location,
    ].request();
  }

  // ---------------------------------------------------------------------------
  // 1. GESTIÓN SEGURA DE LA CÁMARA (Evita pantallas negras)
  // ---------------------------------------------------------------------------

  void _inicializarCamara() {
    cameraController = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      returnImage: false,
    );
  }

  Future<void> _destruirCamara() async {
    if (cameraController != null) {
      try {
        await cameraController!.stop();
      } catch (e) {
        debugPrint("Error deteniendo cámara: $e");
      }
      cameraController!.dispose();
      cameraController = null;
      // Pequeña pausa para que el hardware se libere
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  // ---------------------------------------------------------------------------
  // 2. LÓGICA DE NEGOCIO (Protocolo César)
  // ---------------------------------------------------------------------------

  void _generarNuevoTicket() {
    final random = Random();
    // Generamos entre 1 y 9 monedas ($5 a $45)
    // Esto es para enviar un solo dígito al PIC ("1"..."9")
    int monedas = random.nextInt(9) + 1;
    int precio = monedas * 5;

    int ticketId = random.nextInt(9999);
    setState(() {
      qrData = "TICKET-ID-$ticketId|PRECIO:$precio";
    });
  }

  Future<void> _procesarQR(String rawValue) async {
    if (ticketEscaneado) return;

    // 1. Matamos la cámara para congelar la UI y procesar
    await _destruirCamara();

    try {
      if (rawValue.contains("PRECIO:")) {
        // Parsear datos del QR
        final parts = rawValue.split('|');
        final precioPart = parts.firstWhere((e) => e.startsWith("PRECIO:"));
        final precioStr = precioPart.split(':')[1];

        int precio = int.parse(precioStr);
        // Calcular monedas necesarias (división entera redondeada hacia arriba)
        int monedasNecesarias = (precio / 5).ceil();

        if (!mounted) return;

        setState(() {
          precioDetectado = precio;
          ticketEscaneado = true;
          saldoIngresado = 0;
          pagoCompletado = false;
        });

        // 2. ENVIAR CUOTA AL PIC (Handshake Inicial)
        if (connection != null && connection!.isConnected) {
          // Enviamos el número como STRING (Ej: "3")
          connection!.output.add(utf8.encode(monedasNecesarias.toString()));
          await connection!.output.allSent;

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "Ticket de \$$precio. Pidiendo $monedasNecesarias monedas al PIC...",
              ),
              backgroundColor: Colors.indigo,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("⚠ Bluetooth desconectado. Conéctate primero."),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("Error QR: $e");
      // Si falló, revivimos la cámara
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
    });
  }

  // ---------------------------------------------------------------------------
  // 3. INTERFAZ GRÁFICA (Vistas)
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Sistema de Parking IoT"),
        elevation: 2,
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

  // --- TAB 1: GENERADOR QR ---
  Widget _buildGeneratorTab() {
    return Center(
      child: Card(
        margin: const EdgeInsets.all(20),
        elevation: 5,
        child: Padding(
          padding: const EdgeInsets.all(30.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "ENTRADA DE VEHÍCULO",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: Colors.indigo,
                ),
              ),
              const SizedBox(height: 20),
              QrImageView(data: qrData, version: QrVersions.auto, size: 200.0),
              const SizedBox(height: 20),
              Text(
                qrData,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 30),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                ),
                onPressed: _generarNuevoTicket,
                icon: const Icon(Icons.refresh),
                label: const Text("Generar Nuevo Ticket"),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- TAB 2: TERMINAL DE COBRO ---
  Widget _buildTerminalTab() {
    return Column(
      children: [
        // ZONA SUPERIOR: CÁMARA O INFO
        Expanded(
          flex: 4,
          child: !ticketEscaneado && cameraController != null
              ? ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(20),
                  ),
                  child: MobileScanner(
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
                  ),
                )
              : Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: pagoCompletado
                        ? Colors.green[100]
                        : Colors.indigo[50],
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(20),
                    ),
                  ),
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

        // ZONA INFERIOR: ESTADO DEL PROCESO
        Expanded(
          flex: 5,
          child: Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const SizedBox(height: 10),
                const Text(
                  "ESTADO DE LA MÁQUINA",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                const Divider(),
                const Spacer(),

                // VISUALIZADOR DE MONEDAS
                if (ticketEscaneado)
                  Column(
                    children: [
                      const Text(
                        "Dinero Ingresado:",
                        style: TextStyle(fontSize: 18),
                      ),
                      Text(
                        "\$$saldoIngresado",
                        style: const TextStyle(
                          fontSize: 60,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (!pagoCompletado)
                        const Chip(
                          avatar: Icon(
                            Icons.arrow_downward,
                            color: Colors.white,
                          ),
                          label: Text("INSERTE MONEDAS AHORA"),
                          backgroundColor: Colors.orange,
                          labelStyle: TextStyle(color: Colors.white),
                        ),
                      if (pagoCompletado)
                        const Chip(
                          avatar: Icon(Icons.lock_open, color: Colors.white),
                          label: Text("BARRERA ABIERTA"),
                          backgroundColor: Colors.green,
                          labelStyle: TextStyle(color: Colors.white),
                        ),
                    ],
                  )
                else
                  Column(
                    children: const [
                      Icon(Icons.qr_code_scanner, size: 50, color: Colors.grey),
                      SizedBox(height: 10),
                      Text(
                        "Escanee un ticket para comenzar",
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),

                const Spacer(),

                // BOTÓN DE REINICIO
                if (ticketEscaneado)
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: pagoCompletado
                            ? Colors.green
                            : Colors.redAccent,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _resetTerminal,
                      icon: Icon(pagoCompletado ? Icons.check : Icons.close),
                      label: Text(
                        pagoCompletado
                            ? "FINALIZAR / SIGUIENTE CLIENTE"
                            : "CANCELAR OPERACIÓN",
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

  // --- TAB 3: BLUETOOTH CON LISTENER CÉSAR ---
  Widget _buildBluetoothTab() {
    return Column(
      children: [
        ListTile(
          title: Text(
            isConnected
                ? "Conectado a: ${selectedDevice?.name}"
                : "Desconectado",
          ),
          subtitle: Text(
            isConnected ? "Escuchando al PIC..." : "Toque conectar abajo",
          ),
          trailing: Icon(
            isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: isConnected ? Colors.green : Colors.grey,
          ),
          tileColor: isConnected ? Colors.green[50] : Colors.grey[100],
        ),
        const Divider(),
        Expanded(
          child: FutureBuilder(
            future: FlutterBluetoothSerial.instance.getBondedDevices(),
            builder: (context, snapshot) {
              if (!snapshot.hasData)
                return const Center(child: CircularProgressIndicator());
              final devices = snapshot.data as List<BluetoothDevice>;

              if (devices.isEmpty) {
                return const Center(
                  child: Text(
                    "No hay dispositivos vinculados.\nVaya a ajustes de Bluetooth.",
                  ),
                );
              }

              return ListView.builder(
                itemCount: devices.length,
                itemBuilder: (context, index) {
                  final device = devices[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.devices),
                      title: Text(device.name ?? "Dispositivo Desconocido"),
                      subtitle: Text(device.address),
                      trailing: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              isConnected &&
                                  selectedDevice?.address == device.address
                              ? Colors.red
                              : Colors.indigo,
                          foregroundColor: Colors.white,
                        ),
                        child: Text(
                          isConnected &&
                                  selectedDevice?.address == device.address
                              ? "Desconectar"
                              : "Conectar",
                        ),
                        onPressed: () async {
                          if (isConnected) {
                            setState(() {
                              connection?.dispose();
                              isConnected = false;
                              connection = null;
                            });
                            return;
                          }

                          try {
                            BluetoothConnection connectionResult =
                                await BluetoothConnection.toAddress(
                                  device.address,
                                );

                            setState(() {
                              connection = connectionResult;
                              isConnected = true;
                              selectedDevice = device;
                            });

                            // ===============================================
                            //     EL LISTENER DEL PROTOCOLO DE CÉSAR
                            // ===============================================
                            connection!.input!
                                .listen((Uint8List data) {
                                  String incoming = utf8.decode(data).trim();
                                  debugPrint("PIC DICE: $incoming");

                                  // 1. PIC CONFIRMA CUOTA ('S')
                                  if (incoming.contains('S')) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            "✅ SISTEMA SINCRONIZADO: Deposite monedas.",
                                          ),
                                          backgroundColor: Colors.blue,
                                        ),
                                      );
                                    }
                                  }

                                  // 2. PIC CUENTA MONEDA ('$')
                                  if (incoming.contains('\$')) {
                                    if (mounted &&
                                        ticketEscaneado &&
                                        !pagoCompletado) {
                                      setState(() {
                                        saldoIngresado += 5;
                                      });
                                    }
                                  }

                                  // 3. PIC ABRE PLUMA ('P')
                                  if (incoming.contains('P')) {
                                    if (mounted) {
                                      setState(() {
                                        pagoCompletado = true;
                                        saldoIngresado =
                                            precioDetectado; // Ajuste visual
                                      });

                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            "✨ ¡PAGO COMPLETADO! Pluma Abierta.",
                                          ),
                                          backgroundColor: Colors.green,
                                          duration: Duration(seconds: 4),
                                        ),
                                      );
                                    }
                                  }
                                })
                                .onDone(() {
                                  if (mounted)
                                    setState(() {
                                      isConnected = false;
                                    });
                                });
                          } catch (e) {
                            debugPrint("Error conectando: $e");
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("Error: $e")),
                              );
                            }
                          }
                        },
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
