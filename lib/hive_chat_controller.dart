import 'dart:async';

import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:hive_ce/hive.dart';

// A class can only extend one parent.
// But sometimes you want to add behaviors from multiple places.
// MixIn is a piece of reusable code that a class can “mix in”
// to get extra methods or properties without extending a new parent class.
class HiveChatController
    with UploadProgressMixin, ScrollToMessageMixin
    implements ChatController {
  final _box = Hive.box('chat'); // 'chat' is like a table name in DB
  final _operationsController = StreamController<ChatOperation>.broadcast();

  // messages都是保存在 Hive box, persistence里的. 每次读取msgs时 不可能每次都去 磁盘读取
  // 所以 每次读取磁盘后  缓存一份在内存里_cachedMessages,下次读取时 优先从这里读
  // 每当messages数据需要 变更时, 先修改 Hive box里的, 然后更新_cachedMessages
  List<Message>? _cachedMessages;

  /// Invalidates the cached messages list
  void _invalidateCache() {
    _cachedMessages = null;
  }

  @override
  List<Message> get messages {
    if (_cachedMessages != null) {
      return _cachedMessages!;
    }

    _cachedMessages =
        _box.values.map((json) => Message.fromJson(_convertMap(json))).toList()..sort(
          (a, b) => (a.createdAt?.millisecondsSinceEpoch ?? 0).compareTo(
            b.createdAt?.millisecondsSinceEpoch ?? 0,
          ),
        );

    return _cachedMessages!;
  }

  @override
  Stream<ChatOperation> get operationsStream => _operationsController.stream;

  @override
  Future<void> insertMessage(Message message, {int? index, bool animated = true}) async {
    if (_box.containsKey(message.id)) return;

    // Index is ignored because Hive does not maintain order
    // FlyerCore 的Message类 已经写好了 对于各种类型msg的 fromJson 和 toJson 方法
    await _box.put(message.id, message.toJson());
    _invalidateCache();
    _operationsController.add(
      // insert第二参数是 插入的index, _box.length-1 也就是尾部插入
      ChatOperation.insert(message, _box.length - 1, animated: animated),
    );
  }

  @override
  Future<void> removeMessage(Message message, {bool animated = true}) async {
    // messages 是一个方法名(getter方法) ,返回 排序后的消息列表  List<Message> get messages { ... }
    final sortedMessages = List.from(messages);
    final index = sortedMessages.indexWhere((m) => m.id == message.id);

    if (index != -1) {
      final messageToRemove = sortedMessages[index];
      // box里 key是 msg.id, value是 msg.toJson()
      await _box.delete(messageToRemove.id);
      _invalidateCache();
      _operationsController.add(
        // 而在 ChatOperation stream里, 用index 来删除
        ChatOperation.remove(messageToRemove, index, animated: animated),
      );
    }
  }

  @override
  Future<void> updateMessage(Message oldMessage, Message newMessage) async {
    final sortedMessages = List.from(messages);
    final index = sortedMessages.indexWhere((m) => m.id == oldMessage.id);

    if (index != -1) {
      final actualOldMessage = sortedMessages[index];

      if (actualOldMessage == newMessage) {
        return;
      }

      await _box.put(actualOldMessage.id, newMessage.toJson());
      _invalidateCache();
      _operationsController.add(
        ChatOperation.update(actualOldMessage, newMessage, index),
      );
    }
  }

  // 用来 设置整个messages list 例如 1.被“一键清空聊天”调用  2.初始化时 可以在聊天记录 开头放入一点 系统tips消息
  @override
  Future<void> setMessages(List<Message> messages, {bool animated = true}) async {
    await _box.clear();
    // 如果传入的 messages 为空, 直接清空缓存和发出 set 操作
    if (messages.isEmpty) {
      _invalidateCache();
      _operationsController.add(ChatOperation.set([], animated: false));
      return;
      // 否则 批量插入所有消息
    } else {
      await _box.putAll(
        messages
            .map((message) => {message.id: message.toJson()})
            .toList()
            .reduce((acc, map) => {...acc, ...map}),
      );
      _invalidateCache();
      _operationsController.add(ChatOperation.set(messages, animated: animated));
    }
  }

  @override
  Future<void> insertAllMessages(
    List<Message> messages, {
    int? index,
    bool animated = true,
  }) async {
    if (messages.isEmpty) return;

    // Index is ignored because Hive does not maintain order
    final originalLength = _box.length;
    await _box.putAll(
      messages
          .map((message) => {message.id: message.toJson()})
          .toList()
          .reduce((acc, map) => {...acc, ...map}),
    );
    _invalidateCache();
    _operationsController.add(
      ChatOperation.insertAll(messages, originalLength, animated: animated),
    );
  }

  @override
  void dispose() {
    _operationsController.close();
    disposeUploadProgress();
    disposeScrollMethods();
  }
}

/// Recursively converts a map with dynamic keys and values to a map with String keys.
/// It's optimized to avoid creating new maps if no conversion is needed.
Map<String, dynamic> _convertMap(dynamic map) {
  if (map is Map<String, dynamic>) {
    Map<String, dynamic>? newMap;
    for (final entry in map.entries) {
      final value = entry.value;
      if (value is Map) {
        final convertedValue = _convertMap(value);
        if (convertedValue != value) {
          newMap ??= Map<String, dynamic>.of(map);
          newMap[entry.key] = convertedValue;
        }
      }
    }
    return newMap ?? map;
  }

  final convertedMap = Map<String, dynamic>.from(map as Map);

  for (final key in convertedMap.keys) {
    final value = convertedMap[key];
    if (value is Map) {
      convertedMap[key] = _convertMap(value);
    }
  }

  return convertedMap;
}
