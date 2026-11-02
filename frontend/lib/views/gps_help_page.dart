import 'package:flutter/material.dart';

class GpsHelpPage extends StatelessWidget {
  const GpsHelpPage({super.key});

  static const _tips = [
    (
      Icons.wb_sunny_outlined,
      '屋外の開けた場所へ移動する',
      '上空の視界が開けている場所ほど衛星を掴みやすくなります。ビルの谷間や森の中は苦手です。'
    ),
    (
      Icons.domain_disabled_outlined,
      '建物の中・地下・トンネルを避ける',
      '屋内や地下、トンネルの中では衛星の電波が届かず、位置情報を取得できないことがあります。'
    ),
    (
      Icons.backpack_outlined,
      '端末をカバンやポケットの外に出す',
      '端末が金属製のものや体に密着していると、電波を受信しにくくなることがあります。'
    ),
    (
      Icons.wifi,
      'Wi-Fiをオンにする',
      'Wi-Fiがオンになっていると、周辺のアクセスポイント情報を使って屋内でも位置情報の精度が上がることがあります。'
    ),
    (
      Icons.hourglass_empty,
      '少し待ってから再試行する',
      '位置情報の取得には数秒〜数十秒かかることがあります。特に電源を入れた直後は時間がかかりやすいです。'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('位置情報を取得しやすくするには')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _tips.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final (icon, title, description) = _tips[index];
          return Card(
            child: ListTile(
              leading: Icon(icon, size: 32),
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(description)
              )
            )
          );
        }
      )
    );
  }
}
