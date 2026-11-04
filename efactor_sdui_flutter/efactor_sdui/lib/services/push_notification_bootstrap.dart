import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'call_lifecycle_tracker.dart';
import 'circle_connect_device_key_store.dart';
import 'grid_chat_message_notification.dart';
import 'grid_unread_counts_service.dart';
import 'incoming_call_service.dart';
import 'json_http.dart';
import 'ongoing_call_service.dart';
import '../auth_sdui/auth_secure_storage.dart';
import '../grid_sdui/grid_in_app_webview_page.dart';
import '../grid_sdui/grid_live_location_service.dart';

/// Call notification channel configured with system default ringtone and USAGE_NOTIFICATION_RINGTONE.
const AndroidNotificationChannel kCallsChannel = AndroidNotificationChannel(
  'grid_calls_v4',
  'Incoming calls',
  description: 'Alerts for incoming Circle Connect calls',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  enableLights: true,
  audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
);

/// Message notification channel configured with system message sound.
const AndroidNotificationChannel kMessagesChannel = AndroidNotificationChannel(
  'grid_messages_v4',
  'Messages',
  description: 'Circle Connect chat message notifications',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

/// Notification channel for Professional Space (GRID) social activity, posts, comments, connections.
const AndroidNotificationChannel kGridActivityChannel = AndroidNotificationChannel(
  'grid_activity',
  'Professional Space',
  description: 'Notifications for posts, comments, connections, and activity in Professional Space',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
);

/// Circle Connect Notification Channel Groups
const AndroidNotificationChannelGroup kGroupGridChatMessages =
    AndroidNotificationChannelGroup(
  'grid_chat_messages',
  'GRID Chat messages',
  description: 'Messages, calls, and chat alerts from Circle Connect',
);

const AndroidNotificationChannelGroup kGroupGridChatActivity =
    AndroidNotificationChannelGroup(
  'grid_chat_activity',
  'GRID Chat activity',
  description: 'Activity, mentions, reactions, and social updates from Circle Connect',
);

/// Group 1: GRID Chat messages
const AndroidNotificationChannel kChannelMessages = AndroidNotificationChannel(
  'messages',
  'Messages',
  groupId: 'grid_chat_messages',
  description: 'Circle Connect direct chat messages',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

const AndroidNotificationChannel kChannelGroupMessages =
    AndroidNotificationChannel(
  'group_messages',
  'Group messages',
  groupId: 'grid_chat_messages',
  description: 'Circle Connect group chat messages',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

const AndroidNotificationChannel kChannelCalls = AndroidNotificationChannel(
  'calls',
  'Calls',
  groupId: 'grid_chat_messages',
  description: 'Circle Connect incoming voice and video calls',
  importance: Importance.max,
  audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

const AndroidNotificationChannel kChannelMissedCalls =
    AndroidNotificationChannel(
  'missed_calls',
  'Missed calls',
  groupId: 'grid_chat_messages',
  description: 'Circle Connect missed call notifications',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

/// Group 2: GRID Chat activity
const AndroidNotificationChannel kChannelMentions = AndroidNotificationChannel(
  'mentions',
  'Mentions',
  groupId: 'grid_chat_activity',
  description: 'Mentions in moments, comments, and posts',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

const AndroidNotificationChannel kChannelComments = AndroidNotificationChannel(
  'comments',
  'Comments',
  groupId: 'grid_chat_activity',
  description: 'Comments and replies on your moments and posts',
  importance: Importance.defaultImportance,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

const AndroidNotificationChannel kChannelLikes = AndroidNotificationChannel(
  'likes',
  'Likes & reactions',
  groupId: 'grid_chat_activity',
  description: 'Likes and reactions on your moments and messages',
  importance: Importance.defaultImportance,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

const AndroidNotificationChannel kChannelLive = AndroidNotificationChannel(
  'live',
  'Live videos',
  groupId: 'grid_chat_activity',
  description: 'Live video broadcasts from people you follow',
  importance: Importance.defaultImportance,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

const AndroidNotificationChannel kChannelChannels = AndroidNotificationChannel(
  'channels',
  'Channel posts & followers',
  groupId: 'grid_chat_activity',
  description: 'Posts and follower updates from subscribed channels',
  importance: Importance.defaultImportance,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

const AndroidNotificationChannel kChannelGroups = AndroidNotificationChannel(
  'groups',
  'Groups (added / admin)',
  groupId: 'grid_chat_activity',
  description: 'Group additions, admin alerts, and group invites',
  importance: Importance.defaultImportance,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

const AndroidNotificationChannel kChannelLocation = AndroidNotificationChannel(
  'location',
  'Live location',
  groupId: 'grid_chat_activity',
  description: 'Live location sharing updates from contacts',
  importance: Importance.defaultImportance,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

const AndroidNotificationChannel kChannelPolls = AndroidNotificationChannel(
  'polls',
  'Polls',
  groupId: 'grid_chat_activity',
  description: 'Poll alerts and voting results',
  importance: Importance.defaultImportance,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

const AndroidNotificationChannel kChannelContacts = AndroidNotificationChannel(
  'contacts',
  'Contacts joined',
  groupId: 'grid_chat_activity',
  description: 'Alerts when your phone contacts join Circle Connect',
  importance: Importance.defaultImportance,
  playSound: true,
  enableVibration: true,
  enableLights: true,
);

/// Map of all Circle Connect channel IDs to their definitions.
const Map<String, AndroidNotificationChannel> kCircleConnectChannels = {
  'messages': kChannelMessages,
  'group_messages': kChannelGroupMessages,
  'calls': kChannelCalls,
  'missed_calls': kChannelMissedCalls,
  'mentions': kChannelMentions,
  'comments': kChannelComments,
  'likes': kChannelLikes,
  'live': kChannelLive,
  'channels': kChannelChannels,
  'groups': kChannelGroups,
  'location': kChannelLocation,
  'polls': kChannelPolls,
  'contacts': kChannelContacts,
};

/// Resolves the effective Android notification channel id from push data key `channel`.
String resolveCircleConnectChannelId(String? rawChannel, {String fallback = 'mentions'}) {
  final clean = rawChannel?.trim().toLowerCase();
  if (clean == null || clean.isEmpty) return fallback;
  if (clean == 'calls') return PushNotificationBootstrap.activeCallsChannelId;
  if (clean == 'messages') return PushNotificationBootstrap.activeMessagesChannelId;
  if (kCircleConnectChannels.containsKey(clean)) return clean;
  return fallback;
}

/// Safely validates that a target URL belongs to the efactor.tech domain.
bool isSafeEfactorUrl(String url) {
  final clean = url.trim();
  if (clean.isEmpty) return false;
  final uri = Uri.tryParse(clean);
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  return host == 'efactor.tech' || host.endsWith('.efactor.tech');
}

/// Darwin notification categories providing interactive action buttons on iOS
/// (Answer/Decline on calls, inline text Reply + Mark as read on messages, and Stop on live location).
List<DarwinNotificationCategory> get kDarwinNotificationCategories =>
    <DarwinNotificationCategory>[
      DarwinNotificationCategory(
        'calls_category',
        actions: <DarwinNotificationAction>[
          DarwinNotificationAction.plain(
            'decline',
            'Decline',
            options: <DarwinNotificationActionOption>{
              DarwinNotificationActionOption.destructive,
            },
          ),
          DarwinNotificationAction.plain(
            'answer',
            'Answer',
            options: <DarwinNotificationActionOption>{
              DarwinNotificationActionOption.foreground,
            },
          ),
        ],
        options: <DarwinNotificationCategoryOption>{
          DarwinNotificationCategoryOption.hiddenPreviewShowTitle,
        },
      ),
      DarwinNotificationCategory(
        'messages_category',
        actions: <DarwinNotificationAction>[
          DarwinNotificationAction.text(
            'reply',
            'Reply',
            buttonTitle: 'Send',
            placeholder: 'Type a reply...',
          ),
          DarwinNotificationAction.plain(
            'mark_as_read',
            'Mark as read',
          ),
          DarwinNotificationAction.plain(
            'mute',
            'Mute',
          ),
        ],
        options: <DarwinNotificationCategoryOption>{
          DarwinNotificationCategoryOption.hiddenPreviewShowTitle,
        },
      ),
      const DarwinNotificationCategory(
        'messages_locked_category',
        actions: <DarwinNotificationAction>[],
        options: <DarwinNotificationCategoryOption>{
          DarwinNotificationCategoryOption.hiddenPreviewShowTitle,
        },
      ),
      DarwinNotificationCategory(
        'missed_calls_category',
        actions: <DarwinNotificationAction>[
          DarwinNotificationAction.plain(
            'callback',
            'Call back',
            options: <DarwinNotificationActionOption>{
              DarwinNotificationActionOption.foreground,
            },
          ),
          DarwinNotificationAction.plain(
            'message',
            'Message',
            options: <DarwinNotificationActionOption>{
              DarwinNotificationActionOption.foreground,
            },
          ),
        ],
      ),
      DarwinNotificationCategory(
        'live_location_category',
        actions: <DarwinNotificationAction>[
          DarwinNotificationAction.plain(
            'stop_live_location',
            'Stop Sharing',
            options: <DarwinNotificationActionOption>{
              DarwinNotificationActionOption.destructive,
            },
          ),
        ],
      ),
    ];

/// Background notification response handler (runs in background isolate).
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) async {
  WidgetsFlutterBinding.ensureInitialized();
  final actionId = response.actionId ?? '';
  if (actionId == 'stop_live_location') {
    await GridLiveLocationService.instance.stopAll(postStop: true);
    return;
  }

  final payload = response.payload;
  if (payload == null || payload.isEmpty) return;

  try {
    final data = jsonDecode(payload) as Map<String, dynamic>;
    final actionId = response.actionId ?? '';

    if (actionId == 'decline') {
      final call = IncomingCallData.fromJson(data);
      if (call.callId.isNotEmpty) {
        await CallLifecycleTracker.markCallFinished(call.callId);
      }
      await IncomingCallService.instance.declineCall(call);
    } else if (actionId == 'answer') {
      final call = IncomingCallData.fromJson(data);
      if (call.callId.isNotEmpty) {
        await CallLifecycleTracker.markCallFinished(call.callId);
      }
    } else if (actionId == 'mark_as_read') {
      await handleMarkAsReadFromNotification(data);
      final convId = (data['conversation_id'] ?? data['conversationId'] ?? '')
          .toString()
          .trim();
      if (convId.isNotEmpty) {
        final notifPlugin = FlutterLocalNotificationsPlugin();
        final notifId = GridChatMessage.notificationIdForConversation(convId);
        final tag = (data['tag'] ?? 'conv-$convId').toString().trim();
        await notifPlugin.cancel(notifId, tag: tag);
        await notifPlugin.cancel(notifId);
        await GridChatMessageNotifications.instance.clearConversation(
          convId,
          notifPlugin,
        );
      }
    } else if (actionId == 'reply') {
      final replyText = (response.input ?? '').trim();
      final convId = (data['conversation_id'] ?? data['conversationId'] ?? '')
          .toString()
          .trim();
      final msgId =
          (data['message_id'] ?? data['messageId'] ?? '').toString().trim();
      if (replyText.isNotEmpty && convId.isNotEmpty) {
        final notifPlugin = FlutterLocalNotificationsPlugin();
        final result = await CircleConnectDeviceKeyStore.instance.sendReply(
          conversationId: convId,
          messageId: msgId,
          text: replyText,
          targetUrl: data['url']?.toString(),
        );
        if (result.statusCode == 403) {
          await showReplyErrorNotification(
            notifPlugin,
            conversationId: convId,
            errorMessage:
                result.errorMessage ?? 'Action not allowed or contact blocked.',
          );
        } else {
          final notifId = GridChatMessage.notificationIdForConversation(convId);
          final tag = (data['tag'] ?? 'conv-$convId').toString().trim();
          await notifPlugin.cancel(notifId, tag: tag);
          await notifPlugin.cancel(notifId);
          await GridChatMessageNotifications.instance.clearConversation(
            convId,
            notifPlugin,
          );
        }
      } else if (convId.isNotEmpty) {
        await GridChatMessageNotifications.instance.storePendingOpen(
          conversationId: convId,
          compose: true,
          needsJs: false,
        );
      }
    } else if (actionId == 'mute') {
      final convId = (data['conversation_id'] ?? data['conversationId'] ?? '')
          .toString()
          .trim();
      if (convId.isNotEmpty) {
        final notifPlugin = FlutterLocalNotificationsPlugin();
        await CircleConnectDeviceKeyStore.instance.muteChat(
          conversationId: convId,
          targetUrl: data['url']?.toString(),
        );
        final notifId = GridChatMessage.notificationIdForConversation(convId);
        final tag = (data['tag'] ?? 'conv-$convId').toString().trim();
        await notifPlugin.cancel(notifId, tag: tag);
        await notifPlugin.cancel(notifId);
        await GridChatMessageNotifications.instance.clearConversation(
          convId,
          notifPlugin,
        );
      }
    }
  } catch (e) {
    debugPrint('[PushBootstrap] notificationTapBackground error: $e');
  }
}

/// Top-level FCM background handler (must stay top-level for the isolate).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await PushNotificationBootstrap.refreshActiveChannels();
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  } catch (e) {
    debugPrint('[PushBootstrap] Background Firebase.initializeApp: $e');
  }

  final data = Map<String, dynamic>.from(message.data);
  final type = (data['type'] ?? data['event'] ?? '').toString().toUpperCase();

  // Explicit, un-swallowable terminal diagnostic banner
  // ignore: avoid_print
  print('''
========================================================================
[FCM_DEBUG] >>> BACKGROUND FCM MESSAGE ARRIVED ON ANDROID! <<<
Message ID: ${message.messageId}
Detected Event/Type: $type
Data Payload: $data
System Notification Tray Payload: ${message.notification?.title} | ${message.notification?.body}
========================================================================
''');

  final plugin = FlutterLocalNotificationsPlugin();
  const androidInit = AndroidInitializationSettings('ic_notification');
  await plugin.initialize(
    InitializationSettings(
      android: androidInit,
      iOS: DarwinInitializationSettings(
        notificationCategories: kDarwinNotificationCategories,
      ),
    ),
    onDidReceiveNotificationResponse: (response) {
      notificationTapBackground(response);
    },
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );

  final android = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  for (final oldId in const [
    'grid_calls',
    'grid_calls_v2',
    'grid_calls_v3',
    'grid_messages',
    'grid_messages_v2',
    'grid_messages_v3',
  ]) {
    try {
      await android?.deleteNotificationChannel(oldId);
    } catch (_) {}
  }
  await android?.createNotificationChannelGroup(kGroupGridChatMessages);
  await android?.createNotificationChannelGroup(kGroupGridChatActivity);
  for (final channel in kCircleConnectChannels.values) {
    await android?.createNotificationChannel(channel);
  }
  await android?.createNotificationChannel(kMessagesChannel);
  await android?.createNotificationChannel(kCallsChannel);
  await android?.createNotificationChannel(kGridActivityChannel);

  if (type == 'ACTIVITY') {
    // ignore: avoid_print
    print(
      '[FCM_DEBUG] ACTIVITY push received in background; rendering notification: $data',
    );
    await showActivityNotificationOnPlugin(plugin, data);
    return;
  }

  if (type == 'PROFESSIONAL_SPACE_EVENT') {
    // Professional Space (GRID) sends both notification and data blocks.
    // When the app is in background or closed, Android's system notification manager
    // automatically displays the notification using the notification block.
    // Do NOT build a duplicate notification in onBackgroundMessage.
    // ignore: avoid_print
    print(
      '[FCM_DEBUG] PROFESSIONAL_SPACE_EVENT received in background; handled by system notification tray.',
    );
    return;
  }

  final callId =
      (data['call_id'] ?? data['callId'] ?? data['id'] ?? '').toString().trim();

  // A1. Check the type before treating a push as a call.
  // If endTypes contains type: stop the ring, cancel notification for this call_id,
  // and show "Missed call" only for MISSED_CALL.
  if (CallLifecycleTracker.kEndCallTypes.contains(type)) {
    // ignore: avoid_print
    print(
        '[FCM_DEBUG] End call event ($type) received in background for callId: $callId');
    if (callId.isNotEmpty) {
      await CallLifecycleTracker.markCallFinished(callId);
      await plugin.cancel(callId.hashCode.abs());
    }
    if (type == 'MISSED_CALL' || type == 'CALL_MISSED') {
      final call = IncomingCallData.fromJson(data);
      await showMissedCallNotificationOnPlugin(plugin, call, rawData: data);
    }
    return;
  }

  final isChatMessage =
      type == 'CHAT_MESSAGE' || type == 'MESSAGE' || type == 'NEW_MESSAGE';

  // A1. Only ringTypes. Never treat as call merely because of call_id in payload!
  final isCall =
      !isChatMessage && CallLifecycleTracker.kRingCallTypes.contains(type);

  if (isCall) {
    // A2. Never ring again for a call that's already over.
    if (callId.isNotEmpty &&
        await CallLifecycleTracker.isCallFinished(callId)) {
      // ignore: avoid_print
      print(
          '[FCM_DEBUG] Suppressing background incoming call: callId $callId is already finished.');
      return;
    }

    // A2. While OngoingCallService has an active call, don't start the ring and don't post a ringing notification.
    if (await CallLifecycleTracker.isOngoingCallActive()) {
      // ignore: avoid_print
      print(
          '[FCM_DEBUG] Suppressing background incoming call: an ongoing call is currently active.');
      return;
    }

    final call = IncomingCallData.fromJson(data);
    // ignore: avoid_print
    print(
        '[FCM_DEBUG] Rendering background incoming call notification for caller: ${call.callerName} (callId: ${call.callId})');
    if (call.actionToken.isNotEmpty) {
      unawaited(IncomingCallService.postNativeAction(
        action: 'ringing',
        actionToken: call.actionToken,
        roomUrl: call.roomUrl,
      ));
    }
    await showIncomingCallNotificationOnPlugin(plugin, call, rawData: data);
    return;
  }

  if (GridChatMessage.isGridChatMessage(data)) {
    final convId = (data['conversation_id'] ?? data['conversationId'] ?? '')
        .toString()
        .trim();
    final msgId =
        (data['message_id'] ?? data['messageId'] ?? '').toString().trim();
    if (convId.isNotEmpty && msgId.isNotEmpty) {
      unawaited(
        CircleConnectDeviceKeyStore.instance.sendDelivered(
          conversationId: convId,
          messageId: msgId,
          targetUrl: data['url']?.toString(),
        ),
      );
    }
    await GridChatMessageNotifications.instance.present(
      plugin,
      data,
      appResumed: false,
    );
    return;
  }

  // Chat message or notification payload
  // ignore: avoid_print
  print('[FCM_DEBUG] Rendering chat message notification: $data');
  await showMessageNotificationOnPlugin(plugin, data,
      notification: message.notification);
}

/// Posts ringing call notification with FLAG_INSISTENT, 45s timeout, and Answer/Decline buttons.
Future<void> showIncomingCallNotificationOnPlugin(
  FlutterLocalNotificationsPlugin plugin,
  IncomingCallData call, {
  Map<String, dynamic>? rawData,
}) async {
  final payload =
      rawData != null ? jsonEncode(rawData) : jsonEncode(call.toJson());
  final notifId = (call.callId.isNotEmpty
          ? call.callId.hashCode
          : DateTime.now().millisecondsSinceEpoch ~/ 1000)
      .abs();
  final callSubtitle = call.body.isNotEmpty
      ? call.body
      : (call.isVideo ? 'Incoming video call' : 'Incoming voice call');

  await plugin.show(
    notifId,
    call.callerName,
    callSubtitle,
    NotificationDetails(
      android: AndroidNotificationDetails(
        PushNotificationBootstrap.activeCallsChannelId,
        kCallsChannel.name,
        channelDescription: kCallsChannel.description,
        icon: 'ic_notification',
        importance: Importance.max,
        priority: Priority.max,
        visibility: NotificationVisibility.public,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        ongoing: true,
        autoCancel: true,
        timeoutAfter: 60000,
        color: const Color(0xFF0284C7),
        ticker: 'Incoming call from ${call.callerName}',
        additionalFlags: Int32List.fromList(
            [4]), // Notification.FLAG_INSISTENT loops ringtone
        styleInformation: BigTextStyleInformation(
          callSubtitle,
          htmlFormatBigText: true,
          contentTitle: call.callerName,
          htmlFormatContentTitle: true,
          summaryText: call.isVideo ? 'Video Call' : 'Voice Call',
          htmlFormatSummaryText: true,
        ),
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'decline',
            'Decline',
            icon: DrawableResourceAndroidBitmap('ic_notification'),
            showsUserInterface: false,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'answer',
            'Answer',
            icon: DrawableResourceAndroidBitmap('ic_notification'),
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'call_ringtone.aiff',
        interruptionLevel: InterruptionLevel.timeSensitive,
        categoryIdentifier: 'calls_category',
      ),
    ),
    payload: payload,
  );
}

/// Posts missed call notification with Call back and Message action buttons.
Future<void> showMissedCallNotificationOnPlugin(
  FlutterLocalNotificationsPlugin plugin,
  IncomingCallData call, {
  Map<String, dynamic>? rawData,
}) async {
  final notifId = (call.callId.isNotEmpty
          ? call.callId.hashCode
          : DateTime.now().millisecondsSinceEpoch ~/ 1000)
      .abs();
  // Cancel previous ringing notification with same callId
  await plugin.cancel(notifId);
  await plugin.cancel(call.callId.hashCode.abs());

  final payloadMap =
      rawData != null ? Map<String, dynamic>.from(rawData) : call.toJson();
  payloadMap['type'] = 'MISSED_CALL';

  final rawChannel = rawData?['channel']?.toString();
  final channelId = resolveCircleConnectChannelId(rawChannel,
      fallback: kChannelMissedCalls.id);
  final targetChannel =
      kCircleConnectChannels[channelId] ?? kChannelMissedCalls;

  final subtitle = call.body.isNotEmpty
      ? call.body
      : (call.isVideo ? 'Missed video call' : 'Missed voice call');

  await plugin.show(
    notifId,
    call.callerName,
    subtitle,
    NotificationDetails(
      android: AndroidNotificationDetails(
        targetChannel.id,
        targetChannel.name,
        channelDescription: targetChannel.description,
        icon: 'ic_notification',
        importance: targetChannel.importance,
        priority: Priority.high,
        visibility: NotificationVisibility.public,
        category: AndroidNotificationCategory.missedCall,
        autoCancel: true,
        color: const Color(0xFFEF4444),
        styleInformation: BigTextStyleInformation(
          subtitle,
          contentTitle: call.callerName,
          summaryText: 'Missed Call',
        ),
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'callback',
            'Call back',
            icon: DrawableResourceAndroidBitmap('ic_notification'),
            showsUserInterface: true,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'message',
            'Message',
            icon: DrawableResourceAndroidBitmap('ic_notification'),
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        categoryIdentifier: 'missed_calls_category',
      ),
    ),
    payload: jsonEncode(payloadMap),
  );
}

/// Posts Professional Space (GRID) social activity notification on grid_activity channel.
Future<void> showProfessionalSpaceNotification(
  FlutterLocalNotificationsPlugin plugin, {
  required Map<String, dynamic> data,
  RemoteNotification? notification,
}) async {
  final rawTitle = (notification?.title ?? data['title'] ?? 'Professional Space')
      .toString()
      .trim();
  final title = rawTitle.isNotEmpty ? rawTitle : 'Professional Space';
  final body = (notification?.body ?? data['body'] ?? data['message'] ?? '')
      .toString()
      .trim();
  final targetUrl =
      (data['target_url'] ?? data['targetUrl'] ?? data['url'] ?? '')
          .toString()
          .trim();
  final postId = (data['post_id'] ?? data['postId'] ?? '').toString().trim();
  final notifId = postId.isNotEmpty
      ? postId.hashCode.abs()
      : DateTime.now().millisecondsSinceEpoch ~/ 1000;

  final payloadMap = <String, dynamic>{
    'type': 'PROFESSIONAL_SPACE_EVENT',
    'target_url': targetUrl,
    'url': targetUrl,
    ...data,
  };

  await plugin.show(
    notifId,
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        kGridActivityChannel.id,
        kGridActivityChannel.name,
        channelDescription: kGridActivityChannel.description,
        icon: 'ic_notification',
        importance: Importance.high,
        priority: Priority.high,
        tag: 'grid_activity',
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    ),
    payload: jsonEncode(payloadMap),
  );
}

/// Posts Circle Connect Activity notification (mentions, comments, likes, live, etc.)
/// on its designated notification channel with in-place tag replacement and avatar icon.
Future<void> showActivityNotificationOnPlugin(
  FlutterLocalNotificationsPlugin plugin,
  Map<String, dynamic> data, {
  RemoteNotification? notification,
}) async {
  final rawTitle = (notification?.title ?? data['title'] ?? 'Circle Connect')
      .toString()
      .trim();
  final title = rawTitle.isNotEmpty ? rawTitle : 'Circle Connect';
  final body = (notification?.body ?? data['body'] ?? data['message'] ?? '')
      .toString()
      .trim();
  final rawChannel = data['channel']?.toString();
  final channelId =
      resolveCircleConnectChannelId(rawChannel, fallback: 'mentions');
  final targetChannel = kCircleConnectChannels[channelId] ?? kChannelMentions;
  final tag = (data['tag'] ?? data['activity_id'] ?? '').toString().trim();
  final notifId = (tag.isNotEmpty
          ? tag.hashCode
          : (data['activity_id']?.hashCode ??
              DateTime.now().millisecondsSinceEpoch ~/ 1000))
      .abs();
  final avatarUrl = (data['actor_avatar'] ?? '').toString().trim();
  final rawUrl =
      (data['url'] ?? data['target_url'] ?? data['targetUrl'] ?? '')
          .toString()
          .trim();
  final targetUrl = rawUrl.isNotEmpty
      ? rawUrl
      : 'https://efactor.tech/index.php/grid-chat?open=activity';
  final unread = data['unread'];
  if (unread != null) {
    GridUnreadCountsService.instance.updateUnreadCount(unread);
  }

  ByteArrayAndroidBitmap? largeIconBitmap;
  if (avatarUrl.isNotEmpty && isSafeEfactorUrl(avatarUrl)) {
    try {
      final res = await http
          .get(Uri.parse(avatarUrl))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        largeIconBitmap = ByteArrayAndroidBitmap(res.bodyBytes);
      }
    } catch (_) {}
  }

  final isHigh = targetChannel.importance == Importance.max ||
      targetChannel.importance == Importance.high;

  final androidDetails = AndroidNotificationDetails(
    targetChannel.id,
    targetChannel.name,
    channelDescription: targetChannel.description,
    importance: targetChannel.importance,
    priority: isHigh ? Priority.high : Priority.defaultPriority,
    icon: 'ic_notification',
    largeIcon: largeIconBitmap,
    tag: tag.isNotEmpty ? tag : null,
    playSound: true,
    enableVibration: true,
    enableLights: true,
  );

  const iosDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
  );

  final payloadMap = <String, dynamic>{
    'type': 'ACTIVITY',
    'url': targetUrl,
    'target_url': targetUrl,
    ...data,
  };

  await plugin.show(
    notifId,
    title,
    body,
    NotificationDetails(android: androidDetails, iOS: iosDetails),
    payload: jsonEncode(payloadMap),
  );
}

/// Posts chat message notification with inline Reply and Mark as read buttons.
Future<void> showMessageNotificationOnPlugin(
  FlutterLocalNotificationsPlugin plugin,
  Map<String, dynamic> data, {
  RemoteNotification? notification,
}) async {
  final convId =
      (data['conversation_id'] ?? data['conversationId'] ?? '').toString();
  final rawNotifId = int.tryParse(convId) ??
      (convId.isNotEmpty
          ? convId.hashCode
          : DateTime.now().millisecondsSinceEpoch ~/ 1000);
  final notifId = rawNotifId.abs();

  final isLocked = data['locked'] == true || data['locked'] == 'true';
  final isGroup =
      GridChatMessage.isTruthyFlag(data['is_group'] ?? data['isGroup']);
  final senderName = (data['sender_name'] ??
          data['senderName'] ??
          data['name'] ??
          data['user_name'] ??
          data['sender'] ??
          '')
      .toString()
      .trim();
  final groupTitle =
      (data['group_title'] ?? data['groupTitle'] ?? '').toString().trim();
  final rawTitle =
      (notification?.title ?? data['title'] ?? '').toString().trim();

  // For group messages (is_group = 1), title is group_title or title ("Test group").
  // On a 1:1 message notification (is_group = 0), the title should be just the sender's name.
  final effectiveTitle = isGroup
      ? (groupTitle.isNotEmpty
          ? groupTitle
          : (rawTitle.isNotEmpty
              ? rawTitle
              : (senderName.isNotEmpty ? senderName : 'Group Chat')))
      : (senderName.isNotEmpty
          ? senderName
          : (rawTitle.isNotEmpty ? rawTitle : 'Circle Connect'));

  final rawBody = notification?.body ??
      data['body'] ??
      data['message'] ??
      data['text'] ??
      data['content'];
  final msgType = (data['msg_type'] ??
          data['msgType'] ??
          data['message_type'] ??
          data['messageType'] ??
          'text')
      .toString()
      .trim()
      .toLowerCase();

  final baseBody = (rawBody != null && rawBody.toString().trim().isNotEmpty)
      ? rawBody.toString().trim()
      : _defaultBodyForMessageType(msgType);

  // For group messages, show line like WhatsApp: "Pavan Nagapuri: message".
  final effectiveBody = (isGroup && senderName.isNotEmpty)
      ? (baseBody.toLowerCase().startsWith('${senderName.toLowerCase()}:')
          ? baseBody
          : '$senderName: $baseBody')
      : baseBody;

  final rawChannel = data['channel']?.toString();
  final channelId = rawChannel != null && rawChannel.trim().isNotEmpty
      ? resolveCircleConnectChannelId(
          rawChannel,
          fallback: isGroup
              ? kChannelGroupMessages.id
              : PushNotificationBootstrap.activeMessagesChannelId,
        )
      : (isGroup
          ? kChannelGroupMessages.id
          : PushNotificationBootstrap.activeMessagesChannelId);
  final targetChannel = kCircleConnectChannels[channelId] ??
      (isGroup ? kChannelGroupMessages : kMessagesChannel);

  if (isLocked) {
    await plugin.show(
      notifId,
      'Circle Connect',
      'New message',
      NotificationDetails(
        android: AndroidNotificationDetails(
          targetChannel.id,
          targetChannel.name,
          channelDescription: targetChannel.description,
          icon: 'ic_notification',
          importance: targetChannel.importance,
          priority: Priority.high,
          visibility: NotificationVisibility.public,
          autoCancel: true,
          color: const Color(0xFF0284C7),
          styleInformation: const BigTextStyleInformation(
            'New message',
            contentTitle: 'Circle Connect',
            summaryText: 'Locked Content',
          ),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          categoryIdentifier: 'messages_locked_category',
        ),
      ),
      payload: jsonEncode(data),
    );
    return;
  }

  await plugin.show(
    notifId,
    effectiveTitle,
    effectiveBody,
    NotificationDetails(
      android: AndroidNotificationDetails(
        targetChannel.id,
        targetChannel.name,
        channelDescription: targetChannel.description,
        icon: 'ic_notification',
        importance: targetChannel.importance,
        priority: Priority.high,
        visibility: NotificationVisibility.public,
        category: AndroidNotificationCategory.message,
        autoCancel: true,
        color: const Color(0xFF0284C7),
        styleInformation: BigTextStyleInformation(
          effectiveBody,
          contentTitle: effectiveTitle,
          summaryText: isGroup ? effectiveTitle : 'Circle Connect Chat',
        ),
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'reply',
            'Reply',
            icon: DrawableResourceAndroidBitmap('ic_notification'),
            showsUserInterface: true,
            inputs: <AndroidNotificationActionInput>[
              AndroidNotificationActionInput(label: 'Type a reply...'),
            ],
          ),
          AndroidNotificationAction(
            'mark_as_read',
            'Mark as read',
            icon: DrawableResourceAndroidBitmap('ic_notification'),
            showsUserInterface: false,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'mute',
            'Mute',
            icon: DrawableResourceAndroidBitmap('ic_notification'),
            showsUserInterface: false,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        categoryIdentifier: 'messages_category',
      ),
    ),
    payload: jsonEncode(data),
  );
}

String _defaultBodyForMessageType(String type) {
  switch (type.toLowerCase().trim()) {
    case 'image':
    case 'photo':
      return '📷 Photo';
    case 'video':
      return '🎥 Video';
    case 'audio':
    case 'voice':
      return '🎤 Voice message';
    case 'file':
    case 'document':
    case 'pdf':
      return '📄 Document';
    default:
      return 'New message';
  }
}

/// Sends background Mark as read request using CircleConnect device key,
/// with fallback to legacy cookie auth if no device key is stored yet.
Future<void> handleMarkAsReadFromNotification(Map<String, dynamic> data) async {
  final convId =
      (data['conversation_id'] ?? data['conversationId'] ?? '').toString().trim();
  final msgId = (data['message_id'] ?? data['messageId'] ?? '').toString().trim();
  var targetUrl =
      (data['url'] ?? IncomingCallData.defaultCallUrl).toString().trim();
  if (targetUrl.isNotEmpty &&
      !targetUrl.startsWith('http://') &&
      !targetUrl.startsWith('https://')) {
    targetUrl =
        'https://efactor.tech/${targetUrl.replaceAll(RegExp(r'^/+'), '')}';
  }

  // 1. Immediately cancel all notifications for this conversation
  if (convId.isNotEmpty) {
    unawaited(PushNotificationBootstrap.instance.clearChatNotifications(convId));
  }

  // 2. Perform authenticated background Mark as Read via CircleConnectDeviceKeyStore
  final handledByDeviceKey = await CircleConnectDeviceKeyStore.instance.markAsRead(
    conversationId: convId,
    messageId: msgId,
    targetUrl: targetUrl,
  );

  if (handledByDeviceKey) return;

  // 3. Fallback to legacy cookie-based read only if no device key is stored
  final existingKey = await CircleConnectDeviceKeyStore.instance.getDeviceKey();
  if (existingKey != null && existingKey.isNotEmpty) {
    return;
  }

  final cookies =
      await IncomingCallService.instance.getCookiesForUrl(targetUrl);
  final cleanUrl = targetUrl.split('?').first.replaceAll(RegExp(r'/+$'), '');
  final primaryUri = Uri.tryParse('$cleanUrl/api/chat/read');
  final originUri = Uri.tryParse(targetUrl);
  final fallbackUri = originUri != null
      ? Uri.tryParse('${originUri.origin}/index.php/grid-chat/api/chat/read')
      : null;

  final headers = <String, String>{
    'Content-Type': 'application/x-www-form-urlencoded',
    if (cookies.isNotEmpty) 'Cookie': cookies,
    if (IncomingCallService.instance.activeAccessToken != null)
      'Authorization':
          'Bearer ${IncomingCallService.instance.activeAccessToken}',
  };

  final bodyFields = <String, String>{
    'conversation_id': convId,
    'message_id': msgId,
  };

  try {
    if (primaryUri != null) {
      final resp = await http
          .post(primaryUri, headers: headers, body: bodyFields)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    }
    if (fallbackUri != null && fallbackUri != primaryUri) {
      await http
          .post(fallbackUri, headers: headers, body: bodyFields)
          .timeout(const Duration(seconds: 10));
    }
  } catch (e) {
    debugPrint('[PushBootstrap] legacy markAsRead error: $e');
  }
}

/// Sends Reply request to server with WebView cookies.
Future<void> handleSendReplyFromNotification(
  Map<String, dynamic> data,
  String replyText,
) async {
  final convId =
      (data['conversation_id'] ?? data['conversationId'] ?? '').toString();
  var targetUrl =
      (data['url'] ?? IncomingCallData.defaultCallUrl).toString().trim();
  if (targetUrl.isNotEmpty &&
      !targetUrl.startsWith('http://') &&
      !targetUrl.startsWith('https://')) {
    targetUrl =
        'https://efactor.tech/${targetUrl.replaceAll(RegExp(r'^/+'), '')}';
  }
  final clientId =
      'reply_${DateTime.now().millisecondsSinceEpoch}_${convId.hashCode}';

  final cookies =
      await IncomingCallService.instance.getCookiesForUrl(targetUrl);
  final cleanUrl = targetUrl.split('?').first.replaceAll(RegExp(r'/+$'), '');
  final primaryUri = Uri.tryParse('$cleanUrl/api/chat/send');
  final originUri = Uri.tryParse(targetUrl);
  final fallbackUri = originUri != null
      ? Uri.tryParse('${originUri.origin}/index.php/grid-chat/api/chat/send')
      : null;

  final headers = <String, String>{
    'Content-Type': 'application/x-www-form-urlencoded',
    if (cookies.isNotEmpty) 'Cookie': cookies,
    if (IncomingCallService.instance.activeAccessToken != null)
      'Authorization':
          'Bearer ${IncomingCallService.instance.activeAccessToken}',
  };

  final bodyFields = <String, String>{
    'conversation_id': convId,
    'msg_type': 'text',
    'message_type': 'text',
    'body': replyText,
    'client_id': clientId,
  };

  try {
    if (primaryUri != null) {
      final resp = await http
          .post(primaryUri, headers: headers, body: bodyFields)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    }
    if (fallbackUri != null && fallbackUri != primaryUri) {
      await http
          .post(fallbackUri, headers: headers, body: bodyFields)
          .timeout(const Duration(seconds: 10));
    }
  } catch (e) {
    debugPrint('[PushBootstrap] sendReply error: $e');
  }
}

/// Displays an error alert notification when an inline reply fails (e.g., 403 blocked contact).
Future<void> showReplyErrorNotification(
  FlutterLocalNotificationsPlugin plugin, {
  required String conversationId,
  required String errorMessage,
}) async {
  final notifId =
      (int.tryParse(conversationId) ?? conversationId.hashCode).abs();
  final androidDetails = AndroidNotificationDetails(
    PushNotificationBootstrap.activeMessagesChannelId,
    kMessagesChannel.name,
    channelDescription: kMessagesChannel.description,
    icon: 'ic_notification',
    importance: Importance.high,
    priority: Priority.high,
    autoCancel: true,
    color: const Color(0xFFEF4444),
  );
  const iosDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
  );
  await plugin.show(
    notifId,
    'GRID Chat',
    errorMessage,
    NotificationDetails(android: androidDetails, iOS: iosDetails),
  );
}

/// Wires FCM + local notifications into [IncomingCallService].
///
/// Requires `android/app/google-services.json` and
/// `ios/Runner/GoogleService-Info.plist`. Without them, [initialize] no-ops
/// so the app still boots.
class PushNotificationBootstrap {
  PushNotificationBootstrap._();
  static final PushNotificationBootstrap instance =
      PushNotificationBootstrap._();

  static String _activeCallsChannelId = kCallsChannel.id;
  static String _activeMessagesChannelId = kMessagesChannel.id;

  static String get activeCallsChannelId => _activeCallsChannelId;
  static String get activeMessagesChannelId => _activeMessagesChannelId;

  static Future<void> refreshActiveChannels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedCalls = prefs.getString('circle_connect_calls_channel_id');
      if (savedCalls != null && savedCalls.isNotEmpty) {
        _activeCallsChannelId = savedCalls;
      }
      final savedMsgs = prefs.getString('circle_connect_messages_channel_id');
      if (savedMsgs != null && savedMsgs.isNotEmpty) {
        _activeMessagesChannelId = savedMsgs;
        GridChatMessageNotifications.activeChannelId = savedMsgs;
      }
    } catch (_) {}
  }

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  var _ready = false;
  Future<void>? _initFuture;
  StreamSubscription<String>? _tokenSub;
  String? _activeConversationId;

  bool get isReady => _ready;
  String? get activeConversationId => _activeConversationId;

  /// Sets the currently active conversation in Circle Connect chat.
  /// When set, foreground notification banners for this conversation are suppressed.
  void setActiveConversationId(String? conversationId) {
    final cleanId = conversationId?.trim();
    _activeConversationId =
        (cleanId == null || cleanId.isEmpty) ? null : cleanId;
    debugPrint(
        '[PushBootstrap] Active conversation set to: $_activeConversationId');
    if (_activeConversationId != null) {
      unawaited(clearChatNotifications(_activeConversationId!));
    }
  }

  bool _localNotificationsReady = false;

  /// Reads the Answer action that launched a killed app, before Firebase
  /// and before the home dashboard is built.
  Future<void> captureColdStartAnswer() async {
    if (kIsWeb) return;
    await _initLocalNotifications();
    try {
      final launchDetails = await _local.getNotificationAppLaunchDetails();
      final response = launchDetails?.notificationResponse;
      if (launchDetails?.didNotificationLaunchApp != true || response == null) {
        return;
      }
      final payload = response.payload;
      if (payload == null || payload.isEmpty) return;
      final data = jsonDecode(payload) as Map<String, dynamic>;
      if (response.actionId == 'answer') {
        final call = IncomingCallData.fromJson(data);
        if (call.callId.isEmpty) return;
        await IncomingCallService.instance.recordNotificationAnswer(call);
        return;
      }
      if (GridChatMessage.isGridChatMessage(data)) {
        final conversationId =
            (data['conversation_id'] ?? data['conversationId'] ?? '')
                .toString()
                .trim();
        if (conversationId.isEmpty) return;
        await GridChatMessageNotifications.instance.storePendingOpen(
          conversationId: conversationId,
          compose: response.actionId == 'reply',
          needsJs: false,
        );
      }
    } catch (e) {
      // ignore: avoid_print
      print('[CALL] cold-start answer capture failed error=$e');
    }
  }

  Future<void> initialize() async {
    if (_ready || kIsWeb) return;
    if (_initFuture != null) return _initFuture;
    _initFuture = _doInitialize();
    return _initFuture;
  }

  Future<void> _doInitialize() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
    } catch (e) {
      logDebug(
        '[PushBootstrap] Firebase not configured ($e). '
        'Copy google-services.json and GoogleService-Info.plist then rebuild.',
      );
      _initFuture = null;
      return;
    }

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    await _initLocalNotifications();
    await requestNotificationPermission();

    final messaging = FirebaseMessaging.instance;
    await _captureToken(messaging);

    _tokenSub = messaging.onTokenRefresh.listen((refreshed) {
      IncomingCallService.instance.setDeviceToken(refreshed);
      unawaited(_syncTokenIfLoggedIn(refreshed));
    });

    FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_onMessageOpened);

    const MethodChannel('tech.efactor/circle_connect')
        .setMethodCallHandler((call) async {
      if (call.method == 'openSettingsUrl') {
        final url = (call.arguments as Map?)?['url']?.toString() ??
            'https://efactor.tech/index.php/grid-chat/settings';
        if (isSafeEfactorUrl(url)) {
          unawaited(GridInAppWebViewPage.loadTargetUrl(url));
        }
      }
      return null;
    });
    try {
      final initial = await messaging
          .getInitialMessage()
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      if (initial != null) {
        _onMessageOpened(initial);
      }
    } catch (e) {
      logDebug('[PushBootstrap] getInitialMessage error: $e');
    }

    try {
      final launchDetails = await _local.getNotificationAppLaunchDetails();
      if (launchDetails != null &&
          launchDetails.didNotificationLaunchApp &&
          launchDetails.notificationResponse != null) {
        logDebug(
          '[PushBootstrap] App launched from notification action: '
          '${launchDetails.notificationResponse?.actionId} '
          'payload: ${launchDetails.notificationResponse?.payload}',
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _handleNotificationResponse(launchDetails.notificationResponse!);
        });
      }
    } catch (e) {
      logDebug('[PushBootstrap] getNotificationAppLaunchDetails error: $e');
    }

    try {
      if (IncomingCallService.instance.activeAccessToken == null) {
        final session = await AuthSecureStorage().readSession();
        final token = session['accessToken'];
        final uid = session['userId'];
        if (token != null && token.isNotEmpty) {
          IncomingCallService.instance.activeAccessToken = token;
          if (uid != null) {
            IncomingCallService.instance.activeUserId = int.tryParse(uid);
          }
          final fcmToken = IncomingCallService.instance.deviceToken;
          if (fcmToken != null && fcmToken.isNotEmpty && uid != null) {
            unawaited(
              IncomingCallService.instance.syncDeviceTokenOnLogin(
                userId: uid,
                accessToken: token,
                tokenOverride: fcmToken,
              ),
            );
          }
        }
      }
    } catch (e) {
      logDebug('[PushBootstrap] Cold start session restore error: $e');
    }

    _ready = true;
    logDebug('[PushBootstrap] READY');
  }

  /// Call after login (or anytime) to refresh OS permission + FCM token.
  Future<void> requestNotificationPermission() async {
    if (kIsWeb) return;
    try {
      if (Platform.isAndroid) {
        final status = await Permission.notification.status;
        if (!status.isGranted) {
          await Permission.notification.request();
        }
      }
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        criticalAlert: true,
        provisional: false,
        providesAppNotificationSettings: true,
      );
      if (Platform.isIOS) {
        // Prevent Firebase from auto-popping raw, unstacked alert banners in the foreground.
        // Instead, GridChatMessageNotifications / showMessageNotificationOnPlugin controls
        // the rich foreground presentation with deduplication, active-chat suppression,
        // message stacking, and interactive action buttons.
        await messaging.setForegroundNotificationPresentationOptions(
          alert: false,
          badge: true,
          sound: false,
        );
      }
      final android = _local.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
    } catch (e) {
      logDebug('[PushBootstrap] permission request failed: $e');
    }
  }

  /// Ensures a token is present and synced after authentication.
  Future<void> ensureTokenSynced({
    required String userId,
    required String accessToken,
  }) async {
    if (!_ready) {
      await initialize();
    }
    await requestNotificationPermission();
    try {
      if (!kIsWeb && Platform.isIOS) {
        // iOS requires APNs token to be acquired first before FCM token can be generated
        int retries = 0;
        while (retries < 6) {
          final apns = await FirebaseMessaging.instance.getAPNSToken();
          if (apns != null && apns.isNotEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          retries++;
        }
      }
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        IncomingCallService.instance.setDeviceToken(token);
        // ignore: avoid_print
        print('''
========================================================================
[FCM_DEBUG] DEVICE FCM TOKEN ACQUIRED FOR USER: $userId
Token: $token
========================================================================
''');
        await IncomingCallService.instance.syncDeviceTokenOnLogin(
          userId: userId,
          accessToken: accessToken,
          tokenOverride: token,
        );
      } else {
        // ignore: avoid_print
        print('[FCM_DEBUG] No FCM token returned from Firebase after login.');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[FCM_DEBUG] ensureTokenSynced failed: $e');
    }
  }

  Future<void> _captureToken(FirebaseMessaging messaging) async {
    try {
      if (!kIsWeb && Platform.isIOS) {
        int retries = 0;
        while (retries < 6) {
          final apns = await messaging.getAPNSToken();
          if (apns != null && apns.isNotEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          retries++;
        }
      }
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        IncomingCallService.instance.setDeviceToken(token);
        // ignore: avoid_print
        print(
            '[FCM_DEBUG] Startup FCM token captured (${token.length} chars): $token');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[FCM_DEBUG] Startup getToken failed: $e');
    }
  }

  Future<void> _syncTokenIfLoggedIn(String token) async {
    final uid = IncomingCallService.instance.activeUserId;
    final access = IncomingCallService.instance.activeAccessToken;
    if (uid == null || access == null || access.isEmpty) return;
    await IncomingCallService.instance.syncDeviceTokenOnLogin(
      userId: uid.toString(),
      accessToken: access,
      tokenOverride: token,
    );
  }

  Future<void> _initLocalNotifications() async {
    if (_localNotificationsReady) return;
    await refreshActiveChannels();
    const android = AndroidInitializationSettings('ic_notification');
    final ios = DarwinInitializationSettings(
      notificationCategories: kDarwinNotificationCategories,
    );
    await _local.initialize(
      InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: _handleNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    final androidPlugin = _local.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    for (final oldId in const [
      'grid_calls',
      'grid_calls_v2',
      'grid_calls_v3',
      'grid_messages',
      'grid_messages_v2',
      'grid_messages_v3',
    ]) {
      try {
        await androidPlugin?.deleteNotificationChannel(oldId);
      } catch (_) {}
    }
    await androidPlugin?.createNotificationChannelGroup(kGroupGridChatMessages);
    await androidPlugin?.createNotificationChannelGroup(kGroupGridChatActivity);
    for (final channel in kCircleConnectChannels.values) {
      await androidPlugin?.createNotificationChannel(channel);
    }
    await androidPlugin?.createNotificationChannel(kMessagesChannel);
    await androidPlugin?.createNotificationChannel(kCallsChannel);
    await androidPlugin?.createNotificationChannel(kGridActivityChannel);
    _localNotificationsReady = true;
  }

  Future<void> _onForegroundMessage(RemoteMessage message) async {
    final data = Map<String, dynamic>.from(message.data);
    final type = (data['type'] ?? data['event'] ?? '').toString().toUpperCase();

    // ignore: avoid_print
    print('''
========================================================================
[FCM_DEBUG] >>> FOREGROUND FCM RECEIVED! <<<
Message ID: ${message.messageId}
Type: $type
Data: $data
Notification: ${message.notification?.title} | ${message.notification?.body}
========================================================================
''');

    final callId = (data['call_id'] ?? data['callId'] ?? data['id'] ?? '')
        .toString()
        .trim();

    // A1. Check endTypes before treating a push as a call
    if (CallLifecycleTracker.kEndCallTypes.contains(type)) {
      if (callId.isNotEmpty) {
        unawaited(CallLifecycleTracker.markCallFinished(callId));
        unawaited(cancelCallNotification(callId));
      }
      IncomingCallService.instance.handleIncomingPayload(data);
      return;
    }

    final isChatMessage =
        type == 'CHAT_MESSAGE' || type == 'MESSAGE' || type == 'NEW_MESSAGE';

    // A1. Only ringTypes. Never treat as call merely because of call_id!
    final isCall =
        !isChatMessage && CallLifecycleTracker.kRingCallTypes.contains(type);

    if (isCall) {
      // A2. Never ring again for a call that's already over.
      if (callId.isNotEmpty &&
          (CallLifecycleTracker.isCallFinishedSync(callId) ||
              await CallLifecycleTracker.isCallFinished(callId))) {
        // ignore: avoid_print
        print(
            '[FCM_DEBUG] Suppressing foreground incoming call: callId $callId is already finished.');
        return;
      }

      // A2. While OngoingCallService has an active call, don't start the ring and don't post a ringing notification.
      if (OngoingCallService.instance.isCallActive ||
          await CallLifecycleTracker.isOngoingCallActive()) {
        // ignore: avoid_print
        print(
            '[FCM_DEBUG] Suppressing foreground incoming call: an ongoing call is currently active.');
        return;
      }

      final call = IncomingCallData.fromJson(data);
      if (call.actionToken.isNotEmpty) {
        unawaited(IncomingCallService.postNativeAction(
          action: 'ringing',
          actionToken: call.actionToken,
          roomUrl: call.roomUrl,
        ));
      }
      IncomingCallService.instance.handleIncomingPayload(data);
      return;
    }

    if (GridChatMessage.isGridChatMessage(data)) {
      final convId = (data['conversation_id'] ?? data['conversationId'] ?? '')
          .toString()
          .trim();
      final msgId =
          (data['message_id'] ?? data['messageId'] ?? '').toString().trim();
      if (convId.isNotEmpty && msgId.isNotEmpty) {
        unawaited(
          CircleConnectDeviceKeyStore.instance.sendDelivered(
            conversationId: convId,
            messageId: msgId,
            targetUrl: data['url']?.toString(),
          ),
        );
      }
      final resumed =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      unawaited(
        GridChatMessageNotifications.instance.present(
          _local,
          data,
          appResumed: resumed,
          activeConversationId: _activeConversationId,
        ),
      );
      return;
    }
    if (type == 'ACTIVITY') {
      unawaited(showActivityNotificationOnPlugin(_local, data));
      return;
    }
    if (type == 'PROFESSIONAL_SPACE_EVENT') {
      unawaited(
        showProfessionalSpaceNotification(
          _local,
          data: data,
          notification: message.notification,
        ),
      );
      return;
    }
    unawaited(showMessageNotificationOnPlugin(_local, data,
        notification: message.notification));
  }

  void _onMessageOpened(RemoteMessage message) {
    _handlePayloadMap(Map<String, dynamic>.from(message.data));
  }

  Future<void> _handleNotificationResponse(
    NotificationResponse response,
  ) async {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final type =
          (data['type'] ?? data['event'] ?? '').toString().toUpperCase();
      final actionId = response.actionId;

      if (actionId == 'stop_live_location') {
        await GridLiveLocationService.instance.stopAll(postStop: true);
        return;
      }
      if (actionId == 'decline') {
        final call = IncomingCallData.fromJson(data);
        if (call.callId.isNotEmpty) {
          unawaited(CallLifecycleTracker.markCallFinished(call.callId));
        }
        await IncomingCallService.instance.declineCall(call);
        return;
      }
      if (actionId == 'answer') {
        final call = IncomingCallData.fromJson(data);
        if (call.callId.isNotEmpty) {
          unawaited(CallLifecycleTracker.markCallFinished(call.callId));
        }
        await IncomingCallService.instance.answerCall(call);
        return;
      }
      if (actionId == null || actionId.isEmpty) {
        final tappedCallId =
            (data['call_id'] ?? data['callId'] ?? '').toString();
        if (IncomingCallService.instance
            .shouldIgnoreNotificationBodyTap(tappedCallId)) {
          // ignore: avoid_print
          print(
            '[CALL] ignored notification dismiss call_id=$tappedCallId',
          );
          return;
        }
      }
      if (actionId == 'callback') {
        final call = IncomingCallData.fromJson(data);
        await IncomingCallService.instance.callbackCall(call);
        return;
      }
      if (actionId == 'message') {
        final call = IncomingCallData.fromJson(data);
        await IncomingCallService.instance.messageCall(call);
        return;
      }
      if (actionId == 'mark_as_read') {
        await handleMarkAsReadFromNotification(data);
        final convId = (data['conversation_id'] ?? data['conversationId'] ?? '')
            .toString()
            .trim();
        if (convId.isNotEmpty) {
          final notifId = GridChatMessage.notificationIdForConversation(convId);
          final tag = (data['tag'] ?? 'conv-$convId').toString().trim();
          await _local.cancel(notifId, tag: tag);
          await _local.cancel(notifId);
          await GridChatMessageNotifications.instance.clearConversation(
            convId,
            _local,
          );
        }
        return;
      }
      if (actionId == 'reply') {
        final replyText = (response.input ?? '').trim();
        final convId = (data['conversation_id'] ?? data['conversationId'] ?? '')
            .toString()
            .trim();
        final msgId =
            (data['message_id'] ?? data['messageId'] ?? '').toString().trim();
        if (replyText.isNotEmpty && convId.isNotEmpty) {
          final result = await CircleConnectDeviceKeyStore.instance.sendReply(
            conversationId: convId,
            messageId: msgId,
            text: replyText,
            targetUrl: data['url']?.toString(),
          );
          if (result.statusCode == 403) {
            await showReplyErrorNotification(
              _local,
              conversationId: convId,
              errorMessage:
                  result.errorMessage ?? 'Action not allowed or contact blocked.',
            );
          } else {
            final notifId = GridChatMessage.notificationIdForConversation(convId);
            final tag = (data['tag'] ?? 'conv-$convId').toString().trim();
            await _local.cancel(notifId, tag: tag);
            await _local.cancel(notifId);
            await GridChatMessageNotifications.instance.clearConversation(
              convId,
              _local,
            );
          }
        } else if (convId.isNotEmpty) {
          await IncomingCallService.instance.openChatFromNotification(
            conversationId: convId,
            url: '',
            compose: true,
          );
          await GridChatMessageNotifications.instance.clearConversation(
            convId,
            _local,
          );
        }
        return;
      }
      if (actionId == 'mute') {
        final convId = (data['conversation_id'] ?? data['conversationId'] ?? '')
            .toString()
            .trim();
        if (convId.isNotEmpty) {
          await CircleConnectDeviceKeyStore.instance.muteChat(
            conversationId: convId,
            targetUrl: data['url']?.toString(),
          );
          final notifId = GridChatMessage.notificationIdForConversation(convId);
          final tag = (data['tag'] ?? 'conv-$convId').toString().trim();
          await _local.cancel(notifId, tag: tag);
          await _local.cancel(notifId);
          await GridChatMessageNotifications.instance.clearConversation(
            convId,
            _local,
          );
        }
        return;
      }

      // No button clicked -> user tapped notification banner / full-screen intent
      if (type == 'INCOMING_CALL' || type == 'CALL') {
        final call = IncomingCallData.fromJson(data);
        await IncomingCallService.instance.showCallScreen(call);
      } else if (type == 'MISSED_CALL') {
        final call = IncomingCallData.fromJson(data);
        await IncomingCallService.instance.openCallScreenWithoutAction(call);
      } else if (type == 'ACTIVITY') {
        final rawUrl =
            (data['url'] ?? data['target_url'] ?? data['targetUrl'] ?? '')
                .toString()
                .trim();
        final effectiveUrl = rawUrl.isNotEmpty
            ? rawUrl
            : 'https://efactor.tech/index.php/grid-chat?open=activity';
        if (isSafeEfactorUrl(effectiveUrl)) {
          unawaited(GridInAppWebViewPage.loadTargetUrl(effectiveUrl));
          return;
        }
      } else {
        // Professional Space event or target_url tap
        final targetUrl =
            (data['target_url'] ?? data['targetUrl'] ?? '').toString().trim();
        if (type == 'PROFESSIONAL_SPACE_EVENT' || targetUrl.isNotEmpty) {
          final effectiveUrl = targetUrl.isNotEmpty
              ? targetUrl
              : (data['url'] ?? '').toString().trim();
          if (effectiveUrl.isNotEmpty && isSafeEfactorUrl(effectiveUrl)) {
            unawaited(GridInAppWebViewPage.loadTargetUrl(effectiveUrl));
            return;
          }
        }

        // Message notification tap
        final convId = (data['conversation_id'] ?? data['conversationId'] ?? '')
            .toString();
        final url = (data['url'] ?? '').toString();
        await IncomingCallService.instance.openChatFromNotification(
          conversationId: convId,
          url: url,
        );
      }
    } catch (e) {
      debugPrint('[PushBootstrap] _handleNotificationResponse error: $e');
    }
  }

  void _handlePayloadMap(Map<String, dynamic> data) {
    final type = (data['type'] ?? data['event'] ?? '').toString().toUpperCase();
    if (CallLifecycleTracker.kRingCallTypes.contains(type)) {
      final call = IncomingCallData.fromJson(data);
      if (CallLifecycleTracker.isCallFinishedSync(call.callId)) {
        debugPrint(
            '[PushBootstrap] Suppressing showCallScreen: call is finished ${call.callId}');
        return;
      }
      unawaited(
        IncomingCallService.instance.showCallScreen(call),
      );
      return;
    }
    if (type == 'MISSED_CALL' || type == 'CALL_MISSED') {
      final call = IncomingCallData.fromJson(data);
      unawaited(
        IncomingCallService.instance.openCallScreenWithoutAction(call),
      );
      return;
    }
    if (type == 'ACTIVITY') {
      final rawUrl =
          (data['url'] ?? data['target_url'] ?? data['targetUrl'] ?? '')
              .toString()
              .trim();
      final effectiveUrl = rawUrl.isNotEmpty
          ? rawUrl
          : 'https://efactor.tech/index.php/grid-chat?open=activity';
      if (isSafeEfactorUrl(effectiveUrl)) {
        unawaited(GridInAppWebViewPage.loadTargetUrl(effectiveUrl));
        return;
      }
    }

    // Professional Space event or target_url tap
    final targetUrl =
        (data['target_url'] ?? data['targetUrl'] ?? '').toString().trim();
    if (type == 'PROFESSIONAL_SPACE_EVENT' || targetUrl.isNotEmpty) {
      final effectiveUrl = targetUrl.isNotEmpty
          ? targetUrl
          : (data['url'] ?? '').toString().trim();
      if (effectiveUrl.isNotEmpty && isSafeEfactorUrl(effectiveUrl)) {
        unawaited(GridInAppWebViewPage.loadTargetUrl(effectiveUrl));
        return;
      }
    }

    final convId =
        (data['conversation_id'] ?? data['conversationId'] ?? '').toString();
    final url = (data['url'] ?? '').toString();
    unawaited(
      IncomingCallService.instance.openChatFromNotification(
        conversationId: convId,
        url: url,
      ),
    );
  }

  final Set<String> _postedIncomingCallIds = <String>{};

  /// Public API called by [IncomingCallService] and [GridInAppWebViewPage].
  /// The same call_id is posted once until it is cancelled.
  Future<void> showIncomingCallNotification(IncomingCallData call) async {
    final id = call.callId.trim();
    if (id.isNotEmpty && _postedIncomingCallIds.contains(id)) {
      return;
    }
    if (OngoingCallService.instance.isCallActive ||
        await CallLifecycleTracker.isOngoingCallActive() ||
        (id.isNotEmpty && await CallLifecycleTracker.isCallFinished(id))) {
      debugPrint(
          '[PushBootstrap] Suppressing showIncomingCallNotification: call is finished or ongoing active: $id');
      return;
    }
    try {
      await showIncomingCallNotificationOnPlugin(_local, call);
      if (id.isNotEmpty) {
        _postedIncomingCallIds.add(id);
      }
    } catch (e) {
      debugPrint('[PushBootstrap] showIncomingCallNotification error: $e');
    }
  }

  Future<void> showMissedCallNotification(IncomingCallData call) async {
    try {
      await showMissedCallNotificationOnPlugin(_local, call);
    } catch (e) {
      debugPrint('[PushBootstrap] showMissedCallNotification error: $e');
    }
  }

  /// Public API for chat message push notifications.
  Future<void> showMessageNotification(Map<String, dynamic> data) async {
    final convId = (data['conversation_id'] ??
            data['conversationId'] ??
            data['chat_id'] ??
            '')
        .toString()
        .trim();
    if (_activeConversationId != null &&
        convId.isNotEmpty &&
        _activeConversationId == convId) {
      debugPrint(
          '[PushBootstrap] Suppressing showMessageNotification for active conversation: $convId');
      return;
    }
    try {
      await showMessageNotificationOnPlugin(_local, data);
    } catch (e) {
      debugPrint('[PushBootstrap] showMessageNotification error: $e');
    }
  }

  Future<void> handleCallHandled(String callId) async {
    final id = callId.trim();
    if (id.isNotEmpty) {
      unawaited(CallLifecycleTracker.markCallFinished(id));
    }
    _postedIncomingCallIds.remove(id);
    try {
      await _local.cancel(callId.hashCode.abs());
    } catch (_) {}
  }

  Future<void> cancelCallNotification(String callId) async {
    final id = callId.trim();
    if (id.isNotEmpty) {
      unawaited(CallLifecycleTracker.markCallFinished(id));
    }
    IncomingCallService.instance.markNotificationCleared(id);
    if (id.isEmpty) {
      _postedIncomingCallIds.clear();
    } else {
      _postedIncomingCallIds.remove(id);
    }
    try {
      await _local.cancel(callId.hashCode.abs());
    } catch (_) {}
  }

  /// Drops Android incoming-call notifications already on screen, including
  /// ones posted by the background isolate before GRID Chat took the call.
  Future<void> cancelVisibleIncomingCallNotifications() async {
    try {
      final active = await _local.getActiveNotifications();
      for (final notification in active) {
        final id = notification.id;
        if (id == null) continue;
        final channelId = notification.channelId;
        if (channelId != null && channelId != kCallsChannel.id) continue;
        if (channelId == null) {
          final payload = notification.payload ?? '';
          if (!payload.contains('call_id') &&
              !payload.contains('INCOMING_CALL')) {
            continue;
          }
        }
        final payload = notification.payload ?? '';
        if (payload.isNotEmpty) {
          try {
            final decoded = jsonDecode(payload);
            if (decoded is Map) {
              final callId =
                  (decoded['call_id'] ?? decoded['callId'] ?? '').toString();
              IncomingCallService.instance.markNotificationCleared(callId);
            }
          } catch (_) {}
        }
        await _local.cancel(id);
      }
    } catch (e) {
      debugPrint('[PushBootstrap] cancelVisibleIncomingCallNotifications: $e');
    }
    for (final id in _postedIncomingCallIds) {
      IncomingCallService.instance.markNotificationCleared(id);
    }
    _postedIncomingCallIds.clear();
  }

  Future<void> clearChatNotifications(String conversationId) async {
    await GridChatMessageNotifications.instance.clearConversation(
      conversationId,
      _local,
    );
  }

  /// Clears Professional Space (GRID) social activity notifications from the system tray.
  Future<void> clearGridActivityNotifications() async {
    try {
      final active = await _local.getActiveNotifications();
      for (final notification in active) {
        final id = notification.id;
        if (id == null) continue;
        if (notification.channelId == kGridActivityChannel.id ||
            notification.tag == 'grid_activity') {
          await _local.cancel(id, tag: notification.tag);
        }
      }
    } catch (e) {
      debugPrint('[PushBootstrap] clearGridActivityNotifications error: $e');
    }
  }

  /// Clears all chat message notifications from the system tray.
  Future<void> clearAllChatMessageNotifications() async {
    try {
      final active = await _local.getActiveNotifications();
      for (final notification in active) {
        final id = notification.id;
        if (id == null) continue;
        if (notification.channelId == kMessagesChannel.id ||
            (notification.tag != null &&
                notification.tag!.startsWith('conv-'))) {
          await _local.cancel(id, tag: notification.tag);
        }
      }
    } catch (e) {
      debugPrint('[PushBootstrap] clearAllChatMessageNotifications error: $e');
    }
  }

  Future<void> dispose() async {
    await _tokenSub?.cancel();
    _tokenSub = null;
  }
}
