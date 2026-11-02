// 時刻を"HH:mm:ss"で表示する(絶対時刻)。呼び出し側は経過が数十秒以内に
//収まるケース(startRecordingのフォールバック確認)を想定しており、日付を跨ぐ
// ケースは扱わないため日付は含めない。
String formatTimeOfDayJa(DateTime time) {
  final hh = time.hour.toString().padLeft(2, '0');
  final mm = time.minute.toString().padLeft(2, '0');
  final ss = time.second.toString().padLeft(2, '0');
  return '$hh:$mm:$ss';
}

// 経過時間を"○○前"の形式で表示するための共通フォーマッタ。
// 10秒未満は秒単位で出しても意味が薄いため"10秒以内"にまとめる。
String formatElapsedJa(Duration elapsed) {
  final seconds = elapsed.inSeconds;
  if (seconds < 10) return '10秒以内';
  if (seconds < 60) return '$seconds秒前';

  final minutes = elapsed.inMinutes;
  if (minutes < 60) return '$minutes分前';

  final hours = elapsed.inHours;
  if (hours < 24) return '$hours時間前';

  final days = elapsed.inDays;
  return '$days日前';
}
