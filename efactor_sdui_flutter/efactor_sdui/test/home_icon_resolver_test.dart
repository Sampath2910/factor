import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:efactor_sdui/home_sdui/home_icon_resolver.dart';

void main() {
  test('Home icon registry names resolve to Font Awesome symbols', () {
    final icons = HomeIconResolver(<String, dynamic>{
      'iconRegistry': <String, dynamic>{
        'crown': <String, dynamic>{
          'flutter': <String, dynamic>{
            'pack': 'font_awesome_flutter',
            'name': 'crown',
          },
        },
      },
    });

    expect(icons.resolve('crown'), FontAwesomeIcons.crown);
    expect(icons.resolve('coins'), FontAwesomeIcons.coins);
    expect(icons.resolve('percent'), FontAwesomeIcons.percent);
    expect(icons.resolve('laptop'), FontAwesomeIcons.laptop);
    expect(icons.resolve('fa-video'), FontAwesomeIcons.video);
    expect(icons.resolve('shopping-cart'), FontAwesomeIcons.shoppingCart);
    expect(icons.resolve('gifts'), FontAwesomeIcons.gifts);
    expect(icons.resolve('bed'), FontAwesomeIcons.bed);
  });

  test('IoT and Grid nav tokens resolve to different schema icons', () {
    final icons = HomeIconResolver(<String, dynamic>{
      'iconRegistry': <String, dynamic>{
        'devices': <String, dynamic>{
          'flutter': <String, dynamic>{
            'pack': 'font_awesome_flutter',
            'name': 'tableCellsLarge',
          },
        },
        'grid': <String, dynamic>{
          'flutter': <String, dynamic>{
            'pack': 'font_awesome_flutter',
            'name': 'borderAll',
          },
        },
        'profile': <String, dynamic>{
          'flutter': <String, dynamic>{
            'pack': 'font_awesome_flutter',
            'name': 'userPen',
          },
        },
      },
    });

    expect(icons.resolve('devices'), FontAwesomeIcons.tableCellsLarge);
    expect(icons.resolve('grid'), FontAwesomeIcons.borderAll);
    expect(icons.resolve('devices'), isNot(icons.resolve('grid')));
    expect(icons.resolve('profile'), FontAwesomeIcons.userPen);
  });
}
