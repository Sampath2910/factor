import 'package:flutter_test/flutter_test.dart';

import 'package:efactor_sdui/auth_sdui/auth_temporary_api_overlay.dart';

void main() {
  test('overlay does not rewrite login identity or logo URLs', () {
    final schema = <String, dynamic>{
      'state': <String, dynamic>{
        'auth': <String, dynamic>{'accesstoken': 't'},
      },
      'assets': <String, dynamic>{
        'logo': <String, dynamic>{
          'type': 'networkImage',
          'url': 'https://efactor.tech/files/home/Logo_new.png',
        },
      },
      'pages': <dynamic>[
        <String, dynamic>{
          'id': 'login',
          'components': <dynamic>[
            <String, dynamic>{
              'id': 'login_identity',
              'stateKey': 'loginForm.identity',
              'placeholder': 'Email or mobile number',
              'leadingIcon': 'mail',
            },
          ],
        },
      ],
      'validationRules': <String, dynamic>{
        'login': <String, dynamic>{
          'identity': <String, dynamic>{'required': true, 'maxLength': 191},
        },
      },
    };

    final applied = AuthTemporaryApiOverlay.apply(schema);
    final identity = (((applied['pages'] as List).first as Map)['components']
            as List)
        .first as Map;
    expect(identity['placeholder'], 'Email or mobile number');
    expect(identity['leadingIcon'], 'mail');
    expect(
      (applied['assets'] as Map)['logo']['url'],
      'https://efactor.tech/files/home/Logo_new.png',
    );
    expect(
      ((applied['validationRules'] as Map)['login'] as Map)['identity']
          ['maxLength'],
      191,
    );
    expect((applied['state'] as Map)['auth']['accessToken'], 't');
  });
}
