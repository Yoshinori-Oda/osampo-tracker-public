/// 地図タイル(OpenStreetMapの公開タイルサーバー)の設定。全画面の`TileLayer`で共通に使う。
///
/// OpenStreetMapのタイル利用ポリシーでは、アプリを識別できる一意なUser-Agentが必要。
/// flutter_mapは`userAgentPackageName`からUser-Agentを作る。`com.example.*`のような汎用の値や未設定では
/// タイルサーバーに拒否される(2025-08以降、`com.example`を含むものは拒否の対象)。
/// アプリ固有のドメイン(`yoshinori-oda.github.io`)を逆にした値にしている。
const osmTileUrlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const osmUserAgentPackageName = 'io.github.yoshinori_oda.osampo_tracker';
