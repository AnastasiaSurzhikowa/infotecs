import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

void main() {
  runApp(const MultiServerClientApp());
}

class MultiServerClientApp extends StatelessWidget {
  const MultiServerClientApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Multi-Server Client',
      debugShowCheckedModeBanner: false,
      home: const ClientHomePage(),
    );
  }
}

class ClientHomePage extends StatefulWidget {
  const ClientHomePage({super.key});
  @override
  State<ClientHomePage> createState() => _ClientHomePageState();
}

class _ClientHomePageState extends State<ClientHomePage> {
  // UI controllers
  final TextEditingController _hostCtrl = TextEditingController(text: '127.0.0.1');
  final TextEditingController _portCtrl = TextEditingController(text: '3000');
  final TextEditingController _sendCtrl = TextEditingController();

  // connection & state
  Socket? _socket;
  StreamSubscription<String>? _sub;
  bool _connecting = false;
  bool _autoReconnect = true;
  Timer? _reconnectTimer;

  // log
  final List<String> _log = [];

  // presets
  final Map<String, Map<String, String>> _presets = {
    'C++ server (127.0.0.1:3000)': {'host': '127.0.0.1', 'port': '3000'},
    'Dart server (127.0.0.1:4041)': {'host': '127.0.0.1', 'port': '4041'},
    'Custom': {'host': '', 'port': ''}
  };
  String _selectedPreset = 'C++ server (127.0.0.1:3000)';

  @override
  void initState() {
    super.initState();
    _applyPreset(_selectedPreset);
  }

  @override
  void dispose() {
    _cancelReconnectTimer();
    _sub?.cancel();
    _socket?.destroy();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _sendCtrl.dispose();
    super.dispose();
  }

  // --- helpers ---
  void _addLog(String s) {
    if (!mounted) return;
    setState(() {
      final stamp = DateTime.now().toIso8601String().substring(11, 19);
      _log.add('[$stamp] $s');
      if (_log.length > 1500) _log.removeRange(0, _log.length - 1500);
    });
  }

  void _applyPreset(String name) {
    final p = _presets[name]!;
    if (p['host']!.isNotEmpty) _hostCtrl.text = p['host']!;
    if (p['port']!.isNotEmpty) _portCtrl.text = p['port']!;
  }

  // --- connect / disconnect / reconnect logic ---
  Future<void> _connect() async {
    if (_connecting || _socket != null) return;
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    if (host.isEmpty || port == null) {
      _addLog('Ошибка: неверный host или порт');
      return;
    }

    _connecting = true;
    _addLog('Попытка подключения к $host:$port ...');

    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      // cancel any pending reconnect attempts (we connected)
      _cancelReconnectTimer();

      _socket = s;
      _addLog('Подключено к ${s.remoteAddress.address}:${s.remotePort}');

      final stream = utf8.decoder.bind(s).transform(const LineSplitter());
      _sub = stream.listen((line) {
        final trimmed = line.trim();
        if (trimmed.toUpperCase().startsWith('SUM:')) {
          final val = trimmed.substring(4).trim();
          _addLog('Сервер (сумма): $val');
        } else if (trimmed.toUpperCase().startsWith('ERROR:')) {
          final err = trimmed.substring(6).trim();
          _addLog('Сервер (ошибка): $err');
        } else {
          _addLog('Сервер: $trimmed');
        }
      }, onError: (e) {
        _addLog('Ошибка (stream): $e');
        _handleDisconnect(wantReconnect: _autoReconnect);
      }, onDone: () {
        _addLog('Соединение закрыто сервером');
        _handleDisconnect(wantReconnect: _autoReconnect);
      });

      _connecting = false;
    } catch (e) {
      _connecting = false;
      _addLog('Не удалось подключиться: $e');
      if (_autoReconnect) _scheduleReconnect();
    }
  }

  void _disconnect({bool manual = true}) {
    _cancelReconnectTimer();
    _sub?.cancel();
    _sub = null;
    if (_socket != null) {
      try {
        _socket!.destroy();
      } catch (_) {}
      _socket = null;
      _addLog(manual ? 'Отключено пользователем' : 'Отключено (cleanup)');
    }
    _connecting = false;
  }

  void _handleDisconnect({bool wantReconnect = true}) {
    _sub?.cancel();
    _sub = null;
    if (_socket != null) {
      try {
        _socket!.destroy();
      } catch (_) {}
      _socket = null;
    }
    _connecting = false;
    if (wantReconnect && _autoReconnect) {
      _addLog('Попытка переподключения через 3 сек...');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _cancelReconnectTimer();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (_socket == null && !_connecting) {
        _connect();
      }
    });
  }

  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  // --- UI actions ---
  void _onPresetChanged(String? newPreset) {
    if (newPreset == null) return;
    setState(() {
      _selectedPreset = newPreset;
      _applyPreset(newPreset);
      _disconnect(manual: true);
      Future.delayed(const Duration(milliseconds: 150), () {
        _connect();
      });
    });
  }

  void _onConnectPressed() {
    if (_socket == null) {
      _connect();
    } else {
      _disconnect();
    }
  }

  void _onSendPressed() {
    final text = _sendCtrl.text.trim();
    if (text.isEmpty) return;
    if (_socket == null) {
      _addLog('Ошибка: нет подключения, сообщение не отправлено');
      return;
    }

    // Если выбран C++ preset — валидируем (только 1..64 цифр)
    final isCxxPreset = _selectedPreset.toLowerCase().startsWith('c++');
    if (isCxxPreset) {
      final ok = RegExp(r'^\d{1,64}$').hasMatch(text);
      if (!ok) {
        _addLog('Ошибка: для C++ сервера допускаются только 1..64 цифр');
        return;
      }
    }

    try {
      // send with newline so server using LineSplitter gets a full line
      _socket!.write(text + '\n');
      _addLog('Я: $text');
      _sendCtrl.clear();
    } catch (e) {
      _addLog('Ошибка отправки: $e');
      _handleDisconnect(wantReconnect: _autoReconnect);
    }
  }

  // --- Build UI ---
  @override
  Widget build(BuildContext context) {
    final connected = _socket != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Multi-Server Client')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _selectedPreset,
                items: _presets.keys
                    .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                    .toList(),
                onChanged: _onPresetChanged,
                decoration: const InputDecoration(labelText: 'Preset'),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () {
                // apply current preset to fields (manual)
                _applyPreset(_selectedPreset);
              },
              child: const Text('Apply'),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _hostCtrl,
                decoration: const InputDecoration(labelText: 'Host'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 120,
              child: TextField(
                controller: _portCtrl,
                decoration: const InputDecoration(labelText: 'Port'),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _onConnectPressed,
              child: Text(connected ? 'Disconnect' : 'Connect'),
            ),
          ]),
          Row(
            children: [
              Switch(
                value: _autoReconnect,
                onChanged: (v) {
                  setState(() => _autoReconnect = v);
                  if (v && _socket == null && !_connecting) _scheduleReconnect();
                  if (!v) _cancelReconnectTimer();
                },
              ),
              const Text('Auto-reconnect'),
              const SizedBox(width: 12),
              Text('Status: ${_socket != null ? 'Connected' : (_connecting ? 'Connecting...' : 'Disconnected')}'),
            ],
          ),
          const SizedBox(height: 8),
          // messages log
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade400), borderRadius: BorderRadius.circular(8)),
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder: (context, i) {
                  final line = _log[i];
                  Color color = Colors.black;
                  if (line.contains('Ошибка') || line.contains('ERROR')) color = Colors.red;
                  if (line.contains('Сервер (сумма)') || line.contains('Я:')) color = Colors.blue;
                  if (line.contains('Подключено')) color = Colors.green;
                  return Text(line, style: TextStyle(color: color));
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _sendCtrl,
                decoration: const InputDecoration(hintText: 'Message to send'),
                onSubmitted: (_) => _onSendPressed(),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: _onSendPressed, child: const Text('Send')),
          ]),
        ]),
      ),
    );
  }
}
