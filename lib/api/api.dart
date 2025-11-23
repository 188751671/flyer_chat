import 'dart:async';

import 'package:cross_cache/cross_cache.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flyer_chat_image_message/flyer_chat_image_message.dart';
import 'package:flyer_chat_text_message/flyer_chat_text_message.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../create_message.dart';
import '../widgets/composer_action_bar.dart';
import 'api_service.dart';
import 'connection_status.dart';
import 'upload_file.dart';
import 'websocket_service.dart';

const baseUrl = 'https://whatever.diamanthq.dev';
const host = 'whatever.diamanthq.dev';

class Api extends StatefulWidget {
  final UserID currentUserId;
  final String chatId;
  final List<Message> initialMessages;
  final Dio dio;

  const Api({
    super.key,
    required this.currentUserId,
    required this.chatId,
    required this.initialMessages,
    required this.dio,
  });

  @override
  ApiState createState() => ApiState();
}

class ApiState extends State<Api> {
  final _crossCache = CrossCache(); // 用于缓存图片等二进制数据
  final _uuid = const Uuid();

  final users = const {'john': User(id: 'john'), 'jane': User(id: 'jane')};

  // 既然已经有了 api_service里的dio  为什么还要websocket service？

  // Dio 走 HTTP/REST，用于给 服务端 发送请求，例如 发送 message、删除 message、标记已读等
  // WebSocket 是持续长连接，用于接收 服务端的推送，例如接收服务器的 messages、user在线状态、正在输入等

  late final ApiService _apiService;

  late final ChatWebSocketService _webSocketService;
  late final StreamSubscription<WebSocketEvent> _webSocketSubscription;

  // ChatController 持有两个重要字段 _messages 和一个 Stream<ChatOperation> 的 stream
  // 前者记录所有消息,  后者记录 消息的增删改等操作, 而UI会监听这个 stream 来更新显示
  late final ChatController _chatController;

  @override
  void initState() {
    super.initState();

    // 初始化 ChatController, 并用 initialMessages 预填充
    _chatController = InMemoryChatController(
      messages: widget.initialMessages,
    ); // widget. 就是上面 本类的 常量

    _apiService = ApiService(baseUrl: baseUrl, chatId: widget.chatId, dio: widget.dio);

    _webSocketService = ChatWebSocketService(
      host: host,
      chatId: widget.chatId,
      authorId: widget.currentUserId,
    );

    // 连接到服务器 并监听 服务器发过来的事件. 监听器赋值给 _webSocketSubscription
    _webSocketSubscription = _webSocketService.connect().listen((event) {
      if (!mounted) return;

      switch (event.type) {
        case WebSocketEventType.newMessage:
          _chatController.insertMessage(event.message!);
          break;
        case WebSocketEventType.deleteMessage:
          _chatController.removeMessage(event.message!);
          break;
        case WebSocketEventType.flush:
          _chatController.setMessages([]);
          break;
        case WebSocketEventType.error:
          _showInfo('Error: ${event.error}');
          break;
        case WebSocketEventType.unknown:
          break;
      }
    });
  }

  @override
  void dispose() {
    _webSocketSubscription.cancel();
    _webSocketService.dispose();
    _chatController.dispose();
    _crossCache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Api')),
      body: Stack(
        children: [
          Chat(
            // Builders 是一个 抽象类的实现, 里面包含了 多个 回调函数
            // typedef TextStreamMessageBuilder =
            // Widget Function(
            //   BuildContext,
            //   TextStreamMessage,
            //   int index, {
            //   required bool isSentByMe,
            //   MessageGroupStatus? groupStatus,
            // });

            // Builders 用于 定制化 各种消息类型的显示方式
            // 例如 textMessageBuilder 就是 定制化 text message 的显示
            // Builders 里 还可以 定制 composer (消息输入栏) 的显示
            builders: Builders(
              textMessageBuilder:
                  (
                    context,
                    message,
                    index, {
                    required bool isSentByMe,
                    MessageGroupStatus? groupStatus,
                  }) => FlyerChatTextMessage(message: message, index: index),
              imageMessageBuilder:
                  (
                    context,
                    message,
                    index, {
                    required bool isSentByMe,
                    MessageGroupStatus? groupStatus,
                  }) => FlyerChatImageMessage(message: message, index: index),
              composerBuilder: (context) => Composer(
                topWidget: ComposerActionBar(
                  buttons: [
                    ComposerActionButton(
                      icon: Icons.shuffle,
                      title: 'Send random',
                      onPressed: () => _addItem(null),
                    ),
                    ComposerActionButton(
                      icon: Icons.delete_sweep,
                      title: 'Clear all',
                      onPressed: () async {
                        try {
                          await _apiService.flush();
                          if (mounted) {
                            await _chatController.setMessages([]);
                            await _showInfo('All messages cleared');
                          }
                        } catch (error) {
                          await _showInfo('Error: $error');
                        }
                      },
                      destructive: true,
                    ),
                  ],
                ),
              ),
            ),

            // 创建 Chat widget 会传入 chatController. 因此Chat widget(UI) 可以订阅chatController的消息流 来更新UI
            chatController: _chatController,
            crossCache: _crossCache,
            currentUserId: widget.currentUserId,
            onAttachmentTap: _handleAttachmentTap,
            onMessageSend: _addItem,
            onMessageTap: _removeItem,
            resolveUser: (id) => Future.value(users[id]),
            theme: ChatTheme.fromThemeData(theme),
          ),

          // 绿色dot, 显示 websocket连接状态 (也就是跟服务器的连接状态  能不能接收到 消息)
          Positioned(
            top: 16,
            left: 16,
            child: ConnectionStatus(webSocketService: _webSocketService),
          ),
        ],
      ),
    );
  }

  void _addItem(String? text) async {
    final message = await createMessage(widget.currentUserId, widget.dio, text: text);
    final originalMetadata = message.metadata;

    if (mounted) {
      await _chatController.insertMessage(
        // copyWith create a new memory instance of Message with some fields changed
        // Map<String, dynamic>? originalMetadata
        // ... is the spread operator; it expands the entries of a map/list into a new literal.
        // {'sending': true} adds/overrides a metadata entry marking the message as “sending”.
        // So overall it clones the message
        // and merges existing metadata with {'sending': true} for UI/state tracking.
        message.copyWith(metadata: {...?originalMetadata, 'sending': true}),
      );
    }

    try {
      final response = await _apiService.send(message); // web req to send message

      if (mounted) {
        // firstWhere scans the list and returns the first element that satisfies the predicate.
        // Here it looks for a message in _chatController.messages whose id matches message.id.
        // If none is found, orElse returns the passed-in message instead,
        // so currentMessage is either the existing list item with that id or the passed-in message

        // Make sure to get the updated message
        // (width and height might have been set by the image message widget)
        final currentMessage = _chatController.messages.firstWhere(
          (element) => element.id == message.id,
          orElse: () => message,
        );

        // Create a new Message instance with updated fields from the server response
        final nextMessage = currentMessage.copyWith(
          id: response['id'],
          createdAt: null,
          // response['ts'] is server-assigned createdAt timestamp in milliseconds since epoch
          // can be used to order messages;
          // it converts that to a DateTime object in UTC
          sentAt: DateTime.fromMillisecondsSinceEpoch(response['ts'], isUtc: true),
          metadata: originalMetadata,
        );
        await _chatController.updateMessage(currentMessage, nextMessage);

        // 整个流程是  先_chatController.insertMessage 让UI显示“正在发送”状态的消息
        // 然后用 api_service.send()  web req 发给服务器
        // 然后等服务器返回结果后 再用 _chatController.updateMessage 更新 消息的ID和 时间戳等信息
      }
    } catch (error) {
      debugPrint('Error sending message: $error');
    }
  }

  void _handleAttachmentTap() async {
    final picker = ImagePicker();

    final image = await picker.pickImage(source: ImageSource.gallery);

    if (image == null) return;

    final bytes = await image.readAsBytes();
    // Saves image to persistent cache using image.path as key
    await _crossCache.set(image.path, bytes);

    final id = _uuid.v4();

    final imageMessage = ImageMessage(
      id: id,
      authorId: widget.currentUserId,
      createdAt: DateTime.now().toUtc(),
      source: image.path,
    );

    // Insert message to UI before uploading
    await _chatController.insertMessage(imageMessage);

    try {
      final response = await uploadFile(image.path, bytes, id, _chatController);

      if (mounted) {
        final blobId = response['blob_id'];

        // Make sure to get the updated message
        // (width and height might have been set by the image message widget)
        final currentMessage =
            _chatController.messages.firstWhere(
                  (element) => element.id == id,
                  orElse: () => imageMessage,
                )
                as ImageMessage;
        final originalMetadata = currentMessage.metadata;
        final nextMessage = currentMessage.copyWith(
          source: 'https://whatever.diamanthq.dev/blob/$blobId',
        );
        // Saves the same image to persistent cache using the new url as key
        // Alternatively, you could use updateKey to update the same content with a different key
        await _crossCache.set(nextMessage.source, bytes);
        await _chatController.updateMessage(
          currentMessage,
          nextMessage.copyWith(metadata: {...?originalMetadata, 'sending': true}),
        );

        final newMessageResponse = await _apiService.send(nextMessage);

        if (mounted) {
          // Make sure to get the updated message
          // (width and height might have been set by the image message widget)
          final currentMessage2 = _chatController.messages.firstWhere(
            (element) => element.id == nextMessage.id,
            orElse: () => nextMessage,
          );
          final nextMessage2 = currentMessage2.copyWith(
            id: newMessageResponse['id'],
            createdAt: null,
            sentAt: DateTime.fromMillisecondsSinceEpoch(
              newMessageResponse['ts'],
              isUtc: true,
            ),
            metadata: originalMetadata,
          );
          await _chatController.updateMessage(currentMessage2, nextMessage2);
        }
      }
    } catch (error) {
      debugPrint('Error uploading/sending image message: $error');
    }
  }

  void _removeItem(
    BuildContext context,
    Message item, {
    int? index,
    TapUpDetails? details,
  }) async {
    // 可能会出现 _chatController UI移除msg成功后, 但是 服务器删除失败
    // 可以改成: call the API first then remove locally on success
    await _chatController.removeMessage(item);

    try {
      await _apiService.delete(item);
    } catch (error) {
      debugPrint(error.toString());
    }
  }

  Future<void> _showInfo(String message) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Info'),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }
}
