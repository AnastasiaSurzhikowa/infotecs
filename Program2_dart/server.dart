import 'dart:io';
import 'dart:convert';

void main() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 4041);
  print('Dart server running on ${server.address.address}:${server.port}');

  await for (var socket in server) {
    print('Client connected: ${socket.remoteAddress.address}:${socket.remotePort}');

    socket.listen(
      (List<int> data) {
        final message = utf8.decode(data).trim();
        print('Received: "$message"');

        String reply;
        if (message.length <= 2) {
          reply = 'Ошибка: слишком короткое значение (длина ${message.length})';
        } else {
          final value = int.tryParse(message);
          if (value == null) {
            reply = 'Ошибка: нечисловое значение';
          } else if (value % 32 != 0) {
            reply = 'Ошибка: значение не кратно 32';
          } else {
            reply = 'ОК: принято значение $value (длина ${message.length})';
          }
        }

        socket.write('$reply\n');
        print('Sent: $reply');
      },
      onDone: () {
        print('Client disconnected: ${socket.remoteAddress.address}:${socket.remotePort}');
      },
      onError: (error) {
        print('Error: $error');
      },
    );
  }
}

