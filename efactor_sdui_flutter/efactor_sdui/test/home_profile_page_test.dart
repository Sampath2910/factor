import 'package:efactor_sdui/home_sdui/home_sdui_renderer.dart';
import 'package:efactor_sdui/home_sdui/home_sdui_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('schema Profile page renders bindings and logs out', (
    tester,
  ) async {
    var loggedOut = false;
    final state = HomeSduiState(
      schema: _profileSchema(),
      accessToken: 'token',
      userId: 655,
      email: 'pavankiran26082003@gmail.com',
      username: 'pavankiran26082003',
    );
    state.hostActionHandler = (actionId, _) async {
      if (actionId == 'logout') loggedOut = true;
    };

    await tester.binding.setSurfaceSize(const Size(400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return HomeSduiRenderer(state).buildComponent(
                context,
                'profile-page',
              );
            },
          ),
        ),
      ),
    );

    expect(find.text('eFactor'), findsNothing);
    expect(find.text('Account'), findsNothing);
    expect(find.text('pavankiran26082003'), findsOneWidget);
    expect(find.text('pavankiran26082003@gmail.com'), findsOneWidget);
    expect(find.text('7815827400'), findsOneWidget);
    expect(find.text('EF-655'), findsOneWidget);
    expect(find.text('Edit profile'), findsOneWidget);
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('English (India)'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Logout'), findsOneWidget);

    await tester.ensureVisible(find.text('Logout'));
    await tester.tap(find.text('Logout'));
    await tester.pump();
    expect(loggedOut, isTrue);
  });
}

Map<String, dynamic> _profileSchema() {
  return <String, dynamic>{
    'state': <String, dynamic>{
      'navigation': <String, dynamic>{'activeRouteId': 'profile'},
    },
    'profilePage': <String, dynamic>{
      'name': 'pavankiran26082003',
      'email': 'pavankiran26082003@gmail.com',
      'phone': '7815827400',
      'memberId': 'EF-655',
      'language': 'English (India)',
    },
    'designTokens': <String, dynamic>{
      'colors': <String, dynamic>{
        'surface': '#ffffff',
        'surfaceElevated': '#F3E8FF',
        'textPrimary': '#111827',
        'textSecondary': '#6B7280',
        'textMuted': '#9CA3AF',
        'accent': '#6D28D9',
      },
      'spacing': <String, dynamic>{
        'xs': 4,
        'sm': 8,
        'md': 12,
        'lg': 16,
      },
    },
    'localization': <String, dynamic>{
      'defaultLocale': 'en',
      'fallbackLocale': 'en',
      'resources': <String, dynamic>{
        'en': <String, dynamic>{
          'profile.edit': 'Edit profile',
          'profile.editSubtitle': 'Manage account details',
          'profile.notifications': 'Notifications',
          'profile.notificationsSubtitle': 'Alerts and reminders enabled',
          'profile.language': 'Language',
          'profile.appearance': 'Appearance',
          'profile.privacy': 'Privacy Policy',
          'profile.privacySubtitle': 'Security and data controls',
          'profile.logout': 'Logout',
        },
      },
    },
    'navigation': <String, dynamic>{'items': <dynamic>[]},
    'routes': <String, dynamic>{
      'profile': <String, dynamic>{'pageId': 'profile'},
    },
    'pages': <String, dynamic>{
      'profile': <String, dynamic>{
        'id': 'profile',
        'routeId': 'profile',
        'rootComponentId': 'profile-page',
      },
    },
    'components': <String, dynamic>{
      'profile-page': <String, dynamic>{
        'id': 'profile-page',
        'type': 'scrollPage',
        'layout': <String, dynamic>{
          'padding': 16,
          'gap': 12,
        },
        'children': <String>[
          'profile-header',
          'profile-menu',
          'profile-logout-button',
        ],
      },
      'profile-header': <String, dynamic>{
        'id': 'profile-header',
        'type': 'profileHeader',
        'nameBinding': <String, dynamic>{
          r'$state': 'session.user.displayName',
          'fallback': 'pavankiran26082003',
        },
        'emailBinding': <String, dynamic>{
          r'$state': 'session.user.email',
          'fallback': 'pavankiran26082003@gmail.com',
        },
        'phoneBinding': <String, dynamic>{
          r'$state': 'session.user.phone',
          'fallback': '7815827400',
        },
        'memberIdBinding': <String, dynamic>{
          r'$state': 'session.user.memberId',
          'fallback': 'EF-655',
        },
        'avatarTextBinding': <String, dynamic>{
          r'$state': 'session.user.initials',
          'fallback': 'P',
        },
        'appearance': <String, dynamic>{
          'cardPadding': 20,
          'cardBorderRadius': 18,
          'avatarSize': 64,
          'avatarFontSize': 22,
          'avatarFontWeight': 800,
          'avatarGradientStart': '#6d28d9',
          'avatarGradientEnd': '#6d28d9',
          'avatarTextColor': '#ffffff',
          'nameFontSize': 20,
          'nameFontWeight': 800,
          'emailFontSize': 13,
          'metaFontSize': 12,
        },
      },
      'profile-menu': <String, dynamic>{
        'id': 'profile-menu',
        'type': 'profileMenu',
        'appearance': <String, dynamic>{
          'listGap': 10,
          'rowMinHeight': 56,
          'rowPaddingVertical': 14,
          'rowPaddingHorizontal': 14,
          'rowBorderRadius': 14,
          'iconBoxSize': 36,
          'iconBoxBorderRadius': 10,
          'iconSize': 16,
          'rowTitleFontSize': 14,
          'rowTitleFontWeight': 700,
          'rowSubtitleFontSize': 11,
          'rowSubtitleFontWeight': 500,
          'chevronSize': 12,
        },
        'items': <dynamic>[
          <String, dynamic>{
            'iconToken': 'profile',
            'label': <String, dynamic>{r'$i18n': 'profile.edit'},
            'subtitle': <String, dynamic>{r'$i18n': 'profile.editSubtitle'},
          },
          <String, dynamic>{
            'iconToken': 'alerts',
            'label': <String, dynamic>{r'$i18n': 'profile.notifications'},
            'subtitle': <String, dynamic>{
              r'$i18n': 'profile.notificationsSubtitle',
            },
          },
          <String, dynamic>{
            'iconToken': 'language',
            'label': <String, dynamic>{r'$i18n': 'profile.language'},
            'subtitle': 'English (India)',
          },
          <String, dynamic>{
            'iconToken': 'appearance',
            'label': <String, dynamic>{r'$i18n': 'profile.appearance'},
            'subtitle': 'Light mode',
          },
          <String, dynamic>{
            'iconToken': 'shield',
            'label': <String, dynamic>{r'$i18n': 'profile.privacy'},
            'subtitle': <String, dynamic>{r'$i18n': 'profile.privacySubtitle'},
          },
        ],
      },
      'profile-logout-button': <String, dynamic>{
        'id': 'profile-logout-button',
        'type': 'actionButton',
        'label': <String, dynamic>{r'$i18n': 'profile.logout'},
        'iconToken': 'logout',
        'actionId': 'logout',
        'appearance': <String, dynamic>{
          'minHeight': 48,
          'borderRadius': 14,
          'backgroundColor': '#111827',
          'textColor': '#ffffff',
        },
      },
    },
  };
}
