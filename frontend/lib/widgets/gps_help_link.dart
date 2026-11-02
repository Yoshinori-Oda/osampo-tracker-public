import 'package:flutter/material.dart';
import '../views/gps_help_page.dart';

// 位置情報を掴みやすくするヘルプページへ遷移するリンクボタン。
// 位置情報系のバナー・エラーダイアログから共通で使う。
class GpsHelpLinkButton extends StatelessWidget {
  final Color textColor;

  const GpsHelpLinkButton({super.key, this.textColor = Colors.white});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () {
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(builder: (_) => const GpsHelpPage())
        );
      },
      child: Text('取得のコツ', style: TextStyle(color: textColor))
    );
  }
}
