import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
//import 'package:web_socket_channel/io.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:video_player/video_player.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(SecurityCameraApp(camera: cameras.first));
}

class SecurityCameraApp extends StatelessWidget {
  final CameraDescription camera;

  const SecurityCameraApp({Key? key, required this.camera}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: CameraScreen(camera: camera),
    );
  }
}

class CameraScreen extends StatefulWidget {
  final CameraDescription camera;

  const CameraScreen({Key? key, required this.camera}) : super(key: key);

  @override
  _CameraScreenState createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  HttpServer? _server;
  List<WebSocket> _clients = [];
  String _ipAddress = '';
  int _port = 8080;
  bool _isRecording = false;
  List<String> _recordings = [];
  Timer? _recordingTimer;
  int _recordingDuration = 60; // Duración de cada grabación en segundos
  bool _isServerRunning = true; // Controla el estado del servidor

  // Variable para almacenar la calidad actual
  ResolutionPreset _currentResolution = ResolutionPreset.medium;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(widget.camera, _currentResolution);
    _initializeControllerFuture = _controller.initialize();
    _startServer();
    _getIpAddress();
    _loadRecordings();
  }

  Future<void> _getIpAddress() async {
    final info = NetworkInfo();
    final ipAddress = await info.getWifiIP();
    setState(() {
      _ipAddress = ipAddress ?? 'No se pudo obtener la IP';
    });
  }

  Future<void> _startServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      print('Servidor iniciado en $_ipAddress:$_port');
      _server!.listen((HttpRequest request) {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          WebSocketTransformer.upgrade(request).then((WebSocket ws) {
            _handleWebSocket(ws);
          });
        }
      });
      setState(() {
        _isServerRunning = true;
      });
    } catch (e) {
      print('Error al iniciar el servidor: $e');
    }
  }

  void _handleWebSocket(WebSocket ws) {
    print('Nuevo cliente conectado');
    _clients.add(ws);
    ws.listen(
      (message) {
        // Manejar mensajes del cliente si es necesario
      },
      onDone: () {
        print('Cliente desconectado');
        _clients.remove(ws);
      },
    );
  }

  // Función para mostrar el diálogo y cambiar la calidad
  Future<void> _showQualityDialog() async {
    final selectedQuality = await showDialog<ResolutionPreset>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Cambiar Calidad de Streaming'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: ResolutionPreset.values.map((quality) {
              return RadioListTile<ResolutionPreset>(
                title: Text(quality.toString().split('.').last),
                value: quality,
                groupValue: _currentResolution, // Usamos la variable local
                onChanged: (value) {
                  Navigator.of(context).pop(value);
                },
              );
            }).toList(),
          ),
        );
      },
    );

    if (selectedQuality != null && selectedQuality != _currentResolution) {
      setState(() {
        _currentResolution = selectedQuality;
        _controller = CameraController(widget.camera, _currentResolution);
        _initializeControllerFuture = _controller.initialize();
      });
    }
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    if (!_controller.value.isInitialized) {
      return;
    }
    final Directory extDir = await getApplicationDocumentsDirectory();
    final String dirPath = '${extDir.path}/SecurityCameraRecordings';
    await Directory(dirPath).create(recursive: true);
    //final String filePath = '$dirPath/${DateTime.now().millisecondsSinceEpoch}.mp4';
    try {
      await _controller.startVideoRecording();
      setState(() {
        _isRecording = true;
      });
      _recordingTimer = Timer.periodic(Duration(seconds: _recordingDuration), (timer) async {
        await _stopRecording();
        await _startRecording();
      });
    } catch (e) {
      print(e);
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) {
      return;
    }
    try {
      final XFile file = await _controller.stopVideoRecording();
      setState(() {
        _isRecording = false;
        _recordings.add(file.path);
      });
      _recordingTimer?.cancel();
    } catch (e) {
      print(e);
    }
  }

  Future<void> _loadRecordings() async {
    final Directory extDir = await getApplicationDocumentsDirectory();
    final String dirPath = '${extDir.path}/SecurityCameraRecordings';
    final Directory dir = Directory(dirPath);
    if (await dir.exists()) {
      final List<FileSystemEntity> entities = await dir.list().toList();
      setState(() {
        _recordings = entities
            .where((entity) => entity is File && path.extension(entity.path) == '.mp4')
            .map((entity) => entity.path)
            .toList();
      });
    }
  }

  // Función para alternar entre iniciar y detener el servidor
  void _toggleServer() {
    if (_isServerRunning) {
      _server?.close();
      setState(() {
        _isServerRunning = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Servidor detenido')),
      );
    } else {
      _startServer();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Servidor iniciado')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Cámara de Seguridad')),
      body: Stack(
        children: [
          // Cámara en el fondo
          FutureBuilder<void>(
            future: _initializeControllerFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.done) {
                return CameraPreview(_controller);
              } else {
                return Center(child: CircularProgressIndicator());
              }
            },
          ),
          // Barra superior con transparencia y dirección IP
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black.withOpacity(0.5), // Color semitransparente
              padding: EdgeInsets.all(5.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'IP del servidor: $_ipAddress:$_port',
                    style: TextStyle(color: Colors.white),
                  ),
                  IconButton(
                    icon: Icon(Icons.settings, color: Colors.white),
                    onPressed: _showQualityDialog, // Mostrar opciones de calidad
                  ),
                ],
              ),
            ),
          ),
          // Barra inferior con transparencia y botón de detener/iniciar servidor
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black.withOpacity(0.5), // Color semitransparente
              padding: EdgeInsets.all(5.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end, // Botón alineado a la derecha
                children: [
                  ElevatedButton.icon(
                    icon: Icon(_isServerRunning ? Icons.stop : Icons.play_arrow),
                    label: Text(_isServerRunning ? "Detener Servidor" : "Iniciar Servidor"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isServerRunning ? Colors.red : Colors.green, // Cambia el color según el estado
                    ),
                    onPressed: _toggleServer, // Alternar entre iniciar y detener el servidor
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            child: Icon(_isRecording ? Icons.stop : Icons.videocam),
            onPressed: _toggleRecording,
          ),
          SizedBox(width: 16),
          // Botón para la línea de tiempo
          FloatingActionButton(
            child: Icon(Icons.timeline),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => TimelineScreen(recordings: _recordings)),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    for (var client in _clients) {
      client.close();
    }
    _server?.close();
    _recordingTimer?.cancel();
    super.dispose();
  }
}


class TimelineScreen extends StatefulWidget {
  final List<String> recordings;

  const TimelineScreen({Key? key, required this.recordings}) : super(key: key);

  @override
  _TimelineScreenState createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  late List<String> _recordings;

  @override
  void initState() {
    super.initState();
    _recordings = List.from(widget.recordings);
  }

  Future<void> _renameRecording(BuildContext context, int index) async {
    final oldFilePath = _recordings[index];
    final TextEditingController controller = TextEditingController();
    String? newFileName;

    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Renombrar Grabación'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: "Nuevo nombre de archivo"),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () {
                newFileName = controller.text;
                Navigator.of(context).pop();
              },
              child: const Text('Aceptar'),
            ),
          ],
        );
      },
    );

    if (newFileName != null && newFileName!.isNotEmpty) {
      final newFilePath = path.join(path.dirname(oldFilePath), '$newFileName.mp4');
      final oldFile = File(oldFilePath);
      await oldFile.rename(newFilePath);
      
      setState(() {
        _recordings[index] = newFilePath; // Actualizar la lista con el nuevo nombre
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Grabación renombrada a $newFileName.mp4')),
      );
    }
  }

  Future<void> _deleteRecording(BuildContext context, int index) async {
    final filePath = _recordings[index];
    final file = File(filePath);

    final bool confirm = await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Eliminar Grabación'),
          content: const Text('¿Estás seguro de que deseas eliminar esta grabación?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(false); // Cancelar
              },
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(true); // Confirmar
              },
              child: const Text('Eliminar'),
            ),
          ],
        );
      },
    );

    if (confirm) {
      await file.delete();  // Eliminar el archivo

      setState(() {
        _recordings.removeAt(index);  // Eliminar de la lista
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: const Text('Grabación eliminada')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Línea de Tiempo')),
      body: _recordings.isEmpty
          ? Center(child: const Text('No hay grabaciones disponibles'))
          : ListView.builder(
              itemCount: _recordings.length,
              itemBuilder: (context, index) {
                final recording = _recordings[index];
                return ListTile(
                  title: Text('Grabación ${index + 1}'),
                  subtitle: Text(path.basename(recording)),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => VideoPlayerScreen(videoPath: recording),
                      ),
                    );
                  },
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => _renameRecording(context, index),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () => _deleteRecording(context, index),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class VideoPlayerScreen extends StatefulWidget {
  final String videoPath;

  const VideoPlayerScreen({Key? key, required this.videoPath}) : super(key: key);

  @override
  _VideoPlayerScreenState createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) {
        setState(() {});
      });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reproductor de Video')),
      body: Center(
        child: _controller.value.isInitialized
            ? AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              )
            : const CircularProgressIndicator(),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() {
            _controller.value.isPlaying
                ? _controller.pause()
                : _controller.play();
          });
        },
        child: Icon(
          _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
        ),
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
    _controller.dispose();
  }
}